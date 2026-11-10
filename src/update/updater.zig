const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const Version = @import("version.zig").Version;
const version_mod = @import("version.zig");
const release = @import("release.zig");
const verify = @import("verify.zig");
const extract = @import("extract.zig");
const fetch = @import("fetch.zig");
const config = @import("../config.zig");
const audit = @import("../audit.zig");

const embedded_pubkey = @embedFile("signing.pub");

pub const Mode = enum { apply, check, rollback, auto_run, auto_on, auto_off, auto_status };

pub const Options = struct {
    mode: Mode = .apply,
    yes: bool = false,
    force: bool = false,
    mirror: ?[]const u8 = null,
    pubkey: ?[]const u8 = null,
    binary: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    soak_days: u32 = 3,
};

pub const exit_ok: u8 = 0;
pub const exit_failed: u8 = 1;
pub const exit_usage: u8 = 2;
pub const exit_update_available: u8 = 10;

const default_binary = "/usr/local/bin/nodos";
const default_config = "/etc/nodos/nodos.conf";
const state_file = "update-state";
const unit_service = "nodos";
const unit_timer = "nodos-update.timer";

const Failure = error{ Failed, OutOfMemory };

const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out: *Io.Writer,
    opts: Options,
    cfg: config.Config = .{},
    src: release.Source = release.Source.github,

    fn say(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        c.out.print(fmt ++ "\n", args) catch {};
        c.out.flush() catch {};
    }

    fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) Failure {
        _ = c;
        std.debug.print("nodos update: " ++ fmt ++ "\n", args);
        return error.Failed;
    }
};

pub fn stateHasBad(text: []const u8, tag: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "bad=") and std.mem.eql(u8, line[4..], tag)) return true;
    }
    return false;
}

pub fn stateWithBad(arena: std.mem.Allocator, text: []const u8, tag: []const u8) ![]u8 {
    if (stateHasBad(text, tag)) return arena.dupe(u8, text);
    const sep: []const u8 = if (text.len == 0 or text[text.len - 1] == '\n') "" else "\n";
    return std.fmt.allocPrint(arena, "{s}{s}bad={s}\n", .{ text, sep, tag });
}

pub fn parseVersionOutput(text: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "nodos ")) return null;
    const v = std.mem.trim(u8, t["nodos ".len..], " ");
    return if (v.len == 0) null else v;
}

pub fn healthVersion(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const H = struct { version: []const u8 = "" };
    const h = std.json.parseFromSliceLeaky(H, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    return if (h.version.len == 0) null else h.version;
}

pub fn healthUrl(arena: std.mem.Allocator, listen: []const u8, port: u16) ![]const u8 {
    const host = if (std.mem.eql(u8, listen, "0.0.0.0")) "127.0.0.1" else if (std.mem.eql(u8, listen, "::")) "[::1]" else listen;
    const bracket = std.mem.findScalar(u8, host, ':') != null and host[0] != '[';
    return std.fmt.allocPrint(arena, "http://{s}{s}{s}:{d}/api/v1/health", .{ if (bracket) "[" else "", host, if (bracket) "]" else "", port });
}

pub fn run(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, out: *Io.Writer, opts: Options) u8 {
    var ctx: Ctx = .{ .io = io, .gpa = gpa, .arena = arena, .out = out, .opts = opts };
    return dispatch(&ctx) catch |err| switch (err) {
        error.Failed => exit_failed,
        error.OutOfMemory => blk: {
            std.debug.print("nodos update: out of memory\n", .{});
            break :blk exit_failed;
        },
    };
}

fn dispatch(ctx: *Ctx) Failure!u8 {
    ctx.cfg = loadConfig(ctx);
    const mirror = ctx.opts.mirror orelse if (ctx.cfg.update_mirror.len > 0) ctx.cfg.update_mirror else null;
    if (mirror) |m| ctx.src = release.Source.mirror(ctx.arena, m) catch return error.OutOfMemory;
    if (!release.urlAllowed(ctx.src.meta_url)) return ctx.fail("the update source must be https (http is only allowed for this machine)", .{});

    return switch (ctx.opts.mode) {
        .check => try cmdCheck(ctx),
        .apply => try cmdApply(ctx, false),
        .auto_run => try cmdApply(ctx, true),
        .rollback => try cmdRollback(ctx),
        .auto_on, .auto_off, .auto_status => try cmdAuto(ctx),
    };
}

fn loadConfig(ctx: *Ctx) config.Config {
    const path = ctx.opts.config_path orelse blk: {
        _ = Io.Dir.cwd().statFile(ctx.io, default_config, .{}) catch break :blk null;
        break :blk @as(?[]const u8, default_config);
    } orelse return .{};
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(64 * 1024)) catch return .{};
    var diag: config.Diagnostic = .{};
    return config.parse(ctx.arena, text, &diag) catch .{};
}

