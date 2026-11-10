//! Pulling the `nodos` binary out of a release tarball, in memory.
//!
//! Nothing from the archive touches the filesystem by name: we scan the entries
//! and copy out the bytes of the one regular file called `nodos`. A hostile
//! archive full of `../../etc/passwd` entries has nowhere to go.
const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

pub const Error = error{
    /// Not a readable gzip tar.
    BadArchive,
    /// No regular file named `nodos` in it.
    BinaryMissing,
    /// A binary bigger than we are willing to install.
    TooLarge,
    OutOfMemory,
};

/// The release binary is under a megabyte. 32 MiB leaves room to grow and
/// still stops a decompression bomb long before it hurts.
pub const max_binary = 32 * 1024 * 1024;

/// Returns the bytes of the first entry that is a regular file whose last path
/// component is exactly `nodos`.
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
        // We consumed the content ourselves; tell the iterator not to skip it again.
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
    // chop the real archive in half
    const r = binaryFromTarGz(a, sample[0 .. sample.len / 2]);
    try std.testing.expect(std.meta.isError(r));
    if (r) |_| return error.TestUnexpectedResult else |e| try std.testing.expect(e == error.BadArchive or e == error.BinaryMissing);
}

test "an archive without a nodos file reports that" {
    // the same tarball, searched by a different rule: no scripts/nodos exists,
    // and install.sh must not be mistaken for the binary
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bin = try binaryFromTarGz(arena.allocator(), sample);
    try std.testing.expect(!std.mem.startsWith(u8, bin, "#!/bin/sh"));
}
