const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const collect = @import("agent/collect.zig");

pub const Kind = enum { raid, zpool, smart };
pub const Status = enum { ok, warn, crit };

pub const Item = struct {
    kind: Kind,
    name: collect.Str(63) = .{},
    status: Status,
    detail: collect.Str(95) = .{},
};

pub const max_items = 32;
pub const max_smart_devices = 8;

pub const Report = struct {
    items: [max_items]Item = undefined,
    count: usize = 0,

    pub fn add(r: *Report, kind: Kind, name: []const u8, status: Status, detail: []const u8) void {
        if (r.count >= max_items) return;
        var it: Item = .{ .kind = kind, .status = status };
        it.name.set(name);
        it.detail.set(detail);
        r.items[r.count] = it;
        r.count += 1;
    }

    pub fn slice(r: *const Report) []const Item {
        return r.items[0..r.count];
    }
};

pub fn validDevice(path: []const u8) bool {
    const prefix = "/dev/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const rest = path[prefix.len..];
    if (rest.len == 0 or rest.len > 24) return false;
    for (rest) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

// ---- Linux software RAID ----

fn raidBrackets(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    var found: ?[]const u8 = null;
    while (std.mem.findScalarPos(u8, line, i, '[')) |open| {
        const close = std.mem.findScalarPos(u8, line, open, ']') orelse break;
        const inner = line[open + 1 .. close];
        i = close + 1;
        if (inner.len == 0) continue;
        var only_u = true;
        for (inner) |c| if (c != 'U' and c != '_') {
            only_u = false;
            break;
        };
        if (only_u) found = inner;
    }
    return found;
}

fn progress(line: []const u8) ?struct { what: []const u8, pct: []const u8 } {
    const words = [_][]const u8{ "resync", "recovery", "reshape", "check" };
    for (words) |w| {
        const at = std.mem.find(u8, line, w) orelse continue;
        const eq = std.mem.findScalarPos(u8, line, at, '=') orelse continue;
        const pct_end = std.mem.findScalarPos(u8, line, eq, '%') orelse continue;
        const pct = std.mem.trim(u8, line[eq + 1 .. pct_end], " ");
        if (pct.len == 0 or pct.len > 6) continue;
        return .{ .what = w, .pct = pct };
    }
    return null;
}

pub fn parseMdstat(text: []const u8, report: *Report) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var name: []const u8 = "";
    var state: []const u8 = "";
    var level: []const u8 = "";
    var status: Status = .ok;
    var detail_buf: [95]u8 = undefined;
    var detail: []const u8 = "";

    const Flush = struct {
        fn go(r: *Report, n: []const u8, st: Status, d: []const u8) void {
            if (n.len > 0) r.add(.raid, n, st, d);
        }
    };

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "Personalities") or std.mem.startsWith(u8, line, "unused devices")) continue;
        if (line[0] != ' ' and line[0] != '\t') {
            Flush.go(report, name, status, detail);
            name = "";
            const colon = std.mem.find(u8, line, " : ") orelse continue;
            name = line[0..colon];
            if (name.len == 0 or name.len > 32) {
                name = "";
                continue;
            }
            var toks = std.mem.tokenizeScalar(u8, line[colon + 3 ..], ' ');
            state = toks.next() orelse "";
            level = if (std.mem.eql(u8, state, "active")) (toks.next() orelse "") else "";
            if (std.mem.startsWith(u8, level, "(")) level = "";
            status = .ok;
            detail = std.fmt.bufPrint(&detail_buf, "{s} {s}", .{ state, level }) catch "";
            if (!std.mem.eql(u8, state, "active")) status = .crit;
            continue;
        }
        if (name.len == 0) continue;
        if (raidBrackets(line)) |b| {
            var down: usize = 0;
            for (b) |c| if (c == '_') {
                down += 1;
            };
            if (down > 0) {
                status = .crit;
                detail = std.fmt.bufPrint(&detail_buf, "degraded, {d} of {d} devices missing", .{ down, b.len }) catch "degraded";
            }
        }
        if (progress(line)) |p| {
            const busy_ok = std.mem.eql(u8, p.what, "check");
            if (!busy_ok and status == .ok) status = .warn;
            if (status != .crit) detail = std.fmt.bufPrint(&detail_buf, "{s} {s}%", .{ p.what, p.pct }) catch p.what;
        }
    }
    Flush.go(report, name, status, detail);
}

// ---- ZFS ----

