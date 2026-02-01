//! NVMe Command Helpers via ASM2362 Passthrough
//!
//! High-level wrappers for common NVMe admin commands, with output parsing
//! and JSON serialization support.

const std = @import("std");
const passthrough = @import("passthrough.zig");
const sg_io = @import("../scsi/sg_io.zig");

/// NVMe SMART/Health Log structure (512 bytes)
pub const SmartLog = extern struct {
    /// Critical Warning (Bit 0: spare below threshold, Bit 1: temp exceeded,
    /// Bit 2: reliability degraded, Bit 3: read-only mode, Bit 4: volatile backup failed)
    critical_warning: u8,
    /// Composite Temperature (Kelvin)
    temperature: [2]u8,
    /// Available Spare (percentage)
    available_spare: u8,
    /// Available Spare Threshold (percentage)
    available_spare_threshold: u8,
    /// Percentage Used (may exceed 100%)
    percentage_used: u8,
    /// Endurance Group Critical Warning Summary
    endurance_grp_critical: u8,
    /// Reserved
    reserved7: [25]u8,
    /// Data Units Read (in 1000 x 512 byte units)
    data_units_read: [16]u8,
    /// Data Units Written (in 1000 x 512 byte units)
    data_units_written: [16]u8,
    /// Host Read Commands
    host_read_commands: [16]u8,
    /// Host Write Commands
    host_write_commands: [16]u8,
    /// Controller Busy Time (minutes)
    controller_busy_time: [16]u8,
    /// Power Cycles
    power_cycles: [16]u8,
    /// Power On Hours
    power_on_hours: [16]u8,
    /// Unsafe Shutdowns
    unsafe_shutdowns: [16]u8,
    /// Media and Data Integrity Errors
    media_errors: [16]u8,
    /// Number of Error Information Log Entries
    num_err_log_entries: [16]u8,
    /// Warning Composite Temperature Time (minutes)
    warning_temp_time: u32,
    /// Critical Composite Temperature Time (minutes)
    critical_temp_time: u32,
    /// Temperature Sensors (Kelvin, 0 = not implemented)
    temp_sensor: [8]u16,
    /// Thermal Management Temperature 1 Transition Count
    thm_temp1_trans_count: u32,
    /// Thermal Management Temperature 2 Transition Count
    thm_temp2_trans_count: u32,
    /// Total Time For Thermal Management Temperature 1
    thm_temp1_total_time: u32,
    /// Total Time For Thermal Management Temperature 2
    thm_temp2_total_time: u32,
    /// Reserved
    reserved232: [280]u8,

    comptime {
        std.debug.assert(@sizeOf(SmartLog) == 512);
    }

    /// Read a 128-bit counter as u128
    fn read128(bytes: [16]u8) u128 {
        var result: u128 = 0;
        for (bytes, 0..) |byte, i| {
            result |= @as(u128, byte) << @intCast(i * 8);
        }
        return result;
    }

    /// Get temperature in Celsius
    pub fn getTemperatureCelsius(self: *const SmartLog) i32 {
        const kelvin = @as(u16, self.temperature[0]) | (@as(u16, self.temperature[1]) << 8);
        return @as(i32, kelvin) - 273;
    }

    /// Check if drive is in read-only mode
    pub fn isReadOnly(self: *const SmartLog) bool {
        return (self.critical_warning & 0x08) != 0;
    }

    /// Check if spare capacity is below threshold
    pub fn isSpareBelowThreshold(self: *const SmartLog) bool {
        return (self.critical_warning & 0x01) != 0;
    }

    /// Get data read in GB
    pub fn getDataReadGB(self: *const SmartLog) u64 {
        const units = read128(self.data_units_read);
        // Each unit is 1000 * 512 bytes = 512KB
        return @intCast(units * 512 / 1000000);
    }

    /// Get data written in GB
    pub fn getDataWrittenGB(self: *const SmartLog) u64 {
        const units = read128(self.data_units_written);
        return @intCast(units * 512 / 1000000);
    }

    /// Get power cycles
    pub fn getPowerCycles(self: *const SmartLog) u64 {
        return @intCast(read128(self.power_cycles));
    }

    /// Get power on hours
    pub fn getPowerOnHours(self: *const SmartLog) u64 {
        return @intCast(read128(self.power_on_hours));
    }

    /// Get unsafe shutdowns
    pub fn getUnsafeShutdowns(self: *const SmartLog) u64 {
        return @intCast(read128(self.unsafe_shutdowns));
    }

    /// Get media errors
    pub fn getMediaErrors(self: *const SmartLog) u64 {
        return @intCast(read128(self.media_errors));
    }
};

