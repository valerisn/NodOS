//! NodOS library root. Everything the binary uses is re-exported from here
//! so the executable stays a thin CLI shell and the logic stays testable.
const std = @import("std");

pub const version: []const u8 = @import("build_options").version;

pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const server = @import("server.zig");
pub const auth = @import("auth.zig");
pub const users = @import("users.zig");
pub const ratelimit = @import("ratelimit.zig");
pub const audit = @import("audit.zig");

test {
    std.testing.refAllDecls(@This());
}

test "version is not empty" {
    try std.testing.expect(version.len > 0);
}
