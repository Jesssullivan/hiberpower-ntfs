//! Linux SG_IO ioctl wrapper for SCSI passthrough
//!
//! This module provides a Zig-native interface to the Linux SCSI Generic (sg)
//! driver, enabling direct SCSI command execution to block devices.

const std = @import("std");
const os = std.os;

/// SG_IO ioctl number (0x2285)
pub const SG_IO: u32 = 0x2285;

/// Data transfer directions
pub const Direction = enum(i32) {
    none = -1, // SG_DXFER_NONE
    to_dev = -2, // SG_DXFER_TO_DEV (write)
    from_dev = -3, // SG_DXFER_FROM_DEV (read)
    to_from_dev = -4, // SG_DXFER_TO_FROM_DEV
};

/// SG_IO interface ID (must be 'S' = 0x53)
pub const SG_INTERFACE_ID: i32 = 'S';

/// Maximum CDB length for this driver
pub const MAX_CDB_LEN: usize = 16;

/// Maximum sense buffer length
pub const MAX_SENSE_LEN: usize = 64;

/// Default timeout in milliseconds
pub const DEFAULT_TIMEOUT_MS: u32 = 30000;

/// sg_io_hdr structure matching Linux kernel definition
/// This is the core structure for SG_IO ioctl commands
pub const SgIoHdr = extern struct {
    /// Interface ID - must be 'S' (0x53) for SCSI generic
    interface_id: i32 = SG_INTERFACE_ID,

    /// Data transfer direction
    dxfer_direction: i32,

    /// SCSI command length (max 16 bytes)
    cmd_len: u8,

    /// Maximum length to write to sense buffer
    mx_sb_len: u8,

    /// Scatter-gather list element count (0 = no scatter-gather)
    iovec_count: u16 = 0,

    /// Byte count of data transfer
    dxfer_len: u32,

    /// Pointer to data transfer buffer or scatter-gather list
    dxferp: ?*anyopaque,

    /// Pointer to SCSI command (CDB)
    cmdp: [*]const u8,

    /// Pointer to sense buffer
    sbp: [*]u8,

    /// Timeout in milliseconds (0xFFFFFFFF = no timeout)
    timeout: u32,

    /// Flags (0 = default)
    flags: u32 = 0,

    /// Packet ID (unused internally, for user tracking)
    pack_id: i32 = 0,

    /// User pointer (unused internally)
    usr_ptr: ?*anyopaque = null,

    /// SCSI status byte [output]
    status: u8 = 0,

    /// Shifted, masked SCSI status [output]
    masked_status: u8 = 0,

    /// Message level data [output]
    msg_status: u8 = 0,

    /// Actual bytes written to sense buffer [output]
    sb_len_wr: u8 = 0,

    /// Host adapter errors [output]
    host_status: u16 = 0,

    /// Software driver errors [output]
    driver_status: u16 = 0,

    /// Residual count: dxfer_len - actual_transferred [output]
    resid: i32 = 0,

    /// Command duration in milliseconds [output]
    duration: u32 = 0,

    /// Auxiliary information [output]
    info: u32 = 0,
};

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
    @"error" = 0x07, // 'error' is a Zig keyword
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
    @"error" = 0x04, // 'error' is a Zig keyword
    invalid = 0x05,
    timeout = 0x06,
    hard = 0x07,
    sense = 0x08,
    _,
};

/// Info bits returned in sg_io_hdr.info
pub const InfoMask = struct {
    pub const OK: u32 = 0x0;
    pub const CHECK: u32 = 0x1;
    pub const DIRECT_IO: u32 = 0x2;
    pub const MIXED_IO: u32 = 0x4;
};

/// Result of an SG_IO command execution
pub const SgResult = struct {
    /// SCSI status
    status: ScsiStatus,
    /// Host adapter status
    host_status: HostStatus,
    /// Driver status
    driver_status: DriverStatus,
    /// Sense data (if check condition)
    sense_data: []const u8,
    /// Actual bytes transferred
    bytes_transferred: usize,
    /// Command duration in milliseconds
    duration_ms: u32,
    /// Whether command completed successfully
    success: bool,

    pub fn isCheckCondition(self: SgResult) bool {
        return self.status == .check_condition;
    }
};

/// Errors that can occur during SG_IO operations
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