/// NVMe Identify Controller structure (partial - key fields)
pub const IdentifyController = extern struct {
    /// PCI Vendor ID
    vid: u16,
    /// PCI Subsystem Vendor ID
    ssvid: u16,
    /// Serial Number (20 bytes, space-padded ASCII)
    sn: [20]u8,
    /// Model Number (40 bytes, space-padded ASCII)
    mn: [40]u8,
    /// Firmware Revision (8 bytes)
    fr: [8]u8,
    /// Recommended Arbitration Burst
    rab: u8,
    /// IEEE OUI Identifier
    ieee: [3]u8,
    /// Controller Multi-Path I/O and Namespace Sharing Capabilities
    cmic: u8,
    /// Maximum Data Transfer Size
    mdts: u8,
    /// Controller ID
    cntlid: u16,
    /// Version
    ver: u32,
    /// RTD3 Resume Latency
    rtd3r: u32,
    /// RTD3 Entry Latency
    rtd3e: u32,
    /// Optional Asynchronous Events Supported
    oaes: u32,
    /// Controller Attributes
    ctratt: u32,
    /// Read Recovery Levels Supported
    rrls: u16,
    /// Reserved
    reserved102: [9]u8,
    /// Controller Type
    cntrltype: u8,
    /// FRU Globally Unique Identifier
    fguid: [16]u8,
    /// Command Retry Delay Time 1
    crdt1: u16,
    /// Command Retry Delay Time 2
    crdt2: u16,
    /// Command Retry Delay Time 3
    crdt3: u16,
    /// Reserved
    reserved134: [122]u8,
    /// Optional Admin Command Support
    oacs: u16,
    /// Abort Command Limit
    acl: u8,
    /// Asynchronous Event Request Limit
    aerl: u8,
    /// Firmware Updates
    frmw: u8,
    /// Log Page Attributes
    lpa: u8,
    /// Error Log Page Entries
    elpe: u8,
    /// Number of Power States Support
    npss: u8,
    /// Admin Vendor Specific Command Configuration
    avscc: u8,
    /// Autonomous Power State Transition Attributes
    apsta: u8,
    /// Warning Composite Temperature Threshold
    wctemp: u16,
    /// Critical Composite Temperature Threshold
    cctemp: u16,
    /// Maximum Time for Firmware Activation
    mtfa: u16,
    /// Host Memory Buffer Preferred Size
    hmpre: u32,
    /// Host Memory Buffer Minimum Size
    hmmin: u32,
    /// Total NVM Capacity (bytes, 128-bit)
    tnvmcap: [16]u8,
    /// Unallocated NVM Capacity (bytes, 128-bit)
    unvmcap: [16]u8,
    /// Replay Protected Memory Block Support
    rpmbs: u32,
    /// Extended Device Self-test Time
    edstt: u16,
    /// Device Self-test Options
    dsto: u8,
    /// Firmware Update Granularity
    fwug: u8,
    /// Keep Alive Support
    kas: u16,
    /// Host Controlled Thermal Management Attributes
    hctma: u16,
    /// Minimum Thermal Management Temperature
    mntmt: u16,
    /// Maximum Thermal Management Temperature
    mxtmt: u16,
    /// Sanitize Capabilities
    sanicap: u32,
    /// Host Memory Buffer Minimum Descriptor Entry Size
    hmminds: u32,
    /// Host Memory Maximum Descriptors Entries
    hmmaxd: u16,
    /// NVM Set Identifier Maximum
    nsetidmax: u16,
    /// Endurance Group Identifier Maximum
    endgidmax: u16,
    /// ANA Transition Time
    anatt: u8,
    /// Asymmetric Namespace Access Capabilities
    anacap: u8,
    /// ANA Group Identifier Maximum
    anagrpmax: u32,
    /// Number of ANA Group Identifiers
    nanagrpid: u32,
    /// Persistent Event Log Size
    pels: u32,
    /// Reserved
    reserved356: [156]u8,
    /// Submission Queue Entry Size
    sqes: u8,
    /// Completion Queue Entry Size
    cqes: u8,
    /// Maximum Outstanding Commands
    maxcmd: u16,
    /// Number of Namespaces
    nn: u32,
    /// Optional NVM Command Support
    oncs: u16,
    /// Fused Operation Support
    fuses: u16,
    /// Format NVM Attributes
    fna: u8,
    /// Volatile Write Cache
    vwc: u8,
    /// Atomic Write Unit Normal
    awun: u16,
    /// Atomic Write Unit Power Fail
    awupf: u16,
    /// NVM Vendor Specific Command Configuration
    nvscc: u8,
    /// Namespace Write Protection Capabilities
    nwpc: u8,
    /// Atomic Compare & Write Unit
    acwu: u16,
    /// Reserved
    reserved534: [2]u8,
    /// SGL Support
    sgls: u32,
    /// Maximum Number of Allowed Namespaces
    mnan: u32,
    /// Reserved
    reserved544: [224]u8,
    /// NVM Subsystem NVMe Qualified Name
    subnqn: [256]u8,
    /// Reserved and vendor specific...
    reserved1024: [3072]u8,

    /// Get serial number as trimmed string
    pub fn getSerialNumber(self: *const IdentifyController) []const u8 {
        return std.mem.trimRight(u8, &self.sn, " ");
    }

    /// Get model number as trimmed string
    pub fn getModelNumber(self: *const IdentifyController) []const u8 {
        return std.mem.trimRight(u8, &self.mn, " ");
    }

    /// Get firmware revision as trimmed string
    pub fn getFirmwareRevision(self: *const IdentifyController) []const u8 {
        return std.mem.trimRight(u8, &self.fr, " ");
    }

    /// Get total NVM capacity in bytes
    pub fn getTotalCapacity(self: *const IdentifyController) u128 {
        var result: u128 = 0;
        for (self.tnvmcap, 0..) |byte, i| {
            result |= @as(u128, byte) << @intCast(i * 8);
        }
        return result;
    }

    /// Check if Format NVM command is supported
    pub fn supportsFormat(self: *const IdentifyController) bool {
        return (self.oacs & 0x02) != 0;
    }

    /// Check if Sanitize command is supported
    pub fn supportsSanitize(self: *const IdentifyController) bool {
        return self.sanicap != 0;
    }

    /// Check if Crypto Erase is supported
    pub fn supportsCryptoErase(self: *const IdentifyController) bool {
        return (self.sanicap & 0x01) != 0;
    }

    /// Check if Block Erase is supported
    pub fn supportsBlockErase(self: *const IdentifyController) bool {
        return (self.sanicap & 0x02) != 0;
    }
};

