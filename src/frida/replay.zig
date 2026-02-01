//! Command Replay Module
//!
//! Replays captured commands from Frida JSON captures back to a device.
//! Used to reproduce SP Toolbox command sequences on Linux via asm2362-tool.

const std = @import("std");
const sg_io = @import("../scsi/sg_io.zig");
const sense = @import("../scsi/sense.zig");

/// A captured command from Frida JSON export
pub const CapturedCommand = struct {
    timestamp: i64 = 0,
    handle: ?[]const u8 = null,
    device: ?[]const u8 = null,
    ioctl_code: []const u8,
    ioctl_name: ?[]const u8 = null,
    cdb: []const u8, // hex string like "e6 06 00 01..."
    cdb_length: u8 = 16,
    data_direction: []const u8, // "read", "write", "none"
    data_length: u32 = 0,

    /// Nested parsed info (optional)
    parsed: ?struct {
        type: ?[]const u8 = null,
        nvme_opcode: ?[]const u8 = null,
        nvme_command: ?[]const u8 = null,
        cdw10: ?[]const u8 = null,
    } = null,
};

/// Replay result for a single command
pub const ReplayResult = struct {
    index: usize,
    success: bool,
    scsi_status: u8,
    sense_key: ?u8 = null,
    asc: ?u8 = null,
    ascq: ?u8 = null,
    error_message: ?[]const u8 = null,
};

/// Command replay controller
pub const CommandReplayer = struct {
    allocator: std.mem.Allocator,
    device_path: []const u8,
    device_fd: ?std.posix.fd_t = null,
    dry_run: bool = false,
    results: std.ArrayList(ReplayResult),
    verbose: bool = false,

    pub fn init(allocator: std.mem.Allocator, device_path: []const u8, dry_run: bool) CommandReplayer {
        return .{
            .allocator = allocator,
            .device_path = device_path,
            .dry_run = dry_run,
            .results = std.ArrayList(ReplayResult).init(allocator),
        };
    }

    pub fn deinit(self: *CommandReplayer) void {
        if (self.device_fd) |fd| {
            std.posix.close(fd);
        }
        self.results.deinit();
    }

    /// Open the target device
    pub fn openDevice(self: *CommandReplayer) !void {
        if (self.dry_run) {
            std.debug.print("[DRY-RUN] Would open device: {s}\n", .{self.device_path});
            return;
        }

        const fd = try std.posix.open(
            self.device_path,
            .{ .ACCMODE = .RDWR },
            0,
        );
        self.device_fd = fd;
    }

    /// Parse hex string to bytes
    fn parseHexString(self: *CommandReplayer, hex_str: []const u8, output: []u8) !usize {
        _ = self;
        var byte_count: usize = 0;
        var i: usize = 0;

        while (i < hex_str.len and byte_count < output.len) {
            // Skip spaces
            while (i < hex_str.len and hex_str[i] == ' ') {
                i += 1;
            }
            if (i >= hex_str.len) break;

            // Parse two hex chars
            if (i + 1 >= hex_str.len) break;

            const high = std.fmt.charToDigit(hex_str[i], 16) catch break;
            const low = std.fmt.charToDigit(hex_str[i + 1], 16) catch break;
            output[byte_count] = (high << 4) | low;
            byte_count += 1;
            i += 2;
        }

        return byte_count;
    }

    /// Replay a single command
    pub fn replayCommand(self: *CommandReplayer, cmd: *const CapturedCommand, index: usize) !ReplayResult {
        // Parse CDB from hex string
        var cdb: [16]u8 = [_]u8{0} ** 16;
        const cdb_len = try self.parseHexString(cmd.cdb, &cdb);

        // Determine direction
        const direction: sg_io.Direction = if (std.mem.eql(u8, cmd.data_direction, "read"))
            .from_dev
        else if (std.mem.eql(u8, cmd.data_direction, "write"))
            .to_dev
        else
            .none;

        // Log command info
        if (self.verbose) {
            std.debug.print("[{d}] Replaying: ", .{index});
            if (cmd.parsed) |p| {
                if (p.nvme_command) |nvme_cmd| {
                    std.debug.print("{s} ", .{nvme_cmd});
                }
            }
            std.debug.print("CDB[0..{d}] direction={s} len={d}\n", .{
                cdb_len,
                cmd.data_direction,
                cmd.data_length,
            });
        }

        if (self.dry_run) {
            std.debug.print("[DRY-RUN] Would send CDB: ", .{});
            for (cdb[0..cdb_len]) |b| {
                std.debug.print("{x:0>2} ", .{b});
            }
            std.debug.print("\n", .{});

            return ReplayResult{
                .index = index,
                .success = true,
                .scsi_status = 0,
            };
        }

        // Execute via SG_IO
        const fd = self.device_fd orelse return error.DeviceNotOpen;

        // Allocate data buffer if needed
        var data_buf: ?[]u8 = null;
        defer if (data_buf) |buf| self.allocator.free(buf);

        if (cmd.data_length > 0) {
            data_buf = try self.allocator.alloc(u8, cmd.data_length);
            @memset(data_buf.?, 0);
        }

        const result = sg_io.executeOnFd(
            fd,
            cdb[0..cdb_len],
            data_buf,
            direction,
            30000, // 30 second timeout
        );

        if (result) |r| {
            var replay_result = ReplayResult{
                .index = index,
                .success = r.success,
                .scsi_status = @intFromEnum(r.status),
            };

            if (r.isCheckCondition()) {
                if (sense.parse(r.sense_data)) |sd| {
                    replay_result.sense_key = @intFromEnum(sd.sense_key);
                    replay_result.asc = sd.asc;
                    replay_result.ascq = sd.ascq;
                }
            }

            return replay_result;
        } else |err| {
            return ReplayResult{
                .index = index,
                .success = false,
                .scsi_status = 0xFF,
                .error_message = @errorName(err),
            };
        }
    }

    /// Replay all commands from a list
    pub fn replayAll(self: *CommandReplayer, commands: []const CapturedCommand) !void {
        std.debug.print("Replaying {d} commands to {s}\n", .{ commands.len, self.device_path });

        if (!self.dry_run) {
            try self.openDevice();
        }

        for (commands, 0..) |*cmd, i| {
            const result = try self.replayCommand(cmd, i);
            try self.results.append(result);

            if (!result.success) {
                std.debug.print("[{d}] FAILED: status={x}", .{ i, result.scsi_status });
                if (result.sense_key) |sk| {
                    std.debug.print(" sense={x}/{x}/{x}", .{ sk, result.asc orelse 0, result.ascq orelse 0 });
                }
                std.debug.print("\n", .{});
            }
        }

        // Summary
        var success_count: usize = 0;
        for (self.results.items) |r| {
            if (r.success) success_count += 1;
        }

        std.debug.print("\nReplay complete: {d}/{d} commands succeeded\n", .{ success_count, commands.len });
    }
};

