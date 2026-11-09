//! Docker Engine API over its Unix socket.
//!
//! Security notes, because this is the riskiest module in the project:
//!  - Access to the Docker socket is root-equivalent on the host. Everything
//!    here is reachable only from authenticated, CSRF-protected endpoints and
//!    destructive actions are admin-only and audited by the caller.
//!  - Container references are validated against a strict charset before they
//!    go anywhere near a request line. There is no shell and no string passed
//!    through one; the only "command" is one of three fixed verbs.
//!  - We send HTTP/1.0 so the daemon replies with a plain body that ends at
//!    EOF. No chunked decoding on the hot path, and the connection is closed
//!    after each request, so there is no state to leak between users.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const Client = struct {
    io: Io,
    socket_path: []const u8,
    /// A wedged daemon must not wedge us. Without a deadline each dashboard
    /// poll against a hung dockerd would pin a connection slot forever.
    timeout_ms: u32 = 8000,

    pub const Error = error{
        /// Socket missing, refused, or permission denied.
        Unavailable,
        /// Connected, but no complete answer inside `timeout_ms`.
        TimedOut,
        BadResponse,
        ResponseTooLarge,
        InvalidTarget,
        OutOfMemory,
    };

    pub const Response = struct {
        status: u16,
        /// Points into the arena passed to `request`.
        body: []const u8,
    };

    /// One request, one connection. `arena` owns the returned body.
    pub fn request(c: Client, arena: Allocator, method: []const u8, target: []const u8, max_body: usize) Error!Response {
        // Belt and braces: callers validate ids, this stops a bug there from
        // becoming request smuggling.
        if (std.mem.findAny(u8, target, " \r\n\t") != null) return error.InvalidTarget;
        if (std.mem.findAny(u8, method, " \r\n\t") != null) return error.InvalidTarget;

        // Dev builds only: `docker_socket = fake` serves invented containers
        // so the UI can be built without a daemon. Compiled out otherwise.
        if (comptime build_options.fake_host) {
            if (std.mem.eql(u8, c.socket_path, "fake")) return fake.respond(arena, method, target);
        }

        // Race the exchange against a timer; whichever finishes first wins and
        // the other is cancelled (which interrupts a blocked read).
        const Race = union(enum) {
            reply: Error!Response,
            timer: Io.Cancelable!void,
        };
        var slots: [2]Race = undefined;
        var sel: Io.Select(Race) = .init(c.io, &slots);
        sel.concurrent(.reply, exchange, .{ c, arena, method, target, max_body }) catch return error.Unavailable;
        sel.concurrent(.timer, sleepMs, .{ c.io, c.timeout_ms }) catch {
            sel.cancelDiscard();
            return error.Unavailable;
        };
        const first = sel.await() catch {
            sel.cancelDiscard();
            return error.Unavailable;
        };
        // Stop the loser and wait for it, so nothing touches the arena after we return.
        sel.cancelDiscard();
        return switch (first) {
            .reply => |r| r,
            .timer => error.TimedOut,
        };
    }

    fn sleepMs(io: Io, ms: u32) Io.Cancelable!void {
        try io.sleep(.fromMilliseconds(ms), .awake);
    }

    fn exchange(c: Client, arena: Allocator, method: []const u8, target: []const u8, max_body: usize) Error!Response {
        const addr = Io.net.UnixAddress.init(c.socket_path) catch return error.Unavailable;
        const stream = addr.connect(c.io) catch return error.Unavailable;
        defer stream.close(c.io);

        var wbuf: [1024]u8 = undefined;
        var w = stream.writer(c.io, &wbuf);
        w.interface.print(
            "{s} {s} HTTP/1.0\r\nHost: docker\r\nUser-Agent: nodos\r\nAccept: application/json\r\nContent-Length: 0\r\n\r\n",
            .{ method, target },
        ) catch return error.Unavailable;
        w.interface.flush() catch return error.Unavailable;

        var rbuf: [4096]u8 = undefined;
        var r = stream.reader(c.io, &rbuf);
        // Headers add a few hundred bytes on top of the body limit.
        const raw = r.interface.allocRemaining(arena, .limited(max_body + 8192)) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unavailable,
        };
        const resp = try parseResponse(arena, raw);
        if (resp.body.len > max_body) return error.ResponseTooLarge;
        return resp;
    }
};

