"""Loopback-only HTTP fixture for the hostless production SSE transport tests."""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

lock = threading.Lock()
counts = {"redirects_followed": 0, "closed_streams": 0, "cancelled_token_requests": 0}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def response(self, status, body=b"", content_type="text/plain", **headers):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/metrics":
            with lock:
                self.response(200, json.dumps(counts).encode(), "application/json")
            return
        if url.path == "/redirect-target":
            with lock:
                counts["redirects_followed"] += 1
            self.response(200)
            return
        if url.path.startswith("/cancelled-token/"):
            with lock:
                counts["cancelled_token_requests"] += 1
        if (self.headers.get("Authorization") != "Bearer test-token"
                or self.headers.get("Accept") != "text/event-stream"
                or parse_qs(url.query) != {"client_id": ["native & device"]}
                or not url.path.endswith("/sync/invalidations")):
            self.response(400)
            return
        if url.path.startswith("/redirect/"):
            self.response(302, Location="/redirect-target")
            return
        if url.path.startswith("/unauthorized/"):
            self.response(401)
            return
        if url.path.startswith("/wrong-type/"):
            self.response(200, b"{}", "application/json")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            # Deliberately split field names, CRLF and JSON across writes.
            for part in [b"ev", b"ent: ready\r", b"\ndata:", b" {}\r\n\r", b"\n"]:
                self.wfile.write(part)
                self.wfile.flush()
                time.sleep(0.005)
            if url.path.startswith("/hold/"):
                for _ in range(100):
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    time.sleep(0.02)
            else:
                self.wfile.write(b'event: invalidate\ndata: {"namespace":"chromium:phi","data_types":[2000],"source_client_id":"peer"}\n\n')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            with lock:
                counts["closed_streams"] += 1


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as ready:
    ready.write(str(server.server_port))
server.serve_forever()
