const std = @import("std");
const auth = @import("auth.zig");
const updater = @import("update/updater.zig");

pub const Command = enum {
    help,
    version,
    serve,
    update,
    user_add,
    user_passwd,
    user_remove,
    user_list,
};

pub const Parsed = struct {
    command: Command,
    config_path: ?[]const u8 = null,
    user_name: ?[]const u8 = null,
    role: auth.Role = .admin,
    update: updater.Options = .{},
};

pub const ParseError = error{
    UnknownCommand,
    UnexpectedArgument,
    MissingValue,
    InvalidRole,
    InvalidNumber,
    ConflictingOptions,
};

const top_level = [_]struct { name: []const u8, cmd: Command }{
    .{ .name = "help", .cmd = .help },
    .{ .name = "version", .cmd = .version },
    .{ .name = "serve", .cmd = .serve },
    .{ .name = "update", .cmd = .update },
};

const user_sub = [_]struct { name: []const u8, cmd: Command, takes_name: bool }{
    .{ .name = "add", .cmd = .user_add, .takes_name = true },
    .{ .name = "passwd", .cmd = .user_passwd, .takes_name = true },
    .{ .name = "remove", .cmd = .user_remove, .takes_name = true },
    .{ .name = "list", .cmd = .user_list, .takes_name = false },
};

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

    if (out.command == .update) {
        out.update = try parseUpdateFlags(rest);
        out.config_path = out.update.config_path;
        return out;
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

fn parseUpdateFlags(rest: []const []const u8) ParseError!updater.Options {
    var o: updater.Options = .{};
    var mode_set = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--check")) {
            if (mode_set) return error.ConflictingOptions;
            mode_set = true;
            o.mode = .check;
        } else if (std.mem.eql(u8, a, "--rollback")) {
            if (mode_set) return error.ConflictingOptions;
            mode_set = true;
            o.mode = .rollback;
        } else if (std.mem.eql(u8, a, "--auto-run")) {
            if (mode_set) return error.ConflictingOptions;
            mode_set = true;
            o.mode = .auto_run;
        } else if (std.mem.eql(u8, a, "--auto")) {
            if (mode_set) return error.ConflictingOptions;
            mode_set = true;
            i += 1;
            if (i >= rest.len) return error.MissingValue;
            o.mode = if (std.mem.eql(u8, rest[i], "on")) .auto_on else if (std.mem.eql(u8, rest[i], "off")) .auto_off else if (std.mem.eql(u8, rest[i], "status")) .auto_status else return error.UnexpectedArgument;
        } else if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) {
            o.yes = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            o.force = true;
        } else if (std.mem.eql(u8, a, "--mirror")) {
            i += 1;
            if (i >= rest.len) return error.MissingValue;
            o.mirror = rest[i];
        } else if (std.mem.eql(u8, a, "--pubkey")) {
            i += 1;
            if (i >= rest.len) return error.MissingValue;
            o.pubkey = rest[i];
        } else if (std.mem.eql(u8, a, "--binary")) {
            i += 1;
            if (i >= rest.len) return error.MissingValue;
            o.binary = rest[i];
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= rest.len) return error.MissingValue;
            o.config_path = rest[i];
        } else if (std.mem.eql(u8, a, "--soak-days")) {
            i += 1;
            if (i >= rest.len) return error.MissingValue;
            o.soak_days = std.fmt.parseInt(u32, rest[i], 10) catch return error.InvalidNumber;
            if (o.soak_days > 365) return error.InvalidNumber;
        } else return error.UnexpectedArgument;
    }
    return o;
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
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "user", "passwd", "a", "--role", "admin" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "user", "list", "alice" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "user", "remove" }));
}

test "update flags" {
    const plain = try parse(&.{"update"});
    try std.testing.expectEqual(Command.update, plain.command);
    try std.testing.expectEqual(updater.Mode.apply, plain.update.mode);

    const check = try parse(&.{ "update", "--check" });
    try std.testing.expectEqual(updater.Mode.check, check.update.mode);

    const rb = try parse(&.{ "update", "--rollback", "--binary", "/opt/nodos" });
    try std.testing.expectEqual(updater.Mode.rollback, rb.update.mode);
    try std.testing.expectEqualStrings("/opt/nodos", rb.update.binary.?);

    const on = try parse(&.{ "update", "--auto", "on", "--yes" });
    try std.testing.expectEqual(updater.Mode.auto_on, on.update.mode);
    try std.testing.expect(on.update.yes);
    try std.testing.expectEqual(updater.Mode.auto_off, (try parse(&.{ "update", "--auto", "off" })).update.mode);
    try std.testing.expectEqual(updater.Mode.auto_status, (try parse(&.{ "update", "--auto", "status" })).update.mode);

    const m = try parse(&.{ "update", "--mirror", "http://127.0.0.1:1", "--pubkey", "ab", "--config", "c.conf", "--soak-days", "7", "--force" });
    try std.testing.expectEqualStrings("http://127.0.0.1:1", m.update.mirror.?);
    try std.testing.expectEqualStrings("c.conf", m.config_path.?);
    try std.testing.expectEqual(@as(u32, 7), m.update.soak_days);
    try std.testing.expect(m.update.force);

    try std.testing.expectError(error.ConflictingOptions, parse(&.{ "update", "--check", "--rollback" }));
    try std.testing.expectError(error.ConflictingOptions, parse(&.{ "update", "--auto", "on", "--check" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "update", "--auto", "maybe" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "update", "now" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "update", "--mirror" }));
    try std.testing.expectError(error.InvalidNumber, parse(&.{ "update", "--soak-days", "many" }));
    try std.testing.expectError(error.InvalidNumber, parse(&.{ "update", "--soak-days", "9999" }));
}

test "rejects garbage" {
    try std.testing.expectError(error.UnknownCommand, parse(&.{"frobnicate"}));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "version", "extra" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "help", "--config", "x" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "serve", "--role", "admin" }));
}
