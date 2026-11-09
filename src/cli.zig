//! Argument parsing. Deliberately tiny: a handful of commands do not justify
//! a parsing library, and we are not adding a dependency for it.
const std = @import("std");
const auth = @import("auth.zig");

pub const Command = enum {
    help,
    version,
    serve,
    user_add,
};

pub const Parsed = struct {
    command: Command,
    config_path: ?[]const u8 = null,
    /// user_add only
    user_name: ?[]const u8 = null,
    role: auth.Role = .admin,
};

pub const ParseError = error{
    UnknownCommand,
    UnexpectedArgument,
    MissingValue,
    InvalidRole,
};

/// `args` is argv without the program name. No args means help, because a
/// server tool that silently does something on bare invocation is a footgun.
pub fn parse(args: []const []const u8) ParseError!Parsed {
    if (args.len == 0) return .{ .command = .help };

    var out: Parsed = undefined;
    var rest: []const []const u8 = undefined;

    if (std.mem.eql(u8, args[0], "user")) {
        if (args.len < 2 or !std.mem.eql(u8, args[1], "add")) return error.UnknownCommand;
        if (args.len < 3) return error.MissingValue;
        out = .{ .command = .user_add, .user_name = args[2] };
        rest = args[3..];
    } else if (std.meta.stringToEnum(Command, args[0])) |cmd| {
        if (cmd == .user_add) return error.UnknownCommand; // only reachable as "user add"
        out = .{ .command = cmd };
        rest = args[1..];
    } else {
        return .{ .command = try flag(args[0]) };
    }

    const takes_config = out.command == .serve or out.command == .user_add;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (takes_config and std.mem.eql(u8, rest[i], "--config")) {
            i += 1;
            if (i >= rest.len) return error.MissingValue;
            out.config_path = rest[i];
        } else if (out.command == .user_add and std.mem.eql(u8, rest[i], "--role")) {
            i += 1;
            if (i >= rest.len) return error.MissingValue;
            out.role = std.meta.stringToEnum(auth.Role, rest[i]) orelse return error.InvalidRole;
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

test "user add" {
    const p = try parse(&.{ "user", "add", "alice", "--role", "viewer", "--config", "c.conf" });
    try std.testing.expectEqual(Command.user_add, p.command);
    try std.testing.expectEqualStrings("alice", p.user_name.?);
    try std.testing.expectEqual(auth.Role.viewer, p.role);
    try std.testing.expectEqualStrings("c.conf", p.config_path.?);
    try std.testing.expectError(error.MissingValue, parse(&.{ "user", "add" }));
    try std.testing.expectError(error.InvalidRole, parse(&.{ "user", "add", "a", "--role", "root" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "user", "del", "a" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{"user_add"}));
}

test "rejects garbage" {
    try std.testing.expectError(error.UnknownCommand, parse(&.{"frobnicate"}));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "version", "extra" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "help", "--config", "x" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "serve", "--role", "admin" }));
}