/// Input is `zpool list -H -o name,health,capacity`: tab separated rows.
pub fn parseZpool(text: []const u8, report: *Report) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const name = f.next() orelse continue;
        const health = f.next() orelse continue;
        const cap = f.next() orelse "";
        if (name.len == 0 or name.len > 63) continue;
        const status: Status = if (std.mem.eql(u8, health, "ONLINE")) .ok else if (std.mem.eql(u8, health, "DEGRADED") or std.mem.eql(u8, health, "FAULTED") or std.mem.eql(u8, health, "UNAVAIL") or std.mem.eql(u8, health, "SUSPENDED") or std.mem.eql(u8, health, "REMOVED")) .crit else .warn;
        var buf: [95]u8 = undefined;
        const d = std.fmt.bufPrint(&buf, "{s}, {s} full", .{ health[0..@min(health.len, 20)], cap[0..@min(cap.len, 8)] }) catch health;
        report.add(.zpool, name, status, d);
    }
}

// ---- SMART (smartctl --json) ----

fn getObj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn asInt(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

pub fn parseSmart(arena: Allocator, device: []const u8, json: []const u8, report: *Report) void {
    const name = if (std.mem.startsWith(u8, device, "/dev/")) device["/dev/".len..] else device;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch {
        report.add(.smart, name, .warn, "no readable answer from smartctl");
        return;
    };

    var status: Status = .ok;
    var why: []const u8 = "";

    const passed = if (getObj(root, "smart_status")) |s| (if (getObj(s, "passed")) |p| (if (p == .bool) p.bool else null) else null) else null;
    if (passed != null and !passed.?) {
        status = .crit;
        why = "SMART self-assessment failed";
    }

    var bad_sectors: i64 = 0;
    if (getObj(root, "ata_smart_attributes")) |a| {
        if (getObj(a, "table")) |t| if (t == .array) for (t.array.items) |row| {
            const id = asInt(getObj(row, "id")) orelse continue;
            if (id != 5 and id != 197 and id != 198) continue;
            const raw = getObj(row, "raw") orelse continue;
            bad_sectors += asInt(getObj(raw, "value")) orelse 0;
        };
    }
    if (bad_sectors > 0 and status == .ok) {
        status = .warn;
        why = std.fmt.allocPrint(arena, "{d} bad or pending sectors", .{bad_sectors}) catch "bad sectors";
    }

    if (getObj(root, "nvme_smart_health_information_log")) |n| {
        if ((asInt(getObj(n, "critical_warning")) orelse 0) != 0) {
            status = .crit;
            why = "NVMe critical warning";
        } else if (status == .ok and (asInt(getObj(n, "media_errors")) orelse 0) > 0) {
            status = .warn;
            why = "NVMe media errors";
        } else if (status == .ok and (asInt(getObj(n, "percentage_used")) orelse 0) >= 90) {
            status = .warn;
            why = "NVMe wear above 90%";
        }
    }

    const model = if (getObj(root, "model_name")) |m| (if (m == .string) m.string else "") else "";
    const temp = asInt(if (getObj(root, "temperature")) |t| getObj(t, "current") else null);
    const hours = asInt(if (getObj(root, "power_on_time")) |t| getObj(t, "hours") else null);

    var buf: [95]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    if (why.len > 0) w.print("{s}; ", .{why}) catch {};
    if (model.len > 0) w.print("{s}", .{model[0..@min(model.len, 30)]}) catch {};
    if (temp) |t| w.print(", {d} C", .{t}) catch {};
    if (hours) |h| w.print(", {d} h on", .{h}) catch {};
    const detail = if (w.buffered().len == 0) "no data" else w.buffered();
    report.add(.smart, name, status, detail);
}

// ---- collecting ----

pub const Options = struct {
    zfs: bool = false,
    smart_devices: []const []const u8 = &.{},
};

const Output = struct { code: u8, stdout: []u8 };

fn exec(gpa: Allocator, io: Io, argv: []const []const u8, limit: usize) ?Output {
    const r = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(8 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } },
    }) catch return null;
    gpa.free(r.stderr);
    const code: u8 = switch (r.term) {
        .exited => |x| x,
        else => 255,
    };
    return .{ .code = code, .stdout = r.stdout };
}

pub fn collectFast(gpa: Allocator, io: Io, report: *Report) void {
    if (comptime build_options.fake_host) return fakeFast(report);
    const text = Io.Dir.cwd().readFileAlloc(io, "/proc/mdstat", gpa, .limited(64 * 1024)) catch return;
    defer gpa.free(text);
    parseMdstat(text, report);
}

