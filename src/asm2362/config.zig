//! ASM2362 bridge configuration access.
//!
//! The ASM2362 exposes vendor-specific SCSI opcodes for configuration access:
//! - 0xE0: Read config image (128 bytes)
//! - 0xE1: Write config image (not implemented here yet)

const std = @import("std");
const sg_io = @import("../scsi/sg_io.zig");

pub const CONFIG_SIZE: usize = 128;
pub const IMAGE_COUNT: u8 = 2;

pub const ConfigError = error{
    PermissionDenied,
    DeviceNotFound,
    Timeout,
    InvalidImageIndex,
    CommandFailed,
    ShortRead,
};

pub const ConfigReadResult = struct {
    image_index: u8,
    data: [CONFIG_SIZE]u8,
    duration_ms: u32,
    scsi_status: sg_io.ScsiStatus,
};

/// Build a READ CONFIG CDB (0xE0).
///
/// Source: cyrozap/usb-to-pcie-re ASM2x6x notes:
///   e0 <image> 00 00 00 00
pub fn buildReadConfigCdb(image_index: u8) [6]u8 {
    return .{
        0xE0,
        image_index,
        0x00,
        0x00,
        0x00,
        0x00,
    };
}

pub fn readConfig(device_path: []const u8, image_index: u8) ConfigError!ConfigReadResult {
    if (image_index >= IMAGE_COUNT) {
        return ConfigError.InvalidImageIndex;
    }

    var buffer: [CONFIG_SIZE]u8 = [_]u8{0} ** CONFIG_SIZE;
    const cdb = buildReadConfigCdb(image_index);
    const result = sg_io.execute(device_path, &cdb, &buffer, .from_dev, sg_io.DEFAULT_TIMEOUT_MS) catch |err| {
        return switch (err) {
            sg_io.SgError.PermissionDenied => ConfigError.PermissionDenied,
            sg_io.SgError.InvalidDevice => ConfigError.DeviceNotFound,
            sg_io.SgError.Timeout => ConfigError.Timeout,
            else => ConfigError.CommandFailed,
        };
    };

    if (!result.success) {
        return ConfigError.CommandFailed;
    }

    if (result.bytes_transferred < CONFIG_SIZE) {
        return ConfigError.ShortRead;
    }

    return ConfigReadResult{
        .image_index = image_index,
        .data = buffer,
        .duration_ms = result.duration_ms,
        .scsi_status = result.status,
    };
}

pub fn printConfigHuman(result: *const ConfigReadResult) void {
    std.debug.print("Bridge Config Image {d} ({d} bytes)\n", .{ result.image_index, CONFIG_SIZE });
    std.debug.print("Result: SCSI status={s}, duration={d}ms\n", .{
        @tagName(result.scsi_status),
        result.duration_ms,
    });
    std.debug.print("Notable bytes:\n", .{});
    std.debug.print("  [0x7D] = 0x{x:0>2}\n", .{result.data[0x7D]});
    std.debug.print("\nHex dump:\n", .{});

    for (0..CONFIG_SIZE) |i| {
        if (i % 16 == 0) {
            std.debug.print("  {x:0>4}: ", .{i});
        }
        std.debug.print("{x:0>2} ", .{result.data[i]});
        if (i % 16 == 15) {
            std.debug.print("\n", .{});
        }
    }
}

pub fn printConfigJson(result: *const ConfigReadResult) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(
        "{{\n  \"image_index\": {},\n  \"duration_ms\": {},\n  \"byte_7d\": \"0x{x:0>2}\",\n  \"data_hex\": \"",
        .{ result.image_index, result.duration_ms, result.data[0x7D] },
    ) catch return;

    for (result.data) |byte| {
        stdout.print("{x:0>2}", .{byte}) catch return;
    }

    stdout.print("\"\n}}\n", .{}) catch return;
}

test "build READ CONFIG CDB" {
    const cdb0 = buildReadConfigCdb(0);
    try std.testing.expectEqual(@as(u8, 0xE0), cdb0[0]);
    try std.testing.expectEqual(@as(u8, 0x00), cdb0[1]);
    try std.testing.expectEqual(@as(usize, 6), cdb0.len);

    const cdb1 = buildReadConfigCdb(1);
    try std.testing.expectEqual(@as(u8, 0x01), cdb1[1]);
}
