"""Scheduled collector that snapshots what this site actually costs to run.

Cost Explorer bills $0.01 per API request, so this runs once a day rather than
per page view: two requests daily is roughly $0.60/month, and the snapshot is
cached in DynamoDB for the API to serve for free.

Cost Explorer is a global service with a us-east-1 endpoint, which is why the
client is pinned to that region regardless of where the function runs.
"""

from __future__ import annotations

import calendar
import logging
import os
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

TABLE_NAME = os.environ.get("TABLE_NAME", "")

# Optional cost-allocation tag filter, e.g. "Project=personal-site". Leave unset
# to report whole-account spend. Note that user-defined cost allocation tags must
# be activated in the Billing console and take ~24h to appear in Cost Explorer.
COST_TAG_KEY = os.environ.get("COST_TAG_KEY", "")
COST_TAG_VALUE = os.environ.get("COST_TAG_VALUE", "")

TOP_SERVICES = int(os.environ.get("TOP_SERVICES", "8"))

_table = None
_ce = None


def _get_table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(TABLE_NAME)
    return _table


def _get_ce():
    global _ce
    if _ce is None:
        _ce = boto3.client("ce", region_name="us-east-1")
    return _ce


def _month_bounds(today: date) -> tuple[str, str, str]:
    """Return (month_start, tomorrow, next_month_start) as ISO dates.

    Cost Explorer treats End as exclusive, so month-to-date needs tomorrow's
    date to include everything billed so far today.
    """
    month_start = today.replace(day=1)
    tomorrow = today + timedelta(days=1)

    last_day = calendar.monthrange(today.year, today.month)[1]
    next_month_start = today.replace(day=last_day) + timedelta(days=1)

    return month_start.isoformat(), tomorrow.isoformat(), next_month_start.isoformat()


def _tag_filter() -> dict | None:
    if not COST_TAG_KEY or not COST_TAG_VALUE:
        return None
    return {"Tags": {"Key": COST_TAG_KEY, "Values": [COST_TAG_VALUE]}}


def fetch_month_to_date(today: date) -> dict:
    """Month-to-date unblended cost, broken down by service."""
    month_start, tomorrow, _ = _month_bounds(today)

    kwargs: dict[str, Any] = {
        "TimePeriod": {"Start": month_start, "End": tomorrow},
        "Granularity": "MONTHLY",
        "Metrics": ["UnblendedCost"],
        "GroupBy": [{"Type": "DIMENSION", "Key": "SERVICE"}],
    }

    cost_filter = _tag_filter()
    if cost_filter:
        kwargs["Filter"] = cost_filter

    response = _get_ce().get_cost_and_usage(**kwargs)

    total = Decimal("0")
    services: list[dict] = []
    currency = "USD"

    for period in response.get("ResultsByTime", []):
        for group in period.get("Groups", []):
            amount_raw = group["Metrics"]["UnblendedCost"]["Amount"]
            currency = group["Metrics"]["UnblendedCost"].get("Unit", currency)
            amount = Decimal(amount_raw)

            if amount <= 0:
                continue

            total += amount
            services.append(
                {
                    "service": group["Keys"][0],
                    "amount": amount.quantize(Decimal("0.01")),
                }
            )

    services.sort(key=lambda s: s["amount"], reverse=True)

    return {
        "month": month_start[:7],
        "currency": currency,
        "month_to_date": total.quantize(Decimal("0.01")),
        "by_service": services[:TOP_SERVICES],
    }


def fetch_forecast(today: date) -> Decimal | None:
    """Projected spend through the end of the month.

    Cost Explorer refuses to forecast when it has too little history, and the
    request window is empty on the last day of the month. Neither is an error
    worth failing the run over -- the panel just omits the forecast.
    """
    _, tomorrow, next_month_start = _month_bounds(today)

    if tomorrow >= next_month_start:
        return None

    kwargs: dict[str, Any] = {
        "TimePeriod": {"Start": tomorrow, "End": next_month_start},
        "Metric": "UNBLENDED_COST",
        "Granularity": "MONTHLY",
    }

    cost_filter = _tag_filter()
    if cost_filter:
        kwargs["Filter"] = cost_filter

    try:
        response = _get_ce().get_cost_forecast(**kwargs)
        return Decimal(response["Total"]["Amount"]).quantize(Decimal("0.01"))
    except ClientError as exc:
        LOG.warning("forecast unavailable: %s", exc.response["Error"]["Code"])
        return None


def handler(event: dict, context: Any) -> dict:  # noqa: ARG001 - Lambda signature
    today = datetime.now(UTC).date()

    snapshot = fetch_month_to_date(today)
    forecast = fetch_forecast(today)

    # month_to_date is spend so far; the forecast covers the remaining days, so
    # the projected month-end total is the sum of the two.
    projected = snapshot["month_to_date"] + forecast if forecast is not None else None

    item = {
        "pk": "COST",
        "sk": "LATEST",
        "month": snapshot["month"],
        "currency": snapshot["currency"],
        "month_to_date": snapshot["month_to_date"],
        "forecast_month_end": projected,
        "by_service": snapshot["by_service"],
        "collected_at": datetime.now(UTC).replace(microsecond=0).isoformat(),
    }

    _get_table().put_item(Item=item)

    LOG.info(
        "collected cost: %s %s MTD across %d services",
        item["month_to_date"],
        item["currency"],
        len(snapshot["by_service"]),
    )

    return {"month_to_date": str(item["month_to_date"]), "month": item["month"]}
