# HTTP API (v1)

All endpoints live under `/api/v1`. Bodies are JSON. Every response carries
`x-content-type-options`, `x-frame-options`, `referrer-policy`, `cache-control:
no-store` and a same-origin `content-security-policy`.

Status: only the endpoints below exist. Monitoring, Docker and service
endpoints arrive in later phases.

## Authentication model

Login sets an `HttpOnly`, `SameSite=Strict` cookie named `nodos_session`
(`Secure` unless `secure_cookies = false`). Sessions expire after 30 minutes
idle or 12 hours absolute, and live in server memory, so a restart logs
everyone out.

State-changing requests (`POST`) on an authenticated session must also send the
CSRF token from the login or `/me` response in the `x-csrf-token` header.

## Endpoints

### `GET /api/v1/health`

No authentication. `{"status":"ok","version":"0.0.1-dev"}`.

### `POST /api/v1/login`

Body: `{"username": "...", "password": "..."}`, at most 1024 bytes.

| Status | Meaning |
| --- | --- |
| 200 | `{"username","role","csrf"}` plus `Set-Cookie` |
| 400 | Body is not valid JSON of that shape |
| 401 | Invalid credentials. Unknown user and wrong password are indistinguishable |
| 413 | Body too large |
| 429 | Too many failures from this address (5 per 15 minutes) |

### `GET /api/v1/me`

Requires a session. Returns `{"username","role","csrf"}`. 401 otherwise.

### `POST /api/v1/logout`

Requires a session and `x-csrf-token`. Destroys the session and clears the
cookie. 403 on a missing or wrong CSRF token.

### `GET /api/v1/system`

Requires a session. The latest host snapshot, sampled every `sample_interval_ms`:

```json
{
  "ts": 1794216317, "hostname": "homebox", "os": "Debian GNU/Linux 13",
  "kernel": "6.8.0", "uptime_s": 350735, "load": [0.5, 0.6, 0.6],
  "cpu": {"percent": 12.5, "cores": [10.0, 15.0]},
  "memory": {"total_kb": 16318244, "used_kb": 6441701, "available_kb": 9876543,
             "swap_total_kb": 2097148, "swap_used_kb": 148},
  "network": [{"name": "eth0", "rx_bytes": 0, "tx_bytes": 0, "rx_bps": 0,
               "tx_bps": 0, "rx_errors": 0, "tx_errors": 0}],
  "storage": [{"device": "/dev/sda1", "mount": "/", "fstype": "ext4",
               "total_bytes": 0, "used_bytes": 0, "avail_bytes": 0}],
  "temperatures": [{"label": "x86_pkg_temp", "celsius": 47.0}]
}
```

CPU percentages and network rates are computed between two samples, so they
read 0 on the very first one. Only real filesystems appear in `storage`
(ext4, xfs, btrfs, zfs, vfat, nfs and similar; tmpfs and overlay are hidden).
`temperatures` is empty on machines without thermal zones.

503 when no sample exists yet, or when the host OS is not Linux.

### `GET /api/v1/history`

Requires a session. Up to 300 recent samples (ten minutes at the default
interval), oldest first, as parallel arrays:

```json
{"ts": [1794216317], "cpu": [12.5], "mem": [39.5], "rx_bps": [1200], "tx_bps": [300]}
```

`rx_bps` and `tx_bps` sum all interfaces except `lo`. History is in memory only
and resets when the server restarts.

### `GET /api/v1/stream`

Requires a session. A Server-Sent Events stream (`text/event-stream`). Each
new sample arrives as one event, the same JSON as `/system`:

```
event: snapshot
data: {"ts":1794216317,"hostname":"homebox", ...}

```

Between samples the server sends `: ping` comment lines (at least every 5
seconds) so proxies keep the connection open. The stream ends when the client
disconnects, the session expires or is logged out, or the server stops. At most
16 streams run at once; more get 503. Browsers reconnect automatically with
`EventSource`, which sends the session cookie, so no token handling is needed.

## Errors

Errors are `{"error": "message"}` with a matching HTTP status. A `POST` with no
`Content-Length` or `Transfer-Encoding` gets 411.
