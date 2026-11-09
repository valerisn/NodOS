//! systemd service status, logs and control, through `systemctl` and
//! `journalctl` with fixed argument vectors. No shell, ever.
//!
//! The safety model is an allowlist: only units the admin names in the config
//! (`services = ssh, nginx`) can be shown or touched. A unit name from a
//! request is matched against that list by exact string comparison before it
//! reaches any command line, and names are also checked for shape so that even
//! a sloppy config can't smuggle in an option like `--now`.
//!
//! Starting and stopping needs OS permission. NodOS does not run as root; the
//! admin grants it per unit with polkit (see docs/installation). Without that,
//! start/stop fail with systemd's own message, which we pass through.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const max_units = 32;

pub const Error = error{
    /// systemctl is missing, or this is not a systemd host.
    Unavailable,
    BadOutput,
    TimedOut,
    OutOfMemory,
};

/// One unit name, as written in the config, without the `.service` suffix.
pub fn validUnit(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    // A leading dash would be read by systemctl as an option.
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '@' or c == ':')) return false;
    }
    return true;
}

pub const Action = enum {
    start,
    stop,
    restart,

    pub fn parse(s: []const u8) ?Action {
        return std.meta.stringToEnum(Action, s);
    }
};

pub const Status = struct {
    unit: []const u8,
    description: []const u8 = "",
    /// loaded, not-found, masked, ...
    load: []const u8 = "",
    /// active, inactive, failed, activating, deactivating
    active: []const u8 = "",
    /// running, exited, dead, failed, ...
    sub: []const u8 = "",
    pid: u32 = 0,
};

/// Parses `systemctl show a b c -p ...` output: blocks of Key=Value lines,
/// one blank line between units. Order of blocks follows the unit arguments.
/// Strings point into `text`.
pub fn parseShow(arena: Allocator, units: []const []const u8, text: []const u8) Error![]Status {
    const out = try arena.alloc(Status, units.len);
    for (out, units) |*o, u| o.* = .{ .unit = u };

    var idx: usize = 0;
    var seen_any = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (seen_any) idx += 1;
            seen_any = false;
            continue;
        }
        if (idx >= out.len) break;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        seen_any = true;
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        const s = &out[idx];
        if (std.mem.eql(u8, key, "Description")) s.description = val;
        if (std.mem.eql(u8, key, "LoadState")) s.load = val;
        if (std.mem.eql(u8, key, "ActiveState")) s.active = val;
        if (std.mem.eql(u8, key, "SubState")) s.sub = val;
        if (std.mem.eql(u8, key, "MainPID")) s.pid = std.fmt.parseInt(u32, val, 10) catch 0;
    }
    return out;
}

pub fn writeStatuses(w: *Io.Writer, list: []const Status) Io.Writer.Error!void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("services");
    try j.beginArray();
    for (list) |s| {
        try j.beginObject();
        try j.objectField("unit");
        try j.write(s.unit);
        try j.objectField("description");
        try j.write(s.description);
        try j.objectField("load");
        try j.write(s.load);
        try j.objectField("active");
        try j.write(s.active);
        try j.objectField("sub");
        try j.write(s.sub);
        try j.objectField("pid");
        try j.write(s.pid);
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
}

pub const ActionOutcome = union(enum) {
    done,
    /// systemctl said no; the message is its stderr, first line.
    refused: []const u8,
};

