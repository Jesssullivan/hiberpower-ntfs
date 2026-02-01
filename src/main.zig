//! ASM2362 Recovery Tool
//!
//! Send vendor-specific commands to ASMedia ASM2362 USB-NVMe bridge
//! to recover NVMe drives exhibiting silent write failure.
//!
//! Usage:
//!   asm2362-tool probe /dev/sdX        - Probe device capabilities
//!   asm2362-tool identify /dev/sdX     - Get NVMe identify data
//!   asm2362-tool smart /dev/sdX        - Get SMART log
//!   asm2362-tool format /dev/sdX       - Format NVM (destructive)
//!   asm2362-tool replay <file> /dev/sdX - Replay captured commands

const std = @import("std");
const sg_io = @import("scsi/sg_io.zig");
const sense = @import("scsi/sense.zig");
const passthrough = @import("asm2362/passthrough.zig");
const commands = @import("asm2362/commands.zig");
const identify = @import("nvme/identify.zig");
const format = @import("nvme/format.zig");
const sanitize = @import("nvme/sanitize.zig");
const probe = @import("analysis/probe.zig");
const replay = @import("frida/replay.zig");

pub const std_options = .{
    .log_level = .info,
};

const Command = enum {
    probe,
    identify,
    smart,
    format,
    sanitize,
    replay,
    get_features,
    set_features,
    security_recv,
    security_send,
    help,
};

const Args = struct {
    command: Command,
    device_path: ?[]const u8,
    replay_file: ?[]const u8,
    dry_run: bool,
    ses: u8, // Secure Erase Setting for format
    verbose: bool,
    json_output: bool,
    asm_only: bool, // Filter to ASMedia commands only in replay
    // Get/Set Features args
    feature_id: u8, // NVMe Feature ID (e.g., 0x84 for write protect)
    feature_value: u32, // Value to set for Set Features
    save_feature: bool, // Persist feature across power cycles
    // Security args
    security_protocol: u8, // Security protocol (0x00=info, 0xEF=ATA password)
    sp_specific: u16, // Protocol-specific value
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var result = Args{
        .command = .help,
        .device_path = null,
        .replay_file = null,
        .dry_run = false,
        .ses = 0,
        .verbose = false,
        .json_output = false,
        .asm_only = false,
        .feature_id = 0x84, // Default: Namespace Write Protect
        .feature_value = 0,
        .save_feature = false,
        .security_protocol = 0x00, // Default: Protocol Info
        .sp_specific = 0,
    };

    if (args.len < 2) {
        return result;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--dry-run")) {
            result.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--asm-only")) {
            result.asm_only = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            result.verbose = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            result.json_output = true;
        } else if (std.mem.startsWith(u8, arg, "--ses=")) {
            result.ses = std.fmt.parseInt(u8, arg[6..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "probe")) {
            result.command = .probe;
        } else if (std.mem.eql(u8, arg, "identify")) {
            result.command = .identify;
        } else if (std.mem.eql(u8, arg, "smart")) {
            result.command = .smart;
        } else if (std.mem.eql(u8, arg, "format")) {
            result.command = .format;
        } else if (std.mem.eql(u8, arg, "sanitize")) {
            result.command = .sanitize;
        } else if (std.mem.eql(u8, arg, "replay")) {
            result.command = .replay;
            if (i + 1 < args.len) {
                i += 1;
                result.replay_file = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "get-features")) {
            result.command = .get_features;
        } else if (std.mem.eql(u8, arg, "set-features")) {
            result.command = .set_features;
        } else if (std.mem.eql(u8, arg, "security-recv")) {
            result.command = .security_recv;
        } else if (std.mem.eql(u8, arg, "security-send")) {
            result.command = .security_send;
        } else if (std.mem.startsWith(u8, arg, "--fid=")) {
            result.feature_id = std.fmt.parseInt(u8, arg[6..], 0) catch 0x84;
        } else if (std.mem.startsWith(u8, arg, "--value=")) {
            result.feature_value = std.fmt.parseInt(u32, arg[8..], 0) catch 0;
        } else if (std.mem.eql(u8, arg, "--save")) {
            result.save_feature = true;
        } else if (std.mem.startsWith(u8, arg, "--protocol=")) {
            result.security_protocol = std.fmt.parseInt(u8, arg[11..], 0) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--sp-specific=")) {
            result.sp_specific = std.fmt.parseInt(u16, arg[14..], 0) catch 0;
        } else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.command = .help;
        } else if (arg[0] == '/') {
            // Device path
            result.device_path = try allocator.dupe(u8, arg);
        }
    }

    return result;
}

