# Phase 3 Research Summary: SP Toolbox & Frida RE

**Date**: 2026-01-21
**Status**: Research Complete, Implementation In Progress

---

## Key Findings

### 1. SP Toolbox Limitations

**Critical Discovery**: SP Toolbox has significant limitations that affect our recovery strategy:

1. **USB Bridge Detection**: SP Toolbox often cannot detect drives via USB bridges - expects direct SATA/NVMe connection
2. **Secure Erase Blocked**: "This function may be unavailable for most SSDs" - Windows inbox driver blocks Format (0x80) and Sanitize except in WinPE
3. **Vendor Commands Restricted**: Only opcodes 0xC0-0xFF allowed via `IOCTL_STORAGE_PROTOCOL_COMMAND`, and only if Command Effects Log permits

### 2. Windows Storage Stack

```
Application (SP Toolbox)
    ↓
DeviceIoControl (kernel32.dll)
    ↓
┌─────────────────────────────────────────┐
│ IOCTL_SCSI_PASS_THROUGH_DIRECT (0x4d014)│ ← For USB bridges with 0xe6 CDB
│ IOCTL_STORAGE_PROTOCOL_COMMAND (0x2d0140)│ ← For native NVMe
│ IOCTL_STORAGE_QUERY_PROPERTY (0x2d1400)  │ ← For SMART/Identify
└─────────────────────────────────────────┘
    ↓
StorNVMe.sys / USB Mass Storage
    ↓
ASM2362 Bridge → NVMe SSD
```

### 3. ASM2362 Passthrough Protocol

The 0xe6 vendor CDB format (confirmed from smartmontools):

```
CDB[0]  = 0xe6           // ASMedia passthrough opcode
CDB[1]  = NVMe opcode    // 0x06=Identify, 0x02=GetLog, 0x80=Format, 0x84=Sanitize
CDB[2]  = Reserved
CDB[3]  = CDW10[7:0]     // Low byte
CDB[4]  = Reserved
CDB[5]  = Reserved
CDB[6]  = CDW10[23:16]
CDB[7]  = CDW10[31:24]
CDB[8-11] = CDW13        // Big-endian
CDB[12-15] = CDW12       // Big-endian
```

**Limitation**: CDW11, CDW14, CDW15 NOT supported by ASMedia bridges.

### 4. Phison Controller Info

Silicon Power uses Phison controllers:
- **PS5012-E12** (PCIe Gen3) - Common in P34A series
- **PS3111-S11** (SATA) - Budget drives, prone to "SATAFIRM S11" failure

**Safe Mode**: Phison controllers enter read-only safe mode when FTL corruption detected. Recovery requires:
- Shorting service pins to enter factory mode
- Professional tools (PC-3000 SSD)
- Direct NAND access bypassing controller

### 5. "Medium Not Present" Root Cause

Our drive's behavior matches documented Phison failure patterns:
- FTL (Flash Translation Layer) corruption from power loss during hibernate
- Controller enters protective mode blocking admin commands
- Data path still works (SCSI reads succeed)
- Admin command path broken ("Medium not present")

---

## Frida Capture Strategy

### Primary Targets

1. **IOCTL_SCSI_PASS_THROUGH_DIRECT** (0x4d014)
   - Most likely used for ASM2362 passthrough
   - Parse SCSI_PASS_THROUGH_DIRECT structure
   - Capture 0xe6 CDBs with NVMe opcodes

2. **IOCTL_STORAGE_QUERY_PROPERTY** (0x2d1400)
   - Used for SMART/Identify queries
   - Capture StorageAdapterProtocolSpecificProperty requests

3. **CreateFileW**
   - Map handles to device paths (\\.\PhysicalDriveX)
   - Track which handle corresponds to target drive

### Expected Command Sequence (Secure Erase)

1. **Open Device** → CreateFileW("\\.\PhysicalDrive2")
2. **Identify Controller** → 0xe6 CDB, NVMe opcode 0x06, CNS=1
3. **Get SMART Log** → 0xe6 CDB, NVMe opcode 0x02, LID=2
4. **Get Features** → 0xe6 CDB, NVMe opcode 0x0A
5. **Security Unlock** (if needed) → 0xe6 CDB, NVMe opcode 0x82
6. **Format NVM** → 0xe6 CDB, NVMe opcode 0x80, SES=1 or 2
7. **OR Sanitize** → 0xe6 CDB, NVMe opcode 0x84, SANACT=2 or 4

---

## Alternative Tools

### API Monitor (Recommended for Initial Capture)
- Free Windows tool: http://www.rohitab.com/apimonitor
- Can decode IOCTL codes automatically
- Captures async I/O completions
- Easier initial analysis before Frida scripting

### IoctlHunter (Frida-based)
- GitHub: https://github.com/Z4kSec/IoctlHunter
- `pip install IoctlHunter`
- Similar to our hooks.js but more mature

### nvmetool-win (Reference Implementation)
- GitHub: https://github.com/ken-yossy/nvmetool-win
- Windows NVMe command tool
- Good reference for IOCTL structures

---

## Recovery Path Forward

### Option A: Frida Capture (Current Focus)
1. Improve hooks.js with research findings
2. Run SP Toolbox on Windows VM with Frida attached
3. Capture any vendor-specific recovery commands
4. Implement replay in asm2362-tool

### Option B: Direct M.2 Connection
1. Remove drive from USB enclosure
2. Connect directly to M.2 slot
3. Use native nvme-cli commands
4. May enable Format/Sanitize that USB bridge blocks

### Option C: Extended Power Cycle
1. Disconnect drive completely
2. Wait 5+ minutes (drain all capacitors)
3. Some controllers reset to factory state
4. Reconnect and retry

### Option D: Professional Recovery
1. PC-3000 SSD with Phison support
2. Service pin shorting for factory mode
3. ~$300-500 for professional service

---

## Files to Update

| File | Changes |
|------|---------|
| `src/frida/hooks.js` | Add improvements from research |
| `src/frida/capture.py` | Python Frida controller script |
| `src/frida/replay.zig` | Command replay from JSON |

---

## Sources

### Windows Storage
- [Microsoft - Working with NVMe Drives](https://learn.microsoft.com/en-us/windows/win32/fileio/working-with-nvme-devices)
- [SCSI_PASS_THROUGH Structure](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddscsi/ns-ntddscsi-_scsi_pass_through)

### Frida Techniques
- [IoctlHunter](https://github.com/Z4kSec/IoctlHunter)
- [Red Team Notes - Windows API Hooking](https://www.ired.team/miscellaneous-reversing-forensics/windows-kernel-internals/instrumenting-windows-apis-with-frida)

### SSD Recovery
- [ACE Lab PC-3000 SSD](https://www.acelaboratory.com/pc-3000-ssd.php)
- [sedutil NVMe passthrough](https://github.com/Drive-Trust-Alliance/sedutil/issues/463)
