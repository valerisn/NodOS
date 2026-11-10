const std = @import("std");
const systemd = @import("integrations/systemd.zig");
const release = @import("update/release.zig");
const notify = @import("notify.zig");
const alerts = @import("alerts.zig");

pub const LogLevel = enum { err, warn, info, debug };

pub const Config = struct {
    listen: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    data_dir: []const u8 = "/var/lib/nodos",
    log_level: LogLevel = .info,
    secure_cookies: bool = true,
    docker_socket: []const u8 = "/var/run/docker.sock",
    trusted_proxy: []const u8 = "",
    services: []const []const u8 = &.{},
    // the only outbound connection nodos makes: a User-Agent and nothing else
    update_check: bool = true,
    update_mirror: []const u8 = "",
    webhook_url: []const u8 = "",
    alerts: alerts.Thresholds = .{},
    sample_interval_ms: u32 = 2000,
};

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const ParseError = error{ InvalidConfig, OutOfMemory };

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
        } else if (std.mem.eql(u8, key, "update_check")) {
            cfg.update_check = parseBool(value) orelse
                return fail(diag, line_no, "update_check must be true or false");
        } else if (std.mem.eql(u8, key, "update_mirror")) {
            if (!release.urlAllowed(value))
                return fail(diag, line_no, "update_mirror must be an https:// URL (http:// only for this machine)");
            cfg.update_mirror = try arena.dupe(u8, value);
        } else if (std.mem.startsWith(u8, key, "alert_")) {
            try parseAlertKey(&cfg.alerts, key["alert_".len..], value, diag, line_no);
        } else if (std.mem.eql(u8, key, "webhook_url")) {
            if (!notify.urlOk(value))
                return fail(diag, line_no, "webhook_url must be an http:// or https:// URL without spaces");
            cfg.webhook_url = try arena.dupe(u8, value);
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

/// What the Settings page shows. Anything that can carry a secret (the webhook
/// address, a mirror URL) is reduced to "is it set".
pub fn writeSettings(w: *std.Io.Writer, cfg: Config, version: []const u8) std.Io.Writer.Error!void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("version");
    try j.write(version);
    try j.objectField("listen");
    try j.write(cfg.listen);
    try j.objectField("port");
    try j.write(cfg.port);
    try j.objectField("data_dir");
    try j.write(cfg.data_dir);
    try j.objectField("log_level");
    try j.write(@tagName(cfg.log_level));
    try j.objectField("secure_cookies");
    try j.write(cfg.secure_cookies);
    try j.objectField("trusted_proxy");
    try j.write(cfg.trusted_proxy);
    try j.objectField("docker_socket");
    try j.write(cfg.docker_socket);
    try j.objectField("services");
    try j.write(cfg.services);
    try j.objectField("sample_interval_ms");
    try j.write(cfg.sample_interval_ms);
    try j.objectField("update_check");
    try j.write(cfg.update_check);
    try j.objectField("update_mirror_set");
    try j.write(cfg.update_mirror.len > 0);
    try j.objectField("webhook_set");
    try j.write(cfg.webhook_url.len > 0);
    try j.objectField("alerts");
    try j.beginObject();
    inline for (.{ "cpu_warn", "cpu_samples", "mem_warn", "mem_crit", "disk_warn", "disk_crit", "temp_warn", "temp_crit", "swap_warn" }) |name| {
        try j.objectField(name);
        try j.write(@field(cfg.alerts, name));
    }
    try j.endObject();
    try j.endObject();
}

fn parseAlertKey(t: *alerts.Thresholds, key: []const u8, value: []const u8, diag: *Diagnostic, line_no: usize) ParseError!void {
    if (std.mem.eql(u8, key, "cpu_samples")) {
        t.cpu_samples = std.fmt.parseInt(u8, value, 10) catch return fail(diag, line_no, "alert_cpu_samples must be a number from 1 to 60");
    } else {
        const v = std.fmt.parseFloat(f32, value) catch return fail(diag, line_no, "alert thresholds must be numbers");
        if (!std.math.isFinite(v)) return fail(diag, line_no, "alert thresholds must be numbers");
        if (std.mem.eql(u8, key, "cpu_warn")) t.cpu_warn = v else if (std.mem.eql(u8, key, "mem_warn")) t.mem_warn = v else if (std.mem.eql(u8, key, "mem_crit")) t.mem_crit = v else if (std.mem.eql(u8, key, "disk_warn")) t.disk_warn = v else if (std.mem.eql(u8, key, "disk_crit")) t.disk_crit = v else if (std.mem.eql(u8, key, "temp_warn")) t.temp_warn = v else if (std.mem.eql(u8, key, "temp_crit")) t.temp_crit = v else if (std.mem.eql(u8, key, "swap_warn")) t.swap_warn = v else return fail(diag, line_no, "unknown key");
    }
    if (!t.valid()) return fail(diag, line_no, "alert thresholds out of range (percentages 15-100, warn at or below crit, temperatures 10-150)");
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
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

test "update settings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const def = try parse(arena.allocator(), "", &d);
    try std.testing.expect(def.update_check);
    try std.testing.expectEqualStrings("", def.update_mirror);
    const c = try parse(arena.allocator(), "update_check = false\nupdate_mirror = https://mirror.example.lan/nodos\n", &d);
    try std.testing.expect(!c.update_check);
    try std.testing.expectEqualStrings("https://mirror.example.lan/nodos", c.update_mirror);
    _ = try parse(arena.allocator(), "update_mirror = http://127.0.0.1:8099", &d);
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "update_mirror = http://evil.example.com/x", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "update_check = maybe", &d));
}

test "alert thresholds are configurable and checked" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const def = try parse(arena.allocator(), "", &d);
    try std.testing.expectEqual(@as(f32, 85), def.alerts.disk_warn);
    const c = try parse(arena.allocator(), "alert_disk_warn = 70\nalert_disk_crit = 90\nalert_temp_warn = 65.5\nalert_cpu_samples = 3\n", &d);
    try std.testing.expectEqual(@as(f32, 70), c.alerts.disk_warn);
    try std.testing.expectEqual(@as(f32, 65.5), c.alerts.temp_warn);
    try std.testing.expectEqual(@as(u8, 3), c.alerts.cpu_samples);
    try std.testing.expectEqual(@as(f32, 67), c.alerts.diskClear());
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "alert_disk_warn = 99\n", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "alert_disk_warn = abc\n", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "alert_disk_warn = nan\n", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "alert_mem_warn = 5\n", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "alert_bogus = 5\n", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "alert_cpu_samples = 0\n", &d));
}

test "settings json hides secrets and parses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const cfg = try parse(arena.allocator(), "webhook_url = https://ntfy.sh/secret-topic\nupdate_mirror = https://m.example/secret\nservices = ssh, nginx\n", &d);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeSettings(&out.writer, cfg, "1.2.3");
    try std.testing.expect(std.mem.find(u8, out.written(), "secret") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expect(o.get("webhook_set").?.bool);
    try std.testing.expect(o.get("update_mirror_set").?.bool);
    try std.testing.expectEqual(@as(usize, 2), o.get("services").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 85), o.get("alerts").?.object.get("disk_warn").?.integer);
}

test "webhook_url" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try std.testing.expectEqualStrings("", (try parse(arena.allocator(), "", &d)).webhook_url);
    const c = try parse(arena.allocator(), "webhook_url = https://ntfy.sh/mytopic", &d);
    try std.testing.expectEqualStrings("https://ntfy.sh/mytopic", c.webhook_url);
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "webhook_url = ftp://x/y", &d));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "webhook_url = https://a b", &d));
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
