const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http = std.http;
const signals = @import("signals.zig");
const config = @import("config.zig");
const auth = @import("auth.zig");
const users_mod = @import("users.zig");
const ratelimit = @import("ratelimit.zig");
const audit = @import("audit.zig");
const assets = @import("assets.zig");
const alerts_mod = @import("alerts.zig");
const update_checker = @import("update/checker.zig");
const update_release = @import("update/release.zig");
const docker = @import("integrations/docker.zig");
const systemd = @import("integrations/systemd.zig");
const sampler_mod = @import("agent/sampler.zig");
const encode = @import("agent/encode.zig");
const version = @import("build_options").version;

const log = std.log.scoped(.server);

const max_connections = 256;

const max_body = 1024;

const cookie_name = "nodos_session";
const csrf_header = "x-csrf-token";

pub const App = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    users: users_mod.Users,
    sessions: auth.SessionStore = .{},
    limiter: ratelimit.Limiter = .{},
    sampler: sampler_mod.Sampler = .{},
    streams: std.atomic.Value(u32) = .init(0),
    alerts: alerts_mod.Engine = .{},
    updates: update_checker.Checker = .{},
    docker: ?docker.Client = null,
    systemd: ?systemd.Client = null,
    audit_log: ?audit.Log = null,
    dummy_phc: [auth.hash_buf_len]u8 = undefined,
    dummy_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, cfg: config.Config, users: users_mod.Users) !App {
        var app: App = .{ .gpa = gpa, .cfg = cfg, .users = users };
        if (!std.mem.eql(u8, cfg.docker_socket, "off")) {
            app.docker = .{ .io = io, .socket_path = cfg.docker_socket };
        }
        if (cfg.services.len > 0) {
            app.systemd = .{ .io = io, .gpa = gpa, .units = cfg.services };
        }
        var pw: [24]u8 = undefined;
        try io.randomSecure(&pw);
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
        app.recordTarget(io, now_s, actor, action, "", ok, ip);
    }

    pub fn onSample(ctx: *anyopaque, io: Io, snap: *const @import("agent/collect.zig").Snapshot) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        var events: [alerts_mod.max_alerts]alerts_mod.Event = undefined;
        const n = app.alerts.evaluate(io, snap, &events);
        for (events[0..n]) |ev| {
            var target_buf: [160]u8 = undefined;
            const target = std.fmt.bufPrint(&target_buf, "{s} {s} {s} {d:.1}", .{ @tagName(ev.alert.kind), ev.alert.subject.slice(), @tagName(ev.alert.level), ev.alert.value }) catch "alert";
            var action_buf: [32]u8 = undefined;
            const action = std.fmt.bufPrint(&action_buf, "alert.{s}", .{@tagName(ev.what)}) catch "alert";
            if (ev.what == .cleared) {
                log.info("alert cleared: {s}", .{target});
            } else {
                log.warn("alert {s}: {s}", .{ @tagName(ev.what), target });
            }
            app.recordTarget(io, snap.ts_s, "system", action, target, true, "");
        }
    }

    fn recordTarget(app: *App, io: Io, now_s: i64, actor: []const u8, action: []const u8, target: []const u8, ok: bool, ip: []const u8) void {
        if (app.audit_log) |*a| a.record(io, .{ .ts = now_s, .actor = actor, .action = action, .target = target, .ok = ok, .ip = ip });
    }
};

pub const Reply = struct {
    status: http.Status,
    content_type: []const u8 = "application/json",
    body: []const u8,
    set_cookie: ?[]const u8 = null,
};

pub const Ctx = struct {
    method: http.Method,
    path: []const u8,
    query: []const u8 = "",
    cookie_token: ?[43]u8 = null,
    csrf: ?[43]u8 = null,
    client: ratelimit.Key,
    ip_text: []const u8,
    now_s: i64,
};

pub const Scratch = struct {
    body: [512]u8 = undefined,
    cookie: [192]u8 = undefined,
    big: [32 * 1024]u8 = undefined,
};

