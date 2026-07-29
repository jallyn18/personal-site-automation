"""Shared fixtures.

All three Lambdas define a module named `handler`, so they are loaded by path
under distinct module names rather than by import. Loading fresh in each test
also resets the module-level client caches, which would otherwise leak a real
boto3 resource across moto contexts.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

ROOT = Path(__file__).resolve().parents[1]
TABLE_NAME = "test-metrics"
REGION = "us-east-1"


def load_module(name: str, relative_path: str):
    """Import a Lambda handler from disk under an explicit module name."""
    path = ROOT / relative_path
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:  # pragma: no cover - import plumbing
        raise ImportError(f"cannot load {path}")

    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    """Fake credentials so a misconfigured test cannot reach a real account."""
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("AWS_REGION", REGION)

    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("DEDUPE_SALT", "unit-test-salt")
    monkeypatch.setenv("SITE_URL", "https://example.test")


@pytest.fixture
def table(aws_env):
    """A DynamoDB table matching the schema in terraform/dynamodb.tf."""
    with mock_aws():
        resource = boto3.resource("dynamodb", region_name=REGION)
        created = resource.create_table(
            TableName=TABLE_NAME,
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        created.wait_until_exists()
        yield created


@pytest.fixture
def api(table):
    return load_module("api_handler", "lambdas/api/handler.py")


@pytest.fixture
def uptime(table):
    return load_module("uptime_handler", "lambdas/uptime/handler.py")


@pytest.fixture
def cost(table):
    return load_module("cost_handler", "lambdas/cost/handler.py")


def make_event(
    method: str = "GET",
    path: str = "/api/health",
    source_ip: str = "203.0.113.7",
    user_agent: str = "pytest/1.0",
) -> dict:
    """A Lambda Function URL payload-format-2.0 event."""
    return {
        "version": "2.0",
        "rawPath": path,
        "headers": {"user-agent": user_agent},
        "requestContext": {
            "http": {
                "method": method,
                "path": path,
                "sourceIp": source_ip,
            }
        },
    }
