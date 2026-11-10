//! NodOS library root. Everything the binary uses is re-exported from here
//! so the executable stays a thin CLI shell and the logic stays testable.
const std = @import("std");

pub const version: []const u8 = @import("build_options").version;

pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const server = @import("server.zig");
pub const auth = @import("auth.zig");
pub const users = @import("users.zig");
pub const assets = @import("assets.zig");
pub const alerts = @import("alerts.zig");
pub const robustness = @import("robustness.zig");
pub const ratelimit = @import("ratelimit.zig");
pub const audit = @import("audit.zig");
pub const update = struct {
    pub const version = @import("update/version.zig");
};
pub const integrations = struct {
    pub const docker = @import("integrations/docker.zig");
    pub const systemd = @import("integrations/systemd.zig");
};
pub const agent = struct {
    pub const proc = @import("agent/proc.zig");
    pub const collect = @import("agent/collect.zig");
    pub const sampler = @import("agent/sampler.zig");
    pub const encode = @import("agent/encode.zig");
};

test {
    std.testing.refAllDecls(@This());
    // refAllDecls stops at the first level, and a silent zero-test module is
    // exactly how parsers rot.
    std.testing.refAllDecls(agent);
    std.testing.refAllDecls(integrations);
    std.testing.refAllDecls(update);
}

test "version is not empty" {
    try std.testing.expect(version.len > 0);
}
