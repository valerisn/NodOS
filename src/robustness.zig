const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const users = @import("users.zig");
const proc = @import("agent/proc.zig");
const docker = @import("integrations/docker.zig");
const systemd = @import("integrations/systemd.zig");
const audit = @import("audit.zig");
const server = @import("server.zig");
const cli = @import("cli.zig");

const iterations = 3000;

fn randomBytes(rng: std.Random, buf: []u8) []u8 {
    const len = rng.uintLessThan(usize, buf.len + 1);
    rng.bytes(buf[0..len]);
    return buf[0..len];
}

fn mutate(rng: std.Random, src: []const u8, out: []u8) []u8 {
    const n = @min(src.len, out.len);
    @memcpy(out[0..n], src[0..n]);
    var len = n;
    const edits = rng.uintLessThan(usize, 6) + 1;
    for (0..edits) |_| {
        if (len == 0) break;
        const at = rng.uintLessThan(usize, len);
        switch (rng.uintLessThan(u8, 5)) {
            0 => out[at] = rng.int(u8),
            1 => len = at,
            2 => {
                std.mem.copyForwards(u8, out[at .. len - 1], out[at + 1 .. len]);
                len -= 1;
            },
            3 => if (len < out.len) {
                std.mem.copyBackwards(u8, out[at + 1 .. len + 1], out[at..len]);
                len += 1;
            },
            else => out[at] = "\n:= \t\"{}[],\\\r\x00"[rng.uintLessThan(usize, 13)],
        }
    }
    return out[0..len];
}

fn prng(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

test "the fixtures are valid and the mutations really reach both outcomes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    const valid = "listen = 0.0.0.0\nport = 9000\nservices = ssh, nginx\ntrusted_proxy = 127.0.0.1\nsecure_cookies = false\n";
    _ = try config.parse(arena.allocator(), valid, &diag);
    _ = try proc.parseCpuStat("cpu  4705 150 1120 16250 520 30 45 0 0 0\ncpu0 1200 40 300 4000 100 10 20 0 0 0\n");
    _ = try proc.parseNetDev("a\nb\n  eth0: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16\n");
    _ = try docker.parseResponse(arena.allocator(), "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");

    var p = prng(99);
    const rng = p.random();
    var buf: [512]u8 = undefined;
    var accepted: usize = 0;
    var rejected: usize = 0;
    for (0..2000) |_| {
        var a2: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer a2.deinit();
        const input = mutate(rng, valid, &buf);
        if (config.parse(a2.allocator(), input, &diag)) |_| accepted += 1 else |_| rejected += 1;
    }
    try std.testing.expect(accepted > 50);
    try std.testing.expect(rejected > 50);
}

test "config parser survives garbage" {
    var p = prng(1);
    const rng = p.random();
    var buf: [512]u8 = undefined;
    const valid = "listen = 0.0.0.0\nport = 9000\nservices = ssh, nginx\ntrusted_proxy = 127.0.0.1\nsecure_cookies = false\n";
    for (0..iterations) |i| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diag: config.Diagnostic = .{};
        const input = if (i % 2 == 0) randomBytes(rng, &buf) else mutate(rng, valid, &buf);
        _ = config.parse(arena.allocator(), input, &diag) catch {};
    }
}

test "users file parser survives garbage" {
    var p = prng(2);
    const rng = p.random();
    var buf: [512]u8 = undefined;
    const valid = "1:alice:admin:$argon2id$v=19$m=19456,t=2,p=1$abc$def\n2:bob:viewer:$argon2id$x\n";
    for (0..iterations) |i| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const input = if (i % 2 == 0) randomBytes(rng, &buf) else mutate(rng, valid, &buf);
        _ = users.parse(arena.allocator(), input) catch {};
    }
}

test "proc parsers survive garbage" {
    var p = prng(3);
    const rng = p.random();
    var buf: [1024]u8 = undefined;
    const stat = "cpu  4705 150 1120 16250 520 30 45 0 0 0\ncpu0 1200 40 300 4000 100 10 20 0 0 0\ncpu1 1150 30 280 4100 130 5 10 0 0 0\n";
    const mem = "MemTotal: 16318244 kB\nMemFree: 1234567 kB\nMemAvailable: 9876543 kB\nSwapTotal: 2097148 kB\nSwapFree: 2097000 kB\n";
    const net = "Inter-|   Receive\n face |bytes\n    lo:  100000     500    0    0    0     0          0         0   100000     500    0    0    0     0       0          0\n  eth0: 98765432  123456    2    1    0     0          0       100 12345678   65432    3    0    0     0       0          0\n";
    const mounts = "/dev/nvme0n1p2 / ext4 rw 0 0\n/dev/sda1 /mnt/big\\040drive xfs rw 0 0\nproc /proc proc rw 0 0\n";
    for (0..iterations) |i| {
        const noise = i % 3 == 0;
        if (proc.parseCpuStat(if (noise) randomBytes(rng, &buf) else mutate(rng, stat, &buf))) |s| {
            _ = proc.cpuPercent(s.all, s.all);
            _ = proc.cpuPercent(.{}, s.all);
        } else |_| {}
        if (proc.parseMeminfo(if (noise) randomBytes(rng, &buf) else mutate(rng, mem, &buf))) |m| {
            _ = m.usedKb();
        } else |_| {}
        if (proc.parseNetDev(if (noise) randomBytes(rng, &buf) else mutate(rng, net, &buf))) |n| {
            _ = n.find("eth0");
        } else |_| {}
        _ = proc.parseMounts(if (noise) randomBytes(rng, &buf) else mutate(rng, mounts, &buf)) catch {};
        _ = proc.parseUptime(randomBytes(rng, &buf)) catch {};
        _ = proc.parseLoadavg(randomBytes(rng, &buf)) catch {};
        _ = proc.parseMilliCelsius(randomBytes(rng, &buf)) catch {};
    }
}

