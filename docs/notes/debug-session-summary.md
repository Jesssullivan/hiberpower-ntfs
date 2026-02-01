# Debug Session Summary - 2026-01-21

## Hardware Stack
```
[NVMe SSD: SPCC/Silicon Power 256GB]
         ↓
[USB Bridge: ASMedia ASM2362 (0x174c:0x2362)]
         ↓
[Linux UAS Driver]
         ↓
[/dev/sdb]
```

## Commands Tested & Results

| Command | Reports | Actual Result |
|---------|---------|---------------|
| `dd if=/dev/zero` | Success | **NO WRITE** |
| `wipefs --all` | Success | **NO WRITE** |
| `sg_format` | Fail | MODE SENSE not supported |
| `sg_sanitize --block` | Fail | Sense category 9 |
| `sg_unmap` | Fail | "Medium not present" |
| `sg_write_same` | Fail | Error |
| `blkdiscard` | Fail | Not supported |
| `smartctl -d sntasmedia` | Fail | "Medium not present" |
| ASM2362 0xe6 passthrough | Fail | "Medium not present" |

## Key Finding

The NVMe controller returns **"Medium not present"** to admin commands via USB passthrough, yet SCSI read commands work. This indicates:

1. FTL (Flash Translation Layer) corruption
2. NVMe controller in firmware-level read-only/protection mode
3. Admin command path broken, data read path functional

## Agent Research Highlights

### nvme-protocol-analysis.md
- USB bridges block most NVMe admin commands
- SMART Critical Warning Bit 3 = firmware read-only mode
- ASM2362 has 0xe6 proprietary passthrough (but failing here)

### ntfs-hibernate-research.md
- Power loss during hibernate corrupts FTL
- Consumer SSDs lack power-loss protection
- 50-75% bit error rates on power-cut during writes

### linux-kernel-investigation.md
- UAS driver issues common with USB-NVMe bridges
- Async writes can silently fail
- Kernel reports writable even when firmware isn't

### lowlevel-tools-guide.md
- Custom C/Zig tools for raw NVMe ioctl
- hdparm ATA security commands (need native connection)

### literature-review.md
- SMART Critical Warning Bit 3 (0x08) = unrecoverable
- Vendor-specific commands only path to recovery
- Similar "SATAFIRM S11" corruption in Phison controllers

## Remaining Attack Vectors

1. **Native M.2 connection** - bypass USB, direct NVMe access
2. **Extended power cycle** - 5+ min, drain all capacitors
3. **Windows SP Toolbox** - vendor secure erase
4. **Custom ASM2362 exploit** - craft vendor-specific commands
5. **Phison tools** - if controller is Phison-based (UPTOOL)

## Hypothesis for Paper

The Windows hibernate + power loss sequence corrupted the NVMe FTL mapping tables. The controller entered a protective read-only mode where:
- Data reads succeed (FTL has valid read mappings)
- Writes silently fail (FTL refuses to update mappings)
- Admin commands fail (controller rejects state changes)

This is **undetectable by standard Linux tools** which check WP flags (all report writable).
