//! ASMedia ASM2362 XRAM Direct Access
//!
//! Implements vendor SCSI commands 0xE4 (XDATA Read), 0xE5 (XDATA Write),
//! and 0xE8 (Reset) for direct bridge XRAM manipulation. Used to inject
//! NVMe admin commands into the Admin Submission Queue, bypassing the
//! 0xe6 opcode whitelist that blocks Format, Sanitize, Security, and
//! Features commands.
//!
//! Reference: cyrozap/usb-to-pcie-re ASM2x6x/doc/Notes.md
//!
//! XRAM Memory Map:
//!   0xA000-0xAFFF  NVMe I/O Submission Queue
//!   0xB000-0xB1FF  NVMe Admin Submission Queue (DMA 0x00800000)
//!   0xB200-0xB7FF  PCIe controller MMIO registers
//!   0xF000-0xFFFF  NVMe generic data buffer

const std = @import("std");
const sg_io = @import("../scsi/sg_io.zig");
const sense = @import("../scsi/sense.zig");

// ── SCSI vendor opcodes ──────────────────────────────────────────────

pub const XDATA_READ_OPCODE: u8 = 0xE4;
pub const XDATA_WRITE_OPCODE: u8 = 0xE5;
pub const RESET_OPCODE: u8 = 0xE8;

// ── XRAM address ranges ─────────────────────────────────────────────

pub const IO_SQ_BASE: u16 = 0xA000;
pub const IO_SQ_END: u16 = 0xAFFF;

pub const ADMIN_SQ_BASE: u16 = 0xB000;
pub const ADMIN_SQ_END: u16 = 0xB1FF;
pub const ADMIN_SQ_SIZE: u16 = 0x0200; // 512 bytes
pub const ADMIN_SQ_ENTRY_SIZE: u8 = 64;
pub const ADMIN_SQ_MAX_ENTRIES: u8 = 8;

pub const PCIE_MMIO_BASE: u16 = 0xB200;
pub const PCIE_MMIO_END: u16 = 0xB7FF;

pub const DATA_BUFFER_BASE: u16 = 0xF000;
pub const DATA_BUFFER_END: u16 = 0xFFFF;

pub const XDATA_MAX_READ_LEN: u8 = 255;

// ── PCIe TLP registers (for doorbell writes) ─────────────────────────
// Source: cyrozap/usb-to-pcie-re asm2x6x_tool.py pcie_gen_req()

pub const PCIE_TLP_HEADER: u16 = 0xB210; // 12-byte TLP request header (3x u32 BE)
pub const PCIE_TLP_DATA: u16 = 0xB220; // 4-byte TLP write data (u32 BE)
pub const PCIE_TLP_CPL: u16 = 0xB224; // 12-byte completion header
pub const PCIE_OP: u16 = 0xB254; // 1-byte operation trigger
pub const PCIE_STATUS_B284: u16 = 0xB284; // 1-byte status for cfg req validation
pub const PCIE_CSR: u16 = 0xB296; // 1-byte control/status register
// CSR bits: 0=timeout, 1=completion done, 2=ready

// ── Types ────────────────────────────────────────────────────────────

pub const ResetType = enum(u8) {
    cpu = 0x00,
    pcie = 0x01,

    pub fn toString(self: ResetType) []const u8 {
        return switch (self) {
            .cpu => "CPU reset (full 8051 restart)",
            .pcie => "PCIe soft reset (link re-init)",
        };
    }
};

pub const XramError = error{
    SgIoFailed,
    PermissionDenied,
    DeviceNotFound,
    Timeout,
    ReadFailed,
    WriteFailed,
    ResetFailed,
    AddressOutOfRange,
    InvalidLength,
    VerificationFailed,
    QueueBusy,
    InjectAborted,
    SenseError,
    OutOfMemory,
    PcieTimeout,
    PcieError,
};

pub const XramReadResult = struct {
    data: []u8,
    bytes_read: usize,
    scsi_status: sg_io.ScsiStatus,
    duration_ms: u32,
    success: bool,
};

pub const XramWriteResult = struct {
    scsi_status: sg_io.ScsiStatus,
    duration_ms: u32,
    success: bool,
    verified: bool,
};