/// Get SMART log from device and print to stdout
pub fn getSmartLog(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    json_output: bool,
) !void {
    const result = passthrough.getSmartLog(allocator, device_path) catch |err| {
        std.debug.print("Failed to get SMART log: {s}\n", .{@errorName(err)});
        return err;
    };
    defer if (result.data) |data| allocator.free(data);

    if (result.data) |data| {
        if (data.len < @sizeOf(SmartLog)) {
            std.debug.print("Error: Insufficient data returned ({d} bytes)\n", .{data.len});
            return;
        }

        const smart: *const SmartLog = @ptrCast(@alignCast(data.ptr));

        if (json_output) {
            printSmartLogJson(smart);
        } else {
            printSmartLogHuman(smart);
        }
    } else {
        std.debug.print("No data returned from SMART log command\n", .{});
    }
}

fn printSmartLogHuman(smart: *const SmartLog) void {
    std.debug.print("\nNVMe SMART/Health Log:\n", .{});
    std.debug.print("======================\n", .{});
    std.debug.print("Critical Warning:        0x{x:0>2}", .{smart.critical_warning});
    if (smart.critical_warning == 0) {
        std.debug.print(" (OK)\n", .{});
    } else {
        std.debug.print(" (WARNING!)\n", .{});
        if (smart.isSpareBelowThreshold())
            std.debug.print("  - Available spare below threshold\n", .{});
        if ((smart.critical_warning & 0x02) != 0)
            std.debug.print("  - Temperature exceeded threshold\n", .{});
        if ((smart.critical_warning & 0x04) != 0)
            std.debug.print("  - NVM subsystem reliability degraded\n", .{});
        if (smart.isReadOnly())
            std.debug.print("  - Media in READ-ONLY mode\n", .{});
        if ((smart.critical_warning & 0x10) != 0)
            std.debug.print("  - Volatile memory backup failed\n", .{});
    }
    std.debug.print("Temperature:             {} C\n", .{smart.getTemperatureCelsius()});
    std.debug.print("Available Spare:         {}%\n", .{smart.available_spare});
    std.debug.print("Available Spare Thresh:  {}%\n", .{smart.available_spare_threshold});
    std.debug.print("Percentage Used:         {}%\n", .{smart.percentage_used});
    std.debug.print("Data Read:               {} GB\n", .{smart.getDataReadGB()});
    std.debug.print("Data Written:            {} GB\n", .{smart.getDataWrittenGB()});
    std.debug.print("Power Cycles:            {}\n", .{smart.getPowerCycles()});
    std.debug.print("Power On Hours:          {}\n", .{smart.getPowerOnHours()});
    std.debug.print("Unsafe Shutdowns:        {}\n", .{smart.getUnsafeShutdowns()});
    std.debug.print("Media Errors:            {}\n", .{smart.getMediaErrors()});
    std.debug.print("\n", .{});
}

