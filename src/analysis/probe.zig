//! Device Capability Probing
//!
//! Probe a USB-attached NVMe device to determine:
//! - Bridge controller type (ASM2362, JMS583, etc.)
//! - Supported passthrough mechanisms
//! - NVMe capabilities exposed through the bridge

const std = @import("std");
const sg_io = @import("../scsi/sg_io.zig");
const sense = @import("../scsi/sense.zig");
const passthrough = @import("../asm2362/passthrough.zig");

/// Known USB-NVMe bridge controllers
pub const BridgeType = enum {
    unknown,
    asmedia_asm2362,
    asmedia_asm2364,
    jmicron_jms583,
    jmicron_jms586,
    realtek_rtl9210,
    via_vl716,

    pub fn toString(self: BridgeType) []const u8 {
        return switch (self) {
            .unknown => "Unknown",
            .asmedia_asm2362 => "ASMedia ASM2362",
            .asmedia_asm2364 => "ASMedia ASM2364",
            .jmicron_jms583 => "JMicron JMS583",
            .jmicron_jms586 => "JMicron JMS586",
            .realtek_rtl9210 => "Realtek RTL9210",
            .via_vl716 => "VIA VL716",
        };
    }
};

/// Probe results
pub const ProbeResult = struct {
    /// Detected bridge type
    bridge_type: BridgeType,
    /// SCSI vendor identification
    scsi_vendor: [8]u8,
    /// SCSI product identification
    scsi_product: [16]u8,
    /// SCSI revision
    scsi_revision: [4]u8,
    /// Device capacity in bytes
    capacity_bytes: u64,
    /// Block size in bytes
    block_size: u32,
    /// Test Unit Ready successful
    unit_ready: bool,
    /// ASMedia passthrough test result
    asm_passthrough_works: bool,
    /// Specific passthrough error (if any)
    passthrough_error: ?[]const u8,
    /// SMART log accessible
    smart_accessible: bool,
    /// Identify accessible
    identify_accessible: bool,
};

