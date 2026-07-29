#!/usr/bin/env bash
#
# First-run setup. Drives the whole sequence from an empty AWS account to a
# working stack, so the outputs of one step do not have to be hand-copied into
# the next.
#
#   ./scripts/setup.sh
#
# Terraform still prompts before it changes anything -- this script sequences
# the steps, it does not auto-approve them.
#
# Safe to re-run. Terraform is idempotent, and the steps that write files ask
# before overwriting.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BOOTSTRAP_DIR="terraform/bootstrap"
STACK_DIR="terraform"
BACKEND_FILE="${STACK_DIR}/backend.hcl"
TFVARS_FILE="${STACK_DIR}/terraform.tfvars"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  %s\033[0m\n' "$*"; }
die() {
  printf '\033[31merror: %s\033[0m\n' "$*" >&2
  exit 1
}

step() {
  printf '\n'
  bold "==> $*"
}

# --- 1. preflight -------------------------------------------------------------

step "Checking prerequisites"

command -v terraform >/dev/null || die "terraform not found. Install >= 1.11."
command -v aws >/dev/null || die "aws CLI not found."

tf_version="$(terraform version -json | sed -n 's/.*"terraform_version": *"\([^"]*\)".*/\1/p')"
info "terraform ${tf_version}"

# S3 native state locking (use_lockfile) needs 1.11+.
tf_major="${tf_version%%.*}"
tf_minor="$(printf '%s' "$tf_version" | cut -d. -f2)"
if [ "$tf_major" -lt 1 ] || { [ "$tf_major" -eq 1 ] && [ "$tf_minor" -lt 11 ]; }; then
  die "terraform >= 1.11 required (S3 state locking). Found ${tf_version}."
fi

if ! caller_identity="$(aws sts get-caller-identity --output text --query 'Arn' 2>&1)"; then
  die "no working AWS credentials. Run 'aws configure' or 'aws sso login' first."
fi
info "authenticated as ${caller_identity}"

# --- 2. validate before touching the account ---------------------------------

# This is deliberately first. A provider-schema error costs 30 seconds to find
# here and a failed apply to find later.
step "Validating Terraform"

terraform -chdir="$STACK_DIR" init -backend=false -input=false >/dev/null
terraform -chdir="$STACK_DIR" validate
terraform -chdir="$BOOTSTRAP_DIR" init -backend=false -input=false >/dev/null
terraform -chdir="$BOOTSTRAP_DIR" validate
info "both configurations are valid"

# --- 3. variables -------------------------------------------------------------

step "Checking configuration"

if [ ! -f "$TFVARS_FILE" ]; then
  cp "${STACK_DIR}/terraform.tfvars.example" "$TFVARS_FILE"
  warn "created ${TFVARS_FILE} from the example."
  warn "Set domain_name and alert_email in it, then re-run this script."
  exit 1
fi

if grep -q 'REPLACE-ME' "$TFVARS_FILE"; then
  die "${TFVARS_FILE} still contains REPLACE-ME. Fill it in and re-run."
fi
info "$(basename "$TFVARS_FILE") looks filled in"

# --- 4. state bucket ----------------------------------------------------------

step "Creating the Terraform state bucket"

info "This uses local state and only has to happen once."
terraform -chdir="$BOOTSTRAP_DIR" init -input=false
terraform -chdir="$BOOTSTRAP_DIR" apply

# --- 5. backend config --------------------------------------------------------

step "Writing ${BACKEND_FILE}"

if [ -f "$BACKEND_FILE" ]; then
  warn "${BACKEND_FILE} already exists."
  read -r -p "  Overwrite it? [y/N] " reply
  case "$reply" in
    [yY]*) ;;
    *)
      info "keeping the existing file"
      ;;
  esac
fi

if [ ! -f "$BACKEND_FILE" ] || [[ "${reply:-n}" =~ ^[yY] ]]; then
  terraform -chdir="$BOOTSTRAP_DIR" output -raw backend_config >"$BACKEND_FILE"
  info "wrote $(wc -l <"$BACKEND_FILE" | tr -d ' ') lines"
fi

# --- 6. the stack -------------------------------------------------------------

step "Initialising the main stack against remote state"

terraform -chdir="$STACK_DIR" init -input=false -reconfigure -backend-config=backend.hcl

step "Applying the stack"

# The custom domain is deliberately left off for the first apply. ACM validation
# blocks until the registrar delegates to Route53, and a blocked apply sits for
# ~45 minutes before timing out. The site comes up on the CloudFront domain now;
# the real domain gets switched on once DNS resolves.
if grep -qE '^\s*enable_custom_domain\s*=\s*true' "$TFVARS_FILE"; then
  warn "enable_custom_domain is true in ${TFVARS_FILE}."
  warn "If your registrar is not delegating to Route53 yet, this apply will hang"
  warn "on certificate validation. Set it to false for the first run."
  read -r -p "  Continue anyway? [y/N] " reply
  case "$reply" in
    [yY]*) ;;
    *) die "stopped. Set enable_custom_domain = false and re-run." ;;
  esac
fi

terraform -chdir="$STACK_DIR" apply

# --- 7. what happens next -----------------------------------------------------

step "Done. Next steps"

tfvar() {
  grep -oE "$1"'[[:space:]]*=[[:space:]]*"[^"]*"' "$TFVARS_FILE" |
    head -1 | sed 's/.*"\(.*\)"/\1/'
}

cloudfront_domain="$(terraform -chdir="$STACK_DIR" output -raw cloudfront_domain)"
domain="$(tfvar domain_name)"
alert_email="$(tfvar alert_email)"

cat <<EOF

  The stack is up. CloudFront takes 5-15 minutes to finish deploying the first
  time; until then the URL below may return an error.

  Site (for now):  https://${cloudfront_domain}

  1. Delegate the domain. Set these as the nameservers at your registrar:

$(terraform -chdir="$STACK_DIR" output -json nameservers | tr -d '[]"' | tr ',' '\n' | sed 's/^/       /')

  2. Confirm the alert subscription. AWS has emailed a confirmation link for
     the SNS topic. Alarms go nowhere until it is clicked.

  3. Publish the site. From the personal-site-gatsby repo:

       ./scripts/deploy.sh

  4. Switch on the real domain once delegation resolves. Check it with:

       dig +short NS ${domain}

     When that returns the nameservers above, set enable_custom_domain = true
     in ${TFVARS_FILE} and re-run:

       make apply

  5. Wire up GitHub Actions when you want pushes to deploy themselves:

       Repository variables for personal-site-automation:
         AWS_TERRAFORM_ROLE_ARN = $(terraform -chdir="$STACK_DIR" output -raw terraform_role_arn)
         TF_STATE_BUCKET        = $(terraform -chdir="$BOOTSTRAP_DIR" output -raw state_bucket)
         DOMAIN_NAME            = ${domain}
         ALERT_EMAIL            = ${alert_email}

       Repository variable for personal-site-gatsby:
         AWS_DEPLOY_ROLE_ARN    = $(terraform -chdir="$STACK_DIR" output -raw deploy_role_arn)

EOF
