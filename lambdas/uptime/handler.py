"""Scheduled prober that measures whether the site is actually reachable.

Runs from EventBridge every few minutes, fetches the public URL over the real
internet path (through CloudFront, not a bucket shortcut), and folds the result
into a rolling aggregate the API can read in one GetItem.

Individual probe records expire after a week; the aggregate is permanent.
"""

from __future__ import annotations

import logging
import os
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from typing import Any

import boto3

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

TABLE_NAME = os.environ.get("TABLE_NAME", "")
SITE_URL = os.environ.get("SITE_URL", "")
TIMEOUT_SECONDS = float(os.environ.get("TIMEOUT_SECONDS", "10"))
CHECK_TTL_DAYS = int(os.environ.get("CHECK_TTL_DAYS", "7"))
USER_AGENT = "personal-site-uptime-probe/1.0 (+https://github.com)"

_table = None


def _get_table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(TABLE_NAME)
    return _table


def _now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def probe(url: str) -> dict:
    """Fetch the URL once and report status plus wall-clock latency.

    Any non-2xx response, timeout, or DNS failure counts as down -- from a
    visitor's point of view there is no difference.
    """
    request = urllib.request.Request(
        url,
        method="GET",
        headers={"User-Agent": USER_AGENT},
    )

    started = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            response.read(1024)  # touch the body so we time a real transfer
            latency_ms = round((time.perf_counter() - started) * 1000)
            healthy = 200 <= response.status < 300
            return {
                "healthy": healthy,
                "status_code": response.status,
                "latency_ms": latency_ms,
            }
    except urllib.error.HTTPError as exc:
        return {
            "healthy": False,
            "status_code": exc.code,
            "latency_ms": round((time.perf_counter() - started) * 1000),
            "error": f"http {exc.code}",
        }
    except Exception as exc:  # noqa: BLE001 - timeouts, DNS, TLS all mean "down"
        return {
            "healthy": False,
            "status_code": 0,
            "latency_ms": round((time.perf_counter() - started) * 1000),
            "error": type(exc).__name__,
        }


def _record(result: dict) -> None:
    table = _get_table()
    now = _now_iso()
    expires_at = int(time.time()) + CHECK_TTL_DAYS * 86400

    table.put_item(
        Item={
            "pk": "UPTIME",
            "sk": f"CHECK#{now}",
            "healthy": result["healthy"],
            "status_code": result["status_code"],
            "latency_ms": result["latency_ms"],
            "error": result.get("error"),
            "expires_at": expires_at,
        }
    )

    # ADD creates the attribute at zero on first use, so no seeding required.
    table.update_item(
        Key={"pk": "UPTIME", "sk": "AGGREGATE"},
        UpdateExpression=(
            "ADD total_checks :one, failed_checks :failed, total_latency_ms :latency "
            "SET last_status = :status, last_checked_at = :now, "
            "last_latency_ms = :latency_now, "
            "window_started_at = if_not_exists(window_started_at, :now)"
        ),
        ExpressionAttributeValues={
            ":one": 1,
            ":failed": 0 if result["healthy"] else 1,
            ":latency": result["latency_ms"],
            ":latency_now": result["latency_ms"],
            ":status": "up" if result["healthy"] else "down",
            ":now": now,
        },
    )


def handler(event: dict, context: Any) -> dict:  # noqa: ARG001 - Lambda signature
    if not SITE_URL:
        raise RuntimeError("SITE_URL is not configured")

    result = probe(SITE_URL)
    _record(result)

    if result["healthy"]:
        LOG.info("probe ok: %sms", result["latency_ms"])
    else:
        # Logged at ERROR so the metric filter and alarm in monitoring.tf fire.
        LOG.error("probe failed: %s", result.get("error") or result["status_code"])

    return result
