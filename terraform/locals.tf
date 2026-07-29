data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  name = var.project

  # Bucket names are globally unique; account id keeps this collision-free
  # without leaking anything sensitive.
  site_bucket_name = "${var.project}-site-${local.account_id}"

  www_domain = "www.${var.domain_name}"

  subject_alternative_names = coalesce(var.subject_alternative_names, [local.www_domain])

  # Every name the certificate and CloudFront distribution must answer for.
  all_domains = concat([var.domain_name], local.subject_alternative_names)

  site_url = "https://${var.domain_name}"

  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn

  tags = merge(
    {
      Project   = var.project
      ManagedBy = "terraform"
      Repo      = "${var.github_owner}/${var.automation_repo}"
    },
    var.tags,
  )
}
