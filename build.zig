const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "asm2362-tool",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link libc for syscalls
    exe.linkLibC();

    // Platform-specific build configuration
    const target_os = target.result.os.tag;
    if (target_os == .linux) {
        exe.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    } else if (target_os == .macos) {
        exe.linkFramework("IOKit");
        exe.linkFramework("CoreFoundation");
    }

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the ASM2362 tool");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Platform abstraction tests
    const platform_tests = b.addTest(.{
        .root_source_file = b.path("src/platform/scsi.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_tests.linkLibC();

    // Legacy sg_io tests (Linux-specific, kept for backwards compatibility)
    const sg_io_tests = b.addTest(.{
        .root_source_file = b.path("src/scsi/sg_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    sg_io_tests.linkLibC();

    const sense_tests = b.addTest(.{
        .root_source_file = b.path("src/scsi/sense.zig"),
        .target = target,
        .optimize = optimize,
    });
    sense_tests.linkLibC();

    const passthrough_tests = b.addTest(.{
        .root_source_file = b.path("src/asm2362/passthrough.zig"),
        .target = target,
        .optimize = optimize,
    });
    passthrough_tests.linkLibC();

    const replay_tests = b.addTest(.{
        .root_source_file = b.path("src/frida/replay.zig"),
        .target = target,
        .optimize = optimize,
    });
    replay_tests.linkLibC();

    const xram_tests = b.addTest(.{
        .root_source_file = b.path("src/asm2362/xram.zig"),
        .target = target,
        .optimize = optimize,
    });
    xram_tests.linkLibC();

    const run_platform_tests = b.addRunArtifact(platform_tests);
    const run_sg_io_tests = b.addRunArtifact(sg_io_tests);
    const run_sense_tests = b.addRunArtifact(sense_tests);
    const run_passthrough_tests = b.addRunArtifact(passthrough_tests);
    const run_replay_tests = b.addRunArtifact(replay_tests);
    const run_xram_tests = b.addRunArtifact(xram_tests);

    const test_all_step = b.step("test-all", "Run all module tests");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(&run_platform_tests.step);
    test_all_step.dependOn(&run_sg_io_tests.step);
    test_all_step.dependOn(&run_sense_tests.step);
    test_all_step.dependOn(&run_passthrough_tests.step);
    test_all_step.dependOn(&run_replay_tests.step);
    test_all_step.dependOn(&run_xram_tests.step);
}
