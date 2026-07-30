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
    show("aliases", dc.get("Aliases", {}).get("Items") or "(none)")

    dist_domain = None
    dist = aws("cloudfront", "get-distribution", "--id", dist_id)
    if dist:
        show("status", dist["Distribution"].get("Status"))
        dist_domain = dist["Distribution"].get("DomainName")
        show("domainName", dist_domain)

    # Is this actually the distribution the domain resolves to? A second,
    # orphaned distribution owning the alias would explain everything while
    # leaving the Terraform-managed one looking perfect.
    print("\n== every distribution in the account")
    all_dists = aws("cloudfront", "list-distributions")
    if all_dists:
        for item in all_dists.get("DistributionList", {}).get("Items", []) or []:
            marker = "  <- the one in SSM" if item.get("Id") == dist_id else ""
            print(f"  - id={item.get('Id')}{marker}")
            show("aliases", item.get("Aliases", {}).get("Items") or "(none)")
            show("status/enabled", f"{item.get('Status')}/{item.get('Enabled')}")

    # And what does the zone actually point at?
    print("\n== route53 alias target")
    zone = os.environ.get("ROUTE53_ZONE_ID", "")
    if zone:
        records = aws(
            "route53", "list-resource-record-sets", "--hosted-zone-id", zone,
            "--max-items", "40",
        )
        if records:
            for rr in records.get("ResourceRecordSets", []) or []:
                if rr.get("Type") not in ("A", "AAAA"):
                    continue
                target = (rr.get("AliasTarget") or {}).get("DNSName", "")
                print(f"  - {rr.get('Name')} {rr.get('Type')} -> {scrub(target)}")
                if dist_domain and target:
                    matches = target.rstrip(".").lower() == dist_domain.rstrip(".").lower()
                    show("points at the SSM distribution", matches)

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

    # --- is the handler itself healthy? -----------------------------------
    # Invoking the function directly bypasses the Function URL and its auth,
    # so this separates "the handler is broken" from "nothing can reach it".
    print("\n== direct handler invoke (bypasses the function URL)")
    event = json.dumps({
        "rawPath": "/api/health",
        "requestContext": {"http": {"method": "GET", "path": "/api/health"}},
        "headers": {},
    })
    proc = subprocess.run(
        ["aws", "lambda", "invoke",
         "--function-name", fn,
         "--payload", event,
         "--cli-binary-format", "raw-in-base64-out",
         "--region", REGION,
         "/tmp/handler-out.json"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print(f"    ! invoke failed: {scrub(proc.stderr.strip())}")
    else:
        try:
            with open("/tmp/handler-out.json") as fh:
                print(f"    response: {scrub(fh.read().strip())[:400]}")
        except OSError as exc:
            print(f"    ! could not read response: {exc}")

    # --- does the function URL accept a correctly signed caller? -----------
    # If a SigV4 request from this role succeeds, the URL and its auth layer
    # work, and the problem is specific to CloudFront's signed requests.
    print("\n== signed request straight to the function URL")
    if url_config:
        try:
            import boto3
            import urllib.request
            from botocore.auth import SigV4Auth
            from botocore.awsrequest import AWSRequest

            url = url_config["FunctionUrl"].rstrip("/") + "/api/health"
            creds = boto3.Session().get_credentials().get_frozen_credentials()
            req = AWSRequest(method="GET", url=url)
            SigV4Auth(creds, "lambda", REGION).add_auth(req)
            signed = urllib.request.Request(
                url, headers=dict(req.headers), method="GET"
            )
            with urllib.request.urlopen(signed, timeout=20) as resp:  # noqa: S310
                show("status", resp.status)
                show("body", resp.read().decode()[:200])
        except Exception as exc:  # noqa: BLE001 - any failure is the datum
            show("failed", f"{type(exc).__name__}: {exc}")

    # --- did either probe produce a log stream? ---------------------------
    print("\n== invocation history again (after the probes)")
    streams = aws(
        "logs", "describe-log-streams",
        "--log-group-name", log_group,
        "--order-by", "LastEventTime", "--descending",
        "--max-items", "5",
        "--region", REGION,
    )
    if streams is not None:
        show("log streams", len(streams.get("logStreams", []) or []))

    print("\n== done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
