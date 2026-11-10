const std = @import("std");
const builtin = @import("builtin");

const supported = builtin.os.tag == .linux;

var listen_fd: std.atomic.Value(i32) = .init(-1);

// only async-signal-safe thing in here: shutdown() the listener so accept() returns
fn onSignal(_: std.posix.SIG) callconv(.c) void {
    const fd = listen_fd.load(.monotonic);
    if (fd >= 0) _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.RDWR);
}

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
