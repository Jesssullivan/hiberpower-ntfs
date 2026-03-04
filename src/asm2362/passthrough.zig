//! ASMedia ASM2362 NVMe Passthrough Implementation
//!
//! This module implements the vendor-specific 0xe6 CDB for sending NVMe
//! admin commands through the ASM2362 USB-to-NVMe bridge controller.
//!
//! Reference: smartmontools os_linux.cpp - implementation for sntasmedia device type
//!
//! CDB Format (16 bytes):
//! Byte 0:     0xe6 (ASMedia passthrough opcode)
//! Byte 1:     NVMe opcode (0x06=Identify, 0x02=GetLog, 0x80=Format, etc.)
//! Byte 2:     Reserved
//! Byte 3:     CDW10[7:0]
//! Byte 4:     Reserved
//! Byte 5:     Reserved
//! Byte 6:     CDW10[23:16]
//! Byte 7:     CDW10[31:24]
//! Bytes 8-11: CDW13 (big-endian)
//! Bytes 12-15: CDW12 (big-endian)

const std = @import("std");
const sg_io = @import("../scsi/sg_io.zig");
const sense = @import("../scsi/sense.zig");

/// ASMedia passthrough opcode
pub const ASM_PASSTHROUGH_OPCODE: u8 = 0xe6;

/// NVMe Admin Command Opcodes
pub const NvmeOpcode = enum(u8) {
    // Admin commands
    delete_io_sq = 0x00,
    create_io_sq = 0x01,
    get_log_page = 0x02,
    delete_io_cq = 0x04,
    create_io_cq = 0x05,
    identify = 0x06,
    abort = 0x08,
    set_features = 0x09,
    get_features = 0x0A,
    async_event_req = 0x0C,
    ns_management = 0x0D,
    firmware_commit = 0x10,
    firmware_download = 0x11,
    device_self_test = 0x14,
    ns_attachment = 0x15,
    format_nvm = 0x80,
    security_send = 0x81,
    security_recv = 0x82,
    sanitize = 0x84,

    pub fn toString(self: NvmeOpcode) []const u8 {
        return switch (self) {
            .delete_io_sq => "Delete I/O SQ",
            .create_io_sq => "Create I/O SQ",
            .get_log_page => "Get Log Page",
            .delete_io_cq => "Delete I/O CQ",
            .create_io_cq => "Create I/O CQ",
            .identify => "Identify",
            .abort => "Abort",
            .set_features => "Set Features",
            .get_features => "Get Features",
            .async_event_req => "Async Event Request",
            .ns_management => "NS Management",
            .firmware_commit => "Firmware Commit",
            .firmware_download => "Firmware Download",
            .device_self_test => "Device Self-Test",
            .ns_attachment => "NS Attachment",
            .format_nvm => "Format NVM",
            .security_send => "Security Send",
            .security_recv => "Security Receive",
            .sanitize => "Sanitize",
        };
    }
};

/// NVMe Identify CNS values
pub const IdentifyCns = enum(u8) {
    namespace = 0x00,
    controller = 0x01,
    active_ns_list = 0x02,
    ns_desc_list = 0x03,
    nvm_set_list = 0x04,
    _,
};

/// NVMe Log Page IDs
pub const LogPageId = enum(u8) {
    error_info = 0x01,
    smart_health = 0x02,
    firmware_slot = 0x03,
    changed_ns_list = 0x04,
    commands_supported = 0x05,
    device_self_test = 0x06,
    telemetry_host = 0x07,
    telemetry_controller = 0x08,
    endurance_group = 0x09,
    _,
};

/// Errors specific to ASM2362 passthrough
pub const PassthroughError = error{
    SgIoFailed,
    CheckCondition,
    InvalidResponse,
    MediumNotPresent,
    WriteProtected,
    InvalidCommand,
    Timeout,
    PermissionDenied,
    DeviceNotFound,
};

/// Result of an NVMe passthrough command
pub const PassthroughResult = struct {
    /// Data returned from command (if any)
    data: ?[]u8,
    /// NVMe status code (from completion queue)
    nvme_status: u16,
    /// SCSI status
    scsi_status: sg_io.ScsiStatus,
    /// Sense data (if check condition)
    sense_data: ?sense.SenseData,
    /// Command duration in milliseconds
    duration_ms: u32,

    pub fn isSuccess(self: PassthroughResult) bool {
        return self.scsi_status == .good and self.nvme_status == 0;
    }
};