/// NVMe Submission Queue Entry (64 bytes, little-endian)
/// Matches NVMe Base Spec 2.0 Figure 88
pub const NvmeSqEntry = struct {
    cdw0: u32, // Opcode[7:0], FUSE[9:8], PSDT[15:14], CID[31:16]
    nsid: u32,
    reserved8: u32 = 0,
    reserved12: u32 = 0,
    mptr_lo: u32 = 0,
    mptr_hi: u32 = 0,
    prp1_lo: u32 = 0,
    prp1_hi: u32 = 0,
    prp2_lo: u32 = 0,
    prp2_hi: u32 = 0,
    cdw10: u32 = 0,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,

    pub fn getOpcode(self: NvmeSqEntry) u8 {
        return @truncate(self.cdw0 & 0xFF);
    }

    pub fn getCommandId(self: NvmeSqEntry) u16 {
        return @truncate((self.cdw0 >> 16) & 0xFFFF);
    }

    pub fn isEmpty(self: NvmeSqEntry) bool {
        return self.cdw0 == 0 and self.nsid == 0 and self.cdw10 == 0 and self.cdw11 == 0;
    }

    /// Serialize to 64 little-endian bytes for XRAM write
    pub fn toBytes(self: NvmeSqEntry) [64]u8 {
        var out: [64]u8 = undefined;
        writeU32Le(out[0..4], self.cdw0);
        writeU32Le(out[4..8], self.nsid);
        writeU32Le(out[8..12], self.reserved8);
        writeU32Le(out[12..16], self.reserved12);
        writeU32Le(out[16..20], self.mptr_lo);
        writeU32Le(out[20..24], self.mptr_hi);
        writeU32Le(out[24..28], self.prp1_lo);
        writeU32Le(out[28..32], self.prp1_hi);
        writeU32Le(out[32..36], self.prp2_lo);
        writeU32Le(out[36..40], self.prp2_hi);
        writeU32Le(out[40..44], self.cdw10);
        writeU32Le(out[44..48], self.cdw11);
        writeU32Le(out[48..52], self.cdw12);
        writeU32Le(out[52..56], self.cdw13);
        writeU32Le(out[56..60], self.cdw14);
        writeU32Le(out[60..64], self.cdw15);
        return out;
    }

    /// Deserialize from 64 little-endian XRAM bytes
    pub fn fromBytes(bytes: []const u8) NvmeSqEntry {
        return .{
            .cdw0 = readU32Le(bytes[0..4]),
            .nsid = readU32Le(bytes[4..8]),
            .reserved8 = readU32Le(bytes[8..12]),
            .reserved12 = readU32Le(bytes[12..16]),
            .mptr_lo = readU32Le(bytes[16..20]),
            .mptr_hi = readU32Le(bytes[20..24]),
            .prp1_lo = readU32Le(bytes[24..28]),
            .prp1_hi = readU32Le(bytes[28..32]),
            .prp2_lo = readU32Le(bytes[32..36]),
            .prp2_hi = readU32Le(bytes[36..40]),
            .cdw10 = readU32Le(bytes[40..44]),
            .cdw11 = readU32Le(bytes[44..48]),
            .cdw12 = readU32Le(bytes[48..52]),
            .cdw13 = readU32Le(bytes[52..56]),
            .cdw14 = readU32Le(bytes[56..60]),
            .cdw15 = readU32Le(bytes[60..64]),
        };
    }

    /// Human-readable opcode description
    pub fn describeOpcode(self: NvmeSqEntry) []const u8 {
        return switch (self.getOpcode()) {
            0x00 => "Delete I/O SQ",
            0x01 => "Create I/O SQ",
            0x02 => "Get Log Page",
            0x04 => "Delete I/O CQ",
            0x05 => "Create I/O CQ",
            0x06 => "Identify",
            0x08 => "Abort",
            0x09 => "Set Features",
            0x0A => "Get Features",
            0x80 => "Format NVM",
            0x81 => "Security Send",
            0x82 => "Security Receive",
            0x84 => "Sanitize",
            else => "Unknown",
        };
    }
};

pub const InjectResult = struct {
    pre_sq_state: [ADMIN_SQ_MAX_ENTRIES]NvmeSqEntry,
    slot_used: u8,
    bytes_written: usize,
    verified: bool,
    doorbell_rung: bool,
    post_sq_state: ?[ADMIN_SQ_MAX_ENTRIES]NvmeSqEntry,
    total_duration_ms: u64,
};

// ── CDB Builders ─────────────────────────────────────────────────────

/// Build XDATA Read CDB (0xE4) — 6 bytes
///
/// Byte layout: E4 [length] [00] [addr_hi] [addr_lo] [00]
/// Source: cyrozap/usb-to-pcie-re asm2x6x_tool.py Asm236x.read()
/// Direction: FROM_DEV, transfer = length bytes
pub fn buildXdataReadCdb(address: u16, length: u8) [6]u8 {
    return .{
        XDATA_READ_OPCODE, // Byte 0: opcode
        length, // Byte 1: number of bytes to read (1-255)
        0x00, // Byte 2: padding
        @truncate(address >> 8), // Byte 3: address high
        @truncate(address & 0xFF), // Byte 4: address low
        0x00, // Byte 5: padding
    };
}

/// Build XDATA Write CDB (0xE5) — 6 bytes
///
/// Byte layout: E5 [value] [00] [addr_hi] [addr_lo] [00]
/// Source: cyrozap/usb-to-pcie-re asm2x6x_tool.py Asm236x.write()
/// Direction: NONE (byte embedded in CDB, no data transfer)
pub fn buildXdataWriteCdb(address: u16, value: u8) [6]u8 {
    return .{
        XDATA_WRITE_OPCODE, // Byte 0: opcode
        value, // Byte 1: byte value to write
        0x00, // Byte 2: padding
        @truncate(address >> 8), // Byte 3: address high
        @truncate(address & 0xFF), // Byte 4: address low
        0x00, // Byte 5: padding
    };
}

/// Build Reset CDB (0xE8) — 12 bytes
///
/// Byte layout: E8 [type] [00 x10]
/// Source: cyrozap/usb-to-pcie-re
/// Direction: NONE
pub fn buildResetCdb(reset_type: ResetType) [12]u8 {
    var cdb = [_]u8{0} ** 12;
    cdb[0] = RESET_OPCODE;
    cdb[1] = @intFromEnum(reset_type);
    return cdb;
}

// ── Address Safety ───────────────────────────────────────────────────

/// Check if an XRAM address is within known mapped regions (safe to read).
/// The entire 64KB XRAM space is readable; some regions may return zeros.
pub fn isAddressSafe(address: u16) bool {
    _ = address;
    return true; // All 0x0000-0xFFFF is readable via 0xE4
}

/// Check if an XRAM address is safe to write.
/// More restrictive: only Admin SQ and data buffer regions.
pub fn isWriteAddressSafe(address: u16) bool {
    if (address >= ADMIN_SQ_BASE and address <= ADMIN_SQ_END) return true;
    if (address >= DATA_BUFFER_BASE and address <= DATA_BUFFER_END) return true;
    return false;
}