const Latest = struct {
    rel: release.Release,
    current: Version,
    current_text: []const u8,
};

fn installedVersion(ctx: *Ctx) []const u8 {
    const path = ctx.opts.binary orelse blk: {
        _ = Io.Dir.cwd().statFile(ctx.io, default_binary, .{}) catch break :blk null;
        break :blk @as(?[]const u8, default_binary);
    } orelse return build_options.version;
    return binaryVersion(ctx, path) orelse build_options.version;
}

fn binaryVersion(ctx: *Ctx, path: []const u8) ?[]const u8 {
    const r = std.process.run(ctx.gpa, ctx.io, .{
        .argv = &.{ path, "version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch return null;
    defer ctx.gpa.free(r.stdout);
    defer ctx.gpa.free(r.stderr);
    const v = parseVersionOutput(r.stdout) orelse return null;
    return ctx.arena.dupe(u8, v) catch null;
}

fn fetchLatest(ctx: *Ctx) Failure!Latest {
    const body = fetch.getOk(ctx.arena, ctx.io, ctx.src.meta_url, 256 * 1024, 20_000) catch |err| switch (err) {
        error.BadStatus => return ctx.fail("the release server has no published release yet (or the address is wrong): {s}", .{ctx.src.meta_url}),
        error.TimedOut => return ctx.fail("the release server did not answer in time", .{}),
        error.UrlNotAllowed => return ctx.fail("refusing to use that update source", .{}),
        else => return ctx.fail("could not reach the release server ({s}). Is this machine online?", .{@errorName(err)}),
    };
    const rel = release.parse(ctx.arena, body) catch |err| return ctx.fail("the release server sent something unreadable ({s})", .{@errorName(err)});
    const current_text = installedVersion(ctx);
    const current = Version.parse(current_text) catch return ctx.fail("the installed binary has an unreadable version ({s})", .{current_text});
    return .{ .rel = rel, .current = current, .current_text = current_text };
}

fn cmdCheck(ctx: *Ctx) Failure!u8 {
    const l = try fetchLatest(ctx);
    ctx.say("installed: nodos {s}", .{l.current_text});
    ctx.say("latest:    nodos {s}", .{l.rel.tag[1..]});
    if (l.rel.prerelease or !l.rel.version.newerThan(l.current)) {
        ctx.say("You are up to date.", .{});
        return exit_ok;
    }
    ctx.say("An update is available. To install it, run:  sudo nodos update", .{});
    if (l.rel.page_url.len > 0) ctx.say("Release notes: {s}", .{l.rel.page_url});
    return exit_update_available;
}

const Target = struct {
    dir: Io.Dir,
    path: []const u8,
    name: []const u8,
};

fn openTarget(ctx: *Ctx) Failure!Target {
    const path = ctx.opts.binary orelse blk: {
        _ = Io.Dir.cwd().statFile(ctx.io, default_binary, .{}) catch break :blk null;
        break :blk @as(?[]const u8, default_binary);
    } orelse {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.executablePath(ctx.io, &buf) catch return ctx.fail("cannot tell where nodos is installed; pass --binary PATH", .{});
        return splitTarget(ctx, try ctx.arena.dupe(u8, buf[0..n]));
    };
    return splitTarget(ctx, path);
}

fn splitTarget(ctx: *Ctx, path: []const u8) Failure!Target {
    const slash = std.mem.findScalarLast(u8, path, '/') orelse std.mem.findScalarLast(u8, path, '\\') orelse
        return ctx.fail("the binary path must include a directory: {s}", .{path});
    const dir_path = if (slash == 0) "/" else path[0..slash];
    const dir = Io.Dir.cwd().openDir(ctx.io, dir_path, .{}) catch |err|
        return ctx.fail("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
    return .{ .dir = dir, .path = path, .name = path[slash + 1 ..] };
}

fn requireRoot(ctx: *Ctx) Failure!void {
    if (builtin.os.tag == .linux and std.os.linux.geteuid() != 0)
        return ctx.fail("this needs root. Run it with sudo.", .{});
}

fn pubkeyText(ctx: *Ctx) []const u8 {
    return ctx.opts.pubkey orelse embedded_pubkey;
}

fn cmdApply(ctx: *Ctx, auto: bool) Failure!u8 {
    const l = try fetchLatest(ctx);
    const tag = l.rel.tag;

    if (l.rel.prerelease or !l.rel.version.newerThan(l.current)) {
        ctx.say("nodos {s} is the newest release. Nothing to do.", .{l.current_text});
        return exit_ok;
    }

    const state_path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ctx.cfg.data_dir, state_file });
    const state = Io.Dir.cwd().readFileAlloc(ctx.io, state_path, ctx.arena, .limited(16 * 1024)) catch "";
    const known_bad = stateHasBad(state, tag);

    if (auto) {
        if (!version_mod.autoAllowed(l.current, l.rel.version)) {
            ctx.say("auto-update: {s} is not a patch release of {d}.{d}.x, so it waits for a manual `sudo nodos update`.", .{ tag, l.current.major, l.current.minor });
            return exit_ok;
        }
        const now_s = Io.Timestamp.now(ctx.io, .real).toSeconds();
        const soak_s: i64 = @as(i64, ctx.opts.soak_days) * 86400;
        if (!release.oldEnough(l.rel, now_s, soak_s)) {
            ctx.say("auto-update: {s} is newer than {d} days, waiting for it to prove itself.", .{ tag, ctx.opts.soak_days });
            return exit_ok;
        }
        if (known_bad) {
            ctx.say("auto-update: {s} failed here before, skipping it.", .{tag});
            return exit_ok;
        }
    } else if (known_bad and !ctx.opts.force) {
        return ctx.fail("{s} failed to start on this machine before. Use --force to try it again.", .{tag});
    }

    if (builtin.os.tag != .linux and ctx.opts.binary == null)
        return ctx.fail("installing updates is only supported on Linux", .{});
    try requireRoot(ctx);

    const arch = release.Arch.current() orelse return ctx.fail("no release is built for this CPU", .{});
    const tgz_name = try release.tarballName(ctx.arena, tag, arch);

    ctx.say("Updating nodos {s} to {s}", .{ l.current_text, tag[1..] });

    const sums = fetchAsset(ctx, tag, "SHA256SUMS", 64 * 1024, 30_000) catch |e| return e;
    const sig = fetchAsset(ctx, tag, "SHA256SUMS.sig", 4 * 1024, 30_000) catch |e| return e;
    ctx.say("Downloading {s}...", .{tgz_name});
    const tgz = fetchAsset(ctx, tag, tgz_name, 64 * 1024 * 1024, 300_000) catch |e| return e;

    // nothing downloaded gets unpacked or run before this passes
    verify.verifyDownload(sums, sig, pubkeyText(ctx), tgz_name, tgz) catch |err| switch (err) {
        error.NoSigningKey => return ctx.fail(
            "this build of nodos has no release signing key compiled in, so it cannot check that a download is genuine and will not install one. " ++
                "Official releases include the key; if you run a private mirror, pass --pubkey HEX.",
            .{},
        ),
        error.BadKey => return ctx.fail("the signing key is malformed", .{}),
        error.BadSignature, error.SignatureMismatch => return ctx.fail(
            "the release signature is NOT valid. Refusing to install. Nothing was changed. If this keeps happening, the download may have been tampered with; tell the maintainers.",
            .{},
        ),
        error.ChecksumMissing => return ctx.fail("the signed checksum list does not mention {s}. Nothing was changed.", .{tgz_name}),
        error.ChecksumMismatch => return ctx.fail("the download does not match its signed checksum. Nothing was changed.", .{}),
    };
    ctx.say("Signature and checksum verified.", .{});

    const bin = extract.binaryFromTarGz(ctx.arena, tgz) catch |err| return ctx.fail("could not read the release archive ({s})", .{@errorName(err)});

    var target = try openTarget(ctx);
    defer target.dir.close(ctx.io);

    const new_name = try std.fmt.allocPrint(ctx.arena, "{s}.new", .{target.name});
    try writeExecutable(ctx, target.dir, new_name, bin);
    errdefer target.dir.deleteFile(ctx.io, new_name) catch {};
    const new_path = try siblingPath(ctx, target.path, new_name);
    try sanityRun(ctx, new_path, tag[1..]);

    const prev_name = try std.fmt.allocPrint(ctx.arena, "{s}.previous", .{target.name});
    target.dir.copyFile(target.name, target.dir, prev_name, ctx.io, .{}) catch |err| {
        target.dir.deleteFile(ctx.io, new_name) catch {};
        return ctx.fail("could not back up the current binary ({s}). Nothing was changed.", .{@errorName(err)});
    };

    // rename is atomic, the installed name is never missing
    target.dir.rename(new_name, target.dir, target.name, ctx.io) catch |err| {
        target.dir.deleteFile(ctx.io, new_name) catch {};
        return ctx.fail("could not install the new binary ({s}). The old one is still in place.", .{@errorName(err)});
    };
    ctx.say("Installed nodos {s} at {s} (previous version kept as {s}).", .{ tag[1..], target.path, prev_name });

    if (!serviceActive(ctx)) {
        ctx.say("The nodos service is not running, so there is nothing to restart. Start it with: sudo systemctl start nodos", .{});
        writeAudit(ctx, "update.applied", l.current_text, tag, true);
        return exit_ok;
    }
    ctx.say("Restarting the service...", .{});
    if (!systemctl(ctx, &.{ "restart", unit_service })) {
        ctx.say("systemctl could not restart nodos; rolling back.", .{});
        return rollbackAfterFailure(ctx, target, prev_name, tag, l.current_text);
    }
    if (waitHealthy(ctx, tag[1..], 30)) {
        ctx.say("nodos {s} is up and healthy.", .{tag[1..]});
        ctx.say("If anything looks wrong, undo it with: sudo nodos update --rollback", .{});
        writeAudit(ctx, "update.applied", l.current_text, tag, true);
        return exit_ok;
    }
    ctx.say("The new version did not become healthy within 30 seconds.", .{});
    return rollbackAfterFailure(ctx, target, prev_name, tag, l.current_text);
}

fn fetchAsset(ctx: *Ctx, tag: []const u8, name: []const u8, max: usize, timeout_ms: u32) Failure![]u8 {
    const url = try release.assetUrl(ctx.arena, ctx.src, tag, name);
    return fetch.getOk(ctx.arena, ctx.io, url, max, timeout_ms) catch |err| switch (err) {
        error.BadStatus => ctx.fail("the release {s} has no file called {s} (it may still be uploading)", .{ tag, name }),
        error.TooLarge => ctx.fail("{s} is larger than expected, refusing it", .{name}),
        error.TimedOut => ctx.fail("downloading {s} timed out", .{name}),
        else => ctx.fail("could not download {s} ({s})", .{ name, @errorName(err) }),
    };
}

fn siblingPath(ctx: *Ctx, path: []const u8, name: []const u8) Failure![]const u8 {
    const slash = std.mem.findScalarLast(u8, path, '/') orelse std.mem.findScalarLast(u8, path, '\\') orelse return name;
    return std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ path[0 .. slash + 1], name });
}