/// Probe device capabilities
pub fn probeDevice(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    json_output: bool,
) !void {
    std.debug.print("Probing device: {s}\n", .{device_path});
    std.debug.print("==================================\n\n", .{});

    var result = ProbeResult{
        .bridge_type = .unknown,
        .scsi_vendor = [_]u8{' '} ** 8,
        .scsi_product = [_]u8{' '} ** 16,
        .scsi_revision = [_]u8{' '} ** 4,
        .capacity_bytes = 0,
        .block_size = 0,
        .unit_ready = false,
        .asm_passthrough_works = false,
        .passthrough_error = null,
        .smart_accessible = false,
        .identify_accessible = false,
    };

    // 1. Test Unit Ready
    std.debug.print("1. Testing Unit Ready...\n", .{});
    result.unit_ready = testUnitReady(device_path);
    std.debug.print("   Result: {s}\n\n", .{if (result.unit_ready) "READY" else "NOT READY"});

    // 2. SCSI Inquiry
    std.debug.print("2. SCSI Inquiry...\n", .{});
    if (doInquiry(device_path, &result)) {
        std.debug.print("   Vendor:   {s}\n", .{std.mem.trimRight(u8, &result.scsi_vendor, " ")});
        std.debug.print("   Product:  {s}\n", .{std.mem.trimRight(u8, &result.scsi_product, " ")});
        std.debug.print("   Revision: {s}\n", .{std.mem.trimRight(u8, &result.scsi_revision, " ")});

        // Detect bridge type from vendor/product
        result.bridge_type = detectBridgeType(&result.scsi_vendor, &result.scsi_product);
        std.debug.print("   Bridge:   {s}\n", .{result.bridge_type.toString()});
    } else {
        std.debug.print("   Failed to get INQUIRY data\n", .{});
    }
    std.debug.print("\n", .{});

    // 3. Read Capacity
    std.debug.print("3. Read Capacity...\n", .{});
    if (doReadCapacity(device_path, &result)) {
        const capacity_gb = result.capacity_bytes / 1000000000;
        std.debug.print("   Capacity:   {} bytes ({} GB)\n", .{ result.capacity_bytes, capacity_gb });
        std.debug.print("   Block Size: {} bytes\n", .{result.block_size});
    } else {
        std.debug.print("   Failed to read capacity\n", .{});
    }
    std.debug.print("\n", .{});

    // 4. Test ASMedia passthrough
    std.debug.print("4. Testing ASMedia 0xe6 Passthrough...\n", .{});
    testAsmPassthrough(allocator, device_path, &result);
    std.debug.print("   Result: {s}\n", .{if (result.asm_passthrough_works) "WORKING" else "FAILED"});
    if (result.passthrough_error) |err| {
        std.debug.print("   Error:  {s}\n", .{err});
    }
    std.debug.print("\n", .{});

    // 5. Summary
    std.debug.print("==================================\n", .{});
    std.debug.print("PROBE SUMMARY\n", .{});
    std.debug.print("==================================\n", .{});
    std.debug.print("Device:            {s}\n", .{device_path});
    std.debug.print("Bridge Controller: {s}\n", .{result.bridge_type.toString()});
    std.debug.print("Unit Ready:        {s}\n", .{if (result.unit_ready) "Yes" else "No"});
    std.debug.print("ASM Passthrough:   {s}\n", .{if (result.asm_passthrough_works) "Yes" else "No"});
    std.debug.print("SMART Accessible:  {s}\n", .{if (result.smart_accessible) "Yes" else "No"});
    std.debug.print("Identify Access:   {s}\n", .{if (result.identify_accessible) "Yes" else "No"});
    std.debug.print("\n", .{});

    if (!result.asm_passthrough_works) {
        std.debug.print("RECOMMENDATION:\n", .{});
        if (result.passthrough_error != null and
            std.mem.indexOf(u8, result.passthrough_error.?, "Medium not present") != null)
        {
            std.debug.print("  The drive reports 'Medium not present' for admin commands.\n", .{});
            std.debug.print("  This indicates FTL corruption with controller protection.\n", .{});
            std.debug.print("\n", .{});
            std.debug.print("  Next steps:\n", .{});
            std.debug.print("  1. Try Windows SP Toolbox for vendor-specific recovery\n", .{});
            std.debug.print("  2. Connect directly to M.2 slot (bypass USB bridge)\n", .{});
            std.debug.print("  3. Extended power cycle (5+ minutes unpowered)\n", .{});
            std.debug.print("  4. Use Frida to capture SP Toolbox commands (see frida/hooks.js)\n", .{});
        } else {
            std.debug.print("  ASMedia passthrough not working. Try:\n", .{});
            std.debug.print("  1. Check if device is actually an ASM2362 bridge\n", .{});
            std.debug.print("  2. Try smartctl -d sntasmedia for comparison\n", .{});
            std.debug.print("  3. Check dmesg for USB/SCSI errors\n", .{});
        }
    }

    if (json_output) {
        printProbeJson(&result);
    }
}

fn testUnitReady(device_path: []const u8) bool {
    const cdb = sg_io.buildTestUnitReadyCdb();
    const result = sg_io.execute(device_path, &cdb, null, .none, 5000) catch {
        return false;
    };
    return result.success;
}

fn doInquiry(device_path: []const u8, probe_result: *ProbeResult) bool {
    var buffer: [96]u8 = [_]u8{0} ** 96;
    const cdb = sg_io.buildInquiryCdb(96);

    const result = sg_io.execute(device_path, &cdb, &buffer, .from_dev, 5000) catch {
        return false;
    };

    if (!result.success or result.bytes_transferred < 36) {
        return false;
    }

    // Parse standard INQUIRY response
    // Vendor ID: bytes 8-15
    @memcpy(&probe_result.scsi_vendor, buffer[8..16]);
    // Product ID: bytes 16-31
    @memcpy(&probe_result.scsi_product, buffer[16..32]);
    // Revision: bytes 32-35
    @memcpy(&probe_result.scsi_revision, buffer[32..36]);

    return true;
}

fn doReadCapacity(device_path: []const u8, probe_result: *ProbeResult) bool {
    var buffer: [32]u8 = [_]u8{0} ** 32;
    const cdb = sg_io.buildReadCapacity16Cdb();

    const result = sg_io.execute(device_path, &cdb, &buffer, .from_dev, 5000) catch {
        return false;
    };

    if (!result.success or result.bytes_transferred < 12) {
        return false;
    }

    // Parse READ CAPACITY(16) response
    // Returned Logical Block Address (8 bytes, big-endian)
    var last_lba: u64 = 0;
    for (buffer[0..8]) |byte| {
        last_lba = (last_lba << 8) | byte;
    }

    // Block Length (4 bytes, big-endian)
    var block_len: u32 = 0;
    for (buffer[8..12]) |byte| {
        block_len = (block_len << 8) | byte;
    }

    probe_result.block_size = block_len;
    probe_result.capacity_bytes = (last_lba + 1) * block_len;

    return true;
}

