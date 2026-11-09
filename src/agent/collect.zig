//! Turns raw host files into a Snapshot. The file source is a type parameter:
//! Linux uses `LinuxSource` (real /proc and /sys), tests use a fixture map, so
//! the whole pipeline is testable on a machine that has no /proc.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const proc = @import("proc.zig");

/// Fixed-capacity string so Snapshot needs no allocator and copies cheaply.
pub fn Str(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: u8 = 0,

        const Self = @This();

        pub fn set(s: *Self, text: []const u8) void {
            const n = @min(text.len, N);
            @memcpy(s.buf[0..n], text[0..n]);
            s.len = @intCast(n);
        }
        pub fn slice(s: *const Self) []const u8 {
            return s.buf[0..s.len];
        }
    };
}

pub const FsUsage = struct {
    total_bytes: u64,
    free_bytes: u64,
    /// Free space available to unprivileged users (excludes the root reserve).
    avail_bytes: u64,
};

pub const IfaceRate = struct {
    name: Str(15) = .{},
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    rx_bps: u64 = 0,
    tx_bps: u64 = 0,
    rx_errs: u64 = 0,
    tx_errs: u64 = 0,
};

pub const MountUsage = struct {
    device: Str(63) = .{},
    path: Str(255) = .{},
    fstype: Str(15) = .{},
    usage: ?FsUsage = null,
};

pub const Temp = struct {
    label: Str(31) = .{},
    celsius: f32 = 0,
};

pub const max_temps = 8;

pub const Snapshot = struct {
    ts_s: i64 = 0,
    uptime_s: f64 = 0,
    load: proc.LoadAvg = .{ .one = 0, .five = 0, .fifteen = 0 },
    hostname: Str(63) = .{},
    kernel: Str(63) = .{},
    os_name: Str(63) = .{},
    cpu_pct: f32 = 0,
    core_pct: [proc.max_cores]f32 = @splat(0),
    core_count: u16 = 0,
    mem: proc.MemInfo = .{},
    ifaces: [proc.max_ifaces]IfaceRate = @splat(.{}),
    iface_count: u8 = 0,
    mounts: [proc.max_mounts]MountUsage = @splat(.{}),
    mount_count: u8 = 0,
    temps: [max_temps]Temp = @splat(.{}),
    temp_count: u8 = 0,
};

pub const CollectError = error{ Unsupported, Unreadable, Malformed };

const paths = struct {
    const stat = "/proc/stat";
    const meminfo = "/proc/meminfo";
    const netdev = "/proc/net/dev";
    const uptime = "/proc/uptime";
    const loadavg = "/proc/loadavg";
    const mounts = "/proc/mounts";
    const hostname = "/proc/sys/kernel/hostname";
    const osrelease = "/proc/sys/kernel/osrelease";
    const os_release = "/etc/os-release";
};

