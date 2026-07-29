# Alerting is deliberately small: a spend guardrail, a signal that the site is
# down, and a signal that the functions are throwing. Anything more would be
# noise for a personal site.

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
  # Confirmation happens out of band: AWS emails a link that must be clicked.
  # Terraform will show this subscription as "pending confirmation" until then.
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "budgets.amazonaws.com"]
    }

    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# --- spend guardrail ----------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 80% of budget on actual spend: early warning.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  # 100% forecast: catches a runaway before the bill actually lands.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  depends_on = [aws_sns_topic_policy.alerts]
}

# --- site availability --------------------------------------------------------

# The prober logs at ERROR when a check fails; turning that into a metric avoids
# a second DynamoDB read path just for alarming.
resource "aws_cloudwatch_log_metric_filter" "probe_failed" {
  name           = "${local.name}-probe-failed"
  log_group_name = aws_cloudwatch_log_group.lambda["uptime"].name
  pattern        = "\"probe failed\""

  metric_transformation {
    name          = "ProbeFailed"
    namespace     = local.name
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "site_down" {
  alarm_name        = "${local.name}-site-down"
  alarm_description = "Two consecutive uptime probes failed against ${var.domain_name}"

  namespace   = local.name
  metric_name = "ProbeFailed"
  statistic   = "Sum"
  period      = var.uptime_check_rate_minutes * 60

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 2 # ride out a single blip
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# --- function health ----------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.functions

  alarm_name        = "${local.name}-${each.key}-errors"
  alarm_description = "The ${each.key} function is throwing"

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  statistic   = "Sum"
  period      = 300

  dimensions = {
    FunctionName = "${local.name}-${each.key}"
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# --- edge health --------------------------------------------------------------

# CloudFront publishes metrics only to us-east-1.
resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  provider = aws.us_east_1

  alarm_name        = "${local.name}-cloudfront-5xx"
  alarm_description = "CloudFront is returning server errors"

  namespace   = "AWS/CloudFront"
  metric_name = "5xxErrorRate"
  statistic   = "Average"
  period      = 300

  dimensions = {
    DistributionId = aws_cloudfront_distribution.site.id
    Region         = "Global"
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 5 # percent
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
}
