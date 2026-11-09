const std = @import("std");
const Io = std.Io;
const nodos = @import("nodos");

const usage =
    \\NodOS - home server management
    \\
    \\Usage: nodos <command>
    \\
    \\Commands:
    \\  serve [--config PATH]   Run the server
    \\  version                 Print version and exit
    \\  help                    Show this message
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
        .serve => {
            const cfg = loadConfig(init.io, arena, cmd.config_path);
            runtime_level.store(@backingInt(toLogLevel(cfg.log_level)), .monotonic);
            nodos.server.run(init.io, cfg) catch |err| {
                std.log.err("server stopped: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
        },
    }
    try w.flush();
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
    const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 * 1024)) catch |err| {
        std.debug.print("nodos: cannot read {s}: {s}\n", .{ p, @errorName(err) });
        std.process.exit(1);
    };
    var diag: nodos.config.Diagnostic = .{};
    return nodos.config.parse(arena, text, &diag) catch |err| switch (err) {
        error.InvalidConfig => {
            std.debug.print("nodos: {s}:{d}: {s}\n", .{ p, diag.line, diag.message });
            std.process.exit(1);
        },
        error.OutOfMemory => {
            std.debug.print("nodos: out of memory\n", .{});
            std.process.exit(1);
        },
    };
}

test {
    _ = nodos;
}
