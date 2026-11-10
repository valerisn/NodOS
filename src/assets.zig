const std = @import("std");

pub const Asset = struct {
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const html = "text/html; charset=utf-8";
const js = "text/javascript; charset=utf-8";
const css = "text/css; charset=utf-8";

pub const all = [_]Asset{
    .{ .path = "/", .content_type = html, .body = @embedFile("web/index.html") },
    .{ .path = "/static/app.css", .content_type = css, .body = @embedFile("web/app.css") },
    .{ .path = "/static/app.js", .content_type = js, .body = @embedFile("web/app.js") },
    .{ .path = "/static/api.js", .content_type = js, .body = @embedFile("web/api.js") },
    .{ .path = "/static/chart.js", .content_type = js, .body = @embedFile("web/chart.js") },
    .{ .path = "/static/format.js", .content_type = js, .body = @embedFile("web/format.js") },
    .{ .path = "/static/views.js", .content_type = js, .body = @embedFile("web/views.js") },
    .{ .path = "/static/favicon.svg", .content_type = "image/svg+xml", .body = @embedFile("web/favicon.svg") },
};

pub fn find(path: []const u8) ?Asset {
    for (all) |a| if (std.mem.eql(u8, a.path, path)) return a;
    return null;
}

test "index and scripts are embedded" {
    try std.testing.expect(std.mem.find(u8, find("/").?.body, "<title>NodOS</title>") != null);
    try std.testing.expect(find("/static/app.js") != null);
    try std.testing.expect(find("/static/nope.js") == null);
    try std.testing.expect(find("/etc/passwd") == null);
}

test "every module the app imports is served" {
    for (all) |a| {
        if (!std.mem.endsWith(u8, a.path, ".js")) continue;
        var it = std.mem.splitSequence(u8, a.body, "from \"./");
        _ = it.next();
        while (it.next()) |rest| {
            const end = std.mem.findScalar(u8, rest, '"').?;
            var want: [64]u8 = undefined;
            const p = try std.fmt.bufPrint(&want, "/static/{s}", .{rest[0..end]});
            try std.testing.expect(find(p) != null);
        }
    }
}
