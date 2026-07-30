# Spec 001 — Personal professional website

| | |
| --- | --- |
| **Status** | Implemented |
| **Written** | 2026-07-29, **after** the implementation |
| **Owner** | Jon Allyn (@jallyn18) |
| **Repos** | `personal-site-automation` (infrastructure, pipeline), `personal-site-gatsby` (site) |
| **Live** | https://jon-allyn.com |

> **This spec is retroactive.** It was reconstructed from the delivered system on
> the day the system went live — it did not drive the original build, and it does
> not pretend to. It exists so that the *next* change has something to be
> specified against, and so the reasoning behind what shipped is recoverable by
> someone who was not there.
>
> Where the original work made a decision this document could not have predicted,
> that is recorded in [`plan.md`](./plan.md) rather than smoothed over here.

---

## 1. Problem

A resume is a static PDF and a LinkedIn profile is a form someone else designed.
Neither one demonstrates the thing an automation engineer is actually hired for:
that they can take a system from nothing to running, in public, with the seams
visible.

The gap is not "I need a homepage." It is that the strongest available evidence of
competence — working infrastructure, a real pipeline, decisions with stated
tradeoffs — has nowhere to live where a hiring manager will encounter it.

## 2. Intent

Ship a personal website that *is* the work sample. Someone evaluating Jon should
be able to read the site, then read the repository that deploys the site, and find
the same engineering in both.

The site's credibility comes from being self-referential: it reports on its own
build, its own uptime, and its own running cost, from live data rather than from
claims in prose.

## 3. Users

| User | What they came for | What must not happen |
| --- | --- | --- |
| Hiring manager / recruiter | Fast read on seniority and scope. Probably on a phone, probably in under 90 seconds. | Buried headline; slow first paint; a wall of text |
| Engineer on an interview panel | Depth. Wants the repo, the tradeoffs, the parts that were hard. | Marketing voice with nothing underneath; a repo that contradicts the site |
| Peer / network contact | What Jon works on now, how to reach him. | Dead links; stale content |
| Jon | Somewhere to point people, editable in minutes. | Editing content requires touching infrastructure |

## 4. Functional requirements

Numbered so a change can cite what it satisfies or breaks.

### Content

- **FR-1** — The site presents professional history, projects, and skills sourced
  from plain data files (`src/data/*.js`), so content is editable without touching
  components or infrastructure.
- **FR-2** — The AI delivery model is the site's lead position, not a footnote.
  Jon currently leads a team producing 100% of its code with AI under
  spec-driven development; the site says so prominently and explains the method.
- **FR-3** — The AI content includes an explicit statement of what is *not* being
  claimed. An unqualified claim about AI reads as either naive or dishonest to the
  exact audience this site is for.
- **FR-4** — Content states nothing about Jon's career that Jon did not state.
  Unverified specifics are left as visible `TODO:` markers in the data files
  rather than plausibly invented.
- **FR-5** — Links to GitHub and LinkedIn are present and correct.
- **FR-6** — A `/pipeline/` page explains how the site is built and deployed, and
  names the commit currently being served.
- **FR-7** — A resume view exists as a page, readable and printable.
- **FR-8** — A 404 page exists and is styled consistently.

### Live self-reporting

- **FR-9** — **Build metadata panel.** The site displays the commit SHA, branch,
  workflow run, and build timestamp of the deploy currently being served, baked in
  at build time.
- **FR-10** — **Visitor counter.** The site displays a total visit count,
  incremented server-side, deduplicated so one visitor refreshing does not inflate
  it.
- **FR-11** — **Uptime panel.** The site displays availability measured by a probe
  that runs against the live site on a schedule, not a hardcoded "99.9%".
- **FR-12** — **Cost panel.** The site displays this project's actual
  month-to-date AWS spend and a month-end forecast, read from Cost Explorer.
- **FR-13** — Every panel degrades to a legible empty or stale state. A cold
  DynamoDB table, an unpopulated Cost Explorer, or a failed probe must render as
  "no data yet", never as a broken page or a fabricated number.

### API

- **FR-14** — Dynamic data is served from the same origin as the site under
  `/api/*`. No second hostname, therefore no CORS.
- **FR-15** — Endpoints: `GET /api/health`, `GET|POST /api/visits`,
  `GET /api/status`, `GET /api/cost`. Unknown paths return 404; wrong methods
  return 405.
- **FR-16** — The API returns JSON with explicit cache headers per endpoint, and
  never a stack trace. Upstream AWS failures surface as 503, unexpected errors as
  500.

## 5. Non-functional requirements

- **NFR-1 — Cost.** Low single-digit USD per month at portfolio traffic. A budget
  alarm enforces the ceiling rather than trusting an estimate.
