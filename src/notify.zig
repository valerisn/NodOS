const std = @import("std");
const Io = std.Io;
const alerts = @import("alerts.zig");
const version = @import("build_options").version;

pub const max_in_flight: u32 = 8;
pub const timeout_ms: u32 = 8000;
pub const max_url = 512;

pub fn urlOk(url: []const u8) bool {
    if (url.len > max_url) return false;
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return false;
    if (rest.len == 0 or rest[0] == '/' or rest[0] == ':') return false;
    for (url) |c| if (c <= ' ' or c == 0x7f) return false;
    return true;
}

pub fn writePayload(w: *Io.Writer, host: []const u8, ev: alerts.Event) Io.Writer.Error!void {
    var text_buf: [256]u8 = undefined;
    const verb = switch (ev.what) {
        .raised => "raised",
        .escalated => "escalated",
        .cleared => "cleared",
    };
    const text = std.fmt.bufPrint(&text_buf, "[{s}] {s} {s}: {s} {s} ({d:.1})", .{
        host,
        verb,
        @tagName(ev.alert.level),
        ev.alert.kind.title(),
        ev.alert.subject.slice(),
        ev.alert.value,
    }) catch "NodOS alert";

    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("text");
    try s.write(text);
    try s.objectField("content");
    try s.write(text);
    try s.objectField("host");
    try s.write(host);
    try s.objectField("event");
    try s.write(verb);
    try s.objectField("kind");
    try s.write(@tagName(ev.alert.kind));
    try s.objectField("subject");
    try s.write(ev.alert.subject.slice());
    try s.objectField("level");
    try s.write(@tagName(ev.alert.level));
    try s.objectField("value");
    try s.write(ev.alert.value);
    try s.endObject();
}

pub const Job = struct {
    gpa: std.mem.Allocator,
    inflight: *std.atomic.Value(u32),
    url: []u8,
    body: []u8,
};

/// Reserves a slot and a copy of everything the task needs. Null means the
/// queue is full or memory is short; the caller just drops the notification.
pub fn prepare(
    gpa: std.mem.Allocator,
    inflight: *std.atomic.Value(u32),
    url: []const u8,
    host: []const u8,
    ev: alerts.Event,
) ?*Job {
    if (inflight.fetchAdd(1, .acq_rel) >= max_in_flight) {
        _ = inflight.fetchSub(1, .acq_rel);
        return null;
    }
    const job = gpa.create(Job) catch {
        _ = inflight.fetchSub(1, .acq_rel);
        return null;
    };
    var aw: Io.Writer.Allocating = .init(gpa);
    writePayload(&aw.writer, host, ev) catch {
        aw.deinit();
        gpa.destroy(job);
        _ = inflight.fetchSub(1, .acq_rel);
        return null;
    };
    const body = aw.toOwnedSlice() catch {
        aw.deinit();
        gpa.destroy(job);
        _ = inflight.fetchSub(1, .acq_rel);
        return null;
    };
    const url_copy = gpa.dupe(u8, url) catch {
        gpa.free(body);
        gpa.destroy(job);
        _ = inflight.fetchSub(1, .acq_rel);
        return null;
    };
    job.* = .{ .gpa = gpa, .inflight = inflight, .url = url_copy, .body = body };
    return job;
}

pub fn deliver(io: Io, job: *Job) void {
    const gpa = job.gpa;
    defer {
        _ = job.inflight.fetchSub(1, .acq_rel);
        gpa.free(job.url);
        gpa.free(job.body);
        gpa.destroy(job);
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const code = post(arena.allocator(), io, job.url, job.body) catch |err| {
        std.log.scoped(.notify).warn("webhook failed: {s}", .{@errorName(err)});
        return;
    };
    if (code < 200 or code >= 300) std.log.scoped(.notify).warn("webhook answered {d}", .{code});
}

pub const PostError = error{ Unreachable, TimedOut, OutOfMemory };

pub fn post(arena: std.mem.Allocator, io: Io, url: []const u8, body: []const u8) PostError!u16 {
    const Race = union(enum) {
        reply: PostError!u16,
        timer: Io.Cancelable!void,
    };
    var slots: [2]Race = undefined;
    var sel: Io.Select(Race) = .init(io, &slots);
    sel.concurrent(.reply, exchange, .{ arena, io, url, body }) catch return error.Unreachable;
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

fn exchange(arena: std.mem.Allocator, io: Io, url: []const u8, body: []const u8) PostError!u16 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var ua_buf: [64]u8 = undefined;
    const ua = std.fmt.bufPrint(&ua_buf, "nodos/{s}", .{version}) catch "nodos";

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = .{
            .user_agent = .{ .override = ua },
            .content_type = .{ .override = "application/json" },
        },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unreachable,
    };
    return @backingInt(result.status);
}

