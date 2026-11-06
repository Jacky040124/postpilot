"""HTTP metrics served by the API's /metrics endpoint."""

from prometheus_client import Counter, Histogram

HTTP_REQUESTS = Counter(
    "http_requests", "HTTP requests handled by the API", ["method", "route", "status"]
)
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds", "API request latency", ["method", "route"]
)
