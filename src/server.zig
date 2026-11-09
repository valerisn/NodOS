//! HTTP front door. Built on std.http.Server over std.Io streams, one task
//! per connection. Routing is a pure function so it can be tested without
//! opening a socket.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const config = @import("config.zig");
const version = @import("build_options").version;

const log = std.log.scoped(.server);

/// Hard cap on simultaneous connections. A home box does not need more, and
/// every connection costs a task plus 16 KB of buffers.
const max_connections = 256;

// TODO: no read timeouts yet, so a client that opens a socket and goes quiet
// holds a slot forever. Fix before auth ships, this is a slowloris gift.

pub const Reply = struct {
    status: http.Status,
    content_type: []const u8 = "application/json",
    body: []const u8,
};

/// `buf` backs any formatted body; the returned Reply may point into it.
pub fn route(method: http.Method, target: []const u8, buf: []u8) Reply {
    const path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;

    if (std.mem.eql(u8, path, "/api/v1/health")) {
        if (method != .GET and method != .HEAD) return .{ .status = .method_not_allowed, .body = "{\"error\":\"method not allowed\"}" };
        const body = std.fmt.bufPrint(buf, "{{\"status\":\"ok\",\"version\":\"{s}\"}}", .{version}) catch
            return .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };
        return .{ .status = .ok, .body = body };
    }
    return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
}

// Sent on every response. The dashboard is same-origin only, so the CSP can
// be strict from day one; loosening later is easy, tightening is not.
const security_headers = [_]http.Header{
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "content-security-policy", .value = "default-src 'self'; frame-ancestors 'none'" },
};

pub fn run(io: Io, cfg: config.Config) !void {
    const addr = try Io.net.IpAddress.parse(cfg.listen, cfg.port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    log.info("listening on {s}:{d}", .{ cfg.listen, cfg.port });

    var group: Io.Group = .init;
    defer group.cancel(io);
    var active: std.atomic.Value(u32) = .init(0);

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                log.warn("accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        if (active.fetchAdd(1, .acq_rel) >= max_connections) {
            _ = active.fetchSub(1, .acq_rel);
            stream.close(io);
            log.warn("connection limit reached, dropping client", .{});
            continue;
        }
        group.concurrent(io, serveConnection, .{ io, stream, &active }) catch {
            _ = active.fetchSub(1, .acq_rel);
            stream.close(io);
            log.warn("could not start connection task", .{});
        };
    }
}

fn serveConnection(io: Io, stream: Io.net.Stream, active: *std.atomic.Value(u32)) Io.Cancelable!void {
    defer _ = active.fetchSub(1, .acq_rel);
    defer stream.close(io);

    var in_buf: [8192]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var srv = http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var req = srv.receiveHead() catch |err| {
            // Closed connections and garbage are routine, not worth a warning.
            log.debug("receiveHead: {s}", .{@errorName(err)});
            return;
        };
        var body_buf: [256]u8 = undefined;
        const framed = bodyFramingValid(req.head.method, req.head.transfer_encoding, req.head.content_length);
        const reply: Reply = if (framed)
            route(req.head.method, req.head.target, &body_buf)
        else
            .{ .status = .length_required, .body = "{\"error\":\"length required\"}" };
        const keep_alive = req.head.keep_alive and framed;
        const headers = security_headers ++ [_]http.Header{.{ .name = "content-type", .value = reply.content_type }};
        req.respond(reply.body, .{
            .status = reply.status,
            .extra_headers = &headers,
            .keep_alive = keep_alive,
        }) catch |err| {
            log.debug("respond: {s}", .{@errorName(err)});
            return;
        };
        if (!keep_alive) return;
    }
}

/// std.http.Server asserts (crashes the whole process) when a POST/PUT shows up
/// with neither Content-Length nor Transfer-Encoding, found by smoke test on
/// 0.17.0. Any client could kill the server, so we reject it ourselves first.
/// Remove once upstream returns an error instead.
fn bodyFramingValid(method: http.Method, te: http.TransferEncoding, content_length: ?u64) bool {
    if (!method.requestHasBody()) return true;
    return te != .none or content_length != null;
}

test "body framing guard" {
    try std.testing.expect(bodyFramingValid(.GET, .none, null));
    try std.testing.expect(!bodyFramingValid(.POST, .none, null));
    try std.testing.expect(bodyFramingValid(.POST, .none, 0));
    try std.testing.expect(bodyFramingValid(.POST, .chunked, null));
}

test "health route" {
    var buf: [256]u8 = undefined;
    const r = route(.GET, "/api/v1/health?x=1", &buf);
    try std.testing.expectEqual(http.Status.ok, r.status);
    try std.testing.expect(std.mem.startsWith(u8, r.body, "{\"status\":\"ok\""));
}

test "unknown path and wrong method" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(http.Status.not_found, route(.GET, "/nope", &buf).status);
    try std.testing.expectEqual(http.Status.method_not_allowed, route(.POST, "/api/v1/health", &buf).status);
}
