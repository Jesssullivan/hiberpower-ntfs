//! macOS IOKit backend for SCSI passthrough
//!
//! Uses SCSITaskUserClient via IOKit framework to send arbitrary SCSI CDBs
//! to USB mass storage devices. Requires sudo and unmounted volumes.
//!
//! Pattern: Force-unmount disk → IOKit exclusive access → SCSITask → execute
//! Reference: LTFS macOS driver (github.com/amiaopensource/ltfs)

const std = @import("std");
const scsi = @import("scsi.zig");

// ═══════════════════════════════════════════════════════════════════
// C imports — IOKit framework
// ═══════════════════════════════════════════════════════════════════

const c = @cImport({
    @cInclude("IOKit/IOKitLib.h");
    @cInclude("IOKit/IOCFPlugIn.h");
    @cInclude("IOKit/scsi/SCSITaskLib.h");
    @cInclude("IOKit/IOBSD.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

// UUID helpers — C macros use NULL which Zig translates as ?*anyopaque
// (type mismatch with CFAllocatorRef), so we construct them manually
fn cfUUID(b0: u8, b1: u8, b2: u8, b3: u8, b4: u8, b5: u8, b6: u8, b7: u8, b8: u8, b9: u8, b10: u8, b11: u8, b12: u8, b13: u8, b14: u8, b15: u8) c.CFUUIDRef {
    return c.CFUUIDGetConstantUUIDWithBytes(@as(c.CFAllocatorRef, null), b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15);
}

fn kSCSITaskDeviceUserClientTypeID() c.CFUUIDRef {
    return cfUUID(0x7D, 0x66, 0x67, 0x8E, 0x08, 0xA2, 0x11, 0xD5, 0xA1, 0xB8, 0x00, 0x30, 0x65, 0x7D, 0x05, 0x2A);
}
fn kSCSITaskDeviceInterfaceID() c.CFUUIDRef {
    return cfUUID(0x1B, 0xBC, 0x41, 0x32, 0x08, 0xA5, 0x11, 0xD5, 0x90, 0xED, 0x00, 0x30, 0x65, 0x7D, 0x05, 0x2A);
}
fn kIOCFPlugInInterfaceID() c.CFUUIDRef {
    return cfUUID(0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F);
}

// ═══════════════════════════════════════════════════════════════════
// IOKit handle state
// ═══════════════════════════════════════════════════════════════════

// Store raw opaque pointers — the COM vtable calling convention requires
// passing the double-pointer (self) as the first arg to every method.
var g_plugin: ?*anyopaque = null;
var g_device: ?*anyopaque = null;
var g_service: c.io_service_t = 0;
var g_exclusive: bool = false;
var g_open_path: [128]u8 = undefined;
var g_open_path_len: usize = 0;
var g_ref_count: u32 = 0;

// Helper: call a COM vtable method on a typed interface pointer
/// Open a device by BSD name (e.g., "/dev/disk4" or "disk4") via IOKit
/// Reuses existing handle if same device is requested (refcounted).
pub fn openDevice(device_path: []const u8) scsi.SgError!std.posix.fd_t {
    // Strip /dev/ prefix if present
    const bsd_name = if (std.mem.startsWith(u8, device_path, "/dev/"))
        device_path[5..]
    else
        device_path;

    // Reuse existing handle if same device
    if (g_device != null and g_open_path_len > 0) {
        if (std.mem.eql(u8, g_open_path[0..g_open_path_len], bsd_name)) {
            g_ref_count += 1;
            return 42;
        }
    }

    // Convert to null-terminated C string
    var name_buf: [128]u8 = undefined;
    if (bsd_name.len >= name_buf.len) return scsi.SgError.InvalidDevice;
    @memcpy(name_buf[0..bsd_name.len], bsd_name);
    name_buf[bsd_name.len] = 0;

    // Find IOService by BSD name, then walk up to IOSCSIPeripheralDeviceType00
    const matching = c.IOBSDNameMatching(c.kIOMainPortDefault, 0, &name_buf) orelse
        return scsi.SgError.InvalidDevice;

    const service = c.IOServiceGetMatchingService(c.kIOMainPortDefault, matching);
    if (service == 0) return scsi.SgError.InvalidDevice;

    // Walk parent chain
    var scsi_service: c.io_service_t = 0;
    var current = service;
    for (0..16) |_| {
        var cls: [128]u8 = undefined;
        if (c.IOObjectGetClass(current, &cls) == c.kIOReturnSuccess) {
            if (std.mem.eql(u8, std.mem.sliceTo(&cls, 0), "IOSCSIPeripheralDeviceType00")) {
                scsi_service = current;
                break;
            }
        }
        var parent: c.io_service_t = 0;
        if (c.IORegistryEntryGetParentEntry(current, c.kIOServicePlane, &parent) != c.kIOReturnSuccess) break;
        if (current != service) _ = c.IOObjectRelease(current);
        current = parent;
    }

    if (scsi_service == 0) {
        if (current != service) _ = c.IOObjectRelease(current);
        _ = c.IOObjectRelease(service);
        return scsi.SgError.InvalidDevice;
    }

    // Create CFPlugin
    var plugin: ?*?*c.IOCFPlugInInterface = null;
    var score: c.SInt32 = 0;
    var kr = c.IOCreatePlugInInterfaceForService(
        scsi_service,
        kSCSITaskDeviceUserClientTypeID(),
        kIOCFPlugInInterfaceID(),
        @ptrCast(&plugin),
        &score,
    );
    if (kr != c.kIOReturnSuccess or plugin == null) {
        _ = c.IOObjectRelease(scsi_service);
        return scsi.SgError.DeviceOpenFailed;
    }

    // QueryInterface → SCSITaskDeviceInterface
    var device_raw: ?*anyopaque = null;
    const plugin_self: ?*anyopaque = @ptrCast(plugin);
    const qi = plugin.?.*.?.*.QueryInterface.?(
        plugin_self,
        c.CFUUIDGetUUIDBytes(kSCSITaskDeviceInterfaceID()),
        @ptrCast(&device_raw),
    );
    if (qi != 0 or device_raw == null) {
        _ = plugin.?.*.?.*.Release.?(plugin_self);
        _ = c.IOObjectRelease(scsi_service);
        return scsi.SgError.DeviceOpenFailed;
    }

    // Obtain exclusive access
    const device: *?*c.SCSITaskDeviceInterface = @ptrCast(@alignCast(&device_raw));
    kr = device.*.?.*.ObtainExclusiveAccess.?(device_raw);
    if (kr != c.kIOReturnSuccess) {
        _ = device.*.?.*.Release.?(device_raw);
        _ = plugin.?.*.?.*.Release.?(plugin_self);
        _ = c.IOObjectRelease(scsi_service);
        return scsi.SgError.PermissionDenied;
    }

    // Store globally
    g_plugin = plugin_self;
    g_device = device_raw;
    g_service = scsi_service;
    g_exclusive = true;
    @memcpy(g_open_path[0..bsd_name.len], bsd_name);
    g_open_path_len = bsd_name.len;
    g_ref_count = 1;

    return 42; // sentinel fd
}

/// Close IOKit handle (refcounted — only releases on last close)
pub fn closeDevice(fd: std.posix.fd_t) void {
    _ = fd;
    if (g_ref_count > 1) {
        g_ref_count -= 1;
        return;
    }
    g_ref_count = 0;
    g_open_path_len = 0;
    if (g_device) |dev| {
        const device: *?*c.SCSITaskDeviceInterface = @ptrCast(@alignCast(&g_device));
        if (g_exclusive) {
            _ = device.*.?.*.ReleaseExclusiveAccess.?(dev);
        }
        _ = device.*.?.*.Release.?(dev);
    }
    if (g_plugin) |plug| {
        const plugin: *?*c.IOCFPlugInInterface = @ptrCast(@alignCast(&g_plugin));
        _ = plugin.*.?.*.Release.?(plug);
    }
    if (g_service != 0) _ = c.IOObjectRelease(g_service);
    g_device = null;
    g_plugin = null;
    g_service = 0;
    g_exclusive = false;
}

/// Execute a SCSI command via IOKit SCSITaskUserClient
pub fn executeOnFd(
    fd: std.posix.fd_t,
    cdb: []const u8,
    data_buffer: ?[]u8,
    direction: scsi.Direction,
    timeout_ms: u32,
) scsi.SgError!scsi.SgResult {
    _ = fd;

    const dev = g_device orelse return scsi.SgError.DeviceOpenFailed;
    const device: *?*c.SCSITaskDeviceInterface = @ptrCast(@alignCast(&g_device));

    std.debug.print("[iokit] executeOnFd: cdb[0]=0x{x:0>2} len={} dir={} buf={}\n", .{
        cdb[0], cdb.len, @intFromEnum(direction), if (data_buffer) |b| b.len else 0,
    });

    // Create SCSITask
    const task_raw = device.*.?.*.CreateSCSITask.?(dev) orelse {
        std.debug.print("[iokit] CreateSCSITask returned null\n", .{});
        return scsi.SgError.IoctlFailed;
    };

    var task_ptr = task_raw;
    const task: *?*c.SCSITaskInterface = @ptrCast(@alignCast(&task_ptr));
    defer _ = task.*.?.*.Release.?(@constCast(@ptrCast(&task_raw)));

    // Set CDB
    var cdb_buf: [16]u8 = [_]u8{0} ** 16;
    const cdb_len: u8 = @intCast(@min(cdb.len, 16));
    @memcpy(cdb_buf[0..cdb_len], cdb[0..cdb_len]);

    var kr = task.*.?.*.SetCommandDescriptorBlock.?(
        @constCast(@ptrCast(&task_raw)),
        &cdb_buf,
        cdb_len,
    );
    if (kr != c.kIOReturnSuccess) {
        std.debug.print("IOKit SetCommandDescriptorBlock failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(kr))});
        return scsi.SgError.IoctlFailed;
    }

    // Set scatter-gather
    if (data_buffer) |buf| {
        var range = c.IOVirtualRange{
            .address = @intFromPtr(buf.ptr),
            .length = buf.len,
        };
        const scsi_dir: u8 = switch (direction) {
            .from_dev => c.kSCSIDataTransfer_FromTargetToInitiator,
            .to_dev => c.kSCSIDataTransfer_FromInitiatorToTarget,
            else => c.kSCSIDataTransfer_NoDataTransfer,
        };
        kr = task.*.?.*.SetScatterGatherEntries.?(
            @constCast(@ptrCast(&task_raw)),
            &range,
            1,
            buf.len,
            scsi_dir,
        );
        if (kr != c.kIOReturnSuccess) return scsi.SgError.IoctlFailed;
    }

    // Set timeout
    kr = task.*.?.*.SetTimeoutDuration.?(@constCast(@ptrCast(&task_raw)), timeout_ms);
    if (kr != c.kIOReturnSuccess) return scsi.SgError.IoctlFailed;

    // Execute
    var sense_data: c.SCSI_Sense_Data = std.mem.zeroes(c.SCSI_Sense_Data);
    var task_status: c.SCSITaskStatus = 0;
    var transferred: u64 = 0;

    kr = task.*.?.*.ExecuteTaskSync.?(
        @constCast(@ptrCast(&task_raw)),
        &sense_data,
        &task_status,
        &transferred,
    );

    if (kr != c.kIOReturnSuccess) {
        std.debug.print("IOKit ExecuteTaskSync failed: 0x{x:0>8} (task_status={}, cdb[0]=0x{x:0>2})\n", .{
            @as(u32, @bitCast(kr)), task_status, cdb[0],
        });
        return switch (kr) {
            c.kIOReturnTimeout => scsi.SgError.Timeout,
            c.kIOReturnNotPermitted => scsi.SgError.PermissionDenied,
            c.kIOReturnNoDevice => scsi.SgError.InvalidDevice,
            else => scsi.SgError.IoctlFailed,
        };
    }

    std.debug.print("[iokit] ExecuteTaskSync OK: task_status={} transferred={}\n", .{ task_status, transferred });

    // Map status
    const status: scsi.ScsiStatus = switch (task_status) {
        c.kSCSITaskStatus_GOOD => .good,
        c.kSCSITaskStatus_CHECK_CONDITION => .check_condition,
        c.kSCSITaskStatus_BUSY => .busy,
        c.kSCSITaskStatus_RESERVATION_CONFLICT => .reservation_conflict,
        c.kSCSITaskStatus_TASK_SET_FULL => .task_set_full,
        c.kSCSITaskStatus_ACA_ACTIVE => .aca_active,
        else => @enumFromInt(@as(u8, @intCast(task_status & 0xFF))),
    };

    const sense_bytes = std.mem.asBytes(&sense_data);
    const sense_len: usize = if (status == .check_condition) @sizeOf(c.SCSI_Sense_Data) else 0;

    return scsi.SgResult{
        .status = status,
        .host_status = .ok,
        .driver_status = if (status == .check_condition) .sense else .ok,
        .sense_data = sense_bytes[0..sense_len],
        .bytes_transferred = @intCast(transferred),
        .duration_ms = 0,
        .success = (status == .good),
    };
}