test "docker response and payload parsers survive garbage" {
    var p = prng(4);
    const rng = p.random();
    var buf: [1024]u8 = undefined;
    const resp = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    const list = "[{\"Id\":\"3f4a9c1d2b7e8a00\",\"Names\":[\"/web\"],\"Image\":\"nginx\",\"State\":\"running\",\"Status\":\"Up\",\"Created\":1}]";
    const frames = "\x01\x00\x00\x00\x00\x00\x00\x06hello\n\x02\x00\x00\x00\x00\x00\x00\x05oops\n";
    for (0..iterations) |i| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const noise = i % 3 == 0;
        _ = docker.parseResponse(a, if (noise) randomBytes(rng, &buf) else mutate(rng, resp, &buf)) catch {};
        _ = docker.parseContainers(a, if (noise) randomBytes(rng, &buf) else mutate(rng, list, &buf)) catch {};
        if (docker.demuxLogs(a, if (noise) randomBytes(rng, &buf) else mutate(rng, frames, &buf))) |text| {
            var out: [512]u8 = undefined;
            var w: Io.Writer = .fixed(&out);
            docker.writeLogs(a, &w, text, 50) catch {};
        } else |_| {}
        _ = docker.validRef(randomBytes(rng, &buf));
    }
}

test "systemd output parser survives garbage" {
    var p = prng(5);
    const rng = p.random();
    var buf: [1024]u8 = undefined;
    const valid = "Description=OpenBSD Secure Shell server\nLoadState=loaded\nActiveState=active\nSubState=running\nMainPID=812\n\nDescription=x\nActiveState=failed\n\n";
    const units = [_][]const u8{ "ssh", "nginx", "cron" };
    for (0..iterations) |i| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const input = if (i % 3 == 0) randomBytes(rng, &buf) else mutate(rng, valid, &buf);
        _ = systemd.parseShow(arena.allocator(), &units, input) catch {};
        _ = systemd.validUnit(randomBytes(rng, &buf));
    }
}

test "request-side helpers survive garbage" {
    var p = prng(6);
    const rng = p.random();
    var buf: [512]u8 = undefined;
    for (0..iterations) |_| {
        const junk = randomBytes(rng, &buf);
        _ = server.cookieValue(junk, "nodos_session");
        _ = server.cookieValue(mutate(rng, "a=1; nodos_session=abc; b=2", &buf), "nodos_session");
        _ = server.rightmostForwarded(randomBytes(rng, &buf));
        _ = server.rightmostForwarded(mutate(rng, "9.9.9.9, 203.0.113.7", &buf));
    }
}

test "audit tail rendering survives garbage" {
    var p = prng(7);
    const rng = p.random();
    var buf: [1024]u8 = undefined;
    var out: [256]u8 = undefined;
    const valid = "{\"ts\":1,\"actor\":\"a\",\"action\":\"x\",\"target\":\"\",\"ok\":true,\"ip\":\"\"}\n{\"ts\":2}\n";
    for (0..iterations) |i| {
        var w: Io.Writer = .fixed(&out);
        const input = if (i % 2 == 0) randomBytes(rng, &buf) else mutate(rng, valid, &buf);
        audit.writeEntries(&w, input, rng.boolean(), rng.uintLessThan(usize, 300)) catch {};
    }
}

test "login bodies of every shape are handled" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var app = try server.testApp(arena.allocator());
    defer app.deinit(io);
    var p = prng(8);
    const rng = p.random();
    var buf: [700]u8 = undefined;
    const valid = "{\"username\":\"alice\",\"password\":\"not the right one\"}";
    for (0..400) |i| {
        var s: server.Scratch = .{};
        var ctx = server.testCtx(.POST, "/api/v1/login");
        ctx.client = @splat(0);
        std.mem.writeInt(u32, ctx.client[0..4], @intCast(i), .little);
        const body = if (i % 3 == 0) randomBytes(rng, &buf) else mutate(rng, valid, &buf);
        const r = server.dispatch(&app, io, ctx, body, &s);
        try std.testing.expect(@backingInt(r.status) >= 200 and @backingInt(r.status) < 500);
    }
}

test "cli parser survives odd argument lists" {
    var p = prng(9);
    const rng = p.random();
    const words = [_][]const u8{ "serve", "user", "add", "passwd", "remove", "list", "--config", "--role", "admin", "viewer", "x", "", "--", "-h", "version", "help", "\n", "--config=x" };
    var args: [6][]const u8 = undefined;
    for (0..iterations) |_| {
        const n = rng.uintLessThan(usize, args.len + 1);
        for (args[0..n]) |*a| a.* = words[rng.uintLessThan(usize, words.len)];
        _ = cli.parse(args[0..n]) catch {};
    }
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    const n: usize = smith.slice(&buf);
    const input = buf[0..n];
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    _ = config.parse(arena.allocator(), input, &diag) catch {};
    _ = proc.parseCpuStat(input) catch {};
    _ = proc.parseNetDev(input) catch {};
    _ = docker.parseResponse(arena.allocator(), input) catch {};
    _ = systemd.parseShow(arena.allocator(), &.{ "a", "b" }, input) catch {};
    _ = server.cookieValue(input, "nodos_session");
}

test "fuzz entry point for zig build test --fuzz" {
    try std.testing.fuzz({}, fuzzOne, .{});
}
