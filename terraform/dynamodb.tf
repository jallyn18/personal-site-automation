# Single table, on-demand billing. At this traffic level the monthly cost
# rounds to zero, and there is no capacity to tune or forget about.
#
# Access patterns:
#   pk = "VISITS"        sk = "TOTAL"      -> atomic counter
#   pk = "VISITS"        sk = "DAY#<date>" -> per-day counter
#   pk = "DEDUPE#<hash>" sk = "<date>"     -> one-visit-per-day guard, TTL 48h
#   pk = "UPTIME"        sk = "AGGREGATE"  -> rolling availability + latency
#   pk = "UPTIME"        sk = "CHECK#<ts>" -> individual probe, TTL 7d
#   pk = "COST"          sk = "LATEST"     -> month-to-date spend snapshot

resource "aws_dynamodb_table" "metrics" {
  name         = "${local.name}-metrics"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}