pub fn collectSlow(gpa: Allocator, io: Io, opts: Options, report: *Report) void {
    if (comptime build_options.fake_host) return fakeSlow(report);
    if (opts.zfs) {
        if (exec(gpa, io, &.{ "zpool", "list", "-H", "-o", "name,health,capacity" }, 64 * 1024)) |o| {
            defer gpa.free(o.stdout);
            if (o.code == 0) parseZpool(o.stdout, report) else report.add(.zpool, "zpool", .warn, "zpool list failed");
        } else report.add(.zpool, "zpool", .warn, "zpool not available");
    }
    for (opts.smart_devices) |dev| {
        if (!validDevice(dev)) continue;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const o = exec(gpa, io, &.{ "smartctl", "--json=o", "-a", "-n", "standby", dev }, 512 * 1024) orelse {
            report.add(.smart, dev["/dev/".len..], .warn, "smartctl not available");
            continue;
        };
        defer gpa.free(o.stdout);
        if (o.code & 3 != 0) {
            const standby = std.mem.find(u8, o.stdout, "STANDBY") != null;
            if (standby) report.add(.smart, dev["/dev/".len..], .ok, "asleep, not woken to check") else report.add(.smart, dev["/dev/".len..], .warn, "cannot read the disk (smartctl needs access to the device)");
            continue;
        }
        parseSmart(arena_state.allocator(), dev, o.stdout, report);
    }
}

fn fakeFast(report: *Report) void {
    report.add(.raid, "md0", .ok, "active raid1");
}

fn fakeSlow(report: *Report) void {
    report.add(.zpool, "tank", .ok, "ONLINE, 61% full");
    report.add(.smart, "sda", .ok, "WDC WD40EFRX, 34 C, 21874 h on");
    report.add(.smart, "sdb", .warn, "8 bad or pending sectors; ST4000DM004, 41 C, 30112 h on");
}

pub const Hook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, io: Io, report: *const Report, now_s: i64) void,
};

pub const Monitor = struct {
    mutex: Io.Mutex = .init,
    report: Report = .{},
    have: bool = false,

    pub fn copy(m: *Monitor, io: Io, out: *Report) bool {
        m.mutex.lockUncancelable(io);
        defer m.mutex.unlock(io);
        out.* = m.report;
        return m.have;
    }

    pub fn run(m: *Monitor, io: Io, gpa: Allocator, opts: Options, hook: ?Hook) Io.Cancelable!void {
        var slow_report: Report = .{};
        var round: u32 = 0;
        while (true) {
            if (round % 10 == 0) {
                slow_report = .{};
                collectSlow(gpa, io, opts, &slow_report);
            }
            var fresh: Report = .{};
            collectFast(gpa, io, &fresh);
            for (slow_report.slice()) |it| {
                if (fresh.count < max_items) {
                    fresh.items[fresh.count] = it;
                    fresh.count += 1;
                }
            }
            m.mutex.lockUncancelable(io);
            m.report = fresh;
            m.have = true;
            m.mutex.unlock(io);
            if (hook) |h| h.call(h.ctx, io, &fresh, Io.Timestamp.now(io, .real).toSeconds());
            round +%= 1;
            try io.sleep(.fromSeconds(60), .awake);
        }
    }
};

pub fn writeJson(w: *Io.Writer, report: *const Report, have: bool) Io.Writer.Error!void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("checked");
    try j.write(have);
    try j.objectField("items");
    try j.beginArray();
    for (report.slice()) |it| {
        try j.beginObject();
        try j.objectField("kind");
        try j.write(@tagName(it.kind));
        try j.objectField("name");
        try j.write(it.name.slice());
        try j.objectField("status");
        try j.write(@tagName(it.status));
        try j.objectField("detail");
        try j.write(it.detail.slice());
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
}

const mdstat_fixture =
    \\Personalities : [raid1] [raid6] [raid5] [raid4]
    \\md0 : active raid1 sdb1[1] sda1[0]
    \\      976630336 blocks super 1.2 [2/2] [UU]
    \\      bitmap: 0/8 pages [0KB], 65536KB chunk
    \\
    \\md1 : active raid5 sdf1[3] sde1[2] sdd1[1]
    \\      1953260544 blocks super 1.2 level 5, 512k chunk [3/2] [_UU]
    \\
    \\md2 : active raid1 sdg1[1] sdh1[0]
    \\      488254464 blocks super 1.2 [2/2] [UU]
    \\      [==>..................]  resync = 12.6% (61546112/488254464) finish=35.2min speed=201817K/sec
    \\
    \\md3 : inactive sdi1[0](S)
    \\      1000 blocks super 1.2
    \\
    \\unused devices: <none>
;

test "mdstat: healthy, degraded, resyncing and inactive arrays" {
    var r: Report = .{};
    parseMdstat(mdstat_fixture, &r);
    try std.testing.expectEqual(@as(usize, 4), r.count);
    try std.testing.expectEqualStrings("md0", r.items[0].name.slice());
    try std.testing.expectEqual(Status.ok, r.items[0].status);
    try std.testing.expectEqual(Status.crit, r.items[1].status);
    try std.testing.expect(std.mem.find(u8, r.items[1].detail.slice(), "1 of 3") != null);
    try std.testing.expectEqual(Status.warn, r.items[2].status);
    try std.testing.expect(std.mem.find(u8, r.items[2].detail.slice(), "12.6%") != null);
    try std.testing.expectEqual(Status.crit, r.items[3].status);
}