const err_not_found: Reply = .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
const err_method: Reply = .{ .status = .method_not_allowed, .body = "{\"error\":\"method not allowed\"}" };
const err_unauth: Reply = .{ .status = .unauthorized, .body = "{\"error\":\"unauthorized\"}" };
const err_forbidden: Reply = .{ .status = .forbidden, .body = "{\"error\":\"forbidden\"}" };
const err_bad: Reply = .{ .status = .bad_request, .body = "{\"error\":\"bad request\"}" };
const err_internal: Reply = .{ .status = .internal_server_error, .body = "{\"error\":\"internal\"}" };
const err_unavailable: Reply = .{ .status = .service_unavailable, .body = "{\"error\":\"monitoring data not available\"}" };

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
    if (std.mem.eql(u8, ctx.path, "/api/v1/system")) {
        if (!get) return err_method;
        _ = currentSession(app, io, ctx) orelse return err_unauth;
        if (app.sampler.isUnsupported(io)) return err_unavailable;
        const snap = app.sampler.latestCopy(io) orelse return err_unavailable;
        var w: Io.Writer = .fixed(&s.big);
        encode.writeSnapshot(&w, &snap) catch return err_internal;
        return .{ .status = .ok, .body = w.buffered() };
    }
    if (std.mem.eql(u8, ctx.path, "/api/v1/update")) {
        if (!get) return err_method;
        _ = currentSession(app, io, ctx) orelse return err_unauth;
        var w: Io.Writer = .fixed(&s.body);
        update_checker.writeJson(&w, app.cfg.update_check, app.updates.copy(io)) catch return err_internal;
        return .{ .status = .ok, .body = w.buffered() };
    }
    if (std.mem.eql(u8, ctx.path, "/api/v1/audit")) {
        if (!get) return err_method;
        const sess = currentSession(app, io, ctx) orelse return err_unauth;
        if (sess.role != .admin) return err_forbidden;
        const log_file = if (app.audit_log) |*l| l else return err_unavailable;
        const limit = std.math.clamp(queryInt(ctx.query, "limit") orelse 100, 1, 200);
        var read_buf: [48 * 1024]u8 = undefined;
        const tail = log_file.readTail(io, &read_buf) catch return err_internal;
        var w: Io.Writer = .fixed(&s.big);
        audit.writeEntries(&w, tail.bytes, tail.from_start, limit) catch return err_internal;
        return .{ .status = .ok, .body = w.buffered() };
    }
    if (std.mem.eql(u8, ctx.path, "/api/v1/alerts")) {
        if (!get) return err_method;
        _ = currentSession(app, io, ctx) orelse return err_unauth;
        var list: [alerts_mod.max_alerts]alerts_mod.Alert = undefined;
        const snap = app.alerts.snapshot(io, &list);
        var w: Io.Writer = .fixed(&s.big);
        alerts_mod.writeJson(&w, list[0..snap.n]) catch return err_internal;
        return .{ .status = .ok, .body = w.buffered() };
    }
    if (std.mem.eql(u8, ctx.path, "/api/v1/history")) {
        if (!get) return err_method;
        _ = currentSession(app, io, ctx) orelse return err_unauth;
        if (app.sampler.isUnsupported(io)) return err_unavailable;
        var pts: [sampler_mod.history_len]sampler_mod.Point = undefined;
        const n = app.sampler.historyCopy(io, &pts);
        var w: Io.Writer = .fixed(&s.big);
        encode.writeHistory(&w, pts[0..n]) catch return err_internal;
        return .{ .status = .ok, .body = w.buffered() };
    }
    if (std.mem.eql(u8, ctx.path, "/api/v1/logout")) {
        if (ctx.method != .POST) return err_method;
        const sess = currentSession(app, io, ctx) orelse return err_unauth;
        if (!csrfOk(sess, ctx)) return err_forbidden;
        app.sessions.destroy(io, &ctx.cookie_token.?);
        app.record(io, ctx.now_s, userName(app, sess), "auth.logout", true, ctx.ip_text);
        return .{ .status = .ok, .body = "{\"ok\":true}", .set_cookie = cookie(app, s, "", 0) };
    }
    if (std.mem.startsWith(u8, ctx.path, "/api/v1/docker/")) return dockerRoute(app, io, ctx, s);
    if (std.mem.startsWith(u8, ctx.path, "/api/v1/services")) return serviceRoute(app, io, ctx, s);
    if (get) if (assets.find(ctx.path)) |a| {
        return .{ .status = .ok, .content_type = a.content_type, .body = a.body };
    };
    return err_not_found;
}

const err_docker_off: Reply = .{ .status = .service_unavailable, .body = "{\"error\":\"docker integration is turned off\"}" };
const err_docker_down: Reply = .{ .status = .service_unavailable, .body = "{\"error\":\"docker is not reachable\"}" };
const err_docker_odd: Reply = .{ .status = .bad_gateway, .body = "{\"error\":\"docker sent an unexpected reply\"}" };

const err_docker_slow: Reply = .{ .status = .gateway_timeout, .body = "{\"error\":\"docker did not answer in time\"}" };

fn dockerFailure(err: anyerror) Reply {
    return switch (err) {
        error.Unavailable => err_docker_down,
        error.TimedOut => err_docker_slow,
        error.InvalidTarget => err_bad,
        error.OutOfMemory => err_internal,
        else => err_docker_odd,
    };
}

fn queryInt(query: []const u8, name: []const u8) ?usize {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return std.fmt.parseInt(usize, pair[eq + 1 ..], 10) catch null;
    }
    return null;
}

