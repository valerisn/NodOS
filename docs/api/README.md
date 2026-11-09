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

## Errors

Errors are `{"error": "message"}` with a matching HTTP status. A `POST` with no
`Content-Length` or `Transfer-Encoding` gets 411.
