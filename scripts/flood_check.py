#!/usr/bin/env python3
"""Hold more idle connections than nodos allows and check it recovers on its own."""
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

t_end = time.time() + 4
while time.time() < t_end:
    for _ in range(25):
        try:
            held.append(socket.create_connection(("127.0.0.1", port), timeout=2))
        except OSError:
            pass
    time.sleep(0.2)
print(f"now holding {len(held)} sockets, including ones the server already dropped", flush=True)

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
