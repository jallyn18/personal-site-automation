#!/usr/bin/env bash
#
# Validates the repository configuration and discovers the Terraform state
# bucket's region, then prints everything it resolved.
#
# Run from the workflows before `terraform init`. The point is to fail on the
# actual problem rather than on a downstream symptom: a wrong region surfaces as
# an S3 301 that names no variable, and a mispasted ARN surfaces as an IAM
# "invalid principal" several minutes later.
#
# Reads from the environment (set by the workflow from repository variables) and
# writes state_region to $GITHUB_OUTPUT.

set -euo pipefail

bucket="${TF_STATE_BUCKET:-}"
oidc="${AWS_OIDC_PROVIDER_ARN:-}"
deploy_region="${DEPLOY_REGION:-us-east-1}"

fail() {
  # ::error:: annotates the failure at the top of the run summary.
  echo "::error::$1"
  exit 1
}

# Mask the AWS account id before anything is printed.
#
# On a public repository workflow logs are world-readable, and almost every
# identifier this script handles embeds the account id: the state bucket name,
# the OIDC provider ARN, the caller identity, and the failure messages below
# that quote them back. AWS does not treat an account id as a secret, but it is
# what turns "somebody's infrastructure" into "this account's infrastructure"
# for anyone probing role and bucket names, and masking it costs nothing.
#
# add-mask only applies to the job that registers it, so every job calling this
# script gets its own registration -- which is the point of doing it here.
mask_account() {
  # Exactly twelve digits, or it is not an account id and masking it would
  # redact something we want to be able to read.
  case "$1" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) echo "::add-mask::$1" ;;
  esac
}

# From the ARN first, so the validation failures below are already masked even
# when the credentials are broken and STS cannot answer.
mask_account "$(printf '%s' "$oidc" | cut -d: -f5)"
mask_account "$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || true)"

if [ -z "$bucket" ]; then
  fail "TF_STATE_BUCKET is not set. Use the bootstrap stack's StateBucket output. If you set it, check it is a Repository variable rather than an Environment one -- environment-scoped variables are invisible to jobs without an 'environment:' key."
fi

if [ -z "$oidc" ]; then
  fail "AWS_OIDC_PROVIDER_ARN is not set. Use the bootstrap stack's OidcProviderArn output."
fi

# The bootstrap stack emits three ARNs and it is easy to paste the wrong one.
# An OIDC provider ARN contains ':oidc-provider/'; a role ARN contains ':role/'.
case "$oidc" in
  *":oidc-provider/"*) ;;
  *":role/"*)
    fail "AWS_OIDC_PROVIDER_ARN is set to a role ARN ($oidc). That is the TerraformRoleArn output, which belongs in AWS_TERRAFORM_ROLE_ARN. This variable wants OidcProviderArn, which looks like arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com"
    ;;
  *)
    fail "AWS_OIDC_PROVIDER_ARN does not look like an OIDC provider ARN ($oidc). Expected something containing ':oidc-provider/'."
    ;;
esac

# Discover where the bucket actually is rather than trusting a variable to agree
# with it. S3 answers a cross-region request with a 301 the AWS SDK will not
# follow, so being wrong here is fatal and silent.
#
# get-bucket-location reports us-east-1 as "None", for historical reasons that
# are not going to be fixed.
if ! location="$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text 2>&1)"; then
  fail "Could not read the location of bucket '$bucket': $location"
fi

if [ "$location" = "None" ] || [ "$location" = "null" ] || [ -z "$location" ]; then
  location="us-east-1"
fi

echo "state_region=${location}" >>"$GITHUB_OUTPUT"

echo "state bucket  : ${bucket}"
echo "state region  : ${location} (discovered from the bucket)"
echo "deploy region : ${deploy_region}"
echo "domain        : ${DOMAIN_NAME:-<unset>}"
# enable_custom_domain, route53_zone_id and manage_email_dns live in
# terraform/ci.tfvars, not in repository variables, so they are not echoed
# here -- printing a value this script does not actually control would be
# worse than printing nothing.
echo "oidc provider : ${oidc}"
echo "caller identity:"
aws sts get-caller-identity
