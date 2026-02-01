# Diagnosis Findings: Silent Write Failure

**Date**: 2026-01-21
**Device**: SPCC M.2 PCIe SSD (Silicon Power) - 256GB
**Serial**: C90000000000
**Connection**: USB (UAS driver)

## Summary

The NVMe SSD exhibits **firmware-level silent write failure**. Write commands are accepted and reported as successful, but data is not actually written to NAND flash.

## Evidence

### Test 1: dd to Sector 0 (MBR)
```
$ sudo dd if=/dev/zero of=/dev/sdb bs=512 count=1 conv=fsync oflag=direct
512 bytes copied, 0.000313659 s, 1.6 MB/s

$ sudo xxd -l 64 /dev/sdb
00000000: 33c0 8ed0 bc00 7c8e...  # MBR boot code - NOT ZEROS!
```
**Result**: dd reported success, MBR unchanged.

### Test 2: wipefs signature erasure
```
$ sudo wipefs --all --force /dev/sdb
/dev/sdb: 8 bytes were erased at offset 0x200 (gpt)
/dev/sdb: 8 bytes were erased at offset 0x3b9e655e00 (gpt)
/dev/sdb: 2 bytes were erased at offset 0x1fe (PMBR)

$ sudo xxd -s 0x1fe -l 2 /dev/sdb
000001fe: 55aa    # Still present!

$ sudo xxd -s 512 -l 16 /dev/sdb
00000200: 4546 4920 5041 5254...  # "EFI PART" still present!
```
**Result**: wipefs reported success, GPT header and MBR signature unchanged.

### Test 3: Sector 2 (GPT partition entries)
```
BEFORE:
00000430: 0000 0000 0000 0000 4d00 6900 6300 7200  ........M.i.c.r.

$ sudo dd if=/dev/zero of=/dev/sdb bs=512 count=1 seek=2 conv=fsync oflag=direct
512 bytes copied, 0.00578528 s, 88.5 kB/s

AFTER:
00000430: 0000 0000 0000 0000 4d00 6900 6300 7200  ........M.i.c.r.
```
**Result**: dd reported success, data byte-for-byte identical.

## Device Characteristics

| Property | Value |
|----------|-------|
| Vendor | SPCC M.2 (Silicon Power) |
| Model | PCIe SSD |
| Capacity | 256 GB (500118192 sectors) |
| Sector Size | 512 bytes logical/physical |
| Connection | USB via UAS driver |
| Write Protect Flag | OFF (WP=0 in mode pages) |
| blockdev --getro | 0 (reports writable) |

## USB Bridge Limitations

The USB-NVMe bridge does NOT support:
- ATA PASS-THROUGH commands (sg_sat_identify fails)
- SCSI log sense
- SCSI mode page 1
- BLKDISCARD ioctl (TRIM)
- Full sg_format (fails on MODE SENSE)

## Root Cause Hypothesis

1. **Power loss during Windows hibernate** corrupted the NVMe Flash Translation Layer (FTL)
2. The NVMe controller entered **firmware-level read-only mode** as a protective measure
3. The controller accepts write commands for protocol compliance but does not commit them to NAND
4. This is NOT detectable via standard Linux write-protect checks (WP flag is OFF)
5. The USB bridge prevents access to NVMe admin commands that could diagnose/fix the issue

## NVMe Firmware Read-Only Mode

Per NVMe specification, when **SMART/Health Critical Warning Bit 3** (`0x08`) is set:
- Controller may place drive in read-only mode
- Media/internal errors have occurred
- Only vendor-specific commands may be able to clear this state

To check this bit, native M.2 connection is required:
```bash
nvme smart-log /dev/nvmeXnY | grep -i critical
```

## Recommended Next Steps

1. **Extended power cycle**: Disconnect for 5+ minutes (drain capacitors)
2. **Native M.2 connection**: Bypass USB bridge, check SMART data
3. **NVMe secure erase**: `nvme format /dev/nvmeXnY --ses=1`
4. **Vendor tools**: Contact Silicon Power for recovery utilities
5. **Last resort**: `nvme sanitize` or firmware reflash

## Relevant Research

- UC San Diego study: 50-75% bit error rates on power loss during writes
- 13/15 consumer SSDs lost data in power fault testing (Ohio State/HP Labs)
- USB bridges block most NVMe admin commands including secure erase