test "mdstat: nothing configured gives an empty report" {
    var r: Report = .{};
    parseMdstat("Personalities :\nunused devices: <none>\n", &r);
    try std.testing.expectEqual(@as(usize, 0), r.count);
}

test "mdstat: a scheduled check is not a warning" {
    var r: Report = .{};
    parseMdstat("md0 : active raid1 sdb1[1] sda1[0]\n      100 blocks [2/2] [UU]\n      [=>....]  check = 3.0% (1/2) finish=1min\n", &r);
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(Status.ok, r.items[0].status);
}

test "zpool rows" {
    var r: Report = .{};
    parseZpool("tank\tONLINE\t61%\nbackup\tDEGRADED\t88%\nold\tOFFLINE\t1%\n\n", &r);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqual(Status.ok, r.items[0].status);
    try std.testing.expectEqual(Status.crit, r.items[1].status);
    try std.testing.expectEqual(Status.warn, r.items[2].status);
    try std.testing.expectEqualStrings("tank", r.items[0].name.slice());
}

const smart_ok =
    \\{"model_name":"WDC WD40EFRX","smart_status":{"passed":true},"temperature":{"current":34},
    \\"power_on_time":{"hours":21874},"ata_smart_attributes":{"table":[{"id":5,"raw":{"value":0}},{"id":197,"raw":{"value":0}}]}}
;
const smart_bad_sectors =
    \\{"model_name":"ST4000","smart_status":{"passed":true},"ata_smart_attributes":{"table":[{"id":5,"raw":{"value":8}}]}}
;
const smart_failed =
    \\{"model_name":"ST4000","smart_status":{"passed":false}}
;
const nvme_warn =
    \\{"model_name":"Samsung 980","smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":0,"media_errors":0,"percentage_used":93}}
;

test "smart: healthy, bad sectors, failed, nvme wear" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Report = .{};
    parseSmart(a, "/dev/sda", smart_ok, &r);
    parseSmart(a, "/dev/sdb", smart_bad_sectors, &r);
    parseSmart(a, "/dev/sdc", smart_failed, &r);
    parseSmart(a, "/dev/nvme0", nvme_warn, &r);
    parseSmart(a, "/dev/sdd", "not json", &r);
    try std.testing.expectEqual(@as(usize, 5), r.count);
    try std.testing.expectEqual(Status.ok, r.items[0].status);
    try std.testing.expectEqualStrings("sda", r.items[0].name.slice());
    try std.testing.expect(std.mem.find(u8, r.items[0].detail.slice(), "34 C") != null);
    try std.testing.expectEqual(Status.warn, r.items[1].status);
    try std.testing.expectEqual(Status.crit, r.items[2].status);
    try std.testing.expectEqual(Status.warn, r.items[3].status);
    try std.testing.expectEqual(Status.warn, r.items[4].status);
}

test "device paths: only plain /dev names" {
    try std.testing.expect(validDevice("/dev/sda"));
    try std.testing.expect(validDevice("/dev/nvme0n1"));
    try std.testing.expect(!validDevice("/dev/"));
    try std.testing.expect(!validDevice("sda"));
    try std.testing.expect(!validDevice("/dev/../etc/passwd"));
    try std.testing.expect(!validDevice("/dev/sda --foo"));
    try std.testing.expect(!validDevice("-d"));
}

test "report json" {
    var r: Report = .{};
    r.add(.raid, "md0", .crit, "degraded \"x\"");
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJson(&out.writer, &r, true);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("items").?.array.items.len);
}

test "parsers survive garbage" {
    var p = std.Random.DefaultPrng.init(31);
    const rng = p.random();
    var buf: [512]u8 = undefined;
    for (0..3000) |i| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const src: []const u8 = switch (i % 3) {
            0 => mdstat_fixture,
            1 => smart_ok,
            else => "tank\tONLINE\t61%\n",
        };
        const n = @min(src.len, buf.len);
        @memcpy(buf[0..n], src[0..n]);
        for (0..rng.uintLessThan(usize, 6) + 1) |_| buf[rng.uintLessThan(usize, n)] = rng.int(u8);
        const cut = rng.uintLessThan(usize, n + 1);
        var r: Report = .{};
        parseMdstat(buf[0..cut], &r);
        parseZpool(buf[0..cut], &r);
        parseSmart(arena.allocator(), "/dev/sda", buf[0..cut], &r);
    }
}
