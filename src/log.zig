//! JSON Command Logging Infrastructure
//!
//! Log all commands sent to the device for analysis and replay.

const std = @import("std");
const sg_io = @import("scsi/sg_io.zig");
const sense = @import("scsi/sense.zig");

/// A single command log entry
pub const CommandLogEntry = struct {
    /// Unix timestamp (milliseconds)
    timestamp_ms: i64,
    /// Device path
    device: []const u8,
    /// Command type
    command_type: []const u8,
    /// Raw CDB bytes (hex)
    cdb_hex: []const u8,
    /// Data direction
    direction: []const u8,
    /// Data transfer length
    data_len: usize,
    /// Success flag
    success: bool,
    /// SCSI status
    scsi_status: u8,
    /// Sense key (if check condition)
    sense_key: ?u8,
    /// ASC (if check condition)
    asc: ?u8,
    /// ASCQ (if check condition)
    ascq: ?u8,
    /// Command duration in milliseconds
    duration_ms: u32,
};

/// Command logger
pub const CommandLogger = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CommandLogEntry),
    log_file: ?std.fs.File,

    pub fn init(allocator: std.mem.Allocator, log_path: ?[]const u8) !CommandLogger {
        var logger = CommandLogger{
            .allocator = allocator,
            .entries = std.ArrayList(CommandLogEntry).init(allocator),
            .log_file = null,
        };

        if (log_path) |path| {
            logger.log_file = std.fs.cwd().createFile(path, .{}) catch null;
        }

        return logger;
    }

    pub fn deinit(self: *CommandLogger) void {
        if (self.log_file) |file| {
            file.close();
        }
        self.entries.deinit();
    }

    /// Log a command execution
    pub fn logCommand(
        self: *CommandLogger,
        device: []const u8,
        command_type: []const u8,
        cdb: []const u8,
        direction: sg_io.Direction,
        data_len: usize,
        result: *const sg_io.SgResult,
    ) !void {
        var cdb_hex_buf: [64]u8 = undefined;
        const cdb_hex = sg_io.formatCdb(cdb, &cdb_hex_buf);

        var sense_key: ?u8 = null;
        var asc: ?u8 = null;
        var ascq: ?u8 = null;

        if (result.isCheckCondition()) {
            if (sense.parse(result.sense_data)) |sd| {
                sense_key = @intFromEnum(sd.sense_key);
                asc = sd.asc;
                ascq = sd.ascq;
            }
        }

        const entry = CommandLogEntry{
            .timestamp_ms = std.time.milliTimestamp(),
            .device = try self.allocator.dupe(u8, device),
            .command_type = try self.allocator.dupe(u8, command_type),
            .cdb_hex = try self.allocator.dupe(u8, cdb_hex),
            .direction = switch (direction) {
                .none => "none",
                .to_dev => "write",
                .from_dev => "read",
                .to_from_dev => "bidirectional",
            },
            .data_len = data_len,
            .success = result.success,
            .scsi_status = @intFromEnum(result.status),
            .sense_key = sense_key,
            .asc = asc,
            .ascq = ascq,
            .duration_ms = result.duration_ms,
        };

        try self.entries.append(entry);

        // Write to log file if open
        if (self.log_file) |file| {
            try self.writeEntryJson(file.writer(), &entry);
            try file.writer().writeAll("\n");
        }
    }

    /// Write a single entry as JSON
    fn writeEntryJson(self: *CommandLogger, writer: anytype, entry: *const CommandLogEntry) !void {
        _ = self;
        try writer.writeAll("{");
        try writer.print("\"timestamp_ms\":{},", .{entry.timestamp_ms});
        try writer.print("\"device\":\"{s}\",", .{entry.device});
        try writer.print("\"command_type\":\"{s}\",", .{entry.command_type});
        try writer.print("\"cdb_hex\":\"{s}\",", .{entry.cdb_hex});
        try writer.print("\"direction\":\"{s}\",", .{entry.direction});
        try writer.print("\"data_len\":{},", .{entry.data_len});
        try writer.print("\"success\":{},", .{entry.success});
        try writer.print("\"scsi_status\":{},", .{entry.scsi_status});
        try writer.print("\"duration_ms\":{}", .{entry.duration_ms});

        if (entry.sense_key) |sk| {
            try writer.print(",\"sense_key\":{}", .{sk});
        }
        if (entry.asc) |a| {
            try writer.print(",\"asc\":{}", .{a});
        }
        if (entry.ascq) |q| {
            try writer.print(",\"ascq\":{}", .{q});
        }

        try writer.writeAll("}");
    }

    /// Export all entries as a JSON array
    pub fn exportJson(self: *CommandLogger, writer: anytype) !void {
        try writer.writeAll("[\n");
        for (self.entries.items, 0..) |*entry, i| {
            try writer.writeAll("  ");
            try self.writeEntryJson(writer, entry);
            if (i < self.entries.items.len - 1) {
                try writer.writeAll(",");
            }
            try writer.writeAll("\n");
        }
        try writer.writeAll("]\n");
    }
};

/// Format a timestamp as ISO 8601
pub fn formatTimestamp(timestamp_ms: i64, buffer: []u8) []u8 {
    const secs = @divFloor(timestamp_ms, 1000);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();

    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @as(u8, @intFromEnum(year_day.month)),
        year_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    }) catch buffer[0..0];
}

test "format timestamp" {
    var buffer: [32]u8 = undefined;
    // Test with known timestamp
    const formatted = formatTimestamp(0, &buffer);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatted);
}
