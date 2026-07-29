output "nameservers" {
  description = "Set these as the NS records at your registrar to delegate the domain to Route53."
  value       = aws_route53_zone.primary.name_servers
}

output "site_url" {
  description = "Public URL of the site."
  value       = var.enable_custom_domain ? local.site_url : "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "cloudfront_domain" {
  description = "Distribution domain, usable before DNS delegation completes."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "distribution_id" {
  description = "CloudFront distribution id, used for cache invalidation."
  value       = aws_cloudfront_distribution.site.id
}

output "site_bucket" {
  description = "S3 bucket the built site is synced into."
  value       = aws_s3_bucket.site.id
}

output "deploy_role_arn" {
  description = "Set as AWS_DEPLOY_ROLE_ARN in the site repository's Actions variables."
  value       = aws_iam_role.deploy.arn
}

output "terraform_role_arn" {
  description = "Set as AWS_TERRAFORM_ROLE_ARN in this repository's Actions variables."
  value       = aws_iam_role.terraform.arn
}

output "metrics_table" {
  description = "DynamoDB table backing the visit counter, uptime and cost panels."
  value       = aws_dynamodb_table.metrics.name
}

output "api_function_url" {
  description = "Direct function URL. Returns 403 unless SigV4-signed; the site reaches it through CloudFront at /api/*."
  value       = aws_lambda_function_url.api.function_url
}
