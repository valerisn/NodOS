//! Parsers for Linux /proc text. Pure functions: text in, struct out, no I/O,
//! so they are tested against fixtures on any OS. Reading the files lives in
//! collect.zig.
const std = @import("std");

pub const ParseError = error{Malformed};

// ---------------------------------------------------------------- cpu

pub const max_cores = 128;

pub const CpuTimes = struct {
    /// Sum of all accounted jiffies. guest time is already inside user, so it
    /// is deliberately not added again.
    total: u64 = 0,
    /// idle + iowait. A core waiting on disk is not busy.
    idle: u64 = 0,
};

pub const CpuStat = struct {
    all: CpuTimes = .{},
    cores: [max_cores]CpuTimes = @splat(.{}),
    core_count: u16 = 0,
};

pub fn parseCpuStat(text: []const u8) ParseError!CpuStat {
    var out: CpuStat = .{};
    var have_all = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const label = f.next().?;
        var v: [8]u64 = @splat(0);
        var i: usize = 0;
        while (i < v.len) : (i += 1) {
            const tok = f.next() orelse break;
            v[i] = std.fmt.parseInt(u64, tok, 10) catch return error.Malformed;
        }
        // Old kernels give fewer than 8 columns; the missing ones are zero.
        if (i < 4) return error.Malformed;
        var total: u64 = 0;
        for (v) |x| total += x;
        const t: CpuTimes = .{ .total = total, .idle = v[3] + v[4] };

        if (std.mem.eql(u8, label, "cpu")) {
            out.all = t;
            have_all = true;
        } else {
            const idx = std.fmt.parseInt(u16, label[3..], 10) catch return error.Malformed;
            if (idx < max_cores) {
                out.cores[idx] = t;
                out.core_count = @max(out.core_count, idx + 1);
            }
        }
    }
    if (!have_all) return error.Malformed;
    return out;
}

/// Busy percentage between two samples, 0 to 100. No elapsed time reads as 0.
pub fn cpuPercent(prev: CpuTimes, cur: CpuTimes) f32 {
    if (cur.total <= prev.total) return 0;
    const dt: f64 = @floatFromInt(cur.total - prev.total);
    const di: f64 = @floatFromInt(@min(cur.idle -| prev.idle, cur.total - prev.total));
    return @floatCast((dt - di) / dt * 100.0);
}

// ---------------------------------------------------------------- memory

pub const MemInfo = struct {
    total_kb: u64 = 0,
    free_kb: u64 = 0,
    available_kb: u64 = 0,
    buffers_kb: u64 = 0,
    cached_kb: u64 = 0,
    swap_total_kb: u64 = 0,
    swap_free_kb: u64 = 0,

    pub fn usedKb(m: MemInfo) u64 {
        return m.total_kb -| m.available_kb;
    }
};

pub fn parseMeminfo(text: []const u8) ParseError!MemInfo {
    var m: MemInfo = .{};
    var have_available = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        var rest = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const num = rest.next() orelse continue;
        const val = std.fmt.parseInt(u64, num, 10) catch return error.Malformed;
        if (std.mem.eql(u8, key, "MemTotal")) {
            m.total_kb = val;
        } else if (std.mem.eql(u8, key, "MemFree")) {
            m.free_kb = val;
        } else if (std.mem.eql(u8, key, "MemAvailable")) {
            m.available_kb = val;
            have_available = true;
        } else if (std.mem.eql(u8, key, "Buffers")) {
            m.buffers_kb = val;
        } else if (std.mem.eql(u8, key, "Cached")) {
            m.cached_kb = val;
        } else if (std.mem.eql(u8, key, "SwapTotal")) {
            m.swap_total_kb = val;
        } else if (std.mem.eql(u8, key, "SwapFree")) {
            m.swap_free_kb = val;
        }
    }
    if (m.total_kb == 0) return error.Malformed;
    // Kernels before 3.14 have no MemAvailable. This estimate is the old rule of thumb.
    if (!have_available) m.available_kb = m.free_kb + m.buffers_kb + m.cached_kb;
    return m;
}

