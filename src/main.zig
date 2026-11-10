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
    \\  version                      Print version and exit
    \\  help                         Show this message
    \\
;

// Filter at runtime so the config file can set the level. The journal adds
// timestamps when we run under systemd, so we don't bother with our own.
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

/// Password comes from stdin, never argv: argv shows up in `ps` and shell
/// history. Returns a PHC hash in `hash_buf`.
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

/// All the `nodos user ...` commands: load users.db, change it, write it back.
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
            // Check the user exists before asking for anything.
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
    // The running server keeps its own copy, loaded at start.
    try w.writeAll("restart nodos for this to take effect on a running server\n");
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

/// Exits the process on any problem. Starting with a half-read config is
/// worse than not starting.
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
