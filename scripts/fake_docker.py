#!/usr/bin/env python3
"""Pretend docker daemon on a unix socket, for the smoke test."""
import json
import os
import socketserver
import struct
import sys
from http.server import BaseHTTPRequestHandler

SOCK, LOG = sys.argv[1], sys.argv[2]

CONTAINERS = [
    {"Id": "3f4a9c1d2b7e8a00112233445566778899aabbccddeeff001122334455667788",
     "Names": ["/web"], "Image": "nginx:1.27", "State": "running", "Status": "Up 2 hours", "Created": 1700000000},
    {"Id": "91be04c7aa210f33112233445566778899aabbccddeeff001122334455667788",
     "Names": ["/old-job"], "Image": "busybox", "State": "exited", "Status": "Exited (0) 3 days ago", "Created": 1700000001},
]

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *_):
        pass

    def _record(self):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")

    def do_GET(self):
        self._record()
        if self.path.startswith("/containers/json"):
            body = json.dumps(CONTAINERS).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/images/json"):
            body = json.dumps([{"Id": "sha256:0a1b2c3d4e5f60718293", "RepoTags": ["nginx:1.27"], "Size": 192000000, "Created": 1700000000}]).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        elif "/stats" in self.path:
            body = json.dumps({
                "cpu_stats": {"cpu_usage": {"total_usage": 2000000}, "system_cpu_usage": 100000000, "online_cpus": 4},
                "precpu_stats": {"cpu_usage": {"total_usage": 1000000}, "system_cpu_usage": 50000000},
                "memory_stats": {"usage": 300000, "limit": 1000000, "stats": {"inactive_file": 100000}},
                "pids_stats": {"current": 7},
                "networks": {"eth0": {"rx_bytes": 10, "tx_bytes": 20}},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        elif "/logs" in self.path:
            text = b"web starting\nlistening on :8080\n"
            frame = b"\x01\x00\x00\x00" + struct.pack(">I", len(text)) + text
            self.send_response(200)
            self.end_headers()
            self.wfile.write(frame)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        self._record()
        if any(self.path.startswith(f"/containers/web/{v}") for v in ("start", "stop", "restart")):
            self.send_response(204)
        else:
            self.send_response(404)
        self.end_headers()

class Server(socketserver.UnixStreamServer):
    def get_request(self):
        request, _ = super().get_request()
        return request, ("local", 0)

if os.path.exists(SOCK):
    os.unlink(SOCK)
with Server(SOCK, Handler) as srv:
    srv.serve_forever()
