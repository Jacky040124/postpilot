"""Stand-in for a Discord/Slack incoming webhook, for local runs and CI smoke tests.

POST /webhook  -> stores the JSON body, returns 204 (like Discord)
GET  /received -> returns everything stored so far
Set FAIL_RATE=0.3 to make 30% of deliveries return 500 and exercise retries.
"""

import json
import os
import random
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RECEIVED: list[dict] = []
FAIL_RATE = float(os.getenv("FAIL_RATE", "0"))


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 (http.server naming)
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if random.random() < FAIL_RATE:  # noqa: S311 (not crypto)
            self.send_response(500)
            self.end_headers()
            return
        RECEIVED.append(body)
        print(json.dumps({"message": "webhook_received", "body": body}), flush=True)
        self.send_response(204)
        self.end_headers()

    def do_GET(self):  # noqa: N802
        payload = json.dumps(RECEIVED).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):  # keep stdout for our JSON lines only
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
