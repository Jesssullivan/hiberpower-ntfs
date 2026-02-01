//! SCSI Sense Data Parsing
//!
//! Parse SCSI sense data returned from CHECK CONDITION status.
//! Supports both fixed format (0x70, 0x71) and descriptor format (0x72, 0x73).

const std = @import("std");

/// Sense key values (4 bits)
pub const SenseKey = enum(u4) {
    no_sense = 0x0,
    recovered_error = 0x1,
    not_ready = 0x2,
    medium_error = 0x3,
    hardware_error = 0x4,
    illegal_request = 0x5,
    unit_attention = 0x6,
    data_protect = 0x7,
    blank_check = 0x8,
    vendor_specific = 0x9,
    copy_aborted = 0xa,
    aborted_command = 0xb,
    reserved_c = 0xc,
    volume_overflow = 0xd,
    miscompare = 0xe,
    completed = 0xf,

    pub fn toString(self: SenseKey) []const u8 {
        return switch (self) {
            .no_sense => "NO SENSE",
            .recovered_error => "RECOVERED ERROR",
            .not_ready => "NOT READY",
            .medium_error => "MEDIUM ERROR",
            .hardware_error => "HARDWARE ERROR",
            .illegal_request => "ILLEGAL REQUEST",
            .unit_attention => "UNIT ATTENTION",
            .data_protect => "DATA PROTECT",
            .blank_check => "BLANK CHECK",
            .vendor_specific => "VENDOR SPECIFIC",
            .copy_aborted => "COPY ABORTED",
            .aborted_command => "ABORTED COMMAND",
            .reserved_c => "RESERVED",
            .volume_overflow => "VOLUME OVERFLOW",
            .miscompare => "MISCOMPARE",
            .completed => "COMPLETED",
        };
    }
};

/// Common Additional Sense Codes (ASC)
pub const Asc = struct {
    // ASC 0x00
    pub const NO_ADDITIONAL_SENSE: u8 = 0x00;
    // ASC 0x04 - NOT READY
    pub const NOT_READY_CAUSE_NOT_REPORTABLE: u8 = 0x04;
    // ASC 0x20
    pub const INVALID_COMMAND_OPERATION_CODE: u8 = 0x20;
    // ASC 0x24
    pub const INVALID_FIELD_IN_CDB: u8 = 0x24;
    // ASC 0x25
    pub const LOGICAL_UNIT_NOT_SUPPORTED: u8 = 0x25;
    // ASC 0x26
    pub const INVALID_FIELD_IN_PARAMETER_LIST: u8 = 0x26;
    // ASC 0x27
    pub const WRITE_PROTECTED: u8 = 0x27;
    // ASC 0x28
    pub const NOT_READY_TO_READY_TRANSITION: u8 = 0x28;
    // ASC 0x29
    pub const POWER_ON_RESET_OR_BUS_DEVICE_RESET: u8 = 0x29;
    // ASC 0x2A
    pub const PARAMETERS_CHANGED: u8 = 0x2A;
    // ASC 0x3A
    pub const MEDIUM_NOT_PRESENT: u8 = 0x3A;
    // ASC 0x3D
    pub const INVALID_BITS_IN_IDENTIFY_MESSAGE: u8 = 0x3D;
    // ASC 0x44
    pub const INTERNAL_TARGET_FAILURE: u8 = 0x44;
    // ASC 0x4E
    pub const OVERLAPPED_COMMANDS_ATTEMPTED: u8 = 0x4E;
};

/// Parsed sense data result
pub const SenseData = struct {
    /// Response code (0x70-0x73)
    response_code: u8,
    /// Is this a deferred error (codes 0x71, 0x73)
    deferred: bool,
    /// Sense key (main error category)
    sense_key: SenseKey,
    /// Additional Sense Code
    asc: u8,
    /// Additional Sense Code Qualifier
    ascq: u8,
    /// Field pointer (if SKSV set)
    field_pointer: ?u16,
    /// Information field (for fixed format)
    information: ?u32,
    /// Command-specific information
    command_specific: ?u32,
    /// Is this descriptor format
    descriptor_format: bool,
    /// Raw sense data
    raw: []const u8,

    /// Get a human-readable description
    pub fn getDescription(self: SenseData, buffer: []u8) []u8 {
        var offset: usize = 0;

        // Sense key
        const sk_str = self.sense_key.toString();
        if (offset + sk_str.len < buffer.len) {
            @memcpy(buffer[offset .. offset + sk_str.len], sk_str);
            offset += sk_str.len;
        }

        // ASC/ASCQ description
        const asc_desc = getAscDescription(self.asc, self.ascq);
        if (offset + 2 + asc_desc.len < buffer.len) {
            buffer[offset] = ':';
            buffer[offset + 1] = ' ';
            offset += 2;
            @memcpy(buffer[offset .. offset + asc_desc.len], asc_desc);
            offset += asc_desc.len;
        }

        return buffer[0..offset];
    }

    /// Check if this indicates "Medium not present"
    pub fn isMediumNotPresent(self: SenseData) bool {
        return self.asc == Asc.MEDIUM_NOT_PRESENT;
    }

    /// Check if this indicates a write protection issue
    pub fn isWriteProtected(self: SenseData) bool {
        return self.asc == Asc.WRITE_PROTECTED;
    }

    /// Check if this is an invalid command
    pub fn isInvalidCommand(self: SenseData) bool {
        return self.asc == Asc.INVALID_COMMAND_OPERATION_CODE or
            self.asc == Asc.INVALID_FIELD_IN_CDB or
            self.asc == Asc.LOGICAL_UNIT_NOT_SUPPORTED;
    }
};

