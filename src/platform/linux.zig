//! Linux SG_IO ioctl backend for SCSI passthrough
//!
//! Uses the SCSI Generic (sg) driver to execute SCSI commands via ioctl.
//! Requires /dev/sgN or /dev/sdN device access (typically root).

const std = @import("std");
const scsi = @import("scsi.zig");

/// SG_IO ioctl number (0x2285)
const SG_IO: u32 = 0x2285;

/// SG_IO interface ID (must be 'S' = 0x53)
const SG_INTERFACE_ID: i32 = 'S';

/// sg_io_hdr structure matching Linux kernel definition
const SgIoHdr = extern struct {
    interface_id: i32 = SG_INTERFACE_ID,
    dxfer_direction: i32,
    cmd_len: u8,
    mx_sb_len: u8,
    iovec_count: u16 = 0,
    dxfer_len: u32,
    dxferp: ?*anyopaque,
    cmdp: [*]const u8,
    sbp: [*]u8,
    timeout: u32,
    flags: u32 = 0,
    pack_id: i32 = 0,
    usr_ptr: ?*anyopaque = null,
    status: u8 = 0,
    masked_status: u8 = 0,
    msg_status: u8 = 0,
    sb_len_wr: u8 = 0,
    host_status: u16 = 0,
    driver_status: u16 = 0,
    resid: i32 = 0,
    duration: u32 = 0,
    info: u32 = 0,
};

/// Info bits returned in sg_io_hdr.info
const InfoMask = struct {
    pub const CHECK: u32 = 0x1;
};

/// Execute a SCSI command via SG_IO ioctl on an open file descriptor
pub fn executeOnFd(
    fd: std.posix.fd_t,
    cdb: []const u8,
    data_buffer: ?[]u8,
    direction: scsi.Direction,
    timeout_ms: u32,
) scsi.SgError!scsi.SgResult {
    var sense_buffer: [scsi.MAX_SENSE_LEN]u8 = [_]u8{0} ** scsi.MAX_SENSE_LEN;

    var hdr = SgIoHdr{
        .interface_id = SG_INTERFACE_ID,
        .dxfer_direction = @intFromEnum(direction),
        .cmd_len = @intCast(cdb.len),
        .mx_sb_len = scsi.MAX_SENSE_LEN,
        .dxfer_len = if (data_buffer) |buf| @intCast(buf.len) else 0,
        .dxferp = if (data_buffer) |buf| @ptrCast(buf.ptr) else null,
        .cmdp = cdb.ptr,
        .sbp = &sense_buffer,
        .timeout = timeout_ms,
    };

    const result = std.os.linux.ioctl(fd, SG_IO, @intFromPtr(&hdr));
    if (result != 0) {
        const err = std.posix.errno(result);
        return switch (err) {
            .ACCES => scsi.SgError.PermissionDenied,
            .NODEV => scsi.SgError.InvalidDevice,
            .TIMEDOUT => scsi.SgError.Timeout,
            else => scsi.SgError.IoctlFailed,
        };
    }

    const status: scsi.ScsiStatus = @enumFromInt(hdr.status);
    const host_status: scsi.HostStatus = @enumFromInt(hdr.host_status);
    const driver_status: scsi.DriverStatus = @enumFromInt(hdr.driver_status);

    const success = (hdr.info & InfoMask.CHECK) == 0 and
        status == .good and
        host_status == .ok and
        (driver_status == .ok or driver_status == .sense);

    return scsi.SgResult{
        .status = status,
        .host_status = host_status,
        .driver_status = driver_status,
        .sense_data = sense_buffer[0..hdr.sb_len_wr],
        .bytes_transferred = hdr.dxfer_len - @as(usize, @intCast(@max(0, hdr.resid))),
        .duration_ms = hdr.duration,
        .success = success,
    };
}

/// Open a device by path
pub fn openDevice(device_path: []const u8) scsi.SgError!std.posix.fd_t {
    return std.posix.open(device_path, .{ .ACCMODE = .RDWR }, 0) catch |err| {
        return switch (err) {
            error.AccessDenied => scsi.SgError.PermissionDenied,
            error.FileNotFound, error.NoDevice => scsi.SgError.InvalidDevice,
            else => scsi.SgError.DeviceOpenFailed,
        };
    };
}

/// Close a device
pub fn closeDevice(fd: std.posix.fd_t) void {
    std.posix.close(fd);
}
