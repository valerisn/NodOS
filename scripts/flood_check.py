#!/usr/bin/env python3
"""Slowloris-style check for the smoke test.

Opens more idle connections than NodOS allows (256) and then NEVER closes them.
Two things must be true:

  1. The flood really saturates the server (a health request fails or stalls
     while the sockets are held). Without this the test could pass by never
     having stressed anything.
  2. The server then cuts the idle connections off by itself (15 second idle
     limit) and answers real requests again, while the attacker is still
     holding every socket. If a slot only freed up when the client let go,
     part 2 would fail.

Usage: flood_check.py PORT
"""
import socket
import sys
import time
import urllib.request

port = int(sys.argv[1])
url = f"http://127.0.0.1:{port}/api/v1/health"


def healthy() -> bool:
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


held = []
for _ in range(320):
    try:
        held.append(socket.create_connection(("127.0.0.1", port), timeout=3))
    except OSError:
        pass
print(f"holding {len(held)} idle connections", flush=True)

# Give the accept loop time to take them all and fill every slot.
time.sleep(3)

saturated = not healthy()
print(f"saturated: {saturated}", flush=True)
if not saturated:
    print("FAIL: 320 idle connections did not saturate the server, so this test proves nothing", file=sys.stderr)
    sys.exit(1)

start = time.time()
recovered_at = None
while time.time() - start < 45:
    if healthy():
        recovered_at = time.time() - start
        break
    time.sleep(1)

if recovered_at is None:
    print("FAIL: server never freed its slots while idle connections were still held open", file=sys.stderr)
    sys.exit(1)
print(f"recovered: server answered again {recovered_at:.0f}s later with all {len(held)} sockets still held open")
