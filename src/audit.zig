const std = @import("std");
const Io = std.Io;

pub const Event = struct {
    ts: i64,
    actor: []const u8,
    action: []const u8,
    target: []const u8 = "",
    ok: bool,
    ip: []const u8 = "",
};

pub fn format(w: *Io.Writer, ev: Event) Io.Writer.Error!void {
    std.json.Stringify.value(ev, .{}, w) catch return error.WriteFailed;
    try w.writeByte('\n');
}

pub fn writeEntries(w: *Io.Writer, tail: []const u8, from_start: bool, limit: usize) Io.Writer.Error!void {
    var body = tail;
    if (!from_start) {
        const nl = std.mem.findScalar(u8, body, '\n') orelse return w.writeAll("{\"entries\":[]}");
        body = body[nl + 1 ..];
    }
    try w.writeAll("{\"entries\":[");
    var first = true;
    var count: usize = 0;
    var end = body.len;
    while (end > 0 and count < limit) {
        var stop = end;
        if (body[stop - 1] == '\n') stop -= 1;
        const start = if (std.mem.findScalarLast(u8, body[0..stop], '\n')) |p| p + 1 else 0;
        const line = body[start..stop];
        end = start;
        if (line.len == 0) continue;
        if (w.buffered().len + line.len + 32 > w.buffer.len) break;
        if (!first) try w.writeByte(',');
        try w.writeAll(line);
        first = false;
        count += 1;
    }
    try w.writeAll("]}");
}

pub const Log = struct {
    file: Io.File,
    mutex: Io.Mutex = .init,

    pub const file_name = "audit.log";

    pub fn open(io: Io, dir: Io.Dir) !Log {
        const f = try dir.createFile(io, file_name, .{ .truncate = false, .read = true });
        return .{ .file = f };
    }

    pub fn readTail(l: *Log, io: Io, buf: []u8) !struct { bytes: []const u8, from_start: bool } {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        const len = try l.file.length(io);
        const want: u64 = @min(len, buf.len);
        const offset = len - want;
        const n = try l.file.readPositionalAll(io, buf[0..@intCast(want)], offset);
        return .{ .bytes = buf[0..n], .from_start = offset == 0 };
    }

    pub fn close(l: *Log, io: Io) void {
        l.file.close(io);
    }

    pub fn record(l: *Log, io: Io, ev: Event) void {
        var buf: [1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        format(&w, ev) catch {
            std.log.err("audit: event too large, dropped action={s}", .{ev.action});
            return;
        };
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        const end = l.file.length(io) catch |err| {
            std.log.err("audit: stat failed: {s}", .{@errorName(err)});
            return;
        };
        l.file.writePositionalAll(io, w.buffered(), end) catch |err| {
            std.log.err("audit: write failed: {s}", .{@errorName(err)});
        };
    }
};

test "entries come out newest first, limited, and as valid json" {
    const log =
        \\{"ts":1,"actor":"a","action":"one","target":"","ok":true,"ip":""}
        \\{"ts":2,"actor":"a","action":"two","target":"","ok":true,"ip":""}
        \\{"ts":3,"actor":"a","action":"three","target":"","ok":false,"ip":""}
        \\
    ;
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeEntries(&w, log, true, 2);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("three", items[0].object.get("action").?.string);
    try std.testing.expectEqualStrings("two", items[1].object.get("action").?.string);
}

test "a tail that starts mid-line drops the cut line" {
    const tail = "ke\":1}\n{\"ts\":2,\"actor\":\"b\",\"action\":\"two\",\"target\":\"\",\"ok\":true,\"ip\":\"\"}\n";
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeEntries(&w, tail, false, 10);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("entries").?.array.items.len);
}

test "empty and tiny inputs give an empty list" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeEntries(&w, "", true, 5);
    try std.testing.expectEqualStrings("{\"entries\":[]}", w.buffered());
    var w2: Io.Writer = .fixed(&buf);
    try writeEntries(&w2, "no newline here", false, 5);
    try std.testing.expectEqualStrings("{\"entries\":[]}", w2.buffered());
}

test "output stops before overflowing the buffer" {
    var src: [40 * 70]u8 = undefined;
    var n: usize = 0;
    for (0..40) |i| {
        const line = std.fmt.bufPrint(src[n..], "{{\"ts\":{d},\"actor\":\"x\",\"action\":\"filler\",\"ok\":true}}\n", .{i}) catch unreachable;
        n += line.len;
    }
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeEntries(&w, src[0..n], true, 100);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("entries").?.array.items.len < 40);
}

test "format escapes hostile input" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try format(&w, .{ .ts = 42, .actor = "evil\"\n{\"ok\":true}", .action = "auth.login", .ok = false, .ip = "10.0.0.1" });
    const line = w.buffered();
    try std.testing.expectEqual(line.len - 1, std.mem.findScalar(u8, line, '\n').?);
    try std.testing.expect(std.mem.find(u8, line, "\\n") != null);
    try std.testing.expect(std.mem.startsWith(u8, line, "{\"ts\":42,"));
}