fn writeExecutable(ctx: *Ctx, dir: Io.Dir, name: []const u8, bytes: []const u8) Failure!void {
    const perms = if (@hasDecl(Io.File.Permissions, "fromMode")) Io.File.Permissions.fromMode(0o755) else Io.File.Permissions.default_file;
    var f = dir.createFile(ctx.io, name, .{ .permissions = perms, .truncate = true }) catch |err|
        return ctx.fail("cannot write {s} ({s})", .{ name, @errorName(err) });
    defer f.close(ctx.io);
    f.writeStreamingAll(ctx.io, bytes) catch |err| return ctx.fail("cannot write {s} ({s})", .{ name, @errorName(err) });
}

fn sanityRun(ctx: *Ctx, path: []const u8, want: []const u8) Failure!void {
    const r = std.process.run(ctx.gpa, ctx.io, .{
        .argv = &.{ path, "version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch |err| return ctx.fail("the downloaded binary would not run ({s}). Nothing was changed.", .{@errorName(err)});
    defer ctx.gpa.free(r.stdout);
    defer ctx.gpa.free(r.stderr);
    const got = parseVersionOutput(r.stdout) orelse
        return ctx.fail("the downloaded binary did not report a version. Nothing was changed.", .{});
    if (!std.mem.eql(u8, got, want))
        return ctx.fail("the downloaded binary says it is {s}, but the release is {s}. Nothing was changed.", .{ got, want });
}

fn execCode(ctx: *Ctx, argv: []const []const u8, timeout_s: i64) ?u8 {
    const r = std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    }) catch return null;
    defer ctx.gpa.free(r.stdout);
    defer ctx.gpa.free(r.stderr);
    return switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
}

fn systemctl(ctx: *Ctx, args: []const []const u8) bool {
    var argv: [8][]const u8 = undefined;
    argv[0] = "systemctl";
    for (args, 1..) |a, i| argv[i] = a;
    return (execCode(ctx, argv[0 .. args.len + 1], 60) orelse return false) == 0;
}

fn serviceActive(ctx: *Ctx) bool {
    return (execCode(ctx, &.{ "systemctl", "is-active", "--quiet", unit_service }, 10) orelse return false) == 0;
}

fn waitHealthy(ctx: *Ctx, want: []const u8, seconds: u32) bool {
    const url = healthUrl(ctx.arena, ctx.cfg.listen, ctx.cfg.port) catch return false;
    var waited: u32 = 0;
    while (waited < seconds) : (waited += 1) {
        var scratch: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer scratch.deinit();
        if (fetch.getAny(scratch.allocator(), ctx.io, url, 4096, 2000)) |r| {
            if (r.status == 200) {
                if (healthVersion(scratch.allocator(), r.body)) |v| {
                    if (std.mem.eql(u8, v, want)) return true;
                }
            }
        } else |_| {}
        ctx.io.sleep(.fromSeconds(1), .awake) catch return false;
    }
    return false;
}

fn rollbackAfterFailure(ctx: *Ctx, target: Target, prev_name: []const u8, bad_tag: []const u8, old_version: []const u8) Failure!u8 {
    ctx.say("Rolling back to the previous version...", .{});
    target.dir.copyFile(prev_name, target.dir, target.name, ctx.io, .{}) catch |err|
        return ctx.fail("ROLLBACK FAILED ({s}). The previous binary is at {s}/{s}; copy it over {s} by hand.", .{ @errorName(err), "(same directory)", prev_name, target.path });
    rememberBad(ctx, bad_tag);
    writeAudit(ctx, "update.rolledback", old_version, bad_tag, false);
    const restarted = systemctl(ctx, &.{ "restart", unit_service });
    if (restarted and waitHealthy(ctx, old_version, 30)) {
        ctx.say("Rolled back. nodos {s} is running again.", .{old_version});
    } else {
        ctx.say("Rolled back the binary, but the service is not healthy. Check: journalctl -u nodos -e", .{});
    }
    return ctx.fail("the update to {s} did not work and was undone. It will not be tried again automatically.", .{bad_tag});
}

fn rememberBad(ctx: *Ctx, tag: []const u8) void {
    const path = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ctx.cfg.data_dir, state_file }) catch return;
    const old = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(16 * 1024)) catch "";
    const text = stateWithBad(ctx.arena, old, tag) catch return;
    Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = text }) catch |err|
        std.debug.print("nodos update: could not record the failed version ({s})\n", .{@errorName(err)});
}