// ── Low-Level Operations ─────────────────────────────────────────────

/// Read bytes from XRAM. Maximum single read: 255 bytes.
/// Caller must free returned data with allocator.
pub fn xdataRead(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    address: u16,
    length: u8,
) XramError!XramReadResult {
    if (length == 0) return XramError.InvalidLength;

    const data_buffer = allocator.alloc(u8, length) catch return XramError.OutOfMemory;
    errdefer allocator.free(data_buffer);
    @memset(data_buffer, 0);

    const cdb = buildXdataReadCdb(address, length);
    const result = sg_io.execute(
        device_path,
        &cdb,
        data_buffer,
        .from_dev,
        5000,
    ) catch |err| {
        return switch (err) {
            sg_io.SgError.PermissionDenied => XramError.PermissionDenied,
            sg_io.SgError.InvalidDevice => XramError.DeviceNotFound,
            sg_io.SgError.Timeout => XramError.Timeout,
            else => XramError.ReadFailed,
        };
    };

    return XramReadResult{
        .data = data_buffer,
        .bytes_read = result.bytes_transferred,
        .scsi_status = result.status,
        .duration_ms = result.duration_ms,
        .success = result.success,
    };
}

/// Write a single byte to XRAM. If verify=true, reads back to confirm.
pub fn xdataWrite(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    address: u16,
    value: u8,
    verify: bool,
) XramError!XramWriteResult {
    const cdb = buildXdataWriteCdb(address, value);
    const result = sg_io.execute(
        device_path,
        &cdb,
        null,
        .none,
        5000,
    ) catch |err| {
        return switch (err) {
            sg_io.SgError.PermissionDenied => XramError.PermissionDenied,
            sg_io.SgError.InvalidDevice => XramError.DeviceNotFound,
            sg_io.SgError.Timeout => XramError.Timeout,
            else => XramError.WriteFailed,
        };
    };

    var verified = false;
    if (verify and result.success) {
        const readback = xdataRead(allocator, device_path, address, 1) catch {
            return XramWriteResult{
                .scsi_status = result.status,
                .duration_ms = result.duration_ms,
                .success = true,
                .verified = false,
            };
        };
        defer allocator.free(readback.data);
        if (readback.data.len == 1 and readback.data[0] == value) {
            verified = true;
        } else {
            return XramError.VerificationFailed;
        }
    }

    return XramWriteResult{
        .scsi_status = result.status,
        .duration_ms = result.duration_ms,
        .success = result.success,
        .verified = verified,
    };
}

/// Send a reset command to the bridge controller.
pub fn resetBridge(
    device_path: []const u8,
    reset_type: ResetType,
) XramError!void {
    const cdb = buildResetCdb(reset_type);
    _ = sg_io.execute(
        device_path,
        &cdb,
        null,
        .none,
        10000,
    ) catch |err| {
        return switch (err) {
            sg_io.SgError.PermissionDenied => XramError.PermissionDenied,
            sg_io.SgError.InvalidDevice => XramError.DeviceNotFound,
            sg_io.SgError.Timeout => XramError.Timeout,
            else => XramError.ResetFailed,
        };
    };
}

// ── PCIe TLP Operations (Doorbell) ──────────────────────────────────
// Port of cyrozap/usb-to-pcie-re asm2x6x_tool.py pcie_gen_req()

/// Write a big-endian u32 to XRAM via four 0xE5 commands.
fn writeBe32(device_path: []const u8, address: u16, value: u32) XramError!void {
    const bytes = [4]u8{
        @truncate((value >> 24) & 0xFF),
        @truncate((value >> 16) & 0xFF),
        @truncate((value >> 8) & 0xFF),
        @truncate(value & 0xFF),
    };
    for (bytes, 0..) |b, i| {
        try xdataWriteRaw(device_path, address + @as(u16, @intCast(i)), b);
    }
}

/// Write a single byte to XRAM without verification (for PCIe register pokes).
fn xdataWriteRaw(device_path: []const u8, address: u16, value: u8) XramError!void {
    const cdb = buildXdataWriteCdb(address, value);
    _ = sg_io.execute(
        device_path,
        &cdb,
        null,
        .none,
        5000,
    ) catch |err| {
        return switch (err) {
            sg_io.SgError.PermissionDenied => XramError.PermissionDenied,
            sg_io.SgError.InvalidDevice => XramError.DeviceNotFound,
            sg_io.SgError.Timeout => XramError.Timeout,
            else => XramError.WriteFailed,
        };
    };
}

/// Read a single byte from XRAM (for CSR polling).
fn xdataReadByte(device_path: []const u8, address: u16) XramError!u8 {
    var buf = [1]u8{0};
    const cdb = buildXdataReadCdb(address, 1);
    const result = sg_io.execute(
        device_path,
        &cdb,
        &buf,
        .from_dev,
        5000,
    ) catch |err| {
        return switch (err) {
            sg_io.SgError.PermissionDenied => XramError.PermissionDenied,
            sg_io.SgError.InvalidDevice => XramError.DeviceNotFound,
            sg_io.SgError.Timeout => XramError.Timeout,
            else => XramError.ReadFailed,
        };
    };
    _ = result;
    return buf[0];
}

