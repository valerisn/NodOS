//! HTTP front door. Built on std.http.Server over std.Io streams, one task
//! per connection. Request handling is `dispatch`, a function of plain values,
//! so the auth flow is testable without opening a socket.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const config = @import("config.zig");
const auth = @import("auth.zig");
const users_mod = @import("users.zig");
const ratelimit = @import("ratelimit.zig");
const audit = @import("audit.zig");
const version = @import("build_options").version;

const log = std.log.scoped(.server);

/// Hard cap on simultaneous connections. A home box does not need more, and
/// every connection costs a task plus 16 KB of buffers.
const max_connections = 256;

/// API bodies are tiny JSON. Anything bigger is a mistake or an attack.
const max_body = 1024;

const cookie_name = "nodos_session";
const csrf_header = "x-csrf-token";

pub const App = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    users: users_mod.Users,
    sessions: auth.SessionStore = .{},
    limiter: ratelimit.Limiter = .{},
    /// Null in tests.
    audit_log: ?audit.Log = null,
    /// A real hash of a throwaway password, verified against when the
    /// username doesn't exist, so "no such user" costs the same time as
    /// "wrong password" and can't be used to enumerate accounts.
    dummy_phc: [auth.hash_buf_len]u8 = undefined,
    dummy_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, cfg: config.Config, users: users_mod.Users) !App {
        var app: App = .{ .gpa = gpa, .cfg = cfg, .users = users };
        var pw: [24]u8 = undefined;
        try io.randomSecure(&pw);
        // hashPassword wants printable-length input; raw bytes are fine for argon2.
        const phc = try auth.hashPassword(gpa, io, &pw, &app.dummy_phc);
        app.dummy_len = phc.len;
        return app;
    }

    pub fn deinit(app: *App, io: Io) void {
        app.sessions.deinit(app.gpa);
        app.limiter.deinit(app.gpa);
        if (app.audit_log) |*a| a.close(io);
    }

    fn record(app: *App, io: Io, now_s: i64, actor: []const u8, action: []const u8, ok: bool, ip: []const u8) void {
        if (app.audit_log) |*a| a.record(io, .{ .ts = now_s, .actor = actor, .action = action, .ok = ok, .ip = ip });
    }
};

pub const Reply = struct {
    status: http.Status,
    content_type: []const u8 = "application/json",
    body: []const u8,
    set_cookie: ?[]const u8 = null,
};

/// Everything dispatch needs from the request, copied out before the body
/// reader invalidates the header strings.
pub const Ctx = struct {
    method: http.Method,
    path: []const u8,
    cookie_token: ?[43]u8 = null,
    csrf: ?[43]u8 = null,
    client: ratelimit.Key,
    ip_text: []const u8,
    now_s: i64,
};

/// Per-request scratch the Reply may point into.
pub const Scratch = struct {
    body: [512]u8 = undefined,
    cookie: [192]u8 = undefined,
};

const err_not_found: Reply = .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
const err_method: Reply = .{ .status = .method_not_allowed, .body = "{\"error\":\"method not allowed\"}" };
const err_unauth: Reply = .{ .status = .unauthorized, .body = "{\"error\":\"unauthorized\"}" };
const err_forbidden: Reply = .{ .status = .forbidden, .body = "{\"error\":\"forbidden\"}" };
const err_bad: Reply = .{ .status = .bad_request, .body = "{\"error\":\"bad request\"}" };
const err_internal: Reply = .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };

