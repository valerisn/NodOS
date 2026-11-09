//! NodOS library root. Everything the binary uses is re-exported from here
//! so the executable stays a thin CLI shell and the logic stays testable.
const std = @import("std");

pub const version: []const u8 = @import("build_options").version;

pub const cli = @import("cli.zig");

test {
    std.testing.refAllDecls(@This());
}

test "version is not empty" {
    try std.testing.expect(version.len > 0);
}