/// Low-level PCIe TLP request. Mirrors cyrozap pcie_gen_req().
/// For posted writes (fmt_type=0x40), returns immediately after sending.
/// For reads (fmt_type=0x00/0x04/0x05), waits for completion and returns value.
fn pcieGenReq(
    device_path: []const u8,
    fmt_type: u8,
    address: u32,
    value: ?u32,
    size: u8,
) XramError!?u32 {
    const masked_address = address & 0xFFFFFFFC;
    const offset: u5 = @truncate(address & 0x03);
    const size5: u5 = @truncate(size);
    const byte_enable: u32 = (@as(u32, (@as(u32, 1) << size5) - 1) << offset);

    // Write data if present
    if (value) |v| {
        const shifted_value = v << (@as(u5, offset) * 8);
        try writeBe32(device_path, PCIE_TLP_DATA, shifted_value);
    }

    // Write 12-byte TLP header (3x u32 big-endian)
    try writeBe32(device_path, PCIE_TLP_HEADER, @as(u32, 0x00000001) | (@as(u32, fmt_type) << 24));
    try writeBe32(device_path, PCIE_TLP_HEADER + 4, byte_enable);
    try writeBe32(device_path, PCIE_TLP_HEADER + 8, masked_address);

    // Clear timeout bit
    try xdataWriteRaw(device_path, PCIE_CSR, 0x01);

    // Trigger operation
    try xdataWriteRaw(device_path, PCIE_OP, 0x0F);

    // Wait for PCIe ready (bit 2)
    var polls: u32 = 0;
    while (polls < 1000) : (polls += 1) {
        const csr = try xdataReadByte(device_path, PCIE_CSR);
        if (csr & 4 != 0) break;
    } else {
        return XramError.PcieTimeout;
    }

    // Send TLP
    try xdataWriteRaw(device_path, PCIE_CSR, 0x04);

    // Check if posted transaction (memory write = 0x40)
    if ((fmt_type & 0b11011111) == 0b01000000) {
        return null; // Posted write — no completion expected
    }

    // Wait for completion (bit 1)
    polls = 0;
    while (polls < 1000) : (polls += 1) {
        const csr = try xdataReadByte(device_path, PCIE_CSR);
        if (csr & 2 != 0) break;
        if (csr & 1 != 0) {
            try xdataWriteRaw(device_path, PCIE_CSR, 0x01);
            return XramError.PcieTimeout;
        }
    } else {
        return XramError.PcieTimeout;
    }

    // Clear done bit
    try xdataWriteRaw(device_path, PCIE_CSR, 0x02);

    // Read result for read operations
    if (value == null) {
        // Read response from data register
        var resp_buf: [4]u8 = undefined;
        const read_cdb = buildXdataReadCdb(PCIE_TLP_DATA, 4);
        _ = sg_io.execute(
            device_path,
            &read_cdb,
            &resp_buf,
            .from_dev,
            5000,
        ) catch return XramError.ReadFailed;
        // Response is big-endian, shift and mask
        const full_value = (@as(u32, resp_buf[0]) << 24) |
            (@as(u32, resp_buf[1]) << 16) |
            (@as(u32, resp_buf[2]) << 8) |
            @as(u32, resp_buf[3]);
        const shifted = full_value >> (@as(u5, offset) * 8);
        if (size >= 4) return shifted;
        const mask = (@as(u32, 1) << (@as(u5, @truncate(size)) * 8)) - 1;
        return shifted & mask;
    }

    return null;
}

/// Read NVMe BAR0 from PCIe config space (bus=1, dev=0, fn=0).
pub fn readBar0(device_path: []const u8) XramError!u32 {
    // Config read: fmt_type=0x05 (type 1 config read, for bus != 0)
    const cfg_address: u32 = (1 << 24) | (0 << 19) | (0 << 16) | 0x10; // bus=1 dev=0 fn=0 offset=0x10
    const result = try pcieGenReq(device_path, 0x05, cfg_address, null, 4);
    if (result) |bar0_raw| {
        return bar0_raw & 0xFFFFFFF0; // Mask type bits
    }
    return XramError.PcieError;
}

/// Ring the NVMe Admin SQ Tail Doorbell without resetting the bridge.
/// Writes the new tail index to BAR0 + 0x1000 via a PCIe posted memory write.
/// USB connection stays alive — no disconnection.
pub fn ringDoorbell(device_path: []const u8, new_tail: u32) XramError!void {
    const writer = std.io.getStdErr().writer();

    // Step 1: Read BAR0
    const bar0 = readBar0(device_path) catch |err| {
        writer.print("  Failed to read BAR0: {s}\n", .{@errorName(err)}) catch {};
        return err;
    };
    writer.print("  BAR0 = 0x{x:0>8}\n", .{bar0}) catch {};

    // Step 2: Write new tail to Admin SQ Tail Doorbell (BAR0 + 0x1000)
    const doorbell_addr = bar0 + 0x1000;
    writer.print("  Doorbell addr = 0x{x:0>8}, writing tail = {d}\n", .{ doorbell_addr, new_tail }) catch {};

    _ = pcieGenReq(device_path, 0x40, doorbell_addr, new_tail, 4) catch |err| {
        writer.print("  Doorbell write failed: {s}\n", .{@errorName(err)}) catch {};
        return err;
    };
    writer.print("  Doorbell rung successfully (USB alive)\n", .{}) catch {};
}

// ── Range Operations ─────────────────────────────────────────────────

