locals {
  lambda_runtime = "python3.12"

  # Every function gets its own role. Sharing one role across three functions
  # would mean the uptime prober could read cost data, which it has no business
  # doing.
  functions = {
    api    = { timeout = 10, memory = 256 }
    uptime = { timeout = 30, memory = 128 }
    cost   = { timeout = 60, memory = 256 }
  }
}

data "archive_file" "lambda" {
  for_each = local.functions

  type        = "zip"
  source_dir  = "${path.module}/../lambdas/${each.key}"
  output_path = "${path.module}/build/${each.key}.zip"
}

# Rotating this salt resets same-day visit dedupe, which is harmless. It exists
# so stored fingerprints cannot be brute-forced back to an IP address.
resource "random_password" "dedupe_salt" {
  length  = 32
  special = false
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each = local.functions

  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.functions

  name              = "/aws/lambda/${local.name}-${each.key}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "lambda_logs" {
  for_each = local.functions

  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda[each.key].arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda_logs" {
  for_each = local.functions

  name   = "logs"
  role   = aws_iam_role.lambda[each.key].id
  policy = data.aws_iam_policy_document.lambda_logs[each.key].json
}

# --- per-function data access -------------------------------------------------

data "aws_iam_policy_document" "api_data" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
    ]
    resources = [aws_dynamodb_table.metrics.arn]
  }
}

resource "aws_iam_role_policy" "api_data" {
  name   = "dynamodb"
  role   = aws_iam_role.lambda["api"].id
  policy = data.aws_iam_policy_document.api_data.json
}

data "aws_iam_policy_document" "uptime_data" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.metrics.arn]
  }
}

resource "aws_iam_role_policy" "uptime_data" {
  name   = "dynamodb"
  role   = aws_iam_role.lambda["uptime"].id
  policy = data.aws_iam_policy_document.uptime_data.json
}

data "aws_iam_policy_document" "cost_data" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.metrics.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
    ]
    # Cost Explorer has no resource-level permissions; "*" is the only valid value.
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cost_data" {
  name   = "cost-explorer"
  role   = aws_iam_role.lambda["cost"].id
  policy = data.aws_iam_policy_document.cost_data.json
}

# --- functions ----------------------------------------------------------------

resource "aws_lambda_function" "api" {
  function_name = "${local.name}-api"
  role          = aws_iam_role.lambda["api"].arn
  handler       = "handler.handler"
  runtime       = local.lambda_runtime
  architectures = ["arm64"] # ~20% cheaper per ms than x86_64

  filename         = data.archive_file.lambda["api"].output_path
  source_code_hash = data.archive_file.lambda["api"].output_base64sha256

  timeout     = local.functions["api"].timeout
  memory_size = local.functions["api"].memory

  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.metrics.name
      DEDUPE_SALT = random_password.dedupe_salt.result
      LOG_LEVEL   = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_function" "uptime" {
  function_name = "${local.name}-uptime"
  role          = aws_iam_role.lambda["uptime"].arn
  handler       = "handler.handler"
  runtime       = local.lambda_runtime
  architectures = ["arm64"]

  filename         = data.archive_file.lambda["uptime"].output_path
  source_code_hash = data.archive_file.lambda["uptime"].output_base64sha256

  timeout     = local.functions["uptime"].timeout
  memory_size = local.functions["uptime"].memory

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.metrics.name
      # Probe the CloudFront domain when the custom domain is not live yet,
      # otherwise every check fails until DNS delegation finishes.
      SITE_URL  = var.enable_custom_domain ? local.site_url : "https://${aws_cloudfront_distribution.site.domain_name}"
      LOG_LEVEL = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_function" "cost" {
  function_name = "${local.name}-cost"
  role          = aws_iam_role.lambda["cost"].arn
  handler       = "handler.handler"
  runtime       = local.lambda_runtime
  architectures = ["arm64"]

  filename         = data.archive_file.lambda["cost"].output_path
  source_code_hash = data.archive_file.lambda["cost"].output_base64sha256

  timeout     = local.functions["cost"].timeout
  memory_size = local.functions["cost"].memory

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.metrics.name
      LOG_LEVEL  = "INFO"

      # Empty means no filter, which reports whole-account spend.
      COST_TAG_KEY   = try(var.cost_filter_tag.key, "")
      COST_TAG_VALUE = try(var.cost_filter_tag.value, "")
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# --- function URL -------------------------------------------------------------

# AWS_IAM auth means an unsigned request gets 403. Combined with the resource
# policy below, only this CloudFront distribution can invoke the function.
resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "AWS_IAM"
}

resource "aws_lambda_permission" "cloudfront_invoke_api" {
  statement_id           = "AllowCloudFrontOAC"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.site.arn
  function_url_auth_type = "AWS_IAM"
}

# The second statement is not redundant. AWS's own instructions for putting an
# OAC in front of a function URL issue two add-permission calls, one for
# lambda:InvokeFunctionUrl and one for lambda:InvokeFunction, and this stack
# only ever had the first.
#
# That reads like belt and braces -- InvokeFunctionUrl is the action documented
# for function URLs, and plenty of published examples grant only it -- so it was
# passed over twice while /api/* returned nothing but the site's 404 page. It
# was the whole problem. Adding it turned every endpoint from 404 to 200 with no
# other change.
#
# Granting only InvokeFunctionUrl fails in a way that is almost impossible to
# read from outside. Every individual piece checks out: the cache behaviour is
# applied at the edge, it targets this origin, the OAC is lambda/always/sigv4
# and attached to it, the function URL is AWS_IAM with a matching host, and a
# correctly signed request to that URL returns 200. CloudFront is simply refused,
# and the distribution turns the resulting origin 403 into /404.html, so the
# symptom is a missing page rather than a permissions error.
#
# Follow AWS's instructions exactly here. The apparently redundant second call
# is the one that matters.
#
# No function_url_auth_type here, unlike the statement above. AddPermission
# rejects the pair outright -- "FunctionUrlAuthType is only supported for
# lambda:InvokeFunctionUrl action" -- and AWS's own second command does not
# pass it either. Terraform cannot catch this at plan time because the
# validation happens in the Lambda API, so it surfaces as a failed apply.
resource "aws_lambda_permission" "cloudfront_invoke_api_function" {
  statement_id  = "AllowCloudFrontOACInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.site.arn
}