fn writeAudit(ctx: *Ctx, action: []const u8, from: []const u8, tag: []const u8, ok: bool) void {
    const path = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ctx.cfg.data_dir, "audit.log" }) catch return;
    var f = Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .write_only }) catch return;
    defer f.close(ctx.io);
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var target_buf: [96]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "{s} -> {s}", .{ from, tag }) catch tag;
    audit.format(&w, .{ .ts = Io.Timestamp.now(ctx.io, .real).toSeconds(), .actor = "updater", .action = action, .target = target, .ok = ok }) catch return;
    const end = f.length(ctx.io) catch return;
    f.writePositionalAll(ctx.io, w.buffered(), end) catch {};
}

fn cmdRollback(ctx: *Ctx) Failure!u8 {
    try requireRoot(ctx);
    var target = try openTarget(ctx);
    defer target.dir.close(ctx.io);
    const prev_name = try std.fmt.allocPrint(ctx.arena, "{s}.previous", .{target.name});
    const prev_path = try siblingPath(ctx, target.path, prev_name);

    _ = target.dir.statFile(ctx.io, prev_name, .{}) catch
        return ctx.fail("there is no previous version to go back to ({s} does not exist)", .{prev_path});

    const r = std.process.run(ctx.gpa, ctx.io, .{
        .argv = &.{ prev_path, "version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch |err| return ctx.fail("the previous binary would not run ({s}); not touching anything", .{@errorName(err)});
    defer ctx.gpa.free(r.stdout);
    defer ctx.gpa.free(r.stderr);
    const prev_version = parseVersionOutput(r.stdout) orelse return ctx.fail("the previous binary did not report a version; not touching anything", .{});
    const replaced_version = binaryVersion(ctx, target.path) orelse build_options.version;

    const holding = try std.fmt.allocPrint(ctx.arena, "{s}.swap", .{target.name});
    target.dir.copyFile(target.name, target.dir, holding, ctx.io, .{}) catch |err|
        return ctx.fail("could not stage the swap ({s})", .{@errorName(err)});
    target.dir.copyFile(prev_name, target.dir, target.name, ctx.io, .{}) catch |err|
        return ctx.fail("could not restore the previous binary ({s})", .{@errorName(err)});
    target.dir.rename(holding, target.dir, prev_name, ctx.io) catch |err|
        std.debug.print("nodos update: restored, but could not keep the replaced binary ({s})\n", .{@errorName(err)});

    var tag_buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&tag_buf, "v{s}", .{replaced_version})) |t| rememberBad(ctx, t) else |_| {}

    ctx.say("Restored nodos {s} (replacing {s}).", .{ prev_version, replaced_version });
    if (serviceActive(ctx)) {
        ctx.say("Restarting the service...", .{});
        if (!systemctl(ctx, &.{ "restart", unit_service }) or !waitHealthy(ctx, prev_version, 30)) {
            return ctx.fail("the service did not come back healthy. Check: journalctl -u nodos -e", .{});
        }
        ctx.say("nodos {s} is up and healthy.", .{prev_version});
    }
    writeAudit(ctx, "update.rollback", replaced_version, prev_version, true);
    return exit_ok;
}

const auto_warning =
    \\Automatic updates are PROBABLY NOT WHAT YOU WANT.
    \\
    \\  Software that updates itself while you are not looking can break your
    \\  server at 3 am. If a release turns out to be broken, it will be installed
    \\  on this machine anyway until the maintainers notice and pull it.
    \\
    \\What is done to limit that:
    \\  - only patch releases of your current minor version (0.1.x to 0.1.y),
    \\    never a bigger jump
    \\  - a release must be at least 3 days old first, so a bad one is usually
    \\    pulled before it reaches you
    \\  - every download is checked against the maintainers' signature
    \\  - the new version must come up healthy, or it is rolled back and never
    \\    tried again
    \\
    \\It still is not risk free. The safer habit is to read the release notes
    \\and run `sudo nodos update` yourself when it suits you.
    \\
;

fn cmdAuto(ctx: *Ctx) Failure!u8 {
    switch (ctx.opts.mode) {
        .auto_status => {
            const enabled = (execCode(ctx, &.{ "systemctl", "is-enabled", "--quiet", unit_timer }, 10) orelse
                return ctx.fail("systemd is not available here", .{})) == 0;
            ctx.say("auto-update: {s}", .{if (enabled) "ON (not recommended)" else "off"});
            if (enabled) ctx.say("turn it off with: sudo nodos update --auto off", .{});
            return exit_ok;
        },
        .auto_off => {
            try requireRoot(ctx);
            if (!systemctl(ctx, &.{ "disable", "--now", unit_timer })) return ctx.fail("could not disable {s}", .{unit_timer});
            ctx.say("auto-update is off.", .{});
            return exit_ok;
        },
        .auto_on => {
            try requireRoot(ctx);
            if (!ctx.opts.yes) {
                ctx.out.writeAll(auto_warning) catch {};
                ctx.say("To turn it on anyway, run:  sudo nodos update --auto on --yes", .{});
                return exit_usage;
            }
            if ((execCode(ctx, &.{ "systemctl", "cat", unit_timer }, 10) orelse 1) != 0)
                return ctx.fail("{s} is not installed. Re-run scripts/install.sh from a recent release, which installs it.", .{unit_timer});
            if (!systemctl(ctx, &.{ "enable", "--now", unit_timer })) return ctx.fail("could not enable {s}", .{unit_timer});
            ctx.say("auto-update is ON. It checks daily and installs only safe patch releases.", .{});
            ctx.say("Turn it off any time with: sudo nodos update --auto off", .{});
            return exit_ok;
        },
        else => unreachable,
    }
}

test "bad-version state file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!stateHasBad("", "v1.0.0"));
    const one = try stateWithBad(a, "", "v1.0.0");
    try std.testing.expectEqualStrings("bad=v1.0.0\n", one);
    try std.testing.expect(stateHasBad(one, "v1.0.0"));
    try std.testing.expect(!stateHasBad(one, "v1.0.1"));
    try std.testing.expect(!stateHasBad(one, "v1.0"));
    const two = try stateWithBad(a, "bad=v1.0.0", "v1.0.1");
    try std.testing.expectEqualStrings("bad=v1.0.0\nbad=v1.0.1\n", two);
    try std.testing.expectEqualStrings(two, try stateWithBad(a, two, "v1.0.1"));
    try std.testing.expect(stateHasBad("junk\r\nbad=v2.0.0\r\n", "v2.0.0"));
}