/// Read a contiguous XRAM range, handling the 255-byte-per-read limit.
/// Caller must free returned buffer.
pub fn readRange(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    start_address: u16,
    total_length: u16,
) XramError![]u8 {
    const buffer = allocator.alloc(u8, total_length) catch return XramError.OutOfMemory;
    errdefer allocator.free(buffer);
    @memset(buffer, 0);

    var offset: u16 = 0;
    while (offset < total_length) {
        const remaining = total_length - offset;
        const chunk: u8 = @intCast(@min(remaining, XDATA_MAX_READ_LEN));
        const addr = start_address +% offset;

        const result = try xdataRead(allocator, device_path, addr, chunk);
        defer allocator.free(result.data);

        if (!result.success) return XramError.ReadFailed;

        const copy_len: u16 = @intCast(@min(result.bytes_read, remaining));
        @memcpy(buffer[offset..][0..copy_len], result.data[0..copy_len]);
        offset += copy_len;
    }

    return buffer;
}

/// Write a byte array to XRAM, one byte at a time via 0xE5.
/// Returns count of bytes written.
pub fn writeRange(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    start_address: u16,
    data: []const u8,
    verify: bool,
) XramError!usize {
    for (data, 0..) |byte, i| {
        const addr = start_address +% @as(u16, @intCast(i));
        _ = try xdataWrite(allocator, device_path, addr, byte, verify);
    }
    return data.len;
}

// ── Display ──────────────────────────────────────────────────────────

/// Dump an XRAM region in hex dump format to stdout.
pub fn dumpRegion(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    start_address: u16,
    length: u16,
) XramError!void {
    const data = try readRange(allocator, device_path, start_address, length);
    defer allocator.free(data);
    printHexDump(start_address, data);
}

/// Print a hex dump with addresses, hex bytes, and ASCII.
pub fn printHexDump(base_address: u16, data: []const u8) void {
    const writer = std.io.getStdErr().writer();
    var i: usize = 0;
    while (i < data.len) {
        const addr = base_address +% @as(u16, @intCast(i));
        writer.print("  {x:0>4}: ", .{addr}) catch return;

        // Hex bytes
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            if (i + j < data.len) {
                writer.print("{x:0>2} ", .{data[i + j]}) catch return;
            } else {
                writer.print("   ", .{}) catch return;
            }
        }

        // ASCII
        writer.print(" |", .{}) catch return;
        j = 0;
        while (j < 16 and i + j < data.len) : (j += 1) {
            const b = data[i + j];
            if (b >= 0x20 and b < 0x7f) {
                writer.print("{c}", .{b}) catch return;
            } else {
                writer.print(".", .{}) catch return;
            }
        }
        writer.print("|\n", .{}) catch return;

        i += 16;
    }
}

// ── Admin SQ Inspection ──────────────────────────────────────────────

/// Read and parse all 8 Admin Submission Queue entries from XRAM.
/// Caller must free returned slice.
pub fn readAdminSq(
    allocator: std.mem.Allocator,
    device_path: []const u8,
) XramError![]NvmeSqEntry {
    const raw = try readRange(allocator, device_path, ADMIN_SQ_BASE, ADMIN_SQ_SIZE);
    defer allocator.free(raw);

    var entries = allocator.alloc(NvmeSqEntry, ADMIN_SQ_MAX_ENTRIES) catch return XramError.OutOfMemory;

    for (0..ADMIN_SQ_MAX_ENTRIES) |i| {
        const offset = i * @as(usize, ADMIN_SQ_ENTRY_SIZE);
        entries[i] = NvmeSqEntry.fromBytes(raw[offset..][0..64]);
    }

    return entries;
}

/// Print Admin SQ state in human-readable form.
pub fn printAdminSqState(
    allocator: std.mem.Allocator,
    device_path: []const u8,
) XramError!void {
    const entries = try readAdminSq(allocator, device_path);
    defer allocator.free(entries);

    const writer = std.io.getStdErr().writer();
    writer.print("\nAdmin Submission Queue (0xB000-0xB1FF, {d} entries):\n", .{ADMIN_SQ_MAX_ENTRIES}) catch return;

    for (entries, 0..) |entry, i| {
        const addr = ADMIN_SQ_BASE + @as(u16, @intCast(i)) * @as(u16, ADMIN_SQ_ENTRY_SIZE);
        if (entry.isEmpty()) {
            writer.print("  [{d}] 0x{x:0>4}: (empty)\n", .{ i, addr }) catch return;
        } else {
            writer.print("  [{d}] 0x{x:0>4}: OPC=0x{x:0>2} ({s}) CID={d} NSID=0x{x:0>8} CDW10=0x{x:0>8}\n", .{
                i,
                addr,
                entry.getOpcode(),
                entry.describeOpcode(),
                entry.getCommandId(),
                entry.nsid,
                entry.cdw10,
            }) catch return;
        }
    }
}

// ── XRAM Probe ───────────────────────────────────────────────────────