fn printSmartLogJson(smart: *const SmartLog) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("{{\n", .{}) catch return;
    stdout.print("  \"critical_warning\": {},\n", .{smart.critical_warning}) catch return;
    stdout.print("  \"temperature_celsius\": {},\n", .{smart.getTemperatureCelsius()}) catch return;
    stdout.print("  \"available_spare\": {},\n", .{smart.available_spare}) catch return;
    stdout.print("  \"available_spare_threshold\": {},\n", .{smart.available_spare_threshold}) catch return;
    stdout.print("  \"percentage_used\": {},\n", .{smart.percentage_used}) catch return;
    stdout.print("  \"data_read_gb\": {},\n", .{smart.getDataReadGB()}) catch return;
    stdout.print("  \"data_written_gb\": {},\n", .{smart.getDataWrittenGB()}) catch return;
    stdout.print("  \"power_cycles\": {},\n", .{smart.getPowerCycles()}) catch return;
    stdout.print("  \"power_on_hours\": {},\n", .{smart.getPowerOnHours()}) catch return;
    stdout.print("  \"unsafe_shutdowns\": {},\n", .{smart.getUnsafeShutdowns()}) catch return;
    stdout.print("  \"media_errors\": {},\n", .{smart.getMediaErrors()}) catch return;
    stdout.print("  \"read_only_mode\": {}\n", .{smart.isReadOnly()}) catch return;
    stdout.print("}}\n", .{}) catch return;
}

test "SmartLog size" {
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(SmartLog));
}
