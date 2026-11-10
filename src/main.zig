const std = @import("std");
const Io = std.Io;
const nodos = @import("nodos");

const usage =
    \\NodOS - home server management
    \\
    \\Usage: nodos <command>
    \\
    \\Commands:
    \\  serve [--config PATH]        Run the server
    \\  user add NAME [--role admin|viewer] [--config PATH]
    \\                               Create a user; password is read from stdin
    \\  user passwd NAME [--config PATH]
    \\                               Change a password; new one is read from stdin
    \\  user remove NAME [--config PATH]
    \\                               Delete a user (never the last admin)
    \\  user list [--config PATH]    Show users and roles
    \\  update [--check] [--rollback] [--auto on|off|status] [--yes] [--config PATH]
    \\                               Check for, install or undo a release
    \\  backup --out FILE [--force] [--config PATH]
    \\                               Save users and the audit log to a tar file
    \\  restore FILE [--force] [--config PATH]
    \\                               Put a backup back (stop the server first)
    \\  version                      Print version and exit
    \\  help                         Show this message
    \\
;

var runtime_level: std.atomic.Value(u8) = .init(@backingInt(std.log.Level.info));

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) > runtime_level.load(.monotonic)) return;
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [512]u8 = undefined;
    var out: Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const w = &out.interface;

    const cmd = nodos.cli.parse(args[1..]) catch |err| {
        std.debug.print("nodos: {s}\n\n{s}", .{ @errorName(err), usage });
        std.process.exit(2);
    };

    switch (cmd.command) {
        .help => try w.writeAll(usage),
        .version => try w.print("nodos {s}\n", .{nodos.version}),
        .serve => try serve(init, cmd),
        .update => {
            try w.flush();
            const code = nodos.update.updater.run(init.io, init.gpa, arena, w, cmd.update);
            try w.flush();
            if (code != 0) std.process.exit(code);
        },
        .backup => try backupCommand(init, cmd, w),
        .restore => try restoreCommand(init, cmd, w),
        .user_add, .user_passwd, .user_remove, .user_list => try userCommand(init, cmd, w),
    }
    try w.flush();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("nodos: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn serve(init: std.process.Init, cmd: nodos.cli.Parsed) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = loadConfig(io, arena, cmd.config_path);
    runtime_level.store(@backingInt(toLogLevel(cfg.log_level)), .monotonic);

    var dir = openDataDir(io, cfg.data_dir);
    defer dir.close(io);

    const users = nodos.users.load(io, arena, dir) catch |err|
        fatal("cannot load users: {s}", .{@errorName(err)});

    var app = nodos.server.App.init(init.gpa, io, cfg, users) catch |err|
        fatal("startup failed: {s}", .{@errorName(err)});
    defer app.deinit(io);
    app.audit_log = nodos.audit.Log.open(io, dir) catch |err|
        fatal("cannot open audit log: {s}", .{@errorName(err)});

    nodos.server.run(io, &app) catch |err| {
        std.log.err("server stopped: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn readPasswordHash(init: std.process.Init, hash_buf: *[nodos.auth.hash_buf_len]u8) []const u8 {
    var in_buf: [512]u8 = undefined;
    var stdin: Io.File.Reader = .init(.stdin(), init.io, &in_buf);
    const line = (stdin.interface.takeDelimiter('\n') catch fatal("cannot read password", .{})) orelse
        fatal("no password on stdin", .{});
    const password = std.mem.trimEnd(u8, line, "\r");
    return nodos.auth.hashPassword(init.gpa, init.io, password, hash_buf) catch |err| switch (err) {
        error.PasswordTooShort => fatal("password must be at least {d} characters", .{nodos.auth.min_password_len}),
        error.PasswordTooLong => fatal("password must be at most {d} characters", .{nodos.auth.max_password_len}),
        else => fatal("hashing failed: {s}", .{@errorName(err)}),
    };
}

fn userCommand(init: std.process.Init, cmd: nodos.cli.Parsed, w: *Io.Writer) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = loadConfig(io, arena, cmd.config_path);
    var dir = openDataDir(io, cfg.data_dir);
    defer dir.close(io);

    var users = nodos.users.load(io, arena, dir) catch |err|
        fatal("cannot load users: {s}", .{@errorName(err)});

    switch (cmd.command) {
        .user_list => {
            if (users.list.items.len == 0) try w.writeAll("no users yet\n");
            for (users.list.items) |u| try w.print("{s}\t{s}\n", .{ u.name, @tagName(u.role) });
            return;
        },
        .user_add => {
            var hash_buf: [nodos.auth.hash_buf_len]u8 = undefined;
            const phc = readPasswordHash(init, &hash_buf);
            const user = users.add(arena, cmd.user_name.?, cmd.role, phc) catch |err| switch (err) {
                error.InvalidName => fatal("name must be 1-32 chars of a-z, 0-9, '-' or '_'", .{}),
                error.DuplicateName => fatal("user '{s}' already exists", .{cmd.user_name.?}),
                else => fatal("cannot add user: {s}", .{@errorName(err)}),
            };
            try w.print("created {s} user '{s}'\n", .{ @tagName(user.role), user.name });
        },
        .user_passwd => {
            if (users.find(cmd.user_name.?) == null) fatal("no such user '{s}'", .{cmd.user_name.?});
            var hash_buf: [nodos.auth.hash_buf_len]u8 = undefined;
            const phc = readPasswordHash(init, &hash_buf);
            users.setHash(arena, cmd.user_name.?, phc) catch |err| fatal("cannot change password: {s}", .{@errorName(err)});
            try w.print("changed password for '{s}'\n", .{cmd.user_name.?});
        },
        .user_remove => {
            users.remove(cmd.user_name.?) catch |err| switch (err) {
                error.NoSuchUser => fatal("no such user '{s}'", .{cmd.user_name.?}),
                error.LastAdmin => fatal("'{s}' is the only admin; create another admin first", .{cmd.user_name.?}),
                else => fatal("cannot remove user: {s}", .{@errorName(err)}),
            };
            try w.print("removed '{s}'\n", .{cmd.user_name.?});
        },
        else => unreachable,
    }
    nodos.users.save(io, dir, &users) catch |err| fatal("cannot save users: {s}", .{@errorName(err)});
    try w.writeAll("restart nodos for this to take effect on a running server\n");
}

fn fileExists(io: Io, dir: Io.Dir, name: []const u8) bool {
    var f = dir.openFile(io, name, .{}) catch return false;
    f.close(io);
    return true;
}

fn writePrivate(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, name, .{ .permissions = nodos.users.privateFile(), .replace = true });
    defer atomic.deinit(io);
    var buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &buf);
    try fw.interface.writeAll(data);
    try fw.interface.flush();
    try atomic.replace(io);
}

