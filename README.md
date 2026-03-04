# ASM2362 NVMe Recovery Research

Experimental research into recovering NVMe SSDs exhibiting firmware-level write protection after FTL corruption. **This is not production software.**

## The Problem

A 256GB Silicon Power NVMe SSD connected via ASMedia ASM2362 USB bridge exhibits silent write failure after a Windows hibernate + power loss event.

| Operation | Reports | Actual |
|-----------|---------|--------|
| `dd if=/dev/zero of=/dev/sdb` | Success | Data unchanged |
| `wipefs --all` | Success | Signatures remain |
| SCSI READ | Success | Data readable |
| SCSI WRITE | Success | Silent failure |
| NVMe admin commands | Fail | "Medium not present" (ASC=0x3A) |

Standard Linux disk tools (fdisk, gdisk, blkdiscard, sg_format) all fail to modify the drive despite reporting success.

---

## Hardware Stack

```
+---------------------------------------------+
|  NVMe SSD: Silicon Power 256GB              |
|  Controller: Phison PS5012-E12 (likely)     |
|  State: FTL corrupted, read-only mode       |
+----------------------+----------------------+
                       | M.2 PCIe
+----------------------+----------------------+
|  USB Bridge: ASMedia ASM2362                |
|  VID:PID = 0x174c:0x2362                    |
|  Passthrough: 0xe6 CDB (NVMe tunneling)     |
+----------------------+----------------------+
                       | USB 3.1 Gen 2
+----------------------+----------------------+
|  Linux: UAS driver -> /dev/sdb              |
+---------------------------------------------+
```

---

## Technical Reference

### SMART Critical Warning Bits

The NVMe SMART/Health log contains critical warning flags at byte offset 0:

| Bit | Mask | Meaning |
|-----|------|---------|
| 0 | 0x01 | Available spare capacity below threshold |
| 1 | 0x02 | Temperature exceeded threshold |
| 2 | 0x04 | NVM subsystem reliability degraded |
| **3** | **0x08** | **Media placed in read-only mode** |
| 4 | 0x10 | Volatile memory backup failed |

**Bit 3 (0x08) is our target.** When set, the controller has entered firmware-level protection mode. Per NVMe spec:

> "The media has been placed in read only mode. Vendor specific recovery may be required."

### SCSI Sense Data

When NVMe admin commands fail through the USB bridge:

| Field | Value | Meaning |
|-------|-------|---------|
| Sense Key | 0x02 | NOT READY |
| ASC | 0x3A | MEDIUM NOT PRESENT |
| ASCQ | 0x00 | - |

This indicates the NVMe controller is rejecting commands at firmware level, not the USB bridge.

### ASM2362 Passthrough Protocol

The ASMedia ASM2362 uses a proprietary 16-byte CDB with opcode `0xe6` to tunnel NVMe commands:

```
Byte 0:     0xe6        ASMedia passthrough opcode
Byte 1:     NVMe opcode (0x06=Identify, 0x02=GetLog, etc.)
Byte 2:     Reserved
Byte 3:     CDW10[7:0]
Byte 4-5:   Reserved
Byte 6:     CDW10[23:16]
Byte 7:     CDW10[31:24]
Bytes 8-11: CDW13 (big-endian)
Bytes 12-15: CDW12 (big-endian)
```

**Limitation**: CDW11, CDW14, CDW15 cannot be passed, restricting some admin commands.

### NVMe Opcodes via 0xe6 Passthrough

| Opcode | Command | Status |
|--------|---------|--------|
| 0x02 | Get Log Page | **Works** |
| 0x06 | Identify | **Works** |
| 0x09 | Set Features | Blocked by whitelist |
| 0x0A | Get Features | Blocked by whitelist |
| 0x80 | Format NVM | Blocked by whitelist |
| 0x81 | Security Receive | Blocked by whitelist |
| 0x82 | Security Send | Blocked by whitelist |
| 0x84 | Sanitize | Blocked by whitelist |

Blocked opcodes can be sent via **XRAM injection** (0xE4/0xE5) instead. See [docs/archive/dead-ends-e6-whitelist.md](docs/archive/dead-ends-e6-whitelist.md) for details.

