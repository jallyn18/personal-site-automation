# Plan 001 — Personal professional website

| | |
| --- | --- |
| **Status** | Executed |
| **Written** | 2026-07-29, **after** execution |
| **Spec** | [`spec.md`](./spec.md) |
| **Delivered** | `03c0fcd` … `9ae6813` (automation), `66b3b2a` … `b518dbb` (site) |

> **This plan is retroactive.** It records the architecture that was built and the
> reasoning behind it, reconstructed on the day the system went live. §7 is the
> part a forward-written plan would not contain: what actually went wrong, and what
> each failure taught. That section is the most useful thing in this document and
> the least flattering, which is why it is here.

---

## 1. Architecture

```
                        Route53  jon-allyn.com  (adopted zone, not owned)
                                      │
                                A/AAAA alias
                                      ▼
                        ┌──────────────────────────────┐
                        │  CloudFront distribution     │
                        │  ACM cert (us-east-1)        │
                        │  security headers policy     │
                        │  viewer function: index      │
                        └───────┬──────────────┬───────┘
                        default │              │ /api/*
                          (OAC) │              │ (OAC, AWS_IAM)
                                ▼              ▼
                     ┌──────────────┐   ┌──────────────────┐
                     │ S3  private  │   │ Lambda  api      │
                     │ Gatsby build │   │ Function URL     │
                     └──────────────┘   └────────┬─────────┘
                                                 │
                                        ┌────────▼─────────┐
                                        │ DynamoDB metrics │
                                        └────────▲─────────┘
                                                 │
                          EventBridge ──▶ Lambda uptime  (probes the live site)
                          EventBridge ──▶ Lambda cost    (reads Cost Explorer)

              CloudWatch alarms ──▶ SNS ──▶ email        AWS Budgets ──▶ SNS
```

Two origins behind one distribution. One hostname, so the browser makes
same-origin requests and CORS never enters the picture.

## 2. Repository split

| Repo | Owns | Changes when |
| --- | --- | --- |
| `personal-site-automation` | Terraform, Lambda handlers, bootstrap, security and drift workflows | Infrastructure changes |
| `personal-site-gatsby` | Site source, content data, deploy workflow | Content or presentation changes |

**Decision.** Two repos, not one.

**Why.** Content changes should be cheap and frequent; infrastructure changes
should be rare and reviewed. A monorepo puts a typo fix in the same blast radius
as a distribution replacement. The two repos are coupled only through SSM
Parameter Store: the site repo reads `/personal-site/site_bucket`,
`/personal-site/distribution_id`, and `/personal-site/site_url` at deploy time, so
renaming a bucket or replacing the distribution needs no change in the site repo
at all (NFR-8).

## 3. Delivery, given that Terraform cannot run locally (CON-1)

This constraint drives more of the design than any other.

```
bootstrap/cloudformation.yaml     ── once, by hand ──▶  OIDC provider
                                                        terraform role
                                                        state bucket

pull request  ──▶ fmt/validate ──▶ plan ──▶ plan posted, artifact uploaded
merge to main ──▶ fmt/validate ──▶ plan ──▶ apply (replays the artifact)
daily 08:00Z  ──▶ plan -detailed-exitcode ──▶ opens/updates a drift issue
push to site  ──▶ build ──▶ sync ──▶ invalidate ──▶ verify live ──▶ summary
```

Three consequences worth naming:

**The plan artifact is the unit of apply.** `apply` replays the exact `tfplan`
the plan job produced. It does not re-plan. Nobody can inspect a plan locally,
so the plan that was reviewed must be the plan that executes — re-planning at
apply time would silently act on a moved target.

**Lambda zips travel with the plan.** `archive_file` builds them during plan and
the plan records their hashes. Apply runs on a different runner. Rebuilding there
would upload bytes the plan never hashed; not shipping them means apply cannot
find its own artifacts. So `terraform/build/` is uploaded alongside `tfplan`.
(The directory is `build/` and not `.build/` because `upload-artifact` silently
excludes dotfiles.)

**Verification is not optional.** The site deploy fetches the live URL and asserts
the short SHA appears on `/pipeline/`, retrying five times, failing the run if it
never does (NFR-6, AC-5). Without this the pipeline reports success on the strength
of `aws s3 sync` having exited zero, which is not the same claim.

## 4. Decisions

