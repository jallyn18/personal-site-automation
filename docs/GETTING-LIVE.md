# Getting live

From an empty AWS account to a site you can look at, without running Terraform
locally. Everything runs in GitHub Actions; the only manual step is one
CloudFormation stack in the AWS console.

The site comes up on a CloudFront URL first, so you are not blocked waiting on
domain delegation. `jon-allyn.com` gets switched on afterwards.

---

## Why there is a manual step at all

Terraform cannot store state before its state bucket exists, and GitHub Actions
cannot assume a role that has not been created yet. Something has to come from
outside Terraform. `bootstrap/cloudformation.yaml` is that something: it creates
the OIDC trust relationship, the role the pipeline assumes, and the state
bucket — and nothing else.

The alternative is putting AWS access keys in GitHub secrets to bootstrap, then
removing them. This avoids that entirely: **no long-lived AWS credentials exist
at any point.**

---

## 1. Deploy the bootstrap stack

AWS Console → **CloudFormation** → **Create stack** → **With new resources** →
**Upload a template file** → choose `bootstrap/cloudformation.yaml` from this
repository.

Stack name: `personal-site-bootstrap`

Leave every parameter at its default unless your account already has a GitHub
OIDC provider — in that case set `CreateOidcProvider` to `No` and paste the
existing ARN into `ExistingOidcProviderArn`.

Acknowledge the IAM capability checkbox and create it. Takes about a minute.

When it finishes, open the **Outputs** tab. You need all three values.

## 2. Set the repository variables

In **personal-site-automation** → Settings → Secrets and variables → Actions.

**Variables** tab → New repository variable:

| Variable | Value |
| --- | --- |
| `AWS_TERRAFORM_ROLE_ARN` | `TerraformRoleArn` from the stack outputs |
| `TF_STATE_BUCKET` | `StateBucket` from the stack outputs |
| `AWS_OIDC_PROVIDER_ARN` | `OidcProviderArn` from the stack outputs |
| `DOMAIN_NAME` | `jon-allyn.com` |

**Secrets** tab → New repository secret:

| Secret | Value |
| --- | --- |
| `ALERT_EMAIL` | an address you actually read |

The four ARNs and names are variables because none of them are credentials. A
role ARN is an identifier; knowing it grants nothing, because the trust policy
decides who may assume the role and it demands an OIDC token from this specific
repository. AWS treats account IDs and role ARNs as non-secret, and they appear
throughout published documentation and templates.

There is also a practical reason not to make them secrets: GitHub masks secret
values everywhere they appear in logs. Put the account ID in a secret and every
Terraform plan turns into `***` soup, precisely when you need to read it.

`ALERT_EMAIL` is the exception. It is not a credential either, but it is
personal data, and if these repositories are public then so are the Actions
logs. Masking is the behaviour you want. Terraform plans will show `***` where
the address appears, which is a small price.

> **If your repositories are public**, the plan output in Actions logs is
> publicly readable — including your AWS account ID, bucket names, and role
> ARNs. That is normal and AWS does not treat it as a disclosure, but it is a
> deliberate choice rather than an accident. Making the automation repository
> private is the alternative, at the cost of the "read the code" claim the site
> makes.

Leave `ENABLE_CUSTOM_DOMAIN` unset for now. It defaults to `false`, which is
what you want until DNS is delegated.

## 3. Run a plan without changing anything

Actions → **terraform** → **Run workflow** → pick the branch
`claude/aws-professional-website-bpwdzi` → Run.

On a non-default branch this runs `fmt`, `validate`, and `plan`, then stops. The
apply job is gated to the default branch and will show as skipped.

**This is the step that matters.** The Terraform in this repository has never
had `terraform validate` run against real provider schemas — the sandbox it was
written in blocks the Terraform registry. If something is wrong, it surfaces
here, having changed nothing.

Read the plan in the job summary. Expect roughly 60 resources: a hosted zone,
a CloudFront distribution, an S3 bucket, three Lambdas, a DynamoDB table, IAM
roles, alarms, and a budget.

If it fails, send me the error.

## 4. Apply

Merge the branch into `main`:

```
Pull requests → New pull request → base: main, compare: claude/aws-professional-website-bpwdzi
```

Opening the PR runs plan again and posts it. Merging runs plan **and apply**.

The apply job uses a `production` environment. GitHub creates it automatically
on first use with no protection rules, so it runs unattended. Add required
reviewers later in Settings → Environments if you want a human gate.

Expect 5–10 minutes, most of it CloudFront.

When it finishes, the job summary prints the site URL, the distribution id, and
the bucket name.

**CloudFront takes a further 5–15 minutes to finish deploying the first time.**
The URL will error until it does. That is normal, not a failure.

## 5. Publish the site

In **personal-site-gatsby** → Settings → Secrets and variables → Actions →
Variables:

