# Performance measurements

Numbers here were measured, with the method noted. Anything without a
measurement says so. Re-measure when the code changes enough to matter.

## On Linux (the target)

Measured by the CI job "Install as a service (linux)": the real release binary
(`ReleaseSafe`, stripped), installed with `scripts/install.sh` and running under
the hardened systemd unit, on a GitHub-hosted Ubuntu runner (a shared 4 vCPU
VM, so treat the numbers as indicative, not as a benchmark). The step prints
the table to the job summary on every run, so it stays current.

First recorded run, 2026-11-09:

| Measure | Result | Budget |
| --- | --- | --- |
| Binary size | 782 KB | under 5 MB |
| Idle RSS | 2.3 MB | under 20 MB |
| Idle CPU (2 s sampling) | 0.1% of one core | under 1% |
| `GET /api/v1/health`, new connection each, p50 / p99 | 0.11 ms / 0.17 ms | p99 under 10 ms |
| `GET /api/v1/system` (authenticated), p50 / p99 | 0.13 ms / 0.28 ms | p99 under 10 ms |
| RSS after 1000 requests | 2.3 MB (no growth) | |
| RSS with 16 live streams (the cap) | 8.1 MB | |
| CPU with 16 live streams | below the measurement resolution | |

Latency is curl's own `time_total` against loopback, 500 requests each, so it
includes connection setup but not process start-up.

### Connection flood

The smoke test (`scripts/flood_check.py`) opens 820 idle connections against
the 256 slot cap and never closes them, while continuing to knock like a real
attacker. On the CI runner:

- The server stayed up and logged `connection limit reached` for every
  connection past the cap.
- A health request failed while the flood was held (saturation confirmed).
- The idle cutoff freed the slots by itself and the server answered again about
  10 seconds later, with every attacker socket still open.

So an idle-connection flood denies service for at most the 15 second idle limit
plus the reaper tick, and only for as long as the attacker keeps reconnecting.
That is a real, bounded availability weakness of a 256 slot design; the answer
is a rate limit at the reverse proxy.

## On Windows (development only)

Not a supported monitoring platform. Observed with a Debug build: about 8 MB
working set with a dashboard tab streaming, 40 MB with 260 threads during a
connection flood.

One behavioral difference found by that flood test: on Windows the idle cutoff
closes the client's side of a connection but the server's handler thread stays
blocked until the client lets go (a socket `shutdown` does not wake a blocked
read there), so slots are not reclaimed. Linux does not have the problem, which
is what the smoke test proves. Fixing it for Windows would mean racing every
connection against a timer as the Docker client does; not worth two threads per
connection on the platform that matters.

## Binary size history

Stripped, cross-compiled from Windows, 2026-11-09:

| Target | ReleaseSafe | ReleaseSmall |
| --- | --- | --- |
| x86_64-linux-musl | 0.67 MB (at the time, before Docker and systemd) | 0.37 MB |
| aarch64-linux-musl | 0.57 MB | 0.36 MB |

Unstripped Linux builds are 5 MB or more, nearly all debug info; release builds
pass `-Dstrip=true`.

## Not yet measured

- Long soak: memory growth over days. Nothing in the design should grow (the
  history ring, sessions, limiter and alert tables are all capped), but that is
  an argument, not a measurement.
- Behavior on real home hardware: a Raspberry Pi class device, spinning disks,
  many containers.
- Many authenticated users at once, and the cost of argon2id on slow CPUs
  (19 MiB, two passes, per login; the login throttle bounds how often).
- The frontend: first paint and chart redraw cost on low-end devices.