// ---------------------------------------------------------------- network

pub const max_ifaces = 16;

pub const NetCounters = struct {
    name_buf: [16]u8 = undefined,
    name_len: u8 = 0,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    rx_packets: u64 = 0,
    tx_packets: u64 = 0,
    rx_errs: u64 = 0,
    tx_errs: u64 = 0,

    pub fn name(n: *const NetCounters) []const u8 {
        return n.name_buf[0..n.name_len];
    }
};

pub const NetDev = struct {
    ifaces: [max_ifaces]NetCounters = undefined,
    count: u8 = 0,

    pub fn find(n: *const NetDev, ifname: []const u8) ?*const NetCounters {
        for (n.ifaces[0..n.count]) |*i| if (std.mem.eql(u8, i.name(), ifname)) return i;
        return null;
    }
};

pub fn parseNetDev(text: []const u8) ParseError!NetDev {
    var out: NetDev = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    // First two lines are headers.
    _ = lines.next();
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const nm = std.mem.trim(u8, line[0..colon], " ");
        if (nm.len == 0 or nm.len > 15) return error.Malformed;
        var f = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        var v: [16]u64 = undefined;
        for (&v) |*x| {
            const tok = f.next() orelse return error.Malformed;
            x.* = std.fmt.parseInt(u64, tok, 10) catch return error.Malformed;
        }
        if (out.count >= max_ifaces) break;
        var c: NetCounters = .{
            .rx_bytes = v[0],
            .rx_packets = v[1],
            .rx_errs = v[2],
            .tx_bytes = v[8],
            .tx_packets = v[9],
            .tx_errs = v[10],
        };
        @memcpy(c.name_buf[0..nm.len], nm);
        c.name_len = @intCast(nm.len);
        out.ifaces[out.count] = c;
        out.count += 1;
    }
    return out;
}

// ---------------------------------------------------------------- misc

pub fn parseUptime(text: []const u8) ParseError!f64 {
    var f = std.mem.tokenizeAny(u8, text, " \t\n");
    const tok = f.next() orelse return error.Malformed;
    return std.fmt.parseFloat(f64, tok) catch error.Malformed;
}

pub const LoadAvg = struct { one: f32, five: f32, fifteen: f32 };

pub fn parseLoadavg(text: []const u8) ParseError!LoadAvg {
    var f = std.mem.tokenizeAny(u8, text, " \t\n");
    var v: [3]f32 = undefined;
    for (&v) |*x| {
        const tok = f.next() orelse return error.Malformed;
        x.* = std.fmt.parseFloat(f32, tok) catch return error.Malformed;
    }
    return .{ .one = v[0], .five = v[1], .fifteen = v[2] };
}

/// /sys/class/thermal/*/temp holds millidegrees Celsius.
pub fn parseMilliCelsius(text: []const u8) ParseError!f32 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const milli = std.fmt.parseInt(i32, t, 10) catch return error.Malformed;
    return @as(f32, @floatFromInt(milli)) / 1000.0;
}

// ---------------------------------------------------------------- mounts

pub const max_mounts = 32;
pub const max_path = 256;

pub const Mount = struct {
    device_buf: [64]u8 = undefined,
    device_len: u8 = 0,
    path_buf: [max_path]u8 = undefined,
    path_len: u16 = 0,
    fstype_buf: [16]u8 = undefined,
    fstype_len: u8 = 0,

    pub fn device(m: *const Mount) []const u8 {
        return m.device_buf[0..m.device_len];
    }
    pub fn path(m: *const Mount) []const u8 {
        return m.path_buf[0..m.path_len];
    }
    pub fn fstype(m: *const Mount) []const u8 {
        return m.fstype_buf[0..m.fstype_len];
    }
};

