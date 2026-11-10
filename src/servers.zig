const std = @import("std");
const Io = std.Io;
const users = @import("users.zig");

pub const file_name = "servers.db";
pub const max_servers = 32;

pub const Server = struct {
    name: []const u8,
    url: []const u8,
    token: []const u8,

    /// Host part of the address, for building links that open on that machine.
    pub fn host(s: Server) []const u8 {
        const after = std.mem.find(u8, s.url, "://") orelse return "";
        const rest = s.url[after + 3 ..];
        const end = std.mem.findAny(u8, rest, "/:") orelse rest.len;
        if (rest.len > 0 and rest[0] == '[') {
            const close = std.mem.findScalar(u8, rest, ']') orelse return "";
            return rest[0 .. close + 1];
        }
        return rest[0..end];
    }
};

pub const Error = error{ InvalidName, InvalidUrl, InvalidToken, DuplicateName, NoSuchServer, TooMany, CorruptServerFile, OutOfMemory };

/// An address NodOS may call: http or https, a host, no spaces or quotes, and
/// no path, so a configured server can never be turned into a way to reach
/// arbitrary URLs on that machine.
pub fn validUrl(url: []const u8) bool {
    if (url.len < 9 or url.len > 200) return false;
    const rest = if (std.mem.startsWith(u8, url, "https://")) url["https://".len..] else if (std.mem.startsWith(u8, url, "http://")) url["http://".len..] else return false;
    if (rest.len == 0 or rest[0] == '/' or rest[0] == ':') return false;
    var slashes: usize = 0;
    for (rest, 0..) |c, i| {
        if (c <= ' ' or c == 0x7f or c == '"' or c == '\'' or c == '\\' or c == '|' or c == '?' or c == '#' or c == '@') return false;
        if (c == '/') {
            slashes += 1;
            if (i != rest.len - 1) return false;
        }
    }
    return slashes <= 1;
}

pub fn validToken(t: []const u8) bool {
    if (t.len != 43) return false;
    for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

pub const Servers = struct {
    list: std.ArrayList(Server) = .empty,

    pub fn find(s: *const Servers, name: []const u8) ?*const Server {
        for (s.list.items) |*x| if (std.mem.eql(u8, x.name, name)) return x;
        return null;
    }

    pub fn add(s: *Servers, arena: std.mem.Allocator, name: []const u8, url: []const u8, token: []const u8) Error!void {
        if (!users.validName(name)) return error.InvalidName;
        if (!validUrl(url)) return error.InvalidUrl;
        if (!validToken(token)) return error.InvalidToken;
        if (s.find(name) != null) return error.DuplicateName;
        if (s.list.items.len >= max_servers) return error.TooMany;
        var u = url;
        if (u[u.len - 1] == '/') u = u[0 .. u.len - 1];
        try s.list.append(arena, .{ .name = try arena.dupe(u8, name), .url = try arena.dupe(u8, u), .token = try arena.dupe(u8, token) });
    }

    pub fn remove(s: *Servers, name: []const u8) Error!void {
        for (s.list.items, 0..) |x, i| {
            if (std.mem.eql(u8, x.name, name)) {
                _ = s.list.orderedRemove(i);
                return;
            }
        }
        return error.NoSuchServer;
    }

    pub fn write(s: *const Servers, w: *Io.Writer) Io.Writer.Error!void {
        for (s.list.items) |x| try w.print("{s}|{s}|{s}\n", .{ x.name, x.url, x.token });
    }
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Servers {
    var out: Servers = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '|');
        const name = f.next() orelse return error.CorruptServerFile;
        const url = f.next() orelse return error.CorruptServerFile;
        const token = f.next() orelse return error.CorruptServerFile;
        if (f.next() != null) return error.CorruptServerFile;
        out.add(arena, name, url, token) catch return error.CorruptServerFile;
    }
    return out;
}

pub fn load(io: Io, arena: std.mem.Allocator, dir: Io.Dir) !Servers {
    const text = dir.readFileAlloc(io, file_name, arena, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(arena, text);
}

pub fn save(io: Io, dir: Io.Dir, s: *const Servers) !void {
    var atomic = try dir.createFileAtomic(io, file_name, .{ .permissions = users.privateFile(), .replace = true });
    defer atomic.deinit(io);
    var buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &buf);
    try s.write(&fw.interface);
    try fw.interface.flush();
    try atomic.replace(io);
}

pub fn writeJson(w: *Io.Writer, s: *const Servers) Io.Writer.Error!void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("servers");
    try j.beginArray();
    for (s.list.items) |x| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(x.name);
        try j.objectField("host");
        try j.write(x.host());
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
}

const tok = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";

test "url rules" {
    try std.testing.expect(validUrl("http://192.168.1.20:8080"));
    try std.testing.expect(validUrl("https://rack2.home.lan/"));
    try std.testing.expect(validUrl("http://[fd00::5]:8080"));
    try std.testing.expect(!validUrl("ftp://x.lan"));
    try std.testing.expect(!validUrl("https://"));
    try std.testing.expect(!validUrl("https://a.lan/path"));
    try std.testing.expect(!validUrl("https://a.lan/?x=1"));
    try std.testing.expect(!validUrl("https://user@a.lan"));
    try std.testing.expect(!validUrl("https://a b.lan"));
    try std.testing.expect(!validUrl("https://a.lan|x"));
    try std.testing.expect(!validUrl("file:///etc/passwd"));
    try std.testing.expect(!validUrl(""));
}

test "add, find, host, remove, round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Servers = .{};
    try s.add(a, "rack2", "http://10.0.0.7:8080/", tok);
    try s.add(a, "nas", "https://nas.home.lan", tok);
    try std.testing.expectEqualStrings("http://10.0.0.7:8080", s.find("rack2").?.url);
    try std.testing.expectEqualStrings("10.0.0.7", s.find("rack2").?.host());
    try std.testing.expectEqualStrings("nas.home.lan", s.find("nas").?.host());
    try std.testing.expectError(error.DuplicateName, s.add(a, "nas", "https://x.lan", tok));
    try std.testing.expectError(error.InvalidToken, s.add(a, "x", "https://x.lan", "short"));
    try std.testing.expectError(error.InvalidName, s.add(a, "Bad", "https://x.lan", tok));

    var out: Io.Writer.Allocating = .init(a);
    try s.write(&out.writer);
    const again = try parse(a, out.written());
    try std.testing.expectEqual(@as(usize, 2), again.list.items.len);
    try s.remove("rack2");
    try std.testing.expect(s.find("rack2") == null);
    try std.testing.expectError(error.NoSuchServer, s.remove("rack2"));
    try std.testing.expectError(error.CorruptServerFile, parse(a, "garbage"));
}

test "the json list never contains tokens or full addresses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Servers = .{};
    try s.add(a, "rack2", "http://10.0.0.7:8080", tok);
    var out: Io.Writer.Allocating = .init(a);
    try writeJson(&out.writer, &s);
    try std.testing.expect(std.mem.find(u8, out.written(), tok) == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "8080") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"host\":\"10.0.0.7\"") != null);
}