/// Build an ASM2362 passthrough CDB for an NVMe admin command
///
/// Parameters:
/// - opcode: NVMe admin command opcode
/// - cdw10: Command Dword 10
/// - cdw12: Command Dword 12
/// - cdw13: Command Dword 13
pub fn buildCdb(opcode: NvmeOpcode, cdw10: u32, cdw12: u32, cdw13: u32) [16]u8 {
    var cdb: [16]u8 = [_]u8{0} ** 16;

    // Byte 0: ASMedia passthrough opcode
    cdb[0] = ASM_PASSTHROUGH_OPCODE;

    // Byte 1: NVMe opcode
    cdb[1] = @intFromEnum(opcode);

    // Byte 2: Reserved
    cdb[2] = 0x00;

    // Byte 3: CDW10[7:0]
    cdb[3] = @truncate(cdw10 & 0xFF);

    // Bytes 4-5: Reserved
    cdb[4] = 0x00;
    cdb[5] = 0x00;

    // Byte 6: CDW10[23:16]
    cdb[6] = @truncate((cdw10 >> 16) & 0xFF);

    // Byte 7: CDW10[31:24]
    cdb[7] = @truncate((cdw10 >> 24) & 0xFF);

    // Bytes 8-11: CDW13 (big-endian)
    cdb[8] = @truncate((cdw13 >> 24) & 0xFF);
    cdb[9] = @truncate((cdw13 >> 16) & 0xFF);
    cdb[10] = @truncate((cdw13 >> 8) & 0xFF);
    cdb[11] = @truncate(cdw13 & 0xFF);

    // Bytes 12-15: CDW12 (big-endian)
    cdb[12] = @truncate((cdw12 >> 24) & 0xFF);
    cdb[13] = @truncate((cdw12 >> 16) & 0xFF);
    cdb[14] = @truncate((cdw12 >> 8) & 0xFF);
    cdb[15] = @truncate(cdw12 & 0xFF);

    return cdb;
}

/// Build CDB for NVMe Identify Controller command
pub fn buildIdentifyControllerCdb() [16]u8 {
    // CNS=0x01 (Controller), NSID=0
    return buildCdb(.identify, @intFromEnum(IdentifyCns.controller), 0, 0);
}

/// Build CDB for NVMe Identify Namespace command
pub fn buildIdentifyNamespaceCdb(nsid: u32) [16]u8 {
    // CNS=0x00 (Namespace), NSID specified
    // For Identify NS, NSID goes in CDW10 high bits in some implementations
    // but typically it's a separate command field. Check empirically.
    return buildCdb(.identify, @intFromEnum(IdentifyCns.namespace), 0, nsid);
}

/// Build CDB for NVMe Get Log Page (SMART/Health) command
pub fn buildSmartLogCdb() [16]u8 {
    // Log Page ID 0x02 (SMART/Health), NSID=0xFFFFFFFF (global)
    // CDW10: NUMDL=127 (128 dwords = 512 bytes), LID=2
    const numdl: u32 = 127; // Number of Dwords Lower (0-based)
    const lid: u32 = @intFromEnum(LogPageId.smart_health);
    const cdw10 = (numdl << 16) | lid;

    return buildCdb(.get_log_page, cdw10, 0, 0);
}

/// Build CDB for NVMe Format NVM command
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn buildFormatCdb(nsid: u32, lbaf: u4, ses: u3) [16]u8 {
    // CDW10: LBAF (bits 3:0), SES (bits 11:9)
    const cdw10: u32 = @as(u32, lbaf) | (@as(u32, ses) << 9);
    return buildCdb(.format_nvm, cdw10, 0, nsid);
}

/// Build CDB for NVMe Sanitize command
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn buildSanitizeCdb(sanact: u3) [16]u8 {
    // CDW10: SANACT (bits 2:0)
    // 1 = Exit Failure Mode
    // 2 = Block Erase
    // 3 = Overwrite
    // 4 = Crypto Erase
    const cdw10: u32 = @as(u32, sanact);
    return buildCdb(.sanitize, cdw10, 0, 0);
}

/// Security Protocol values for Security Send/Receive
pub const SecurityProtocol = enum(u8) {
    /// Security Protocol Information
    info = 0x00,
    /// TCG Storage
    tcg = 0x01,
    /// IEEE 1667
    ieee1667 = 0xee,
    /// ATA Device Server Password Security
    ata_password = 0xef,
    _,
};

