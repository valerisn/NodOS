const std = @import("std");
const Io = std.Io;

pub const Key = [16]u8;

/// Attempt counter per key. An attempt is counted when it is admitted, before
/// the password is checked, and handed back only if the login succeeds. So the
/// count is failures plus attempts still in flight, and a burst of parallel
/// requests cannot all pass a check that was made before any of them finished.
pub const Limiter = struct {
    const Entry = struct { attempts: u16, window_start_s: i64 };

    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    mutex: Io.Mutex = .init,

    pub const window_s: i64 = 15 * 60;
    pub const max_entries = 4096;

    pub fn deinit(l: *Limiter, gpa: std.mem.Allocator) void {
        l.map.deinit(gpa);
    }

    /// True if the attempt may go ahead. It is already counted when this
    /// returns true; call `refund` if it turns out to be a good login.
    pub fn admit(l: *Limiter, gpa: std.mem.Allocator, io: Io, key: Key, limit: u16, now_s: i64) bool {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);

        if (l.map.getPtr(key)) |e| {
            if (now_s - e.window_start_s >= window_s) {
                e.* = .{ .attempts = 1, .window_start_s = now_s };
                return true;
            }
            if (e.attempts >= limit) return false;
            e.attempts += 1;
            return true;
        }

        if (l.map.count() >= max_entries) l.makeRoomLocked(now_s);
        l.map.put(gpa, key, .{ .attempts = 1, .window_start_s = now_s }) catch return false;
        return true;
    }

    /// Gives one counted attempt back. Does nothing to failures already
    /// counted, so a good login never wipes out a run of bad ones.
    pub fn refund(l: *Limiter, io: Io, key: Key) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        const e = l.map.getPtr(key) orelse return;
        if (e.attempts <= 1) {
            _ = l.map.remove(key);
        } else {
            e.attempts -= 1;
        }
    }

    pub fn count(l: *Limiter, io: Io) usize {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        return l.map.count();
    }

    /// Hard bound on memory. Expired entries go first; if every entry is still
    /// live, the oldest one is dropped. An attacker with thousands of distinct
    /// sources can push their own history out this way, but they cannot grow
    /// the table, and thousands of live sources is not a home server threat.
    fn makeRoomLocked(l: *Limiter, now_s: i64) void {
        var oldest_key: ?Key = null;
        var oldest_start: i64 = std.math.maxInt(i64);
        var it = l.map.iterator();
        while (it.next()) |e| {
            if (now_s - e.value_ptr.window_start_s >= window_s) {
                l.map.removeByPtr(e.key_ptr);
                return;
            }
            if (e.value_ptr.window_start_s < oldest_start) {
                oldest_start = e.value_ptr.window_start_s;
                oldest_key = e.key_ptr.*;
            }
        }
        if (oldest_key) |k| _ = l.map.remove(k);
    }
};

/// Collapses an address to the bucket it is throttled in. IPv4 is itself.
/// An IPv6 customer normally holds a whole /64, so throttling single addresses
/// would hand an attacker 2^64 fresh buckets; use the /64. IPv4-mapped
/// addresses are really IPv4 and keep all their bytes.
pub fn bucketIp6(bytes: [16]u8) Key {
    var k = bytes;
    const zeros: [10]u8 = @splat(0);
    const v4_mapped = std.mem.eql(u8, bytes[0..10], &zeros) and bytes[10] == 0xff and bytes[11] == 0xff;
    if (!v4_mapped) @memset(k[8..], 0);
    return k;
}

/// Account bucket: SHA-256 of the name, truncated. Works for any bytes, so
/// names that don't exist or aren't even valid are throttled the same way.
pub fn userKey(name: []const u8) Key {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name[0..@min(name.len, 256)], &h, .{});
    return h[0..16].*;
}

test "a burst of parallel attempts is cut off at the limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const k: Key = @splat(1);
    var admitted: usize = 0;
    for (0..100) |_| {
        if (l.admit(gpa, io, k, 5, 100)) admitted += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), admitted);
}

test "other keys are unaffected, and the window expires" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const a: Key = @splat(1);
    const b: Key = @splat(2);
    for (0..5) |_| try std.testing.expect(l.admit(gpa, io, a, 5, 100));
    try std.testing.expect(!l.admit(gpa, io, a, 5, 101));
    try std.testing.expect(l.admit(gpa, io, b, 5, 101));
    try std.testing.expect(l.admit(gpa, io, a, 5, 100 + Limiter.window_s));
}

test "a good login gives its attempt back but does not erase earlier failures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const k: Key = @splat(3);

    // four failures
    for (0..4) |_| try std.testing.expect(l.admit(gpa, io, k, 5, 10));
    // a successful login from the same source, then its refund
    try std.testing.expect(l.admit(gpa, io, k, 5, 11));
    l.refund(io, k);
    // still only one attempt left: the four failures were not wiped
    try std.testing.expect(l.admit(gpa, io, k, 5, 12));
    try std.testing.expect(!l.admit(gpa, io, k, 5, 13));
}

test "interleaving good logins cannot buy unlimited guesses" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const k: Key = @splat(4);
    var guesses: usize = 0;
    for (0..200) |i| {
        if (i % 5 == 4) {
            // the attacker signs in to an account of their own
            if (l.admit(gpa, io, k, 5, 50)) l.refund(io, k);
        } else if (l.admit(gpa, io, k, 5, 50)) {
            guesses += 1;
        }
    }
    try std.testing.expect(guesses <= 5);
}

test "memory is bounded however many sources show up" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    var i: u32 = 0;
    while (i < Limiter.max_entries * 3) : (i += 1) {
        var k: Key = @splat(0);
        std.mem.writeInt(u32, k[0..4], i, .little);
        _ = l.admit(gpa, io, k, 5, @intCast(i));
    }
    try std.testing.expect(l.count(io) <= Limiter.max_entries);
}

test "ipv6 clients share one bucket per /64, ipv4 and mapped addresses stay exact" {
    const a: [16]u8 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4 };
    var b = a;
    b[15] = 99;
    b[8] = 0x11;
    try std.testing.expectEqualSlices(u8, &bucketIp6(a), &bucketIp6(b));
    b[7] = 2; // different /64
    try std.testing.expect(!std.mem.eql(u8, &bucketIp6(a), &bucketIp6(b)));

    var m1: [16]u8 = @splat(0);
    m1[10] = 0xff;
    m1[11] = 0xff;
    m1[12] = 192;
    m1[15] = 1;
    var m2 = m1;
    m2[15] = 2;
    try std.testing.expect(!std.mem.eql(u8, &bucketIp6(m1), &bucketIp6(m2)));
}

test "account keys differ per name and tolerate any bytes" {
    try std.testing.expect(!std.mem.eql(u8, &userKey("alice"), &userKey("bob")));
    try std.testing.expectEqualSlices(u8, &userKey("alice"), &userKey("alice"));
    _ = userKey("");
    _ = userKey("\x00\xff weird");
    const long: [1000]u8 = @splat('x');
    _ = userKey(&long);
}