fn testAsmPassthrough(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    probe_result: *ProbeResult,
) void {
    // Try to get SMART log via ASMedia passthrough
    const result = passthrough.getSmartLog(allocator, device_path) catch |err| {
        probe_result.asm_passthrough_works = false;
        probe_result.passthrough_error = switch (err) {
            passthrough.PassthroughError.MediumNotPresent => "Medium not present",
            passthrough.PassthroughError.InvalidCommand => "Invalid command",
            passthrough.PassthroughError.WriteProtected => "Write protected",
            passthrough.PassthroughError.PermissionDenied => "Permission denied",
            passthrough.PassthroughError.DeviceNotFound => "Device not found",
            passthrough.PassthroughError.Timeout => "Timeout",
            else => "Unknown error",
        };
        return;
    };

    if (result.data) |data| {
        allocator.free(data);
        probe_result.asm_passthrough_works = true;
        probe_result.smart_accessible = true;
    }
}

fn detectBridgeType(vendor: *const [8]u8, product: *const [16]u8) BridgeType {
    const vendor_str = std.mem.trimRight(u8, vendor, " ");
    const product_str = std.mem.trimRight(u8, product, " ");

    // Check vendor strings
    if (std.mem.indexOf(u8, vendor_str, "ASMedia") != null or
        std.mem.indexOf(u8, product_str, "ASM") != null)
    {
        if (std.mem.indexOf(u8, product_str, "2362") != null) {
            return .asmedia_asm2362;
        }
        if (std.mem.indexOf(u8, product_str, "2364") != null) {
            return .asmedia_asm2364;
        }
        return .asmedia_asm2362; // Default ASMedia
    }

    if (std.mem.indexOf(u8, vendor_str, "JMicron") != null or
        std.mem.indexOf(u8, product_str, "JMS") != null)
    {
        if (std.mem.indexOf(u8, product_str, "583") != null) {
            return .jmicron_jms583;
        }
        if (std.mem.indexOf(u8, product_str, "586") != null) {
            return .jmicron_jms586;
        }
        return .jmicron_jms583;
    }

    if (std.mem.indexOf(u8, vendor_str, "Realtek") != null or
        std.mem.indexOf(u8, product_str, "RTL") != null)
    {
        return .realtek_rtl9210;
    }

    if (std.mem.indexOf(u8, vendor_str, "VIA") != null) {
        return .via_vl716;
    }

    return .unknown;
}

fn printProbeJson(result: *const ProbeResult) void {
    const stdout = std.io.getStdOut().writer();

    stdout.print("\n{{\n", .{}) catch return;
    stdout.print("  \"bridge_type\": \"{s}\",\n", .{result.bridge_type.toString()}) catch return;
    stdout.print("  \"scsi_vendor\": \"{s}\",\n", .{std.mem.trimRight(u8, &result.scsi_vendor, " ")}) catch return;
    stdout.print("  \"scsi_product\": \"{s}\",\n", .{std.mem.trimRight(u8, &result.scsi_product, " ")}) catch return;
    stdout.print("  \"scsi_revision\": \"{s}\",\n", .{std.mem.trimRight(u8, &result.scsi_revision, " ")}) catch return;
    stdout.print("  \"capacity_bytes\": {},\n", .{result.capacity_bytes}) catch return;
    stdout.print("  \"block_size\": {},\n", .{result.block_size}) catch return;
    stdout.print("  \"unit_ready\": {},\n", .{result.unit_ready}) catch return;
    stdout.print("  \"asm_passthrough_works\": {},\n", .{result.asm_passthrough_works}) catch return;
    stdout.print("  \"smart_accessible\": {},\n", .{result.smart_accessible}) catch return;
    stdout.print("  \"identify_accessible\": {}\n", .{result.identify_accessible}) catch return;
    stdout.print("}}\n", .{}) catch return;
}
