const std = @import("std");
const Io = std.Io;
const Str = @import("../agent/collect.zig").Str;
const Version = @import("version.zig").Version;
const release = @import("release.zig");
const fetch = @import("fetch.zig");
const build_options = @import("build_options");

const log = std.log.scoped(.update);

pub const Info = struct {
    checked_s: i64 = 0,
    failed: bool = false,
    available: bool = false,
    latest: Str(40) = .{},
    page: Str(160) = .{},
    published_s: i64 = 0,
};

pub fn evaluate(arena: std.mem.Allocator, current_text: []const u8, json: []const u8, now_s: i64) Info {
    const current = Version.parse(current_text) catch return .{ .checked_s = now_s, .failed = true };
    const r = release.parse(arena, json) catch return .{ .checked_s = now_s, .failed = true };
    var info: Info = .{ .checked_s = now_s };
    if (r.prerelease or !r.version.newerThan(current)) return info;
    info.available = true;
    info.latest.set(r.tag);
    info.page.set(r.page_url);
    info.published_s = r.published_s;
    return info;
}

pub const Checker = struct {
    mutex: Io.Mutex = .init,
    info: Info = .{},
    announced: Str(40) = .{},

    pub const first_delay_s = 30;
    pub const interval_s = 12 * 60 * 60;

    pub fn copy(c: *Checker, io: Io) Info {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        return c.info;
    }

    fn store(c: *Checker, io: Io, info: Info) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        // a failed check shouldn't wipe a good earlier answer
        if (info.failed) {
            c.info.failed = true;
            return;
        }
        c.info = info;
        if (info.available and !std.mem.eql(u8, c.announced.slice(), info.latest.slice())) {
            c.announced.set(info.latest.slice());
            log.info("NodOS {s} is available (this is {s}). To update: sudo nodos update", .{ info.latest.slice(), build_options.version });
        }
    }

    pub fn checkOnce(c: *Checker, gpa: std.mem.Allocator, io: Io, meta_url: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const now_s = Io.Timestamp.now(io, .real).toSeconds();
        const body = fetch.getOk(arena.allocator(), io, meta_url, 256 * 1024, 20_000) catch |err| {
            log.debug("update check failed: {s}", .{@errorName(err)});
            c.store(io, .{ .checked_s = now_s, .failed = true });
            return;
        };
        c.store(io, evaluate(arena.allocator(), build_options.version, body, now_s));
    }

    pub fn run(c: *Checker, gpa: std.mem.Allocator, io: Io, meta_url: []const u8) Io.Cancelable!void {
        try io.sleep(.fromSeconds(first_delay_s), .awake);
        while (true) {
            c.checkOnce(gpa, io, meta_url);
            try io.sleep(.fromSeconds(interval_s), .awake);
        }
    }
};

pub fn writeJson(w: *Io.Writer, enabled: bool, info: Info) Io.Writer.Error!void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("current");
    try j.write(build_options.version);
    try j.objectField("enabled");
    try j.write(enabled);
    try j.objectField("checked");
    try j.write(info.checked_s);
    try j.objectField("failed");
    try j.write(info.failed);
    try j.objectField("available");
    try j.write(info.available);
    try j.objectField("latest");
    try j.write(info.latest.slice());
    try j.objectField("page");
    try j.write(info.page.slice());
    try j.objectField("command");
    try j.write("sudo nodos update");
    try j.endObject();
}

fn meta(comptime tag: []const u8, comptime extra: []const u8) []const u8 {
    return "{\"tag_name\":\"" ++ tag ++ "\",\"draft\":false," ++ extra ++ "\"published_at\":\"2026-11-09T05:00:01Z\",\"html_url\":\"https://example.test/rel\"}";
}

test "a newer release is reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const i = evaluate(arena.allocator(), "0.1.0", meta("v0.2.0", ""), 5000);
    try std.testing.expect(i.available);
    try std.testing.expect(!i.failed);
    try std.testing.expectEqualStrings("v0.2.0", i.latest.slice());
    try std.testing.expectEqualStrings("https://example.test/rel", i.page.slice());
    try std.testing.expectEqual(@as(i64, 5000), i.checked_s);
}

test "same, older, and prerelease versions are not offered" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!evaluate(a, "0.2.0", meta("v0.2.0", ""), 1).available);
    try std.testing.expect(!evaluate(a, "0.3.0", meta("v0.2.0", ""), 1).available);
    try std.testing.expect(!evaluate(a, "0.1.0", meta("v0.2.0", "\"prerelease\":true,"), 1).available);
    try std.testing.expect(!evaluate(a, "0.1.0", meta("v0.2.0-rc.1", ""), 1).available);
    try std.testing.expect(evaluate(a, "0.1.0-dev", meta("v0.1.0", ""), 1).available);
}

test "garbage in is a failed check, never a false alarm" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = evaluate(a, "0.1.0", "<html>captive portal</html>", 9);
    try std.testing.expect(bad.failed and !bad.available);
    try std.testing.expect(evaluate(a, "not a version", meta("v0.2.0", ""), 9).failed);
    try std.testing.expect(evaluate(a, "0.1.0", "{\"tag_name\":\"v1.0.0/../x\"}", 9).failed);
}

test "a failed attempt keeps the last good answer" {
    const io = std.testing.io;
    var c: Checker = .{};
    var good: Info = .{ .checked_s = 100, .available = true };
    good.latest.set("v9.9.9");
    c.store(io, good);
    c.store(io, .{ .checked_s = 200, .failed = true });
    const got = c.copy(io);
    try std.testing.expect(got.available);
    try std.testing.expect(got.failed);
    try std.testing.expectEqual(@as(i64, 100), got.checked_s);
    try std.testing.expectEqualStrings("v9.9.9", got.latest.slice());
}

test "json shape" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var info: Info = .{ .checked_s = 7, .available = true };
    info.latest.set("v1.2.3");
    try writeJson(&out.writer, true, info);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expect(o.get("available").?.bool);
    try std.testing.expectEqualStrings("v1.2.3", o.get("latest").?.string);
    try std.testing.expectEqualStrings("sudo nodos update", o.get("command").?.string);
    try std.testing.expectEqualStrings(build_options.version, o.get("current").?.string);
}
