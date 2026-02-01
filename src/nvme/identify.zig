//! NVMe Identify Controller/Namespace Implementation
//!
//! Retrieve and parse NVMe Identify data via ASM2362 passthrough.

const std = @import("std");
const passthrough = @import("../asm2362/passthrough.zig");
const commands = @import("../asm2362/commands.zig");

/// Execute NVMe Identify Controller and print results
pub fn identifyController(
    allocator: std.mem.Allocator,
    device_path: []const u8,
    json_output: bool,
) !void {
    std.debug.print("Sending NVMe Identify Controller command to {s}...\n", .{device_path});

    const result = passthrough.identifyController(allocator, device_path) catch |err| {
        std.debug.print("Failed to identify controller: {s}\n", .{@errorName(err)});
        if (err == passthrough.PassthroughError.MediumNotPresent) {
            std.debug.print("\nThe drive reports 'Medium not present'. This indicates:\n", .{});
            std.debug.print("  - NVMe controller is in a firmware-level protected state\n", .{});
            std.debug.print("  - Admin commands are blocked, but SCSI reads may work\n", .{});
            std.debug.print("  - This is the expected failure mode for the corrupted SSD\n", .{});
        }
        return err;
    };
    defer if (result.data) |data| allocator.free(data);

    if (result.data) |data| {
        if (data.len < @sizeOf(commands.IdentifyController)) {
            std.debug.print("Error: Insufficient data returned ({d} bytes, expected 4096)\n", .{data.len});
            return;
        }

        const ctrl: *const commands.IdentifyController = @ptrCast(@alignCast(data.ptr));

        if (json_output) {
            printIdentifyJson(ctrl);
        } else {
            printIdentifyHuman(ctrl);
        }
    } else {
        std.debug.print("Command succeeded but no data returned\n", .{});
    }
}

fn printIdentifyHuman(ctrl: *const commands.IdentifyController) void {
    std.debug.print("\nNVMe Controller Identify Data:\n", .{});
    std.debug.print("==============================\n", .{});
    std.debug.print("Vendor ID:            0x{x:0>4}\n", .{ctrl.vid});
    std.debug.print("Subsystem Vendor ID:  0x{x:0>4}\n", .{ctrl.ssvid});
    std.debug.print("Serial Number:        {s}\n", .{ctrl.getSerialNumber()});
    std.debug.print("Model Number:         {s}\n", .{ctrl.getModelNumber()});
    std.debug.print("Firmware Revision:    {s}\n", .{ctrl.getFirmwareRevision()});
    std.debug.print("Controller ID:        {d}\n", .{ctrl.cntlid});

    // Capacity
    const cap_bytes = ctrl.getTotalCapacity();
    const cap_gb = @divFloor(cap_bytes, 1000000000);
    std.debug.print("Total NVM Capacity:   {} bytes ({} GB)\n", .{ cap_bytes, cap_gb });

    // Version
    const ver_major = (ctrl.ver >> 16) & 0xFFFF;
    const ver_minor = (ctrl.ver >> 8) & 0xFF;
    const ver_ter = ctrl.ver & 0xFF;
    std.debug.print("NVMe Version:         {}.{}.{}\n", .{ ver_major, ver_minor, ver_ter });

    // Capabilities
    std.debug.print("\nAdmin Command Support (OACS): 0x{x:0>4}\n", .{ctrl.oacs});
    std.debug.print("  Security Send/Receive: {}\n", .{(ctrl.oacs & 0x01) != 0});
    std.debug.print("  Format NVM:            {}\n", .{ctrl.supportsFormat()});
    std.debug.print("  Firmware Download:     {}\n", .{(ctrl.oacs & 0x04) != 0});
    std.debug.print("  Namespace Management:  {}\n", .{(ctrl.oacs & 0x08) != 0});
    std.debug.print("  Device Self-Test:      {}\n", .{(ctrl.oacs & 0x10) != 0});
    std.debug.print("  Directives:            {}\n", .{(ctrl.oacs & 0x20) != 0});

    std.debug.print("\nSanitize Capabilities (SANICAP): 0x{x:0>8}\n", .{ctrl.sanicap});
    std.debug.print("  Crypto Erase:          {}\n", .{ctrl.supportsCryptoErase()});
    std.debug.print("  Block Erase:           {}\n", .{ctrl.supportsBlockErase()});
    std.debug.print("  Overwrite:             {}\n", .{(ctrl.sanicap & 0x04) != 0});

    std.debug.print("\nFormat NVM Attributes (FNA): 0x{x:0>2}\n", .{ctrl.fna});
    std.debug.print("  Format applies to all NS: {}\n", .{(ctrl.fna & 0x01) != 0});
    std.debug.print("  Secure erase to all NS:   {}\n", .{(ctrl.fna & 0x02) != 0});
    std.debug.print("  Crypto erase supported:   {}\n", .{(ctrl.fna & 0x04) != 0});

    std.debug.print("\nNumber of Namespaces: {}\n", .{ctrl.nn});
    std.debug.print("\n", .{});
}

fn printIdentifyJson(ctrl: *const commands.IdentifyController) void {
    const stdout = std.io.getStdOut().writer();

    stdout.print("{{\n", .{}) catch return;
    stdout.print("  \"vid\": {},\n", .{ctrl.vid}) catch return;
    stdout.print("  \"ssvid\": {},\n", .{ctrl.ssvid}) catch return;
    stdout.print("  \"serial_number\": \"{s}\",\n", .{ctrl.getSerialNumber()}) catch return;
    stdout.print("  \"model_number\": \"{s}\",\n", .{ctrl.getModelNumber()}) catch return;
    stdout.print("  \"firmware_revision\": \"{s}\",\n", .{ctrl.getFirmwareRevision()}) catch return;
    stdout.print("  \"controller_id\": {},\n", .{ctrl.cntlid}) catch return;
    stdout.print("  \"total_capacity_bytes\": {},\n", .{ctrl.getTotalCapacity()}) catch return;
    stdout.print("  \"nvme_version\": \"{}.{}.{}\",\n", .{
        (ctrl.ver >> 16) & 0xFFFF,
        (ctrl.ver >> 8) & 0xFF,
        ctrl.ver & 0xFF,
    }) catch return;
    stdout.print("  \"oacs\": {},\n", .{ctrl.oacs}) catch return;
    stdout.print("  \"sanicap\": {},\n", .{ctrl.sanicap}) catch return;
    stdout.print("  \"fna\": {},\n", .{ctrl.fna}) catch return;
    stdout.print("  \"nn\": {},\n", .{ctrl.nn}) catch return;
    stdout.print("  \"supports_format\": {},\n", .{ctrl.supportsFormat()}) catch return;
    stdout.print("  \"supports_sanitize\": {},\n", .{ctrl.supportsSanitize()}) catch return;
    stdout.print("  \"supports_crypto_erase\": {},\n", .{ctrl.supportsCryptoErase()}) catch return;
    stdout.print("  \"supports_block_erase\": {}\n", .{ctrl.supportsBlockErase()}) catch return;
    stdout.print("}}\n", .{}) catch return;
}