fn sampleEvent() alerts.Event {
    var a: alerts.Alert = .{ .kind = .disk_high, .level = .crit, .value = 96.25, .since_s = 0 };
    a.subject.set("/mnt/\"data\"");
    return .{ .what = .raised, .alert = a };
}

test "urls: http and https only, no spaces, needs a host" {
    try std.testing.expect(urlOk("https://ntfy.sh/mytopic"));
    try std.testing.expect(urlOk("http://192.168.1.20:8080/hook"));
    try std.testing.expect(!urlOk("ftp://x/y"));
    try std.testing.expect(!urlOk("file:///etc/passwd"));
    try std.testing.expect(!urlOk("https://"));
    try std.testing.expect(!urlOk("https:///x"));
    try std.testing.expect(!urlOk("https://a b/"));
    try std.testing.expect(!urlOk("https://a/\r\nX: y"));
    try std.testing.expect(!urlOk(""));
}

test "payload is valid json and escapes whatever the subject holds" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writePayload(&aw.writer, "box\"1", sampleEvent());
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqualStrings("box\"1", o.get("host").?.string);
    try std.testing.expectEqualStrings("disk_high", o.get("kind").?.string);
    try std.testing.expectEqualStrings("/mnt/\"data\"", o.get("subject").?.string);
    try std.testing.expectEqualStrings("raised", o.get("event").?.string);
    try std.testing.expect(std.mem.find(u8, o.get("text").?.string, "Disk nearly full") != null);
}

test "in-flight cap drops extra notifications" {
    const gpa = std.testing.allocator;
    var inflight: std.atomic.Value(u32) = .init(0);
    var jobs: [max_in_flight]*Job = undefined;
    for (&jobs) |*j| j.* = prepare(gpa, &inflight, "https://x.test/h", "h", sampleEvent()).?;
    try std.testing.expect(prepare(gpa, &inflight, "https://x.test/h", "h", sampleEvent()) == null);
    try std.testing.expectEqual(max_in_flight, inflight.load(.monotonic));
    for (jobs) |j| {
        _ = j.inflight.fetchSub(1, .acq_rel);
        gpa.free(j.url);
        gpa.free(j.body);
        gpa.destroy(j);
    }
}

fn captureServer(io: Io, server: *Io.net.Server, out: []u8, got: *usize) Io.Cancelable!void {
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
        if (std.ascii.startsWithIgnoreCase(t, "content-length:"))
            content_len = std.fmt.parseInt(usize, std.mem.trim(u8, t["content-length:".len..], " "), 10) catch 0;
        if (len + t.len + 1 <= out.len) {
            @memcpy(out[len..][0..t.len], t);
            out[len + t.len] = '\n';
            len += t.len + 1;
        }
    }
    var left = content_len;
    while (left > 0 and len < out.len) {
        const b = r.interface.takeByte() catch break;
        out[len] = b;
        len += 1;
        left -= 1;
    }
    got.* = len;
    var wbuf: [128]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n") catch return;
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

test "a notification is posted as json and the job cleans up" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var l = try listenLocal(io);
    defer l.server.deinit(io);
    var seen: [4096]u8 = undefined;
    var got: usize = 0;
    var fut = io.async(captureServer, .{ io, &l.server, &seen, &got });
    defer fut.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hook", .{l.port});
    var inflight: std.atomic.Value(u32) = .init(0);
    const job = prepare(gpa, &inflight, url, "testbox", sampleEvent()).?;
    deliver(io, job);
    try fut.await(io);

    const req = seen[0..got];
    try std.testing.expect(std.mem.startsWith(u8, req, "POST /hook"));
    try std.testing.expect(std.ascii.findIgnoreCase(req, "content-type: application/json") != null);
    try std.testing.expect(std.mem.find(u8, req, "\"host\":\"testbox\"") != null);
    try std.testing.expectEqual(@as(u32, 0), inflight.load(.monotonic));
}

test "an unreachable endpoint fails quietly and frees its slot" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var l = try listenLocal(io);
    const port = l.port;
    l.server.deinit(io);
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hook", .{port});
    var inflight: std.atomic.Value(u32) = .init(0);
    const job = prepare(gpa, &inflight, url, "testbox", sampleEvent()).?;
    deliver(io, job);
    try std.testing.expectEqual(@as(u32, 0), inflight.load(.monotonic));
}