/// Splits a raw HTTP response into status and body, decoding chunked bodies
/// in case a daemon chunks even though we asked for HTTP/1.0.
pub fn parseResponse(arena: Allocator, raw: []const u8) Client.Error!Client.Response {
    const head_end = std.mem.find(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    const head = raw[0..head_end];
    const body = raw[head_end + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    // "HTTP/1.0 200 OK"
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    const proto = parts.next() orelse return error.BadResponse;
    if (!std.mem.startsWith(u8, proto, "HTTP/1.")) return error.BadResponse;
    const code = parts.next() orelse return error.BadResponse;
    const status = std.fmt.parseInt(u16, code, 10) catch return error.BadResponse;

    var chunked = false;
    while (lines.next()) |l| {
        const colon = std.mem.findScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(l[0..colon], "transfer-encoding") and
            std.ascii.findIgnoreCase(l[colon + 1 ..], "chunked") != null) chunked = true;
    }
    if (!chunked) return .{ .status = status, .body = body };
    return .{ .status = status, .body = try dechunk(arena, body) };
}

fn dechunk(arena: Allocator, body: []const u8) Client.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (true) {
        const nl = std.mem.findPos(u8, body, i, "\r\n") orelse return error.BadResponse;
        const size_txt = std.mem.trim(u8, body[i..nl], " \t");
        // chunk extensions (";...") are legal and ignored
        const size_end = std.mem.findScalar(u8, size_txt, ';') orelse size_txt.len;
        const size = std.fmt.parseInt(usize, size_txt[0..size_end], 16) catch return error.BadResponse;
        i = nl + 2;
        if (size == 0) break;
        if (i + size > body.len) return error.BadResponse;
        try out.appendSlice(arena, body[i .. i + size]);
        i += size + 2; // data + trailing CRLF
        if (i > body.len) return error.BadResponse;
    }
    return out.items;
}

// ---------------------------------------------------------------- validation

/// Container id or name. Docker names allow [a-zA-Z0-9][a-zA-Z0-9_.-]*, ids are
/// hex. One rule covers both, and nothing in it can alter a URL.
pub fn validRef(ref: []const u8) bool {
    if (ref.len == 0 or ref.len > 64) return false;
    if (!std.ascii.isAlphanumeric(ref[0])) return false;
    for (ref) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
    }
    return true;
}

pub const Action = enum {
    start,
    stop,
    restart,

    pub fn parse(s: []const u8) ?Action {
        return std.meta.stringToEnum(Action, s);
    }
};

pub const ActionResult = enum { done, unchanged, not_found, failed };

pub fn classifyAction(status: u16) ActionResult {
    return switch (status) {
        204 => .done,
        304 => .unchanged, // already running / already stopped
        404 => .not_found,
        else => .failed,
    };
}

pub fn runAction(c: Client, arena: Allocator, ref: []const u8, action: Action) Client.Error!ActionResult {
    if (!validRef(ref)) return error.InvalidTarget;
    var buf: [160]u8 = undefined;
    // Ten second grace on stop/restart, the Docker CLI default.
    const target = switch (action) {
        .start => std.fmt.bufPrint(&buf, "/containers/{s}/start", .{ref}),
        .stop => std.fmt.bufPrint(&buf, "/containers/{s}/stop?t=10", .{ref}),
        .restart => std.fmt.bufPrint(&buf, "/containers/{s}/restart?t=10", .{ref}),
    } catch return error.InvalidTarget;
    const resp = try c.request(arena, "POST", target, 64 * 1024);
    return classifyAction(resp.status);
}

// ---------------------------------------------------------------- listing

pub const Container = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    state: []const u8,
    status: []const u8,
    created: i64,
};

const Raw = struct {
    Id: []const u8 = "",
    Names: []const []const u8 = &.{},
    Image: []const u8 = "",
    State: []const u8 = "",
    Status: []const u8 = "",
    Created: i64 = 0,
};

/// The API response has to fit one fixed buffer, so very large hosts see the
/// first 64 and a `total` they can compare against. Pagination comes later.
pub const max_containers = 64;

pub const Listing = struct {
    items: []Container,
    /// How many containers the daemon reported, before the cap.
    total: usize,
};

