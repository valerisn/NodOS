# Performance measurements

Numbers here were measured, with the method noted. Anything without a
measurement is a target, not a claim. Re-measure when the code changes enough
to matter.

## Binary size

Measured with `zig build -Dtarget=<t> -Doptimize=<mode> -Dstrip=true`, Zig 0.17.0,
cross-compiled from Windows, 2026-11-09. Includes the embedded dashboard.

| Target | ReleaseSafe | ReleaseSmall |
| --- | --- | --- |
| x86_64-linux-musl | 0.67 MB | 0.37 MB |
| aarch64-linux-musl | 0.57 MB | 0.36 MB |

Unstripped Linux builds were 5.0 to 5.2 MB, almost all debug info. Release
builds pass `-Dstrip=true`. Budget in the architecture doc: under 5 MB.

## Memory

Debug build, synthetic host (`-Dfake-host=true`), Windows, one dashboard tab
streaming plus a few curl requests: about 8 MB working set. This is a Debug
build on Windows, so treat it as an upper bound for the shape of the thing, not
as the Linux release figure. Budget: under 20 MB idle. Not yet measured on
Linux, release mode.

## Not yet measured

- API latency under load (the curl loops used so far are dominated by process
  start-up and say nothing about the server)
- CPU use at idle on Linux, and sampler cost per tick
- Many simultaneous SSE connections
- Behavior at the 256 connection cap

These need a Linux box and a proper load tool. They block the first release.
