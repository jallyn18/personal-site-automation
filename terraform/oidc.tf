# GitHub Actions authenticates to AWS with short-lived OIDC tokens. There are no
# access keys stored in either repository -- the only secret GitHub holds is the
# role ARN, which is not sensitive.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS verifies the provider's certificate against its own trust store for
  # this issuer, so the thumbprint is vestigial -- but the API still requires
  # a syntactically valid one.
  # This is a public certificate thumbprint, not a credential.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # pragma: allowlist secret
}

# --- infrastructure role (personal-site-automation) ---------------------------
#
# Only created when Terraform is run from a workstation. When GitHub Actions
# runs Terraform, this role has to exist before the run starts, so it comes
# from bootstrap/cloudformation.yaml instead and create_terraform_role is false.
# The role name is identical either way.

data "aws_iam_policy_document" "terraform_assume_role" {
  count = var.create_terraform_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Plans run on pull requests, applies run on the default branch. Both are
    # scoped to this one repository -- a fork cannot mint a token that matches.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${var.automation_repo}:ref:refs/heads/${var.deploy_branch}",
        "repo:${var.github_owner}/${var.automation_repo}:pull_request",
        # The apply job runs in an environment, which replaces the ref in the
        # claim rather than adding to it.
        "repo:${var.github_owner}/${var.automation_repo}:environment:${var.deploy_environment}",
      ]
    }
  }
}

resource "aws_iam_role" "terraform" {
  count = var.create_terraform_role ? 1 : 0

  name                 = "${local.name}-gha-terraform"
  description          = "Assumed by GitHub Actions in ${var.automation_repo} to manage this stack"
  assume_role_policy   = data.aws_iam_policy_document.terraform_assume_role[0].json
  max_session_duration = 3600
}

# Terraform genuinely needs broad rights to manage what it creates. Scoping this
# to a hand-written allowlist is a maintenance treadmill that tends to end in
# "*" anyway; the honest control is that only this repo's default branch and PRs
# can assume the role, plus the budget alarm below.
resource "aws_iam_role_policy_attachment" "terraform_power" {
  count = var.create_terraform_role ? 1 : 0

  role       = aws_iam_role.terraform[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess deliberately excludes IAM, which this stack needs in order to
# manage its own roles. Granted narrowly rather than by attaching IAMFullAccess.
data "aws_iam_policy_document" "terraform_iam" {
  count = var.create_terraform_role ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:ListRoles",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.name}-*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:TagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    resources = ["*"]
  }

  # Budgets and Cost Explorer sit outside PowerUserAccess.
  statement {
    effect = "Allow"
    actions = [
      "budgets:*",
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "terraform_iam" {
  count = var.create_terraform_role ? 1 : 0

  name   = "iam-and-billing"
  role   = aws_iam_role.terraform[0].id
  policy = data.aws_iam_policy_document.terraform_iam[0].json
}

# --- deploy role (personal-site-gatsby) ---------------------------------------

data "aws_iam_policy_document" "deploy_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the default branch of the site repo. Pull requests build but do not
    # deploy, so a PR from a fork cannot publish to the bucket.
    #
    # The deploy job declares an environment, which replaces the ref in the
    # subject claim rather than adding to it -- both forms are listed so the
    # role works whether or not the job is gated by an environment.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${var.site_repo}:ref:refs/heads/${var.deploy_branch}",
        "repo:${var.github_owner}/${var.site_repo}:environment:${var.deploy_environment}",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-gha-deploy"
  description          = "Assumed by GitHub Actions in ${var.site_repo} to publish the built site"
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume_role.json
  max_session_duration = 3600

  # Without this the failure is a confusing "Invalid principal" from the IAM
  # API rather than a statement of what is actually missing.
  lifecycle {
    precondition {
      condition     = local.oidc_provider_arn != null && local.oidc_provider_arn != ""
      error_message = "No GitHub OIDC provider. Either set create_github_oidc_provider = true, or pass existing_oidc_provider_arn using the OidcProviderArn output from the bootstrap CloudFormation stack."
    }
  }
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid    = "SyncSiteObjects"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObject",
    ]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }

  statement {
    sid       = "ListSiteBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn]
  }

  statement {
    sid       = "InvalidateCache"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [aws_cloudfront_distribution.site.arn]
  }

  # The deploy workflow reads its own configuration rather than hardcoding
  # bucket names and distribution ids in the site repository.
  statement {
    sid       = "ReadDeployConfig"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${local.name}/*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