/// Get description for ASC/ASCQ combination
fn getAscDescription(asc: u8, ascq: u8) []const u8 {
    return switch (asc) {
        0x00 => switch (ascq) {
            0x00 => "No additional sense information",
            0x06 => "I/O process terminated",
            else => "No additional sense",
        },
        0x04 => switch (ascq) {
            0x00 => "Logical unit not ready, cause not reportable",
            0x01 => "Logical unit is in process of becoming ready",
            0x02 => "Logical unit not ready, initializing command required",
            0x03 => "Logical unit not ready, manual intervention required",
            0x04 => "Logical unit not ready, format in progress",
            0x09 => "Logical unit not ready, self-test in progress",
            else => "Logical unit not ready",
        },
        0x20 => "Invalid command operation code",
        0x21 => "Logical block address out of range",
        0x24 => "Invalid field in CDB",
        0x25 => "Logical unit not supported",
        0x26 => "Invalid field in parameter list",
        0x27 => switch (ascq) {
            0x00 => "Write protected",
            0x01 => "Hardware write protected",
            0x02 => "Logical unit software write protected",
            else => "Write protected",
        },
        0x28 => switch (ascq) {
            0x00 => "Not ready to ready transition, medium may have changed",
            else => "Not ready to ready transition",
        },
        0x29 => switch (ascq) {
            0x00 => "Power on, reset, or bus device reset occurred",
            0x01 => "Power on occurred",
            0x02 => "SCSI bus reset occurred",
            0x03 => "Bus device reset function occurred",
            0x04 => "Device internal reset",
            else => "Power on or reset occurred",
        },
        0x2A => "Parameters changed",
        0x3A => switch (ascq) {
            0x00 => "Medium not present",
            0x01 => "Medium not present, tray closed",
            0x02 => "Medium not present, tray open",
            else => "Medium not present",
        },
        0x44 => "Internal target failure",
        0x4E => "Overlapped commands attempted",
        0x55 => "System resource failure",
        else => "Unknown error",
    };
}

/// Parse sense data bytes into structured form
pub fn parse(data: []const u8) ?SenseData {
    if (data.len < 2) {
        return null;
    }

    const response_code = data[0] & 0x7F;

    // Check for valid response codes
    return switch (response_code) {
        0x70, 0x71 => parseFixed(data),
        0x72, 0x73 => parseDescriptor(data),
        else => null,
    };
}

/// Parse fixed format sense data (response codes 0x70, 0x71)
fn parseFixed(data: []const u8) ?SenseData {
    if (data.len < 8) {
        return null;
    }

    const response_code = data[0] & 0x7F;
    const sense_key: SenseKey = @enumFromInt(@as(u4, @truncate(data[2] & 0x0F)));

    // Additional sense code and qualifier at bytes 12, 13
    const asc: u8 = if (data.len > 12) data[12] else 0;
    const ascq: u8 = if (data.len > 13) data[13] else 0;

    // Information field (bytes 3-6)
    const information: ?u32 = if (data[0] & 0x80 != 0 and data.len >= 7)
        (@as(u32, data[3]) << 24) | (@as(u32, data[4]) << 16) |
            (@as(u32, data[5]) << 8) | @as(u32, data[6])
    else
        null;

    // Command specific info (bytes 8-11)
    const command_specific: ?u32 = if (data.len >= 12)
        (@as(u32, data[8]) << 24) | (@as(u32, data[9]) << 16) |
            (@as(u32, data[10]) << 8) | @as(u32, data[11])
    else
        null;

    // Sense key specific (bytes 15-17) - field pointer
    var field_pointer: ?u16 = null;
    if (data.len >= 18 and (data[15] & 0x80) != 0) {
        field_pointer = (@as(u16, data[16]) << 8) | @as(u16, data[17]);
    }

    return SenseData{
        .response_code = response_code,
        .deferred = response_code == 0x71,
        .sense_key = sense_key,
        .asc = asc,
        .ascq = ascq,
        .field_pointer = field_pointer,
        .information = information,
        .command_specific = command_specific,
        .descriptor_format = false,
        .raw = data,
    };
}

