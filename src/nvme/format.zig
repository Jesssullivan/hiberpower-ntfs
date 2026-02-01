//! NVMe Format NVM Command Implementation
//!
//! WARNING: This command is DESTRUCTIVE and will erase all data on the drive.

const std = @import("std");
const passthrough = @import("../asm2362/passthrough.zig");

/// Secure Erase Setting values
pub const SecureEraseSetting = enum(u3) {
    /// No secure erase operation requested
    none = 0,
    /// User Data Erase: all user data shall be erased
    user_data = 1,
    /// Cryptographic Erase: encryption key changed (fastest)
    crypto = 2,
};

/// Execute NVMe Format NVM command
pub fn formatNvm(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    ses: u8,
) !void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  WARNING: FORMAT NVM - DESTRUCTIVE OPERATION                  ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Device: {s:52} ║\n", .{device_path});
    std.debug.print("║  Secure Erase Setting: {d}                                     ║\n", .{ses});
    std.debug.print("║                                                              ║\n", .{});
    std.debug.print("║  This operation will:                                        ║\n", .{});
    std.debug.print("║  - ERASE ALL DATA on the drive                               ║\n", .{});
    std.debug.print("║  - Reset the FTL (Flash Translation Layer)                   ║\n", .{});
    std.debug.print("║  - Clear all namespaces                                      ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const ses_setting: SecureEraseSetting = @enumFromInt(@as(u3, @truncate(ses)));
    const ses_desc = switch (ses_setting) {
        .none => "No secure erase (format only)",
        .user_data => "User Data Erase (erase all user data)",
        .crypto => "Cryptographic Erase (change encryption key)",
    };
    std.debug.print("Secure Erase: {s}\n\n", .{ses_desc});

    // Build and send Format NVM command
    // NSID=0xFFFFFFFF for all namespaces, LBAF=0 (first LBA format)
    std.debug.print("Sending Format NVM command...\n", .{});

    const result = passthrough.formatNvm(
        allocator,
        device_path,
        0xFFFFFFFF, // All namespaces
        0, // LBAF 0
        @truncate(ses),
    ) catch |err| {
        std.debug.print("Format command failed: {s}\n", .{@errorName(err)});

        switch (err) {
            passthrough.PassthroughError.MediumNotPresent => {
                std.debug.print("\nThe drive reports 'Medium not present'.\n", .{});
                std.debug.print("This is expected for a drive with corrupted FTL.\n", .{});
                std.debug.print("The Format command cannot be executed through USB passthrough.\n", .{});
                std.debug.print("\nRecommendations:\n", .{});
                std.debug.print("  1. Try connecting the drive directly to an M.2 slot\n", .{});
                std.debug.print("  2. Use vendor-specific tools (SP Toolbox on Windows)\n", .{});
                std.debug.print("  3. Extended power cycle (5+ minutes unpowered)\n", .{});
            },
            passthrough.PassthroughError.InvalidCommand => {
                std.debug.print("\nThe bridge or drive does not support Format NVM.\n", .{});
                std.debug.print("Try the sanitize command instead.\n", .{});
            },
            passthrough.PassthroughError.WriteProtected => {
                std.debug.print("\nThe drive is write-protected.\n", .{});
                std.debug.print("This may indicate firmware-level read-only mode.\n", .{});
            },
            else => {},
        }
        return err;
    };

    if (result.isSuccess()) {
        std.debug.print("Format command completed successfully!\n", .{});
        std.debug.print("Duration: {} ms\n", .{result.duration_ms});
    } else {
        std.debug.print("Format command returned with status:\n", .{});
        std.debug.print("  SCSI Status: {s}\n", .{@tagName(result.scsi_status)});
        std.debug.print("  NVMe Status: 0x{x:0>4}\n", .{result.nvme_status});
    }
}