test "version output and health json parsing" {
    try std.testing.expectEqualStrings("1.2.3", parseVersionOutput("nodos 1.2.3\n").?);
    try std.testing.expectEqualStrings("0.0.1-dev", parseVersionOutput("  nodos 0.0.1-dev \r\n").?);
    try std.testing.expect(parseVersionOutput("") == null);
    try std.testing.expect(parseVersionOutput("nodos ") == null);
    try std.testing.expect(parseVersionOutput("something else 1.0") == null);
    try std.testing.expect(parseVersionOutput("error: unknown command") == null);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1.0.0", healthVersion(a, "{\"status\":\"ok\",\"version\":\"1.0.0\"}").?);
    try std.testing.expect(healthVersion(a, "{\"status\":\"ok\"}") == null);
    try std.testing.expect(healthVersion(a, "<html>") == null);
}

test "health url follows the configured address" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/api/v1/health", try healthUrl(a, "127.0.0.1", 8080));
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/api/v1/health", try healthUrl(a, "0.0.0.0", 9000));
    try std.testing.expectEqualStrings("http://[::1]:8080/api/v1/health", try healthUrl(a, "::", 8080));
    try std.testing.expectEqualStrings("http://192.168.1.5:8080/api/v1/health", try healthUrl(a, "192.168.1.5", 8080));
    try std.testing.expectEqualStrings("http://[fe80::1]:8080/api/v1/health", try healthUrl(a, "fe80::1", 8080));
}

test "the auto-update warning says what matters" {
    try std.testing.expect(std.mem.find(u8, auto_warning, "PROBABLY NOT WHAT YOU WANT") != null);
    try std.testing.expect(std.mem.find(u8, auto_warning, "patch releases") != null);
    try std.testing.expect(std.mem.find(u8, auto_warning, "rolled back") != null);
    try std.testing.expect(std.mem.find(u8, auto_warning, "\xe2\x80\x94") == null);
}