pub fn dispatch(app: *App, io: Io, ctx: Ctx, body: []const u8, s: *Scratch) Reply {
    const get = ctx.method == .GET or ctx.method == .HEAD;

    if (std.mem.eql(u8, ctx.path, "/api/v1/health")) {
        if (!get) return err_method;
        const b = std.fmt.bufPrint(&s.body, "{{\"status\":\"ok\",\"version\":\"{s}\"}}", .{version}) catch return err_internal;
        return .{ .status = .ok, .body = b };
    }
    if (std.mem.eql(u8, ctx.path, "/api/v1/login")) {
        if (ctx.method != .POST) return err_method;
        return login(app, io, ctx, body, s);
    }
    if (std.mem.eql(u8, ctx.path, "/api/v1/me")) {
        if (!get) return err_method;
        const sess = currentSession(app, io, ctx) orelse return err_unauth;
        return sessionInfo(app, sess, ctx, s);
    }
    if (std.mem.eql(u8, ctx.path, "/api/v1/logout")) {
        if (ctx.method != .POST) return err_method;
        const sess = currentSession(app, io, ctx) orelse return err_unauth;
        if (!csrfOk(sess, ctx)) return err_forbidden;
        app.sessions.destroy(io, &ctx.cookie_token.?);
        app.record(io, ctx.now_s, userName(app, sess), "auth.logout", true, ctx.ip_text);
        return .{ .status = .ok, .body = "{\"ok\":true}", .set_cookie = cookie(app, s, "", 0) };
    }
    return err_not_found;
}

fn login(app: *App, io: Io, ctx: Ctx, body: []const u8, s: *Scratch) Reply {
    if (!app.limiter.allow(io, ctx.client, ctx.now_s)) {
        app.record(io, ctx.now_s, "-", "auth.login.throttled", false, ctx.ip_text);
        return .{ .status = .too_many_requests, .body = "{\"error\":\"too many attempts, try again later\"}" };
    }

    var fba_buf: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const Creds = struct { username: []const u8, password: []const u8 };
    const creds = std.json.parseFromSliceLeaky(Creds, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch return err_bad;

    const user = app.users.find(creds.username);
    const phc: []const u8 = if (user) |u| u.phc else app.dummy_phc[0..app.dummy_len];
    const matched = auth.verifyPassword(app.gpa, io, phc, creds.password);

    if (!matched or user == null) {
        app.limiter.recordFailure(app.gpa, io, ctx.client, ctx.now_s);
        // Log what was typed only if it is a legal username; otherwise a
        // password pasted into the username box would land in the audit log.
        const who = if (users_mod.validName(creds.username)) creds.username else "-";
        app.record(io, ctx.now_s, who, "auth.login", false, ctx.ip_text);
        return .{ .status = .unauthorized, .body = "{\"error\":\"invalid credentials\"}" };
    }

    app.limiter.reset(io, ctx.client);
    const issued = app.sessions.create(app.gpa, io, user.?.id, user.?.role, ctx.now_s) catch |err| {
        log.err("session create failed: {s}", .{@errorName(err)});
        return err_internal;
    };
    app.record(io, ctx.now_s, user.?.name, "auth.login", true, ctx.ip_text);
    const b = std.fmt.bufPrint(&s.body, "{{\"username\":\"{s}\",\"role\":\"{s}\",\"csrf\":\"{s}\"}}", .{ user.?.name, @tagName(user.?.role), &issued.csrf }) catch return err_internal;
    return .{ .status = .ok, .body = b, .set_cookie = cookie(app, s, &issued.token, auth.SessionStore.absolute_ttl_s) };
}

fn sessionInfo(app: *App, sess: auth.Session, ctx: Ctx, s: *Scratch) Reply {
    _ = ctx;
    var csrf: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&csrf, &sess.csrf);
    const b = std.fmt.bufPrint(&s.body, "{{\"username\":\"{s}\",\"role\":\"{s}\",\"csrf\":\"{s}\"}}", .{ userName(app, sess), @tagName(sess.role), &csrf }) catch return err_internal;
    return .{ .status = .ok, .body = b };
}

fn userName(app: *App, sess: auth.Session) []const u8 {
    for (app.users.list.items) |u| if (u.id == sess.user_id) return u.name;
    return "-";
}

fn currentSession(app: *App, io: Io, ctx: Ctx) ?auth.Session {
    const tok = ctx.cookie_token orelse return null;
    return app.sessions.lookup(io, &tok, ctx.now_s);
}

fn csrfOk(sess: auth.Session, ctx: Ctx) bool {
    const presented = ctx.csrf orelse return false;
    return auth.SessionStore.csrfMatches(sess, &presented);
}

/// Strict, HttpOnly, and Secure unless the admin opted out for plain-HTTP LANs.
fn cookie(app: *App, s: *Scratch, token: []const u8, max_age: i64) ?[]const u8 {
    const secure = if (app.cfg.secure_cookies) "; Secure" else "";
    return std.fmt.bufPrint(&s.cookie, "{s}={s}; HttpOnly; SameSite=Strict; Path=/; Max-Age={d}{s}", .{ cookie_name, token, max_age, secure }) catch null;
}

