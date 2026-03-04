# Dead End: ASM2362 0xe6 Passthrough Opcode Whitelist

**Date:** 2026-02-28
**Status:** Confirmed dead end — replaced by XRAM injection (0xE4/0xE5)

## Summary

The ASMedia ASM2362 USB-to-NVMe bridge chip exposes a vendor-specific SCSI
CDB (opcode 0xe6) for tunneling NVMe admin commands over USB. This is the
mechanism used by tools like SP Toolbox, smartmontools, and nvme-cli's
`asmedia` plugin.

However, the bridge firmware only passes **two** NVMe admin opcodes through
the 0xe6 path:

| NVMe Opcode | Command | Passes? |
|-------------|---------|---------|
| 0x02 | Get Log Page | Yes |
| 0x06 | Identify | Yes |
| 0x09 | Set Features | **No** |
| 0x0a | Get Features | **No** |
| 0x80 | Format NVM | **No** |
| 0x81 | Security Receive | **No** |
| 0x82 | Security Send | **No** |
| 0x84 | Sanitize | **No** |

All other opcodes are silently dropped by the bridge firmware. The SCSI
layer returns success, but the command never reaches the NVMe controller.

## Evidence

### 1. cyrozap/usb-to-pcie-re (Firmware RE)

The definitive source. cyrozap reverse-engineered ASMedia USB bridge
firmware and documented the 0xe6 CDB format and its limitations:

> The bridge firmware parses the NVMe opcode from CDB byte 1 and
> maintains an internal allowlist. Commands not on the list are
> acknowledged at the SCSI layer but never forwarded to the PCIe/NVMe
> endpoint.

Source: https://github.com/cyrozap/usb-to-pcie-re

### 2. smartmontools (sntasmedia_device)

The smartmontools ASMedia driver (`sntasmedia_device` class in
`os_linux.cpp`) only implements Identify Controller and SMART/Health
Log retrieval. No Format, Sanitize, or Security commands are attempted:

```cpp
// Only these are implemented in sntasmedia_device:
bool ata_identify_is_cached() const { return true; }
bool nvme_pass_through(const nvme_cmd_in & in, nvme_cmd_out & out);
// ^^ internally limited to Identify and Get Log Page
```

### 3. Our Own Testing

We built Zig implementations of all 8 opcodes found in SP Toolbox USB
captures. Format (0x80) and Sanitize (0x84) consistently returned SCSI
success with no NVMe-side effect — the drive state was unchanged after
each command. Identify (0x06) and Get Log Page (0x02) worked correctly
every time.

The captured 0xe6 CDB patterns from SP Toolbox:

| Opcode | Count in Capture | Result |
|--------|-----------------|--------|
| 0x02 (Get Log) | 17 | Works |
| 0x06 (Identify) | 8 | Works |
| 0x09 (Set Features) | 6 | Silent drop |
| 0x0a (Get Features) | 9 | Silent drop |
| 0x80 (Format NVM) | 5 | Silent drop |
| 0x81 (Security Recv) | 4 | Silent drop |
| 0x82 (Security Send) | 14 | Silent drop |
| 0x84 (Sanitize) | 6 | Silent drop |

## What This Killed

### Archived Files

These files implemented the 0xe6 passthrough path for blocked commands:

- `docs/archive/format.zig.txt` — NVMe Format NVM (opcode 0x80) via 0xe6
- `docs/archive/sanitize.zig.txt` — NVMe Sanitize (opcode 0x84) via 0xe6

### Dead Functions in passthrough.zig (Kept for Reference)

The following functions in `src/asm2362/passthrough.zig` build valid CDBs
but can never succeed through the bridge:

- `buildFormatNvmCdb()` / `formatNvm()` — opcode 0x80, blocked
- `buildSanitizeCdb()` — opcode 0x84, blocked
- `buildSecuritySendCdb()` / `securitySend()` — opcode 0x82, blocked
- `buildSecurityReceiveCdb()` / `securityReceive()` — opcode 0x81, blocked
- `buildSetFeaturesCdb()` / `setFeatures()` — opcode 0x09, blocked
- `buildGetFeaturesCdb()` / `getFeatures()` — opcode 0x0a, blocked

These are retained in passthrough.zig as CDB format reference — useful if
a future firmware version lifts the whitelist or for documentation of the
0xe6 protocol.

### Working Functions in passthrough.zig

- `buildIdentifyCdb()` / `identify()` — opcode 0x06, works
- `buildGetLogPageCdb()` / `getSmartLog()` — opcode 0x02, works

## What Replaced This

### XRAM Injection via 0xE4/0xE5

The ASM2362 exposes three additional vendor SCSI commands that bypass the
0xe6 whitelist entirely:

| SCSI Opcode | Command | Direction | Size |
|-------------|---------|-----------|------|
| 0xE4 | XDATA Read | Device → Host | 1-255 bytes |
| 0xE5 | XDATA Write | Host → Device | 1 byte (in CDB) |
| 0xE8 | Reset | None | N/A |

These commands provide direct read/write access to the bridge chip's
internal XRAM address space. The NVMe Admin Submission Queue lives at
XRAM addresses 0xB000-0xB1FF. By writing a 64-byte NVMe Submission Queue
Entry directly into this region, we bypass the firmware's opcode whitelist
and inject arbitrary NVMe admin commands.

**Implementation:** `src/asm2362/xram.zig`

**Workflow:**
1. Read current Admin SQ state via 0xE4
2. Find an empty slot in the 8-entry queue
3. Write 64 bytes of NVMe SQ entry via 0xE5 (64 individual SCSI commands)
4. Verify the write via 0xE4 readback
5. Ring the doorbell (PCIe reset fallback initially)
6. Confirm post-injection state

This approach lets us send Format NVM, Sanitize, Set Features, Security
Send, and any other NVMe admin command — the full spec, not just the two
opcodes the bridge firmware approves.

## Lessons Learned

1. **USB bridges are not transparent tunnels.** They have their own firmware
   with opinions about which commands should pass through. Always verify
   actual command delivery, not just SCSI-layer success.

2. **Silent drops are worse than errors.** The bridge returns SCSI Good
   status for blocked commands, making it appear like the NVMe controller
   rejected the command or the drive is unresponsive. This misdirects
   debugging effort.

3. **Vendor SCSI commands are the real power.** The 0xe6 passthrough is
   the "official" API, but 0xE4/0xE5/0xE8 provide raw hardware access
   that the firmware cannot filter. The bridge chip is just an 8051 with
   XRAM — and we can read and write that XRAM directly.

4. **Read the firmware RE before writing code.** A few hours with
   cyrozap's documentation would have saved the entire Format/Sanitize
   implementation effort. In recovery/RE projects, the firmware defines
   what's possible — start there.