/// Safe read-only probe of XRAM capabilities.
/// Tests 0xE4, dumps Admin SQ, MMIO header, and data buffer header.
pub fn probeXram(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    verbose: bool,
) XramError!void {
    const writer = std.io.getStdErr().writer();

    writer.print("\nASM2362 XRAM Probe\n", .{}) catch {};
    writer.print("==================\n\n", .{}) catch {};

    // 1. Test basic XDATA Read
    writer.print("1. Testing XDATA Read (0xE4) at 0x0000...\n", .{}) catch {};
    const test_result = xdataRead(allocator, device_path, 0x0000, 16) catch |err| {
        writer.print("   FAILED: {s}\n", .{@errorName(err)}) catch {};
        writer.print("   0xE4 XDATA Read may not be supported on this firmware.\n", .{}) catch {};
        return err;
    };
    defer allocator.free(test_result.data);
    writer.print("   OK: {d} bytes read, SCSI status={s}\n", .{
        test_result.bytes_read,
        @tagName(test_result.scsi_status),
    }) catch {};
    printHexDump(0x0000, test_result.data);

    // 2. Admin SQ state
    writer.print("\n2. Admin Submission Queue:\n", .{}) catch {};
    printAdminSqState(allocator, device_path) catch |err| {
        writer.print("   Failed to read Admin SQ: {s}\n", .{@errorName(err)}) catch {};
    };

    // 3. MMIO registers
    const mmio_len: u16 = if (verbose) 0x0200 else 0x40;
    writer.print("\n3. PCIe MMIO Registers (0xB200, {d} bytes):\n", .{mmio_len}) catch {};
    dumpRegion(allocator, device_path, PCIE_MMIO_BASE, mmio_len) catch |err| {
        writer.print("   Failed to read MMIO: {s}\n", .{@errorName(err)}) catch {};
    };

    // 4. Data buffer
    writer.print("\n4. NVMe Data Buffer (0xF000, 64 bytes):\n", .{}) catch {};
    dumpRegion(allocator, device_path, DATA_BUFFER_BASE, 64) catch |err| {
        writer.print("   Failed to read data buffer: {s}\n", .{@errorName(err)}) catch {};
    };

    writer.print("\nXRAM probe complete.\n", .{}) catch {};
}

// ── NVMe Command Crafting ────────────────────────────────────────────

/// Craft Format NVM (0x80) submission queue entry.
/// No data transfer needed — PRP1/PRP2 = 0.
pub fn craftFormatNvmEntry(nsid: u32, lbaf: u4, ses: u3, command_id: u16) NvmeSqEntry {
    const cdw10: u32 = @as(u32, lbaf) | (@as(u32, ses) << 9);
    return .{
        .cdw0 = @as(u32, 0x80) | (@as(u32, command_id) << 16),
        .nsid = nsid,
        .cdw10 = cdw10,
    };
}

/// Craft Sanitize (0x84) submission queue entry.
/// sanact: 1=Exit Failure, 2=Block Erase, 3=Overwrite, 4=Crypto Erase
pub fn craftSanitizeEntry(sanact: u3, command_id: u16) NvmeSqEntry {
    return .{
        .cdw0 = @as(u32, 0x84) | (@as(u32, command_id) << 16),
        .nsid = 0,
        .cdw10 = @as(u32, sanact),
    };
}

/// Craft Set Features (0x09) submission queue entry.
/// Used to clear write protection (FID=0x84, value=0).
pub fn craftSetFeaturesEntry(fid: u8, nsid: u32, value: u32, save: bool, command_id: u16) NvmeSqEntry {
    var cdw10: u32 = @as(u32, fid);
    if (save) cdw10 |= (1 << 31);
    return .{
        .cdw0 = @as(u32, 0x09) | (@as(u32, command_id) << 16),
        .nsid = nsid,
        .cdw10 = cdw10,
        .cdw11 = value,
    };
}

// ── Injection ────────────────────────────────────────────────────────

/// Find an empty slot in the Admin SQ.
/// Returns slot index (0-7) or QueueBusy if all occupied.
pub fn findEmptySlot(entries: []const NvmeSqEntry) XramError!u8 {
    for (entries, 0..) |entry, i| {
        if (entry.isEmpty()) return @intCast(i);
    }
    return XramError.QueueBusy;
}

/// Inject an NVMe admin command into the Admin SQ via XRAM writes.
///
/// Phases:
///   1. Read current Admin SQ state
///   2. Find empty slot
///   3. Write 64 bytes via 0xE5 (one byte at a time)
///   4. Readback verification
///   5. Ring doorbell (or PCIe reset) — skipped in dry_run
///   6. Read post-injection state
pub fn injectCommand(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    entry: NvmeSqEntry,
    dry_run: bool,
    verbose: bool,
    explicit_slot: ?u8,
    explicit_tail: ?u8,
) XramError!InjectResult {
    const writer = std.io.getStdErr().writer();
    var result = InjectResult{
        .pre_sq_state = undefined,
        .slot_used = 0,
        .bytes_written = 0,
        .verified = false,
        .doorbell_rung = false,
        .post_sq_state = null,
        .total_duration_ms = 0,
    };

    const start_time = std.time.milliTimestamp();

    // Phase 1: Read current Admin SQ
    if (verbose) writer.print("Phase 1: Reading Admin SQ state...\n", .{}) catch {};
    const entries = try readAdminSq(allocator, device_path);
    defer allocator.free(entries);
    @memcpy(&result.pre_sq_state, entries);

    // Phase 2: Find slot
    if (verbose) writer.print("Phase 2: Finding SQ slot...\n", .{}) catch {};
    const slot = if (explicit_slot) |s| blk: {
        if (s >= ADMIN_SQ_MAX_ENTRIES) return XramError.AddressOutOfRange;
        if (verbose) writer.print("  Using explicit slot {d}\n", .{s}) catch {};
        break :blk s;
    } else try findEmptySlot(entries);
    result.slot_used = slot;
    const slot_addr = ADMIN_SQ_BASE + @as(u16, slot) * @as(u16, ADMIN_SQ_ENTRY_SIZE);
    if (verbose) writer.print("  Using slot {d} at XRAM 0x{x:0>4}\n", .{ slot, slot_addr }) catch {};

    // Phase 3: Write command bytes
    if (verbose) writer.print("Phase 3: Writing 64 bytes to XRAM...\n", .{}) catch {};
    const cmd_bytes = entry.toBytes();
    result.bytes_written = try writeRange(allocator, device_path, slot_addr, &cmd_bytes, true);

    // Phase 4: Full readback verification
    if (verbose) writer.print("Phase 4: Verifying...\n", .{}) catch {};
    const readback = try readRange(allocator, device_path, slot_addr, ADMIN_SQ_ENTRY_SIZE);
    defer allocator.free(readback);
    result.verified = std.mem.eql(u8, readback, &cmd_bytes);

    if (!result.verified) {
        writer.print("ERROR: Readback verification failed!\n", .{}) catch {};
        writer.print("  Expected:\n", .{}) catch {};
        printHexDump(slot_addr, &cmd_bytes);
        writer.print("  Got:\n", .{}) catch {};
        printHexDump(slot_addr, readback);
        return XramError.VerificationFailed;
    }

    // Phase 5: Doorbell
    if (dry_run) {
        if (verbose) writer.print("Phase 5: SKIPPED (dry-run) -- doorbell NOT rung\n", .{}) catch {};
    } else {
        // Use explicit tail if provided, otherwise slot+1 (old behavior)
        const new_tail: u32 = if (explicit_tail) |t| @as(u32, t) else result.slot_used + 1;
        if (verbose) writer.print("Phase 5: Ringing doorbell with tail={d}...\n", .{new_tail}) catch {};
        ringDoorbell(device_path, new_tail) catch |err| {
            writer.print("  Doorbell failed: {s}, falling back to PCIe reset\n", .{@errorName(err)}) catch {};
            // Fallback to PCIe reset (will disconnect USB)
            resetBridge(device_path, .pcie) catch {};
        };
        result.doorbell_rung = true;
    }

    // Phase 6: Read post-injection state
    if (verbose) writer.print("Phase 6: Reading post-injection state...\n", .{}) catch {};
    const post_entries = readAdminSq(allocator, device_path) catch null;
    if (post_entries) |pe| {
        var post_state: [ADMIN_SQ_MAX_ENTRIES]NvmeSqEntry = undefined;
        @memcpy(&post_state, pe);
        result.post_sq_state = post_state;
        allocator.free(pe);
    }

    result.total_duration_ms = @intCast(std.time.milliTimestamp() - start_time);
    return result;
}

