# The site repository discovers where to deploy by reading these parameters at
# job time. Nothing about the infrastructure is duplicated into the other repo,
# so renaming a bucket or replacing the distribution needs no coordinated edit.

resource "aws_ssm_parameter" "site_bucket" {
  name  = "/${local.name}/site_bucket"
  type  = "String"
  value = aws_s3_bucket.site.id
}

resource "aws_ssm_parameter" "distribution_id" {
  name  = "/${local.name}/distribution_id"
  type  = "String"
  value = aws_cloudfront_distribution.site.id
}

resource "aws_ssm_parameter" "site_url" {
  name  = "/${local.name}/site_url"
  type  = "String"
  value = var.enable_custom_domain ? local.site_url : "https://${aws_cloudfront_distribution.site.domain_name}"
}
