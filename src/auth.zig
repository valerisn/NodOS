//! Password hashing and server-side sessions.
//!
//! Sessions live in memory only. Restarting nodos logs everyone out, which is
//! a feature for a first release: nothing to steal from disk.
const std = @import("std");
const Io = std.Io;
const argon2 = std.crypto.pwhash.argon2;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.url_safe_no_pad;

/// OWASP minimum for argon2id (19 MiB, t=2, p=1). Cheap enough for a Pi,
/// and the PHC string stores the params so we can raise them later without
/// breaking old hashes.
const hash_params = argon2.Params.owasp_2id;

pub const max_password_len = 256;
pub const min_password_len = 10;

/// 97 bytes is plenty for a PHC argon2id string; 128 leaves slack.
pub const hash_buf_len = 128;

pub const PasswordError = error{ PasswordTooShort, PasswordTooLong };

/// Writes a PHC string into `out` and returns the used slice.
pub fn hashPassword(gpa: std.mem.Allocator, io: Io, password: []const u8, out: *[hash_buf_len]u8) ![]const u8 {
    if (password.len < min_password_len) return error.PasswordTooShort;
    if (password.len > max_password_len) return error.PasswordTooLong;
    return argon2.strHash(password, .{ .allocator = gpa, .params = hash_params }, out, io);
}

/// True only on a match. Any failure, including a malformed stored hash,
/// reads as "no". The caller must not reveal which.
pub fn verifyPassword(gpa: std.mem.Allocator, io: Io, phc: []const u8, password: []const u8) bool {
    if (password.len > max_password_len) return false;
    argon2.strVerify(phc, password, .{ .allocator = gpa }, io) catch return false;
    return true;
}

pub const Role = enum { admin, viewer };

pub const Session = struct {
    user_id: u32,
    role: Role,
    csrf: [32]u8,
    created_s: i64,
    last_seen_s: i64,
};

pub const Issued = struct {
    /// Goes in the HttpOnly cookie.
    token: [43]u8,
    /// Goes to the page; echoed back in a header on every state change.
    csrf: [43]u8,
};

pub const SessionStore = struct {
    const Key = [Sha256.digest_length]u8;

    map: std.AutoHashMapUnmanaged(Key, Session) = .empty,
    mutex: Io.Mutex = .init,

    pub const max_sessions = 1024;
    pub const absolute_ttl_s: i64 = 12 * 60 * 60;
    pub const idle_ttl_s: i64 = 30 * 60;

    pub fn deinit(s: *SessionStore, gpa: std.mem.Allocator) void {
        s.map.deinit(gpa);
    }

    pub fn create(s: *SessionStore, gpa: std.mem.Allocator, io: Io, user_id: u32, role: Role, now_s: i64) !Issued {
        var raw: [32]u8 = undefined;
        var csrf: [32]u8 = undefined;
        try io.randomSecure(&raw);
        try io.randomSecure(&csrf);

        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.reapLocked(now_s);
        if (s.map.count() >= max_sessions) return error.TooManySessions;

        // We store only the hash of the token, so a memory dump or a stray
        // debug print of the map cannot be replayed as a login.
        try s.map.put(gpa, hashToken(&raw), .{
            .user_id = user_id,
            .role = role,
            .csrf = csrf,
            .created_s = now_s,
            .last_seen_s = now_s,
        });

        var out: Issued = undefined;
        _ = b64.Encoder.encode(&out.token, &raw);
        _ = b64.Encoder.encode(&out.csrf, &csrf);
        return out;
    }

    /// Returns a copy of the session if the token is valid and unexpired, and
    /// refreshes its idle timer.
    pub fn lookup(s: *SessionStore, io: Io, token: []const u8, now_s: i64) ?Session {
        const key = parseToken(token) orelse return null;
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const entry = s.map.getPtr(key) orelse return null;
        if (expired(entry.*, now_s)) {
            _ = s.map.remove(key);
            return null;
        }
        entry.last_seen_s = now_s;
        return entry.*;
    }

    pub fn destroy(s: *SessionStore, io: Io, token: []const u8) void {
        const key = parseToken(token) orelse return;
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        _ = s.map.remove(key);
    }

    /// Compare in constant time. `presented` is the base64 string from the header.
    pub fn csrfMatches(session: Session, presented: []const u8) bool {
        var buf: [43]u8 = undefined;
        _ = b64.Encoder.encode(&buf, &session.csrf);
        if (presented.len != buf.len) return false;
        return std.crypto.timing_safe.eql([43]u8, buf, presented[0..43].*);
    }

    fn reapLocked(s: *SessionStore, now_s: i64) void {
        var it = s.map.iterator();
        // Collecting keys first would need an allocator; the map is capped at
        // 1024 so restarting the scan after each removal is fine.
        while (it.next()) |e| {
            if (expired(e.value_ptr.*, now_s)) {
                s.map.removeByPtr(e.key_ptr);
                it = s.map.iterator();
            }
        }
    }

    fn expired(sess: Session, now_s: i64) bool {
        return now_s - sess.created_s >= absolute_ttl_s or now_s - sess.last_seen_s >= idle_ttl_s;
    }

    fn hashToken(raw: *const [32]u8) Key {
        var k: Key = undefined;
        Sha256.hash(raw, &k, .{});
        return k;
    }

    fn parseToken(token: []const u8) ?Key {
        if (token.len != 43) return null;
        var raw: [32]u8 = undefined;
        b64.Decoder.decode(&raw, token) catch return null;
        return hashToken(&raw);
    }
};