### 4.1 CloudFront + S3 + Lambda Function URL — no API Gateway

**Rejected:** API Gateway HTTP API in front of the Lambda.

API Gateway is a second service to configure, a second place for auth to be wrong,
and a per-request cost, in exchange for routing that a CloudFront cache behaviour
already does. A Lambda Function URL with `AWS_IAM` auth, reached through a
CloudFront **Origin Access Control** of type `lambda`, gives a private origin with
CloudFront signing each request. The function URL returns 403 to anyone who calls
it directly (AC-4).

The S3 origin uses the same mechanism with OAC type `s3`. Neither origin is
public — one distribution, two private origins, no bucket website endpoint, no
legacy OAI.

### 4.2 Gatsby

**Rejected:** Next.js, plain HTML, Astro.

Static output onto S3 is the whole requirement. Gatsby's GraphQL layer and Head
API cover the metadata and sitemap work, and React is the ecosystem Jon can edit
fluently. Next.js implies a server this design deliberately does not have. Plain
HTML would have meant hand-rolling the metadata and sitemap.

### 4.3 DynamoDB as the only datastore

One on-demand table, single-table keyed:

| pk | sk | Holds |
| --- | --- | --- |
| `VISITS` | `TOTAL`, `DAY#<date>` | Visit counters |
| `DEDUPE#<fingerprint>` | — | Dedupe marker, TTL'd |
| `UPTIME` | `AGGREGATE`, per-probe | Probe results and rollup |
| `COST` | `LATEST` | Month-to-date and forecast |

On-demand billing means idle cost is effectively zero, which matters more than
throughput at this scale. Dedupe is a conditional write on
`attribute_not_exists(pk)` — the write itself is the check, so there is no
read-then-write race. The fingerprint is salted and not reversible to an IP.

### 4.4 The hosted zone is adopted as a **data source**, never imported

The most consequential decision in the DNS layer.

`jon-allyn.com` had a hosted zone from registration (CON-2). Terraform reads it
via `data.aws_route53_zone` and manages records *inside* it. It does not manage
the zone.

**Why not import it.** An imported zone is a zone `terraform destroy` can delete.
The zone predates this stack and will outlive it; a website stack should not hold
the power to take a domain's DNS with it when torn down. Terraform manages the
records it owns inside the zone; it does not own the zone.

A `postcondition` on the data source compares the zone's name to `domain_name` and
fails the plan if they disagree — a zone id pasted from the wrong domain is caught
before a single record is written into it.

### 4.5 The domain is locked out of email, as configuration and not a toggle

Four records, all four required to make the guarantee stick:

| Record | Value | Without it |
| --- | --- | --- |
| `TXT jon-allyn.com` | `v=spf1 -all` | Anyone may claim to send as the domain |
| `MX jon-allyn.com` | `0 .` | RFC 7505 null MX; senders queue and retry for days, and the domain becomes a bounce-scattering target |
| `TXT _dmarc` | `p=reject; sp=reject; adkim=s; aspf=s;` | SPF failures are advisory; subdomains are unprotected; relaxed alignment slips past both |
| `TXT *._domainkey` | `v=DKIM1; p=` | A forged message can still pass DKIM under an unwatched selector |

`manage_email_dns = true` lives in `terraform/ci.tfvars` — committed, in code
review — rather than in a repository variable, because publishing these records is
a standing security property of the domain and not something that should be
switchable without a diff. No `rua=` reporting address: the reports would be empty
by construction, and a personal address in a public TXT record is an open
invitation to harvesters.

The variable defaults to `false`, because `v=spf1 -all` is destructive to a domain
that *does* send mail and would overwrite an existing apex TXT record such as a
verification token.

### 4.6 Bootstrap in CloudFormation

**Rejected:** a second Terraform state, or a script.

Terraform cannot create the credentials that let Terraform run (CON-3). Something
has to be first, and it should be declarative, reviewable, and obviously
one-time. `bootstrap/cloudformation.yaml` creates the GitHub OIDC provider, the
`personal-site-gha-terraform` role, and the state bucket. It is the only manual
step, and it is a stack rather than a script so that what it created is
inspectable and updatable later — which it was, four times.

### 4.7 S3 state with native locking

