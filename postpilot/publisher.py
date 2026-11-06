"""Deliver a post to a Discord- or Slack-compatible incoming webhook."""

from __future__ import annotations

import httpx

from postpilot.models import Post


class PublishError(Exception):
    pass


class WebhookPublisher:
    def __init__(self, url: str, timeout: float = 5.0, client: httpx.Client | None = None):
        self.url = url
        self.client = client or httpx.Client(timeout=timeout)

    def publish(self, post: Post) -> None:
        message = f"[{post.channel}] {post.content}"
        # Discord reads "content", Slack reads "text"; sending both works for either.
        body = {"content": message, "text": message}
        try:
            response = self.client.post(self.url, json=body)
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise PublishError(f"webhook returned {exc.response.status_code}") from exc
        except httpx.HTTPError as exc:
            raise PublishError(f"webhook request failed: {exc.__class__.__name__}") from exc

    def close(self) -> None:
        self.client.close()
