"""Tests for the /api/* handler."""

from __future__ import annotations

import json
from decimal import Decimal

from conftest import make_event


def body(response: dict) -> dict:
    return json.loads(response["body"])


class TestRouting:
    def test_health_needs_no_data(self, api):
        response = api.handler(make_event(path="/api/health"), None)

        assert response["statusCode"] == 200
        assert body(response) == {"status": "ok"}

    def test_unknown_path_is_404(self, api):
        response = api.handler(make_event(path="/api/nope"), None)

        assert response["statusCode"] == 404

    def test_trailing_slash_matches_the_same_route(self, api):
        response = api.handler(make_event(path="/api/health/"), None)

        assert response["statusCode"] == 200

    def test_unsupported_method_on_visits_is_405(self, api):
        response = api.handler(make_event(method="DELETE", path="/api/visits"), None)

        assert response["statusCode"] == 405

    def test_every_response_is_json(self, api):
        response = api.handler(make_event(path="/api/health"), None)

        assert response["headers"]["content-type"] == "application/json"


class TestVisits:
    def test_count_starts_at_zero(self, api):
        response = api.handler(make_event(path="/api/visits"), None)

        assert response["statusCode"] == 200
        assert body(response)["count"] == 0

    def test_post_increments(self, api):
        response = api.handler(make_event(method="POST", path="/api/visits"), None)

        assert body(response) == {"count": 1, "counted": True}

    def test_same_visitor_is_only_counted_once_per_day(self, api):
        event = make_event(method="POST", path="/api/visits")

        first = body(api.handler(event, None))
        second = body(api.handler(event, None))

        assert first == {"count": 1, "counted": True}
        assert second == {"count": 1, "counted": False}

    def test_distinct_visitors_are_counted_separately(self, api):
        api.handler(make_event(method="POST", path="/api/visits", source_ip="203.0.113.7"), None)
        response = api.handler(
            make_event(method="POST", path="/api/visits", source_ip="198.51.100.4"), None
        )

        assert body(response) == {"count": 2, "counted": True}

    def test_user_agent_is_part_of_the_fingerprint(self, api):
        api.handler(make_event(method="POST", path="/api/visits", user_agent="firefox"), None)
        response = api.handler(
            make_event(method="POST", path="/api/visits", user_agent="chrome"), None
        )

        assert body(response)["count"] == 2

    def test_get_reflects_prior_posts(self, api):
        api.handler(make_event(method="POST", path="/api/visits"), None)

        response = api.handler(make_event(path="/api/visits"), None)

        assert body(response)["count"] == 1

    def test_a_daily_bucket_is_written(self, api, table):
        api.handler(make_event(method="POST", path="/api/visits"), None)

        items = table.scan()["Items"]
        daily = [i for i in items if i["sk"].startswith("DAY#")]

        assert len(daily) == 1
        assert daily[0]["count"] == 1

    def test_fingerprint_does_not_store_the_raw_ip(self, api, table):
        api.handler(make_event(method="POST", path="/api/visits", source_ip="203.0.113.7"), None)

        dedupe = [i for i in table.scan()["Items"] if i["pk"].startswith("DEDUPE#")]

        assert len(dedupe) == 1
        assert "203.0.113.7" not in json.dumps(dedupe[0], default=str)

    def test_dedupe_rows_carry_a_ttl(self, api, table):
        api.handler(make_event(method="POST", path="/api/visits"), None)

        dedupe = [i for i in table.scan()["Items"] if i["pk"].startswith("DEDUPE#")]

        assert dedupe[0]["expires_at"] > 0

    def test_salt_changes_the_fingerprint(self, api, monkeypatch):
        event = make_event(method="POST", path="/api/visits")
        baseline = api._visitor_fingerprint(event)

        monkeypatch.setattr(api, "DEDUPE_SALT", "a-different-salt")

        assert api._visitor_fingerprint(event) != baseline


class TestStatus:
    def test_reports_unavailable_before_the_first_probe(self, api):
        response = api.handler(make_event(path="/api/status"), None)

        assert body(response)["available"] is False

    def test_computes_availability_and_average_latency(self, api, table):
        table.put_item(
            Item={
                "pk": "UPTIME",
                "sk": "AGGREGATE",
                "total_checks": 100,
                "failed_checks": 1,
                "total_latency_ms": 5000,
                "last_status": "up",
                "last_checked_at": "2026-07-29T00:00:00+00:00",
                "last_latency_ms": 42,
                "window_started_at": "2026-07-01T00:00:00+00:00",
            }
        )

        payload = body(api.handler(make_event(path="/api/status"), None))

        assert payload["availability_pct"] == 99.0
        assert payload["avg_latency_ms"] == 50
        assert payload["last_status"] == "up"

    def test_no_checks_yields_null_rates_rather_than_dividing_by_zero(self, api, table):
        table.put_item(
            Item={
                "pk": "UPTIME",
                "sk": "AGGREGATE",
                "total_checks": 0,
                "failed_checks": 0,
                "total_latency_ms": 0,
            }
        )

        payload = body(api.handler(make_event(path="/api/status"), None))

        assert payload["availability_pct"] is None
        assert payload["avg_latency_ms"] is None


class TestCost:
    def test_reports_unavailable_before_the_first_collection(self, api):
        response = api.handler(make_event(path="/api/cost"), None)

        assert body(response)["available"] is False

    def test_serialises_decimals_as_numbers(self, api, table):
        table.put_item(
            Item={
                "pk": "COST",
                "sk": "LATEST",
                "month": "2026-07",
                "currency": "USD",
                "month_to_date": Decimal("1.37"),
                "forecast_month_end": Decimal("2.05"),
                "by_service": [
                    {"service": "Amazon Route 53", "amount": Decimal("0.50")},
                ],
                "collected_at": "2026-07-29T07:00:00+00:00",
            }
        )

        payload = body(api.handler(make_event(path="/api/cost"), None))

        assert payload["month_to_date"] == 1.37
        assert payload["forecast_month_end"] == 2.05
        assert payload["by_service"][0]["amount"] == 0.5


class TestFailureHandling:
    def test_aws_failures_become_503_without_leaking_details(self, api, monkeypatch):
        from botocore.exceptions import ClientError

        def boom():
            raise ClientError(
                {"Error": {"Code": "ProvisionedThroughputExceededException"}},
                "GetItem",
            )

        monkeypatch.setattr(api, "_read_visit_count", boom)

        response = api.handler(make_event(path="/api/visits"), None)

        assert response["statusCode"] == 503
        assert body(response) == {"error": "upstream unavailable"}

    def test_unexpected_errors_become_500_without_a_stack_trace(self, api, monkeypatch):
        def boom():
            raise ValueError("something internal")

        monkeypatch.setattr(api, "_read_visit_count", boom)

        response = api.handler(make_event(path="/api/visits"), None)

        assert response["statusCode"] == 500
        assert "something internal" not in response["body"]