/// Load commands from JSON file
pub fn loadCommandsFromFile(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed([]CapturedCommand) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(content);

    return std.json.parseFromSlice(
        []CapturedCommand,
        allocator,
        content,
        .{ .ignore_unknown_fields = true },
    );
}

/// Filter commands to only ASMedia passthrough (0xe6)
pub fn filterAsmediaCommands(allocator: std.mem.Allocator, commands: []const CapturedCommand) ![]CapturedCommand {
    var filtered = std.ArrayList(CapturedCommand).init(allocator);

    for (commands) |cmd| {
        // Check if CDB starts with "e6"
        if (cmd.cdb.len >= 2 and
            (cmd.cdb[0] == 'e' or cmd.cdb[0] == 'E') and
            cmd.cdb[1] == '6')
        {
            try filtered.append(cmd);
        }
    }

    return filtered.toOwnedSlice();
}

/// Main replay entry point
pub fn replay(allocator: std.mem.Allocator, json_path: []const u8, device_path: []const u8, dry_run: bool, asm_only: bool) !void {
    std.debug.print("Loading commands from: {s}\n", .{json_path});

    const parsed = try loadCommandsFromFile(allocator, json_path);
    defer parsed.deinit();

    var commands = parsed.value;

    // Filter to ASMedia commands if requested
    var filtered: ?[]CapturedCommand = null;
    defer if (filtered) |f| allocator.free(f);

    if (asm_only) {
        filtered = try filterAsmediaCommands(allocator, commands);
        commands = filtered.?;
        std.debug.print("Filtered to {d} ASMedia passthrough commands\n", .{commands.len});
    }

    if (commands.len == 0) {
        std.debug.print("No commands to replay\n", .{});
        return;
    }

    var replayer = CommandReplayer.init(allocator, device_path, dry_run);
    defer replayer.deinit();
    replayer.verbose = true;

    try replayer.replayAll(commands);
}

// Tests
test "parse hex string" {
    var replayer = CommandReplayer.init(std.testing.allocator, "/dev/null", true);
    defer replayer.deinit();

    var output: [16]u8 = undefined;
    const len = try replayer.parseHexString("e6 06 00 01 00 00 00 00", &output);

    try std.testing.expectEqual(@as(usize, 8), len);
    try std.testing.expectEqual(@as(u8, 0xe6), output[0]);
    try std.testing.expectEqual(@as(u8, 0x06), output[1]);
    try std.testing.expectEqual(@as(u8, 0x01), output[3]);
}

test "filter asmedia commands" {
    const commands = [_]CapturedCommand{
        .{ .ioctl_code = "0x4d014", .cdb = "e6 06 00 01", .data_direction = "read" },
        .{ .ioctl_code = "0x4d014", .cdb = "12 00 00 00", .data_direction = "read" }, // INQUIRY, not ASM
        .{ .ioctl_code = "0x4d014", .cdb = "E6 80 00 00", .data_direction = "none" }, // Format
    };

    const filtered = try filterAsmediaCommands(std.testing.allocator, &commands);
    defer std.testing.allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
}