pub fn Collector(comptime Source: type) type {
    return struct {
        source: Source,
        prev_cpu: ?proc.CpuStat = null,
        prev_net: ?proc.NetDev = null,
        prev_time_ms: i64 = 0,
        /// Static facts: read once, they don't change while we run.
        hostname: Str(63) = .{},
        kernel: Str(63) = .{},
        os_name: Str(63) = .{},
        have_static: bool = false,

        const Self = @This();

        /// `now_ms` must come from a monotonic clock; it only feeds rate math.
        /// `wall_s` is the timestamp stamped on the snapshot.
        pub fn sample(c: *Self, now_ms: i64, wall_s: i64) CollectError!Snapshot {
            // One scratch buffer for every file. Biggest realistic input is
            // /proc/stat on a 128 core box, around 16 KB.
            var buf: [48 * 1024]u8 = undefined;
            var snap: Snapshot = .{ .ts_s = wall_s };

            if (!c.have_static) c.readStatic(&buf);
            snap.hostname = c.hostname;
            snap.kernel = c.kernel;
            snap.os_name = c.os_name;

            const dt_s: f64 = if (c.prev_time_ms > 0 and now_ms > c.prev_time_ms)
                @as(f64, @floatFromInt(now_ms - c.prev_time_ms)) / 1000.0
            else
                0;

            // cpu
            const cpu = proc.parseCpuStat(try c.read(paths.stat, &buf)) catch return error.Malformed;
            if (c.prev_cpu) |prev| {
                snap.cpu_pct = proc.cpuPercent(prev.all, cpu.all);
                snap.core_count = cpu.core_count;
                for (0..cpu.core_count) |i| snap.core_pct[i] = proc.cpuPercent(prev.cores[i], cpu.cores[i]);
            } else {
                snap.core_count = cpu.core_count;
            }
            c.prev_cpu = cpu;

            // memory
            snap.mem = proc.parseMeminfo(try c.read(paths.meminfo, &buf)) catch return error.Malformed;

            // load and uptime are nice to have; a missing one must not kill the sample
            if (c.read(paths.uptime, &buf)) |t| {
                snap.uptime_s = proc.parseUptime(t) catch 0;
            } else |_| {}
            if (c.read(paths.loadavg, &buf)) |t| {
                snap.load = proc.parseLoadavg(t) catch snap.load;
            } else |_| {}

            // network
            const net = proc.parseNetDev(try c.read(paths.netdev, &buf)) catch return error.Malformed;
            for (net.ifaces[0..net.count], 0..) |cur, i| {
                var r: IfaceRate = .{ .rx_bytes = cur.rx_bytes, .tx_bytes = cur.tx_bytes, .rx_errs = cur.rx_errs, .tx_errs = cur.tx_errs };
                r.name.set(cur.name());
                if (c.prev_net) |pn| if (pn.find(cur.name())) |old| if (dt_s > 0) {
                    r.rx_bps = rate(old.rx_bytes, cur.rx_bytes, dt_s);
                    r.tx_bps = rate(old.tx_bytes, cur.tx_bytes, dt_s);
                };
                snap.ifaces[i] = r;
            }
            snap.iface_count = net.count;
            c.prev_net = net;

            // storage: an unreadable mount table just means an empty list
            if (c.read(paths.mounts, &buf)) |t| {
                if (proc.parseMounts(t)) |mounts| {
                    for (mounts.items[0..mounts.count], 0..) |*m, i| {
                        var mu: MountUsage = .{ .usage = c.source.fsUsage(m.path()) };
                        mu.device.set(m.device());
                        mu.path.set(m.path());
                        mu.fstype.set(m.fstype());
                        snap.mounts[i] = mu;
                    }
                    snap.mount_count = mounts.count;
                } else |_| {}
            } else |_| {}

            snap.temp_count = c.source.temps(&snap.temps);

            c.prev_time_ms = now_ms;
            return snap;
        }

        fn read(c: *Self, path: []const u8, buf: []u8) CollectError![]const u8 {
            return c.source.read(path, buf);
        }

        fn readStatic(c: *Self, buf: []u8) void {
            if (c.read(paths.hostname, buf)) |t| c.hostname.set(std.mem.trim(u8, t, " \r\n")) else |_| {}
            if (c.read(paths.osrelease, buf)) |t| c.kernel.set(std.mem.trim(u8, t, " \r\n")) else |_| {}
            if (c.read(paths.os_release, buf)) |t| {
                var lines = std.mem.splitScalar(u8, t, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "PRETTY_NAME=")) {
                        c.os_name.set(std.mem.trim(u8, line["PRETTY_NAME=".len..], "\" \r"));
                        break;
                    }
                }
            } else |_| {}
            c.have_static = true;
        }
    };
}

/// Bytes per second. A counter that went backwards (interface reset, 32-bit
/// wrap) reports 0 for that tick instead of a bogus petabyte rate.
fn rate(old: u64, cur: u64, dt_s: f64) u64 {
    if (cur < old) return 0;
    const bps = @as(f64, @floatFromInt(cur - old)) / dt_s;
    return @intFromFloat(bps);
}

// ---------------------------------------------------------------- real source

