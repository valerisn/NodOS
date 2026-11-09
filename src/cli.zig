//! Argument parsing. Deliberately tiny: three commands do not justify a
//! parsing library, and we are not adding a dependency for it.
const std = @import("std");

pub const Command = enum {
    help,
    version,
};

pub const ParseError = error{
    UnknownCommand,
    UnexpectedArgument,
};

/// `args` is argv without the program name. No args means help, because a
/// server tool that silently does something on bare invocation is a footgun.
pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .help;
    const cmd = std.meta.stringToEnum(Command, args[0]) orelse return flag(args[0]);
    if (args.len > 1) return error.UnexpectedArgument;
    return cmd;
}

fn flag(arg: []const u8) ParseError!Command {
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
    if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;
    return error.UnknownCommand;
}

test "no args shows help" {
    try std.testing.expectEqual(Command.help, try parse(&.{}));
}

test "commands and flags" {
    try std.testing.expectEqual(Command.version, try parse(&.{"version"}));
    try std.testing.expectEqual(Command.version, try parse(&.{"--version"}));
    try std.testing.expectEqual(Command.help, try parse(&.{"-h"}));
}

test "rejects garbage" {
    try std.testing.expectError(error.UnknownCommand, parse(&.{"frobnicate"}));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "version", "extra" }));
}
