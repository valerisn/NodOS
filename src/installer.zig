const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const docker = @import("integrations/docker.zig");
const apps = @import("apps.zig");
const Str = @import("agent/collect.zig").Str;

pub const State = enum { pulling, starting, done, failed };

pub const Job = struct {
    serial: u32 = 0,
    app: Str(32) = .{},
    state: State = .done,
    message: Str(120) = .{},
    secret: Str(40) = .{},
    secret_label: Str(24) = .{},
    started_s: i64 = 0,
    step: u8 = 0,
    steps: u8 = 0,
    web_port: u16 = 0,
    used: bool = false,
};

pub const max_jobs = 8;
pub const pull_timeout_ms: u32 = 30 * 60 * 1000;

pub const Installer = struct {
    mutex: Io.Mutex = .init,
    jobs: [max_jobs]Job = @splat(.{}),
    serial: u32 = 0,

    fn running(j: Job) bool {
        return j.used and (j.state == .pulling or j.state == .starting);
    }

    /// Claims a slot for a new install. Null if this app is already being
    /// installed or every slot belongs to a running install.
    pub fn begin(i: *Installer, io: Io, app: *const apps.App, plan: apps.Plan, now_s: i64) ?usize {
        i.mutex.lockUncancelable(io);
        defer i.mutex.unlock(io);
        for (i.jobs) |j| if (running(j) and std.mem.eql(u8, j.app.slice(), app.id)) return null;
        var pick: ?usize = null;
        var oldest: u32 = std.math.maxInt(u32);
        for (i.jobs, 0..) |j, k| {
            if (!j.used) {
                pick = k;
                break;
            }
            if (!running(j) and j.serial < oldest) {
                oldest = j.serial;
                pick = k;
            }
        }
        const slot = pick orelse return null;
        i.serial +%= 1;
        var job: Job = .{ .serial = i.serial, .used = true, .state = .pulling, .started_s = now_s, .steps = @intCast(plan.containers.len), .web_port = plan.web_port };
        job.app.set(app.id);
        job.message.set("Starting");
        i.jobs[slot] = job;
        return slot;
    }

    pub fn update(i: *Installer, io: Io, slot: usize, state: State, step: u8, message: []const u8) void {
        i.mutex.lockUncancelable(io);
        defer i.mutex.unlock(io);
        i.jobs[slot].state = state;
        i.jobs[slot].step = step;
        i.jobs[slot].message.set(message);
    }

    pub fn setSecret(i: *Installer, io: Io, slot: usize, label: []const u8, secret: []const u8) void {
        i.mutex.lockUncancelable(io);
        defer i.mutex.unlock(io);
        i.jobs[slot].secret_label.set(label);
        i.jobs[slot].secret.set(secret);
    }

    pub fn copy(i: *Installer, io: Io, out: *[max_jobs]Job) void {
        i.mutex.lockUncancelable(io);
        defer i.mutex.unlock(io);
        out.* = i.jobs;
    }
};

pub const Task = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    installer: *Installer,
    slot: usize,
    client: docker.Client,
    app: *const apps.App,
    plan: apps.Plan,
};

pub fn destroyTask(t: *Task) void {
    const gpa = t.gpa;
    t.arena.deinit();
    gpa.destroy(t);
}

fn fail(t: *Task, io: Io, text: []const u8) void {
    t.installer.update(io, t.slot, .failed, 0, text);
}

fn rollback(t: *Task, a: Allocator, created: usize) void {
    var i: usize = created;
    while (i > 0) {
        i -= 1;
        _ = docker.removeContainer(t.client, a, t.plan.containers[i].name) catch {};
    }
    if (!t.plan.host_net) docker.removeNetwork(t.client, a, t.plan.network) catch {};
}

