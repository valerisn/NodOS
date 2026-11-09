//! Argument parsing. Deliberately tiny: a handful of commands do not justify
//! a parsing library, and we are not adding a dependency for it.
const std = @import("std");

pub const Command = enum {
    help,
    version,
    serve,
};

pub const Parsed = struct {
    command: Command,
    config_path: ?[]const u8 = null,
};

pub const ParseError = error{
    UnknownCommand,
    UnexpectedArgument,
    MissingValue,
};

/// `args` is argv without the program name. No args means help, because a
/// server tool that silently does something on bare invocation is a footgun.
pub fn parse(args: []const []const u8) ParseError!Parsed {
    if (args.len == 0) return .{ .command = .help };
    const cmd = std.meta.stringToEnum(Command, args[0]) orelse
        return .{ .command = try flag(args[0]) };

    var out: Parsed = .{ .command = cmd };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (cmd == .serve and std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.config_path = args[i];
        } else return error.UnexpectedArgument;
    }
    return out;
}

fn flag(arg: []const u8) ParseError!Command {
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
    if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;
    return error.UnknownCommand;
}

test "no args shows help" {
    try std.testing.expectEqual(Command.help, (try parse(&.{})).command);
}

test "commands and flags" {
    try std.testing.expectEqual(Command.version, (try parse(&.{"version"})).command);
    try std.testing.expectEqual(Command.version, (try parse(&.{"--version"})).command);
    try std.testing.expectEqual(Command.help, (try parse(&.{"-h"})).command);
}

test "serve takes a config path" {
    const p = try parse(&.{ "serve", "--config", "/etc/nodos.conf" });
    try std.testing.expectEqual(Command.serve, p.command);
    try std.testing.expectEqualStrings("/etc/nodos.conf", p.config_path.?);
    try std.testing.expectError(error.MissingValue, parse(&.{ "serve", "--config" }));
}

test "rejects garbage" {
    try std.testing.expectError(error.UnknownCommand, parse(&.{"frobnicate"}));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "version", "extra" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "help", "--config", "x" }));
}
