//! Argument parsing. Deliberately tiny: a handful of commands do not justify
//! a parsing library, and we are not adding a dependency for it.
const std = @import("std");
const auth = @import("auth.zig");

pub const Command = enum {
    help,
    version,
    serve,
    user_add,
    user_passwd,
    user_remove,
    user_list,
};

pub const Parsed = struct {
    command: Command,
    config_path: ?[]const u8 = null,
    /// user add, passwd, remove
    user_name: ?[]const u8 = null,
    /// user add only
    role: auth.Role = .admin,
};

pub const ParseError = error{
    UnknownCommand,
    UnexpectedArgument,
    MissingValue,
    InvalidRole,
};

const top_level = [_]struct { name: []const u8, cmd: Command }{
    .{ .name = "help", .cmd = .help },
    .{ .name = "version", .cmd = .version },
    .{ .name = "serve", .cmd = .serve },
};

const user_sub = [_]struct { name: []const u8, cmd: Command, takes_name: bool }{
    .{ .name = "add", .cmd = .user_add, .takes_name = true },
    .{ .name = "passwd", .cmd = .user_passwd, .takes_name = true },
    .{ .name = "remove", .cmd = .user_remove, .takes_name = true },
    .{ .name = "list", .cmd = .user_list, .takes_name = false },
};

/// `args` is argv without the program name. No args means help, because a
/// server tool that silently does something on bare invocation is a footgun.
pub fn parse(args: []const []const u8) ParseError!Parsed {
    if (args.len == 0) return .{ .command = .help };

    var out: Parsed = undefined;
    var rest: []const []const u8 = undefined;

    if (std.mem.eql(u8, args[0], "user")) {
        if (args.len < 2) return error.UnknownCommand;
        const sub = for (user_sub) |s| {
            if (std.mem.eql(u8, s.name, args[1])) break s;
        } else return error.UnknownCommand;
        out = .{ .command = sub.cmd };
        if (sub.takes_name) {
            if (args.len < 3) return error.MissingValue;
            out.user_name = args[2];
            rest = args[3..];
        } else rest = args[2..];
    } else if (for (top_level) |t| {
        if (std.mem.eql(u8, t.name, args[0])) break t;
    } else null) |t| {
        out = .{ .command = t.cmd };
        rest = args[1..];
    } else {
        return .{ .command = try flag(args[0]) };
    }

    const takes_config = out.command != .help and out.command != .version;
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
    try std.testing.expectError(error.UnknownCommand, parse(&.{"user"}));
    try std.testing.expectError(error.UnknownCommand, parse(&.{"user_add"}));
}

test "user passwd, remove and list" {
    const pw = try parse(&.{ "user", "passwd", "alice", "--config", "c.conf" });
    try std.testing.expectEqual(Command.user_passwd, pw.command);
    try std.testing.expectEqualStrings("alice", pw.user_name.?);
    const rm = try parse(&.{ "user", "remove", "bob" });
    try std.testing.expectEqual(Command.user_remove, rm.command);
    const ls = try parse(&.{ "user", "list", "--config", "c.conf" });
    try std.testing.expectEqual(Command.user_list, ls.command);
    try std.testing.expect(ls.user_name == null);
    // --role only means something for add
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "user", "passwd", "a", "--role", "admin" }));
    // list takes no name
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "user", "list", "alice" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "user", "remove" }));
}

test "rejects garbage" {
    try std.testing.expectError(error.UnknownCommand, parse(&.{"frobnicate"}));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "version", "extra" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "help", "--config", "x" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "serve", "--role", "admin" }));
}
