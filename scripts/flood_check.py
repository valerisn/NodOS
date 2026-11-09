#!/usr/bin/env python3
"""Slowloris-style check for the smoke test.

Opens more idle connections than NodOS allows (256) and then NEVER closes them.
The server must cut them off by itself (15 second idle limit) and go back to
answering real requests while the attacker is still holding the sockets. If a
slot only freed up when the client let go, this would fail.

Usage: flood_check.py PORT
"""
import socket
import sys
import time
import urllib.request

port = int(sys.argv[1])
url = f"http://127.0.0.1:{port}/api/v1/health"

held = []
for _ in range(280):
    try:
        held.append(socket.create_connection(("127.0.0.1", port), timeout=3))
    except OSError:
        pass
print(f"holding {len(held)} idle connections", flush=True)

start = time.time()
recovered_at = None
while time.time() - start < 40:
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            if r.status == 200:
                recovered_at = time.time() - start
                break
    except Exception:
        pass
    time.sleep(1)

if recovered_at is None:
    print("FAIL: server never freed its slots while idle connections were still held open", file=sys.stderr)
    sys.exit(1)
print(f"server answered again {recovered_at:.0f}s after the flood with all sockets still held open")
