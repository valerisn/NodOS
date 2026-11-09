const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single source of truth for the version is build.zig.zon. Don't hardcode
    // it anywhere else or the release workflow will lie to people.
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", zon.version);

    const mod = b.addModule("nodos", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", opts);

    const exe = b.addExecutable(.{
        .name = "nodos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nodos", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run nodos");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);

    // CI runs this. Locally, `zig fmt .` fixes whatever it complains about.
    const fmt_step = b.step("fmt", "Check source formatting");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon") }, .check = true }).step);
}