pub const Client = struct {
    io: Io,
    gpa: Allocator,
    /// Allowlisted unit names. Owned by the config arena.
    units: []const []const u8,

    pub fn allowed(c: Client, unit: []const u8) bool {
        for (c.units) |u| if (std.mem.eql(u8, u, unit)) return true;
        return false;
    }

    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };

    const Output = struct { code: u8, stdout: []u8, stderr: []u8 };

    fn exec(c: Client, argv: []const []const u8, stdout_limit: usize) Error!Output {
        if (comptime build_options.fake_host) return fake.exec(c.gpa, argv);
        const r = std.process.run(c.gpa, c.io, .{
            .argv = argv,
            .stdout_limit = .limited(stdout_limit),
            .stderr_limit = .limited(16 * 1024),
            .timeout = timeout,
        }) catch |err| switch (err) {
            error.Timeout => return error.TimedOut,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unavailable,
        };
        const code: u8 = switch (r.term) {
            .exited => |x| x,
            else => 255,
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// Status of every allowlisted unit with one process launch.
    pub fn statuses(c: Client, arena: Allocator) Error![]Status {
        if (c.units.len == 0) return &.{};
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "systemctl", "show", "--no-pager", "-p", "Description", "-p", "LoadState", "-p", "ActiveState", "-p", "SubState", "-p", "MainPID" });
        // Names are validated and allowlisted, and a leading-dash name cannot
        // pass validUnit, so each one is a plain positional argument.
        for (c.units) |u| try argv.append(arena, try std.fmt.allocPrint(arena, "{s}.service", .{u}));
        const out = try c.exec(argv.items, 256 * 1024);
        defer c.gpa.free(out.stdout);
        defer c.gpa.free(out.stderr);
        if (out.code != 0) return error.BadOutput;
        // parseShow slices into its input, so copy it into the arena first.
        const text = try arena.dupe(u8, out.stdout);
        return parseShow(arena, c.units, text);
    }

    pub fn act(c: Client, arena: Allocator, unit: []const u8, action: Action) Error!ActionOutcome {
        if (!c.allowed(unit)) return error.BadOutput;
        const name = try std.fmt.allocPrint(arena, "{s}.service", .{unit});
        const out = try c.exec(&.{ "systemctl", "--no-ask-password", @tagName(action), name }, 4096);
        defer c.gpa.free(out.stdout);
        defer c.gpa.free(out.stderr);
        if (out.code == 0) return .done;
        return .{ .refused = try arena.dupe(u8, firstLine(out.stderr)) };
    }

    /// Last `lines` journal lines for the unit, plain text.
    pub fn logs(c: Client, arena: Allocator, unit: []const u8, lines: usize) Error![]const u8 {
        if (!c.allowed(unit)) return error.BadOutput;
        const name = try std.fmt.allocPrint(arena, "{s}.service", .{unit});
        const n = try std.fmt.allocPrint(arena, "{d}", .{lines});
        const out = try c.exec(&.{ "journalctl", "--no-pager", "-o", "short-iso", "-u", name, "-n", n }, 1024 * 1024);
        defer c.gpa.free(out.stdout);
        defer c.gpa.free(out.stderr);
        if (out.code != 0) return error.BadOutput;
        return try arena.dupe(u8, out.stdout);
    }
};

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \r\n\t");
    const nl = std.mem.findScalar(u8, t, '\n') orelse t.len;
    return t[0..@min(nl, 200)];
}

// ---------------------------------------------------------------- dev fake

const fake = struct {
    const names = [_][]const u8{ "ssh", "nginx", "postgresql", "cron", "avahi-daemon" };
    var up = [_]bool{ true, true, true, true, false };

    fn exec(gpa: Allocator, argv: []const []const u8) Error!Client.Output {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (argv.len > 1 and std.mem.eql(u8, argv[0], "systemctl") and std.mem.eql(u8, argv[1], "show")) {
            for (argv) |a| {
                if (!std.mem.endsWith(u8, a, ".service")) continue;
                const base = a[0 .. a.len - ".service".len];
                const i = for (names, 0..) |n, k| {
                    if (std.mem.eql(u8, n, base)) break k;
                } else {
                    try out.print(gpa, "Description={s}\nLoadState=not-found\nActiveState=inactive\nSubState=dead\nMainPID=0\n\n", .{a});
                    continue;
                };
                if (up[i]) {
                    try out.print(gpa, "Description={s} service\nLoadState=loaded\nActiveState=active\nSubState=running\nMainPID={d}\n\n", .{ base, 1000 + i * 111 });
                } else {
                    try out.print(gpa, "Description={s} service\nLoadState=loaded\nActiveState=inactive\nSubState=dead\nMainPID=0\n\n", .{base});
                }
            }
            return .{ .code = 0, .stdout = try out.toOwnedSlice(gpa), .stderr = try gpa.alloc(u8, 0) };
        }
        if (argv.len > 2 and std.mem.eql(u8, argv[0], "systemctl")) {
            const verb = argv[2];
            const unit = argv[3];
            for (names, 0..) |n, i| {
                if (std.mem.startsWith(u8, unit, n)) {
                    up[i] = !std.mem.eql(u8, verb, "stop");
                    return .{ .code = 0, .stdout = try gpa.alloc(u8, 0), .stderr = try gpa.alloc(u8, 0) };
                }
            }
            return .{ .code = 5, .stdout = try gpa.alloc(u8, 0), .stderr = try gpa.dupe(u8, "Failed to restart: Unit not found.\n") };
        }
        const text = "2026-11-09T05:00:01+0000 homebox sshd[812]: Server listening on 0.0.0.0 port 22.\n2026-11-09T05:12:44+0000 homebox sshd[1203]: Accepted publickey for keaghan\n";
        return .{ .code = 0, .stdout = try gpa.dupe(u8, text), .stderr = try gpa.alloc(u8, 0) };
    }
};