/// Finds `name` in a Cookie header value. Exact name match only.
pub fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, header, ";");
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        const eq = std.mem.findScalar(u8, p, '=') orelse continue;
        if (std.mem.eql(u8, p[0..eq], name)) return p[eq + 1 ..];
    }
    return null;
}

/// "1.2.3.4:5555" -> "1.2.3.4", "[::1]:5555" -> "::1". The audit log wants
/// the address, not the client's ephemeral port.
fn stripPort(s: []const u8) []const u8 {
    if (s.len > 0 and s[0] == '[') {
        const end = std.mem.findScalar(u8, s, ']') orelse return s;
        return s[1..end];
    }
    const colon = std.mem.findScalarLast(u8, s, ':') orelse return s;
    return s[0..colon];
}

test "stripPort" {
    try std.testing.expectEqualStrings("1.2.3.4", stripPort("1.2.3.4:5555"));
    try std.testing.expectEqualStrings("::1", stripPort("[::1]:5555"));
    try std.testing.expectEqualStrings("?", stripPort("?"));
}

fn clientKey(addr: Io.net.IpAddress) ratelimit.Key {
    var k: ratelimit.Key = @splat(0);
    switch (addr) {
        .ip4 => |a| @memcpy(k[0..4], &a.bytes),
        .ip6 => |a| k = a.bytes,
    }
    return k;
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

/// A connection that completes no request (and sends no complete head) for
/// this long is cut. This is the slowloris defense: without it, 256 silent
/// sockets would lock every real user out.
const idle_limit_s = 15;

/// One entry per allowed connection. The mutex exists so the reaper can never
/// shut down a descriptor number that was already closed and handed to a new
/// client: close and shutdown both happen under the slot lock.
const Slot = struct {
    mutex: Io.Mutex = .init,
    in_use: bool = false,
    stream: Io.net.Stream = undefined,
    last_s: std.atomic.Value(i64) = .init(0),
};

const Pool = struct {
    slots: []Slot,

    fn acquire(p: *Pool, io: Io, stream: Io.net.Stream) ?*Slot {
        for (p.slots) |*s| {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            if (!s.in_use) {
                s.in_use = true;
                s.stream = stream;
                s.last_s.store(nowMono(io), .monotonic);
                return s;
            }
        }
        return null;
    }

    fn release(_: *Pool, io: Io, s: *Slot) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.stream.close(io);
        s.in_use = false;
    }

    fn reap(p: *Pool, io: Io) void {
        const now = nowMono(io);
        for (p.slots) |*s| {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            if (s.in_use and now - s.last_s.load(.monotonic) >= idle_limit_s) {
                log.debug("closing idle connection", .{});
                s.stream.shutdown(io, .both) catch {};
                // Push the deadline out so we don't shut it down every tick
                // while the handler task is still unwinding.
                s.last_s.store(now, .monotonic);
            }
        }
    }
};

fn nowMono(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toSeconds();
}

fn reaper(io: Io, pool: *Pool) Io.Cancelable!void {
    while (true) {
        try io.sleep(.fromSeconds(2), .awake);
        pool.reap(io);
    }
}

pub fn run(io: Io, app: *App) !void {
    const addr = try Io.net.IpAddress.parse(app.cfg.listen, app.cfg.port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    log.info("listening on {s}:{d}", .{ app.cfg.listen, app.cfg.port });
    if (app.users.list.items.len == 0) {
        log.warn("no users exist, create one with: nodos user add <name> --config <file>", .{});
    }

    const slots = try app.gpa.alloc(Slot, max_connections);
    defer app.gpa.free(slots);
    for (slots) |*s| s.* = .{};
    var pool: Pool = .{ .slots = slots };

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, reaper, .{ io, &pool });

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                log.warn("accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        const slot = pool.acquire(io, stream) orelse {
            stream.close(io);
            log.warn("connection limit reached, dropping client", .{});
            continue;
        };
        group.concurrent(io, serveConnection, .{ io, app, &pool, slot, stream }) catch {
            pool.release(io, slot);
            log.warn("could not start connection task", .{});
        };
    }
}

