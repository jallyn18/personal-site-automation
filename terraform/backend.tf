# Partial backend configuration.
#
# Values are supplied at init time so the same code can target different
# accounts without edits:
#
#   terraform init -backend-config=backend.hcl
#
# See backend.hcl.example. The state bucket itself is created by
# terraform/bootstrap, which uses local state (chicken-and-egg).
#
# State locking uses S3 conditional writes (use_lockfile), not DynamoDB.
# The DynamoDB locking mechanism is deprecated as of Terraform 1.11.
terraform {
  backend "s3" {}
}
