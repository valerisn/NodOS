//! Append-only audit log: one JSON object per line in `<data_dir>/audit.log`.
//! Records who did what and whether it worked. Never records secrets.
const std = @import("std");
const Io = std.Io;

pub const Event = struct {
    /// Unix seconds.
    ts: i64,
    /// Username, or "-" when nobody is authenticated (failed logins).
    actor: []const u8,
    /// Dotted action name, e.g. "auth.login", "docker.restart".
    action: []const u8,
    /// What it acted on; empty when not applicable.
    target: []const u8 = "",
    ok: bool,
    /// Peer address as text.
    ip: []const u8 = "",
};

/// Pure formatting so the escaping can be tested without touching disk.
/// std.json handles escaping, so a hostile username can't forge log lines.
pub fn format(w: *Io.Writer, ev: Event) Io.Writer.Error!void {
    std.json.Stringify.value(ev, .{}, w) catch return error.WriteFailed;
    try w.writeByte('\n');
}

pub const Log = struct {
    file: Io.File,
    mutex: Io.Mutex = .init,

    pub const file_name = "audit.log";

    pub fn open(io: Io, dir: Io.Dir) !Log {
        const f = try dir.createFile(io, file_name, .{ .truncate = false, .read = false });
        return .{ .file = f };
    }

    pub fn close(l: *Log, io: Io) void {
        l.file.close(io);
    }

    /// A failed audit write is logged loudly but does not take the server
    /// down. Revisit: for destructive actions we may want to fail closed.
    pub fn record(l: *Log, io: Io, ev: Event) void {
        var buf: [1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        format(&w, ev) catch {
            std.log.err("audit: event too large, dropped action={s}", .{ev.action});
            return;
        };
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        const end = l.file.length(io) catch |err| {
            std.log.err("audit: stat failed: {s}", .{@errorName(err)});
            return;
        };
        l.file.writePositionalAll(io, w.buffered(), end) catch |err| {
            std.log.err("audit: write failed: {s}", .{@errorName(err)});
        };
    }
};

test "format escapes hostile input" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try format(&w, .{ .ts = 42, .actor = "evil\"\n{\"ok\":true}", .action = "auth.login", .ok = false, .ip = "10.0.0.1" });
    const line = w.buffered();
    // exactly one newline, at the end
    try std.testing.expectEqual(line.len - 1, std.mem.findScalar(u8, line, '\n').?);
    try std.testing.expect(std.mem.find(u8, line, "\\n") != null);
    try std.testing.expect(std.mem.startsWith(u8, line, "{\"ts\":42,"));
}