// ---------------------------------------------------------------- tests

test "unit names: shape check blocks options and path tricks" {
    try std.testing.expect(validUnit("ssh"));
    try std.testing.expect(validUnit("avahi-daemon"));
    try std.testing.expect(validUnit("getty@tty1"));
    try std.testing.expect(validUnit("systemd-resolved"));
    try std.testing.expect(!validUnit(""));
    try std.testing.expect(!validUnit("--now"));
    try std.testing.expect(!validUnit("-p"));
    try std.testing.expect(!validUnit("a b"));
    try std.testing.expect(!validUnit("a/b"));
    try std.testing.expect(!validUnit("a;rm"));
    try std.testing.expect(!validUnit("a\nb"));
    try std.testing.expect(!validUnit("../x"));
    const long: [65]u8 = @splat('a');
    try std.testing.expect(!validUnit(&long));
}

test "actions: only start, stop, restart" {
    try std.testing.expectEqual(Action.stop, Action.parse("stop").?);
    try std.testing.expect(Action.parse("mask") == null);
    try std.testing.expect(Action.parse("disable") == null);
    try std.testing.expect(Action.parse("kill") == null);
    try std.testing.expect(Action.parse("daemon-reload") == null);
}

const show_fixture =
    \\Description=OpenBSD Secure Shell server
    \\LoadState=loaded
    \\ActiveState=active
    \\SubState=running
    \\MainPID=812
    \\
    \\Description=ghost.service
    \\LoadState=not-found
    \\ActiveState=inactive
    \\SubState=dead
    \\MainPID=0
    \\
    \\Description=A high performance web server
    \\LoadState=loaded
    \\ActiveState=failed
    \\SubState=failed
    \\MainPID=0
    \\
;

test "show output parses per unit in argument order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const units = [_][]const u8{ "ssh", "ghost", "nginx" };
    const list = try parseShow(arena.allocator(), &units, show_fixture);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("ssh", list[0].unit);
    try std.testing.expectEqualStrings("active", list[0].active);
    try std.testing.expectEqual(@as(u32, 812), list[0].pid);
    try std.testing.expectEqualStrings("not-found", list[1].load);
    try std.testing.expectEqualStrings("failed", list[2].active);
}

test "short or empty show output leaves defaults instead of crashing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const units = [_][]const u8{ "a", "b" };
    const list = try parseShow(arena.allocator(), &units, "Description=only one\nActiveState=active\n");
    try std.testing.expectEqualStrings("active", list[0].active);
    try std.testing.expectEqualStrings("", list[1].active);
    const none = try parseShow(arena.allocator(), &units, "");
    try std.testing.expectEqualStrings("", none[0].active);
    // more blocks than units: extra ones are ignored
    const extra = try parseShow(arena.allocator(), units[0..1], show_fixture);
    try std.testing.expectEqual(@as(usize, 1), extra.len);
}

test "statuses encode to valid json, hostile descriptions included" {
    const list = [_]Status{.{ .unit = "ssh", .description = "a \"quoted\"\nthing", .load = "loaded", .active = "active", .sub = "running", .pid = 5 }};
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeStatuses(&out.writer, &list);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const item = parsed.value.object.get("services").?.array.items[0].object;
    try std.testing.expectEqualStrings("a \"quoted\"\nthing", item.get("description").?.string);
    try std.testing.expectEqual(@as(i64, 5), item.get("pid").?.integer);
}

test "allowlist is exact match" {
    const units = [_][]const u8{ "ssh", "nginx" };
    const c: Client = .{ .io = std.testing.io, .gpa = std.testing.allocator, .units = &units };
    try std.testing.expect(c.allowed("ssh"));
    try std.testing.expect(!c.allowed("ss"));
    try std.testing.expect(!c.allowed("ssh.service"));
    try std.testing.expect(!c.allowed("SSH"));
    try std.testing.expect(!c.allowed(""));
    try std.testing.expect(!c.allowed("nginx "));
}

test "first line of stderr is clipped and trimmed" {
    try std.testing.expectEqualStrings("Interactive authentication required.", firstLine("Interactive authentication required.\nSee system logs and 'systemctl status x' for details.\n"));
    try std.testing.expectEqualStrings("", firstLine("  \n"));
}
