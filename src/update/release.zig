//! What a release looks like to the updater: the metadata GitHub (or a mirror)
//! returns for "latest", the names of the files we expect, and where to find
//! them. The metadata is untrusted input until the signature check passes, so
//! nothing here is believed beyond choosing which version to look at.
const std = @import("std");
const builtin = @import("builtin");
const Version = @import("version.zig").Version;

pub const default_owner = "valerisn";
pub const default_repo = "NodOS";

pub const Source = struct {
    /// URL that returns the latest release as JSON.
    meta_url: []const u8,
    /// Files live at `{assets_url}/{tag}/{file}`.
    assets_url: []const u8,

    pub const github: Source = .{
        .meta_url = "https://api.github.com/repos/" ++ default_owner ++ "/" ++ default_repo ++ "/releases/latest",
        .assets_url = "https://github.com/" ++ default_owner ++ "/" ++ default_repo ++ "/releases/download",
    };

    /// A mirror is a directory served over HTTP(S) holding `latest.json` and a
    /// `download/<tag>/` tree. Handy for air-gapped networks and for tests.
    pub fn mirror(arena: std.mem.Allocator, base: []const u8) !Source {
        const trimmed = std.mem.trimEnd(u8, base, "/");
        return .{
            .meta_url = try std.fmt.allocPrint(arena, "{s}/latest.json", .{trimmed}),
            .assets_url = try std.fmt.allocPrint(arena, "{s}/download", .{trimmed}),
        };
    }
};

pub const Release = struct {
    tag: []const u8,
    version: Version,
    prerelease: bool,
    /// Unix seconds, 0 when the metadata had no usable date.
    published_s: i64,
    page_url: []const u8,
};

const Raw = struct {
    tag_name: []const u8 = "",
    draft: bool = false,
    prerelease: bool = false,
    published_at: []const u8 = "",
    html_url: []const u8 = "",
};

pub const ParseError = error{ BadMetadata, Draft, OutOfMemory };

/// Strings are copied into `arena`.
pub fn parse(arena: std.mem.Allocator, json: []const u8) ParseError!Release {
    const raw = std.json.parseFromSliceLeaky(Raw, arena, json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadMetadata,
    };
    if (raw.draft) return error.Draft;
    const v = Version.parse(raw.tag_name) catch return error.BadMetadata;
    // The tag becomes part of a URL path, so it must be exactly "v" plus a
    // plain version: nothing that could climb out of the download directory.
    if (!validTag(raw.tag_name)) return error.BadMetadata;
    return .{
        .tag = try arena.dupe(u8, raw.tag_name),
        .version = .{ .major = v.major, .minor = v.minor, .patch = v.patch, .pre = try arena.dupe(u8, v.pre) },
        .prerelease = raw.prerelease or v.isPrerelease(),
        .published_s = parseTimestamp(raw.published_at) orelse 0,
        .page_url = try arena.dupe(u8, raw.html_url),
    };
}

fn validTag(tag: []const u8) bool {
    if (tag.len < 6 or tag.len > 40 or tag[0] != 'v') return false;
    for (tag[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '+')) return false;
    }
    return true;
}

pub const Arch = enum {
    x86_64,
    aarch64,

    pub fn current() ?Arch {
        return switch (builtin.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            else => null,
        };
    }
};

/// `nodos-v0.1.0-x86_64-linux.tar.gz`, matching what the release workflow builds.
pub fn tarballName(arena: std.mem.Allocator, tag: []const u8, arch: Arch) ![]const u8 {
    return std.fmt.allocPrint(arena, "nodos-{s}-{s}-linux.tar.gz", .{ tag, @tagName(arch) });
}

pub fn assetUrl(arena: std.mem.Allocator, src: Source, tag: []const u8, file: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ src.assets_url, tag, file });
}

/// "2026-11-09T05:00:01Z" to Unix seconds. Only the form GitHub emits.
pub fn parseTimestamp(s: []const u8) ?i64 {
    if (s.len != 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or se > 60) return null;
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se;
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's algorithm).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Whether a release is old enough for unattended installation. A new release
/// has to survive `soak_s` seconds in public first, which is the window in
/// which a broken one gets noticed and pulled. An unknown date never passes.
pub fn oldEnough(r: Release, now_s: i64, soak_s: i64) bool {
    if (r.published_s == 0) return false;
    return now_s - r.published_s >= soak_s;
}

/// Http is only acceptable to a machine talking to itself. Everything else
/// must be https, so a network attacker can't feed us a different "latest".
pub fn urlAllowed(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "https://")) return true;
    const rest = if (std.mem.startsWith(u8, url, "http://")) url["http://".len..] else return false;
    const host_end = std.mem.findAny(u8, rest, "/:?") orelse rest.len;
    const host = rest[0..host_end];
    if (rest.len > host_end and rest[0] == '[') return false;
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost");
}

// ---------------------------------------------------------------- tests