pub fn listContainers(c: Client, arena: Allocator) (Client.Error || error{BadJson})!Listing {
    const resp = try c.request(arena, "GET", "/containers/json?all=1", 2 * 1024 * 1024);
    if (resp.status != 200) return error.BadResponse;
    return parseContainers(arena, resp.body);
}

pub fn parseContainers(arena: Allocator, body: []const u8) (Client.Error || error{BadJson})!Listing {
    const raw = std.json.parseFromSliceLeaky([]Raw, arena, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadJson,
    };
    const n = @min(raw.len, max_containers);
    const out = try arena.alloc(Container, n);
    for (raw[0..n], out) |r, *o| {
        var name: []const u8 = if (r.Names.len > 0) r.Names[0] else "";
        if (std.mem.startsWith(u8, name, "/")) name = name[1..];
        o.* = .{
            .id = r.Id[0..@min(r.Id.len, 12)],
            .name = name,
            .image = r.Image,
            .state = r.State,
            .status = r.Status,
            .created = r.Created,
        };
    }
    return .{ .items = out, .total = raw.len };
}

pub fn writeContainers(w: *Io.Writer, list: Listing) Io.Writer.Error!void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("total");
    try j.write(list.total);
    try j.objectField("containers");
    try j.beginArray();
    for (list.items) |c| {
        try j.beginObject();
        try j.objectField("id");
        try j.write(c.id);
        try j.objectField("name");
        try j.write(c.name);
        try j.objectField("image");
        try j.write(c.image);
        try j.objectField("state");
        try j.write(c.state);
        try j.objectField("status");
        try j.write(c.status);
        try j.objectField("created");
        try j.write(c.created);
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
}

// ---------------------------------------------------------------- logs

/// Docker multiplexes stdout and stderr into 8 byte framed chunks unless the
/// container has a TTY. Returns the plain text either way.
pub fn demuxLogs(arena: Allocator, body: []const u8) Allocator.Error![]const u8 {
    const framed = body.len >= 8 and body[0] <= 2 and body[1] == 0 and body[2] == 0 and body[3] == 0;
    if (!framed) return body;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 8 <= body.len) {
        const len = std.mem.readInt(u32, body[i + 4 ..][0..4], .big);
        i += 8;
        const end = @min(body.len, i + len);
        try out.appendSlice(arena, body[i..end]);
        i = end;
    }
    return out.items;
}

/// Replaces bytes that would make the JSON invalid. Log output is arbitrary
/// bytes, and a binary blob in one container must not break the page.
fn sanitize(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    const out = try arena.dupe(u8, s);
    var i: usize = 0;
    while (i < out.len) {
        const n = std.unicode.utf8ByteSequenceLength(out[i]) catch {
            out[i] = '?';
            i += 1;
            continue;
        };
        if (i + n > out.len or !std.unicode.utf8ValidateSlice(out[i .. i + n])) {
            out[i] = '?';
            i += 1;
            continue;
        }
        i += n;
    }
    return out;
}

/// Last `tail` lines as {"lines":[...],"truncated":bool}. Output stops once
/// `w` is nearly full instead of failing, and says so.
pub fn writeLogs(arena: Allocator, w: *Io.Writer, text: []const u8, tail: usize) (Io.Writer.Error || Allocator.Error)!void {
    const clean = try sanitize(arena, text);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, clean, '\n');
    while (it.next()) |l| {
        const trimmed = std.mem.trimEnd(u8, l, "\r");
        if (trimmed.len == 0 and it.peek() == null) break; // trailing newline
        try lines.append(arena, trimmed);
    }
    const start = lines.items.len -| tail;

    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("lines");
    try j.beginArray();
    var truncated = start > 0 and false;
    for (lines.items[start..]) |l| {
        // Leave headroom for the closing brackets and the flag.
        if (w.buffered().len + l.len * 2 + 64 > w.buffer.len - 64) {
            truncated = true;
            break;
        }
        try j.write(l);
    }
    try j.endArray();
    try j.objectField("truncated");
    try j.write(truncated);
    try j.endObject();
}