### Write Protection Feature (FID 0x84)

NVMe 1.4+ namespace write protection states:

| Value | State | Persistence |
|-------|-------|-------------|
| 0x00 | No Write Protect | N/A |
| 0x01 | Write Protect | Survives power cycles |
| 0x02 | Write Protect Until Power Cycle | Clears on reboot |
| 0x03 | Permanent Write Protect | **Irreversible** |

### Security Protocols

| Protocol | Purpose |
|----------|---------|
| 0x00 | Discovery - list supported protocols |
| 0xEF | ATA Device Server Password |
| 0x01-0x06 | TCG Opal |

### ASM2362 Vendor SCSI Commands (Beyond 0xe6)

| Opcode | Direction | Command | Purpose |
|--------|-----------|---------|---------|
| 0xE0 | Read | Read Config | 128 bytes bridge configuration |
| 0xE1 | Write | Write Config | Modify bridge configuration |
| 0xE2 | Read | Flash Read | Read SPI flash contents |
| 0xE3 | Write | Firmware Write | Flash firmware (from address 0x80) |
| 0xE4 | Read | **XDATA Read** | Read up to 255 bytes from bridge XRAM |
| 0xE5 | Write | **XDATA Write** | Write single byte to bridge XRAM |
| 0xE6 | Read | NVMe Admin | NVMe passthrough (only 0x02, 0x06) |
| 0xE8 | None | Reset | 0x00=CPU reset, 0x01=PCIe/soft reset |

### ASM2362 XRAM Memory Map

| Address | Size | Contents |
|---------|------|----------|
| 0xA000-0xAFFF | 4KB | NVMe I/O Submission Queue |
| 0xB000-0xB1FF | 512B | NVMe Admin Submission Queue |
| 0xB200-0xB7FF | 1.5KB | PCIe controller MMIO registers |
| 0xF000-0xFFFF | 4KB | NVMe generic data buffer |

### ASM2362 Hardware

- CPU: 8051-compatible core, ~114.3 MHz
- XRAM: 64KB mapped memory
- No firmware signature verification
- UART debug: 921600 8N1, 3.3V (pins 62/63)

