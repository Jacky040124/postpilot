"""Runtime settings, read from environment variables (12-factor style)."""

from __future__ import annotations

import os
from dataclasses import dataclass
from urllib.parse import quote_plus


def _database_url() -> str:
    """Build the database URL.

    Locally we pass DATABASE_URL directly. On ECS the password comes from Secrets
    Manager as its own variable, so we assemble the URL from parts instead.
    """
    url = os.getenv("DATABASE_URL")
    if url:
        return url
    host = os.getenv("DB_HOST")
    if host:
        user = quote_plus(os.getenv("DB_USER", "postpilot"))
        password = quote_plus(os.getenv("DB_PASSWORD", ""))
        port = os.getenv("DB_PORT", "5432")
        name = os.getenv("DB_NAME", "postpilot")
        sslmode = os.getenv("DB_SSLMODE", "prefer")  # RDS sets "require"
        return f"postgresql+psycopg://{user}:{password}@{host}:{port}/{name}?sslmode={sslmode}"
    return "sqlite:///./postpilot.db"


@dataclass(frozen=True)
class Settings:
    database_url: str
    webhook_url: str | None = None
    poll_interval_seconds: float = 5.0
    batch_size: int = 20
    max_attempts: int = 3
    retry_backoff_seconds: float = 30.0
    webhook_timeout_seconds: float = 5.0
    worker_metrics_port: int = 9100
    log_level: str = "INFO"

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            database_url=_database_url(),
            webhook_url=os.getenv("WEBHOOK_URL") or None,
            poll_interval_seconds=float(os.getenv("POLL_INTERVAL_SECONDS", "5")),
            batch_size=int(os.getenv("BATCH_SIZE", "20")),
            max_attempts=int(os.getenv("MAX_ATTEMPTS", "3")),
            retry_backoff_seconds=float(os.getenv("RETRY_BACKOFF_SECONDS", "30")),
            webhook_timeout_seconds=float(os.getenv("WEBHOOK_TIMEOUT_SECONDS", "5")),
            worker_metrics_port=int(os.getenv("WORKER_METRICS_PORT", "9100")),
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
        )
