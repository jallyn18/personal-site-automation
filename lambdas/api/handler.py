"""Read-mostly JSON API served at /api/* through CloudFront.

Invoked via a Lambda Function URL that only CloudFront can reach (IAM auth +
Origin Access Control), so there is no public endpoint to rate-limit separately
and no CORS to configure -- the browser sees same-origin requests.

Routes:
    GET  /api/health   liveness, no data access
    GET  /api/visits   current visit count
    POST /api/visits   record a visit (deduped per visitor per day), return count
    GET  /api/status   uptime and latency, populated by the uptime prober
    GET  /api/cost     month-to-date AWS spend, populated by the cost collector
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

TABLE_NAME = os.environ.get("TABLE_NAME", "")
DEDUPE_SALT = os.environ.get("DEDUPE_SALT", "")
DEDUPE_TTL_HOURS = int(os.environ.get("DEDUPE_TTL_HOURS", "48"))

# Browsers may re-request these; a short edge/browser cache keeps the counter
# lively without hammering DynamoDB from a popular page.
CACHE_SHORT = "public, max-age=30"
CACHE_NONE = "no-store"

_table = None


def _get_table():
    """Lazily build the table resource so imports stay cheap and tests can patch."""
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(TABLE_NAME)
    return _table


class _DecimalEncoder(json.JSONEncoder):
    """DynamoDB hands back Decimal; JSON does not know what to do with it."""

    def default(self, o: Any) -> Any:
        if isinstance(o, Decimal):
            return int(o) if o == o.to_integral_value() else float(o)
        return super().default(o)


def _response(status: int, body: dict, cache: str = CACHE_NONE) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json",
            "cache-control": cache,
        },
        "body": json.dumps(body, cls=_DecimalEncoder),
    }


def _today() -> str:
    return time.strftime("%Y-%m-%d", time.gmtime())


def _visitor_fingerprint(event: dict) -> str:
    """Hash the visitor's IP and user agent -- never store either in the clear.

    The salt is generated at deploy time and lives only in the function's
    environment, so the digests are not reversible with a rainbow table and are
    not correlatable across deployments. Truncated to 128 bits, which is plenty
    for a same-day dedupe key.
    """
    http = event.get("requestContext", {}).get("http", {})
    source_ip = http.get("sourceIp", "unknown")
    user_agent = event.get("headers", {}).get("user-agent", "unknown")

    material = f"{DEDUPE_SALT}|{source_ip}|{user_agent}|{_today()}"
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:32]


def _already_counted(fingerprint: str) -> bool:
    """Claim the fingerprint for today. True means this visitor was already seen.

    The conditional put is the whole mechanism: whoever writes first wins, and
    concurrent duplicate requests lose the race rather than double-counting.
    """
    expires_at = int(time.time()) + DEDUPE_TTL_HOURS * 3600

    try:
        _get_table().put_item(
            Item={
                "pk": f"DEDUPE#{fingerprint}",
                "sk": _today(),
                "expires_at": expires_at,
            },
            ConditionExpression="attribute_not_exists(pk)",
        )
        return False
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return True
        raise


def _read_visit_count() -> int:
    item = (
        _get_table()
        .get_item(
            Key={"pk": "VISITS", "sk": "TOTAL"},
            ConsistentRead=False,
        )
        .get("Item")
    )

    if not item:
        return 0
    return int(item.get("count", 0))


def _increment_visits() -> int:
    """Atomically bump the total and today's bucket, returning the new total."""
    result = _get_table().update_item(
        Key={"pk": "VISITS", "sk": "TOTAL"},
        UpdateExpression="ADD #c :one",
        ExpressionAttributeNames={"#c": "count"},
        ExpressionAttributeValues={":one": 1},
        ReturnValues="UPDATED_NEW",
    )

    # Best-effort daily breakdown; a failure here must not cost us the visit.
    try:
        _get_table().update_item(
            Key={"pk": "VISITS", "sk": f"DAY#{_today()}"},
            UpdateExpression="ADD #c :one",
            ExpressionAttributeNames={"#c": "count"},
            ExpressionAttributeValues={":one": 1},
        )
    except ClientError:
        LOG.warning("daily visit bucket update failed", exc_info=True)

    return int(result["Attributes"]["count"])


def _get_uptime() -> dict:
    item = _get_table().get_item(Key={"pk": "UPTIME", "sk": "AGGREGATE"}).get("Item")

    if not item:
        return {"available": False, "reason": "no probe data yet"}

    total = int(item.get("total_checks", 0))
    failed = int(item.get("failed_checks", 0))
    latency_sum = int(item.get("total_latency_ms", 0))

    return {
        "available": True,
        "last_status": item.get("last_status", "unknown"),
        "last_checked_at": item.get("last_checked_at"),
        "last_latency_ms": int(item.get("last_latency_ms", 0)),
        "total_checks": total,
        "failed_checks": failed,
        "availability_pct": round((total - failed) / total * 100, 4) if total else None,
        "avg_latency_ms": round(latency_sum / total) if total else None,
        "window_started_at": item.get("window_started_at"),
    }


def _get_cost() -> dict:
    item = _get_table().get_item(Key={"pk": "COST", "sk": "LATEST"}).get("Item")

    if not item:
        return {"available": False, "reason": "no cost data yet"}

    return {
        "available": True,
        "currency": item.get("currency", "USD"),
        "month": item.get("month"),
        "month_to_date": item.get("month_to_date"),
        "forecast_month_end": item.get("forecast_month_end"),
        "by_service": item.get("by_service", []),
        "collected_at": item.get("collected_at"),
    }


def handler(event: dict, context: Any) -> dict:  # noqa: ARG001 - Lambda signature
    http = event.get("requestContext", {}).get("http", {})
    method = http.get("method", "GET").upper()
    # The Function URL sees the full CloudFront path, /api/ prefix included.
    path = (event.get("rawPath") or http.get("path") or "/").rstrip("/") or "/"

    LOG.info("request", extra={"method": method, "path": path})

    try:
        if path == "/api/health":
            return _response(200, {"status": "ok"})

        if path == "/api/visits":
            if method == "POST":
                fingerprint = _visitor_fingerprint(event)
                if _already_counted(fingerprint):
                    return _response(200, {"count": _read_visit_count(), "counted": False})
                return _response(200, {"count": _increment_visits(), "counted": True})

            if method == "GET":
                return _response(200, {"count": _read_visit_count()}, CACHE_SHORT)

            return _response(405, {"error": "method not allowed"})

        if path == "/api/status" and method == "GET":
            return _response(200, _get_uptime(), CACHE_SHORT)

        if path == "/api/cost" and method == "GET":
            return _response(200, _get_cost(), CACHE_SHORT)

        return _response(404, {"error": "not found"})

    except ClientError:
        LOG.exception("aws call failed")
        return _response(503, {"error": "upstream unavailable"})
    except Exception:
        LOG.exception("unhandled error")
        return _response(500, {"error": "internal error"})