Source: [cyrozap/usb-to-pcie-re](https://github.com/cyrozap/usb-to-pcie-re)

---

## Hypothesis

We believe SMART Critical Warning Bit 3 (0x08) is set, causing:

1. **Read path functional** - FTL read mappings intact
2. **Write path blocked** - FTL refuses to update NAND
3. **Admin commands blocked** - "Medium not present"

Recovery requires a vendor-specific command sequence to clear this protection state.

### Key Findings (Feb 2026 Deep Research)

**Bit 3 is not a flag you can flip.** It reflects autonomous firmware state persisted in the controller's NAND service area. No standard NVMe command clears it. Feature 0x84 (namespace write protection) is a separate mechanism entirely.

**The ASM2362 only passes two NVMe opcodes** through 0xe6: Identify (0x06) and Get Log Page (0x02). All other commands (Format, Sanitize, Security Send/Receive, Set/Get Features) are silently dropped by a firmware-level whitelist. This means most recovery commands cannot reach the drive through USB.

**However**, the ASM2362 exposes XRAM access commands (0xE4 read, 0xE5 write) that can write directly to the NVMe Admin Submission Queue at XRAM 0xB000-0xB1FF, potentially bypassing the whitelist.

**"Medium not present" is a SCSI error generated by the bridge**, not the NVMe drive. On native M.2 PCIe, admin commands should work even in read-only mode.

### Recovery Priority Stack

| Priority | Approach | Probability |
|----------|----------|-------------|
| 1 | **Phison Reinitial Tool** (usbdev.ru) -- designed for this exact failure, supports ASM2362 | High |
| 2 | **Native M.2 PCIe** -- eliminates bridge, try `nvme format --ses=1` (one documented success on Phison) | Medium-High |
| 3 | **XRAM queue injection** -- bypass 0xe6 whitelist via 0xE5 writes to Admin SQ | Medium |
| 4 | **SP Toolbox Frida capture** on real Windows -- extract vendor command sequence | Medium |
| 5 | **PC-3000 professional** (Rossmann Group) -- PS5012 now supported | Last resort |

### Abandoned Tracks

| Track | Reason |
|-------|--------|
| Wine + SP Toolbox | Wine lacks IOCTL_SCSI_PASS_THROUGH_DIRECT support |
| Set Features 0x84 to clear bit 3 | Separate mechanism from firmware read-only |
| 0xe6 passthrough for Format/Sanitize | Bridge firmware whitelist blocks all but 0x02/0x06 |

See [docs/research/deep-research-synthesis.md](docs/research/deep-research-synthesis.md) for full analysis.

---

## Silent Write Failure Evidence

### Test 1: dd to Sector 0
```
$ sudo dd if=/dev/zero of=/dev/sdb bs=512 count=1 conv=fsync oflag=direct
512 bytes copied

$ sudo xxd -l 64 /dev/sdb
00000000: 33c0 8ed0 bc00 7c8e...  # MBR boot code - NOT ZEROS
```

### Test 2: wipefs
```
$ sudo wipefs --all --force /dev/sdb
/dev/sdb: 8 bytes were erased at offset 0x200 (gpt)

$ sudo xxd -s 512 -l 8 /dev/sdb
00000200: 4546 4920 5041 5254  # "EFI PART" still present
```

### Device Characteristics
| Property | Value |
|----------|-------|
| Vendor | SPCC M.2 (Silicon Power) |
| Capacity | 256 GB (500118192 sectors) |
| Sector Size | 512 bytes |
| Connection | USB via UAS driver |
| WP Flag | OFF (reports writable) |
| blockdev --getro | 0 |

---

## Building

Requires Zig 0.13.0 or later.

```bash
zig build
```

### Diagnostic Commands (read-only, safe)

```bash
sudo ./zig-out/bin/asm2362-tool probe /dev/sdX        # Detect bridge type
sudo ./zig-out/bin/asm2362-tool identify /dev/sdX      # NVMe Identify Controller
sudo ./zig-out/bin/asm2362-tool smart /dev/sdX --json  # SMART log (JSON output)
```

### XRAM Commands (bridge-level access)

```bash
# Read-only probe — tests 0xE4 support, dumps Admin SQ, MMIO, data buffer
sudo ./zig-out/bin/asm2362-tool xram-probe /dev/sdX

# Raw XRAM read/write
sudo ./zig-out/bin/asm2362-tool xram-read --addr=0xB000 --len=64 /dev/sdX
sudo ./zig-out/bin/asm2362-tool xram-dump --addr=0xB000 --len=512 /dev/sdX
sudo ./zig-out/bin/asm2362-tool xram-write --addr=0xB000 --byte=0x00 /dev/sdX

# NVMe command injection via XRAM (dry-run by default)
sudo ./zig-out/bin/asm2362-tool inject --inject-cmd=format /dev/sdX         # dry-run
sudo ./zig-out/bin/asm2362-tool inject --inject-cmd=format --force /dev/sdX  # live

# Bridge reset
sudo ./zig-out/bin/asm2362-tool reset --reset-type=1 /dev/sdX  # PCIe soft reset
```

### Running Tests

```bash
zig build test       # main.zig tests
zig build test-all   # all module tests (sg_io, sense, passthrough, replay, xram)
```

---

## Implementation Status

| Component | Status |
|-----------|--------|
| SCSI SG_IO layer | Complete |
| ASM2362 0xe6 passthrough | Complete (Identify + SMART work; others blocked by whitelist) |
| XRAM access (0xE4/0xE5/0xE8) | Complete |
| XRAM NVMe command injection | Complete (dry-run default, doorbell via PCIe reset) |
| NVMe Identify + SMART | Complete |
| Format NVM / Sanitize (via 0xe6) | Archived — [dead end](docs/archive/dead-ends-e6-whitelist.md) |
| Frida hooks for Windows | Complete |
| Command replay | Complete |

~4,000 lines of Zig with 35 unit tests.

---

## Active Investigation Tracks

**Track 1 - Phison Reinitial Tool**: Pre-built recovery tool from usbdev.ru designed for PS5012-E12 with ASM2362 support. Requires Windows, NAND type identification via Flash ID2, and matching firmware file.

**Track 2 - Native M.2 + nvme-cli**: Bypass USB bridge entirely. Confirm SMART bit 3, attempt `nvme format --ses=1` (secure erase), `nvme sanitize --sanact=2` (block erase), controller resets.

**Track 3 - XRAM Queue Injection**: Use ASM2362 vendor commands 0xE4/0xE5 to write NVMe admin commands directly to the Admin Submission Queue in bridge XRAM, bypassing the 0xe6 opcode whitelist.

**Track 4 - SP Toolbox Frida Capture**: Hook DeviceIoControl on real Windows to capture exact vendor command sequence during Secure Erase. Look for 0xE4/0xE5 XRAM commands, not just 0xe6.

**Track 5 - PC-3000 Professional**: PS5012 is now on the PC-3000 supported list. Rossmann Group has documented E12 capability. $300-1500.

---

## Project Structure

```
src/                    Zig tool source
  main.zig             CLI entry point
  scsi/                SG_IO wrapper, sense parsing
  asm2362/
    passthrough.zig    0xe6 CDB passthrough (Identify, SMART only)
    xram.zig           0xE4/0xE5/0xE8 XRAM access + NVMe injection
    commands.zig       NVMe command helpers
  nvme/                NVMe command implementations (identify)
  frida/               Windows hooks and capture

scripts/
  vm/                  Windows VM management
  analysis/            USB capture, decode, comparison
  setup/               Environment configuration

docs/
  notes/               Research findings
  analysis/            Binary analysis findings
  research/            Unlock sequence hypotheses
  workflows/           Procedure documentation
```

See [docs/INDEX.md](docs/INDEX.md) for documentation navigation.

---

## Key SP Toolbox Methods (RE Target)

| Method | RVA | Purpose |
|--------|-----|---------|
| `DoASMedia_SCSICommand` | 0x13560 | Builds 0xe6 CDB, calls DeviceIoControl |
| `Security_Erase` | 0x16090 | Erase gate logic |
| `do_Erase` | 0x163fc | Actual erase execution |

---

## References

### NVMe Specification
- [NVMe Base Specification 2.0](https://nvmexpress.org/specifications/)
- [NVMe SMART Critical Warning](https://nvmexpress.org/wp-content/uploads/NVM-Express-Base-Specification-2.0e-2024.07.29-Ratified.pdf) - Section 5.14.1.2
- [TCG Opal and NVMe](https://nvmexpress.org/wp-content/uploads/TCGandNVMe_Joint_White_Paper-TCG_Storage_Opal_and_NVMe_FINAL.pdf)

### ASM2362 Reverse Engineering
- [cyrozap/usb-to-pcie-re](https://github.com/cyrozap/usb-to-pcie-re) - ASM2362 firmware RE, XRAM map, vendor commands
- [smartmontools sntasmedia](https://github.com/smartmontools/smartmontools/blob/master/smartmontools/scsinvme.cpp) - Reference 0xe6 implementation
- [smx-smx/ASMTool](https://github.com/smx-smx/ASMTool) - ASMedia firmware dumper

### Phison Recovery Tools
- [Phison PS5012 Reinitial Tool](https://www.usbdev.ru/files/phison/ps5012reinitialtool/) - Recovery for read-only E12 drives
- [Phison NVMe Flash ID2](https://www.usbdev.ru/files/phison/phisonnvmeflashid2/) - NAND identification
- [PS5012 Firmware Library](https://www.usbdev.ru/files/phison/ps5012fw/) - Matching firmware files

### Tools
- [nvme-cli](https://github.com/linux-nvme/nvme-cli)
- [sedutil](https://github.com/Drive-Trust-Alliance/sedutil)
- [sg3_utils / sg_raw](https://sg.danny.cz/sg/sg3_utils.html)

---

## Contributing

This is active research. Useful contributions:

- USB capture data from SP Toolbox operations
- Experience with Phison controller recovery
- Ghidra/IDA analysis of SP Toolbox or SCSICmd.exe
- Documentation of 0xe6 passthrough command sequences

**Note:** The drive may be unrecoverable without professional tools (PC-3000 SSD). This research documents the failure mode and any accessible recovery paths.

## License

Research code - use at your own risk. No warranty implied.