fn backupCommand(init: std.process.Init, cmd: nodos.cli.Parsed, w: *Io.Writer) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = loadConfig(io, arena, cmd.config_path);
    var dir = openDataDir(io, cfg.data_dir);
    defer dir.close(io);

    const out_path = cmd.path.?;
    const out_dir_path = std.fs.path.dirname(out_path) orelse ".";
    const out_name = std.fs.path.basename(out_path);
    var out_dir = Io.Dir.cwd().openDir(io, out_dir_path, .{}) catch |err|
        fatal("cannot open {s}: {s}", .{ out_dir_path, @errorName(err) });
    defer out_dir.close(io);
    if (!cmd.force and fileExists(io, out_dir, out_name)) fatal("{s} already exists; pass --force to replace it", .{out_path});

    const users_db = dir.readFileAlloc(io, nodos.backup.users_name, arena, .limited(1024 * 1024)) catch |err|
        fatal("cannot read users.db in {s}: {s}", .{ cfg.data_dir, @errorName(err) });
    const now_s = Io.Timestamp.now(io, .real).toSeconds();
    const mf = try nodos.backup.manifest(arena, nodos.version, now_s);

    var files: std.ArrayList(nodos.backup.Entry) = .empty;
    try files.append(arena, .{ .name = nodos.backup.manifest_name, .data = mf });
    try files.append(arena, .{ .name = nodos.backup.users_name, .data = users_db });
    if (dir.readFileAlloc(io, nodos.backup.audit_name, arena, .limited(128 * 1024 * 1024))) |log| {
        try files.append(arena, .{ .name = nodos.backup.audit_name, .data = log });
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("nodos: skipping audit.log ({s})\n", .{@errorName(err)}),
    }

    const tar = try nodos.backup.pack(arena, files.items, now_s);
    writePrivate(io, out_dir, out_name, tar) catch |err| fatal("cannot write {s}: {s}", .{ out_path, @errorName(err) });
    try w.print("wrote {s} ({d} bytes, mode 0600)\nIt holds password hashes. Keep it private.\nCopy your config file too ({s}); it is not part of the backup.\n", .{ out_path, tar.len, cmd.config_path orelse "no config file in use" });
}

fn restoreCommand(init: std.process.Init, cmd: nodos.cli.Parsed, w: *Io.Writer) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = loadConfig(io, arena, cmd.config_path);
    const tar = Io.Dir.cwd().readFileAlloc(io, cmd.path.?, arena, .limited(160 * 1024 * 1024)) catch |err|
        fatal("cannot read {s}: {s}", .{ cmd.path.?, @errorName(err) });
    const entries = nodos.backup.unpack(arena, tar) catch |err| fatal("{s} is not a NodOS backup ({s})", .{ cmd.path.?, @errorName(err) });
    nodos.backup.check(arena, entries) catch |err| fatal("backup refused ({s}): it must hold a readable user list with an admin", .{@errorName(err)});

    var dir = openDataDir(io, cfg.data_dir);
    defer dir.close(io);
    if (!cmd.force and fileExists(io, dir, nodos.backup.users_name))
        fatal("{s} already has users; pass --force to overwrite them (stop the server first)", .{cfg.data_dir});

    for (entries) |e| {
        if (std.mem.eql(u8, e.name, nodos.backup.manifest_name)) continue;
        writePrivate(io, dir, e.name, e.data) catch |err| fatal("cannot write {s}: {s}", .{ e.name, @errorName(err) });
        try w.print("restored {s} ({d} bytes)\n", .{ e.name, e.data.len });
    }
    try w.writeAll("done. start nodos again\n");
}

fn openDataDir(io: Io, path: []const u8) Io.Dir {
    Io.Dir.cwd().createDirPath(io, path) catch |err|
        fatal("cannot create data_dir {s}: {s}", .{ path, @errorName(err) });
    return Io.Dir.cwd().openDir(io, path, .{}) catch |err|
        fatal("cannot open data_dir {s}: {s}", .{ path, @errorName(err) });
}

fn toLogLevel(l: nodos.config.LogLevel) std.log.Level {
    return switch (l) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
}

fn loadConfig(io: Io, arena: std.mem.Allocator, path: ?[]const u8) nodos.config.Config {
    const p = path orelse return .{};
    const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 * 1024)) catch |err|
        fatal("cannot read {s}: {s}", .{ p, @errorName(err) });
    var diag: nodos.config.Diagnostic = .{};
    return nodos.config.parse(arena, text, &diag) catch |err| switch (err) {
        error.InvalidConfig => fatal("{s}:{d}: {s}", .{ p, diag.line, diag.message }),
        error.OutOfMemory => fatal("out of memory", .{}),
    };
}

test {
    _ = nodos;
}
