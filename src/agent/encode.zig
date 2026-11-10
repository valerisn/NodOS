const std = @import("std");
const Io = std.Io;
const Stringify = std.json.Stringify;
const collect = @import("collect.zig");
const sampler = @import("sampler.zig");

const Error = Io.Writer.Error;

fn r1(x: f32) f64 {
    return @round(@as(f64, x) * 10.0) / 10.0;
}

pub fn writeSnapshot(w: *Io.Writer, s: *const collect.Snapshot) Error!void {
    var j: Stringify = .{ .writer = w };
    try j.beginObject();

    try j.objectField("ts");
    try j.write(s.ts_s);
    try j.objectField("hostname");
    try j.write(s.hostname.slice());
    try j.objectField("os");
    try j.write(s.os_name.slice());
    try j.objectField("kernel");
    try j.write(s.kernel.slice());
    try j.objectField("uptime_s");
    try j.write(@as(u64, @intFromFloat(s.uptime_s)));

    try j.objectField("load");
    try j.beginArray();
    try j.write(r1(s.load.one));
    try j.write(r1(s.load.five));
    try j.write(r1(s.load.fifteen));
    try j.endArray();

    try j.objectField("cpu");
    try j.beginObject();
    try j.objectField("percent");
    try j.write(r1(s.cpu_pct));
    try j.objectField("cores");
    try j.beginArray();
    for (s.core_pct[0..s.core_count]) |c| try j.write(r1(c));
    try j.endArray();
    try j.endObject();

    try j.objectField("memory");
    try j.beginObject();
    try j.objectField("total_kb");
    try j.write(s.mem.total_kb);
    try j.objectField("used_kb");
    try j.write(s.mem.usedKb());
    try j.objectField("available_kb");
    try j.write(s.mem.available_kb);
    try j.objectField("swap_total_kb");
    try j.write(s.mem.swap_total_kb);
    try j.objectField("swap_used_kb");
    try j.write(s.mem.swap_total_kb -| s.mem.swap_free_kb);
    try j.endObject();

    try j.objectField("network");
    try j.beginArray();
    for (s.ifaces[0..s.iface_count]) |i| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(i.name.slice());
        try j.objectField("rx_bytes");
        try j.write(i.rx_bytes);
        try j.objectField("tx_bytes");
        try j.write(i.tx_bytes);
        try j.objectField("rx_bps");
        try j.write(i.rx_bps);
        try j.objectField("tx_bps");
        try j.write(i.tx_bps);
        try j.objectField("rx_errors");
        try j.write(i.rx_errs);
        try j.objectField("tx_errors");
        try j.write(i.tx_errs);
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("storage");
    try j.beginArray();
    for (s.mounts[0..s.mount_count]) |m| {
        try j.beginObject();
        try j.objectField("device");
        try j.write(m.device.slice());
        try j.objectField("mount");
        try j.write(m.path.slice());
        try j.objectField("fstype");
        try j.write(m.fstype.slice());
        if (m.usage) |u| {
            try j.objectField("total_bytes");
            try j.write(u.total_bytes);
            try j.objectField("used_bytes");
            try j.write(u.total_bytes -| u.free_bytes);
            try j.objectField("avail_bytes");
            try j.write(u.avail_bytes);
        }
        try j.endObject();
    }
    try j.endArray();

    try j.objectField("temperatures");
    try j.beginArray();
    for (s.temps[0..s.temp_count]) |t| {
        try j.beginObject();
        try j.objectField("label");
        try j.write(t.label.slice());
        try j.objectField("celsius");
        try j.write(r1(t.celsius));
        try j.endObject();
    }
    try j.endArray();

    try j.endObject();
}

pub fn writeHistory(w: *Io.Writer, points: []const sampler.Point) Error!void {
    var j: Stringify = .{ .writer = w };
    try j.beginObject();
    inline for (.{ "ts", "cpu", "mem", "rx_bps", "tx_bps" }) |name| {
        try j.objectField(name);
        try j.beginArray();
        for (points) |p| {
            if (comptime std.mem.eql(u8, name, "ts")) try j.write(p.ts_s);
            if (comptime std.mem.eql(u8, name, "cpu")) try j.write(r1(p.cpu_pct));
            if (comptime std.mem.eql(u8, name, "mem")) try j.write(r1(p.mem_pct));
            if (comptime std.mem.eql(u8, name, "rx_bps")) try j.write(p.rx_bps);
            if (comptime std.mem.eql(u8, name, "tx_bps")) try j.write(p.tx_bps);
        }
        try j.endArray();
    }
    try j.endObject();
}

test "snapshot encodes to valid json with expected fields" {
    var snap: collect.Snapshot = .{ .ts_s = 123, .uptime_s = 99.9, .cpu_pct = 12.34 };
    snap.hostname.set("box\"quote");
    snap.core_count = 2;
    snap.core_pct[0] = 10;
    snap.core_pct[1] = 20.55;
    snap.mem = .{ .total_kb = 1000, .available_kb = 400, .swap_total_kb = 10, .swap_free_kb = 4 };
    snap.mount_count = 1;
    snap.mounts[0].path.set("/");
    snap.mounts[0].usage = .{ .total_bytes = 100, .free_bytes = 30, .avail_bytes = 20 };
    snap.mounts[1].path.set("/never");

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeSnapshot(&out.writer, &snap);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("box\"quote", root.get("hostname").?.string);
    try std.testing.expectEqual(@as(i64, 99), root.get("uptime_s").?.integer);
    try std.testing.expectEqual(@as(usize, 2), root.get("cpu").?.object.get("cores").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 600), root.get("memory").?.object.get("used_kb").?.integer);
    try std.testing.expectEqual(@as(i64, 6), root.get("memory").?.object.get("swap_used_kb").?.integer);
    const st = root.get("storage").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), st.len);
    try std.testing.expectEqual(@as(i64, 70), st[0].object.get("used_bytes").?.integer);
}

test "history encodes column arrays" {
    const pts = [_]sampler.Point{
        .{ .ts_s = 1, .cpu_pct = 10, .mem_pct = 20, .rx_bps = 5, .tx_bps = 6 },
        .{ .ts_s = 3, .cpu_pct = 30, .mem_pct = 40, .rx_bps = 7, .tx_bps = 8 },
    };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeHistory(&out.writer, &pts);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 2), o.get("ts").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 8), o.get("tx_bps").?.array.items[1].integer);
}

test "empty history is valid json" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeHistory(&out.writer, &.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("cpu").?.array.items.len);
}
