const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single source of truth for the version is build.zig.zon. Don't hardcode
    // it anywhere else or the release workflow will lie to people.
    const opts = b.addOptions();
    // -Dbuild-version exists so CI can build a "newer" binary from the same
    // source and exercise the updater. Releases never set it.
    opts.addOption([]const u8, "version", b.option([]const u8, "build-version", "Override the compiled-in version (testing only)") orelse zon.version);
    // Dev only: synthetic host data so the dashboard can be built on a box
    // with no /proc. Defaults off; CI and release builds never set it.
    opts.addOption(bool, "fake_host", b.option(bool, "fake-host", "Serve synthetic host data (development only)") orelse false);

    // Release binaries drop debug info: on Linux that was most of the size.
    // Leave it off for local work so stack traces keep file and line numbers.
    const strip = b.option(bool, "strip", "Strip debug info from the binary");

    const mod = b.addModule("nodos", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    mod.addOptions("build_options", opts);

    const exe = b.addExecutable(.{
        .name = "nodos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "nodos", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    // Release signing helper. Separate from nodos, and only built on request.
    const sign_exe = b.addExecutable(.{
        .name = "release-sign",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/release_sign.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const sign_step = b.step("sign-tool", "Build the release signing helper");
    sign_step.dependOn(&b.addInstallArtifact(sign_exe, .{}).step);

    const run_step = b.step("run", "Run nodos");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = sign_exe.root_module })).step);

    // CI runs this. Locally, `zig fmt .` fixes whatever it complains about.
    const fmt_step = b.step("fmt", "Check source formatting");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{ b.path("src"), b.path("tools"), b.path("build.zig"), b.path("build.zig.zon") }, .check = true }).step);
}