fn dockerRoute(app: *App, io: Io, ctx: Ctx, s: *Scratch) Reply {
    const sess = currentSession(app, io, ctx) orelse return err_unauth;
    const client = app.docker orelse return err_docker_off;
    const rest = ctx.path["/api/v1/docker".len..];

    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (std.mem.eql(u8, rest, "/containers")) {
        if (ctx.method != .GET and ctx.method != .HEAD) return err_method;
        const list = docker.listContainers(client, a) catch |e| return dockerFailure(e);
        var w: Io.Writer = .fixed(&s.big);
        docker.writeContainers(&w, list) catch return err_internal;
        return .{ .status = .ok, .body = w.buffered() };
    }

    const prefix = "/containers/";
    if (!std.mem.startsWith(u8, rest, prefix)) return err_not_found;
    const tail = rest[prefix.len..];
    const slash = std.mem.findScalar(u8, tail, '/') orelse return err_not_found;
    const ref = tail[0..slash];
    const verb = tail[slash + 1 ..];
    if (!docker.validRef(ref)) return err_bad;

    if (std.mem.eql(u8, verb, "logs")) {
        if (ctx.method != .GET) return err_method;
        if (sess.role != .admin) return err_forbidden;
        const lines = std.math.clamp(queryInt(ctx.query, "tail") orelse 100, 1, 500);
        const text = docker.fetchLogs(client, a, ref, lines) catch |e| return dockerFailure(e);
        var w: Io.Writer = .fixed(&s.big);
        docker.writeLogs(a, &w, text, lines) catch return err_internal;
        return .{ .status = .ok, .body = w.buffered() };
    }

    const action = docker.Action.parse(verb) orelse return err_not_found;
    if (ctx.method != .POST) return err_method;
    if (sess.role != .admin) return err_forbidden;
    if (!csrfOk(sess, ctx)) return err_forbidden;

    var name_buf: [80]u8 = undefined;
    const action_name = std.fmt.bufPrint(&name_buf, "docker.{s}", .{@tagName(action)}) catch "docker.action";
    const result = docker.runAction(client, a, ref, action) catch |e| {
        app.recordTarget(io, ctx.now_s, userName(app, sess), action_name, ref, false, ctx.ip_text);
        return dockerFailure(e);
    };
    const ok = result == .done or result == .unchanged;
    app.recordTarget(io, ctx.now_s, userName(app, sess), action_name, ref, ok, ctx.ip_text);
    return switch (result) {
        .done => .{ .status = .ok, .body = "{\"ok\":true,\"result\":\"done\"}" },
        .unchanged => .{ .status = .ok, .body = "{\"ok\":true,\"result\":\"unchanged\"}" },
        .not_found => .{ .status = .not_found, .body = "{\"error\":\"no such container\"}" },
        .failed => err_docker_odd,
    };
}

const err_svc_off: Reply = .{ .status = .service_unavailable, .body = "{\"error\":\"no services are configured\"}" };
const err_svc_down: Reply = .{ .status = .service_unavailable, .body = "{\"error\":\"systemd is not available on this host\"}" };
const err_svc_slow: Reply = .{ .status = .gateway_timeout, .body = "{\"error\":\"systemd did not answer in time\"}" };

fn serviceFailure(err: anyerror) Reply {
    return switch (err) {
        error.Unavailable => err_svc_down,
        error.TimedOut => err_svc_slow,
        error.OutOfMemory => err_internal,
        else => err_docker_odd,
    };
}

fn serviceRoute(app: *App, io: Io, ctx: Ctx, s: *Scratch) Reply {
    const sess = currentSession(app, io, ctx) orelse return err_unauth;
    const client = app.systemd orelse return err_svc_off;
    const rest = ctx.path["/api/v1/services".len..];

    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (rest.len == 0) {
        if (ctx.method != .GET and ctx.method != .HEAD) return err_method;
        const list = client.statuses(a) catch |e| return serviceFailure(e);
        var w: Io.Writer = .fixed(&s.big);
        systemd.writeStatuses(&w, list) catch return err_internal;
        return .{ .status = .ok, .body = w.buffered() };
    }

    if (rest[0] != '/') return err_not_found;
    const tail = rest[1..];
    const slash = std.mem.findScalar(u8, tail, '/') orelse return err_not_found;
    const unit = tail[0..slash];
    const verb = tail[slash + 1 ..];
    if (!client.allowed(unit)) return err_not_found;

    if (std.mem.eql(u8, verb, "logs")) {
        if (ctx.method != .GET) return err_method;
        if (sess.role != .admin) return err_forbidden;
        const lines = std.math.clamp(queryInt(ctx.query, "tail") orelse 100, 1, 500);
        const text = client.logs(a, unit, lines) catch |e| return serviceFailure(e);
        var w: Io.Writer = .fixed(&s.big);
        docker.writeLogs(a, &w, text, lines) catch return err_internal;
        return .{ .status = .ok, .body = w.buffered() };
    }

    const action = systemd.Action.parse(verb) orelse return err_not_found;
    if (ctx.method != .POST) return err_method;
    if (sess.role != .admin) return err_forbidden;
    if (!csrfOk(sess, ctx)) return err_forbidden;

    var name_buf: [48]u8 = undefined;
    const action_name = std.fmt.bufPrint(&name_buf, "service.{s}", .{@tagName(action)}) catch "service.action";
    const outcome = client.act(a, unit, action) catch |e| {
        app.recordTarget(io, ctx.now_s, userName(app, sess), action_name, unit, false, ctx.ip_text);
        return serviceFailure(e);
    };
    switch (outcome) {
        .done => {
            app.recordTarget(io, ctx.now_s, userName(app, sess), action_name, unit, true, ctx.ip_text);
            return .{ .status = .ok, .body = "{\"ok\":true,\"result\":\"done\"}" };
        },
        .refused => |msg| {
            app.recordTarget(io, ctx.now_s, userName(app, sess), action_name, unit, false, ctx.ip_text);
            var msg_buf: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&msg_buf, "systemd refused: {s}", .{msg}) catch "systemd refused the request";
            var w: Io.Writer = .fixed(&s.body);
            var j: std.json.Stringify = .{ .writer = &w };
            j.beginObject() catch return err_internal;
            j.objectField("error") catch return err_internal;
            j.write(text) catch return err_internal;
            j.endObject() catch return err_internal;
            return .{ .status = .bad_gateway, .body = w.buffered() };
        },
    }
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