pub const Mounts = struct {
    items: [max_mounts]Mount = undefined,
    count: u8 = 0,
};

/// Filesystems worth showing on a storage page. tmpfs, proc, cgroup, overlay
/// and friends are noise on a home server dashboard.
const real_fs = [_][]const u8{
    "ext2", "ext3",     "ext4", "xfs",   "btrfs",   "zfs", "f2fs",
    "vfat", "exfat",    "ntfs", "ntfs3", "fuseblk", "nfs", "nfs4",
    "cifs", "bcachefs",
};

fn isRealFs(t: []const u8) bool {
    for (real_fs) |r| if (std.mem.eql(u8, r, t)) return true;
    return false;
}

/// /proc/mounts escapes space, tab, newline and backslash as \040 \011 \012 \134.
fn unescapeMountPath(src: []const u8, dst: []u8) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (n >= dst.len) return null;
        if (src[i] == '\\' and i + 4 <= src.len) {
            if (std.fmt.parseInt(u8, src[i + 1 .. i + 4], 8)) |b| {
                dst[n] = b;
                n += 1;
                i += 4;
                continue;
            } else |_| {}
        }
        dst[n] = src[i];
        n += 1;
        i += 1;
    }
    return n;
}

pub fn parseMounts(text: []const u8) ParseError!Mounts {
    var out: Mounts = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = f.next() orelse return error.Malformed;
        const mp = f.next() orelse return error.Malformed;
        const fs = f.next() orelse return error.Malformed;
        if (!isRealFs(fs)) continue;
        if (out.count >= max_mounts) break;
        if (dev.len > 64 or fs.len > 16) continue;

        var m: Mount = .{};
        @memcpy(m.device_buf[0..dev.len], dev);
        m.device_len = @intCast(dev.len);
        @memcpy(m.fstype_buf[0..fs.len], fs);
        m.fstype_len = @intCast(fs.len);
        const plen = unescapeMountPath(mp, &m.path_buf) orelse continue;
        m.path_len = @intCast(plen);

        // Bind mounts and btrfs subvolumes list one device many times. Keep
        // the first, or the dashboard double counts capacity.
        var dup = false;
        for (out.items[0..out.count]) |*e| {
            if (std.mem.eql(u8, e.device(), dev) and std.mem.eql(u8, e.fstype(), fs)) dup = true;
        }
        if (dup) continue;
        out.items[out.count] = m;
        out.count += 1;
    }
    return out;
}

// ---------------------------------------------------------------- tests

const stat_fixture =
    \\cpu  4705 150 1120 16250 520 30 45 0 0 0
    \\cpu0 1200 40 300 4000 100 10 20 0 0 0
    \\cpu1 1150 30 280 4100 130 5 10 0 0 0
    \\intr 12345 0 0
    \\ctxt 99999
    \\btime 1700000000
    \\
;

test "cpu stat parse" {
    const s = try parseCpuStat(stat_fixture);
    try std.testing.expectEqual(@as(u16, 2), s.core_count);
    // 4705+150+1120+16250+520+30+45
    try std.testing.expectEqual(@as(u64, 22820), s.all.total);
    try std.testing.expectEqual(@as(u64, 16770), s.all.idle);
    try std.testing.expectEqual(@as(u64, 4100 + 130), s.cores[1].idle);
}

test "cpu percent" {
    const a: CpuTimes = .{ .total = 1000, .idle = 800 };
    const b: CpuTimes = .{ .total = 1100, .idle = 850 };
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), cpuPercent(a, b), 0.001);
    try std.testing.expectEqual(@as(f32, 0), cpuPercent(b, b));
    try std.testing.expectEqual(@as(f32, 0), cpuPercent(b, a)); // counter went backwards
    // idle jumped more than total (iowait accounting glitch): clamp, don't go negative
    try std.testing.expectEqual(@as(f32, 0), cpuPercent(.{ .total = 10, .idle = 0 }, .{ .total = 20, .idle = 50 }));
}

