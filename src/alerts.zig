const std = @import("std");
const Io = std.Io;
const collect = @import("agent/collect.zig");

pub const Kind = enum {
    cpu_high,
    memory_high,
    disk_high,
    temperature_high,
    swap_high,

    pub fn title(k: Kind) []const u8 {
        return switch (k) {
            .cpu_high => "High CPU load",
            .memory_high => "Low free memory",
            .disk_high => "Disk nearly full",
            .temperature_high => "High temperature",
            .swap_high => "Heavy swap use",
        };
    }
};

pub const Level = enum { warn, crit };

pub const Alert = struct {
    kind: Kind,
    subject: collect.Str(63) = .{},
    level: Level,
    value: f32,
    since_s: i64,
};

pub const EventKind = enum { raised, escalated, cleared };

pub const Event = struct {
    what: EventKind,
    alert: Alert,
};

pub const max_alerts = 48;

/// Where alerts fire. The value an alert clears at sits a fixed margin below
/// its warning level, so a reading hovering at the line does not flap.
pub const Thresholds = struct {
    cpu_warn: f32 = 90,
    cpu_samples: u8 = 5,
    mem_warn: f32 = 90,
    mem_crit: f32 = 95,
    disk_warn: f32 = 85,
    disk_crit: f32 = 95,
    temp_warn: f32 = 80,
    temp_crit: f32 = 90,
    swap_warn: f32 = 50,

    pub fn cpuClear(t: Thresholds) f32 {
        return t.cpu_warn - 10;
    }
    pub fn memClear(t: Thresholds) f32 {
        return t.mem_warn - 5;
    }
    pub fn diskClear(t: Thresholds) f32 {
        return t.disk_warn - 3;
    }
    pub fn tempClear(t: Thresholds) f32 {
        return t.temp_warn - 5;
    }
    pub fn swapClear(t: Thresholds) f32 {
        return t.swap_warn - 10;
    }

    /// Percentages must be sensible and warn must not sit above crit.
    pub fn valid(t: Thresholds) bool {
        const pcts = [_]f32{ t.cpu_warn, t.mem_warn, t.mem_crit, t.disk_warn, t.disk_crit, t.swap_warn };
        for (pcts) |p| if (!(p >= 15 and p <= 100)) return false;
        if (t.mem_warn > t.mem_crit or t.disk_warn > t.disk_crit) return false;
        if (!(t.temp_warn >= 10 and t.temp_crit <= 150 and t.temp_warn <= t.temp_crit)) return false;
        return t.cpu_samples >= 1 and t.cpu_samples <= 60;
    }
};