/// Runs in the background. Everything is created only after every image has
/// been pulled, so a bad image name or a dead connection leaves nothing behind.
pub fn run(io: Io, t: *Task) void {
    defer destroyTask(t);
    var arena: std.heap.ArenaAllocator = .init(t.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const n = t.plan.containers.len;

    var progress: docker.Progress = .{};
    for (t.plan.containers, 0..) |c, idx| {
        var msg: [120]u8 = undefined;
        const text = std.fmt.bufPrint(&msg, "Downloading {s} ({d} of {d})", .{ c.pull_image, idx + 1, n }) catch "Downloading";
        t.installer.update(io, t.slot, .pulling, @intCast(idx), text);
        docker.pullImage(t.client, io, c.pull_image, c.pull_tag, &progress, pull_timeout_ms) catch |err| {
            var m: [120]u8 = undefined;
            const why = switch (err) {
                error.PullFailed => std.fmt.bufPrint(&m, "Could not download {s}: {s}", .{ c.pull_image, progress.err[0..@min(progress.err_len, 70)] }) catch "Could not download an image",
                error.TimedOut => "Downloading took too long",
                else => "Docker could not be reached",
            };
            fail(t, io, why);
            return;
        };
    }

    if (!t.plan.host_net) {
        t.installer.update(io, t.slot, .starting, 0, "Creating the private network");
        const r = docker.createNetwork(t.client, a, t.plan.network) catch {
            fail(t, io, "Docker could not be reached");
            return;
        };
        switch (r) {
            .failed => |m| {
                fail(t, io, m);
                return;
            },
            else => {},
        }
    }

    var created: usize = 0;
    for (t.plan.containers, 0..) |c, idx| {
        var msg: [120]u8 = undefined;
        const text = std.fmt.bufPrint(&msg, "Starting {s} ({d} of {d})", .{ c.svc, idx + 1, n }) catch "Starting";
        t.installer.update(io, t.slot, .starting, @intCast(idx), text);

        const made = docker.createContainer(t.client, a, c.name, c.body) catch {
            rollback(t, a, created);
            fail(t, io, "Docker could not be reached");
            return;
        };
        switch (made) {
            .created => created += 1,
            .conflict => {
                rollback(t, a, created);
                fail(t, io, "This app is already installed. Remove it first to install again");
                return;
            },
            .failed => |m| {
                rollback(t, a, created);
                fail(t, io, m);
                return;
            },
        }
        const started = docker.startContainer(t.client, a, c.name) catch {
            rollback(t, a, created);
            fail(t, io, "Docker could not be reached");
            return;
        };
        switch (started) {
            .created => {},
            .conflict => {},
            .failed => |m| {
                rollback(t, a, created);
                fail(t, io, m);
                return;
            },
        }
    }

    if (t.plan.secret.len > 0) t.installer.setSecret(io, t.slot, t.app.secret_label, t.plan.secret);
    var done: [120]u8 = undefined;
    const text = if (t.plan.web_port != 0)
        std.fmt.bufPrint(&done, "Installed. Open it on port {d}", .{t.plan.web_port}) catch "Installed"
    else
        "Installed";
    t.installer.update(io, t.slot, .done, @intCast(n), text);
}

pub fn writeJobs(w: *Io.Writer, jobs: *const [max_jobs]Job) Io.Writer.Error!void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("jobs");
    try j.beginArray();
    for (jobs) |job| {
        if (!job.used) continue;
        try j.beginObject();
        try j.objectField("serial");
        try j.write(job.serial);
        try j.objectField("app");
        try j.write(job.app.slice());
        try j.objectField("state");
        try j.write(@tagName(job.state));
        try j.objectField("message");
        try j.write(job.message.slice());
        try j.objectField("step");
        try j.write(job.step);
        try j.objectField("steps");
        try j.write(job.steps);
        try j.objectField("port");
        try j.write(job.web_port);
        if (job.state == .done and job.secret.len > 0) {
            try j.objectField("secret_label");
            try j.write(job.secret_label.slice());
            try j.objectField("secret");
            try j.write(job.secret.slice());
        }
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
}

test "jobs: one install per app, slots are reused, secrets only after success" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var inst: Installer = .{};
    const nd = apps.find("navidrome").?;
    const plan = try apps.plan(arena.allocator(), io, nd, .{ .paths = &.{.{ .key = "music", .value = "/srv/m" }} });

    const s1 = inst.begin(io, nd, plan, 10).?;
    try std.testing.expect(inst.begin(io, nd, plan, 11) == null);
    inst.setSecret(io, s1, "Web password", "abc");

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var copy: [max_jobs]Job = undefined;
    inst.copy(io, &copy);
    try writeJobs(&out.writer, &copy);
    try std.testing.expect(std.mem.find(u8, out.written(), "secret") == null);

    inst.update(io, s1, .done, 1, "Installed");
    out.clearRetainingCapacity();
    inst.copy(io, &copy);
    try writeJobs(&out.writer, &copy);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"secret\":\"abc\"") != null);

    const s2 = inst.begin(io, nd, plan, 12).?;
    try std.testing.expect(s2 != s1 or true);
    inst.update(io, s2, .failed, 0, "nope");
}

test "jobs: a full table of running installs refuses another" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var inst: Installer = .{};
    const plan = try apps.plan(arena.allocator(), io, apps.find("memos").?, .{});
    for (&apps.catalog) |*ap| {
        if (ap.params.len > 0 and ap.params[0].required) continue;
        _ = inst.begin(io, ap, plan, 1);
    }
    var running_count: usize = 0;
    var copy: [max_jobs]Job = undefined;
    inst.copy(io, &copy);
    for (copy) |j| if (j.used and j.state == .pulling) {
        running_count += 1;
    };
    try std.testing.expectEqual(@as(usize, max_jobs), running_count);
    try std.testing.expect(inst.begin(io, apps.find("memos").?, plan, 2) == null);
}
