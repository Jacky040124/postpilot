"""Background worker: poll for due posts and publish them.

Safe to run more than one copy: on Postgres, rows are claimed with
SELECT ... FOR UPDATE SKIP LOCKED, so two workers never publish the same post.
"""

from __future__ import annotations

import logging
import signal
import threading
import time
from datetime import datetime, timedelta

from prometheus_client import start_http_server
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from postpilot.config import Settings
from postpilot.db import create_tables, make_engine, make_session_factory
from postpilot.metrics import WorkerMetrics as metrics
from postpilot.models import Post, PostStatus, utcnow
from postpilot.publisher import PublishError, WebhookPublisher

log = logging.getLogger("postpilot.worker")


def _due(now: datetime):
    return (Post.status == PostStatus.SCHEDULED) & (Post.publish_at <= now)


def count_backlog(session: Session, now: datetime) -> int:
    return session.scalar(select(func.count()).select_from(Post).where(_due(now))) or 0


def process_batch(
    session_factory: sessionmaker,
    publisher: WebhookPublisher,
    settings: Settings,
    now: datetime | None = None,
) -> int:
    """Publish up to `batch_size` due posts. Returns how many were published."""
    now = now or utcnow()
    published = 0
    with session_factory() as session, session.begin():
        stmt = (
            select(Post)
            .where(_due(now))
            .order_by(Post.publish_at)
            .limit(settings.batch_size)
            .with_for_update(skip_locked=True)
        )
        for post in session.scalars(stmt):
            post.attempts += 1
            start = time.perf_counter()
            try:
                publisher.publish(post)
            except PublishError as exc:
                metrics.failures.inc()
                post.last_error = str(exc)[:500]
                if post.attempts >= settings.max_attempts:
                    post.status = PostStatus.FAILED
                else:
                    # Exponential backoff: 30s, 60s, 120s ... with the defaults.
                    delay = settings.retry_backoff_seconds * 2 ** (post.attempts - 1)
                    post.publish_at = now + timedelta(seconds=delay)
                log.warning(
                    "publish_failed",
                    extra={
                        "post_id": post.id,
                        "attempt": post.attempts,
                        "final": post.status == PostStatus.FAILED,
                        "error": post.last_error,
                    },
                )
            else:
                post.status = PostStatus.PUBLISHED
                post.published_at = utcnow()
                post.last_error = None
                metrics.published.inc()
                published += 1
                log.info("post_published", extra={"post_id": post.id, "channel": post.channel})
            finally:
                metrics.latency.observe(time.perf_counter() - start)

    with session_factory() as session:
        metrics.backlog.set(count_backlog(session, utcnow()))
    return published


def run_forever(
    session_factory: sessionmaker,
    publisher: WebhookPublisher,
    settings: Settings,
    stop: threading.Event,
) -> None:
    log.info("worker_started", extra={"poll_interval_seconds": settings.poll_interval_seconds})
    while not stop.is_set():
        try:
            process_batch(session_factory, publisher, settings)
        except Exception:
            # Keep polling through transient DB errors; ECS restarts us if we truly die.
            log.exception("poll_failed")
        stop.wait(settings.poll_interval_seconds)
    log.info("worker_stopped")


def main(settings: Settings | None = None) -> int:
    settings = settings or Settings.from_env()
    if not settings.webhook_url:
        log.error("missing_config", extra={"setting": "WEBHOOK_URL"})
        return 1

    engine = make_engine(settings.database_url)
    create_tables(engine)
    start_http_server(settings.worker_metrics_port)

    stop = threading.Event()
    # ECS sends SIGTERM before stopping a task; finish the current batch then exit.
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())

    publisher = WebhookPublisher(settings.webhook_url, settings.webhook_timeout_seconds)
    try:
        run_forever(make_session_factory(engine), publisher, settings, stop)
    finally:
        publisher.close()
        engine.dispose()
    return 0
