//! User accounts, stored in `<data_dir>/users.db` as one line per user:
//!
//!     id:name:role:phc-hash
//!
//! PHC strings contain `$` and `=` but never `:`, which is why colon works as
//! the separator. Users are created from the CLI (`nodos user add`) and read
//! once at server start, so there is no locking here.
const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");

pub const User = struct {
    id: u32,
    name: []const u8,
    role: auth.Role,
    phc: []const u8,
};

pub const Error = error{
    InvalidName,
    DuplicateName,
    CorruptUserFile,
    OutOfMemory,
};

pub const Users = struct {
    list: std.ArrayList(User) = .empty,

    pub fn find(u: *const Users, name: []const u8) ?*const User {
        for (u.list.items) |*user| {
            if (std.mem.eql(u8, user.name, name)) return user;
        }
        return null;
    }

    /// Strings are copied into `arena`; the caller owns the arena.
    pub fn add(u: *Users, arena: std.mem.Allocator, name: []const u8, role: auth.Role, phc: []const u8) Error!*const User {
        if (!validName(name)) return error.InvalidName;
        if (u.find(name) != null) return error.DuplicateName;
        var next_id: u32 = 1;
        for (u.list.items) |user| next_id = @max(next_id, user.id + 1);
        try u.list.append(arena, .{
            .id = next_id,
            .name = try arena.dupe(u8, name),
            .role = role,
            .phc = try arena.dupe(u8, phc),
        });
        return &u.list.items[u.list.items.len - 1];
    }

    pub const ChangeError = error{ NoSuchUser, LastAdmin, OutOfMemory };

    /// Replaces a user's password hash.
    pub fn setHash(u: *Users, arena: std.mem.Allocator, name: []const u8, phc: []const u8) ChangeError!void {
        for (u.list.items) |*user| {
            if (std.mem.eql(u8, user.name, name)) {
                user.phc = try arena.dupe(u8, phc);
                return;
            }
        }
        return error.NoSuchUser;
    }

    pub fn adminCount(u: *const Users) usize {
        var n: usize = 0;
        for (u.list.items) |user| {
            if (user.role == .admin) n += 1;
        }
        return n;
    }

    /// Refuses to delete the only admin: that would leave nobody able to
    /// manage the server short of editing files by hand.
    pub fn remove(u: *Users, name: []const u8) ChangeError!void {
        for (u.list.items, 0..) |user, i| {
            if (!std.mem.eql(u8, user.name, name)) continue;
            if (user.role == .admin and u.adminCount() == 1) return error.LastAdmin;
            _ = u.list.orderedRemove(i);
            return;
        }
        return error.NoSuchUser;
    }

    pub fn write(u: *const Users, w: *Io.Writer) Io.Writer.Error!void {
        for (u.list.items) |user| {
            try w.print("{d}:{s}:{s}:{s}\n", .{ user.id, user.name, @tagName(user.role), user.phc });
        }
    }
};

/// Lowercase letters, digits, dash, underscore, 1 to 32 chars. Boring on
/// purpose: the name ends up in logs and a file format with delimiters.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Users {
    var users: Users = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, ':');
        const id_s = f.next() orelse return error.CorruptUserFile;
        const name = f.next() orelse return error.CorruptUserFile;
        const role_s = f.next() orelse return error.CorruptUserFile;
        const phc = f.rest();
        const id = std.fmt.parseInt(u32, id_s, 10) catch return error.CorruptUserFile;
        const role = std.meta.stringToEnum(auth.Role, role_s) orelse return error.CorruptUserFile;
        if (!validName(name) or phc.len == 0 or users.find(name) != null) return error.CorruptUserFile;
        try users.list.append(arena, .{
            .id = id,
            .name = try arena.dupe(u8, name),
            .role = role,
            .phc = try arena.dupe(u8, phc),
        });
    }
    return users;
}

/// 0600 where the OS has modes; the file holds password hashes.
fn privateFile() Io.File.Permissions {
    if (@hasDecl(Io.File.Permissions, "fromMode")) return Io.File.Permissions.fromMode(0o600);
    return .default_file;
}

pub const file_name = "users.db";

/// Missing file means no users yet, not an error.
pub fn load(io: Io, arena: std.mem.Allocator, dir: Io.Dir) !Users {
    const text = dir.readFileAlloc(io, file_name, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(arena, text);
}

/// Write-then-rename so a crash can never leave half a user file.
pub fn save(io: Io, dir: Io.Dir, users: *const Users) !void {
    var atomic = try dir.createFileAtomic(io, file_name, .{ .permissions = privateFile(), .replace = true });
    defer atomic.deinit(io);
    var buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &buf);
    try users.write(&fw.interface);
    try fw.interface.flush();
    try atomic.replace(io);
}

test "name validation" {
    try std.testing.expect(validName("keaghan"));
    try std.testing.expect(validName("a_b-9"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("Admin"));
    try std.testing.expect(!validName("a:b"));
    try std.testing.expect(!validName("a b"));
    const long: [33]u8 = @splat('x');
    try std.testing.expect(!validName(&long));
}

test "add, find, round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var u: Users = .{};
    const first = try u.add(a, "alice", .admin, "$argon2id$v=19$m=19456,t=2,p=1$abc$def");
    try std.testing.expectEqual(@as(u32, 1), first.id);
    _ = try u.add(a, "bob", .viewer, "$argon2id$x");
    try std.testing.expectError(error.DuplicateName, u.add(a, "alice", .viewer, "x"));
    try std.testing.expectError(error.InvalidName, u.add(a, "Bad Name", .viewer, "x"));

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try u.write(&out.writer);

    const back = try parse(a, out.written());
    try std.testing.expectEqual(@as(usize, 2), back.list.items.len);
    try std.testing.expectEqual(auth.Role.viewer, back.find("bob").?.role);
    try std.testing.expectEqualStrings(first.phc, back.find("alice").?.phc);
}

test "change password, remove, and the last admin is protected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u: Users = .{};
    _ = try u.add(a, "alice", .admin, "$argon2id$old");
    _ = try u.add(a, "bob", .viewer, "$argon2id$b");

    try u.setHash(a, "alice", "$argon2id$new");
    try std.testing.expectEqualStrings("$argon2id$new", u.find("alice").?.phc);
    try std.testing.expectError(error.NoSuchUser, u.setHash(a, "carol", "x"));

    try std.testing.expectError(error.LastAdmin, u.remove("alice"));
    try std.testing.expectError(error.NoSuchUser, u.remove("carol"));
    try u.remove("bob");
    try std.testing.expect(u.find("bob") == null);

    // with a second admin, the first can go
    _ = try u.add(a, "dave", .admin, "$argon2id$d");
    try u.remove("alice");
    try std.testing.expectEqual(@as(usize, 1), u.list.items.len);
    try std.testing.expectEqual(@as(usize, 1), u.adminCount());
}

test "corrupt files are rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.CorruptUserFile, parse(a, "1:alice:admin"));
    try std.testing.expectError(error.CorruptUserFile, parse(a, "x:alice:admin:h"));
    try std.testing.expectError(error.CorruptUserFile, parse(a, "1:alice:root:h"));
    try std.testing.expectError(error.CorruptUserFile, parse(a, "1:alice:admin:h\n2:alice:viewer:h"));
}