/// Reads the live system. Only does anything on 64-bit Linux.
pub const LinuxSource = struct {
    io: Io,

    pub fn read(s: *LinuxSource, path: []const u8, buf: []u8) CollectError![]const u8 {
        if (builtin.os.tag != .linux) return error.Unsupported;
        var file = Io.Dir.cwd().openFile(s.io, path, .{}) catch return error.Unreadable;
        defer file.close(s.io);
        // Tiny reader buffer on purpose: we only use it to drive readSliceShort
        // into the caller's big buffer. /proc files report size 0, so anything
        // that trusts stat() would read nothing.
        var small: [512]u8 = undefined;
        var fr = file.reader(s.io, &small);
        const n = fr.interface.readSliceShort(buf) catch return error.Unreadable;
        if (n == buf.len) return error.Unreadable; // would have truncated
        return buf[0..n];
    }

    pub fn fsUsage(_: *LinuxSource, path: []const u8) ?FsUsage {
        if (builtin.os.tag != .linux) return null;
        const arch = builtin.cpu.arch;
        if (arch != .x86_64 and arch != .aarch64) return null; // statfs layout below is 64-bit only
        var zpath: [proc.max_path + 1]u8 = undefined;
        if (path.len >= proc.max_path) return null;
        @memcpy(zpath[0..path.len], path);
        zpath[path.len] = 0;

        // Hand-rolled because std has no statfs wrapper. Layout is the kernel's
        // struct statfs on 64-bit: eleven 8 byte fields then spare.
        const Statfs = extern struct {
            f_type: i64,
            f_bsize: i64,
            f_blocks: u64,
            f_bfree: u64,
            f_bavail: u64,
            f_files: u64,
            f_ffree: u64,
            f_fsid: [2]i32,
            f_namelen: i64,
            f_frsize: i64,
            f_flags: i64,
            f_spare: [4]i64,
        };
        var st: Statfs = undefined;
        const rc = std.os.linux.syscall2(.statfs, @intFromPtr(&zpath), @intFromPtr(&st));
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        const bs: u64 = @intCast(if (st.f_frsize > 0) st.f_frsize else st.f_bsize);
        return .{
            .total_bytes = st.f_blocks * bs,
            .free_bytes = st.f_bfree * bs,
            .avail_bytes = st.f_bavail * bs,
        };
    }

    /// Fills `out` from /sys/class/thermal, returns how many were found.
    pub fn temps(s: *LinuxSource, out: *[max_temps]Temp) u8 {
        if (builtin.os.tag != .linux) return 0;
        var n: u8 = 0;
        var zone: usize = 0;
        while (zone < 16 and n < max_temps) : (zone += 1) {
            var pbuf: [64]u8 = undefined;
            var tbuf: [32]u8 = undefined;
            const tp = std.fmt.bufPrint(&pbuf, "/sys/class/thermal/thermal_zone{d}/temp", .{zone}) catch continue;
            const raw = s.read(tp, &tbuf) catch continue;
            const c = proc.parseMilliCelsius(raw) catch continue;
            var t: Temp = .{ .celsius = c };
            var lbuf: [32]u8 = undefined;
            const lp = std.fmt.bufPrint(&pbuf, "/sys/class/thermal/thermal_zone{d}/type", .{zone}) catch continue;
            if (s.read(lp, &lbuf)) |l| {
                t.label.set(std.mem.trim(u8, l, " \r\n"));
            } else |_| {
                var nb: [16]u8 = undefined;
                t.label.set(std.fmt.bufPrint(&nb, "zone{d}", .{zone}) catch "zone");
            }
            out[n] = t;
            n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------- dev source

/// Synthetic host for developing the dashboard and exercising streaming on a
/// machine with no /proc (Windows, macOS). Only reachable via
/// `zig build -Dfake-host=true`. Never enabled in release builds.
pub const FakeSource = struct {
    tick: u64 = 0,
    // Cumulative counters, like the real kernel ones: they only ever grow.
    // Advanced once per sample in temps(), which the collector calls last.
    busy: u64 = 0,
    idle: u64 = 0,
    rx: u64 = 0,
    tx: u64 = 0,

    pub fn read(s: *FakeSource, path: []const u8, buf: []u8) CollectError![]const u8 {
        const n = s.tick;
        const eql = std.mem.eql;
        if (eql(u8, path, "/proc/stat")) {
            const b = s.busy;
            const i = s.idle;
            // Cores are fixed multiples of the total so they stay monotonic too.
            return std.fmt.bufPrint(buf, "cpu  {d} 0 0 {d} 0 0 0 0\ncpu0 {d} 0 0 {d} 0 0 0 0\ncpu1 {d} 0 0 {d} 0 0 0 0\ncpu2 {d} 0 0 {d} 0 0 0 0\ncpu3 {d} 0 0 {d} 0 0 0 0\n", .{
                b * 4, i * 4, b / 2, i, b * 3 / 2, i, b, i, b * 2 / 3, i,
            }) catch error.Unreadable;
        }
        if (eql(u8, path, "/proc/meminfo")) {
            const avail = 9_000_000 - (n * 7919) % 2_000_000;
            return std.fmt.bufPrint(buf, "MemTotal: 16318244 kB\nMemFree: 1000000 kB\nMemAvailable: {d} kB\nBuffers: 200000 kB\nCached: 4000000 kB\nSwapTotal: 2097148 kB\nSwapFree: 2090000 kB\n", .{avail}) catch error.Unreadable;
        }
        if (eql(u8, path, "/proc/net/dev")) {
            // A docker host has a veth per container, and that is what makes real
            // snapshots big. Ten of them keeps the fake payload past the
            // streaming writer's buffer, which is exactly the shape that once
            // broke the live stream on Linux and not here.
            const veths = "  veth0: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n  veth1: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n  veth2: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n  veth3: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n  veth4: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n  veth5: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n  veth6: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n  veth7: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n  veth8: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n  veth9: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n";
            return std.fmt.bufPrint(buf, "h\nh\n    lo: 5000 50 0 0 0 0 0 0 5000 50 0 0 0 0 0 0\n  eth0: {d} {d} 0 0 0 0 0 0 {d} {d} 0 0 0 0 0 0\n{s}", .{ s.rx, s.rx / 1400, s.tx, s.tx / 1400, veths }) catch error.Unreadable;
        }
        if (eql(u8, path, "/proc/uptime")) return std.fmt.bufPrint(buf, "{d}.00 0.00\n", .{86_400 * 12 + n * 2}) catch error.Unreadable;
        if (eql(u8, path, "/proc/loadavg")) return "0.62 0.48 0.41 2/311 4242\n";
        if (eql(u8, path, "/proc/mounts")) return "/dev/nvme0n1p2 / ext4 rw 0 0\n/dev/sda1 /mnt/media xfs rw 0 0\n/dev/sdb1 /mnt/backup btrfs rw 0 0\n";
        if (eql(u8, path, "/proc/sys/kernel/hostname")) return "devbox\n";
        if (eql(u8, path, "/proc/sys/kernel/osrelease")) return "6.8.0-fake\n";
        if (eql(u8, path, "/etc/os-release")) return "PRETTY_NAME=\"Fake Linux (dev)\"\n";
        return error.Unreadable;
    }

    pub fn fsUsage(_: *FakeSource, path: []const u8) ?FsUsage {
        const gb: u64 = 1 << 30;
        if (std.mem.eql(u8, path, "/")) return .{ .total_bytes = 500 * gb, .free_bytes = 310 * gb, .avail_bytes = 290 * gb };
        if (std.mem.eql(u8, path, "/mnt/media")) return .{ .total_bytes = 8000 * gb, .free_bytes = 1200 * gb, .avail_bytes = 1200 * gb };
        return .{ .total_bytes = 4000 * gb, .free_bytes = 3700 * gb, .avail_bytes = 3700 * gb };
    }

    pub fn temps(s: *FakeSource, out: *[max_temps]Temp) u8 {
        out[0] = .{ .celsius = 44.0 + @as(f32, @floatFromInt(s.tick % 9)) };
        out[0].label.set("cpu");
        out[1] = .{ .celsius = 36.5 };
        out[1].label.set("nvme");
        // Busy share wanders between ~15% and ~75% so the graph moves.
        const pct = 15 + (s.tick * 13) % 60;
        s.busy += pct;
        s.idle += 100 - pct;
        s.rx += 400_000 + (s.tick * 37_000) % 900_000;
        s.tx += 90_000 + (s.tick * 11_000) % 300_000;
        s.tick += 1;
        return 2;
    }
};

// ---------------------------------------------------------------- tests

test "fake source never panics or goes backwards over a long run" {
    var c: Collector(FakeSource) = .{ .source = .{} };
    var prev_rx: u64 = 0;
    var i: i64 = 0;
    while (i < 2000) : (i += 1) {
        const s = try c.sample(1000 + i * 2000, 1_700_000_000 + i * 2);
        try std.testing.expect(s.cpu_pct >= 0 and s.cpu_pct <= 100);
        const rx = s.ifaces[1].rx_bytes;
        try std.testing.expect(rx >= prev_rx);
        prev_rx = rx;
    }
}

const FixtureSource = struct {
    stat: []const u8,
    net: []const u8,
    reads: usize = 0,

    pub fn read(s: *FixtureSource, path: []const u8, buf: []u8) CollectError![]const u8 {
        s.reads += 1;
        const src: []const u8 = if (std.mem.eql(u8, path, "/proc/stat"))
            s.stat
        else if (std.mem.eql(u8, path, "/proc/net/dev"))
            s.net
        else if (std.mem.eql(u8, path, "/proc/meminfo"))
            "MemTotal: 2000 kB\nMemFree: 500 kB\nMemAvailable: 1000 kB\n"
        else if (std.mem.eql(u8, path, "/proc/uptime"))
            "100.50 90.00\n"
        else if (std.mem.eql(u8, path, "/proc/loadavg"))
            "0.10 0.20 0.30 1/100 999\n"
        else if (std.mem.eql(u8, path, "/proc/mounts"))
            "/dev/sda1 / ext4 rw 0 0\nproc /proc proc rw 0 0\n"
        else if (std.mem.eql(u8, path, "/proc/sys/kernel/hostname"))
            "homebox\n"
        else if (std.mem.eql(u8, path, "/proc/sys/kernel/osrelease"))
            "6.8.0-test\n"
        else if (std.mem.eql(u8, path, "/etc/os-release"))
            "NAME=\"Debian\"\nPRETTY_NAME=\"Debian GNU/Linux 13\"\n"
        else
            return error.Unreadable;
        if (src.len > buf.len) return error.Unreadable;
        @memcpy(buf[0..src.len], src);
        return buf[0..src.len];
    }

    pub fn fsUsage(_: *FixtureSource, path: []const u8) ?FsUsage {
        if (std.mem.eql(u8, path, "/")) return .{ .total_bytes = 1000, .free_bytes = 400, .avail_bytes = 300 };
        return null;
    }

    pub fn temps(_: *FixtureSource, out: *[max_temps]Temp) u8 {
        out[0] = .{ .celsius = 51.5 };
        out[0].label.set("cpu");
        return 1;
    }
};

test "two samples produce cpu percent and network rates" {
    var c: Collector(FixtureSource) = .{ .source = .{
        .stat = "cpu  100 0 100 800 0 0 0 0\ncpu0 100 0 100 800 0 0 0 0\n",
        .net = "h\nh\n  eth0: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n",
    } };
    const first = try c.sample(10_000, 1_700_000_000);
    try std.testing.expectEqual(@as(f32, 0), first.cpu_pct);
    try std.testing.expectEqualStrings("homebox", first.hostname.slice());
    try std.testing.expectEqualStrings("Debian GNU/Linux 13", first.os_name.slice());
    try std.testing.expectEqual(@as(u8, 1), first.mount_count);
    try std.testing.expectEqual(@as(u64, 600), first.mounts[0].usage.?.total_bytes - first.mounts[0].usage.?.free_bytes);
    try std.testing.expectEqual(@as(u8, 1), first.temp_count);

    // 2 seconds later: 100 more busy jiffies, 100 more idle -> 50%
    c.source.stat = "cpu  150 0 150 900 0 0 0 0\ncpu0 150 0 150 900 0 0 0 0\n";
    c.source.net = "h\nh\n  eth0: 5000 50 0 0 0 0 0 0 2400 30 0 0 0 0 0 0\n";
    const second = try c.sample(12_000, 1_700_000_002);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), second.cpu_pct, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), second.core_pct[0], 0.01);
    try std.testing.expectEqual(@as(u64, 2000), second.ifaces[0].rx_bps); // 4000 bytes / 2 s
    try std.testing.expectEqual(@as(u64, 200), second.ifaces[0].tx_bps);
    try std.testing.expectEqual(@as(u64, 1000), second.mem.usedKb());
    try std.testing.expectApproxEqAbs(@as(f64, 100.5), second.uptime_s, 0.001);
}

test "counter reset reports zero rate" {
    try std.testing.expectEqual(@as(u64, 0), rate(500, 100, 2.0));
    try std.testing.expectEqual(@as(u64, 50), rate(0, 100, 2.0));
}

test "missing core file is an error, missing optional file is not" {
    var c: Collector(FixtureSource) = .{ .source = .{ .stat = "garbage", .net = "h\nh\n" } };
    try std.testing.expectError(error.Malformed, c.sample(1000, 1));
}

test "real linux source reads real /proc" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var c: Collector(LinuxSource) = .{ .source = .{ .io = std.testing.io } };
    const a = try c.sample(1000, 1);
    try std.testing.expect(a.mem.total_kb > 0);
    try std.testing.expect(a.core_count > 0);
    try std.testing.expect(a.hostname.len > 0);
    try std.testing.expect(a.uptime_s > 0);
    const b = try c.sample(2000, 2);
    try std.testing.expect(b.cpu_pct >= 0 and b.cpu_pct <= 100);
}