pub fn fetchLogs(c: Client, arena: Allocator, ref: []const u8, tail: usize) Client.Error![]const u8 {
    if (!validRef(ref)) return error.InvalidTarget;
    var buf: [200]u8 = undefined;
    const target = std.fmt.bufPrint(&buf, "/containers/{s}/logs?stdout=1&stderr=1&timestamps=0&tail={d}", .{ ref, tail }) catch return error.InvalidTarget;
    const resp = try c.request(arena, "GET", target, 1024 * 1024);
    if (resp.status == 404) return error.BadResponse;
    if (resp.status != 200) return error.BadResponse;
    return demuxLogs(arena, resp.body);
}

// ---------------------------------------------------------------- dev fake

/// Stateful pretend daemon for `-Dfake-host=true`. Not thread safe and not
/// meant to be: one developer clicking buttons.
const fake = struct {
    const Entry = struct { id: []const u8, name: []const u8, image: []const u8, up_status: []const u8 };
    const entries = [_]Entry{
        .{ .id = "3f4a9c1d2b7e8a00", .name = "/web", .image = "nginx:1.27", .up_status = "Up 2 hours" },
        .{ .id = "91be04c7aa210f33", .name = "/postgres", .image = "postgres:16", .up_status = "Up 9 days" },
        .{ .id = "c0ffee11223344aa", .name = "/jellyfin", .image = "jellyfin/jellyfin:10.9", .up_status = "Up 3 days (healthy)" },
        .{ .id = "d15ea5e000112233", .name = "/backup-job", .image = "restic/restic", .up_status = "Up 1 minute" },
        .{ .id = "babe1234deadbeef", .name = "/old-test", .image = "busybox", .up_status = "Up 5 seconds" },
    };
    var running = [_]bool{ true, true, true, false, false };

    fn respond(arena: Allocator, method: []const u8, target: []const u8) Client.Error!Client.Response {
        if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, target, "/containers/json")) {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (entries, 0..) |e, i| {
                if (i > 0) try out.append(arena, ',');
                const state = if (running[i]) "running" else "exited";
                const status = if (running[i]) e.up_status else "Exited (0) 4 hours ago";
                try out.print(arena, "{{\"Id\":\"{s}\",\"Names\":[\"{s}\"],\"Image\":\"{s}\",\"State\":\"{s}\",\"Status\":\"{s}\",\"Created\":1700000000}}", .{ e.id, e.name, e.image, state, status });
            }
            try out.append(arena, ']');
            return .{ .status = 200, .body = out.items };
        }
        const prefix = "/containers/";
        if (!std.mem.startsWith(u8, target, prefix)) return .{ .status = 404, .body = "" };
        const rest = target[prefix.len..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse return .{ .status = 404, .body = "" };
        const ref = rest[0..slash];
        var verb = rest[slash + 1 ..];
        if (std.mem.findScalar(u8, verb, '?')) |q| verb = verb[0..q];
        const idx = for (entries, 0..) |e, i| {
            if (std.mem.startsWith(u8, e.id, ref) or std.mem.eql(u8, e.name[1..], ref)) break i;
        } else return .{ .status = 404, .body = "" };

        if (std.mem.eql(u8, verb, "logs")) {
            const text = try std.fmt.allocPrint(arena, "{s} starting\nlistening on :8080\nGET /health 200 1ms\nGET /health 200 1ms\nwarn: slow request took 812ms\n", .{entries[idx].name[1..]});
            // framed like a real non-TTY container
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, &.{ 1, 0, 0, 0 });
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, @intCast(text.len), .big);
            try out.appendSlice(arena, &len);
            try out.appendSlice(arena, text);
            return .{ .status = 200, .body = out.items };
        }
        if (std.mem.eql(u8, verb, "start")) {
            const was = running[idx];
            running[idx] = true;
            return .{ .status = if (was) 304 else 204, .body = "" };
        }
        if (std.mem.eql(u8, verb, "stop")) {
            const was = running[idx];
            running[idx] = false;
            return .{ .status = if (was) 204 else 304, .body = "" };
        }
        if (std.mem.eql(u8, verb, "restart")) {
            running[idx] = true;
            return .{ .status = 204, .body = "" };
        }
        return .{ .status = 404, .body = "" };
    }
};

// ---------------------------------------------------------------- tests

