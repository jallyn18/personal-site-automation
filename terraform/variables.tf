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

variable "route53_zone_id" {
  description = <<-EOT
    Id of an existing Route53 hosted zone for domain_name, e.g. "Z0123456789ABCDEFGHIJ".

    Leave null to have this stack create and own the zone. Set it when the zone
    already exists -- registered through Route53, or created by hand -- and the
    stack should publish records into it without owning it. The zone is then read
    as a data source, so `terraform destroy` cannot take the domain's DNS with it.

    Setting this on a stack that already created a zone will destroy that zone on
    the next apply. That is the intended behaviour when the created zone was a
    duplicate, but check that nothing is delegated to it first.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.route53_zone_id == null || can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must look like a Route53 zone id, e.g. Z0123456789ABCDEFGHIJ."
  }
}

variable "manage_email_dns" {
  description = <<-EOT
    Publish SPF and DMARC records declaring that this domain sends no mail.

    Default off because it is destructive to a domain that does send mail:
    "v=spf1 -all" instructs receivers to reject everything from it, and the apex
    TXT record would overwrite anything already there, including domain
    verification tokens.

    Safe to enable on a zone this stack created. On an adopted zone, check what
    is already published first.
  EOT
  type        = bool
  default     = false
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

variable "deploy_environment" {
  description = <<-EOT
    GitHub Actions environment the deploying jobs run in.

    A job that declares an environment presents an OIDC subject claim of
    "environment:<name>" instead of "ref:<ref>" -- the ref is replaced, not
    supplemented -- so the trust policies have to name it explicitly or a job
    with an environment cannot assume the role even when one without can.
  EOT
  type        = string
  default     = "production"
}

variable "create_terraform_role" {
  description = <<-EOT
    Create the IAM role GitHub Actions assumes in order to run Terraform.

    Set to false when that role comes from bootstrap/cloudformation.yaml, which
    is the case whenever the pipeline rather than a workstation runs Terraform:
    the role cannot be created by the Terraform run that needs it to exist.

    terraform/ci.tfvars sets this to false for the GitHub Actions path.
  EOT
  type        = bool
  default     = true
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

variable "cost_filter_tag" {
  description = <<-EOT
    Restrict the cost figures published on the site to resources carrying this
    cost-allocation tag, as { key = "...", value = "..." }.

    Leave null to report whole-account spend. That is the right answer when the
    account hosts nothing but this site, and the wrong one when it does not --
    the figure is published publicly, so an account with other workloads in it
    would be advertising their combined bill.

    Every resource in this stack is already tagged Project = <project>, so
    { key = "Project", value = "personal-site" } scopes it correctly. The tag
    must first be activated under Billing -> Cost allocation tags, and takes up
    to 24 hours to appear in Cost Explorer after activation.
  EOT
  type = object({
    key   = string
    value = string
  })
  default = null
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