fn printUsage() void {
    const usage =
        \\ASM2362 Recovery Tool - NVMe passthrough via USB bridge
        \\
        \\USAGE:
        \\    asm2362-tool <COMMAND> [OPTIONS] <DEVICE>
        \\
        \\COMMANDS:
        \\    probe         Probe device capabilities and identify bridge type
        \\    identify      Get NVMe Identify Controller/Namespace data
        \\    smart         Get NVMe SMART/Health log
        \\    format        Format NVM (DESTRUCTIVE - erases all data)
        \\    sanitize      Sanitize drive (DESTRUCTIVE - erases all data)
        \\    replay        Replay captured command sequence from JSON file
        \\    get-features  Query NVMe feature value (e.g., write protection)
        \\    set-features  Set NVMe feature value
        \\    security-recv Query security protocol state
        \\    security-send Send security protocol command
        \\    help          Show this help message
        \\
        \\OPTIONS:
        \\    --dry-run        Show what would be done without executing
        \\    --ses=N          Secure Erase Setting for format (0=none, 1=user, 2=crypto)
        \\    --asm-only       Filter to ASMedia passthrough commands only (for replay)
        \\    --verbose        Enable verbose output
        \\    --json           Output in JSON format
        \\    --fid=N          Feature ID for get/set-features (default: 0x84 = Write Protect)
        \\    --value=N        Value for set-features
        \\    --save           Save feature persistently (for set-features)
        \\    --protocol=N     Security protocol (0x00=info, 0xEF=ATA password)
        \\    --sp-specific=N  Protocol-specific value
        \\
        \\EXAMPLES:
        \\    asm2362-tool probe /dev/sdb
        \\    asm2362-tool identify /dev/sdb
        \\    asm2362-tool smart /dev/sdb --json
        \\    asm2362-tool format /dev/sdb --ses=1 --dry-run
        \\    asm2362-tool get-features /dev/sdb --fid=0x84     # Query write protect
        \\    asm2362-tool set-features /dev/sdb --fid=0x84 --value=0 --save  # Clear WP
        \\    asm2362-tool security-recv /dev/sdb --protocol=0  # Query security info
        \\    asm2362-tool security-recv /dev/sdb --protocol=0xef  # ATA security state
        \\    asm2362-tool replay captured.json /dev/sdb
        \\
        \\FEATURE IDS (--fid):
        \\    0x06  Volatile Write Cache
        \\    0x84  Namespace Write Protect
        \\
        \\SECURITY PROTOCOLS (--protocol):
        \\    0x00  Security Protocol Information
        \\    0xEF  ATA Device Server Password Security
        \\
        \\SAFETY:
        \\    Format and sanitize commands are DESTRUCTIVE and will erase all data.
        \\    Always use --dry-run first to verify the operation.
        \\
        \\DEVICE:
        \\    The SCSI device path (e.g., /dev/sdb) for the USB-attached NVMe drive.
        \\    Do NOT use the NVMe device path (/dev/nvmeX) - this tool uses SCSI
        \\    passthrough for USB bridges.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    // Clean up allocated strings on exit
    defer if (args.device_path) |p| allocator.free(p);
    defer if (args.replay_file) |p| allocator.free(p);

    if (args.command == .help) {
        printUsage();
        return;
    }

    const device_path = args.device_path orelse {
        std.debug.print("Error: No device path specified\n\n", .{});
        printUsage();
        std.process.exit(1);
    };

    if (args.verbose) {
        std.log.info("Device: {s}", .{device_path});
        std.log.info("Command: {s}", .{@tagName(args.command)});
        if (args.dry_run) {
            std.log.info("Mode: dry-run", .{});
        }
    }

    switch (args.command) {
        .probe => {
            try probe.probeDevice(allocator, device_path, args.json_output);
        },
        .identify => {
            try identify.identifyController(allocator, device_path, args.json_output);
        },
        .smart => {
            try commands.getSmartLog(allocator, device_path, args.json_output);
        },
        .format => {
            if (args.dry_run) {
                std.debug.print("DRY RUN: Would format {s} with SES={d}\n", .{ device_path, args.ses });
                std.debug.print("WARNING: This would erase all data on the drive!\n", .{});
            } else {
                try format.formatNvm(allocator, device_path, args.ses);
            }
        },
        .sanitize => {
            if (args.dry_run) {
                std.debug.print("DRY RUN: Would sanitize {s}\n", .{device_path});
                std.debug.print("WARNING: This would erase all data on the drive!\n", .{});
            } else {
                try sanitize.sanitize(allocator, device_path, .block_erase);
            }
        },
        .replay => {
            const replay_file = args.replay_file orelse {
                std.debug.print("Error: No replay file specified\n", .{});
                std.process.exit(1);
            };
            try replay.replay(allocator, replay_file, device_path, args.dry_run, args.asm_only);
        },
        .get_features => {
            std.debug.print("Get Features: FID=0x{x:0>2} ({s})\n", .{
                args.feature_id,
                passthrough.FeatureId.toString(@enumFromInt(args.feature_id)),
            });
            const result = passthrough.getFeatures(
                allocator,
                device_path,
                args.feature_id,
                1, // NSID=1
                0, // SEL=Current
            ) catch |err| {
                std.debug.print("Error: {s}\n", .{@errorName(err)});
                if (err == passthrough.PassthroughError.MediumNotPresent) {
                    std.debug.print("  Drive is in protection mode - admin commands blocked\n", .{});
                }
                std.process.exit(1);
            };
            std.debug.print("Result: SCSI status={s}, duration={d}ms\n", .{
                @tagName(result.scsi_status),
                result.duration_ms,
            });
            if (result.data) |data| {
                if (data.len >= 4) {
                    const value = std.mem.readInt(u32, data[0..4], .little);
                    std.debug.print("Feature Value: 0x{x:0>8} ({d})\n", .{ value, value });
                }
                allocator.free(data);
            }
        },
        .set_features => {
            std.debug.print("Set Features: FID=0x{x:0>2} ({s}), Value=0x{x:0>8}, Save={}\n", .{
                args.feature_id,
                passthrough.FeatureId.toString(@enumFromInt(args.feature_id)),
                args.feature_value,
                args.save_feature,
            });
            if (args.dry_run) {
                std.debug.print("DRY RUN: Would set feature\n", .{});
            } else {
                const result = passthrough.setFeatures(
                    allocator,
                    device_path,
                    args.feature_id,
                    1, // NSID=1
                    args.feature_value,
                    args.save_feature,
                ) catch |err| {
                    std.debug.print("Error: {s}\n", .{@errorName(err)});
                    if (err == passthrough.PassthroughError.MediumNotPresent) {
                        std.debug.print("  Drive is in protection mode - admin commands blocked\n", .{});
                    }
                    std.process.exit(1);
                };
                std.debug.print("Result: SCSI status={s}, duration={d}ms\n", .{
                    @tagName(result.scsi_status),
                    result.duration_ms,
                });
            }
        },
        .security_recv => {
            std.debug.print("Security Receive: Protocol=0x{x:0>2}, SP Specific=0x{x:0>4}\n", .{
                args.security_protocol,
                args.sp_specific,
            });
            const result = passthrough.securityRecv(
                allocator,
                device_path,
                args.security_protocol,
                args.sp_specific,
                512, // Standard buffer size
            ) catch |err| {
                std.debug.print("Error: {s}\n", .{@errorName(err)});
                if (err == passthrough.PassthroughError.MediumNotPresent) {
                    std.debug.print("  Drive is in protection mode - admin commands blocked\n", .{});
                }
                std.process.exit(1);
            };
            std.debug.print("Result: SCSI status={s}, duration={d}ms\n", .{
                @tagName(result.scsi_status),
                result.duration_ms,
            });
            if (result.data) |data| {
                std.debug.print("Data ({d} bytes):\n", .{data.len});
                // Print hex dump of first 64 bytes
                const dump_len = @min(data.len, 64);
                for (0..dump_len) |i| {
                    if (i % 16 == 0) std.debug.print("  {x:0>4}: ", .{i});
                    std.debug.print("{x:0>2} ", .{data[i]});
                    if (i % 16 == 15) std.debug.print("\n", .{});
                }
                if (dump_len % 16 != 0) std.debug.print("\n", .{});
                allocator.free(data);
            }
        },
        .security_send => {
            std.debug.print("Security Send: Protocol=0x{x:0>2}, SP Specific=0x{x:0>4}\n", .{
                args.security_protocol,
                args.sp_specific,
            });
            if (args.dry_run) {
                std.debug.print("DRY RUN: Would send security command\n", .{});
            } else {
                const result = passthrough.securitySend(
                    allocator,
                    device_path,
                    args.security_protocol,
                    args.sp_specific,
                    &[_]u8{}, // Empty data for now
                ) catch |err| {
                    std.debug.print("Error: {s}\n", .{@errorName(err)});
                    if (err == passthrough.PassthroughError.MediumNotPresent) {
                        std.debug.print("  Drive is in protection mode - admin commands blocked\n", .{});
                    }
                    std.process.exit(1);
                };
                std.debug.print("Result: SCSI status={s}, duration={d}ms\n", .{
                    @tagName(result.scsi_status),
                    result.duration_ms,
                });
            }
        },
        .help => {
            printUsage();
        },
    }
}

test "parse args - probe command" {
    // Basic test infrastructure
    const allocator = std.testing.allocator;
    _ = allocator;
}
