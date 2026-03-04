//! ASM2362 Recovery Tool
//!
//! Send vendor-specific commands to ASMedia ASM2362 USB-NVMe bridge
//! to recover NVMe drives exhibiting silent write failure.
//!
//! Usage:
//!   asm2362-tool probe /dev/sdX            - Probe device capabilities
//!   asm2362-tool identify /dev/sdX         - Get NVMe identify data
//!   asm2362-tool smart /dev/sdX            - Get SMART log
//!   asm2362-tool xram-probe /dev/sdX       - Probe XRAM (safe, read-only)
//!   asm2362-tool inject --dry-run /dev/sdX - Inject NVMe command via XRAM
//!   asm2362-tool replay <file> /dev/sdX    - Replay captured commands

const std = @import("std");
const sg_io = @import("scsi/sg_io.zig");
const sense = @import("scsi/sense.zig");
const passthrough = @import("asm2362/passthrough.zig");
const commands = @import("asm2362/commands.zig");
const xram = @import("asm2362/xram.zig");
const identify = @import("nvme/identify.zig");
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
    // XRAM commands (bypass 0xe6 whitelist)
    xram_probe,
    xram_read,
    xram_write,
    xram_dump,
    inject,
    admin_cq,
    reset,
    help,
};

const InjectCmd = enum {
    format_nvm,
    sanitize_block,
    sanitize_crypto,
    clear_wp,
};