test "ref validation rejects anything that could alter a request" {
    try std.testing.expect(validRef("web"));
    try std.testing.expect(validRef("my_app-1.2"));
    try std.testing.expect(validRef("3f4a9c1d2b7e"));
    try std.testing.expect(!validRef(""));
    try std.testing.expect(!validRef("-leading-dash"));
    try std.testing.expect(!validRef("a/b"));
    try std.testing.expect(!validRef("a b"));
    try std.testing.expect(!validRef("a?x=1"));
    try std.testing.expect(!validRef("a\r\nHost: evil"));
    try std.testing.expect(!validRef("../../etc"));
    const long: [65]u8 = @splat('a');
    try std.testing.expect(!validRef(&long));
}

test "actions parse and classify" {
    try std.testing.expectEqual(Action.restart, Action.parse("restart").?);
    try std.testing.expect(Action.parse("kill") == null);
    try std.testing.expect(Action.parse("rm") == null);
    try std.testing.expectEqual(ActionResult.done, classifyAction(204));
    try std.testing.expectEqual(ActionResult.unchanged, classifyAction(304));
    try std.testing.expectEqual(ActionResult.not_found, classifyAction(404));
    try std.testing.expectEqual(ActionResult.failed, classifyAction(500));
}

test "response parsing, plain and chunked" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = try parseResponse(a, "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n[1,2]");
    try std.testing.expectEqual(@as(u16, 200), plain.status);
    try std.testing.expectEqualStrings("[1,2]", plain.body);

    const chunked = try parseResponse(a, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4;ext=1\r\ndefg\r\n0\r\n\r\n");
    try std.testing.expectEqualStrings("abcdefg", chunked.body);

    try std.testing.expectError(error.BadResponse, parseResponse(a, "garbage"));
    try std.testing.expectError(error.BadResponse, parseResponse(a, "FTP/1.0 200 OK\r\n\r\n"));
    try std.testing.expectError(error.BadResponse, parseResponse(a, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"));
}

const containers_fixture =
    \\[{"Id":"3f4a9c1d2b7e8a0011223344556677889900aabbccddeeff00112233445566ff","Names":["/web"],
    \\"Image":"nginx:1.27","ImageID":"sha256:x","Command":"nginx","Created":1700000000,
    \\"Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],
    \\"Labels":{"a":"b"},"State":"running","Status":"Up 2 hours","HostConfig":{"NetworkMode":"bridge"}},
    \\{"Id":"aaaa","Names":[],"Image":"busybox","State":"exited","Status":"Exited (0) 3 days ago","Created":5}]
;

test "container list parses and encodes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parseContainers(a, containers_fixture);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(usize, 2), list.total);
    try std.testing.expectEqualStrings("3f4a9c1d2b7e", list.items[0].id);
    try std.testing.expectEqualStrings("web", list.items[0].name);
    try std.testing.expectEqualStrings("", list.items[1].name);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeContainers(&out.writer, list);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("containers").?.array.items.len);

    try std.testing.expectError(error.BadJson, parseContainers(a, "{\"not\":\"a list\"}"));
}

test "log demux handles framed and tty output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // stdout "hello\n" then stderr "oops\n"
    const framed = "\x01\x00\x00\x00\x00\x00\x00\x06hello\n\x02\x00\x00\x00\x00\x00\x00\x05oops\n";
    try std.testing.expectEqualStrings("hello\noops\n", try demuxLogs(a, framed));
    try std.testing.expectEqualStrings("plain tty text\n", try demuxLogs(a, "plain tty text\n"));
    // frame claims more bytes than exist: take what is there, don't read past the end
    try std.testing.expectEqualStrings("hi", try demuxLogs(a, "\x01\x00\x00\x00\x00\x00\x00\x63hi"));
}

test "logs encode as json, tail, and survive binary garbage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeLogs(a, &w, "one\ntwo\nthree \xff\xfe bad\nfour\n", 3);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const lines = parsed.value.object.get("lines").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("two", lines[0].string);
    try std.testing.expect(std.mem.startsWith(u8, lines[1].string, "three ?? bad"));
    try std.testing.expectEqualStrings("four", lines[2].string);
    try std.testing.expect(!parsed.value.object.get("truncated").?.bool);
}

test "logs truncate instead of overflowing the output buffer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    for (0..200) |i| try src.print(a, "line number {d} with some padding text to take space\n", .{i});
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeLogs(a, &w, src.items, 500);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
}

