# SP Toolbox Binary Analysis Findings

**Date**: 2026-01-21
**Version Analyzed**: SP Toolbox V4.1.2 (Nov 28, 2025)

## Architecture Overview

SP Toolbox is a .NET Windows Forms application that spawns native command-line tools for actual device operations:

```
SP Toolbox.exe (.NET GUI)
       │
       ├── SCSICmd.exe      - ASMedia USB-NVMe passthrough
       ├── PCIECMD.exe      - Native PCIe NVMe commands
       ├── ATATest.exe      - ATA/SATA operations
       ├── Phison_Smart.exe - Phison controller SMART
       └── Other plugins...
```

## Key Findings

### 1. ASMedia 0xe6 Passthrough (SCSICmd.exe)

Found CDB construction patterns at:

| Location | Command | CDB Bytes |
|----------|---------|-----------|
| RVA 0x01ada | Identify | `e6 06` |
| RVA 0x01d0a | Get Log Page | `e6 02` |

**CDB Structure** (16 bytes):
```
Byte 0:  0xe6          - ASMedia passthrough opcode
Byte 1:  NVMe opcode   - (0x06=Identify, 0x02=GetLog, etc.)
Byte 2:  Reserved
Byte 3:  CDW10[7:0]
...
```

**Limitation**: SCSICmd.exe only implements Identify and Get Log Page - no Format NVM or Sanitize commands in this tool.

### 2. SP Toolbox.exe Key Methods (.NET)

| Method | RVA | Purpose |
|--------|-----|---------|
| DoASMedia_SCSICommand | 0x13560 | ASMedia USB passthrough |
| Security_Erase | 0x16090 | Initiate secure erase |
| do_Erase | 0x163fc | Execute erase operation |
| getIdentify_nvme | 0x0966c | NVMe identify command |
| smart_NVME | 0x09e48 | NVMe SMART data |

### 3. Command Line Interface

SP Toolbox spawns plugins with arguments like:
```
SCSICmd.exe -dsk <device> -SD
ATATest.exe -smart
Phison_Smart.exe -disk=<N> -device=<path>
```

**Security Erase** (ATA drives):
```
-security-set-pass <password>
-security-erase
```

### 4. 0xe6 Pattern Locations in SP Toolbox.exe

Multiple 0xe6 patterns found (likely in obfuscated .NET IL or resources):

| NVMe Opcode | Count | Purpose |
|-------------|-------|---------|
| 0x02 | 17 | Get Log Page |
| 0x06 | 8 | Identify |
| 0x09 | 6 | Set Features |
| 0x0a | 9 | Get Features |
| 0x80 | 5 | **Format NVM** |
| 0x81 | 4 | Security Receive |
| 0x82 | 14 | Security Send |
| 0x84 | 6 | **Sanitize** |

**Critical**: Format NVM (0x80) and Sanitize (0x84) patterns exist in SP Toolbox.exe, suggesting these commands may be implemented in the .NET code directly rather than via external tools.

### 5. P/Invoke Signatures

SP Toolbox imports DeviceIoControl with multiple signatures:
```csharp
[DllImport("kernel32.dll")]
bool DeviceIoControl(
    IntPtr hDevice,
    uint dwIoControlCode,
    IntPtr lpInBuffer,
    uint nInBufferSize,
    IntPtr lpOutBuffer,
    uint nOutBufferSize,
    out uint lpBytesReturned,
    IntPtr lpOverlapped
);
```

IOCTL codes used:
- `0x4d014` - IOCTL_SCSI_PASS_THROUGH_DIRECT
- `0x2d1400` - IOCTL_STORAGE_QUERY_PROPERTY

### 6. PCIECMD.exe Analysis

Uses native Windows NVMe driver interface (not USB passthrough):
- IOCTL_STORAGE_QUERY_PROPERTY for device enumeration
- Designed for PCIe-attached NVMe drives
- **Not usable for USB-NVMe bridges**

## Implications for Recovery

### Good News
1. SP Toolbox contains Format NVM (0x80) and Sanitize (0x84) patterns
2. ASMedia 0xe6 passthrough is implemented
3. Security erase functionality exists

### Challenges
1. Format/Sanitize may be gated by device detection logic
2. Commands may require specific drive model strings to enable
3. The .NET code may check VID:PID before exposing features

## Next Steps

1. **USB Capture**: Run SP Toolbox with Wireshark capturing USB traffic to see actual CDB bytes sent for each operation

2. **Wine Testing**: Try running SP Toolbox under Wine to capture commands without a Windows VM

3. **Dynamic Analysis**: Use Frida to hook DeviceIoControl in real-time and log exact CDB sequences

4. **Feature Enable**: Look for drive model checks that may gate Format/Sanitize buttons

## File Locations

```
downloads/SP_Toolbox_V4.1.2-20251128/
├── SP Toolbox.exe          # Main .NET app (5.3MB)
├── DriveCheck.exe          # Simple launcher
└── Plugin/
    ├── SCSICmd.exe         # ASMedia passthrough
    ├── PCIECMD.exe         # Native NVMe
    ├── ATATest.exe         # ATA operations
    └── Phison_Smart.exe    # Phison SMART
```

## Tools Used

- pefile (PE parsing)
- dnfile (.NET metadata)
- capstone (x86 disassembly)
- strings (string extraction)
