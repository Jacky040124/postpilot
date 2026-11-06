from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from postpilot.api import create_app
from postpilot.config import Settings
from postpilot.db import create_tables, make_engine, make_session_factory


@pytest.fixture
def settings(tmp_path) -> Settings:
    # A file-backed SQLite DB per test: fast, isolated, no Postgres needed.
    return Settings(
        database_url=f"sqlite:///{tmp_path / 'test.db'}",
        webhook_url="http://webhook.test/hook",
        max_attempts=3,
        retry_backoff_seconds=30,
    )


@pytest.fixture
def client(settings):
    with TestClient(create_app(settings)) as test_client:
        yield test_client


@pytest.fixture
def session_factory(settings):
    engine = make_engine(settings.database_url)
    create_tables(engine)
    yield make_session_factory(engine)
    engine.dispose()