// ── Helpers ──────────────────────────────────────────────────────────

fn writeU32Le(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val & 0xFF);
    buf[1] = @truncate((val >> 8) & 0xFF);
    buf[2] = @truncate((val >> 16) & 0xFF);
    buf[3] = @truncate((val >> 24) & 0xFF);
}

fn readU32Le(buf: *const [4]u8) u32 {
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

// ── Tests ────────────────────────────────────────────────────────────

test "build XDATA Read CDB" {
    // CDB format: E4 [len] [00] [addr_hi] [addr_lo] [00]
    const cdb = buildXdataReadCdb(0xB000, 64);
    try std.testing.expectEqual(@as(u8, 0xE4), cdb[0]); // opcode
    try std.testing.expectEqual(@as(u8, 64), cdb[1]); // length
    try std.testing.expectEqual(@as(u8, 0x00), cdb[2]); // padding
    try std.testing.expectEqual(@as(u8, 0xB0), cdb[3]); // addr_hi
    try std.testing.expectEqual(@as(u8, 0x00), cdb[4]); // addr_lo
    try std.testing.expectEqual(@as(u8, 0x00), cdb[5]); // padding
    try std.testing.expectEqual(@as(usize, 6), cdb.len);
}

test "build XDATA Read CDB edge addresses" {
    const cdb_min = buildXdataReadCdb(0x0000, 1);
    try std.testing.expectEqual(@as(u8, 1), cdb_min[1]); // length
    try std.testing.expectEqual(@as(u8, 0x00), cdb_min[3]); // addr_hi
    try std.testing.expectEqual(@as(u8, 0x00), cdb_min[4]); // addr_lo

    const cdb_max = buildXdataReadCdb(0xFFFF, 255);
    try std.testing.expectEqual(@as(u8, 255), cdb_max[1]); // length
    try std.testing.expectEqual(@as(u8, 0xFF), cdb_max[3]); // addr_hi
    try std.testing.expectEqual(@as(u8, 0xFF), cdb_max[4]); // addr_lo
}

test "build XDATA Write CDB" {
    // CDB format: E5 [value] [00] [addr_hi] [addr_lo] [00]
    const cdb = buildXdataWriteCdb(0xB042, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xE5), cdb[0]); // opcode
    try std.testing.expectEqual(@as(u8, 0xAB), cdb[1]); // value
    try std.testing.expectEqual(@as(u8, 0x00), cdb[2]); // padding
    try std.testing.expectEqual(@as(u8, 0xB0), cdb[3]); // addr_hi
    try std.testing.expectEqual(@as(u8, 0x42), cdb[4]); // addr_lo
    try std.testing.expectEqual(@as(u8, 0x00), cdb[5]); // padding
    try std.testing.expectEqual(@as(usize, 6), cdb.len);
}

test "build Reset CDB" {
    const cdb_cpu = buildResetCdb(.cpu);
    try std.testing.expectEqual(@as(u8, 0xE8), cdb_cpu[0]);
    try std.testing.expectEqual(@as(u8, 0x00), cdb_cpu[1]);
    try std.testing.expectEqual(@as(usize, 12), cdb_cpu.len);

    const cdb_pcie = buildResetCdb(.pcie);
    try std.testing.expectEqual(@as(u8, 0xE8), cdb_pcie[0]);
    try std.testing.expectEqual(@as(u8, 0x01), cdb_pcie[1]);
}

