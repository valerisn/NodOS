//! Graceful shutdown on SIGINT/SIGTERM.
//!
//! The handler does one async-signal-safe thing: shutdown(2) on the listening
//! socket. That makes the blocked accept() return SocketNotListening, and the
//! normal return path in server.run tears everything down. No flags, no
//! polling, no allocation in signal context.
//!
//! Linux only for now. Elsewhere Ctrl-C kills the process, which is fine for a
//! dev box. Untested on a real Linux machine at the time of writing; the CI
//! smoke test (scripts/smoke.sh) is what actually proves this works.
const std = @import("std");
const builtin = @import("builtin");

const supported = builtin.os.tag == .linux;

var listen_fd: std.atomic.Value(i32) = .init(-1);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    const fd = listen_fd.load(.monotonic);
    if (fd >= 0) _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.RDWR);
}

/// Returns false when this platform has no handler, so the caller can say so.
pub fn installShutdown(listener_fd: i32) bool {
    if (!supported) return false;
    listen_fd.store(listener_fd, .monotonic);
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
    return true;
}