fn cookie(app: *App, s: *Scratch, token: []const u8, max_age: i64) ?[]const u8 {
    const secure = if (app.cfg.secure_cookies) "; Secure" else "";
    return std.fmt.bufPrint(&s.cookie, "{s}={s}; HttpOnly; SameSite=Strict; Path=/; Max-Age={d}{s}", .{ cookie_name, token, max_age, secure }) catch null;
}

pub fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, header, ";");
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        const eq = std.mem.findScalar(u8, p, '=') orelse continue;
        if (std.mem.eql(u8, p[0..eq], name)) return p[eq + 1 ..];
    }
    return null;
}

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

pub fn rightmostForwarded(xff: []const u8) ?Io.net.IpAddress {
    const comma = std.mem.findScalarLast(u8, xff, ',');
    const last = std.mem.trim(u8, if (comma) |c| xff[c + 1 ..] else xff, " \t");
    if (last.len == 0) return null;
    const bare = if (last.len > 2 and last[0] == '[' and last[last.len - 1] == ']') last[1 .. last.len - 1] else last;
    return Io.net.IpAddress.parse(bare, 0) catch null;
}

fn sameHost(a: Io.net.IpAddress, b: Io.net.IpAddress) bool {
    return switch (a) {
        .ip4 => |x| switch (b) {
            .ip4 => |y| std.mem.eql(u8, &x.bytes, &y.bytes),
            else => false,
        },
        .ip6 => |x| switch (b) {
            .ip6 => |y| std.mem.eql(u8, &x.bytes, &y.bytes),
            else => false,
        },
    };
}

fn formatHost(addr: Io.net.IpAddress, buf: []u8) []const u8 {
    return stripPort(std.fmt.bufPrint(buf, "{f}", .{addr}) catch return "?");
}

test "forwarded address: rightmost wins, junk is ignored" {
    const a = rightmostForwarded("9.9.9.9, 203.0.113.7").?;
    try std.testing.expect(sameHost(a, try Io.net.IpAddress.parse("203.0.113.7", 0)));
    try std.testing.expect(rightmostForwarded("203.0.113.7").?.ip4.bytes[3] == 7);
    const spoof = rightmostForwarded("10.0.0.1, 198.51.100.4").?;
    try std.testing.expect(sameHost(spoof, try Io.net.IpAddress.parse("198.51.100.4", 0)));
    try std.testing.expect(rightmostForwarded("") == null);
    try std.testing.expect(rightmostForwarded("not an ip") == null);
    try std.testing.expect(rightmostForwarded("1.2.3.4,") == null);
    const v6 = rightmostForwarded("1.2.3.4, [2001:db8::1]").?;
    try std.testing.expect(v6 == .ip6);
}

test "sameHost ignores ports and families" {
    const a = try Io.net.IpAddress.parse("127.0.0.1", 1111);
    const b = try Io.net.IpAddress.parse("127.0.0.1", 2222);
    const c = try Io.net.IpAddress.parse("::1", 1111);
    try std.testing.expect(sameHost(a, b));
    try std.testing.expect(!sameHost(a, c));
}

fn clientKey(addr: Io.net.IpAddress) ratelimit.Key {
    var k: ratelimit.Key = @splat(0);
    switch (addr) {
        .ip4 => |a| @memcpy(k[0..4], &a.bytes),
        .ip6 => |a| k = a.bytes,
    }
    return k;
}

const security_headers = [_]http.Header{
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "content-security-policy", .value = "default-src 'self'; frame-ancestors 'none'" },
};

