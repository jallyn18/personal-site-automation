# Settings for the GitHub Actions path.
#
# Committed deliberately: these are structural facts about how the stack is
# deployed, not secrets and not account-specific. Values that ARE account
# specific -- domain, alert address, the OIDC provider ARN -- come from
# repository variables and are passed with -var on the command line.
#
# The bootstrap CloudFormation stack owns the OIDC provider and the Terraform
# role, because neither can be created by the Terraform run that requires them
# to already exist.

create_github_oidc_provider = false
create_terraform_role       = false
