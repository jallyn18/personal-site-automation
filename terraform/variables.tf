variable "project" {
  description = "Short name used to prefix every resource."
  type        = string
  default     = "personal-site"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.project))
    error_message = "project must be 3-32 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "aws_region" {
  description = "Region for regional resources (DynamoDB, Lambda, logs)."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = <<-EOT
    Apex domain you own, e.g. "example.com". The Route53 hosted zone is created
    by this stack; point your registrar's nameservers at the zone's NS records
    (see the `nameservers` output) to finish delegation.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*\\.[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a bare apex domain such as example.com (no scheme, no trailing dot)."
  }
}

variable "enable_custom_domain" {
  description = <<-EOT
    Attach the custom domain + ACM certificate to CloudFront.

    Set this to false for the very first apply if your registrar is not yet
    delegating to Route53: ACM validation blocks until DNS resolves publicly,
    and a blocked apply will time out after ~45 minutes. Apply once with false,
    update the nameservers at your registrar, then flip to true.
  EOT
  type        = bool
  default     = true
}

variable "subject_alternative_names" {
  description = "Extra names on the certificate. Defaults to www.<domain_name>."
  type        = list(string)
  default     = null
}

variable "cloudfront_price_class" {
  description = "PriceClass_100 (NA+EU) is the cheapest and fine for a resume site."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "Must be one of PriceClass_100, PriceClass_200, PriceClass_All."
  }
}

variable "github_owner" {
  description = "GitHub user or org that owns the repositories below."
  type        = string
  default     = "jallyn18"
}

variable "site_repo" {
  description = "Repository holding the Gatsby site. Gets a deploy-only IAM role."
  type        = string
  default     = "personal-site-gatsby"
}

variable "automation_repo" {
  description = "Repository holding this Terraform. Gets the infrastructure IAM role."
  type        = string
  default     = "personal-site-automation"
}

variable "deploy_branch" {
  description = "Branch allowed to assume the deploy role and push to production."
  type        = string
  default     = "main"
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Create the GitHub OIDC provider in this account. AWS permits exactly one
    provider per issuer URL, so set this to false if the account already has one
    (from another project) and pass its ARN via existing_oidc_provider_arn.
  EOT
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of a pre-existing GitHub OIDC provider. Required when create_github_oidc_provider = false."
  type        = string
  default     = null

  validation {
    condition     = var.existing_oidc_provider_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/", var.existing_oidc_provider_arn))
    error_message = "existing_oidc_provider_arn must be a valid IAM OIDC provider ARN."
  }
}

variable "alert_email" {
  description = "Address that receives budget and CloudWatch alarm notifications. Requires confirming an SNS subscription email."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly spend that triggers a budget alert. This stack should sit near $1-2/month."
  type        = number
  default     = 10

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero."
  }
}

variable "uptime_check_rate_minutes" {
  description = "How often the uptime prober runs. 5 minutes is ~8,600 invocations/month, well inside the Lambda free tier."
  type        = number
  default     = 5

  validation {
    condition     = var.uptime_check_rate_minutes >= 1 && var.uptime_check_rate_minutes <= 1440
    error_message = "uptime_check_rate_minutes must be between 1 and 1440."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda functions."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}
