const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const users = @import("users.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const file_name = "tokens.db";
pub const token_len = 43;

pub const Token = struct {
    name: []const u8,
    role: auth.Role,
    hash: [Sha256.digest_length]u8,
};

pub const Error = error{ InvalidName, DuplicateName, NoSuchToken, CorruptTokenFile, OutOfMemory };

pub fn hashOf(token: []const u8) [Sha256.digest_length]u8 {
    var h: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(token, &h, .{});
    return h;
}

/// Machine access: a long random token that another NodOS (or a script) sends
/// as `Authorization: Bearer`. Only its hash is kept here, the way passwords
/// are, so the file leaking does not hand out working tokens.
pub const Tokens = struct {
    list: std.ArrayList(Token) = .empty,

    pub fn add(t: *Tokens, arena: std.mem.Allocator, name: []const u8, role: auth.Role, token: []const u8) Error!void {
        if (!users.validName(name)) return error.InvalidName;
        for (t.list.items) |x| if (std.mem.eql(u8, x.name, name)) return error.DuplicateName;
        try t.list.append(arena, .{ .name = try arena.dupe(u8, name), .role = role, .hash = hashOf(token) });
    }

    pub fn remove(t: *Tokens, name: []const u8) Error!void {
        for (t.list.items, 0..) |x, i| {
            if (std.mem.eql(u8, x.name, name)) {
                _ = t.list.orderedRemove(i);
                return;
            }
        }
        return error.NoSuchToken;
    }

    /// Looks at every entry whatever the answer, so timing says nothing.
    pub fn lookup(t: *const Tokens, token: []const u8) ?*const Token {
        const h = hashOf(token);
        var found: ?*const Token = null;
        for (t.list.items) |*x| {
            if (std.crypto.timing_safe.eql([Sha256.digest_length]u8, x.hash, h)) found = x;
        }
        return found;
    }

    pub fn write(t: *const Tokens, w: *Io.Writer) Io.Writer.Error!void {
        for (t.list.items) |x| {
            try w.print("{s}:{s}:{x}\n", .{ x.name, @tagName(x.role), x.hash });
        }
    }
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Tokens {
    var out: Tokens = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse return error.CorruptTokenFile;
        const role_s = f.next() orelse return error.CorruptTokenFile;
        const hex = f.next() orelse return error.CorruptTokenFile;
        if (f.next() != null) return error.CorruptTokenFile;
        const role = std.meta.stringToEnum(auth.Role, role_s) orelse return error.CorruptTokenFile;
        if (!users.validName(name) or hex.len != Sha256.digest_length * 2) return error.CorruptTokenFile;
        var h: [Sha256.digest_length]u8 = undefined;
        _ = std.fmt.hexToBytes(&h, hex) catch return error.CorruptTokenFile;
        for (out.list.items) |x| if (std.mem.eql(u8, x.name, name)) return error.CorruptTokenFile;
        try out.list.append(arena, .{ .name = try arena.dupe(u8, name), .role = role, .hash = h });
    }
    return out;
}

pub fn load(io: Io, arena: std.mem.Allocator, dir: Io.Dir) !Tokens {
    const text = dir.readFileAlloc(io, file_name, arena, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(arena, text);
}

pub fn save(io: Io, dir: Io.Dir, t: *const Tokens) !void {
    var atomic = try dir.createFileAtomic(io, file_name, .{ .permissions = users.privateFile(), .replace = true });
    defer atomic.deinit(io);
    var buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &buf);
    try t.write(&fw.interface);
    try fw.interface.flush();
    try atomic.replace(io);
}

/// A fresh token: 32 random bytes as 43 URL-safe characters.
pub fn generate(io: Io) [token_len]u8 {
    var raw: [32]u8 = undefined;
    io.randomSecure(&raw) catch io.random(&raw);
    var out: [token_len]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&out, &raw);
    return out;
}

test "add, look up, remove" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tokens = .{};
    try t.add(a, "hub", .admin, "secret-one");
    try t.add(a, "monitor", .viewer, "secret-two");
    try std.testing.expectEqual(auth.Role.admin, t.lookup("secret-one").?.role);
    try std.testing.expectEqualStrings("monitor", t.lookup("secret-two").?.name);
    try std.testing.expect(t.lookup("secret-three") == null);
    try std.testing.expect(t.lookup("") == null);
    try std.testing.expectError(error.DuplicateName, t.add(a, "hub", .viewer, "x"));
    try std.testing.expectError(error.InvalidName, t.add(a, "Bad Name", .viewer, "x"));
    try t.remove("hub");
    try std.testing.expect(t.lookup("secret-one") == null);
    try std.testing.expectError(error.NoSuchToken, t.remove("hub"));
}

test "file round trip keeps only hashes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Tokens = .{};
    try t.add(a, "hub", .admin, "plain-token-value");
    var out: Io.Writer.Allocating = .init(a);
    try t.write(&out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "plain-token-value") == null);
    const again = try parse(a, out.written());
    try std.testing.expectEqual(auth.Role.admin, again.lookup("plain-token-value").?.role);
    try std.testing.expectError(error.CorruptTokenFile, parse(a, "hub:admin:zz"));
    try std.testing.expectError(error.CorruptTokenFile, parse(a, "hub:root:0000000000000000000000000000000000000000000000000000000000000000"));
    try std.testing.expectError(error.CorruptTokenFile, parse(a, "garbage"));
}

test "generated tokens are 43 url-safe characters and differ" {
    const a = generate(std.testing.io);
    const b = generate(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    for (a) |c| try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
}