const idle_limit_s = 15;

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

    // close and shutdown share the slot lock, otherwise we could shut down an fd that was already handed to someone else
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
    if (builtin.os.tag == .linux) _ = signals.installShutdown(listener.socket.handle);
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
    if (app.cfg.update_check) {
        const meta_url = if (app.cfg.update_mirror.len > 0)
            (update_release.Source.mirror(app.gpa, app.cfg.update_mirror) catch null)
        else
            update_release.Source.github;
        if (meta_url) |src| {
            group.concurrent(io, update_checker.Checker.run, .{ &app.updates, app.gpa, io, src.meta_url }) catch
                log.warn("could not start the update checker", .{});
        }
    }
    try group.concurrent(io, sampler_mod.Sampler.run, .{ &app.sampler, io, app.cfg.sample_interval_ms, @as(?sampler_mod.Sampler.Hook, .{ .ctx = app, .call = App.onSample }) });

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled, error.SocketNotListening => {
                log.info("shutting down", .{});
                return;
            },
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
    const ip_text = formatHost(stream.socket.address, &ip_buf);
    const proxy_trusted = if (app.cfg.trusted_proxy.len > 0) blk: {
        const p = Io.net.IpAddress.parse(app.cfg.trusted_proxy, 0) catch break :blk false;
        break :blk sameHost(p, stream.socket.address);
    } else false;

    while (true) {
        var req = srv.receiveHead() catch |err| {
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
        var fwd_buf: [64]u8 = undefined;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (proxy_trusted and std.ascii.eqlIgnoreCase(h.name, "x-forwarded-for")) {
                if (rightmostForwarded(h.value)) |addr| {
                    ctx.client = clientKey(addr);
                    ctx.ip_text = formatHost(addr, &fwd_buf);
                }
            } else if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
                if (cookieValue(h.value, cookie_name)) |v| {
                    if (v.len == 43) ctx.cookie_token = v[0..43].*;
                }
            } else if (std.ascii.eqlIgnoreCase(h.name, csrf_header)) {
                if (h.value.len == 43) ctx.csrf = h.value[0..43].*;
            }
        }
        var path_buf: [128]u8 = undefined;
        var query_buf: [64]u8 = undefined;
        if (ctx.path.len > path_buf.len) {
            respondSimple(&req, .{ .status = .uri_too_long, .body = "{\"error\":\"uri too long\"}" }, false) catch return;
            return;
        }
        if (std.mem.findScalar(u8, head.target, '?')) |q| {
            const qs = head.target[q + 1 ..];
            const n = @min(qs.len, query_buf.len);
            @memcpy(query_buf[0..n], qs[0..n]);
            ctx.query = query_buf[0..n];
        }
        @memcpy(path_buf[0..ctx.path.len], ctx.path);
        ctx.path = path_buf[0..ctx.path.len];

        if (head.method == .GET and std.mem.eql(u8, ctx.path, "/api/v1/stream")) {
            serveStream(app, io, &req, ctx, slot);
            return;
        }

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

const max_streams = 16;

fn streamTick(app: *App, io: Io, w: *Io.Writer, last_ts: *i64, last_alerts: *u32) !void {
    const ver = app.alerts.currentVersion(io);
    if (ver != last_alerts.*) {
        last_alerts.* = ver;
        var list: [alerts_mod.max_alerts]alerts_mod.Alert = undefined;
        const snap = app.alerts.snapshot(io, &list);
        try w.writeAll("event: alerts\ndata: ");
        try alerts_mod.writeJson(w, list[0..snap.n]);
        try w.writeAll("\n\n");
    }
    if (app.sampler.latestCopy(io)) |snap| {
        if (snap.ts_s != last_ts.*) {
            last_ts.* = snap.ts_s;
            try w.writeAll("event: snapshot\ndata: ");
            try encode.writeSnapshot(w, &snap);
            try w.writeAll("\n\n");
            return;
        }
    }
    try w.writeAll(": ping\n\n");
}