test "cpu stat rejects garbage" {
    try std.testing.expectError(error.Malformed, parseCpuStat("nothing here"));
    try std.testing.expectError(error.Malformed, parseCpuStat("cpu  1 2 x 4"));
}

const meminfo_fixture =
    \\MemTotal:       16318244 kB
    \\MemFree:         1234567 kB
    \\MemAvailable:    9876543 kB
    \\Buffers:          200000 kB
    \\Cached:          5000000 kB
    \\SwapTotal:       2097148 kB
    \\SwapFree:        2097000 kB
    \\HugePages_Total:       0
    \\
;

test "meminfo parse" {
    const m = try parseMeminfo(meminfo_fixture);
    try std.testing.expectEqual(@as(u64, 16318244), m.total_kb);
    try std.testing.expectEqual(@as(u64, 16318244 - 9876543), m.usedKb());
    try std.testing.expectEqual(@as(u64, 2097148), m.swap_total_kb);
}

test "meminfo without MemAvailable falls back" {
    const m = try parseMeminfo("MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 150 kB\n");
    try std.testing.expectEqual(@as(u64, 300), m.available_kb);
    try std.testing.expectError(error.Malformed, parseMeminfo("garbage"));
}

const netdev_fixture =
    \\Inter-|   Receive                                                |  Transmit
    \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    \\    lo:  100000     500    0    0    0     0          0         0   100000     500    0    0    0     0       0          0
    \\  eth0: 98765432  123456    2    1    0     0          0       100 12345678   65432    3    0    0     0       0          0
    \\
;

test "netdev parse" {
    const n = try parseNetDev(netdev_fixture);
    try std.testing.expectEqual(@as(u8, 2), n.count);
    const e = n.find("eth0").?;
    try std.testing.expectEqual(@as(u64, 98765432), e.rx_bytes);
    try std.testing.expectEqual(@as(u64, 12345678), e.tx_bytes);
    try std.testing.expectEqual(@as(u64, 3), e.tx_errs);
    try std.testing.expect(n.find("wlan0") == null);
    try std.testing.expectError(error.Malformed, parseNetDev("h\nh\neth0: 1 2 3\n"));
}

test "uptime, loadavg, temperature" {
    try std.testing.expectApproxEqAbs(@as(f64, 350735.47), try parseUptime("350735.47 234388.90\n"), 0.001);
    const l = try parseLoadavg("0.52 0.58 0.59 1/467 12345\n");
    try std.testing.expectApproxEqAbs(@as(f32, 0.58), l.five, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 47.5), try parseMilliCelsius("47500\n"), 0.001);
    try std.testing.expectError(error.Malformed, parseUptime(""));
    try std.testing.expectError(error.Malformed, parseLoadavg("1 2"));
    try std.testing.expectError(error.Malformed, parseMilliCelsius("hot"));
}

const mounts_fixture =
    \\sysfs /sys sysfs rw,nosuid 0 0
    \\proc /proc proc rw 0 0
    \\/dev/nvme0n1p2 / ext4 rw,relatime 0 0
    \\tmpfs /run tmpfs rw 0 0
    \\/dev/nvme0n1p2 /var/lib/docker/overlay ext4 rw 0 0
    \\/dev/sda1 /mnt/big\040drive xfs rw 0 0
    \\overlay /var/lib/docker/overlay2/x/merged overlay rw 0 0
    \\
;

test "mounts keep only real filesystems, dedupe devices, decode escapes" {
    const m = try parseMounts(mounts_fixture);
    try std.testing.expectEqual(@as(u8, 2), m.count);
    try std.testing.expectEqualStrings("/", m.items[0].path());
    try std.testing.expectEqualStrings("ext4", m.items[0].fstype());
    try std.testing.expectEqualStrings("/mnt/big drive", m.items[1].path());
    try std.testing.expectEqualStrings("/dev/sda1", m.items[1].device());
}
