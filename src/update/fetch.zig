//! One-shot HTTP(S) GET into memory, with a size cap and a deadline.
//!
//! This is the only code in NodOS that talks to the internet. It is used by
//! the update check and the updater, nothing else, and it sends nothing about
//! the machine: a User-Agent of "nodos/<version>" and the request itself.
//!
//! Anything it returns is untrusted until `verify.zig` has checked a signature.
const std = @import("std");
const Io = std.Io;
const release = @import("release.zig");
const version = @import("build_options").version;

pub const Error = error{
    /// URL is not https (or http to this machine).
    UrlNotAllowed,
    Unreachable,
    TimedOut,
    TooLarge,
    /// The server answered, with something other than 200.
    BadStatus,
    OutOfMemory,
};

pub const Fetched = struct {
    status: u16,
    body: []u8,
};

/// `arena` owns the body. `max_bytes` is a hard cap: a server that keeps
/// sending gets cut off instead of filling memory.
pub fn get(arena: std.mem.Allocator, io: Io, url: []const u8, max_bytes: usize, timeout_ms: u32) Error!Fetched {
    if (!release.urlAllowed(url)) return error.UrlNotAllowed;

    const Race = union(enum) {
        reply: Error!Fetched,
        timer: Io.Cancelable!void,
    };
    var slots: [2]Race = undefined;
    var sel: Io.Select(Race) = .init(io, &slots);
    sel.concurrent(.reply, exchange, .{ arena, io, url, max_bytes }) catch return error.Unreachable;
    sel.concurrent(.timer, sleepMs, .{ io, timeout_ms }) catch {
        sel.cancelDiscard();
        return error.Unreachable;
    };
    const first = sel.await() catch {
        sel.cancelDiscard();
        return error.Unreachable;
    };
    sel.cancelDiscard();
    return switch (first) {
        .reply => |r| r,
        .timer => error.TimedOut,
    };
}

fn sleepMs(io: Io, ms: u32) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(ms), .awake);
}

fn exchange(arena: std.mem.Allocator, io: Io, url: []const u8, max_bytes: usize) Error!Fetched {
    // The buffer is the cap: writing past it fails, which we report as TooLarge.
    const buf = try arena.alloc(u8, max_bytes);
    var w: Io.Writer = .fixed(buf);

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var ua_buf: [64]u8 = undefined;
    const ua = std.fmt.bufPrint(&ua_buf, "nodos/{s}", .{version}) catch "nodos";

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &w,
        .headers = .{ .user_agent = .{ .override = ua } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/vnd.github+json, application/octet-stream, */*" }},
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.TooLarge,
        else => return error.Unreachable,
    };
    const code: u16 = @backingInt(result.status);
    if (code != 200) return .{ .status = code, .body = buf[0..0] };
    return .{ .status = code, .body = w.buffered() };
}

/// GET that treats anything but 200 as an error.
pub fn getOk(arena: std.mem.Allocator, io: Io, url: []const u8, max_bytes: usize, timeout_ms: u32) Error![]u8 {
    const r = try get(arena, io, url, max_bytes, timeout_ms);
    if (r.status != 200) return error.BadStatus;
    return r.body;
}

// ---------------------------------------------------------------- tests

fn tinyServer(io: Io, server: *Io.net.Server, response: []const u8, hang: bool) Io.Cancelable!void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [2048]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    while (true) {
        const l = r.interface.takeDelimiter('\n') catch return;
        if (l == null or std.mem.trim(u8, l.?, "\r").len == 0) break;
    }
    if (hang) return io.sleep(.fromSeconds(30), .awake);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(response) catch return;
    w.interface.flush() catch return;
}

fn listenLocal(io: Io) !struct { server: Io.net.Server, port: u16 } {
    var bytes: [2]u8 = undefined;
    io.random(&bytes);
    // Pick from the dynamic range and retry on collision.
    var attempt: u16 = 0;
    while (attempt < 20) : (attempt += 1) {
        const port: u16 = 20000 + (std.mem.readInt(u16, &bytes, .little) +% attempt *% 7919) % 30000;
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        if (addr.listen(io, .{ .reuse_address = true })) |s| return .{ .server = s, .port = port } else |_| continue;
    }
    return error.SkipZigTest;
}

test "fetch reads a small body over loopback http" {
    const io = std.testing.io;
    var l = try listenLocal(io);
    defer l.server.deinit(io);
    var fut = io.async(tinyServer, .{ io, &l.server, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello", false });
    defer fut.cancel(io) catch {};

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{l.port});
    const body = try getOk(arena.allocator(), io, url, 1024, 5000);
    try std.testing.expectEqualStrings("hello", body);
}

test "a body over the cap is refused, not buffered" {
    const io = std.testing.io;
    var l = try listenLocal(io);
    defer l.server.deinit(io);
    var fut = io.async(tinyServer, .{ io, &l.server, "HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\n01234567890123456789", false });
    defer fut.cancel(io) catch {};

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{l.port});
    try std.testing.expectError(error.TooLarge, getOk(arena.allocator(), io, url, 8, 5000));
}

test "non-200 and silent servers" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var url_buf: [64]u8 = undefined;

    {
        var l = try listenLocal(io);
        defer l.server.deinit(io);
        var fut = io.async(tinyServer, .{ io, &l.server, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", false });
        defer fut.cancel(io) catch {};
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{l.port});
        try std.testing.expectError(error.BadStatus, getOk(arena.allocator(), io, url, 1024, 5000));
    }
    {
        var l = try listenLocal(io);
        defer l.server.deinit(io);
        var fut = io.async(tinyServer, .{ io, &l.server, "", true });
        defer fut.cancel(io) catch {};
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{l.port});
        const started = Io.Timestamp.now(io, .awake);
        try std.testing.expectError(error.TimedOut, getOk(arena.allocator(), io, url, 1024, 300));
        try std.testing.expect(started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds() < 5000);
    }
}

test "urls that are not allowed never leave the machine" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UrlNotAllowed, get(arena.allocator(), io, "http://example.com/x", 10, 100));
    try std.testing.expectError(error.UrlNotAllowed, get(arena.allocator(), io, "file:///etc/passwd", 10, 100));
    try std.testing.expectError(error.UrlNotAllowed, get(arena.allocator(), io, "", 10, 100));
}