// A fake daemon on a real Unix socket: accepts one connection, checks the
// request line, answers with a canned response.
fn fakeDaemon(io: Io, server: *Io.net.Server, expect_line: []const u8, response: []const u8, ok: *bool) Io.Cancelable!void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [2048]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const line = r.interface.takeDelimiter('\n') catch return;
    ok.* = line != null and std.mem.startsWith(u8, line.?, expect_line);
    // drain the rest of the headers
    while (true) {
        const l = r.interface.takeDelimiter('\n') catch break;
        if (l == null or std.mem.trim(u8, l.?, "\r").len == 0) break;
    }
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(response) catch return;
    w.interface.flush() catch return;
}

test "client talks to a fake daemon over a unix socket" {
    const io = std.testing.io;
    var path_buf: [96]u8 = undefined;
    var nonce_bytes: [4]u8 = undefined;
    io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u32, &nonce_bytes, .little);
    const sock_path = try std.fmt.bufPrint(&path_buf, "{s}nodos-docker-test-{x}.sock", .{ if (@import("builtin").os.tag == .windows) "C:\\Windows\\Temp\\" else "/tmp/", nonce });
    const addr = try Io.net.UnixAddress.init(sock_path);
    var server = addr.listen(io, .{}) catch |err| switch (err) {
        // Some sandboxes forbid Unix sockets; that is not a bug in the client.
        error.AddressFamilyUnsupported, error.AccessDenied, error.PermissionDenied, error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit(io);
    defer Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var ok = false;
    var fut = io.async(fakeDaemon, .{ io, &server, "GET /containers/json?all=1 HTTP/1.0", "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" ++ containers_fixture, &ok });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const client: Client = .{ .io = io, .socket_path = sock_path };
    const list = try listContainers(client, arena.allocator());
    fut.await(io) catch {};
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("web", list.items[0].name);
}

// A daemon that takes the connection and then says nothing, like a wedged dockerd.
fn silentDaemon(io: Io, server: *Io.net.Server) Io.Cancelable!void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [512]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    // Read the request, then hold the connection open without answering.
    _ = r.interface.takeDelimiter('\n') catch return;
    try io.sleep(.fromSeconds(30), .awake);
}

test "a daemon that never answers times out instead of hanging" {
    const io = std.testing.io;
    var path_buf: [96]u8 = undefined;
    var nonce_bytes: [4]u8 = undefined;
    io.random(&nonce_bytes);
    const nonce = std.mem.readInt(u32, &nonce_bytes, .little);
    const sock_path = try std.fmt.bufPrint(&path_buf, "{s}nodos-silent-{x}.sock", .{ if (@import("builtin").os.tag == .windows) "C:\\Windows\\Temp\\" else "/tmp/", nonce });
    const addr = try Io.net.UnixAddress.init(sock_path);
    var server = addr.listen(io, .{}) catch |err| switch (err) {
        error.AddressFamilyUnsupported, error.AccessDenied, error.PermissionDenied, error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit(io);
    defer Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var fut = io.async(silentDaemon, .{ io, &server });
    defer fut.cancel(io) catch {};

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const client: Client = .{ .io = io, .socket_path = sock_path, .timeout_ms = 300 };
    const started = Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.TimedOut, client.request(arena.allocator(), "GET", "/containers/json", 1024));
    const took_ms = started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    // generous upper bound: the point is "about a third of a second", not 30 s
    try std.testing.expect(took_ms < 5000);
}

test "client reports unavailable when the socket does not exist" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Missing file in a directory that exists, so every OS reports "not found"
    // the ordinary way instead of a surprising status code.
    const missing = if (@import("builtin").os.tag == .windows) "C:\\Windows\\Temp\\nodos-no-such.sock" else "/tmp/nodos-no-such.sock";
    const client: Client = .{ .io = std.testing.io, .socket_path = missing };
    try std.testing.expectError(error.Unavailable, client.request(arena.allocator(), "GET", "/containers/json", 1024));
    try std.testing.expectError(error.InvalidTarget, client.request(arena.allocator(), "GET", "/a b", 1024));
    try std.testing.expectError(error.InvalidTarget, runAction(client, arena.allocator(), "../x", .start));
}