const github_fixture =
    \\{"url":"https://api.github.com/x","tag_name":"v0.2.0","name":"0.2.0","draft":false,
    \\"prerelease":false,"created_at":"2026-11-08T00:00:00Z","published_at":"2026-11-09T05:00:01Z",
    \\"html_url":"https://github.com/valerisn/NodOS/releases/tag/v0.2.0","body":"notes",
    \\"assets":[{"name":"SHA256SUMS","size":1}]}
;

test "release metadata parses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), github_fixture);
    try std.testing.expectEqualStrings("v0.2.0", r.tag);
    try std.testing.expectEqual(@as(u32, 2), r.version.minor);
    try std.testing.expect(!r.prerelease);
    try std.testing.expectEqual(@as(i64, 1794200401), r.published_s);
    try std.testing.expectEqualStrings("https://github.com/valerisn/NodOS/releases/tag/v0.2.0", r.page_url);
}

test "bad or hostile metadata is rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadMetadata, parse(a, "not json"));
    try std.testing.expectError(error.BadMetadata, parse(a, "{}"));
    try std.testing.expectError(error.BadMetadata, parse(a, "{\"tag_name\":\"latest\"}"));
    try std.testing.expectError(error.Draft, parse(a, "{\"tag_name\":\"v1.0.0\",\"draft\":true}"));
    // a tag that tries to leave the download directory
    try std.testing.expectError(error.BadMetadata, parse(a, "{\"tag_name\":\"v1.0.0/../../evil\"}"));
    try std.testing.expectError(error.BadMetadata, parse(a, "{\"tag_name\":\"v1.0.0?x=1\"}"));
    try std.testing.expectError(error.BadMetadata, parse(a, "{\"tag_name\":\"v1.0.0 \"}"));
    // a version-looking tag that isn't one
    try std.testing.expectError(error.BadMetadata, parse(a, "{\"tag_name\":\"v1.2\"}"));
}

test "prerelease flag or a prerelease tag both count" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try parse(a, "{\"tag_name\":\"v1.0.0\",\"prerelease\":true}")).prerelease);
    try std.testing.expect((try parse(a, "{\"tag_name\":\"v1.0.0-rc.1\"}")).prerelease);
    try std.testing.expect(!(try parse(a, "{\"tag_name\":\"v1.0.0\"}")).prerelease);
}

test "timestamps" {
    try std.testing.expectEqual(@as(?i64, 0), parseTimestamp("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 951782400), parseTimestamp("2000-02-29T00:00:00Z")); // leap day
    try std.testing.expectEqual(@as(?i64, 1700000000), parseTimestamp("2023-11-14T22:13:20Z"));
    try std.testing.expectEqual(@as(?i64, null), parseTimestamp(""));
    try std.testing.expectEqual(@as(?i64, null), parseTimestamp("2026-13-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, null), parseTimestamp("2026-11-09 05:00:01"));
    try std.testing.expectEqual(@as(?i64, null), parseTimestamp("2026-11-09T05:00:01+01:00"));
}

test "soak period: new releases wait, unknown dates never pass" {
    const day: i64 = 86400;
    var r: Release = .{ .tag = "v1.0.1", .version = try Version.parse("1.0.1"), .prerelease = false, .published_s = 1000 * day, .page_url = "" };
    try std.testing.expect(!oldEnough(r, 1000 * day + 1, 3 * day));
    try std.testing.expect(!oldEnough(r, 1003 * day - 1, 3 * day));
    try std.testing.expect(oldEnough(r, 1003 * day, 3 * day));
    r.published_s = 0;
    try std.testing.expect(!oldEnough(r, 99999 * day, 3 * day));
}

test "only https, or http to this machine" {
    try std.testing.expect(urlAllowed("https://api.github.com/repos/x/y/releases/latest"));
    try std.testing.expect(urlAllowed("http://127.0.0.1:8099/latest.json"));
    try std.testing.expect(urlAllowed("http://localhost/latest.json"));
    try std.testing.expect(!urlAllowed("http://example.com/latest.json"));
    try std.testing.expect(!urlAllowed("http://127.0.0.1.evil.com/x"));
    try std.testing.expect(!urlAllowed("http://localhost.evil.com/x"));
    try std.testing.expect(!urlAllowed("ftp://x/y"));
    try std.testing.expect(!urlAllowed("file:///etc/passwd"));
    try std.testing.expect(!urlAllowed(""));
    try std.testing.expect(!urlAllowed("//127.0.0.1/x"));
}

test "names and urls are built from the validated tag" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("nodos-v0.2.0-aarch64-linux.tar.gz", try tarballName(a, "v0.2.0", .aarch64));
    try std.testing.expectEqualStrings(
        "https://github.com/valerisn/NodOS/releases/download/v0.2.0/SHA256SUMS",
        try assetUrl(a, Source.github, "v0.2.0", "SHA256SUMS"),
    );
    const m = try Source.mirror(a, "http://127.0.0.1:8099/");
    try std.testing.expectEqualStrings("http://127.0.0.1:8099/latest.json", m.meta_url);
    try std.testing.expectEqualStrings("http://127.0.0.1:8099/download/v1.0.0/x", try assetUrl(a, m, "v1.0.0", "x"));
}
