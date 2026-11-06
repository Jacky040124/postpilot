"""Prometheus metrics.

The API and the worker are separate processes, so each exposes its own /metrics.
Labels are kept to bounded values (no user-supplied channel names) to avoid a
cardinality explosion.
"""

from prometheus_client import Counter, Gauge, Histogram

POSTS_PUBLISHED = Counter("posts_published", "Posts delivered to the webhook")
PUBLISH_FAILURES = Counter("publish_failures", "Failed webhook delivery attempts")
PUBLISH_LATENCY = Histogram(
    "publish_latency_seconds",
    "Time spent calling the webhook for one post",
    buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
)
QUEUE_BACKLOG = Gauge("queue_backlog", "Scheduled posts that are due but not yet published")

HTTP_REQUESTS = Counter(
    "http_requests", "HTTP requests handled by the API", ["method", "route", "status"]
)
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds", "API request latency", ["method", "route"]
)
