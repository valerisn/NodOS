const std = @import("std");
const Io = std.Io;

pub const Key = [16]u8;

pub const Limiter = struct {
    const Entry = struct { failures: u8, window_start_s: i64 };

    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    mutex: Io.Mutex = .init,

    pub const max_failures = 5;
    pub const window_s: i64 = 15 * 60;
    pub const max_entries = 4096;

    pub fn deinit(l: *Limiter, gpa: std.mem.Allocator) void {
        l.map.deinit(gpa);
    }

    pub fn allow(l: *Limiter, io: Io, key: Key, now_s: i64) bool {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        const e = l.map.get(key) orelse return true;
        if (now_s - e.window_start_s >= window_s) return true;
        return e.failures < max_failures;
    }

    pub fn recordFailure(l: *Limiter, gpa: std.mem.Allocator, io: Io, key: Key, now_s: i64) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        if (l.map.count() >= max_entries) l.evictStaleLocked(now_s);
        const gop = l.map.getOrPut(gpa, key) catch return;
        if (!gop.found_existing or now_s - gop.value_ptr.window_start_s >= window_s) {
            gop.value_ptr.* = .{ .failures = 1, .window_start_s = now_s };
        } else {
            gop.value_ptr.failures +|= 1;
        }
    }

    pub fn reset(l: *Limiter, io: Io, key: Key) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        _ = l.map.remove(key);
    }

    fn evictStaleLocked(l: *Limiter, now_s: i64) void {
        var again = true;
        while (again) {
            again = false;
            var it = l.map.iterator();
            while (it.next()) |e| {
                if (now_s - e.value_ptr.window_start_s >= window_s) {
                    l.map.removeByPtr(e.key_ptr);
                    again = true;
                    break;
                }
            }
        }
    }
};

test "locks out after repeated failures, then recovers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const k: Key = @splat(1);
    const other: Key = @splat(2);

    var i: usize = 0;
    while (i < Limiter.max_failures) : (i += 1) {
        try std.testing.expect(l.allow(io, k, 100));
        l.recordFailure(gpa, io, k, 100);
    }
    try std.testing.expect(!l.allow(io, k, 101));
    try std.testing.expect(l.allow(io, other, 101));
    try std.testing.expect(l.allow(io, k, 100 + Limiter.window_s));
}

test "success resets the counter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var l: Limiter = .{};
    defer l.deinit(gpa);
    const k: Key = @splat(9);
    l.recordFailure(gpa, io, k, 1);
    l.recordFailure(gpa, io, k, 2);
    l.reset(io, k);
    var i: usize = 0;
    while (i < Limiter.max_failures - 1) : (i += 1) l.recordFailure(gpa, io, k, 3);
    try std.testing.expect(l.allow(io, k, 4));
}