fn serveStream(app: *App, io: Io, req: *http.Server.Request, ctx: Ctx, slot: *Slot) void {
    const sess_token = ctx.cookie_token orelse {
        respondSimple(req, err_unauth, false) catch {};
        return;
    };
    if (app.sessions.lookup(io, &sess_token, ctx.now_s) == null) {
        respondSimple(req, err_unauth, false) catch {};
        return;
    }
    if (app.sampler.isUnsupported(io)) {
        respondSimple(req, err_unavailable, false) catch {};
        return;
    }
    if (app.streams.fetchAdd(1, .acq_rel) >= max_streams) {
        _ = app.streams.fetchSub(1, .acq_rel);
        respondSimple(req, .{ .status = .service_unavailable, .body = "{\"error\":\"too many live streams\"}" }, false) catch {};
        return;
    }
    defer _ = app.streams.fetchSub(1, .acq_rel);

    var hdrs: [security_headers.len + 1]http.Header = undefined;
    @memcpy(hdrs[0..security_headers.len], &security_headers);
    hdrs[security_headers.len] = .{ .name = "content-type", .value = "text/event-stream" };
    var out_buf: [24 * 1024]u8 = undefined;
    var bw = req.respondStreaming(&out_buf, .{
        .respond_options = .{ .extra_headers = &hdrs, .keep_alive = false },
    }) catch |err| {
        log.debug("stream: respondStreaming failed: {s}", .{@errorName(err)});
        return;
    };

    var last_ts: i64 = 0;
    var last_alerts: u32 = 0;
    const tick_ms: i64 = @min(app.cfg.sample_interval_ms, 5000);
    while (true) {
        const now_s = Io.Timestamp.now(io, .real).toSeconds();
        if (app.sessions.lookup(io, &sess_token, now_s) == null) {
            log.debug("stream: session ended", .{});
            return;
        }
        streamTick(app, io, &bw.writer, &last_ts, &last_alerts) catch |err| {
            log.debug("stream: write failed: {s}", .{@errorName(err)});
            return;
        };
        // two flushes on purpose. bw.flush() only pushes the socket, events sat in bw.writer until its buffer filled
        bw.writer.flush() catch |err| {
            log.debug("stream: writer flush failed: {s}", .{@errorName(err)});
            return;
        };
        bw.flush() catch |err| {
            log.debug("stream: flush failed: {s}", .{@errorName(err)});
            return;
        };
        slot.last_s.store(nowMono(io), .monotonic);
        io.sleep(.fromMilliseconds(tick_ms), .awake) catch return;
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

// std asserts on a POST with no length and takes the whole process down. found that the hard way, so reject it first
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

pub fn testApp(arena: std.mem.Allocator) !App {
    const io = std.testing.io;
    var users: users_mod.Users = .{};
    var hb: [auth.hash_buf_len]u8 = undefined;
    const phc = try auth.hashPassword(std.testing.allocator, io, "correct horse battery", &hb);
    _ = try users.add(arena, "alice", .admin, phc);
    return App.init(std.testing.allocator, io, .{}, users);
}

pub fn testCtx(method: http.Method, path: []const u8) Ctx {
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

    const bad = dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "{\"username\":\"alice\",\"password\":\"nope nope nope\"}", &s);
    try std.testing.expectEqual(http.Status.unauthorized, bad.status);
    const ghost = dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "{\"username\":\"ghost\",\"password\":\"correct horse battery\"}", &s);
    try std.testing.expectEqualStrings(bad.body, ghost.body);
    try std.testing.expectEqual(http.Status.bad_request, dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "not json", &s).status);

    const ok = dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "{\"username\":\"alice\",\"password\":\"correct horse battery\"}", &s);
    try std.testing.expectEqual(http.Status.ok, ok.status);
    const set = ok.set_cookie.?;
    try std.testing.expect(std.mem.find(u8, set, "HttpOnly") != null);
    try std.testing.expect(std.mem.find(u8, set, "SameSite=Strict") != null);
    try std.testing.expect(std.mem.find(u8, set, "Secure") != null);
    var token: [43]u8 = undefined;
    @memcpy(&token, set[cookie_name.len + 1 ..][0..43]);
    const Resp = struct { csrf: []const u8 };
    var fba_buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const parsed = try std.json.parseFromSliceLeaky(Resp, fba.allocator(), ok.body, .{ .ignore_unknown_fields = true });
    var csrf: [43]u8 = undefined;
    @memcpy(&csrf, parsed.csrf[0..43]);

    var s2: Scratch = .{};
    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, testCtx(.GET, "/api/v1/me"), "", &s2).status);
    var me_ctx = testCtx(.GET, "/api/v1/me");
    me_ctx.cookie_token = token;
    try std.testing.expectEqual(http.Status.ok, dispatch(&app, io, me_ctx, "", &s2).status);

    var out_ctx = testCtx(.POST, "/api/v1/logout");
    out_ctx.cookie_token = token;
    try std.testing.expectEqual(http.Status.forbidden, dispatch(&app, io, out_ctx, "", &s2).status);
    out_ctx.csrf = csrf;
    try std.testing.expectEqual(http.Status.ok, dispatch(&app, io, out_ctx, "", &s2).status);
    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, me_ctx, "", &s2).status);
}

test "system and history need a session and real data" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var app = try testApp(arena.allocator());
    defer app.deinit(io);
    var s: Scratch = .{};

    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, testCtx(.GET, "/api/v1/system"), "", &s).status);
    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, testCtx(.GET, "/api/v1/history"), "", &s).status);

    const issued = try app.sessions.create(app.gpa, io, 1, .viewer, 1000);
    var ctx = testCtx(.GET, "/api/v1/system");
    ctx.cookie_token = issued.token;

    try std.testing.expectEqual(http.Status.service_unavailable, dispatch(&app, io, ctx, "", &s).status);

    var snap: @import("agent/collect.zig").Snapshot = .{ .ts_s = 1000, .cpu_pct = 25 };
    snap.mem = .{ .total_kb = 1000, .available_kb = 250 };
    snap.hostname.set("testbox");
    app.sampler.ingest(io, snap);
    snap.ts_s = 1002;
    app.sampler.ingest(io, snap);

    const sys = dispatch(&app, io, ctx, "", &s);
    try std.testing.expectEqual(http.Status.ok, sys.status);
    try std.testing.expect(std.mem.find(u8, sys.body, "\"hostname\":\"testbox\"") != null);

    ctx.path = "/api/v1/history";
    const hist = dispatch(&app, io, ctx, "", &s);
    try std.testing.expectEqual(http.Status.ok, hist.status);
    try std.testing.expect(std.mem.startsWith(u8, hist.body, "{\"ts\":[1002]"));

    ctx.method = .POST;
    try std.testing.expectEqual(http.Status.method_not_allowed, dispatch(&app, io, ctx, "", &s).status);
}

