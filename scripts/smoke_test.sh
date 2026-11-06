#!/usr/bin/env bash
# End-to-end check against the running docker compose stack:
# schedule a post for "now", wait for the worker to deliver it to the mock webhook,
# and confirm the metric moved. Used locally and in CI.
set -euo pipefail

API="${API_URL:-http://localhost:8000}"
WEBHOOK="${WEBHOOK_URL:-http://localhost:8080}"
WORKER_METRICS="${WORKER_METRICS_URL:-http://localhost:9100/metrics}"
MARKER="smoke-$(date +%s)-$RANDOM"

echo "waiting for API readiness..."
for _ in $(seq 1 30); do
  curl -fsS "$API/readyz" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$API/readyz"; echo

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
post=$(curl -fsS -X POST "$API/posts" -H 'Content-Type: application/json' \
  -d "{\"content\":\"$MARKER\",\"channel\":\"smoke\",\"publish_at\":\"$now\"}")
id=$(echo "$post" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "scheduled post $id ($MARKER)"

for _ in $(seq 1 30); do
  status=$(curl -fsS "$API/posts/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
  if [ "$status" = "published" ]; then
    break
  fi
  sleep 1
done
echo "post $id status: $status"
[ "$status" = "published" ] || { echo "FAIL: post was not published"; exit 1; }

curl -fsS "$WEBHOOK/received" | grep -q "$MARKER" || { echo "FAIL: webhook never got $MARKER"; exit 1; }
echo "webhook received $MARKER"

published=$(curl -fsS "$WORKER_METRICS" | awk '/^posts_published_total/ {print $2}')
echo "worker posts_published_total=$published"
python3 -c "import sys; sys.exit(0 if float('${published:-0}') >= 1 else 1)" \
  || { echo "FAIL: posts_published_total did not increase"; exit 1; }
echo "SMOKE TEST PASSED"
