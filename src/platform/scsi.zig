//! Platform-abstracted SCSI passthrough interface
//!
//! Dispatches to platform-specific backends at comptime:
//!   - Linux: SG_IO ioctl (src/platform/linux.zig)
//!   - macOS: IOKit SCSITaskUserClient (src/platform/darwin.zig)
//!
//! All CDB builders, types, and formatting functions are portable and
//! defined here. Only execute/open/close dispatch to platform code.

const std = @import("std");
const builtin = @import("builtin");

// Platform backend selection (comptime)
const backend = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos => @import("darwin.zig"),
    else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag) ++ ". Only Linux and macOS are supported."),
};

// ═══════════════════════════════════════════════════════════════════
// Types (portable — used by all modules)
// ═══════════════════════════════════════════════════════════════════

/// Data transfer directions
pub const Direction = enum(i32) {
    none = -1,
    to_dev = -2,
    from_dev = -3,
    to_from_dev = -4,
};

/// Maximum CDB length
pub const MAX_CDB_LEN: usize = 16;

/// Maximum sense buffer length
pub const MAX_SENSE_LEN: usize = 64;

/// Default timeout in milliseconds
pub const DEFAULT_TIMEOUT_MS: u32 = 30000;

/// SCSI status codes
pub const ScsiStatus = enum(u8) {
    good = 0x00,
    check_condition = 0x02,
    condition_met = 0x04,
    busy = 0x08,
    intermediate = 0x10,
    intermediate_condition_met = 0x14,
    reservation_conflict = 0x18,
    command_terminated = 0x22,
    task_set_full = 0x28,
    aca_active = 0x30,
    task_aborted = 0x40,
    _,
};

/// Host status codes
pub const HostStatus = enum(u16) {
    ok = 0x00,
    no_connect = 0x01,
    bus_busy = 0x02,
    time_out = 0x03,
    bad_target = 0x04,
    abort = 0x05,
    parity = 0x06,
    @"error" = 0x07,
    reset = 0x08,
    bad_intr = 0x09,
    passthrough = 0x0a,
    soft_error = 0x0b,
    _,
};

/// Driver status codes
pub const DriverStatus = enum(u16) {
    ok = 0x00,
    busy = 0x01,
    soft = 0x02,
    media = 0x03,
    @"error" = 0x04,
    invalid = 0x05,
    timeout = 0x06,
    hard = 0x07,
    sense = 0x08,
    _,
};

/// Result of a SCSI command execution
pub const SgResult = struct {
    status: ScsiStatus,
    host_status: HostStatus,
    driver_status: DriverStatus,
    sense_data: []const u8,
    bytes_transferred: usize,
    duration_ms: u32,
    success: bool,

    pub fn isCheckCondition(self: SgResult) bool {
        return self.status == .check_condition;
    }
};

/// Errors that can occur during SCSI operations
pub const SgError = error{
    DeviceOpenFailed,
    IoctlFailed,
    InvalidResponse,
    HostError,
    DriverError,
    Timeout,
    CheckCondition,
    InvalidDevice,
    PermissionDenied,
};

// ═══════════════════════════════════════════════════════════════════
// Platform-dispatched functions
// ═══════════════════════════════════════════════════════════════════

/// Execute a SCSI command on a device path (opens + closes internally)
pub fn execute(
    device_path: []const u8,
    cdb: []const u8,
    data_buffer: ?[]u8,
    direction: Direction,
    timeout_ms: u32,
) SgError!SgResult {
    const fd = try backend.openDevice(device_path);
    defer backend.closeDevice(fd);
    return backend.executeOnFd(fd, cdb, data_buffer, direction, timeout_ms);
}

/// Execute a SCSI command on an already-open file descriptor
pub fn executeOnFd(
    fd: std.posix.fd_t,
    cdb: []const u8,
    data_buffer: ?[]u8,
    direction: Direction,
    timeout_ms: u32,
) SgError!SgResult {
    return backend.executeOnFd(fd, cdb, data_buffer, direction, timeout_ms);
}

// ═══════════════════════════════════════════════════════════════════
// Portable CDB builders (no platform dependency)
// ═══════════════════════════════════════════════════════════════════

/// Build a standard SCSI INQUIRY CDB (6 bytes)
pub fn buildInquiryCdb(allocation_length: u8) [6]u8 {
    return .{ 0x12, 0x00, 0x00, 0x00, allocation_length, 0x00 };
}

/// Build a TEST UNIT READY CDB (6 bytes)
pub fn buildTestUnitReadyCdb() [6]u8 {
    return .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
}

/// Build a READ CAPACITY(16) CDB
pub fn buildReadCapacity16Cdb() [16]u8 {
    return .{ 0x9E, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20 };
}

/// Format a CDB as a hex string for logging
pub fn formatCdb(cdb: []const u8, buffer: []u8) []u8 {
    var offset: usize = 0;
    for (cdb, 0..) |byte, i| {
        if (i > 0 and offset < buffer.len) {
            buffer[offset] = ' ';
            offset += 1;
        }
        if (offset + 2 <= buffer.len) {
            _ = std.fmt.bufPrint(buffer[offset..], "{x:0>2}", .{byte}) catch break;
            offset += 2;
        }
    }
    return buffer[0..offset];
}

// ═══════════════════════════════════════════════════════════════════
// Tests (portable)
// ═══════════════════════════════════════════════════════════════════

test "build INQUIRY CDB" {
    const cdb = buildInquiryCdb(96);
    try std.testing.expectEqual(@as(u8, 0x12), cdb[0]);
    try std.testing.expectEqual(@as(u8, 96), cdb[4]);
}

test "build TEST UNIT READY CDB" {
    const cdb = buildTestUnitReadyCdb();
    try std.testing.expectEqual(@as(u8, 0x00), cdb[0]);
}

test "format CDB" {
    var buffer: [64]u8 = undefined;
    const cdb = [_]u8{ 0xe6, 0x06, 0x00, 0x01 };
    const formatted = formatCdb(&cdb, &buffer);
    try std.testing.expectEqualStrings("e6 06 00 01", formatted);
}
