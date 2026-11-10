const std = @import("std");
const Io = std.Io;
const users_mod = @import("users.zig");

pub const manifest_name = "MANIFEST";
pub const users_name = users_mod.file_name;
pub const audit_name = "audit.log";

pub const Entry = struct {
    name: []const u8,
    data: []const u8,
};

pub const Error = error{
    BadArchive,
    UnexpectedFile,
    TooLarge,
    DuplicateFile,
    NoUsers,
    OutOfMemory,
};

const block = 512;

fn limitFor(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, manifest_name)) return 4 * 1024;
    if (std.mem.eql(u8, name, users_name)) return 1024 * 1024;
    if (std.mem.eql(u8, name, audit_name)) return 128 * 1024 * 1024;
    return null;
}

fn octal(buf: []u8, value: u64) void {
    @memset(buf, '0');
    var v = value;
    var i = buf.len - 1;
    buf[i] = 0;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
        if (v == 0) break;
    }
}

fn checksum(h: *const [block]u8) u64 {
    var sum: u64 = 0;
    for (h, 0..) |b, i| sum += if (i >= 148 and i < 156) ' ' else b;
    return sum;
}

fn writeHeader(out: *std.ArrayList(u8), arena: std.mem.Allocator, name: []const u8, size: usize, mtime_s: i64) Error!void {
    var h: [block]u8 = @splat(0);
    @memcpy(h[0..name.len], name);
    octal(h[100..108], 0o600);
    octal(h[108..116], 0);
    octal(h[116..124], 0);
    octal(h[124..136], size);
    octal(h[136..148], @intCast(@max(mtime_s, 0)));
    h[156] = '0';
    @memcpy(h[257..262], "ustar");
    h[262] = 0;
    h[263] = '0';
    h[264] = '0';
    octal(h[148..155], checksum(&h));
    h[154] = 0;
    h[155] = ' ';
    try out.appendSlice(arena, &h);
}

pub fn pack(arena: std.mem.Allocator, files: []const Entry, mtime_s: i64) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (files) |f| {
        const cap = limitFor(f.name) orelse return error.UnexpectedFile;
        if (f.data.len > cap) return error.TooLarge;
        try writeHeader(&out, arena, f.name, f.data.len, mtime_s);
        try out.appendSlice(arena, f.data);
        const pad = (block - f.data.len % block) % block;
        try out.appendNTimes(arena, 0, pad);
    }
    try out.appendNTimes(arena, 0, block * 2);
    return out.items;
}

fn parseOctal(field: []const u8) ?u64 {
    var end: usize = 0;
    while (end < field.len and field[end] != 0 and field[end] != ' ') end += 1;
    const text = std.mem.trim(u8, field[0..end], " ");
    if (text.len == 0) return 0;
    return std.fmt.parseInt(u64, text, 8) catch null;
}

/// Reads an archive written by `pack`. Only the three known names are
/// accepted, each once, as plain files, within their size caps. Anything else
/// is refused rather than skipped, so a restore never does more than the user
/// can see in the archive.
pub fn unpack(arena: std.mem.Allocator, bytes: []const u8) Error![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var pos: usize = 0;
    while (true) {
        if (pos + block > bytes.len) return error.BadArchive;
        const h: *const [block]u8 = bytes[pos..][0..block];
        if (std.mem.allEqual(u8, h, 0)) break;
        pos += block;

        const stored = parseOctal(h[148..156]) orelse return error.BadArchive;
        if (stored != checksum(h)) return error.BadArchive;
        if (h[156] != '0' and h[156] != 0) return error.UnexpectedFile;

        const name_end = std.mem.findScalar(u8, h[0..100], 0) orelse 100;
        const name = h[0..name_end];
        const cap = limitFor(name) orelse return error.UnexpectedFile;
        for (list.items) |e| if (std.mem.eql(u8, e.name, name)) return error.DuplicateFile;

        const size = parseOctal(h[124..136]) orelse return error.BadArchive;
        if (size > cap) return error.TooLarge;
        const n: usize = @intCast(size);
        const padded = n + (block - n % block) % block;
        if (pos + padded > bytes.len) return error.BadArchive;
        try list.append(arena, .{ .name = try arena.dupe(u8, name), .data = bytes[pos..][0..n] });
        pos += padded;
    }
    return list.items;
}

pub fn find(entries: []const Entry, name: []const u8) ?[]const u8 {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e.data;
    return null;
}

/// What a restore may write, after checking it is safe to. The user list must
/// parse and hold an admin, so a damaged or hostile archive cannot lock you
/// out of your own server.
pub fn check(arena: std.mem.Allocator, entries: []const Entry) Error!void {
    const db = find(entries, users_name) orelse return error.NoUsers;
    const parsed = users_mod.parse(arena, db) catch return error.BadArchive;
    if (parsed.adminCount() == 0) return error.NoUsers;
}