/// NVMe Feature IDs for Get/Set Features commands
pub const FeatureId = enum(u8) {
    /// Arbitration
    arbitration = 0x01,
    /// Power Management
    power_management = 0x02,
    /// LBA Range Type
    lba_range_type = 0x03,
    /// Temperature Threshold
    temperature_threshold = 0x04,
    /// Error Recovery
    error_recovery = 0x05,
    /// Volatile Write Cache
    volatile_write_cache = 0x06,
    /// Number of Queues
    number_of_queues = 0x07,
    /// Interrupt Coalescing
    interrupt_coalescing = 0x08,
    /// Interrupt Vector Configuration
    interrupt_vector_config = 0x09,
    /// Write Atomicity Normal
    write_atomicity_normal = 0x0A,
    /// Async Event Configuration
    async_event_config = 0x0B,
    /// Autonomous Power State Transition
    apst = 0x0C,
    /// Host Memory Buffer
    host_memory_buffer = 0x0D,
    /// Timestamp
    timestamp = 0x0E,
    /// Keep Alive Timer
    keep_alive_timer = 0x0F,
    /// Host Controlled Thermal Management
    hctm = 0x10,
    /// Non-Operational Power State Config
    nopsc = 0x11,
    /// Read Recovery Level
    read_recovery_level = 0x12,
    /// Predictable Latency Mode Config
    plm_config = 0x13,
    /// Predictable Latency Mode Window
    plm_window = 0x14,
    /// LBA Status Information Report Interval
    lba_status_interval = 0x15,
    /// Host Behavior Support
    host_behavior = 0x16,
    /// Sanitize Config
    sanitize_config = 0x17,
    /// Endurance Group Event Config
    endurance_event_config = 0x18,
    /// Software Progress Marker
    software_progress_marker = 0x80,
    /// Host Identifier
    host_identifier = 0x81,
    /// Reservation Notification Mask
    reservation_notification_mask = 0x82,
    /// Reservation Persistence
    reservation_persistence = 0x83,
    /// Namespace Write Protect Config
    namespace_write_protect = 0x84,
    _,

    pub fn toString(self: FeatureId) []const u8 {
        return switch (self) {
            .arbitration => "Arbitration",
            .power_management => "Power Management",
            .lba_range_type => "LBA Range Type",
            .temperature_threshold => "Temperature Threshold",
            .error_recovery => "Error Recovery",
            .volatile_write_cache => "Volatile Write Cache",
            .number_of_queues => "Number of Queues",
            .interrupt_coalescing => "Interrupt Coalescing",
            .interrupt_vector_config => "Interrupt Vector Config",
            .write_atomicity_normal => "Write Atomicity Normal",
            .async_event_config => "Async Event Config",
            .apst => "Auto Power State Transition",
            .host_memory_buffer => "Host Memory Buffer",
            .timestamp => "Timestamp",
            .keep_alive_timer => "Keep Alive Timer",
            .hctm => "Host Controlled Thermal Management",
            .nopsc => "Non-Op Power State Config",
            .read_recovery_level => "Read Recovery Level",
            .plm_config => "Predictable Latency Mode Config",
            .plm_window => "Predictable Latency Mode Window",
            .lba_status_interval => "LBA Status Interval",
            .host_behavior => "Host Behavior Support",
            .sanitize_config => "Sanitize Config",
            .endurance_event_config => "Endurance Group Event Config",
            .software_progress_marker => "Software Progress Marker",
            .host_identifier => "Host Identifier",
            .reservation_notification_mask => "Reservation Notification Mask",
            .reservation_persistence => "Reservation Persistence",
            .namespace_write_protect => "Namespace Write Protect",
            _ => "Unknown Feature",
        };
    }
};

/// Build CDB for NVMe Get Features command (0x0A)
/// Returns current value of specified feature
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn buildGetFeaturesCdb(fid: u8, nsid: u32, sel: u2) [16]u8 {
    // CDW10: SEL (bits 10:8), FID (bits 7:0)
    // SEL: 0=Current, 1=Default, 2=Saved, 3=Supported Capabilities
    const cdw10: u32 = @as(u32, fid) | (@as(u32, sel) << 8);
    return buildCdb(.get_features, cdw10, 0, nsid);
}

