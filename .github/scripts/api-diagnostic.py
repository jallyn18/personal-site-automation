#!/usr/bin/env python3
"""Read-only diagnostic for the /api/* 404.

Answers one question that cannot be answered from outside the account: when
CloudFront forwards /api/* to the Lambda function URL, what actually happens?

From the public side every failure mode collapses into the same response. The
distribution maps both 403 and 404 to /404.html, so a Function URL auth
rejection, a missing cache behaviour and a handler miss are indistinguishable
to a caller. This reads the live configuration and the function's log group
instead of inferring.

Everything printed goes through scrub(): the account id and the function URL's
subdomain are replaced before they can reach the log. This repository is
public, so its Actions logs are too.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

PROJECT = os.environ.get("PROJECT", "personal-site")
REGION = os.environ.get("AWS_REGION", "us-east-1")

# Populated as values are discovered; every print is filtered through these.
SECRETS: list[str] = []


def aws(*args: str) -> dict | list | None:
    """Run an AWS CLI command and parse its JSON. None on any failure."""
    proc = subprocess.run(
        ["aws", *args, "--output", "json"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        err = scrub(proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else "")
        print(f"    ! command failed: aws {' '.join(args[:2])} -> {err}")
        return None
    return json.loads(proc.stdout) if proc.stdout.strip() else None


def register_secret(value: str | None) -> None:
    if value and len(value) > 3 and value not in SECRETS:
        SECRETS.append(value)
        # Belt and braces. ::add-mask:: covers logs but not step summaries, and
        # only in the job that registers it -- scrub() is the real control.
        print(f"::add-mask::{value}")


def scrub(text: str) -> str:
    for secret in SECRETS:
        text = text.replace(secret, "<redacted>")
    return text


def show(label: str, value: object) -> None:
    print(f"    {label}: {scrub(str(value))}")


def main() -> int:
    identity = aws("sts", "get-caller-identity")
    if identity is None:
        print("Could not establish an AWS identity. Nothing else will work.")
        return 1
    register_secret(identity["Account"])

    print(f"== region {REGION}, project {PROJECT}\n")

    # --- the distribution ------------------------------------------------
    print("== CloudFront distribution")
    param = aws(
        "ssm", "get-parameter", "--name", f"/{PROJECT}/distribution_id",
        "--region", REGION,
    )
    if param is None:
        print("    ! no distribution id in SSM; cannot continue")
        return 1
    dist_id = param["Parameter"]["Value"]
    show("id", dist_id)

    config = aws("cloudfront", "get-distribution-config", "--id", dist_id)
    if config is None:
        return 1
    dc = config["DistributionConfig"]

    show("enabled", dc.get("Enabled"))

    dist = aws("cloudfront", "get-distribution", "--id", dist_id)
    if dist:
        show("status", dist["Distribution"].get("Status"))

    # --- origins ---------------------------------------------------------
    print("\n== origins")
    lambda_origin_domain = None
    for origin in dc.get("Origins", {}).get("Items", []):
        domain = origin.get("DomainName", "")
        if ".lambda-url." in domain:
            lambda_origin_domain = domain
            # The URL id is the only unguessable part of the endpoint.
            register_secret(domain.split(".")[0])
        print(f"  - id={origin.get('Id')}")
        show("domain", domain)
        show("originAccessControlId", origin.get("OriginAccessControlId") or "(none)")
        custom = origin.get("CustomOriginConfig")
        if custom:
            show("originProtocolPolicy", custom.get("OriginProtocolPolicy"))

    # --- cache behaviours -------------------------------------------------
    print("\n== cache behaviours (in match order)")
    behaviours = dc.get("CacheBehaviors", {}).get("Items", []) or []
    if not behaviours:
        print("  ! NO ordered cache behaviours -- /api/* would fall through to default")
    for b in behaviours:
        print(f"  - pathPattern={b.get('PathPattern')}")
        show("targetOriginId", b.get("TargetOriginId"))
        show("allowedMethods", b.get("AllowedMethods", {}).get("Items"))
        show("cachePolicyId", b.get("CachePolicyId"))
        show("originRequestPolicyId", b.get("OriginRequestPolicyId") or "(none)")
        show("responseHeadersPolicyId", b.get("ResponseHeadersPolicyId") or "(none)")
        show("functionAssociations",
             b.get("FunctionAssociations", {}).get("Quantity", 0))

    default = dc.get("DefaultCacheBehavior", {})
    print("  - (default)")
    show("targetOriginId", default.get("TargetOriginId"))
    show("functionAssociations",
         default.get("FunctionAssociations", {}).get("Quantity", 0))

    print("\n== custom error responses (these apply to EVERY behaviour)")
    for e in dc.get("CustomErrorResponses", {}).get("Items", []) or []:
        print(
            f"  - origin {e.get('ErrorCode')} -> viewer {e.get('ResponseCode')} "
            f"{e.get('ResponsePagePath')}  (ttl {e.get('ErrorCachingMinTTL')})"
        )

    # --- origin access controls -------------------------------------------
    print("\n== origin access controls")
    oacs = aws("cloudfront", "list-origin-access-controls")
    if oacs:
        for item in oacs.get("OriginAccessControlList", {}).get("Items", []) or []:
            print(f"  - {item.get('Name')}")
            show("id", item.get("Id"))
            show("originType", item.get("OriginAccessControlOriginType"))
            show("signingBehavior", item.get("SigningBehavior"))
            show("signingProtocol", item.get("SigningProtocol"))

    # --- the function URL and its policy ----------------------------------
    fn = f"{PROJECT}-api"
    print(f"\n== lambda {fn}")
    url_config = aws(
        "lambda", "get-function-url-config", "--function-name", fn, "--region", REGION
    )
    if url_config:
        show("authType", url_config.get("AuthType"))
        show("functionUrl", url_config.get("FunctionUrl"))
        if lambda_origin_domain:
            configured = url_config.get("FunctionUrl", "").replace("https://", "").rstrip("/")
            match = configured == lambda_origin_domain
            show("origin domain matches function url", match)
            if not match:
                print("    ! the distribution points at a DIFFERENT function url")

    print(f"\n== resource policy on {fn}")
    policy = aws("lambda", "get-policy", "--function-name", fn, "--region", REGION)
    if policy is None:
        print("    ! NO resource policy at all -- CloudFront cannot invoke this function")
    else:
        doc = json.loads(policy["Policy"])
        for stmt in doc.get("Statement", []):
            print(f"  - sid={stmt.get('Sid')}")
            show("effect", stmt.get("Effect"))
            show("principal", stmt.get("Principal"))
            show("action", stmt.get("Action"))
            show("conditions", stmt.get("Condition"))

    # --- has it ever run? --------------------------------------------------
    # This is the decisive one. Zero invocations means the request is being
    # rejected before it reaches the function -- i.e. at the Function URL auth
    # layer. Invocations present means the handler is running and the 404 is
    # coming from the routing inside it.
    log_group = f"/aws/lambda/{fn}"
    print(f"\n== invocation history ({log_group})")
    streams = aws(
        "logs", "describe-log-streams",
        "--log-group-name", log_group,
        "--order-by", "LastEventTime", "--descending",
        "--max-items", "5",
        "--region", REGION,
    )
    if streams is None:
        print("    ! log group missing or unreadable")
    else:
        items = streams.get("logStreams", []) or []
        show("log streams", len(items))
        if not items:
            print("    => the function has NEVER been invoked.")
            print("       CloudFront is not getting past the Function URL auth layer.")
        for s in items:
            show("stream lastEvent", s.get("lastEventTimestamp"))

        events = aws(
            "logs", "filter-log-events",
            "--log-group-name", log_group,
            "--max-items", "25",
            "--region", REGION,
        )
        if events:
            for e in events.get("events", []) or []:
                print(f"    | {scrub(e.get('message', '').rstrip())}")

    print("\n== done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