pub const Engine = struct {
    mutex: Io.Mutex = .init,
    active: [max_alerts]Alert = undefined,
    count: usize = 0,
    cpu_streak: u8 = 0,
    version: u32 = 1,
    t: Thresholds = .{},

    pub fn evaluate(e: *Engine, io: Io, snap: *const collect.Snapshot, out: *[max_alerts]Event) usize {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        var n: usize = 0;
        const now = snap.ts_s;
        const t = e.t;

        if (snap.cpu_pct >= t.cpu_warn) {
            e.cpu_streak +|= 1;
        } else if (snap.cpu_pct < t.cpuClear()) {
            e.cpu_streak = 0;
        }
        const cpu_want: ?Level = if (e.cpu_streak >= t.cpu_samples) .warn else null;
        n = e.apply(.cpu_high, "", cpu_want, snap.cpu_pct, e.cpu_streak == 0, now, out, n);

        if (snap.mem.total_kb > 0) {
            const used = pct(snap.mem.usedKb(), snap.mem.total_kb);
            const want = level(used, t.mem_warn, t.mem_crit);
            n = e.apply(.memory_high, "", want, used, used < t.memClear(), now, out, n);
        }

        if (snap.mem.swap_total_kb > 0) {
            const used = pct(snap.mem.swap_total_kb -| snap.mem.swap_free_kb, snap.mem.swap_total_kb);
            const want: ?Level = if (used >= t.swap_warn) .warn else null;
            n = e.apply(.swap_high, "", want, used, used < t.swapClear(), now, out, n);
        }

        for (snap.mounts[0..snap.mount_count]) |m| {
            const u = m.usage orelse continue;
            if (u.total_bytes == 0) continue;
            const used = pct(u.total_bytes -| u.free_bytes, u.total_bytes);
            const want = level(used, t.disk_warn, t.disk_crit);
            n = e.apply(.disk_high, m.path.slice(), want, used, used < t.diskClear(), now, out, n);
        }

        for (snap.temps[0..snap.temp_count]) |temp| {
            const want = level(temp.celsius, t.temp_warn, t.temp_crit);
            n = e.apply(.temperature_high, temp.label.slice(), want, temp.celsius, temp.celsius < t.tempClear(), now, out, n);
        }

        var i: usize = 0;
        while (i < e.count) {
            const a = e.active[i];
            const gone = a.kind == .disk_high and !hasMount(snap, a.subject.slice());
            const sensor_gone = a.kind == .temperature_high and !hasSensor(snap, a.subject.slice());
            if (gone or sensor_gone) {
                if (n < out.len) {
                    out[n] = .{ .what = .cleared, .alert = a };
                    n += 1;
                }
                e.removeAt(i);
                e.version +%= 1;
            } else i += 1;
        }
        return n;
    }

    pub fn snapshot(e: *Engine, io: Io, out: *[max_alerts]Alert) struct { n: usize, version: u32 } {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        @memcpy(out[0..e.count], e.active[0..e.count]);
        return .{ .n = e.count, .version = e.version };
    }

    pub fn currentVersion(e: *Engine, io: Io) u32 {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        return e.version;
    }

    fn apply(e: *Engine, kind: Kind, subject: []const u8, want: ?Level, value: f32, can_clear: bool, now: i64, out: *[max_alerts]Event, n_in: usize) usize {
        var n = n_in;
        const idx = e.find(kind, subject);
        if (idx) |i| {
            const cur = &e.active[i];
            cur.value = value;
            if (want) |w| {
                if (@backingInt(w) > @backingInt(cur.level)) {
                    cur.level = w;
                    e.version +%= 1;
                    if (n < out.len) {
                        out[n] = .{ .what = .escalated, .alert = cur.* };
                        n += 1;
                    }
                }
            } else if (can_clear) {
                if (n < out.len) {
                    out[n] = .{ .what = .cleared, .alert = cur.* };
                    n += 1;
                }
                e.removeAt(i);
                e.version +%= 1;
            }
            return n;
        }
        const w = want orelse return n;
        if (e.count >= max_alerts) return n;
        var a: Alert = .{ .kind = kind, .level = w, .value = value, .since_s = now };
        a.subject.set(subject);
        e.active[e.count] = a;
        e.count += 1;
        e.version +%= 1;
        if (n < out.len) {
            out[n] = .{ .what = .raised, .alert = a };
            n += 1;
        }
        return n;
    }

    fn find(e: *const Engine, kind: Kind, subject: []const u8) ?usize {
        for (e.active[0..e.count], 0..) |a, i| {
            if (a.kind == kind and std.mem.eql(u8, a.subject.slice(), subject)) return i;
        }
        return null;
    }

    fn removeAt(e: *Engine, i: usize) void {
        e.active[i] = e.active[e.count - 1];
        e.count -= 1;
    }
};

fn pct(part: u64, whole: u64) f32 {
    if (whole == 0) return 0;
    return @floatCast(@as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole)) * 100.0);
}

fn level(v: f32, warn: f32, crit: f32) ?Level {
    if (v >= crit) return .crit;
    if (v >= warn) return .warn;
    return null;
}

fn hasMount(snap: *const collect.Snapshot, path: []const u8) bool {
    for (snap.mounts[0..snap.mount_count]) |m| if (std.mem.eql(u8, m.path.slice(), path)) return true;
    return false;
}

fn hasSensor(snap: *const collect.Snapshot, label: []const u8) bool {
    for (snap.temps[0..snap.temp_count]) |t| if (std.mem.eql(u8, t.label.slice(), label)) return true;
    return false;
}

pub fn writeJson(w: *Io.Writer, alerts: []const Alert) Io.Writer.Error!void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("alerts");
    try j.beginArray();
    for (alerts) |a| {
        try j.beginObject();
        try j.objectField("kind");
        try j.write(@tagName(a.kind));
        try j.objectField("title");
        try j.write(a.kind.title());
        try j.objectField("subject");
        try j.write(a.subject.slice());
        try j.objectField("level");
        try j.write(@tagName(a.level));
        try j.objectField("value");
        try j.write(@round(@as(f64, a.value) * 10.0) / 10.0);
        try j.objectField("since");
        try j.write(a.since_s);
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
}

fn blank(ts: i64) collect.Snapshot {
    return .{ .ts_s = ts };
}

test "cpu needs a sustained run, then clears with hysteresis" {
    const io = std.testing.io;
    var e: Engine = .{};
    var ev: [max_alerts]Event = undefined;
    var snap = blank(100);

    snap.cpu_pct = 95;
    for (0..4) |_| try std.testing.expectEqual(@as(usize, 0), e.evaluate(io, &snap, &ev));
    snap.cpu_pct = 50;
    try std.testing.expectEqual(@as(usize, 0), e.evaluate(io, &snap, &ev));
    snap.cpu_pct = 95;
    for (0..4) |_| try std.testing.expectEqual(@as(usize, 0), e.evaluate(io, &snap, &ev));
    try std.testing.expectEqual(@as(usize, 1), e.evaluate(io, &snap, &ev));
    try std.testing.expectEqual(EventKind.raised, ev[0].what);
    try std.testing.expectEqual(Kind.cpu_high, ev[0].alert.kind);

    snap.cpu_pct = 85;
    try std.testing.expectEqual(@as(usize, 0), e.evaluate(io, &snap, &ev));
    var buf: [max_alerts]Alert = undefined;
    try std.testing.expectEqual(@as(usize, 1), e.snapshot(io, &buf).n);
    snap.cpu_pct = 70;
    try std.testing.expectEqual(@as(usize, 1), e.evaluate(io, &snap, &ev));
    try std.testing.expectEqual(EventKind.cleared, ev[0].what);
    try std.testing.expectEqual(@as(usize, 0), e.snapshot(io, &buf).n);
}

