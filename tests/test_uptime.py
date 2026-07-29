"""Tests for the scheduled uptime prober."""

from __future__ import annotations

import urllib.error
from contextlib import contextmanager

import pytest


@contextmanager
def _fake_response(status: int):
    class _Response:
        def __init__(self):
            self.status = status

        def read(self, *_args):
            return b"<!doctype html>"

        def __enter__(self):
            return self

        def __exit__(self, *_exc):
            return False

    yield _Response()


def _stub_urlopen(uptime, monkeypatch, *, status=200, exc=None):
    def fake(_request, timeout=None):
        if exc is not None:
            raise exc
        return _fake_response(status).__enter__()

    monkeypatch.setattr(uptime.urllib.request, "urlopen", fake)


class TestProbe:
    def test_2xx_is_healthy(self, uptime, monkeypatch):
        _stub_urlopen(uptime, monkeypatch, status=200)

        result = uptime.probe("https://example.test")

        assert result["healthy"] is True
        assert result["status_code"] == 200
        assert result["latency_ms"] >= 0

    def test_3xx_is_not_healthy(self, uptime, monkeypatch):
        _stub_urlopen(uptime, monkeypatch, status=301)

        assert uptime.probe("https://example.test")["healthy"] is False

    def test_http_error_is_reported_with_its_code(self, uptime, monkeypatch):
        error = urllib.error.HTTPError(
            url="https://example.test", code=503, msg="nope", hdrs=None, fp=None
        )
        _stub_urlopen(uptime, monkeypatch, exc=error)

        result = uptime.probe("https://example.test")

        assert result["healthy"] is False
        assert result["status_code"] == 503
        assert result["error"] == "http 503"

    def test_connection_failures_count_as_down(self, uptime, monkeypatch):
        _stub_urlopen(uptime, monkeypatch, exc=TimeoutError("timed out"))

        result = uptime.probe("https://example.test")

        assert result["healthy"] is False
        assert result["status_code"] == 0
        assert result["error"] == "TimeoutError"


class TestRecording:
    def test_handler_writes_a_check_and_an_aggregate(self, uptime, table, monkeypatch):
        _stub_urlopen(uptime, monkeypatch, status=200)

        uptime.handler({}, None)

        items = table.scan()["Items"]
        checks = [i for i in items if i["sk"].startswith("CHECK#")]
        aggregate = [i for i in items if i["sk"] == "AGGREGATE"]

        assert len(checks) == 1
        assert len(aggregate) == 1
        assert aggregate[0]["total_checks"] == 1
        assert aggregate[0]["failed_checks"] == 0
        assert aggregate[0]["last_status"] == "up"

    def test_aggregate_accumulates_across_runs(self, uptime, table, monkeypatch):
        _stub_urlopen(uptime, monkeypatch, status=200)
        uptime.handler({}, None)

        _stub_urlopen(uptime, monkeypatch, status=500)
        uptime.handler({}, None)

        aggregate = table.get_item(Key={"pk": "UPTIME", "sk": "AGGREGATE"})["Item"]

        assert aggregate["total_checks"] == 2
        assert aggregate["failed_checks"] == 1
        assert aggregate["last_status"] == "down"

    def test_window_start_is_set_once_and_kept(self, uptime, table, monkeypatch):
        _stub_urlopen(uptime, monkeypatch, status=200)

        uptime.handler({}, None)
        first = table.get_item(Key={"pk": "UPTIME", "sk": "AGGREGATE"})["Item"]["window_started_at"]

        uptime.handler({}, None)
        second = table.get_item(Key={"pk": "UPTIME", "sk": "AGGREGATE"})["Item"][
            "window_started_at"
        ]

        assert first == second

    def test_check_rows_carry_a_ttl(self, uptime, table, monkeypatch):
        _stub_urlopen(uptime, monkeypatch, status=200)

        uptime.handler({}, None)

        check = next(i for i in table.scan()["Items"] if i["sk"].startswith("CHECK#"))
        assert check["expires_at"] > 0

    def test_missing_site_url_fails_loudly(self, uptime, monkeypatch):
        monkeypatch.setattr(uptime, "SITE_URL", "")

        with pytest.raises(RuntimeError, match="SITE_URL"):
            uptime.handler({}, None)

    def test_a_failed_probe_logs_at_error_so_the_alarm_fires(self, uptime, monkeypatch, caplog):
        _stub_urlopen(uptime, monkeypatch, status=500)

        with caplog.at_level("ERROR"):
            uptime.handler({}, None)

        assert "probe failed" in caplog.text