test "password round trip" {
    const gpa = std.testing.allocator;
    var buf: [hash_buf_len]u8 = undefined;
    const phc = try hashPassword(gpa, std.testing.io, "correct horse battery", &buf);
    try std.testing.expect(std.mem.startsWith(u8, phc, "$argon2id$"));
    try std.testing.expect(verifyPassword(gpa, std.testing.io, phc, "correct horse battery"));
    try std.testing.expect(!verifyPassword(gpa, std.testing.io, phc, "wrong horse battery!"));
    try std.testing.expect(!verifyPassword(gpa, std.testing.io, "garbage", "correct horse battery"));
}

test "password length limits" {
    var buf: [hash_buf_len]u8 = undefined;
    try std.testing.expectError(error.PasswordTooShort, hashPassword(std.testing.allocator, std.testing.io, "short", &buf));
    const long: [max_password_len + 1]u8 = @splat('x');
    try std.testing.expectError(error.PasswordTooLong, hashPassword(std.testing.allocator, std.testing.io, &long, &buf));
}

test "session lifecycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store: SessionStore = .{};
    defer store.deinit(gpa);

    const t0: i64 = 1_000_000;
    const issued = try store.create(gpa, io, 7, .admin, t0);

    const got = store.lookup(io, &issued.token, t0 + 60).?;
    try std.testing.expectEqual(@as(u32, 7), got.user_id);
    try std.testing.expect(SessionStore.csrfMatches(got, &issued.csrf));
    try std.testing.expect(!SessionStore.csrfMatches(got, &issued.token));

    try std.testing.expect(store.lookup(io, "nonsense", t0) == null);

    // idle expiry
    try std.testing.expect(store.lookup(io, &issued.token, t0 + 60 + SessionStore.idle_ttl_s) == null);
}

test "absolute expiry beats activity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store: SessionStore = .{};
    defer store.deinit(gpa);
    const t0: i64 = 5_000;
    const issued = try store.create(gpa, io, 1, .viewer, t0);
    var t = t0;
    while (t < t0 + SessionStore.absolute_ttl_s - 60) : (t += 600) {
        try std.testing.expect(store.lookup(io, &issued.token, t) != null);
    }
    try std.testing.expect(store.lookup(io, &issued.token, t0 + SessionStore.absolute_ttl_s) == null);
}

test "destroy logs out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var store: SessionStore = .{};
    defer store.deinit(gpa);
    const issued = try store.create(gpa, io, 1, .admin, 100);
    store.destroy(io, &issued.token);
    try std.testing.expect(store.lookup(io, &issued.token, 101) == null);
}
