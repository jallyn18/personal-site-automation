# CLAUDE.md — personal-site-automation

Infrastructure and delivery pipeline for https://jon-allyn.com. The site source
lives in `jallyn18/personal-site-gatsby`.

Read [`specs/001-personal-site/spec.md`](./specs/001-personal-site/spec.md) for
what this system is required to do and [`plan.md`](./specs/001-personal-site/plan.md)
for why it is built this way. Both are retroactive; §7 of the plan is the record of
what already went wrong here, and is worth reading before changing anything in the
pipeline.

---

## The one thing that shapes everything

**Terraform cannot be run locally.** No `plan`, no `apply`, no `init` against the
real backend. The registry is unreachable from the working environment. GitHub
Actions is the only execution path, and its logs are the only feedback channel.

So:

- Never claim a change is verified because it looks right. It is verified when a
  run says so.
- `terraform fmt -check -recursive` and reading carefully are the only local
  gates. Use them.
- When a run fails, **read the log before theorising.** Use `get_job_logs` with
  `failed_only: true`, and widen `tail_lines` — Terraform prints its error
  interleaved *inside* the plan output, not after it, so a short tail will show a
  complete-looking plan and hide the error entirely.

## Invariants

Changing any of these is a decision that belongs in a spec revision, not a commit.

1. **No static AWS credentials, ever.** OIDC only. If a change seems to need an
   access key, the change is wrong.
2. **No public origins.** The S3 bucket and the Lambda Function URL are reachable
   only through CloudFront, via OAC. Do not add a bucket policy granting `*`, do
   not set the Function URL to `NONE` auth.
3. **The hosted zone is a data source, not a resource.** Do not import it, do not
   convert it. `terraform destroy` must never be able to delete the DNS for this
   domain. See plan §4.4.
4. **The email-lockout records stay.** SPF `-all`, null MX, DMARC `p=reject`
   with strict alignment, wildcard DKIM revocation. `manage_email_dns` is set in
   `ci.tfvars` deliberately so it cannot be switched off without a diff. See
   plan §4.5.
5. **Apply replays the plan artifact.** It does not re-plan. Do not "simplify" the
   apply job into `terraform apply -auto-approve`.
6. **Deploys are verified against the live site.** Do not remove the verification
   step from the site repo's workflow to make a run pass.
7. **Every Checkov suppression carries a written reason.** No bare skips.

## Layout

```
bootstrap/cloudformation.yaml   the one manual step: OIDC provider, tf role, state bucket
terraform/                      the stack
  ci.tfvars                     committed decisions -- read the header before editing
  dns.tf                        zone (adopted), ACM, alias records, email lockout
  cloudfront.tf                 distribution, OACs, policies, viewer function
  lambda.tf  dynamodb.tf  s3.tf  monitoring.tf  schedules.tf  oidc.tf  ssm.tf
lambdas/{api,cost,uptime}/handler.py
tests/test_{api,cost,uptime}.py  pytest + moto
scripts/resolve-config.sh        pre-flight validation; fails on the real problem
specs/001-personal-site/         spec.md, plan.md
.checkov.yaml                    26 documented suppressions
.github/workflows/               terraform.yml, security.yml, drift.yml
```

## Gotchas that have already cost time

Each of these was a real failure. Details in plan §7.

- **`-var` beats `-var-file`.** A variable set in both places silently takes the
  workflow's value. Anything in `ci.tfvars` must **not** also be passed as `-var`.
- **`for_each` keys must be known at plan time.** Unknown *values* are fine;
  unknown *keys* are not. This bit the ACM validation records — key on
  `domain_name`, never on `resource_record_name`.
- **The OIDC `sub` claim has three shapes, and `environment:` replaces the ref**
  rather than adding to it. Any trust policy must allow all three:
  `…:ref:refs/heads/BRANCH`, `…:pull_request`, `…:environment:production`.
  A job with an `environment:` key presents only the third.
- **Lambda zips must travel with the plan artifact.** Plan and apply run on
  different runners. The directory is `build/` not `.build/` because
  `upload-artifact` excludes dotfiles.
- **`iam:UpdateRole` does not cover trust policies.** That needs
  `iam:UpdateAssumeRolePolicy`.
- **"Re-run" replays the workflow file from the original commit.** To test a
  workflow change, push a new commit. Re-running will silently execute the old
  file.
- **Verify tool and action versions against the real index**, not from memory or a
  local environment. Two separate failures came from pinning versions that do not
  exist (`aquasecurity/trivy-action@0.28.0`, `detect-secrets==1.5.47`).
- **S3 `get-bucket-location` returns `None` for `us-east-1`.** Handle it.
- **`::add-mask::` filters logs, not step summaries**, and it applies only to the
  job that registers it. `resolve-config.sh` masks the account id for that
  reason, in every job that calls it. Do not print the bucket name into
  `$GITHUB_STEP_SUMMARY` — it embeds the account id and summaries are not
  masked. This repository is public, so its logs and summaries are too.

## Working here

**Branch and PR.** Develop on a feature branch, open a PR, let the plan run.
**Do not merge while the plan check is red** — that already happened once and put a
configuration on `main` that could not plan (plan §7.9).

**Local checks before pushing:**

```bash
terraform fmt -check -recursive -diff
pytest                      # moto-mocked, no AWS needed
checkov -d terraform --config-file .checkov.yaml
detect-secrets-hook --baseline .secrets.baseline $(git diff --cached --name-only)
```

**A change to a security control is not done until it has been observed failing.**
Plant the thing it is supposed to catch, confirm it catches it, remove the plant.

**Commit messages** explain why, in prose, wrapped at 72 characters. The diff
already shows what changed.

## Repository settings that cannot live in this repo

These are real controls with no representation in the codebase, so they are
written down here. If any of them is off, the corresponding guarantee elsewhere in
this file is not actually enforced.

**Default branch:** `main`.

**Required status checks on `main`** — these are what stop plan §7.9 recurring:

| Check | From |
| --- | --- |
| `fmt + validate` | `terraform.yml` |
| `plan` | `terraform.yml` |
| `IaC scan` | `security.yml` |
| `Dependency scan` | `security.yml` |
| `Secret scan` | `security.yml` |
| `test (3.12)`, `test (3.13)` | `python.yml` |

`apply` is **not** required — it only runs on push to `main` and is skipped on
pull requests by design.

Required checks and workflow path filters interact badly: a check excluded by a
`paths` filter never reports, and the pull request blocks on it forever. This is
why `terraform.yml` and `python.yml` have no `paths` filter on their
`pull_request` trigger. **Adding one back will deadlock every pull request that
does not touch the filtered paths.**

**Deployment branch policy on the `production` environment:** restricted to
`main`. This is not cosmetic. The OIDC trust policy must allow the
`…:environment:production` subject claim (plan §4.9), and that claim *replaces*
the branch in the token — so AWS cannot see which branch the job ran on, and IAM
can no longer restrict applies to `main`. The environment's branch policy is what
puts that restriction back, at the identity layer. Without it the only thing
standing between any branch and a production apply is an `if:` condition in a
file that any branch can edit.

## Current state

Applied and live on `https://jon-allyn.com`, serving from the adopted hosted zone
(`route53_zone_id` in `ci.tfvars`).

Resource identifiers — distribution, bucket, role ARNs — are deliberately not
written down here. They are Terraform outputs and SSM parameters, they contain the
account id, and a copy in a document is a copy that goes stale. Read them from the
apply job's summary, or `terraform output`.

Open items are tracked in plan §8 — the live ones are the SNS email confirmation,
enabling Cost Explorer, the `production` deployment branch policy, and a required
plan check.
