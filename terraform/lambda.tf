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
  output_path = "${path.module}/.build/${each.key}.zip"
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
