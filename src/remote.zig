const std = @import("std");
const Io = std.Io;
const servers = @import("servers.zig");
const version = @import("build_options").version;

pub const Error = error{ Unreachable, TimedOut, TooLarge, BadTarget, OutOfMemory };

pub const Result = struct {
    status: u16,
    body: []const u8,
};

pub const timeout_ms: u32 = 12_000;

/// Paths a viewer may read on another server. Anything not listed needs an
/// administrator, because the hub uses an admin token for every request and
/// must not hand that power to a viewer.
pub fn viewerMayRead(sub: []const u8) bool {
    const exact = [_][]const u8{ "/system", "/history", "/alerts", "/storage-health", "/update", "/apps", "/services", "/docker/containers", "/docker/images" };
    for (exact) |e| if (std.mem.eql(u8, sub, e)) return true;
    if (std.mem.startsWith(u8, sub, "/docker/containers/") and std.mem.endsWith(u8, sub, "/stats")) {
        const mid = sub["/docker/containers/".len .. sub.len - "/stats".len];
        return mid.len > 0 and std.mem.findScalar(u8, mid, '/') == null;
    }
    return false;
}

/// Paths that must never be forwarded: they belong to this server's own
/// sessions or would let a hub chain through another hub.
pub fn blocked(sub: []const u8) bool {
    const names = [_][]const u8{ "/login", "/logout", "/remote", "/servers", "/stream", "/me" };
    for (names) |n| {
        if (std.mem.eql(u8, sub, n)) return true;
        if (std.mem.startsWith(u8, sub, n) and sub.len > n.len and sub[n.len] == '/') return true;
    }
    return false;
}

pub fn validSub(sub: []const u8) bool {
    if (sub.len < 2 or sub.len > 100 or sub[0] != '/') return false;
    for (sub) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.')) return false;
    }
    return std.mem.find(u8, sub, "..") == null and std.mem.find(u8, sub, "//") == null;
}

pub fn validQuery(q: []const u8) bool {
    if (q.len > 64) return false;
    for (q) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '=' or c == '&' or c == '-' or c == '_' or c == '.' or c == '%')) return false;
    }
    return true;
}

pub fn forward(arena: std.mem.Allocator, io: Io, srv: servers.Server, method: std.http.Method, sub: []const u8, query: []const u8, payload: ?[]const u8, max_bytes: usize) Error!Result {
    if (!validSub(sub) or !validQuery(query)) return error.BadTarget;
    const url = if (query.len > 0)
        try std.fmt.allocPrint(arena, "{s}/api/v1{s}?{s}", .{ srv.url, sub, query })
    else
        try std.fmt.allocPrint(arena, "{s}/api/v1{s}", .{ srv.url, sub });
    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{srv.token});

    const Race = union(enum) { reply: Error!Result, timer: Io.Cancelable!void };
    var slots: [2]Race = undefined;
    var sel: Io.Select(Race) = .init(io, &slots);
    sel.concurrent(.reply, exchange, .{ arena, io, url, bearer, method, payload, max_bytes }) catch return error.Unreachable;
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

fn exchange(arena: std.mem.Allocator, io: Io, url: []const u8, bearer: []const u8, method: std.http.Method, payload: ?[]const u8, max_bytes: usize) Error!Result {
    const buf = try arena.alloc(u8, max_bytes);
    var w: Io.Writer = .fixed(buf);

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var ua_buf: [64]u8 = undefined;
    const ua = std.fmt.bufPrint(&ua_buf, "nodos-hub/{s}", .{version}) catch "nodos-hub";

    // a redirect would carry the token to wherever it points, so none is followed
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .redirect_behavior = .not_allowed,
        .response_writer = &w,
        .headers = .{
            .user_agent = .{ .override = ua },
            .authorization = .{ .override = bearer },
            .content_type = if (payload != null) .{ .override = "application/json" } else .default,
        },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.TooLarge,
        else => return error.Unreachable,
    };
    return .{ .status = @backingInt(result.status), .body = w.buffered() };
}

test "viewers may only read the harmless paths" {
    try std.testing.expect(viewerMayRead("/system"));
    try std.testing.expect(viewerMayRead("/docker/containers"));
    try std.testing.expect(viewerMayRead("/docker/containers/web/stats"));
    try std.testing.expect(!viewerMayRead("/docker/containers/web/logs"));
    try std.testing.expect(!viewerMayRead("/docker/containers/a/b/stats"));
    try std.testing.expect(!viewerMayRead("/docker/containers//stats"));
    try std.testing.expect(!viewerMayRead("/audit"));
    try std.testing.expect(!viewerMayRead("/settings"));
    try std.testing.expect(!viewerMayRead("/apps/jobs"));
    try std.testing.expect(!viewerMayRead("/services/ssh/logs"));
    try std.testing.expect(!viewerMayRead("/systemx"));
}

