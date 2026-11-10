const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: []const u8 = "",

    pub const ParseError = error{InvalidVersion};

    pub fn parse(text: []const u8) ParseError!Version {
        var s = text;
        if (s.len > 0 and s[0] == 'v') s = s[1..];
        if (std.mem.findScalar(u8, s, '+')) |plus| s = s[0..plus];
        var pre: []const u8 = "";
        if (std.mem.findScalar(u8, s, '-')) |dash| {
            pre = s[dash + 1 ..];
            s = s[0..dash];
            if (pre.len == 0) return error.InvalidVersion;
        }
        var it = std.mem.splitScalar(u8, s, '.');
        const major = try num(it.next());
        const minor = try num(it.next());
        const patch = try num(it.next());
        if (it.next() != null) return error.InvalidVersion;
        return .{ .major = major, .minor = minor, .patch = patch, .pre = pre };
    }

    fn num(part: ?[]const u8) ParseError!u32 {
        const p = part orelse return error.InvalidVersion;
        if (p.len == 0 or p.len > 9) return error.InvalidVersion;
        if (p.len > 1 and p[0] == '0') return error.InvalidVersion;
        return std.fmt.parseInt(u32, p, 10) catch error.InvalidVersion;
    }

    pub fn isPrerelease(v: Version) bool {
        return v.pre.len > 0;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        const core = std.math.order(a.major, b.major).differ() orelse
            std.math.order(a.minor, b.minor).differ() orelse
            std.math.order(a.patch, b.patch).differ();
        if (core) |c| return c;
        if (a.pre.len == 0 and b.pre.len == 0) return .eq;
        if (a.pre.len == 0) return .gt;
        if (b.pre.len == 0) return .lt;
        return comparePre(a.pre, b.pre);
    }

    pub fn newerThan(a: Version, b: Version) bool {
        return a.order(b) == .gt;
    }

    pub fn format(v: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
        if (v.pre.len > 0) try w.print("-{s}", .{v.pre});
    }
};

fn comparePre(a: []const u8, b: []const u8) std.math.Order {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null and y == null) return .eq;
        if (x == null) return .lt;
        if (y == null) return .gt;
        const nx = std.fmt.parseInt(u64, x.?, 10) catch null;
        const ny = std.fmt.parseInt(u64, y.?, 10) catch null;
        const o: std.math.Order = if (nx != null and ny != null)
            std.math.order(nx.?, ny.?)
        else if (nx != null)
            .lt
        else if (ny != null)
            .gt
        else
            std.mem.order(u8, x.?, y.?);
        if (o != .eq) return o;
    }
}

pub fn autoAllowed(current: Version, candidate: Version) bool {
    if (!candidate.newerThan(current)) return false;
    if (candidate.isPrerelease()) return false;
    return candidate.major == current.major and candidate.minor == current.minor;
}

test "parse accepts the shapes we use" {
    const a = try Version.parse("v1.2.3");
    try std.testing.expectEqual(@as(u32, 1), a.major);
    try std.testing.expectEqual(@as(u32, 3), a.patch);
    try std.testing.expect(!a.isPrerelease());
    const b = try Version.parse("0.0.1-dev");
    try std.testing.expect(b.isPrerelease());
    try std.testing.expectEqualStrings("dev", b.pre);
    const c = try Version.parse("2.0.0-rc.1+build5");
    try std.testing.expectEqualStrings("rc.1", c.pre);
}

test "parse rejects junk" {
    for ([_][]const u8{ "", "v", "1", "1.2", "1.2.3.4", "1.2.x", "01.2.3", "1.2.3-", "1..3", "a.b.c", "-1.2.3", "1.2.3 ", "99999999999.0.0" }) |bad| {
        try std.testing.expectError(error.InvalidVersion, Version.parse(bad));
    }
}

test "ordering follows semver" {
    const v = Version.parse;
    try std.testing.expect((try v("1.0.1")).newerThan(try v("1.0.0")));
    try std.testing.expect((try v("1.1.0")).newerThan(try v("1.0.9")));
    try std.testing.expect((try v("2.0.0")).newerThan(try v("1.99.99")));
    try std.testing.expect(!(try v("1.0.0")).newerThan(try v("1.0.0")));
    try std.testing.expect((try v("1.10.0")).newerThan(try v("1.9.0")));
    try std.testing.expect((try v("1.0.0")).newerThan(try v("1.0.0-rc.1")));
    try std.testing.expect(!(try v("1.0.0-rc.1")).newerThan(try v("1.0.0")));
    const chain = [_][]const u8{ "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0" };
    for (chain[0 .. chain.len - 1], chain[1..]) |lo, hi| {
        try std.testing.expect((try v(hi)).newerThan(try v(lo)));
        try std.testing.expect(!(try v(lo)).newerThan(try v(hi)));
    }
    try std.testing.expect((try v("0.0.1")).newerThan(try v("0.0.1-dev")));
}

test "auto update only takes patch releases of the same minor" {
    const v = Version.parse;
    try std.testing.expect(autoAllowed(try v("0.1.0"), try v("0.1.1")));
    try std.testing.expect(autoAllowed(try v("1.4.2"), try v("1.4.9")));
    try std.testing.expect(!autoAllowed(try v("0.1.0"), try v("0.2.0")));
    try std.testing.expect(!autoAllowed(try v("1.4.2"), try v("1.5.0")));
    try std.testing.expect(!autoAllowed(try v("1.4.2"), try v("2.0.0")));
    try std.testing.expect(!autoAllowed(try v("1.4.2"), try v("1.4.1")));
    try std.testing.expect(!autoAllowed(try v("1.4.2"), try v("1.4.2")));
    try std.testing.expect(!autoAllowed(try v("1.4.2"), try v("1.4.3-rc.1")));
    try std.testing.expect(!autoAllowed(try v("0.0.1-dev"), try v("0.1.0")));
}

test "formatting round trips" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (try Version.parse("v3.1.4-rc.2")).format(&w);
    try std.testing.expectEqualStrings("3.1.4-rc.2", w.buffered());
}