/// Build CDB for NVMe Set Features command (0x09)
/// Sets the value of specified feature
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn buildSetFeaturesCdb(fid: u8, nsid: u32, cdw11: u32, save: bool) [16]u8 {
    // CDW10: SV (bit 31), FID (bits 7:0)
    // SV: Save - if set, feature persists across power cycles
    var cdw10: u32 = @as(u32, fid);
    if (save) {
        cdw10 |= (1 << 31);
    }
    // CDW11 contains the feature-specific value
    return buildCdb(.set_features, cdw10, cdw11, nsid);
}

/// Build CDB for NVMe Security Send command (0x81)
/// Used for ATA security password and erase operations
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn buildSecuritySendCdb(protocol: u8, sp_specific: u16, transfer_len: u32) [16]u8 {
    // CDW10: Security Protocol (7:0), SP Specific (23:8), Reserved (31:24)
    const cdw10: u32 = @as(u32, protocol) | (@as(u32, sp_specific) << 8);
    // CDW11: Transfer Length (AL - Allocation Length)
    const cdw11: u32 = transfer_len;
    return buildCdb(.security_send, cdw10, cdw11, 0);
}

/// Build CDB for NVMe Security Receive command (0x82)
/// Used to receive security data/status
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn buildSecurityRecvCdb(protocol: u8, sp_specific: u16, transfer_len: u32) [16]u8 {
    // CDW10: Security Protocol (7:0), SP Specific (23:8), Reserved (31:24)
    const cdw10: u32 = @as(u32, protocol) | (@as(u32, sp_specific) << 8);
    // CDW11: Transfer Length (AL - Allocation Length)
    const cdw11: u32 = transfer_len;
    return buildCdb(.security_recv, cdw10, cdw11, 0);
}

/// Execute NVMe Security Send command
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn securitySend(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    protocol: u8,
    sp_specific: u16,
    data: []const u8,
) PassthroughError!PassthroughResult {
    _ = data; // TODO: Pass data buffer to execute when implementing full security send
    const cdb = buildSecuritySendCdb(protocol, sp_specific, 0);

    return execute(
        allocator,
        device_path,
        &cdb,
        0, // No data transfer for now - security commands need special handling
        .none,
        30000, // 30 second timeout
    );
}

/// Execute NVMe Security Receive command
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn securityRecv(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    protocol: u8,
    sp_specific: u16,
    buffer_len: usize,
) PassthroughError!PassthroughResult {
    const cdb = buildSecurityRecvCdb(protocol, sp_specific, @intCast(buffer_len));
    return execute(
        allocator,
        device_path,
        &cdb,
        buffer_len,
        .from_dev,
        30000, // 30 second timeout
    );
}

/// Execute NVMe Get Features command
/// Returns feature value in result data (4 bytes for simple features)
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn getFeatures(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    fid: u8,
    nsid: u32,
    sel: u2,
) PassthroughError!PassthroughResult {
    const cdb = buildGetFeaturesCdb(fid, nsid, sel);
    return execute(
        allocator,
        device_path,
        &cdb,
        4096, // Some features return data structures
        .from_dev,
        sg_io.DEFAULT_TIMEOUT_MS,
    );
}

/// Execute NVMe Set Features command
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn setFeatures(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    fid: u8,
    nsid: u32,
    value: u32,
    save: bool,
) PassthroughError!PassthroughResult {
    const cdb = buildSetFeaturesCdb(fid, nsid, value, save);
    return execute(
        allocator,
        device_path,
        &cdb,
        0, // No data transfer for simple features
        .none,
        sg_io.DEFAULT_TIMEOUT_MS,
    );
}

/// Get Write Protect status for a namespace
/// Returns true if write protection is enabled
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn getWriteProtectStatus(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    nsid: u32,
) PassthroughError!PassthroughResult {
    return getFeatures(
        allocator,
        device_path,
        @intFromEnum(FeatureId.namespace_write_protect),
        nsid,
        0, // Current value
    );
}

/// Attempt to clear write protection on a namespace
/// Note: This may not work if controller has locked the protection
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn clearWriteProtect(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    nsid: u32,
) PassthroughError!PassthroughResult {
    // CDW11 value 0 = No Write Protect
    return setFeatures(
        allocator,
        device_path,
        @intFromEnum(FeatureId.namespace_write_protect),
        nsid,
        0, // Disable write protection
        true, // Save persistently
    );
}