| Variable | Value |
| --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | from the terraform job summary, or the `deploy_role_arn` output |

Then merge that repository's branch into `main` the same way. Pushing to `main`
triggers the deploy workflow, which builds the site, uploads it in two cache
passes, invalidates CloudFront, and then fetches the live URL to confirm your
commit is actually being served before reporting success.

**At this point you have a site to look at.**

## 6. Iterate

Edit content in `src/data/` — `profile.js`, `experience.js`, `projects.js`,
`skills.js`. Commit to `main`. The deploy workflow runs and the change is live
in a couple of minutes.

For a faster loop, run the site locally first:

```bash
npm install
npm run develop   # localhost:8000
```

No AWS access needed. The `/api/*` panels show placeholders locally; everything
else renders exactly as it will in production.

## 7. Point the domain at it

The terraform job summary includes the nameservers, or read them from the
Route53 console — the hosted zone for `jon-allyn.com` already exists.

Set those four values as the NS records at your registrar. Delegation usually
resolves within an hour.

Check from anywhere:

```
https://dnschecker.org/#NS/jon-allyn.com
```

When it returns the AWS nameservers, add the repository variable:

| Variable | Value |
| --- | --- |
| `ENABLE_CUSTOM_DOMAIN` | `true` |

Then Actions → terraform → Run workflow on `main`. This requests the
certificate, validates it over DNS, attaches it to the distribution, and creates
the apex and `www` records.

If you set this before delegation resolves, the apply will sit on certificate
validation for about 45 minutes and then fail. Nothing breaks — set the variable
back to `false` and re-run — but it wastes an afternoon.

## 8. Confirm the alert email

AWS sent a subscription confirmation to `ALERT_EMAIL` during the first apply.
Until you click it, the budget alarm and the site-down alarm publish into
nothing.

---

## When something goes wrong

**`terraform validate` fails in step 3.** Send me the error. That is the one
thing in this stack never checked against real provider schemas.

**"Not authorized to perform sts:AssumeRoleWithWebIdentity" in the terraform
job.** The trust policy did not match the token. In order:

1. **Is the bootstrap stack on the current template?** A version of it built the
   subject pattern without the `ref:` segment GitHub's claim actually uses, so
   nothing ever matched. Update the stack with the template from this
   repository — CloudFormation → the stack → Update → Replace existing template
   → upload → keep the parameters → submit. IAM changes apply immediately; no
   need to re-run anything else.
2. **Is `AWS_TERRAFORM_ROLE_ARN` set on the right repository**, as a variable?
3. **Does the branch match `AllowedRefPattern`?** Default `refs/heads/*` allows
   any branch. Give the ref without the `ref:` prefix — the template adds it.

To see the claim your run actually presented, add a step before the credentials
step and read it from the job log:

```yaml
      - run: echo "${{ github.workflow_ref }} on ${{ github.ref }}"
```

**"Bucket already exists" from the CloudFormation stack.** Someone has already
created `personal-site-tfstate-<account-id>`. If that was a previous attempt,
delete the bucket or change `ProjectName`.

**The apply hangs on `aws_acm_certificate_validation`.** DNS delegation has not
resolved. Cancel the run, set `ENABLE_CUSTOM_DOMAIN` to `false`, re-run.

**The deploy workflow fails reading SSM.** Infrastructure is not up yet, or the
apply failed. Run the terraform workflow first.

**The deploy says the commit never appeared.** If the distribution was created
in the last few minutes it is still deploying. Re-run the workflow once it
settles.

**The uptime and cost panels show placeholders.** Expected at first. The uptime
prober runs every 5 minutes; the cost collector runs daily at 07:00 UTC, and
Cost Explorer itself needs enabling once in the Billing console and takes up to
24 hours to populate.

---

## What this costs

Roughly $1–2/month. The Route53 hosted zone ($0.50) and the Cost Explorer API
calls (~$0.60) are the fixed floor; CloudFront, S3, Lambda and DynamoDB land in
the cents at personal-site traffic.

A budget alarm emails you at 80% of actual and 100% of forecast spend against
`monthly_budget_usd`, which defaults to $10.

## Tightening up afterwards

Once things are running, two things are worth doing:

1. Update the CloudFormation stack and set `AllowedRefPattern` to
   `refs/heads/main`. Branch plans stop working, which is the point.
2. Add required reviewers to the `production` environment in both repositories,
   so an apply needs a human click.

## If you ever get local Terraform

`scripts/setup.sh` does all of the above from a workstation, and
`personal-site-gatsby/scripts/deploy.sh` publishes without waiting for CI. Both
paths produce identical infrastructure — the local one has Terraform create the
role and state bucket itself, so leave `create_terraform_role` at its default
and skip `ci.tfvars`.
