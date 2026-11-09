//! Samples the host on a timer and keeps the latest Snapshot plus a short ring
//! of history points for the dashboard graphs. History lives in memory only
//! and is lost on restart; that is intentional for early releases.
const std = @import("std");
const Io = std.Io;
const collect = @import("collect.zig");
const build_options = @import("build_options");
const Snapshot = collect.Snapshot;

/// 300 points at the default 2 s interval is ten minutes of graph.
pub const history_len = 300;

pub const Point = struct {
    ts_s: i64,
    cpu_pct: f32,
    mem_pct: f32,
    rx_bps: u64,
    tx_bps: u64,
};

pub fn pointFrom(s: *const Snapshot) Point {
    var rx: u64 = 0;
    var tx: u64 = 0;
    for (s.ifaces[0..s.iface_count]) |i| {
        // Loopback traffic is the box talking to itself, not network load.
        if (std.mem.eql(u8, i.name.slice(), "lo")) continue;
        rx += i.rx_bps;
        tx += i.tx_bps;
    }
    const mem_pct: f32 = if (s.mem.total_kb == 0) 0 else @floatCast(@as(f64, @floatFromInt(s.mem.usedKb())) / @as(f64, @floatFromInt(s.mem.total_kb)) * 100.0);
    return .{ .ts_s = s.ts_s, .cpu_pct = s.cpu_pct, .mem_pct = mem_pct, .rx_bps = rx, .tx_bps = tx };
}

pub const Sampler = struct {
    mutex: Io.Mutex = .init,
    latest: Snapshot = .{},
    have_latest: bool = false,
    ring: [history_len]Point = undefined,
    /// Index the next point will be written to.
    head: usize = 0,
    count: usize = 0,
    /// Set when the first sample fails with Unsupported (non-Linux host).
    unsupported: bool = false,

    pub fn ingest(s: *Sampler, io: Io, snap: Snapshot) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const first = !s.have_latest;
        s.latest = snap;
        s.have_latest = true;
        // The very first sample has no previous counters, so cpu and network
        // rates are all zero. Plotting it would draw a fake dip to zero.
        if (first) return;
        s.ring[s.head] = pointFrom(&snap);
        s.head = (s.head + 1) % history_len;
        if (s.count < history_len) s.count += 1;
    }

    /// Copy out under the lock; Snapshot is a plain value.
    pub fn latestCopy(s: *Sampler, io: Io) ?Snapshot {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        return if (s.have_latest) s.latest else null;
    }

    /// Writes points oldest first into `out`, returns how many.
    pub fn historyCopy(s: *Sampler, io: Io, out: *[history_len]Point) usize {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const start = (s.head + history_len - s.count) % history_len;
        for (0..s.count) |i| out[i] = s.ring[(start + i) % history_len];
        return s.count;
    }

    /// Runs until cancelled. Returns early on a platform we can't read.
    pub fn run(s: *Sampler, io: Io, interval_ms: u32) Io.Cancelable!void {
        const Source = if (build_options.fake_host) collect.FakeSource else collect.LinuxSource;
        var c: collect.Collector(Source) = .{ .source = if (build_options.fake_host) .{} else .{ .io = io } };
        const log = std.log.scoped(.sampler);
        if (build_options.fake_host) log.warn("fake-host build: serving synthetic data, not real metrics", .{});
        var failing = false;
        while (true) {
            const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
            const wall_s = Io.Timestamp.now(io, .real).toSeconds();
            if (c.sample(now_ms, wall_s)) |snap| {
                if (failing) log.info("sampling recovered", .{});
                failing = false;
                s.ingest(io, snap);
            } else |err| switch (err) {
                error.Unsupported => {
                    log.warn("host monitoring is only implemented for Linux, disabled", .{});
                    s.mutex.lockUncancelable(io);
                    s.unsupported = true;
                    s.mutex.unlock(io);
                    return;
                },
                else => {
                    // Log the transition, not every tick: a broken /proc would
                    // otherwise write a line every two seconds forever.
                    if (!failing) log.warn("sample failed: {s}", .{@errorName(err)});
                    failing = true;
                },
            }
            try io.sleep(.fromMilliseconds(interval_ms), .awake);
        }
    }

    pub fn isUnsupported(s: *Sampler, io: Io) bool {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        return s.unsupported;
    }
};

test "ring keeps the newest points in order" {
    const io = std.testing.io;
    var s: Sampler = .{};
    // Prime past the "first sample" filter with a non-zero cpu reading.
    var i: usize = 0;
    while (i < history_len + 50) : (i += 1) {
        var snap: Snapshot = .{ .ts_s = @intCast(i), .cpu_pct = 10 };
        snap.mem = .{ .total_kb = 1000, .available_kb = 500 };
        s.ingest(io, snap);
    }
    var out: [history_len]Point = undefined;
    const n = s.historyCopy(io, &out);
    try std.testing.expectEqual(@as(usize, history_len), n);
    try std.testing.expectEqual(@as(i64, 50), out[0].ts_s);
    try std.testing.expectEqual(@as(i64, history_len + 49), out[n - 1].ts_s);
    try std.testing.expectApproxEqAbs(@as(f32, 50), out[0].mem_pct, 0.01);
}

test "first all-zero sample is not plotted but is still the latest" {
    const io = std.testing.io;
    var s: Sampler = .{};
    var snap: Snapshot = .{ .ts_s = 1 };
    snap.iface_count = 1;
    s.ingest(io, snap);
    var out: [history_len]Point = undefined;
    try std.testing.expectEqual(@as(usize, 0), s.historyCopy(io, &out));
    try std.testing.expect(s.latestCopy(io) != null);
}

test "loopback is excluded from network totals" {
    var snap: Snapshot = .{};
    snap.iface_count = 2;
    snap.ifaces[0].name.set("lo");
    snap.ifaces[0].rx_bps = 9999;
    snap.ifaces[1].name.set("eth0");
    snap.ifaces[1].rx_bps = 100;
    snap.ifaces[1].tx_bps = 50;
    const p = pointFrom(&snap);
    try std.testing.expectEqual(@as(u64, 100), p.rx_bps);
    try std.testing.expectEqual(@as(u64, 50), p.tx_bps);
}