/// Execute an NVMe admin command via ASM2362 passthrough
pub fn execute(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    cdb: []const u8,
    data_len: usize,
    direction: sg_io.Direction,
    timeout_ms: u32,
) PassthroughError!PassthroughResult {
    // Allocate data buffer if needed
    var data_buffer: ?[]u8 = null;
    if (data_len > 0) {
        data_buffer = allocator.alloc(u8, data_len) catch {
            return PassthroughError.SgIoFailed;
        };
        @memset(data_buffer.?, 0);
    }
    errdefer if (data_buffer) |buf| allocator.free(buf);

    // Execute SG_IO
    const result = sg_io.execute(
        device_path,
        cdb,
        data_buffer,
        direction,
        timeout_ms,
    ) catch |err| {
        return switch (err) {
            sg_io.SgError.PermissionDenied => PassthroughError.PermissionDenied,
            sg_io.SgError.InvalidDevice => PassthroughError.DeviceNotFound,
            sg_io.SgError.Timeout => PassthroughError.Timeout,
            else => PassthroughError.SgIoFailed,
        };
    };

    // Parse sense data if present
    var sense_data: ?sense.SenseData = null;
    if (result.isCheckCondition() and result.sense_data.len > 0) {
        sense_data = sense.parse(result.sense_data);

        if (sense_data) |sd| {
            // Note: errdefer handles buffer cleanup on error return
            if (sd.isMediumNotPresent()) {
                return PassthroughError.MediumNotPresent;
            }
            if (sd.isWriteProtected()) {
                return PassthroughError.WriteProtected;
            }
            if (sd.isInvalidCommand()) {
                return PassthroughError.InvalidCommand;
            }
        }
    }

    return PassthroughResult{
        .data = data_buffer,
        .nvme_status = 0, // Would need to extract from response
        .scsi_status = result.status,
        .sense_data = sense_data,
        .duration_ms = result.duration_ms,
    };
}

/// Execute NVMe Identify Controller command
pub fn identifyController(
    allocator: std.mem.Allocator,
    device_path: []const u8,
) PassthroughError!PassthroughResult {
    const cdb = buildIdentifyControllerCdb();
    return execute(
        allocator,
        device_path,
        &cdb,
        4096, // Identify data is 4KB
        .from_dev,
        sg_io.DEFAULT_TIMEOUT_MS,
    );
}

/// Execute NVMe Get Log Page (SMART) command
pub fn getSmartLog(
    allocator: std.mem.Allocator,
    device_path: []const u8,
) PassthroughError!PassthroughResult {
    const cdb = buildSmartLogCdb();
    return execute(
        allocator,
        device_path,
        &cdb,
        512, // SMART log is 512 bytes
        .from_dev,
        sg_io.DEFAULT_TIMEOUT_MS,
    );
}

/// Execute NVMe Format NVM command
/// NOTE: Blocked by ASM2362 firmware whitelist -- use XRAM injection (xram.zig) instead.
pub fn formatNvm(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    nsid: u32,
    lbaf: u4,
    ses: u3,
) PassthroughError!PassthroughResult {
    const cdb = buildFormatCdb(nsid, lbaf, ses);
    return execute(
        allocator,
        device_path,
        &cdb,
        0, // No data transfer
        .none,
        300000, // 5 minute timeout for format
    );
}

/// Debug: print CDB as hex
pub fn printCdb(cdb: []const u8) void {
    std.debug.print("CDB ({d} bytes): ", .{cdb.len});
    for (cdb) |byte| {
        std.debug.print("{x:0>2} ", .{byte});
    }
    std.debug.print("\n", .{});
}

test "build Identify Controller CDB" {
    const cdb = buildIdentifyControllerCdb();
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]); // ASMedia opcode
    try std.testing.expectEqual(@as(u8, 0x06), cdb[1]); // NVMe Identify opcode
    try std.testing.expectEqual(@as(u8, 0x01), cdb[3]); // CNS=Controller
}

test "build SMART Log CDB" {
    const cdb = buildSmartLogCdb();
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]); // ASMedia opcode
    try std.testing.expectEqual(@as(u8, 0x02), cdb[1]); // NVMe Get Log Page opcode
    try std.testing.expectEqual(@as(u8, 0x02), cdb[3]); // LID=2 (SMART)
}