`use_lockfile = true` — S3 conditional writes. The DynamoDB locking table is
deprecated and there is no reason to provision one. The backend region is
**discovered** at run time via `aws s3api get-bucket-location` rather than
configured, for reasons in §7.2.

### 4.8 Broad IAM for Terraform, narrow trust policy

The Terraform role carries `PowerUserAccess` plus a narrow IAM block scoped to
`personal-site-*` role ARNs. Hand-maintaining an allowlist for "everything this
stack might create" is a treadmill that ends at `*` anyway; the real controls are
the trust policy, the apply gate, and the budget alarm. IAM is granted by name
prefix rather than by attaching `IAMFullAccess`.

### 4.9 OIDC subject claims — all three shapes

The token's `sub` claim takes different forms depending on how the job runs, and
**an `environment:` claim replaces the ref rather than adding to it**:

```
repo:OWNER/REPO:ref:refs/heads/BRANCH     branch push
repo:OWNER/REPO:pull_request              pull request
repo:OWNER/REPO:environment:production    any job with environment:
```

Every trust policy in this system allows all three, because a job with an
`environment:` key presents *only* the third. This is audited across all four
AWS-touching jobs (plan, apply, drift, site deploy).

**Consequence, recorded as OQ-4:** allowing the environment claim removes IAM's
branch restriction for jobs that use it. The correct compensating control is a
**deployment branch policy** on the `production` environment in repository
settings, which is not yet configured.

### 4.10 Security scanning as pinned pip CLIs

`checkov==3.3.8`, `pip-audit==2.10.1`, `detect-secrets==1.5.0`, installed by pip,
not marketplace actions. Exact versions, no tag resolution at run time, no
third-party action in the credentials path. Checkov runs with `skip-download: true`
for hermetic runs, and its 26 suppressions each carry a written reason.

## 5. Observability and cost

- **Alarms** on Lambda errors (per function), site-down (from the probe's metric
  filter), and a monthly AWS Budget — all to one SNS topic with an email
  subscription.
- **Log retention** 14 days by default. Indefinite retention on a personal site is
  a slow-growing bill for data nobody will read.
- **Drift detection** daily at 08:00 UTC via `plan -detailed-exitcode`, which
  distinguishes "no changes" (0) from "error" (1) from "drift" (2). Drift opens a
  GitHub issue, or comments on the existing one rather than filing a fresh issue
  every morning.
- **Uptime** is measured by a Lambda probing the live site every 5 minutes, so the
  figure on the site is observed rather than asserted (FR-11).

## 6. Phases, as executed

1. **Content interview.** No career facts invented; unknowns left as `TODO:`
   markers (FR-4).
2. **Terraform + Lambdas + workflows** written in full. `03c0fcd`.
3. **Bootstrap stack** deployed by hand. `3cdf060`.
4. **Debug the pipeline into working order.** Six distinct failures — §7.
5. **First apply.** 55 resources. Site deployed and verified serving `b518dbb` on
   the first attempt.
6. **Adopt the real hosted zone, lock out email, enable the custom domain.**
   `ad5ed80` … `9ae6813`. Live on `jon-allyn.com`.

## 7. What went wrong

The part a forward-written plan cannot contain.

### 7.1 The OIDC subject claim was wrong, and `cfn-lint` passed it

The bootstrap template produced `repo:O/R:refs/heads/*`. The real claim is
`repo:O/R:ref:refs/heads/*` — a literal `ref:` segment. The template was
schema-valid and semantically wrong, so linting had nothing to say. **A validator
that checks shape cannot check meaning.**

### 7.2 State bucket region hardcoded; then "fixed" with something that silently returned empty

The backend region was pinned to `us-east-1`; the bucket was in `us-east-2`. S3
answers a cross-region request with a 301 the SDK will not follow, and the error
names no variable.

The first fix hoisted the region into a workflow-level `env:` block reading from
`vars` — a context with restricted access there, which yields empty rather than
erroring. **The failure mode of an expression that resolves to nothing is worse
than the bug it replaced.** The final fix removed the variable entirely and
discovers the region with `aws s3api get-bucket-location`, handling the historical
`None` that means `us-east-1`.

### 7.3 "Re-run" replays the workflow file from the original commit

Several rounds of fixes appeared to change nothing. The runs showed
`run_attempt: 3` against a stale `head_sha`: re-running replays the *original*
commit's workflow. The fixes had never executed. Found by querying the API for run
metadata rather than reading the logs again.

