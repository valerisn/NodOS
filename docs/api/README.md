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

An `event: alerts` with the `/alerts` JSON is sent first and again whenever the
alert set changes. Between samples the server sends `: ping` comment lines (at least every 5
seconds) so proxies keep the connection open. The stream ends when the client
disconnects, the session expires or is logged out, or the server stops. At most
16 streams run at once; more get 503. Browsers reconnect automatically with
`EventSource`, which sends the session cookie, so no token handling is needed.

### `GET /api/v1/alerts`

Requires a session. Active threshold alerts:

```json
{"alerts": [{"kind": "disk_high", "title": "Disk nearly full", "subject": "/mnt/media",
             "level": "warn", "value": 85.0, "since": 1794221629}]}
```

| Alert | Raised at | Cleared below |
| --- | --- | --- |
| `cpu_high` | 90% for 5 samples in a row | 80% |
| `memory_high` | 90% used (crit at 95%) | 85% |
| `swap_high` | 50% used, only if swap exists | 40% |
| `disk_high`, per mount | 85% used (crit at 95%) | 82% |
| `temperature_high`, per sensor | 80 °C (crit at 90 °C) | 75 °C |

The gap between raise and clear levels is deliberate, so a reading hovering at
the line does not flap. An alert for a drive that is unplugged is cleared.
Raised, escalated and cleared alerts are written to the audit log as actor
`system` and to the process log. The same list arrives on the stream as an
`alerts` event whenever it changes. Thresholds are fixed for now.

### `GET /api/v1/update`

Requires a session. Whether a newer release exists, as last seen by the
background check:

```json
{"current": "0.1.0", "enabled": true, "checked": 1794216317, "failed": false,
 "available": true, "latest": "v0.2.0", "page": "https://github.com/...",
 "command": "sudo nodos update"}
```

`enabled` is false when the config has `update_check = false`. `failed` means
the last attempt could not reach the release server; an earlier good answer is
kept. `checked` is 0 until the first check, which runs 30 seconds after the
server starts. This endpoint only reports: nothing in the web interface can
install an update.

### `GET /api/v1/audit?limit=N`

Admin only. The newest audit entries first, `limit` 1 to 200 (default 100):
`{"entries":[{"ts","actor","action","target","ok","ip"}]}`. Reads the tail of
`audit.log`, so very old entries need the file itself.

### Services (systemd)

Shows and controls the units named in the config's `services` line, through
`systemctl` and `journalctl` with fixed arguments. No shell is involved.

| Route | Who | Notes |
| --- | --- | --- |
| `GET /api/v1/services` | any signed-in user | `{"services":[{unit,description,load,active,sub,pid}]}` for every configured unit |
| `GET /api/v1/services/{unit}/logs?tail=N` | admin | Journal lines, same shape as Docker logs |
| `POST /api/v1/services/{unit}/start`, `stop`, `restart` | admin, CSRF | Audited as `service.start` and so on, target is the unit |

A unit that is not in the allowlist answers 404 whatever it looks like, and so
does any verb other than the three above (`mask`, `disable`, `kill` and the
rest never run). `load: "not-found"` means the unit is listed but not
installed.

NodOS runs unprivileged, so starting and stopping needs permission from the OS.
When systemd refuses, the answer is 502 with systemd's own message, for example
`systemd refused: Interactive authentication required.` That is a polkit
question; see the installation guide for a rule scoped to just your units.
503 means no services are configured or systemd is missing, 504 means systemd
did not answer within 10 seconds.

### Docker

Talks to the Docker Engine over its Unix socket (`docker_socket` in the
config). Access to that socket is root-equivalent on the host, so these routes
are the most tightly gated in NodOS.

| Route | Who | Notes |
| --- | --- | --- |
| `GET /api/v1/docker/containers` | any signed-in user | `{"total","containers":[{id,name,image,state,status,created}]}`. First 64 containers; compare `total` |
| `GET /api/v1/docker/containers/{ref}/logs?tail=N` | admin | `{"lines":[...],"truncated"}`. `tail` is 1 to 500, default 100 |
| `POST /api/v1/docker/containers/{ref}/start` | admin, CSRF | |
| `POST /api/v1/docker/containers/{ref}/stop` | admin, CSRF | 10 second grace period |
| `POST /api/v1/docker/containers/{ref}/restart` | admin, CSRF | 10 second grace period |

`{ref}` is a container id or name: 1 to 64 characters of letters, digits, `_`,
`.` and `-`, starting with a letter or digit. Anything else is a 400. Only the
three verbs above exist; `kill`, `rm`, `exec` and the rest answer 404 and never
reach Docker. There is no endpoint that takes a command.

Actions answer `{"ok":true,"result":"done"}` or `"unchanged"` (already in that
state). Every action is written to the audit log with the container as target.

| Status | Meaning |
| --- | --- |
| 403 | Not an admin, or CSRF token missing or wrong |
| 404 | No such container, or not a supported verb |
| 502 | Docker answered with something unexpected |
| 503 | Docker is turned off in the config, or the socket is not reachable |

## Errors

Errors are `{"error": "message"}` with a matching HTTP status. A `POST` with no
`Content-Length` or `Transfer-Encoding` gets 411.