/// Execute a SCSI command via SG_IO ioctl
pub fn execute(
    device_path: []const u8,
    cdb: []const u8,
    data_buffer: ?[]u8,
    direction: Direction,
    timeout_ms: u32,
) SgError!SgResult {
    // Open device
    const fd = std.posix.open(device_path, .{ .ACCMODE = .RDWR }, 0) catch |err| {
        return switch (err) {
            error.AccessDenied => SgError.PermissionDenied,
            error.FileNotFound, error.NoDevice => SgError.InvalidDevice,
            else => SgError.DeviceOpenFailed,
        };
    };
    defer std.posix.close(fd);

    return executeOnFd(fd, cdb, data_buffer, direction, timeout_ms);
}

/// Execute a SCSI command on an already-open file descriptor
pub fn executeOnFd(
    fd: std.posix.fd_t,
    cdb: []const u8,
    data_buffer: ?[]u8,
    direction: Direction,
    timeout_ms: u32,
) SgError!SgResult {
    var sense_buffer: [MAX_SENSE_LEN]u8 = [_]u8{0} ** MAX_SENSE_LEN;

    var hdr = SgIoHdr{
        .interface_id = SG_INTERFACE_ID,
        .dxfer_direction = @intFromEnum(direction),
        .cmd_len = @intCast(cdb.len),
        .mx_sb_len = MAX_SENSE_LEN,
        .dxfer_len = if (data_buffer) |buf| @intCast(buf.len) else 0,
        .dxferp = if (data_buffer) |buf| @ptrCast(buf.ptr) else null,
        .cmdp = cdb.ptr,
        .sbp = &sense_buffer,
        .timeout = timeout_ms,
    };

    // Execute ioctl
    const result = std.os.linux.ioctl(fd, SG_IO, @intFromPtr(&hdr));
    if (result != 0) {
        const err = std.posix.errno(result);
        return switch (err) {
            .ACCES => SgError.PermissionDenied,
            .NODEV => SgError.InvalidDevice,
            .TIMEDOUT => SgError.Timeout,
            else => SgError.IoctlFailed,
        };
    }

    const status: ScsiStatus = @enumFromInt(hdr.status);
    const host_status: HostStatus = @enumFromInt(hdr.host_status);
    const driver_status: DriverStatus = @enumFromInt(hdr.driver_status);

    const success = (hdr.info & InfoMask.CHECK) == 0 and
        status == .good and
        host_status == .ok and
        (driver_status == .ok or driver_status == .sense);

    return SgResult{
        .status = status,
        .host_status = host_status,
        .driver_status = driver_status,
        .sense_data = sense_buffer[0..hdr.sb_len_wr],
        .bytes_transferred = hdr.dxfer_len - @as(usize, @intCast(@max(0, hdr.resid))),
        .duration_ms = hdr.duration,
        .success = success,
    };
}

/// Build a standard SCSI INQUIRY CDB (6 bytes)
pub fn buildInquiryCdb(allocation_length: u8) [6]u8 {
    return .{
        0x12, // INQUIRY opcode
        0x00, // EVPD=0, Page Code=0
        0x00, // Reserved
        0x00, // Allocation Length (MSB)
        allocation_length, // Allocation Length (LSB)
        0x00, // Control
    };
}

/// Build a TEST UNIT READY CDB (6 bytes)
pub fn buildTestUnitReadyCdb() [6]u8 {
    return .{
        0x00, // TEST UNIT READY opcode
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    };
}

/// Build a READ CAPACITY(16) CDB
pub fn buildReadCapacity16Cdb() [16]u8 {
    return .{
        0x9E, // SERVICE ACTION IN
        0x10, // READ CAPACITY(16) service action
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // LBA (ignored)
        0x00, 0x00, 0x00, 0x00, // Allocation length (32 bytes)
        0x00, 0x00, 0x00, 0x20, // 32 bytes
    };
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

test "SgIoHdr size and alignment" {
    // Verify structure matches kernel expectations
    // The exact size depends on pointer size (32 vs 64 bit)
    const hdr_size = @sizeOf(SgIoHdr);
    try std.testing.expect(hdr_size >= 64); // Minimum expected size
    try std.testing.expect(hdr_size <= 128); // Maximum reasonable size
}

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
