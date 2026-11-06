from __future__ import annotations

import json
import threading
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from prometheus_client import REGISTRY

from postpilot import worker
from postpilot.config import Settings
from postpilot.models import Post, PostStatus
from postpilot.publisher import PublishError, WebhookPublisher


def _metric(name: str) -> float:
    return REGISTRY.get_sample_value(name) or 0.0


class FakeWebhook:
    """Records requests and answers with a fixed status code (or raises)."""

    def __init__(self, status_code: int = 204, error: Exception | None = None):
        self.status_code = status_code
        self.error = error
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.error:
            raise self.error
        return httpx.Response(self.status_code)

    def publisher(self) -> WebhookPublisher:
        client = httpx.Client(transport=httpx.MockTransport(self))
        return WebhookPublisher("http://webhook.test/hook", client=client)


def _add_post(session_factory, publish_at: datetime, **fields) -> int:
    with session_factory() as session:
        post = Post(content="hello", channel="general", publish_at=publish_at, **fields)
        session.add(post)
        session.commit()
        return post.id


def _get(session_factory, post_id: int) -> Post:
    with session_factory() as session:
        return session.get(Post, post_id)


NOW = datetime(2030, 1, 1, 12, 0, tzinfo=UTC)


def test_publishes_due_posts_only(session_factory, settings):
    due = _add_post(session_factory, NOW - timedelta(minutes=1))
    future = _add_post(session_factory, NOW + timedelta(hours=1))
    webhook = FakeWebhook()
    before = _metric("posts_published_total")

    published = worker.process_batch(session_factory, webhook.publisher(), settings, now=NOW)

    assert published == 1
    assert _get(session_factory, due).status == PostStatus.PUBLISHED
    assert _get(session_factory, due).published_at is not None
    assert _get(session_factory, future).status == PostStatus.SCHEDULED
    assert _metric("posts_published_total") == before + 1

    body = json.loads(webhook.requests[0].content)
    assert body["content"] == "[general] hello"
    assert body["text"] == body["content"]


def test_skips_cancelled_posts(session_factory, settings):
    post_id = _add_post(session_factory, NOW - timedelta(minutes=1), status=PostStatus.CANCELLED)
    webhook = FakeWebhook()

    assert worker.process_batch(session_factory, webhook.publisher(), settings, now=NOW) == 0
    assert webhook.requests == []
    assert _get(session_factory, post_id).status == PostStatus.CANCELLED


def test_failure_is_retried_with_backoff(session_factory, settings):
    post_id = _add_post(session_factory, NOW - timedelta(minutes=1))
    before = _metric("publish_failures_total")

    worker.process_batch(session_factory, FakeWebhook(500).publisher(), settings, now=NOW)

    post = _get(session_factory, post_id)
    assert post.status == PostStatus.SCHEDULED
    assert post.attempts == 1
    assert post.last_error == "webhook returned 500"
    assert post.publish_at == NOW + timedelta(seconds=30)
    assert _metric("publish_failures_total") == before + 1


def test_post_fails_permanently_after_max_attempts(session_factory, settings):
    post_id = _add_post(session_factory, NOW - timedelta(minutes=1))
    webhook = FakeWebhook(503)
    now = NOW
    for _ in range(settings.max_attempts):
        worker.process_batch(session_factory, webhook.publisher(), settings, now=now)
        now += timedelta(hours=1)  # jump past any backoff

    post = _get(session_factory, post_id)
    assert post.status == PostStatus.FAILED
    assert post.attempts == settings.max_attempts
    assert len(webhook.requests) == settings.max_attempts


def test_network_errors_become_publish_errors(session_factory, settings):
    post_id = _add_post(session_factory, NOW - timedelta(minutes=1))
    webhook = FakeWebhook(error=httpx.ConnectError("boom"))

    worker.process_batch(session_factory, webhook.publisher(), settings, now=NOW)

    assert _get(session_factory, post_id).last_error == "webhook request failed: ConnectError"


def test_publisher_raises_publish_error():
    with pytest.raises(PublishError):
        FakeWebhook(404).publisher().publish(Post(content="x", channel="y"))


def test_batch_size_limits_work_per_poll(session_factory):
    settings = Settings(database_url="unused", batch_size=2)
    for minutes in range(5):
        _add_post(session_factory, NOW - timedelta(minutes=minutes + 1))

    published = worker.process_batch(session_factory, FakeWebhook().publisher(), settings, now=NOW)

    assert published == 2


def test_queue_backlog_gauge_counts_due_posts(session_factory, settings):
    past = datetime.now(UTC) - timedelta(minutes=5)
    _add_post(session_factory, past)
    _add_post(session_factory, past)
    _add_post(session_factory, datetime.now(UTC) + timedelta(days=1))

    with session_factory() as session:
        assert worker.count_backlog(session, datetime.now(UTC)) == 2

    # After a successful batch the two due posts are gone, so the gauge drops to 0.
    worker.process_batch(session_factory, FakeWebhook().publisher(), settings)
    assert _metric("queue_backlog") == 0


def test_run_forever_stops_on_event(session_factory, settings, monkeypatch):
    calls = []
    stop = threading.Event()

    def fake_batch(*args, **kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("db hiccup")  # first poll fails, loop must survive
        stop.set()
        return 0

    monkeypatch.setattr(worker, "process_batch", fake_batch)
    fast = Settings(database_url="unused", poll_interval_seconds=0)
    worker.run_forever(session_factory, FakeWebhook().publisher(), fast, stop)

    assert len(calls) == 2


def test_main_requires_webhook_url():
    assert worker.main(Settings(database_url="sqlite://", webhook_url=None)) == 1


def test_main_runs_until_stopped(settings, monkeypatch):
    monkeypatch.setattr(worker, "start_http_server", lambda port: None)
    monkeypatch.setattr(worker.signal, "signal", lambda *args: None)

    def fake_run(session_factory, publisher, settings, stop):
        assert publisher.url == settings.webhook_url

    monkeypatch.setattr(worker, "run_forever", fake_run)
    assert worker.main(settings) == 0
