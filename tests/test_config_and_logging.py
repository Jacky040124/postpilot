from __future__ import annotations

import json
import logging
import sys

from postpilot import __main__ as cli
from postpilot.config import Settings
from postpilot.logging_config import JsonFormatter, configure_logging


def test_database_url_from_env(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql+psycopg://u:p@db/x")
    assert Settings.from_env().database_url == "postgresql+psycopg://u:p@db/x"


def test_database_url_from_parts_escapes_password(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("DB_HOST", "db.internal")
    monkeypatch.setenv("DB_PASSWORD", "p@ss/word")
    monkeypatch.setenv("DB_NAME", "postpilot")
    url = Settings.from_env().database_url
    assert url == (
        "postgresql+psycopg://postpilot:p%40ss%2Fword@db.internal:5432/postpilot?sslmode=prefer"
    )


def test_defaults_without_env(monkeypatch):
    for var in ("DATABASE_URL", "DB_HOST", "WEBHOOK_URL", "LOG_LEVEL"):
        monkeypatch.delenv(var, raising=False)
    settings = Settings.from_env()
    assert settings.database_url.startswith("sqlite")
    assert settings.webhook_url is None
    assert settings.log_level == "INFO"


def test_json_formatter_includes_extra_fields():
    record = logging.LogRecord("postpilot.test", logging.INFO, __file__, 1, "hello", None, None)
    record.post_id = 42
    payload = json.loads(JsonFormatter().format(record))
    assert payload["message"] == "hello"
    assert payload["level"] == "INFO"
    assert payload["post_id"] == 42
    assert "timestamp" in payload


def test_json_formatter_includes_exceptions():
    try:
        raise ValueError("bad")
    except ValueError:
        record = logging.LogRecord("t", logging.ERROR, __file__, 1, "oops", None, sys.exc_info())
    payload = json.loads(JsonFormatter().format(record))
    assert "ValueError: bad" in payload["exc_info"]


def test_configure_logging_writes_json(capsys):
    configure_logging("INFO")
    logging.getLogger("postpilot.test").info("ping", extra={"k": "v"})
    line = capsys.readouterr().out.strip().splitlines()[-1]
    assert json.loads(line)["k"] == "v"


def test_cli_dispatches_worker(monkeypatch):
    from postpilot import worker

    monkeypatch.setattr(worker, "main", lambda settings: 7)
    assert cli.main(["worker"]) == 7


def test_cli_dispatches_api(monkeypatch):
    import uvicorn

    seen = {}
    monkeypatch.setattr(uvicorn, "run", lambda app, **kw: seen.update(kw))
    assert cli.main(["api", "--port", "9999"]) == 0
    assert seen["port"] == 9999
