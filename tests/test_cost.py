"""Tests for the daily Cost Explorer collector."""

from __future__ import annotations

from datetime import UTC, date, datetime
from decimal import Decimal

import pytest
from botocore.exceptions import ClientError


class FakeCostExplorer:
    """Records the kwargs it was called with so assertions can inspect them."""

    def __init__(self, groups=None, forecast="1.20", forecast_error=None):
        self.groups = groups if groups is not None else []
        self.forecast = forecast
        self.forecast_error = forecast_error
        self.usage_calls: list[dict] = []
        self.forecast_calls: list[dict] = []

    def get_cost_and_usage(self, **kwargs):
        self.usage_calls.append(kwargs)
        return {"ResultsByTime": [{"Groups": self.groups}]}

    def get_cost_forecast(self, **kwargs):
        self.forecast_calls.append(kwargs)
        if self.forecast_error:
            raise self.forecast_error
        return {"Total": {"Amount": self.forecast, "Unit": "USD"}}


def group(service: str, amount: str) -> dict:
    return {
        "Keys": [service],
        "Metrics": {"UnblendedCost": {"Amount": amount, "Unit": "USD"}},
    }


@pytest.fixture
def ce(cost, monkeypatch):
    fake = FakeCostExplorer()
    monkeypatch.setattr(cost, "_get_ce", lambda: fake)
    return fake


class TestMonthBounds:
    def test_end_is_exclusive_so_today_is_included(self, cost):
        start, end, _ = cost._month_bounds(date(2026, 7, 29))

        assert start == "2026-07-01"
        assert end == "2026-07-30"

    def test_next_month_start_rolls_the_year(self, cost):
        _, _, next_month = cost._month_bounds(date(2026, 12, 15))

        assert next_month == "2027-01-01"

    def test_february_in_a_leap_year(self, cost):
        _, _, next_month = cost._month_bounds(date(2028, 2, 3))

        assert next_month == "2028-03-01"


class TestMonthToDate:
    def test_sums_and_sorts_services_by_spend(self, cost, ce):
        ce.groups = [
            group("AWS Lambda", "0.01"),
            group("Amazon Route 53", "0.50"),
            group("Amazon CloudFront", "0.12"),
        ]

        result = cost.fetch_month_to_date(date(2026, 7, 29))

        assert result["month_to_date"] == Decimal("0.63")
        assert [s["service"] for s in result["by_service"]] == [
            "Amazon Route 53",
            "Amazon CloudFront",
            "AWS Lambda",
        ]

    def test_zero_and_negative_lines_are_dropped(self, cost, ce):
        ce.groups = [
            group("Amazon Route 53", "0.50"),
            group("AWS Free Tier Credit", "-0.50"),
            group("Amazon S3", "0"),
        ]

        result = cost.fetch_month_to_date(date(2026, 7, 29))

        assert [s["service"] for s in result["by_service"]] == ["Amazon Route 53"]
        assert result["month_to_date"] == Decimal("0.50")

    def test_service_list_is_truncated(self, cost, ce, monkeypatch):
        monkeypatch.setattr(cost, "TOP_SERVICES", 2)
        ce.groups = [group(f"Service {i}", f"0.0{i}") for i in range(1, 6)]

        result = cost.fetch_month_to_date(date(2026, 7, 29))

        assert len(result["by_service"]) == 2

    def test_month_label_is_year_month(self, cost, ce):
        assert cost.fetch_month_to_date(date(2026, 7, 29))["month"] == "2026-07"

    def test_no_filter_is_sent_when_no_tag_is_configured(self, cost, ce):
        cost.fetch_month_to_date(date(2026, 7, 29))

        assert "Filter" not in ce.usage_calls[0]

    def test_tag_filter_is_applied_when_configured(self, cost, ce, monkeypatch):
        monkeypatch.setattr(cost, "COST_TAG_KEY", "Project")
        monkeypatch.setattr(cost, "COST_TAG_VALUE", "personal-site")

        cost.fetch_month_to_date(date(2026, 7, 29))

        assert ce.usage_calls[0]["Filter"] == {
            "Tags": {"Key": "Project", "Values": ["personal-site"]}
        }


class TestForecast:
    def test_returns_the_projected_remainder(self, cost, ce):
        ce.forecast = "1.20"

        assert cost.fetch_forecast(date(2026, 7, 29)) == Decimal("1.20")

    def test_last_day_of_month_has_nothing_left_to_forecast(self, cost, ce):
        assert cost.fetch_forecast(date(2026, 7, 31)) is None
        assert ce.forecast_calls == []

    def test_insufficient_history_is_not_fatal(self, cost, ce):
        ce.forecast_error = ClientError(
            {"Error": {"Code": "DataUnavailableException"}}, "GetCostForecast"
        )

        assert cost.fetch_forecast(date(2026, 7, 29)) is None


class TestHandler:
    @pytest.fixture(autouse=True)
    def frozen_clock(self, cost, monkeypatch):
        """Pin the clock to mid-month for every test in this class.

        handler() reads its reporting date from datetime.now(UTC), so without
        this these tests depend on the day they happen to run. On the last day
        of a month fetch_forecast correctly returns None -- the forecast window
        is empty, which TestForecast already asserts for 2026-07-31 -- and every
        assertion here about a forecast then fails. The code is right and the
        calendar moved, which is the worst kind of red: it appears on an
        unrelated pull request and implicates an innocent diff.
        """

        class _Frozen(datetime):
            @classmethod
            def now(cls, tz=None):
                return datetime(2026, 7, 29, 12, 0, tzinfo=tz or UTC)

        monkeypatch.setattr(cost, "datetime", _Frozen)

    def test_writes_a_snapshot(self, cost, ce, table):
        ce.groups = [group("Amazon Route 53", "0.50")]
        ce.forecast = "0.70"

        cost.handler({}, None)

        item = table.get_item(Key={"pk": "COST", "sk": "LATEST"})["Item"]

        assert item["month_to_date"] == Decimal("0.50")
        # Projected month-end is spend so far plus the forecast remainder.
        assert item["forecast_month_end"] == Decimal("1.20")
        assert item["collected_at"]

    def test_snapshot_survives_a_missing_forecast(self, cost, ce, table):
        ce.groups = [group("Amazon Route 53", "0.50")]
        ce.forecast_error = ClientError(
            {"Error": {"Code": "DataUnavailableException"}}, "GetCostForecast"
        )

        cost.handler({}, None)

        item = table.get_item(Key={"pk": "COST", "sk": "LATEST"})["Item"]

        assert item["month_to_date"] == Decimal("0.50")
        assert item["forecast_month_end"] is None

    def test_makes_exactly_two_billable_requests(self, cost, ce):
        cost.handler({}, None)

        assert len(ce.usage_calls) == 1
        assert len(ce.forecast_calls) == 1

    def test_keeps_a_dated_snapshot_alongside_the_current_one(self, cost, ce, table):
        ce.groups = [group("Amazon Route 53", "0.50")]

        cost.handler({}, None)

        dated = [i for i in table.scan()["Items"] if i["sk"].startswith("DAY#")]

        assert len(dated) == 1
        assert dated[0]["month_to_date"] == Decimal("0.50")
        # Without a TTL these would accumulate forever.
        assert dated[0]["expires_at"] > 0

    def test_rerunning_on_the_same_day_overwrites_rather_than_duplicates(self, cost, ce, table):
        ce.groups = [group("Amazon Route 53", "0.50")]

        cost.handler({}, None)
        cost.handler({}, None)

        dated = [i for i in table.scan()["Items"] if i["sk"].startswith("DAY#")]

        assert len(dated) == 1