fn serveConnection(io: Io, app: *App, pool: *Pool, slot: *Slot, stream: Io.net.Stream) Io.Cancelable!void {
    defer pool.release(io, slot);

    var in_buf: [8192]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var srv = http.Server.init(&reader.interface, &writer.interface);

    const client = clientKey(stream.socket.address);
    var ip_buf: [64]u8 = undefined;
    const ip_text = stripPort(std.fmt.bufPrint(&ip_buf, "{f}", .{stream.socket.address}) catch "?");

    while (true) {
        var req = srv.receiveHead() catch |err| {
            // Closed connections and garbage are routine, not worth a warning.
            log.debug("receiveHead: {s}", .{@errorName(err)});
            return;
        };

        slot.last_s.store(nowMono(io), .monotonic);
        const head = req.head;
        const framed = bodyFramingValid(head.method, head.transfer_encoding, head.content_length);
        const too_big = if (head.content_length) |n| n > max_body else head.transfer_encoding != .none;

        var ctx: Ctx = .{
            .method = head.method,
            .path = if (std.mem.findScalar(u8, head.target, '?')) |q| head.target[0..q] else head.target,
            .client = client,
            .ip_text = ip_text,
            .now_s = Io.Timestamp.now(io, .real).toSeconds(),
        };
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
                if (cookieValue(h.value, cookie_name)) |v| {
                    if (v.len == 43) ctx.cookie_token = v[0..43].*;
                }
            } else if (std.ascii.eqlIgnoreCase(h.name, csrf_header)) {
                if (h.value.len == 43) ctx.csrf = h.value[0..43].*;
            }
        }
        // ctx.path points into the head buffer, which dies when the body
        // reader starts. Copy it before touching the body.
        var path_buf: [128]u8 = undefined;
        if (ctx.path.len > path_buf.len) {
            respondSimple(&req, .{ .status = .uri_too_long, .body = "{\"error\":\"uri too long\"}" }, false) catch return;
            return;
        }
        @memcpy(path_buf[0..ctx.path.len], ctx.path);
        ctx.path = path_buf[0..ctx.path.len];

        if (!framed) {
            respondSimple(&req, .{ .status = .length_required, .body = "{\"error\":\"length required\"}" }, false) catch return;
            return;
        }
        if (too_big) {
            respondSimple(&req, .{ .status = .payload_too_large, .body = "{\"error\":\"body too large\"}" }, false) catch return;
            return;
        }

        var body_store: [max_body]u8 = undefined;
        var body: []const u8 = "";
        if (head.method.requestHasBody()) {
            var rbuf: [64]u8 = undefined;
            const br = req.readerExpectContinue(&rbuf) catch return;
            const n = br.readSliceShort(&body_store) catch return;
            body = body_store[0..n];
        }

        var scratch: Scratch = .{};
        const reply = dispatch(app, io, ctx, body, &scratch);
        const keep = head.keep_alive;
        respondSimple(&req, reply, keep) catch return;
        slot.last_s.store(nowMono(io), .monotonic);
        if (!keep) return;
    }
}

