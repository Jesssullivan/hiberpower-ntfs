//! macOS IOKit backend for SCSI passthrough
//!
//! Uses SCSITaskUserClient via IOKit framework to send arbitrary SCSI CDBs
//! to USB mass storage devices. Requires sudo and unmounted volumes.
//!
//! Implementation status: STUB — see docs/MACOS-IOKIT.md for design.
//! Tracked by: https://github.com/Jesssullivan/hiberpower-ntfs/issues/4

const std = @import("std");
const scsi = @import("scsi.zig");

/// Execute a SCSI command via IOKit SCSITaskUserClient
pub fn executeOnFd(
    fd: std.posix.fd_t,
    cdb: []const u8,
    data_buffer: ?[]u8,
    direction: scsi.Direction,
    timeout_ms: u32,
) scsi.SgError!scsi.SgResult {
    _ = fd;
    _ = cdb;
    _ = data_buffer;
    _ = direction;
    _ = timeout_ms;
    @compileError(
        \\macOS IOKit SCSI backend not yet implemented.
        \\See: https://github.com/Jesssullivan/hiberpower-ntfs/issues/4
        \\Ref: docs/MACOS-IOKIT.md
    );
}

/// Open a device by BSD name (e.g., "disk4") via IOKit
pub fn openDevice(device_path: []const u8) scsi.SgError!std.posix.fd_t {
    _ = device_path;
    @compileError(
        \\macOS IOKit device open not yet implemented.
        \\See: https://github.com/Jesssullivan/hiberpower-ntfs/issues/5
    );
}

/// Close an IOKit device handle
pub fn closeDevice(fd: std.posix.fd_t) void {
    _ = fd;
    @compileError("macOS IOKit device close not yet implemented.");
}
