# Settings for the GitHub Actions path.
#
# Committed deliberately. These are decisions about how this specific deployment
# is configured, and they belong in code review rather than in a repository
# variable that can be changed without a diff. Values that are genuinely secret,
# or that would differ per account, still arrive as repository variables and are
# passed with -var.
#
# Note that -var beats -var-file. Anything set here must NOT also be passed as a
# -var from the workflow, or the workflow silently wins.

# The bootstrap CloudFormation stack owns the OIDC provider and the Terraform
# role, because neither can be created by the Terraform run that requires them
# to already exist.
create_github_oidc_provider = false
create_terraform_role       = false

# jon-allyn.com already had a hosted zone, created when the domain was
# registered. Adopting it rather than creating a second one, and reading it as a
# data source so `terraform destroy` cannot take the domain's DNS with it.
route53_zone_id = "Z03449763V0AE74DQS39J"

# The domain sends and receives no mail, and never will. Set here rather than as
# a repository variable so it cannot be switched off without a code change:
# publishing these records is a standing security property of the domain, not a
# toggle. See dns.tf for what they do.
manage_email_dns = true

# Delegation already points at the adopted zone, so certificate validation has
# nothing to wait for.
enable_custom_domain = true

# Ceiling for this deployment, raised from the variable's default of 10.
#
# The budget's notifications are percentages of this number, so raising it moves
# both alert points: 80% of actual is now $24 rather than $8, and the 100%
# forecast alarm is now $30. Steady-state spend here is a small fraction of
# that, which is the tradeoff -- more headroom before being told, and a runaway
# has further to climb before the first warning. See monitoring.tf.
monthly_budget_usd = 30