fn respondSimple(req: *http.Server.Request, reply: Reply, keep_alive: bool) !void {
    var hdrs: [security_headers.len + 2]http.Header = undefined;
    @memcpy(hdrs[0..security_headers.len], &security_headers);
    var n: usize = security_headers.len;
    hdrs[n] = .{ .name = "content-type", .value = reply.content_type };
    n += 1;
    if (reply.set_cookie) |c| {
        hdrs[n] = .{ .name = "set-cookie", .value = c };
        n += 1;
    }
    try req.respond(reply.body, .{
        .status = reply.status,
        .extra_headers = hdrs[0..n],
        .keep_alive = keep_alive,
    });
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

test "cookie parsing" {
    try std.testing.expectEqualStrings("abc", cookieValue("a=1; nodos_session=abc; b=2", "nodos_session").?);
    try std.testing.expect(cookieValue("xnodos_session=abc", "nodos_session") == null);
    try std.testing.expect(cookieValue("", "nodos_session") == null);
}

fn testApp(arena: std.mem.Allocator) !App {
    const io = std.testing.io;
    var users: users_mod.Users = .{};
    var hb: [auth.hash_buf_len]u8 = undefined;
    const phc = try auth.hashPassword(std.testing.allocator, io, "correct horse battery", &hb);
    _ = try users.add(arena, "alice", .admin, phc);
    return App.init(std.testing.allocator, io, .{}, users);
}

fn testCtx(method: http.Method, path: []const u8) Ctx {
    return .{ .method = method, .path = path, .client = @splat(7), .ip_text = "127.0.0.1", .now_s = 1000 };
}

test "health" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var app = try testApp(arena.allocator());
    defer app.deinit(std.testing.io);
    var s: Scratch = .{};
    const r = dispatch(&app, std.testing.io, testCtx(.GET, "/api/v1/health"), "", &s);
    try std.testing.expectEqual(http.Status.ok, r.status);
    try std.testing.expectEqual(http.Status.method_not_allowed, dispatch(&app, std.testing.io, testCtx(.POST, "/api/v1/health"), "", &s).status);
    try std.testing.expectEqual(http.Status.not_found, dispatch(&app, std.testing.io, testCtx(.GET, "/nope"), "", &s).status);
}

test "login, me, csrf, logout" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var app = try testApp(arena.allocator());
    defer app.deinit(io);
    var s: Scratch = .{};

    // bad password and unknown user look identical
    const bad = dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "{\"username\":\"alice\",\"password\":\"nope nope nope\"}", &s);
    try std.testing.expectEqual(http.Status.unauthorized, bad.status);
    const ghost = dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "{\"username\":\"ghost\",\"password\":\"correct horse battery\"}", &s);
    try std.testing.expectEqualStrings(bad.body, ghost.body);
    try std.testing.expectEqual(http.Status.bad_request, dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "not json", &s).status);

    // good login
    const ok = dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "{\"username\":\"alice\",\"password\":\"correct horse battery\"}", &s);
    try std.testing.expectEqual(http.Status.ok, ok.status);
    const set = ok.set_cookie.?;
    try std.testing.expect(std.mem.find(u8, set, "HttpOnly") != null);
    try std.testing.expect(std.mem.find(u8, set, "SameSite=Strict") != null);
    try std.testing.expect(std.mem.find(u8, set, "Secure") != null);
    var token: [43]u8 = undefined;
    @memcpy(&token, set[cookie_name.len + 1 ..][0..43]);
    // pull csrf out of the body json
    const Resp = struct { csrf: []const u8 };
    var fba_buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const parsed = try std.json.parseFromSliceLeaky(Resp, fba.allocator(), ok.body, .{ .ignore_unknown_fields = true });
    var csrf: [43]u8 = undefined;
    @memcpy(&csrf, parsed.csrf[0..43]);

    // /me needs the cookie
    var s2: Scratch = .{};
    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, testCtx(.GET, "/api/v1/me"), "", &s2).status);
    var me_ctx = testCtx(.GET, "/api/v1/me");
    me_ctx.cookie_token = token;
    try std.testing.expectEqual(http.Status.ok, dispatch(&app, io, me_ctx, "", &s2).status);

    // logout without csrf is refused, with it works, and the session dies
    var out_ctx = testCtx(.POST, "/api/v1/logout");
    out_ctx.cookie_token = token;
    try std.testing.expectEqual(http.Status.forbidden, dispatch(&app, io, out_ctx, "", &s2).status);
    out_ctx.csrf = csrf;
    try std.testing.expectEqual(http.Status.ok, dispatch(&app, io, out_ctx, "", &s2).status);
    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, me_ctx, "", &s2).status);
}

test "lockout after repeated failures" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var app = try testApp(arena.allocator());
    defer app.deinit(io);
    var s: Scratch = .{};
    var i: usize = 0;
    while (i < ratelimit.Limiter.max_failures) : (i += 1) {
        _ = dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "{\"username\":\"alice\",\"password\":\"wrong wrong wrong\"}", &s);
    }
    // even the right password is refused while locked out
    const r = dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "{\"username\":\"alice\",\"password\":\"correct horse battery\"}", &s);
    try std.testing.expectEqual(http.Status.too_many_requests, r.status);
}
