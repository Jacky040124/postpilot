from __future__ import annotations

from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient

from postpilot.api import create_app
from postpilot.config import Settings


def _future(minutes: int = 10) -> str:
    return (datetime.now(UTC) + timedelta(minutes=minutes)).isoformat()


def _create(client, **overrides):
    body = {"content": "Launch day!", "channel": "marketing", "publish_at": _future()}
    body.update(overrides)
    return client.post("/posts", json=body)


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_when_database_is_reachable(client):
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_readyz_returns_503_when_database_is_down(tmp_path):
    # A path inside a missing directory cannot be opened, which simulates a dead DB.
    app = create_app(Settings(database_url=f"sqlite:///{tmp_path}/missing/dir/db.sqlite"))
    client = TestClient(app)  # no context manager: skip startup table creation
    response = client.get("/readyz")
    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}


def test_create_post_returns_201_and_defaults(client):
    response = _create(client)
    assert response.status_code == 201
    post = response.json()
    assert post["id"] > 0
    assert post["status"] == "scheduled"
    assert post["attempts"] == 0
    assert post["published_at"] is None


def test_naive_publish_at_is_treated_as_utc(client):
    response = _create(client, publish_at="2030-01-01T09:00:00")
    assert response.status_code == 201
    assert response.json()["publish_at"].startswith("2030-01-01T09:00:00")
    assert response.json()["publish_at"].endswith(("Z", "+00:00"))


def test_offset_publish_at_is_converted_to_utc(client):
    response = _create(client, publish_at="2030-01-01T09:00:00-08:00")
    assert response.json()["publish_at"].startswith("2030-01-01T17:00:00")


def test_create_post_validates_input(client):
    assert _create(client, content="").status_code == 422
    assert _create(client, channel="x" * 65).status_code == 422
    assert _create(client, publish_at="not-a-date").status_code == 422


def test_list_posts_sorted_and_filtered(client):
    later = _create(client, content="later", publish_at=_future(60)).json()
    sooner = _create(client, content="sooner", publish_at=_future(5)).json()
    client.post(f"/posts/{later['id']}/cancel")

    all_posts = client.get("/posts").json()
    assert [p["content"] for p in all_posts] == ["sooner", "later"]

    scheduled = client.get("/posts", params={"status": "scheduled"}).json()
    assert [p["id"] for p in scheduled] == [sooner["id"]]

    assert client.get("/posts", params={"status": "bogus"}).status_code == 422
    assert client.get("/posts", params={"limit": 0}).status_code == 422


def test_get_post(client):
    created = _create(client).json()
    assert client.get(f"/posts/{created['id']}").json() == created
    assert client.get("/posts/9999").status_code == 404


def test_cancel_post(client):
    created = _create(client).json()
    response = client.post(f"/posts/{created['id']}/cancel")
    assert response.status_code == 200
    assert response.json()["status"] == "cancelled"


def test_cancel_twice_conflicts(client):
    created = _create(client).json()
    client.post(f"/posts/{created['id']}/cancel")
    response = client.post(f"/posts/{created['id']}/cancel")
    assert response.status_code == 409


def test_cancel_missing_post(client):
    assert client.post("/posts/9999/cancel").status_code == 404


def test_metrics_endpoint_exposes_app_metrics(client):
    client.get("/healthz")
    body = client.get("/metrics").text
    assert "http_requests_total" in body
    assert 'route="/healthz"' in body
    # Worker metrics are registered in the same module; the names must exist.
    for name in ("posts_published_total", "publish_failures_total", "queue_backlog"):
        assert name in body