pub fn manifest(arena: std.mem.Allocator, version: []const u8, now_s: i64) Error![]u8 {
    return std.fmt.allocPrint(arena, "nodos-backup 1\nversion={s}\ncreated={d}\n", .{ version, now_s }) catch error.OutOfMemory;
}

const sample_users = "1:alice:admin:$argon2id$v=19$m=19456,t=2,p=1$c29tZXNhbHQ$aGFzaGhhc2hoYXNoaGFzaA\n";

fn sampleFiles() [2]Entry {
    return .{
        .{ .name = manifest_name, .data = "nodos-backup 1\n" },
        .{ .name = users_name, .data = sample_users },
    };
}

test "pack then unpack gives the same files back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try a.alloc(u8, 5000);
    @memset(log, 'x');
    const files = [_]Entry{ sampleFiles()[0], sampleFiles()[1], .{ .name = audit_name, .data = log } };
    const tar = try pack(a, &files, 1_700_000_000);
    try std.testing.expect(tar.len % block == 0);
    const back = try unpack(a, tar);
    try std.testing.expectEqual(@as(usize, 3), back.len);
    try std.testing.expectEqualStrings(sample_users, find(back, users_name).?);
    try std.testing.expectEqualStrings(log, find(back, audit_name).?);
}

test "the archive is a real tar: header fields and checksum are standard" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tar = try pack(arena.allocator(), &.{.{ .name = users_name, .data = "hello" }}, 1);
    try std.testing.expectEqualStrings("users.db", tar[0..8]);
    try std.testing.expectEqualStrings("ustar", tar[257..262]);
    try std.testing.expectEqual(@as(u8, '0'), tar[156]);
    try std.testing.expectEqual(@as(u64, 5), parseOctal(tar[124..136]).?);
    try std.testing.expectEqual(checksum(tar[0..block]), parseOctal(tar[148..156]).?);
}

test "unknown names, links, duplicates, bad checksums and truncation are refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.UnexpectedFile, pack(a, &.{.{ .name = "../../etc/passwd", .data = "x" }}, 0));

    const good = try pack(a, &sampleFiles(), 0);

    const renamed = try a.dupe(u8, good);
    @memcpy(renamed[0..8], "evil.txt");
    octal(renamed[148..155], checksum(renamed[0..block]));
    renamed[154] = 0;
    renamed[155] = ' ';
    try std.testing.expectError(error.UnexpectedFile, unpack(a, renamed));

    const symlink = try a.dupe(u8, good);
    symlink[156] = '2';
    octal(symlink[148..155], checksum(symlink[0..block]));
    symlink[154] = 0;
    symlink[155] = ' ';
    try std.testing.expectError(error.UnexpectedFile, unpack(a, symlink));

    const tampered = try a.dupe(u8, good);
    tampered[10] ^= 0xff;
    try std.testing.expectError(error.BadArchive, unpack(a, tampered));

    try std.testing.expectError(error.BadArchive, unpack(a, good[0 .. good.len - 700]));
    try std.testing.expectError(error.BadArchive, unpack(a, ""));

    const twice = try pack(a, &.{ .{ .name = users_name, .data = "a" }, .{ .name = users_name, .data = "b" } }, 0);
    try std.testing.expectError(error.DuplicateFile, unpack(a, twice));
}

test "an oversized member is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tar = try a.dupe(u8, try pack(a, &.{.{ .name = manifest_name, .data = "x" }}, 0));
    octal(tar[124..136], 5 * 1024);
    octal(tar[148..155], checksum(tar[0..block]));
    tar[154] = 0;
    tar[155] = ' ';
    try std.testing.expectError(error.TooLarge, unpack(a, tar));
}

test "check wants a parseable user list with an admin" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try check(a, &sampleFiles());
    try std.testing.expectError(error.NoUsers, check(a, &.{.{ .name = manifest_name, .data = "x" }}));
    try std.testing.expectError(error.BadArchive, check(a, &.{.{ .name = users_name, .data = "garbage" }}));
    const viewer_only = "1:bob:viewer:$argon2id$v=19$m=19456,t=2,p=1$c29tZXNhbHQ$aGFzaGhhc2hoYXNoaGFzaA\n";
    try std.testing.expectError(error.NoUsers, check(a, &.{.{ .name = users_name, .data = viewer_only }}));
}

test "garbage archives never crash the reader" {
    var p = std.Random.DefaultPrng.init(77);
    const rng = p.random();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const good = try pack(arena_state.allocator(), &sampleFiles(), 5);
    var buf: [2048]u8 = undefined;
    for (0..2000) |_| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const n = @min(good.len, buf.len);
        @memcpy(buf[0..n], good[0..n]);
        for (0..rng.uintLessThan(usize, 8) + 1) |_| buf[rng.uintLessThan(usize, n)] = rng.int(u8);
        const cut = rng.uintLessThan(usize, n + 1);
        if (unpack(arena.allocator(), buf[0..cut])) |entries| {
            check(arena.allocator(), entries) catch {};
        } else |_| {}
    }
}