test "stream tick emits a snapshot once, then pings" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var app = try testApp(arena.allocator());
    defer app.deinit(io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var last: i64 = 0;
    var last_alerts: u32 = 0;

    try streamTick(&app, io, &out.writer, &last, &last_alerts);
    try std.testing.expectEqualStrings("event: alerts\ndata: {\"alerts\":[]}\n\n: ping\n\n", out.written());

    var snap: @import("agent/collect.zig").Snapshot = .{ .ts_s = 77 };
    snap.hostname.set("streambox");
    app.sampler.ingest(io, snap);
    out.clearRetainingCapacity();
    try streamTick(&app, io, &out.writer, &last, &last_alerts);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "event: snapshot\ndata: {"));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "}\n\n"));
    try std.testing.expect(std.mem.find(u8, out.written(), "streambox") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\ndata: "));

    out.clearRetainingCapacity();
    try streamTick(&app, io, &out.writer, &last, &last_alerts);
    try std.testing.expectEqualStrings(": ping\n\n", out.written());

    var hot: @import("agent/collect.zig").Snapshot = .{ .ts_s = 80 };
    hot.mem = .{ .total_kb = 1000, .available_kb = 20 };
    App.onSample(&app, io, &hot);
    out.clearRetainingCapacity();
    try streamTick(&app, io, &out.writer, &last, &last_alerts);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "event: alerts\ndata: {\"alerts\":[{\"kind\":\"memory_high\""));
    out.clearRetainingCapacity();
    try streamTick(&app, io, &out.writer, &last, &last_alerts);
    try std.testing.expect(std.mem.find(u8, out.written(), "event: alerts") == null);
}

test "alerts route needs a session and reports raised alerts" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var app = try testApp(arena.allocator());
    defer app.deinit(io);
    var s: Scratch = .{};
    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, testCtx(.GET, "/api/v1/alerts"), "", &s).status);

    var hot: @import("agent/collect.zig").Snapshot = .{ .ts_s = 90 };
    hot.mount_count = 1;
    hot.mounts[0].path.set("/data");
    hot.mounts[0].usage = .{ .total_bytes = 100, .free_bytes = 3, .avail_bytes = 3 };
    App.onSample(&app, io, &hot);

    const issued = try app.sessions.create(app.gpa, io, 2, .viewer, 1000);
    var ctx = testCtx(.GET, "/api/v1/alerts");
    ctx.cookie_token = issued.token;
    const r = dispatch(&app, io, ctx, "", &s);
    try std.testing.expectEqual(http.Status.ok, r.status);
    try std.testing.expect(std.mem.find(u8, r.body, "\"subject\":\"/data\"") != null);
    try std.testing.expect(std.mem.find(u8, r.body, "\"level\":\"crit\"") != null);
}

test "docker routes enforce auth, role, csrf and validation before touching docker" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var app = try testApp(arena.allocator());
    defer app.deinit(io);
    app.docker = .{ .io = io, .socket_path = if (@import("builtin").os.tag == .windows) "C:\\Windows\\Temp\\nodos-none.sock" else "/tmp/nodos-none.sock" };
    var s: Scratch = .{};

    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, testCtx(.GET, "/api/v1/docker/containers"), "", &s).status);
    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, testCtx(.POST, "/api/v1/docker/containers/web/restart"), "", &s).status);

    const viewer = try app.sessions.create(app.gpa, io, 2, .viewer, 1000);
    const admin = try app.sessions.create(app.gpa, io, 1, .admin, 1000);

    var v = testCtx(.GET, "/api/v1/docker/containers/web/logs");
    v.cookie_token = viewer.token;
    try std.testing.expectEqual(http.Status.forbidden, dispatch(&app, io, v, "", &s).status);
    v.method = .POST;
    v.path = "/api/v1/docker/containers/web/stop";
    v.csrf = viewer.csrf;
    try std.testing.expectEqual(http.Status.forbidden, dispatch(&app, io, v, "", &s).status);

    var ad = testCtx(.POST, "/api/v1/docker/containers/web/restart");
    ad.cookie_token = admin.token;
    try std.testing.expectEqual(http.Status.forbidden, dispatch(&app, io, ad, "", &s).status);

    ad.csrf = admin.csrf;
    try std.testing.expectEqual(http.Status.service_unavailable, dispatch(&app, io, ad, "", &s).status);

    ad.path = "/api/v1/docker/containers/web/kill";
    try std.testing.expectEqual(http.Status.not_found, dispatch(&app, io, ad, "", &s).status);
    ad.path = "/api/v1/docker/containers/web/rm";
    try std.testing.expectEqual(http.Status.not_found, dispatch(&app, io, ad, "", &s).status);

    ad.path = "/api/v1/docker/containers/..%2f..%2fetc/restart";
    try std.testing.expectEqual(http.Status.bad_request, dispatch(&app, io, ad, "", &s).status);
    ad.path = "/api/v1/docker/containers/-rf/restart";
    try std.testing.expectEqual(http.Status.bad_request, dispatch(&app, io, ad, "", &s).status);

    ad.path = "/api/v1/docker/containers/web/restart";
    ad.method = .GET;
    try std.testing.expectEqual(http.Status.method_not_allowed, dispatch(&app, io, ad, "", &s).status);

    var vl = testCtx(.GET, "/api/v1/docker/containers");
    vl.cookie_token = viewer.token;
    try std.testing.expectEqual(http.Status.service_unavailable, dispatch(&app, io, vl, "", &s).status);

    app.docker = null;
    try std.testing.expectEqualStrings("{\"error\":\"docker integration is turned off\"}", dispatch(&app, io, vl, "", &s).body);
}

