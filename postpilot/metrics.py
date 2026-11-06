"""Prometheus metrics.

The API and the worker run as separate processes and each serves its own
/metrics, so the metrics are split by process: importing `api_metrics` in the
API does not register worker series (which would always read 0 there).
Labels only use bounded values (no user-supplied channel names) to avoid a
cardinality explosion.
"""

from prometheus_client import Counter, Gauge, Histogram


class WorkerMetrics:
    published = Counter("posts_published", "Posts delivered to the webhook")
    failures = Counter("publish_failures", "Failed webhook delivery attempts")
    latency = Histogram(
        "publish_latency_seconds",
        "Time spent calling the webhook for one post",
        buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
    )
    backlog = Gauge("queue_backlog", "Scheduled posts that are due but not yet published")
