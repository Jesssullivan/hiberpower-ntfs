//! NVMe Sanitize Command Implementation
//!
//! WARNING: This command is DESTRUCTIVE and will permanently erase all data.
//! Sanitize is more thorough than Format as it erases over-provisioned areas.

const std = @import("std");
const passthrough = @import("../asm2362/passthrough.zig");
const sg_io = @import("../scsi/sg_io.zig");

/// Sanitize Action values (SANACT)
pub const SanitizeAction = enum(u3) {
    /// Reserved
    reserved = 0,
    /// Exit Failure Mode
    exit_failure_mode = 1,
    /// Block Erase: NAND block erase all user data
    block_erase = 2,
    /// Overwrite: Pattern-based overwrite (not recommended for NAND)
    overwrite = 3,
    /// Crypto Erase: Destroy encryption key (fastest)
    crypto_erase = 4,
};

/// Execute NVMe Sanitize command
pub fn sanitize(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    action: SanitizeAction,
) !void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  WARNING: SANITIZE - PERMANENT DATA DESTRUCTION              ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Device: {s:52} ║\n", .{device_path});
    std.debug.print("║  Action: {s:52} ║\n", .{getActionDescription(action)});
    std.debug.print("║                                                              ║\n", .{});
    std.debug.print("║  Sanitize is MORE DESTRUCTIVE than Format:                   ║\n", .{});
    std.debug.print("║  - Erases ALL data including over-provisioned areas          ║\n", .{});
    std.debug.print("║  - Clears all internal caches                                ║\n", .{});
    std.debug.print("║  - Cannot be interrupted once started                        ║\n", .{});
    std.debug.print("║  - Resumes automatically after power loss                    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Build Sanitize CDB
    const cdb = passthrough.buildSanitizeCdb(@intFromEnum(action));

    std.debug.print("Sending Sanitize command (action={d})...\n", .{@intFromEnum(action)});

    const result = passthrough.execute(
        allocator,
        device_path,
        &cdb,
        0, // No data transfer
        .none,
        600000, // 10 minute timeout (sanitize can be slow)
    ) catch |err| {
        std.debug.print("Sanitize command failed: {s}\n", .{@errorName(err)});

        switch (err) {
            passthrough.PassthroughError.MediumNotPresent => {
                std.debug.print("\nThe drive reports 'Medium not present'.\n", .{});
                std.debug.print("Sanitize command cannot be executed in this state.\n", .{});
                std.debug.print("\nThis is the expected failure mode for the corrupted SSD.\n", .{});
                std.debug.print("The NVMe controller is blocking admin commands.\n", .{});
            },
            passthrough.PassthroughError.InvalidCommand => {
                std.debug.print("\nSanitize command not supported by drive or bridge.\n", .{});
                std.debug.print("Check SANICAP field with 'identify' command.\n", .{});
            },
            passthrough.PassthroughError.WriteProtected => {
                std.debug.print("\nDrive is in write-protected mode.\n", .{});
            },
            else => {},
        }
        return err;
    };

    if (result.isSuccess()) {
        std.debug.print("Sanitize command initiated successfully!\n", .{});
        std.debug.print("Duration: {} ms\n", .{result.duration_ms});
        std.debug.print("\nNote: Sanitize may continue in the background.\n", .{});
        std.debug.print("Use 'nvme sanitize-log' to check progress.\n", .{});
    } else {
        std.debug.print("Sanitize command returned with status:\n", .{});
        std.debug.print("  SCSI Status: {s}\n", .{@tagName(result.scsi_status)});
        std.debug.print("  NVMe Status: 0x{x:0>4}\n", .{result.nvme_status});

        if (result.sense_data) |sd| {
            var desc_buf: [256]u8 = undefined;
            const desc = sd.getDescription(&desc_buf);
            std.debug.print("  Sense: {s}\n", .{desc});
        }
    }
}

fn getActionDescription(action: SanitizeAction) []const u8 {
    return switch (action) {
        .reserved => "Reserved",
        .exit_failure_mode => "Exit Failure Mode",
        .block_erase => "Block Erase (NAND erase)",
        .overwrite => "Overwrite (pattern-based)",
        .crypto_erase => "Crypto Erase (key destruction)",
    };
}

/// Check sanitize capabilities of a device
pub fn checkCapabilities(
    allocator: std.mem.Allocator,
    device_path: []const u8,
) !void {
    std.debug.print("Checking sanitize capabilities for {s}...\n", .{device_path});

    // Would need to issue Identify Controller and parse SANICAP
    // For now, just document the capability check
    _ = allocator;
    std.debug.print("Use 'identify' command to check SANICAP field.\n", .{});
}