const Args = struct {
    command: Command,
    device_path: ?[]const u8,
    replay_file: ?[]const u8,
    dry_run: bool,
    force: bool,
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
    // XRAM args
    xram_address: u16,
    xram_length: u16,
    xram_value: u8,
    xram_verify: bool,
    // Inject args
    inject_command: InjectCmd,
    inject_nsid: u32,
    inject_slot: ?u8, // Explicit SQ slot (0-7)
    inject_tail: ?u8, // Explicit doorbell tail value
    inject_cid: u16, // Command ID for tracking
    // Reset args
    reset_type: u8,
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var result = Args{
        .command = .help,
        .device_path = null,
        .replay_file = null,
        .dry_run = false,
        .force = false,
        .ses = 0,
        .verbose = false,
        .json_output = false,
        .asm_only = false,
        .feature_id = 0x84,
        .feature_value = 0,
        .save_feature = false,
        .security_protocol = 0x00,
        .sp_specific = 0,
        .xram_address = 0xB000,
        .xram_length = 64,
        .xram_value = 0,
        .xram_verify = true,
        .inject_command = .format_nvm,
        .inject_nsid = 0xFFFFFFFF,
        .inject_slot = null,
        .inject_tail = null,
        .inject_cid = 0x0100,
        .reset_type = 0x01,
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
        } else if (std.mem.eql(u8, arg, "xram-probe")) {
            result.command = .xram_probe;
        } else if (std.mem.eql(u8, arg, "xram-read")) {
            result.command = .xram_read;
        } else if (std.mem.eql(u8, arg, "xram-write")) {
            result.command = .xram_write;
        } else if (std.mem.eql(u8, arg, "xram-dump")) {
            result.command = .xram_dump;
        } else if (std.mem.eql(u8, arg, "inject")) {
            result.command = .inject;
        } else if (std.mem.eql(u8, arg, "admin-cq")) {
            result.command = .admin_cq;
        } else if (std.mem.eql(u8, arg, "reset")) {
            result.command = .reset;
        } else if (std.mem.startsWith(u8, arg, "--addr=")) {
            result.xram_address = std.fmt.parseInt(u16, arg[7..], 0) catch 0xB000;
        } else if (std.mem.startsWith(u8, arg, "--len=")) {
            result.xram_length = std.fmt.parseInt(u16, arg[6..], 0) catch 64;
        } else if (std.mem.startsWith(u8, arg, "--byte=")) {
            result.xram_value = std.fmt.parseInt(u8, arg[7..], 0) catch 0;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            result.xram_verify = false;
        } else if (std.mem.eql(u8, arg, "--force")) {
            result.force = true;
        } else if (std.mem.startsWith(u8, arg, "--inject-cmd=")) {
            const cmd_str = arg[13..];
            if (std.mem.eql(u8, cmd_str, "format")) {
                result.inject_command = .format_nvm;
            } else if (std.mem.eql(u8, cmd_str, "sanitize-block")) {
                result.inject_command = .sanitize_block;
            } else if (std.mem.eql(u8, cmd_str, "sanitize-crypto")) {
                result.inject_command = .sanitize_crypto;
            } else if (std.mem.eql(u8, cmd_str, "clear-wp")) {
                result.inject_command = .clear_wp;
            }
        } else if (std.mem.startsWith(u8, arg, "--nsid=")) {
            result.inject_nsid = std.fmt.parseInt(u32, arg[7..], 0) catch 0xFFFFFFFF;
        } else if (std.mem.startsWith(u8, arg, "--slot=")) {
            result.inject_slot = std.fmt.parseInt(u8, arg[7..], 0) catch null;
        } else if (std.mem.startsWith(u8, arg, "--tail=")) {
            result.inject_tail = std.fmt.parseInt(u8, arg[7..], 0) catch null;
        } else if (std.mem.startsWith(u8, arg, "--cid=")) {
            result.inject_cid = std.fmt.parseInt(u16, arg[6..], 0) catch 0x0100;
        } else if (std.mem.startsWith(u8, arg, "--reset-type=")) {
            result.reset_type = std.fmt.parseInt(u8, arg[13..], 0) catch 0x01;
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
        \\DIAGNOSTIC COMMANDS:
        \\    probe         Probe device capabilities and identify bridge type
        \\    identify      Get NVMe Identify Controller/Namespace data
        \\    smart         Get NVMe SMART/Health log
        \\
        \\XRAM COMMANDS (bypass 0xe6 whitelist via direct bridge XRAM access):
        \\    xram-probe    Probe XRAM capabilities (safe, read-only)
        \\    xram-read     Read bytes from XRAM address
        \\    xram-write    Write a single byte to XRAM
        \\    xram-dump     Hex dump an XRAM region
        \\    inject        Inject NVMe command via XRAM SQ bypass (EXPERIMENTAL)
        \\    reset         Send bridge reset (CPU or PCIe)
        \\
        \\LEGACY COMMANDS (blocked by 0xe6 whitelist -- use inject instead):
        \\    format        Format NVM via 0xe6 (silently dropped by bridge)
        \\    sanitize      Sanitize via 0xe6 (silently dropped by bridge)
        \\    get-features  Query feature via 0xe6 (silently dropped by bridge)
        \\    set-features  Set feature via 0xe6 (silently dropped by bridge)
        \\    security-recv Security Receive via 0xe6 (silently dropped by bridge)
        \\    security-send Security Send via 0xe6 (silently dropped by bridge)
        \\
        \\OTHER:
        \\    replay        Replay captured command sequence from JSON file
        \\    help          Show this help message
        \\
        \\GENERAL OPTIONS:
        \\    --dry-run        Show what would be done without executing
        \\    --force          Required for destructive inject operations
        \\    --verbose, -v    Enable verbose output
        \\    --json           Output in JSON format
        \\
        \\XRAM OPTIONS:
        \\    --addr=0xNNNN    XRAM address (default: 0xB000 = Admin SQ)
        \\    --len=N          Read/dump length in bytes (default: 64)
        \\    --byte=0xNN      Value for xram-write
        \\    --no-verify      Skip write verification readback
        \\    --inject-cmd=CMD format | sanitize-block | sanitize-crypto | clear-wp
        \\    --nsid=N         Namespace ID for inject (default: 0xFFFFFFFF)
        \\    --ses=N          Secure Erase Setting (0=none, 1=user, 2=crypto)
        \\    --reset-type=N   0=CPU reset, 1=PCIe reset (default: 1)
        \\
        \\LEGACY OPTIONS:
        \\    --fid=N          Feature ID for get/set-features (default: 0x84)
        \\    --value=N        Value for set-features
        \\    --save           Save feature persistently
        \\    --protocol=N     Security protocol (0x00=info, 0xEF=ATA password)
        \\    --sp-specific=N  Protocol-specific value
        \\    --asm-only       Filter to ASMedia commands only (for replay)
        \\
        \\EXAMPLES:
        \\    asm2362-tool probe /dev/sdb                              # Safe: detect bridge
        \\    asm2362-tool smart /dev/sdb --json                       # Safe: read SMART
        \\    asm2362-tool xram-probe /dev/sdb                         # Safe: probe XRAM
        \\    asm2362-tool xram-dump --addr=0xB000 --len=512 /dev/sdb  # Dump Admin SQ
        \\    asm2362-tool xram-dump --addr=0xB200 --len=256 /dev/sdb  # Dump MMIO regs
        \\    asm2362-tool inject --inject-cmd=format --dry-run /dev/sdb
        \\    asm2362-tool inject --inject-cmd=format --force /dev/sdb  # LIVE injection
        \\    asm2362-tool reset --reset-type=1 /dev/sdb               # PCIe soft reset
        \\
        \\DEVICE:
        \\    SCSI device path (/dev/sdX) for USB-attached NVMe drive.
        \\    Do NOT use NVMe paths (/dev/nvmeX) -- this tool uses SCSI passthrough.
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
            std.debug.print("WARNING: The ASM2362 0xe6 whitelist blocks Format NVM (0x80).\n", .{});
            std.debug.print("This command will be silently dropped by the bridge firmware.\n\n", .{});
            std.debug.print("Use 'inject --inject-cmd=format' for XRAM injection bypass.\n", .{});
            std.debug.print("Or connect directly to M.2 PCIe and use nvme-cli.\n", .{});
        },
        .sanitize => {
            std.debug.print("WARNING: The ASM2362 0xe6 whitelist blocks Sanitize (0x84).\n", .{});
            std.debug.print("This command will be silently dropped by the bridge firmware.\n\n", .{});
            std.debug.print("Use 'inject --inject-cmd=sanitize-block' for XRAM injection bypass.\n", .{});
            std.debug.print("Or connect directly to M.2 PCIe and use nvme-cli.\n", .{});
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
        // ── XRAM Commands ─────────────────────────────────────────
        .xram_probe => {
            xram.probeXram(allocator, device_path, args.verbose) catch |err| {
                std.debug.print("XRAM probe failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
        .xram_read => {
            std.debug.print("XRAM Read: addr=0x{x:0>4}, len={d}\n", .{ args.xram_address, args.xram_length });
            xram.dumpRegion(allocator, device_path, args.xram_address, args.xram_length) catch |err| {
                std.debug.print("XRAM read failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
        .xram_dump => {
            xram.dumpRegion(allocator, device_path, args.xram_address, args.xram_length) catch |err| {
                std.debug.print("XRAM dump failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
        .xram_write => {
            std.debug.print("XRAM Write: addr=0x{x:0>4}, value=0x{x:0>2}\n", .{ args.xram_address, args.xram_value });
            if (args.dry_run) {
                std.debug.print("DRY RUN: Would write 0x{x:0>2} to XRAM 0x{x:0>4}\n", .{ args.xram_value, args.xram_address });
            } else {
                if (!xram.isWriteAddressSafe(args.xram_address)) {
                    std.debug.print("WARNING: Address 0x{x:0>4} is outside safe write regions.\n", .{args.xram_address});
                    if (!args.force) {
                        std.debug.print("Use --force to override.\n", .{});
                        std.process.exit(1);
                    }
                }
                const result = xram.xdataWrite(allocator, device_path, args.xram_address, args.xram_value, args.xram_verify) catch |err| {
                    std.debug.print("XRAM write failed: {s}\n", .{@errorName(err)});
                    std.process.exit(1);
                };
                std.debug.print("Result: success={}, verified={}, duration={d}ms\n", .{
                    result.success, result.verified, result.duration_ms,
                });
            }
        },
        .admin_cq => {
            // Admin CQ discovered at XRAM 0xBC00 (16-byte NVMe CQ entries)
            const ADMIN_CQ_BASE: u16 = 0xBC00;
            const CQ_ENTRY_SIZE: u16 = 16;
            const num_entries: u16 = 8; // Read 8 entries (128 bytes)

            std.debug.print("Admin Completion Queue (0x{x:0>4}, {d} entries)\n", .{ ADMIN_CQ_BASE, num_entries });
            std.debug.print("=============================================\n\n", .{});

            const cq_data = xram.readRange(allocator, device_path, ADMIN_CQ_BASE, num_entries * CQ_ENTRY_SIZE) catch |err| {
                std.debug.print("Failed to read Admin CQ: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer allocator.free(cq_data);

            var i: u16 = 0;
            while (i < num_entries) : (i += 1) {
                const off = i * CQ_ENTRY_SIZE;
                const e = cq_data[off .. off + CQ_ENTRY_SIZE];
                const sqhd = @as(u16, e[8]) | (@as(u16, e[9]) << 8);
                const sqid = @as(u16, e[10]) | (@as(u16, e[11]) << 8);
                const cid_val = @as(u16, e[12]) | (@as(u16, e[13]) << 8);
                const status = @as(u16, e[14]) | (@as(u16, e[15]) << 8);
                const phase = status & 1;
                const sc = (status >> 1) & 0xFF;
                const sct = (status >> 9) & 0x7;
                const dnr = (status >> 14) & 1;

                const is_empty = std.mem.allEqual(u8, e, 0);
                if (is_empty) {
                    std.debug.print("  [{d}] (empty)\n", .{i});
                } else {
                    std.debug.print("  [{d}] SQHD={d} SQID={d} CID=0x{x:0>4} P={d} SCT={d} SC=0x{x:0>2} DNR={d}", .{
                        i, sqhd, sqid, cid_val, phase, sct, sc, dnr,
                    });
                    if (sc == 0 and sct == 0) {
                        std.debug.print(" (Success)\n", .{});
                    } else if (sct == 1 and sc == 0x0F) {
                        std.debug.print(" (Feature Not Savable)\n", .{});
                    } else if (sct == 1 and sc == 0x0D) {
                        std.debug.print(" (Feature Not Changeable)\n", .{});
                    } else if (sct == 0 and sc == 0x01) {
                        std.debug.print(" (Invalid Command Opcode)\n", .{});
                    } else if (sct == 0 and sc == 0x02) {
                        std.debug.print(" (Invalid Field)\n", .{});
                    } else if (sct == 0 and sc == 0x0B) {
                        std.debug.print(" (Invalid Namespace or Format)\n", .{});
                    } else if (sct == 0 and sc == 0x1D) {
                        std.debug.print(" (Sanitize In Progress)\n", .{});
                    } else {
                        std.debug.print("\n", .{});
                    }
                }
            }
        },
        .inject => {
            const cid = args.inject_cid;
            const entry = switch (args.inject_command) {
                .format_nvm => xram.craftFormatNvmEntry(args.inject_nsid, 0, @truncate(args.ses), cid),
                .sanitize_block => xram.craftSanitizeEntry(2, cid),
                .sanitize_crypto => xram.craftSanitizeEntry(4, cid),
                .clear_wp => xram.craftSetFeaturesEntry(0x84, 1, 0, true, cid),
            };

            std.debug.print("\n", .{});
            std.debug.print("  XRAM INJECTION -- EXPERIMENTAL\n", .{});
            std.debug.print("  Command: {s}\n", .{switch (args.inject_command) {
                .format_nvm => "Format NVM (0x80)",
                .sanitize_block => "Sanitize Block Erase (0x84, SANACT=2)",
                .sanitize_crypto => "Sanitize Crypto Erase (0x84, SANACT=4)",
                .clear_wp => "Set Features: Clear Write Protect (0x09, FID=0x84)",
            }});
            std.debug.print("  OPC=0x{x:0>2}, NSID=0x{x:0>8}, CDW10=0x{x:0>8}, CID=0x{x:0>4}\n", .{
                entry.getOpcode(), entry.nsid, entry.cdw10, cid,
            });
            if (args.inject_slot) |s| std.debug.print("  Explicit slot: {d}\n", .{s});
            if (args.inject_tail) |t| std.debug.print("  Explicit tail: {d}\n", .{t});
            std.debug.print("\n", .{});

            const is_dry = args.dry_run or !args.force;
            if (is_dry and !args.dry_run) {
                std.debug.print("Use --force to execute (doorbell will be rung).\n", .{});
                std.debug.print("Running in dry-run mode (write + verify without doorbell).\n\n", .{});
            }

            const result = xram.injectCommand(
                allocator,
                device_path,
                entry,
                is_dry,
                args.verbose or is_dry,
                args.inject_slot,
                args.inject_tail,
            ) catch |err| {
                std.debug.print("Injection failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };

            std.debug.print("\nInjection result:\n", .{});
            std.debug.print("  Slot used: {d}\n", .{result.slot_used});
            std.debug.print("  Bytes written: {d}\n", .{result.bytes_written});
            std.debug.print("  Verified: {}\n", .{result.verified});
            std.debug.print("  Doorbell rung: {}\n", .{result.doorbell_rung});
            std.debug.print("  Duration: {d}ms\n", .{result.total_duration_ms});
        },
        .reset => {
            const reset_type: xram.ResetType = @enumFromInt(args.reset_type);
            std.debug.print("Bridge Reset: {s}\n", .{reset_type.toString()});
            if (args.dry_run) {
                std.debug.print("DRY RUN: Would send {s}\n", .{reset_type.toString()});
            } else {
                xram.resetBridge(device_path, reset_type) catch |err| {
                    std.debug.print("Reset failed: {s}\n", .{@errorName(err)});
                    std.process.exit(1);
                };
                std.debug.print("Reset command sent.\n", .{});
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
