const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

pub const Error = error{
    BadArchive,
    BinaryMissing,
    TooLarge,
    OutOfMemory,
};

// the real binary is under 1 MB, this just stops a decompression bomb
pub const max_binary = 32 * 1024 * 1024;

pub fn binaryFromTarGz(arena: std.mem.Allocator, tgz: []const u8) Error![]u8 {
    var in: Io.Reader = .fixed(tgz);
    var window: [flate.max_window_len]u8 = undefined;
    var gz: flate.Decompress = .init(&in, .gzip, &window);

    var name_buf: [512]u8 = undefined;
    var link_buf: [512]u8 = undefined;
    var it: std.tar.Iterator = .init(&gz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });

    while (it.next() catch return error.BadArchive) |entry| {
        if (entry.kind != .file) continue;
        const base = if (std.mem.findScalarLast(u8, entry.name, '/')) |s| entry.name[s + 1 ..] else entry.name;
        if (!std.mem.eql(u8, base, "nodos")) continue;
        if (entry.size == 0) return error.BadArchive;
        if (entry.size > max_binary) return error.TooLarge;
        const out = try arena.alloc(u8, @intCast(entry.size));
        it.reader.readSliceAll(out) catch return error.BadArchive;
        it.unread_file_bytes = 0;
        return out;
    }
    return error.BinaryMissing;
}

const sample = @embedFile("testdata/sample.tar.gz");

test "finds the binary in a release shaped tarball" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bin = try binaryFromTarGz(arena.allocator(), sample);
    try std.testing.expectEqualStrings("pretend this is an ELF binary\n", bin);
}

test "garbage and truncated archives fail cleanly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadArchive, binaryFromTarGz(a, ""));
    try std.testing.expectError(error.BadArchive, binaryFromTarGz(a, "this is not gzip at all"));
    const r = binaryFromTarGz(a, sample[0 .. sample.len / 2]);
    try std.testing.expect(std.meta.isError(r));
    if (r) |_| return error.TestUnexpectedResult else |e| try std.testing.expect(e == error.BadArchive or e == error.BinaryMissing);
}

test "an archive without a nodos file reports that" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bin = try binaryFromTarGz(arena.allocator(), sample);
    try std.testing.expect(!std.mem.startsWith(u8, bin, "#!/bin/sh"));
}