- **NFR-2 — No public origins.** The S3 bucket and the compute behind `/api/*` are
  both unreachable except through CloudFront.
- **NFR-3 — No static cloud credentials.** Neither repository holds an AWS access
  key. All authentication is short-lived and federated.
- **NFR-4 — HTTPS only**, on the apex and `www`, with a valid certificate for both.
- **NFR-5 — The domain sends no mail, and is published as sending no mail.** This
  is a standing property, not a setting.
- **NFR-6 — Every deploy is verified against the live site.** A green pipeline that
  did not check is not evidence of a working deploy.
- **NFR-7 — Infrastructure drift is detected without being asked.**
- **NFR-8 — Content edits do not require an infrastructure change.** The site repo
  discovers its own deploy target at run time.
- **NFR-9 — Accessible and responsive.** Semantic markup, keyboard-navigable,
  legible on a phone.

## 6. Non-goals

Recorded because each was considered and declined. Absence here is a decision, not
an oversight.

- **No Ansible.** It is on Jon's skill list and it has no honest role in a static
  site on serverless AWS. Bolting it on to pad the stack would be visible as
  padding to anyone qualified to be impressed by it.
- **No CMS, no database-backed content.** Content is code. A CMS is operational
  surface bought with no return at this scale.
- **No blog.** An empty blog dated eight months ago is worse than no blog.
- **No analytics platform.** The visit counter is the entire appetite for tracking.
  No third-party scripts, no cookie banner, no visitor PII.
- **No contact form.** It requires mail infrastructure, which NFR-5 forbids
  outright. Contact is by the published links.
- **No user accounts, no authentication.** Nothing on the site is private.
- **No multi-region or DR.** A personal site being briefly unavailable is not an
  incident. Paying for a hot standby would be theatre.
- **No `terraform` executed from a workstation.** See CON-1.

## 7. Constraints

- **CON-1 — Terraform runs only in CI.** The operator cannot execute Terraform
  locally. Every apply, and every plan that matters, happens in GitHub Actions;
  the pipeline output is the only feedback channel. This shapes the whole delivery
  design — see `plan.md` §3.
- **CON-2 — `jon-allyn.com` already existed** with a Route53 hosted zone created at
  registration (`Z03449763V0AE74DQS39J`). The zone predates this stack and must
  outlive it.
- **CON-3 — One manual bootstrap step is unavoidable.** Terraform cannot create the
  credentials that permit Terraform to run. Something outside the pipeline must go
  first.
- **CON-4 — Cost Explorer must be enabled by hand** in the Billing console, and
  takes up to 24 hours to populate after enabling.
- **CON-5 — ACM certificates for CloudFront must live in `us-east-1`**, regardless
  of where anything else is deployed.

## 8. Acceptance criteria

Each is checkable, and most are checked automatically.

1. `https://jon-allyn.com` and `https://www.jon-allyn.com` both serve the site over
   valid TLS.
2. `http://` redirects to `https://`.
3. The S3 bucket returns 403 when addressed directly.
4. The Lambda Function URL returns 403 when called without a SigV4 signature.
5. `/pipeline/` names the commit that is actually deployed — **asserted by the
   deploy pipeline itself**, which fetches the live page and fails the run if the
   short SHA is absent.
6. All four live panels render, including with empty backing data.
7. `dig TXT jon-allyn.com` → `v=spf1 -all`; `dig MX jon-allyn.com` → `0 .`;
   `dig TXT _dmarc.jon-allyn.com` → `p=reject` with strict alignment.
8. A `terraform plan` on an unchanged repository reports no changes.
9. Neither repository contains an AWS access key — asserted by a secret scan that
   is verified to actually fail on a planted credential.
10. A month of operation stays under the budget threshold.

## 9. Open questions

Carried, not resolved.

- **OQ-1** — The `TODO:` markers in `src/data/` (role dates, earlier employers,
  project specifics) need Jon's input. Until then the site is honest but thin in
  places. *This is the largest outstanding item.*
- **OQ-2** — The SNS alert subscription requires a confirmation click in the email
  AWS sent. Until confirmed, alarms fire into nothing.
- **OQ-3** — Cost Explorer needs enabling (CON-4) before FR-12 shows real figures.
- **OQ-4** — The `production` GitHub environment has no deployment branch policy.
  Because an environment subject claim *replaces* the branch in the OIDC token,
  IAM alone no longer restricts applies to `main`. See `plan.md` §4.9.
- **OQ-5** — No decision on whether the automation repo should become public. The
  site's credibility argument depends on the repo being readable; it is currently
  private.