test "build Format CDB" {
    const cdb = buildFormatCdb(1, 0, 1); // NSID=1, LBAF=0, SES=1 (User Data Erase)
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]); // ASMedia opcode
    try std.testing.expectEqual(@as(u8, 0x80), cdb[1]); // NVMe Format opcode
    // CDW10 should have SES=1 (bits 11:9) = 0x200
    const cdw10_low = cdb[3];
    try std.testing.expectEqual(@as(u8, 0x00), cdw10_low & 0x0F); // LBAF=0
}

test "build Sanitize CDB" {
    const cdb = buildSanitizeCdb(2); // Block Erase
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]);
    try std.testing.expectEqual(@as(u8, 0x84), cdb[1]); // NVMe Sanitize opcode
    try std.testing.expectEqual(@as(u8, 0x02), cdb[3]); // SANACT=2
}

test "build Security Send CDB" {
    const cdb = buildSecuritySendCdb(0xef, 0x0001, 512); // ATA Password, Set Password
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]); // ASMedia opcode
    try std.testing.expectEqual(@as(u8, 0x81), cdb[1]); // NVMe Security Send opcode
    try std.testing.expectEqual(@as(u8, 0xef), cdb[3]); // Protocol in CDW10[7:0]
}

test "build Security Receive CDB" {
    const cdb = buildSecurityRecvCdb(0x00, 0x0000, 512); // Security Protocol Info
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]); // ASMedia opcode
    try std.testing.expectEqual(@as(u8, 0x82), cdb[1]); // NVMe Security Receive opcode
}

test "build Get Features CDB" {
    // Get Volatile Write Cache feature, current value
    const cdb = buildGetFeaturesCdb(@intFromEnum(FeatureId.volatile_write_cache), 0, 0);
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]); // ASMedia opcode
    try std.testing.expectEqual(@as(u8, 0x0A), cdb[1]); // NVMe Get Features opcode
    try std.testing.expectEqual(@as(u8, 0x06), cdb[3]); // FID=6 (Volatile Write Cache)
}

test "build Get Features CDB with SEL" {
    // Get Write Protect feature, saved value (SEL=2)
    // NOTE: SEL lives in CDW10[10:8] which maps to CDW10[15:8] — this byte range
    // is NOT passed by the 0xe6 CDB format (only [7:0], [23:16], [31:24] are mapped).
    // This is a known limitation: SEL is silently lost through the ASM2362 bridge.
    const cdb = buildGetFeaturesCdb(@intFromEnum(FeatureId.namespace_write_protect), 1, 2);
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]); // ASMedia opcode
    try std.testing.expectEqual(@as(u8, 0x0A), cdb[1]); // NVMe Get Features opcode
    try std.testing.expectEqual(@as(u8, 0x84), cdb[3]); // FID=0x84 (Namespace Write Protect)
    try std.testing.expectEqual(@as(u8, 0x00), cdb[6]); // SEL=2 lost: CDW10[15:8] not mapped in 0xe6 CDB
}

test "build Set Features CDB" {
    // Set Volatile Write Cache enabled
    const cdb = buildSetFeaturesCdb(@intFromEnum(FeatureId.volatile_write_cache), 0, 1, false);
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]); // ASMedia opcode
    try std.testing.expectEqual(@as(u8, 0x09), cdb[1]); // NVMe Set Features opcode
    try std.testing.expectEqual(@as(u8, 0x06), cdb[3]); // FID=6 (Volatile Write Cache)
    // CDW11 (value=1) should be in bytes 12-15 as CDW12 position
    try std.testing.expectEqual(@as(u8, 0x01), cdb[15]); // CDW12[7:0] = 1
}

test "build Set Features CDB with Save" {
    // Set Write Protect with save flag
    const cdb = buildSetFeaturesCdb(@intFromEnum(FeatureId.namespace_write_protect), 1, 0, true);
    try std.testing.expectEqual(@as(u8, 0xe6), cdb[0]); // ASMedia opcode
    try std.testing.expectEqual(@as(u8, 0x09), cdb[1]); // NVMe Set Features opcode
    // CDW10 with SV bit set should have bit 31 = 1
    // Byte 7 = CDW10[31:24], so should have high bit set
    try std.testing.expectEqual(@as(u8, 0x80), cdb[7]); // SV bit in CDW10[31]
}