test "blocked paths and path shape" {
    try std.testing.expect(blocked("/login"));
    try std.testing.expect(blocked("/remote/other/system"));
    try std.testing.expect(blocked("/stream"));
    try std.testing.expect(blocked("/servers"));
    try std.testing.expect(!blocked("/system"));
    try std.testing.expect(!blocked("/streams"));
    try std.testing.expect(validSub("/docker/containers/web/logs"));
    try std.testing.expect(!validSub("/a/../b"));
    try std.testing.expect(!validSub("/a//b"));
    try std.testing.expect(!validSub("/a b"));
    try std.testing.expect(!validSub("/a?b=1"));
    try std.testing.expect(!validSub("system"));
    try std.testing.expect(validQuery("tail=200"));
    try std.testing.expect(!validQuery("a=b c"));
    try std.testing.expect(!validQuery("x=\r\nHost: evil"));
}

fn tinyHub(io: Io, server: *Io.net.Server, seen: []u8, got: *usize, reply: []const u8) Io.Cancelable!void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var len: usize = 0;
    var content_len: usize = 0;
    while (true) {
        const l = r.interface.takeDelimiter('\n') catch return;
        const line = l orelse break;
        const t = std.mem.trim(u8, line, "\r");
        if (t.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(t, "content-length:")) content_len = std.fmt.parseInt(usize, std.mem.trim(u8, t["content-length:".len..], " "), 10) catch 0;
        if (len + t.len + 1 <= seen.len) {
            @memcpy(seen[len..][0..t.len], t);
            seen[len + t.len] = '\n';
            len += t.len + 1;
        }
    }
    var left = content_len;
    while (left > 0 and len < seen.len) {
        const b = r.interface.takeByte() catch break;
        seen[len] = b;
        len += 1;
        left -= 1;
    }
    got.* = len;
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(reply) catch return;
    w.interface.flush() catch return;
}

fn listenLocal(io: Io) !struct { server: Io.net.Server, port: u16 } {
    var bytes: [2]u8 = undefined;
    io.random(&bytes);
    var attempt: u16 = 0;
    while (attempt < 20) : (attempt += 1) {
        const port: u16 = 20000 + (std.mem.readInt(u16, &bytes, .little) +% attempt *% 7919) % 30000;
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        if (addr.listen(io, .{ .reuse_address = true })) |s| return .{ .server = s, .port = port } else |_| continue;
    }
    return error.SkipZigTest;
}

test "forward sends the bearer token and returns status and body" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var l = try listenLocal(io);
    defer l.server.deinit(io);
    var seen: [4096]u8 = undefined;
    var got: usize = 0;
    var fut = io.async(tinyHub, .{ io, &l.server, &seen, &got, "HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"ok\":true}\n" });
    defer fut.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{l.port});
    const srv: servers.Server = .{ .name = "t", .url = url, .token = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ" };
    const r = try forward(arena.allocator(), io, srv, .GET, "/system", "tail=5", null, 4096);
    try fut.await(io);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", r.body);
    const req = seen[0..got];
    try std.testing.expect(std.mem.startsWith(u8, req, "GET /api/v1/system?tail=5"));
    try std.testing.expect(std.ascii.findIgnoreCase(req, "authorization: Bearer abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ") != null);
}

test "forward refuses to follow a redirect, so the token goes nowhere else" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var l = try listenLocal(io);
    defer l.server.deinit(io);
    var seen: [4096]u8 = undefined;
    var got: usize = 0;
    var fut = io.async(tinyHub, .{ io, &l.server, &seen, &got, "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/steal\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" });
    defer fut.cancel(io) catch {};
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{l.port});
    const srv: servers.Server = .{ .name = "t", .url = url, .token = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ" };
    const r = forward(arena.allocator(), io, srv, .GET, "/system", "", null, 4096);
    if (r) |ok| {
        try std.testing.expect(ok.status == 302);
    } else |err| {
        try std.testing.expect(err == error.Unreachable);
    }
}

test "forward reports an unreachable server" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var l = try listenLocal(io);
    const port = l.port;
    l.server.deinit(io);
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{port});
    const srv: servers.Server = .{ .name = "t", .url = url, .token = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ" };
    try std.testing.expectError(error.Unreachable, forward(arena.allocator(), io, srv, .GET, "/system", "", null, 4096));
    try std.testing.expectError(error.BadTarget, forward(arena.allocator(), io, srv, .GET, "/a/../b", "", null, 4096));
}