/// Parse descriptor format sense data (response codes 0x72, 0x73)
fn parseDescriptor(data: []const u8) ?SenseData {
    if (data.len < 8) {
        return null;
    }

    const response_code = data[0] & 0x7F;
    const sense_key: SenseKey = @enumFromInt(@as(u4, @truncate(data[1] & 0x0F)));
    const asc = data[2];
    const ascq = data[3];
    const additional_len = data[7];

    // Parse descriptors if present
    var field_pointer: ?u16 = null;
    var information: ?u32 = null;
    var command_specific: ?u32 = null;

    if (data.len >= 8 + additional_len) {
        var offset: usize = 8;
        while (offset + 2 <= 8 + additional_len) {
            const desc_type = data[offset];
            const desc_len = data[offset + 1];

            if (offset + 2 + desc_len > data.len) break;

            switch (desc_type) {
                0x00 => { // Information
                    if (desc_len >= 10) {
                        information = (@as(u32, data[offset + 6]) << 24) |
                            (@as(u32, data[offset + 7]) << 16) |
                            (@as(u32, data[offset + 8]) << 8) |
                            @as(u32, data[offset + 9]);
                    }
                },
                0x01 => { // Command specific
                    if (desc_len >= 10) {
                        command_specific = (@as(u32, data[offset + 6]) << 24) |
                            (@as(u32, data[offset + 7]) << 16) |
                            (@as(u32, data[offset + 8]) << 8) |
                            @as(u32, data[offset + 9]);
                    }
                },
                0x02 => { // Sense key specific
                    if (desc_len >= 6 and (data[offset + 4] & 0x80) != 0) {
                        field_pointer = (@as(u16, data[offset + 5]) << 8) | @as(u16, data[offset + 6]);
                    }
                },
                else => {},
            }

            offset += 2 + desc_len;
        }
    }

    return SenseData{
        .response_code = response_code,
        .deferred = response_code == 0x73,
        .sense_key = sense_key,
        .asc = asc,
        .ascq = ascq,
        .field_pointer = field_pointer,
        .information = information,
        .command_specific = command_specific,
        .descriptor_format = true,
        .raw = data,
    };
}

/// Format sense data as a hex string
pub fn formatHex(data: []const u8, buffer: []u8) []u8 {
    var offset: usize = 0;
    for (data, 0..) |byte, i| {
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

test "parse fixed format sense - medium not present" {
    // Example sense data for "Medium not present" (0x70 format)
    const sense_data = [_]u8{
        0x70, // Response code (current, fixed)
        0x00, // Obsolete
        0x02, // Sense key: NOT READY
        0x00, 0x00, 0x00, 0x00, // Information
        0x0A, // Additional sense length
        0x00, 0x00, 0x00, 0x00, // Command specific
        0x3A, // ASC: Medium not present
        0x00, // ASCQ
        0x00, // FRU
        0x00, 0x00, 0x00, // SKSV + Sense key specific
    };

    const parsed = parse(&sense_data);
    try std.testing.expect(parsed != null);

    const data = parsed.?;
    try std.testing.expectEqual(SenseKey.not_ready, data.sense_key);
    try std.testing.expectEqual(@as(u8, 0x3A), data.asc);
    try std.testing.expectEqual(@as(u8, 0x00), data.ascq);
    try std.testing.expect(data.isMediumNotPresent());
}

test "parse fixed format sense - illegal request" {
    const sense_data = [_]u8{
        0x70, 0x00,
        0x05, // Sense key: ILLEGAL REQUEST
        0x00, 0x00, 0x00, 0x00,
        0x0A,
        0x00, 0x00, 0x00, 0x00,
        0x24, // ASC: Invalid field in CDB
        0x00,
        0x00,
        0x00, 0x00, 0x00,
    };

    const parsed = parse(&sense_data);
    try std.testing.expect(parsed != null);

    const data = parsed.?;
    try std.testing.expectEqual(SenseKey.illegal_request, data.sense_key);
    try std.testing.expect(data.isInvalidCommand());
}

test "sense key to string" {
    try std.testing.expectEqualStrings("NOT READY", SenseKey.not_ready.toString());
    try std.testing.expectEqualStrings("MEDIUM ERROR", SenseKey.medium_error.toString());
    try std.testing.expectEqualStrings("ILLEGAL REQUEST", SenseKey.illegal_request.toString());
}