### 7.4 A repository variable held the wrong ARN

`AWS_OIDC_PROVIDER_ARN` had been set to the role ARN. It surfaced minutes later as
an unrelated IAM error. `scripts/resolve-config.sh` now validates the shape and
distinguishes `:role/` from `:oidc-provider/` with a message naming the variable
the value actually belongs in.

**This is the pattern behind §7.1 through §7.4:** every one presented as a failure
somewhere other than its cause. The response was to add validation that fails on
the *actual problem* — which is what `resolve-config.sh` is for.

### 7.5 The security scans were decorative

`aquasecurity/trivy-action@0.28.0` does not exist, so all three jobs failed before
scanning anything — and the original config had `exit-code: "0"`, meaning it would
have reported nothing even had it run. Then `detect-secrets==1.5.47` did not exist
either; that version had been read off a sandbox instead of the real index. Then
`detect-secrets scan --baseline` turned out to *mutate* the baseline, so the
`git diff --exit-code` assertion built on it could never pass — it would have
failed forever and looked like a genuine finding.

Fixed to `detect-secrets-hook`, then **verified by planting a fake AWS key and
confirming the scan failed.** The rebuilt scans found a real CVE. A security
control nobody has watched fail is not a control.

### 7.6 A duplicate hosted zone, and an SPF record that would have broken mail

The first apply created a *second* hosted zone for a domain that already had one.
The nameservers reported back were the wrong set — delegation still pointed at the
original zone, so nothing Terraform wrote was authoritative.

Worse: `v=spf1 -all` was unconditional in that first version. Harmless in a zone
Terraform had just created; **destructive in an adopted zone belonging to a domain
that sends mail.** Fixed by §4.4 (adopt, don't create) and §4.5
(`manage_email_dns` defaults off).

### 7.7 `-var` beats `-var-file`

Terraform resolves a command-line `-var` over any value in a `-var-file`. A
variable set in both places silently takes the workflow's value. `ci.tfvars`
carries a header saying so, and the workflow passes only the four values that
are genuinely per-account or sensitive — `aws_region`, `domain_name`,
`alert_email`, `existing_oidc_provider_arn`.

### 7.8 A `for_each` keyed on a value that does not exist until apply

Enabling the custom domain failed the plan with `Invalid for_each argument`. The
ACM validation records were keyed on `dvo.resource_record_name`, which is
`(known after apply)` on a first apply. `for_each` tolerates unknown *values* but
not unknown *keys* — it cannot plan a number of instances it cannot count.

Keyed on `domain_name` instead, which the provider fills from configuration and is
therefore known at plan time, with `trimprefix(…, "*.")` so a wildcard SAN
collapses onto the parent domain it shares a validation record with.

### 7.9 A pull request was merged while its own plan was red

The change in §7.8 shipped to `main` because its PR was merged without the plan
check having passed — so `main` briefly held a configuration that could not plan.
The gate existed and was not honoured.

**This is the strongest argument in this document for a constitution.** Every other
failure here was a knowledge gap, findable by reading a log. This one was a
process failure, and no amount of care catches it reliably. It wants a branch
protection rule.

## 8. Follow-ups

| # | Item | Blocks |
| --- | --- | --- |
| 1 | Fill the `TODO:` markers in `src/data/` | OQ-1 — the site's substance |
| 2 | ~~Confirm the SNS email subscription~~ — done | OQ-2 |
| 3 | Enable Cost Explorer in the Billing console | OQ-3 — FR-12 shows real numbers ~24h later |
| 4 | Deployment branch policy on `production`, both repos | OQ-4 — restores the branch restriction §4.9 removed |
| 5 | Require the checks to pass before merge | §7.9 |
| 6 | Decide whether the automation repo goes public | OQ-5 — the credibility argument depends on it |
| 7 | Write the constitution these documents keep pointing at | all of the above |

Items 4 and 5 have no representation in this repository — they are GitHub
settings. The expected configuration is written down in
[`CLAUDE.md`](../../CLAUDE.md) under "Repository settings that cannot live in this
repo", so that a drift between intent and reality is at least *findable*. The
workflow change that makes item 5 safe (removing `paths` filters from
`pull_request` triggers, so a required check cannot be silently skipped) is in
`terraform.yml` and `python.yml`.