test "disk alerts per mount, escalate, hysteresis, and vanish with the mount" {
    const io = std.testing.io;
    var e: Engine = .{};
    var ev: [max_alerts]Event = undefined;
    var snap = blank(500);
    snap.mount_count = 2;
    snap.mounts[0].path.set("/");
    snap.mounts[1].path.set("/mnt/media");
    snap.mounts[0].usage = .{ .total_bytes = 1000, .free_bytes = 500, .avail_bytes = 500 };
    snap.mounts[1].usage = .{ .total_bytes = 1000, .free_bytes = 120, .avail_bytes = 120 };

    try std.testing.expectEqual(@as(usize, 1), e.evaluate(io, &snap, &ev));
    try std.testing.expectEqual(Level.warn, ev[0].alert.level);
    try std.testing.expectEqualStrings("/mnt/media", ev[0].alert.subject.slice());

    try std.testing.expectEqual(@as(usize, 0), e.evaluate(io, &snap, &ev));

    snap.mounts[1].usage = .{ .total_bytes = 1000, .free_bytes = 40, .avail_bytes = 40 };
    try std.testing.expectEqual(@as(usize, 1), e.evaluate(io, &snap, &ev));
    try std.testing.expectEqual(EventKind.escalated, ev[0].what);
    try std.testing.expectEqual(Level.crit, ev[0].alert.level);

    snap.mounts[1].usage = .{ .total_bytes = 1000, .free_bytes = 170, .avail_bytes = 170 };
    try std.testing.expectEqual(@as(usize, 0), e.evaluate(io, &snap, &ev));
    var buf: [max_alerts]Alert = undefined;
    try std.testing.expectEqual(@as(usize, 1), e.snapshot(io, &buf).n);

    snap.mount_count = 1;
    try std.testing.expectEqual(@as(usize, 1), e.evaluate(io, &snap, &ev));
    try std.testing.expectEqual(EventKind.cleared, ev[0].what);
    try std.testing.expectEqual(@as(usize, 0), e.snapshot(io, &buf).n);
}

test "memory, swap and temperature rules" {
    const io = std.testing.io;
    var e: Engine = .{};
    var ev: [max_alerts]Event = undefined;
    var snap = blank(900);
    snap.mem = .{ .total_kb = 1000, .available_kb = 40, .swap_total_kb = 1000, .swap_free_kb = 400 };
    snap.temp_count = 1;
    snap.temps[0].label.set("cpu");
    snap.temps[0].celsius = 92;

    const n = e.evaluate(io, &snap, &ev);
    try std.testing.expectEqual(@as(usize, 3), n);
    var saw_mem_crit = false;
    var saw_temp_crit = false;
    var saw_swap = false;
    for (ev[0..n]) |x| {
        if (x.alert.kind == .memory_high and x.alert.level == .crit) saw_mem_crit = true;
        if (x.alert.kind == .temperature_high and x.alert.level == .crit) saw_temp_crit = true;
        if (x.alert.kind == .swap_high) saw_swap = true;
    }
    try std.testing.expect(saw_mem_crit and saw_temp_crit and saw_swap);

    var e2: Engine = .{};
    var s2 = blank(1);
    s2.mem = .{ .total_kb = 1000, .available_kb = 900 };
    try std.testing.expectEqual(@as(usize, 0), e2.evaluate(io, &s2, &ev));
}

test "version bumps only when the set changes" {
    const io = std.testing.io;
    var e: Engine = .{};
    var ev: [max_alerts]Event = undefined;
    var snap = blank(1);
    snap.mem = .{ .total_kb = 1000, .available_kb = 40 };
    const v0 = e.currentVersion(io);
    _ = e.evaluate(io, &snap, &ev);
    const v1 = e.currentVersion(io);
    try std.testing.expect(v1 != v0);
    _ = e.evaluate(io, &snap, &ev);
    try std.testing.expectEqual(v1, e.currentVersion(io));
}

test "alerts encode to valid json" {
    var a: Alert = .{ .kind = .disk_high, .level = .warn, .value = 88.449, .since_s = 5 };
    a.subject.set("/mnt/\"odd\"");
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJson(&out.writer, &.{a});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const item = parsed.value.object.get("alerts").?.array.items[0].object;
    try std.testing.expectEqualStrings("disk_high", item.get("kind").?.string);
    try std.testing.expectEqualStrings("/mnt/\"odd\"", item.get("subject").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 88.4), item.get("value").?.float, 0.001);
}