test "service routes enforce auth, role, csrf and the allowlist before running anything" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var app = try testApp(arena.allocator());
    defer app.deinit(io);
    const units = [_][]const u8{ "ssh", "nginx" };
    app.systemd = .{ .io = io, .gpa = std.testing.allocator, .units = &units };
    var s: Scratch = .{};

    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, testCtx(.GET, "/api/v1/services"), "", &s).status);
    try std.testing.expectEqual(http.Status.unauthorized, dispatch(&app, io, testCtx(.POST, "/api/v1/services/ssh/restart"), "", &s).status);

    const viewer = try app.sessions.create(app.gpa, io, 2, .viewer, 1000);
    const admin = try app.sessions.create(app.gpa, io, 1, .admin, 1000);

    var v = testCtx(.GET, "/api/v1/services/ssh/logs");
    v.cookie_token = viewer.token;
    try std.testing.expectEqual(http.Status.forbidden, dispatch(&app, io, v, "", &s).status);
    v.method = .POST;
    v.path = "/api/v1/services/ssh/stop";
    v.csrf = viewer.csrf;
    try std.testing.expectEqual(http.Status.forbidden, dispatch(&app, io, v, "", &s).status);

    var ad = testCtx(.POST, "/api/v1/services/ssh/restart");
    ad.cookie_token = admin.token;
    try std.testing.expectEqual(http.Status.forbidden, dispatch(&app, io, ad, "", &s).status);
    ad.csrf = admin.csrf;

    for ([_][]const u8{
        "/api/v1/services/sshd/restart",
        "/api/v1/services/ssh.service/restart",
        "/api/v1/services/--now/restart",
        "/api/v1/services/ssh%20nginx/restart",
        "/api/v1/services/../restart",
        "/api/v1/services/getty@tty1/stop",
    }) |p| {
        ad.path = p;
        try std.testing.expectEqual(http.Status.not_found, dispatch(&app, io, ad, "", &s).status);
    }

    for ([_][]const u8{ "mask", "disable", "kill", "enable", "daemon-reload", "isolate" }) |verb| {
        var pb: [80]u8 = undefined;
        ad.path = try std.fmt.bufPrint(&pb, "/api/v1/services/ssh/{s}", .{verb});
        try std.testing.expectEqual(http.Status.not_found, dispatch(&app, io, ad, "", &s).status);
    }

    ad.path = "/api/v1/services/ssh/restart";
    ad.method = .GET;
    try std.testing.expectEqual(http.Status.method_not_allowed, dispatch(&app, io, ad, "", &s).status);

    app.systemd = null;
    var any = testCtx(.GET, "/api/v1/services");
    any.cookie_token = viewer.token;
    try std.testing.expectEqual(http.Status.service_unavailable, dispatch(&app, io, any, "", &s).status);
}

test "query integer parsing" {
    try std.testing.expectEqual(@as(?usize, 50), queryInt("tail=50", "tail"));
    try std.testing.expectEqual(@as(?usize, 7), queryInt("a=1&tail=7", "tail"));
    try std.testing.expectEqual(@as(?usize, null), queryInt("tail=abc", "tail"));
    try std.testing.expectEqual(@as(?usize, null), queryInt("other=1", "tail"));
    try std.testing.expectEqual(@as(?usize, null), queryInt("", "tail"));
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
    const r = dispatch(&app, io, testCtx(.POST, "/api/v1/login"), "{\"username\":\"alice\",\"password\":\"correct horse battery\"}", &s);
    try std.testing.expectEqual(http.Status.too_many_requests, r.status);
}
