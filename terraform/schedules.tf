# EventBridge rules drive the two collectors. Classic rules are used rather than
# EventBridge Scheduler: both are free at this volume, and rules keep the
# permission model to a single aws_lambda_permission per target.

resource "aws_cloudwatch_event_rule" "uptime" {
  name                = "${local.name}-uptime"
  description         = "Probe the public site every ${var.uptime_check_rate_minutes} minutes"
  schedule_expression = "rate(${var.uptime_check_rate_minutes} minute${var.uptime_check_rate_minutes == 1 ? "" : "s"})"
}

resource "aws_cloudwatch_event_target" "uptime" {
  rule      = aws_cloudwatch_event_rule.uptime.name
  target_id = "uptime-lambda"
  arn       = aws_lambda_function.uptime.arn
}

resource "aws_lambda_permission" "uptime_events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.uptime.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.uptime.arn
}

# Daily rather than hourly: Cost Explorer charges per request, and yesterday's
# spend does not change often enough to justify the polling.
resource "aws_cloudwatch_event_rule" "cost" {
  name                = "${local.name}-cost"
  description         = "Snapshot month-to-date AWS spend once a day"
  schedule_expression = "cron(0 7 * * ? *)" # 07:00 UTC
}

resource "aws_cloudwatch_event_target" "cost" {
  rule      = aws_cloudwatch_event_rule.cost.name
  target_id = "cost-lambda"
  arn       = aws_lambda_function.cost.arn
}

resource "aws_lambda_permission" "cost_events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cost.arn
}