test "NvmeSqEntry round-trip serialization" {
    const original = craftFormatNvmEntry(0xFFFFFFFF, 0, 1, 0x0100);
    const bytes = original.toBytes();
    const restored = NvmeSqEntry.fromBytes(&bytes);

    try std.testing.expectEqual(original.cdw0, restored.cdw0);
    try std.testing.expectEqual(original.nsid, restored.nsid);
    try std.testing.expectEqual(original.cdw10, restored.cdw10);
    try std.testing.expectEqual(@as(u8, 0x80), restored.getOpcode());
    try std.testing.expectEqual(@as(u16, 0x0100), restored.getCommandId());
}

test "NvmeSqEntry toBytes little-endian" {
    const entry = NvmeSqEntry{
        .cdw0 = 0x01000080, // CID=0x0100, OPC=0x80 (Format NVM)
        .nsid = 0x00000001,
    };
    const bytes = entry.toBytes();

    // CDW0: 0x01000080 in LE = 80 00 00 01
    try std.testing.expectEqual(@as(u8, 0x80), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x01), bytes[3]);

    // NSID: 0x00000001 in LE = 01 00 00 00
    try std.testing.expectEqual(@as(u8, 0x01), bytes[4]);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[5]);
}

test "craft Format NVM entry" {
    const entry = craftFormatNvmEntry(0xFFFFFFFF, 0, 1, 42);
    try std.testing.expectEqual(@as(u8, 0x80), entry.getOpcode());
    try std.testing.expectEqual(@as(u16, 42), entry.getCommandId());
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), entry.nsid);
    // SES=1 at bits 11:9 = 0x200
    try std.testing.expectEqual(@as(u32, 0x200), entry.cdw10);
    try std.testing.expectEqual(@as(u32, 0), entry.prp1_lo);
}

test "craft Sanitize entry" {
    const entry = craftSanitizeEntry(2, 0x200);
    try std.testing.expectEqual(@as(u8, 0x84), entry.getOpcode());
    try std.testing.expectEqual(@as(u16, 0x200), entry.getCommandId());
    try std.testing.expectEqual(@as(u32, 2), entry.cdw10);
    try std.testing.expectEqual(@as(u32, 0), entry.nsid);
}

test "craft Set Features entry" {
    const entry = craftSetFeaturesEntry(0x84, 1, 0, true, 0x300);
    try std.testing.expectEqual(@as(u8, 0x09), entry.getOpcode());
    try std.testing.expectEqual(@as(u32, 1), entry.nsid);
    // FID=0x84 + SV bit 31 = 0x80000084
    try std.testing.expectEqual(@as(u32, 0x80000084), entry.cdw10);
    try std.testing.expectEqual(@as(u32, 0), entry.cdw11); // value=0 (disable WP)
}

test "craft Set Features entry without save" {
    const entry = craftSetFeaturesEntry(0x06, 0, 1, false, 0x400);
    try std.testing.expectEqual(@as(u8, 0x09), entry.getOpcode());
    try std.testing.expectEqual(@as(u32, 0x06), entry.cdw10); // No SV bit
    try std.testing.expectEqual(@as(u32, 1), entry.cdw11);
}

test "NvmeSqEntry isEmpty" {
    const empty = NvmeSqEntry{ .cdw0 = 0, .nsid = 0 };
    try std.testing.expect(empty.isEmpty());

    const nonempty = NvmeSqEntry{ .cdw0 = 0x06, .nsid = 0 };
    try std.testing.expect(!nonempty.isEmpty());
}

test "findEmptySlot all empty" {
    var entries: [8]NvmeSqEntry = undefined;
    for (&entries) |*e| e.* = NvmeSqEntry{ .cdw0 = 0, .nsid = 0 };
    const slot = try findEmptySlot(&entries);
    try std.testing.expectEqual(@as(u8, 0), slot);
}

test "findEmptySlot first occupied" {
    var entries: [8]NvmeSqEntry = undefined;
    for (&entries) |*e| e.* = NvmeSqEntry{ .cdw0 = 0, .nsid = 0 };
    entries[0].cdw0 = 0x01000006; // Identify with CID=0x100
    const slot = try findEmptySlot(&entries);
    try std.testing.expectEqual(@as(u8, 1), slot);
}

test "findEmptySlot all full" {
    var entries: [8]NvmeSqEntry = undefined;
    for (&entries) |*e| e.* = NvmeSqEntry{ .cdw0 = 0x00010006, .nsid = 0 };
    const result = findEmptySlot(&entries);
    try std.testing.expectError(XramError.QueueBusy, result);
}

test "address safety" {
    // All read addresses are safe (full 64KB XRAM is readable via 0xE4)
    try std.testing.expect(isAddressSafe(0xB000));
    try std.testing.expect(isAddressSafe(0x0000));
    try std.testing.expect(isAddressSafe(0x5000));
    try std.testing.expect(isAddressSafe(0xFFFF));

    // Write safety (more restrictive — only Admin SQ and data buffer)
    try std.testing.expect(isWriteAddressSafe(0xB000));
    try std.testing.expect(isWriteAddressSafe(0xB03F));
    try std.testing.expect(isWriteAddressSafe(0xF000));
    try std.testing.expect(!isWriteAddressSafe(0xA000)); // I/O SQ: no writes
    try std.testing.expect(!isWriteAddressSafe(0xB200)); // MMIO: no writes
    try std.testing.expect(!isWriteAddressSafe(0x0000));
}

test "writeU32Le and readU32Le round-trip" {
    var buf: [4]u8 = undefined;
    writeU32Le(&buf, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u8, 0xEF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xBE), buf[1]);
    try std.testing.expectEqual(@as(u8, 0xAD), buf[2]);
    try std.testing.expectEqual(@as(u8, 0xDE), buf[3]);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), readU32Le(&buf));
}
