//! Config file parsing. Format is `key = value`, `#` starts a comment.
//! Not TOML and not ZON on purpose: nobody should need a spec to edit a
//! five line file, and the error messages here carry the line number.
const std = @import("std");
const systemd = @import("integrations/systemd.zig");

pub const LogLevel = enum { err, warn, info, debug };

pub const Config = struct {
    /// Loopback by default. Binding wider is an explicit choice by the admin.
    listen: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    data_dir: []const u8 = "/var/lib/nodos",
    log_level: LogLevel = .info,
    /// Browsers drop Secure cookies on plain HTTP (localhost excepted). Turn
    /// this off only for a trusted-LAN setup without TLS.
    secure_cookies: bool = true,
    /// Docker Engine socket, or "off". Socket access is root-equivalent, so
    /// an admin who doesn't want NodOS to hold that power can switch it off.
    docker_socket: []const u8 = "/var/run/docker.sock",
    /// Address of a reverse proxy whose X-Forwarded-For header we believe.
    /// Empty (the default) means we trust no one, and the header is ignored.
    /// Only ever set this to a proxy you run: anyone else can forge the header
    /// and dodge the login throttle.
    trusted_proxy: []const u8 = "",
    /// systemd units NodOS may show and control, without ".service". Empty
    /// means the services feature is off. An allowlist, never a pattern.
    services: []const []const u8 = &.{},
    /// How often the sampler runs. Below 500 ms the CPU cost stops being funny.
    sample_interval_ms: u32 = 2000,
};

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const ParseError = error{ InvalidConfig, OutOfMemory };

/// Strings in the result are duped into `arena`. On InvalidConfig, `diag`
/// says which line and why.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: *Diagnostic) ParseError!Config {
    var cfg: Config = .{};
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.findScalar(u8, line, '=') orelse
            return fail(diag, line_no, "expected key = value");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len == 0) return fail(diag, line_no, "empty value");

        if (std.mem.eql(u8, key, "listen")) {
            // Validate now so a typo fails at startup, not at bind time.
            _ = std.Io.net.IpAddress.parse(value, 0) catch
                return fail(diag, line_no, "listen is not a valid IP address");
            cfg.listen = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "port")) {
            cfg.port = std.fmt.parseInt(u16, value, 10) catch
                return fail(diag, line_no, "port must be 0-65535");
        } else if (std.mem.eql(u8, key, "data_dir")) {
            cfg.data_dir = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "log_level")) {
            cfg.log_level = std.meta.stringToEnum(LogLevel, value) orelse
                return fail(diag, line_no, "log_level must be err, warn, info or debug");
        } else if (std.mem.eql(u8, key, "services")) {
            var list: std.ArrayList([]const u8) = .empty;
            var parts = std.mem.splitScalar(u8, value, ',');
            while (parts.next()) |p| {
                const name = std.mem.trim(u8, p, " \t");
                if (name.len == 0) continue;
                if (!systemd.validUnit(name)) return fail(diag, line_no, "services: invalid unit name (letters, digits, _ . - @ :, no leading dash)");
                if (list.items.len >= systemd.max_units) return fail(diag, line_no, "services: at most 32 units");
                try list.append(arena, try arena.dupe(u8, name));
            }
            cfg.services = list.items;
        } else if (std.mem.eql(u8, key, "trusted_proxy")) {
            _ = std.Io.net.IpAddress.parse(value, 0) catch
                return fail(diag, line_no, "trusted_proxy is not a valid IP address");
            cfg.trusted_proxy = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "docker_socket")) {
            cfg.docker_socket = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "secure_cookies")) {
            if (std.mem.eql(u8, value, "true")) {
                cfg.secure_cookies = true;
            } else if (std.mem.eql(u8, value, "false")) {
                cfg.secure_cookies = false;
            } else return fail(diag, line_no, "secure_cookies must be true or false");
        } else if (std.mem.eql(u8, key, "sample_interval_ms")) {
            const v = std.fmt.parseInt(u32, value, 10) catch
                return fail(diag, line_no, "sample_interval_ms must be a number");
            if (v < 500 or v > 60_000) return fail(diag, line_no, "sample_interval_ms must be 500-60000");
            cfg.sample_interval_ms = v;
        } else {
            return fail(diag, line_no, "unknown key");
        }
    }
    return cfg;
}

fn fail(diag: *Diagnostic, line: usize, message: []const u8) ParseError {
    diag.* = .{ .line = line, .message = message };
    return error.InvalidConfig;
}

test "defaults on empty input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const cfg = try parse(arena.allocator(), "# nothing\n\n", &d);
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.listen);
}

test "parses all keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const cfg = try parse(arena.allocator(),
        \\listen = 0.0.0.0
        \\port=9000
        \\data_dir = /tmp/nodos
        \\log_level = debug
        \\sample_interval_ms = 1000
        \\secure_cookies = false
        \\docker_socket = off
        \\
    , &d);
    try std.testing.expect(!cfg.secure_cookies);
    try std.testing.expectEqualStrings("off", cfg.docker_socket);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.listen);
    try std.testing.expectEqual(@as(u16, 9000), cfg.port);
    try std.testing.expectEqualStrings("/tmp/nodos", cfg.data_dir);
    try std.testing.expectEqual(LogLevel.debug, cfg.log_level);
    try std.testing.expectEqual(@as(u32, 1000), cfg.sample_interval_ms);
}

test "trusted_proxy must be an ip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const cfg = try parse(arena.allocator(), "trusted_proxy = 127.0.0.1\n", &d);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.trusted_proxy);
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "trusted_proxy = proxy.local", &d));
    try std.testing.expectEqualStrings("", (try parse(arena.allocator(), "", &d)).trusted_proxy);
}

test "services list parses and rejects option-looking names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const cfg = try parse(arena.allocator(), "services = ssh, nginx ,avahi-daemon,,\n", &d);
    try std.testing.expectEqual(@as(usize, 3), cfg.services.len);
    try std.testing.expectEqualStrings("nginx", cfg.services[1]);
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "services = ssh, --now", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "services = a b", &d));
    try std.testing.expectEqual(@as(usize, 0), (try parse(arena.allocator(), "", &d)).services.len);
}

test "errors carry line numbers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "port = 80\nport = 99999\n", &d));
    try std.testing.expectEqual(@as(usize, 2), d.line);
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "bogus = 1", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "listen = not-an-ip", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "sample_interval_ms = 5", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "no equals sign", &d));
}
