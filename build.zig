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

    // Link libc for ioctl syscalls
    exe.linkLibC();

    // Add C include paths for kernel headers
    exe.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });

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

    // Module tests for individual components
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

    const run_sg_io_tests = b.addRunArtifact(sg_io_tests);
    const run_sense_tests = b.addRunArtifact(sense_tests);
    const run_passthrough_tests = b.addRunArtifact(passthrough_tests);
    const run_replay_tests = b.addRunArtifact(replay_tests);
    const run_xram_tests = b.addRunArtifact(xram_tests);

    const test_all_step = b.step("test-all", "Run all module tests");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(&run_sg_io_tests.step);
    test_all_step.dependOn(&run_sense_tests.step);
    test_all_step.dependOn(&run_passthrough_tests.step);
    test_all_step.dependOn(&run_replay_tests.step);
    test_all_step.dependOn(&run_xram_tests.step);
}
