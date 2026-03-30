# macOS APFS + BOT Mode Write Failure: EINTR Root Cause Analysis

**Date**: 2026-03-29
**Author**: Jess Sullivan
**Device**: ASM2362 (VID 0x174C, PID 0x2362) + Silicon Power SPCC M.2 PCIe SSD (Phison PS5012-E12, FW H211011a)
**Host**: Mac Mini M2 (petting-zoo-mini), macOS 15 Sequoia

## Symptom

All filesystem writes to APFS-formatted volumes on a USB NVMe SSD return `EINTR` (Interrupted system call). Reads succeed. The drive reports `SMART Status: Verified` and `Media Read-Only: No`. The identical drive works perfectly on Linux (Rocky Linux, tested with SG_IO, XRAM access, NVMe Identify — all successful).

```
touch /Volumes/TinylandSSD/test: Interrupted system call
echo test > /Volumes/TinylandSSD/test: Interrupted system call
sudo touch /Volumes/TinylandSSD/test: Interrupted system call
```

Even `fsck_apfs -n` returns EINTR when opening the raw device.

## Linux Diagnostics (via asm2362-tool)

Full XRAM probe on yoga (Linux) confirms the drive is healthy:

```
$ sudo asm2362-tool probe /dev/sg0
1. Testing Unit Ready... Result: READY
2. SCSI Inquiry... Vendor: SPCC M.2  Product: PCIe SSD
4. Testing ASMedia 0xe6 Passthrough... Result: FAILED (whitelist)

$ sudo asm2362-tool identify /dev/sg0
Model Number:         SPCC M.2 PCIe SSD
Serial Number:        00000000000000001387
Firmware Revision:    H211011a
NVMe Version:         1.4.0
Total NVM Capacity:   256 GB
Format NVM:           true
Block Erase:          true

$ sudo asm2362-tool xram-probe /dev/sg0
1. Testing XDATA Read (0xE4)... OK: 16 bytes read
2. Admin Submission Queue: 4 entries visible
3. PCIe MMIO Registers: accessible
4. NVMe Data Buffer: accessible
```

The drive is fully functional. The issue is macOS-specific.

## Root Cause Hypothesis: BOT Mode + APFS Concurrent Write Conflict

### Protocol Mismatch

The ASM2362 enclosure is operating in **BOT (Bulk-Only Transport) mode** (`bInterfaceProtocol=80`), not **UAS/UASP** (`bInterfaceProtocol=98`):

```
$ ioreg -r -c IOUSBHostInterface | grep -A5 "ASM236"
"bInterfaceProtocol" = 80    ← BOT mode
"bInterfaceClass" = 8        ← Mass Storage
"bInterfaceSubClass" = 6     ← SCSI
```

**BOT is strictly serial**: one SCSI command at a time. Each read or write must complete before the next command is issued. There is no command queuing.

**APFS is designed for concurrent, pipelined I/O**: it issues multiple outstanding writes simultaneously (journal commits, metadata updates, data writes, TRIM commands). This is by design — APFS was built for NVMe SSDs with deep command queues.

### The Conflict

When APFS issues concurrent writes to a BOT-mode USB device:
1. The macOS USB mass storage driver (`IOUSBMassStorageDriver`) can only dispatch one command at a time
2. Subsequent write requests must wait for the current command to complete
3. While waiting, macOS may deliver a signal (from fseventsd, Spotlight, or the USB driver's timeout handler)
4. This signal interrupts the blocked `write()` syscall, returning `EINTR`
5. Unlike Linux, macOS does not always auto-restart interrupted syscalls for device I/O

### Why Reads Work

Reads are inherently sequential from the application's perspective — even if APFS prefetches, the read path handles EINTR gracefully (retry loops). Write paths in APFS's transaction/journal system are more sensitive to interruption because partial writes corrupt metadata consistency.

### Why Linux Works

1. Linux's USB mass storage driver handles BOT command queuing at the kernel level — userspace never sees the serialization
2. Linux's `SG_IO` ioctl is synchronous by design — no signal delivery during the ioctl
3. Linux filesystems (ext4, XFS) have explicit EINTR retry loops in their write paths
4. Linux has better UAS fallback handling — even in BOT mode, the block layer manages queuing

## Supporting Evidence

### macOS Does Not Fully Support UAS

> "M1/M2/M3 Macs do NOT fully support UAS protocol for external USB devices"
— [OWC: USB Performance on M1 Macs](https://www.owc.com/blog/a-note-about-usb-performance-on-m1-macs)

> "macOS does NOT support UASP (USB Attached SCSI Protocol) for external devices, only BOT"
— [Apple Community Discussion](https://discussions.apple.com/thread/255935166)

### BOT Mode Limits Concurrent Operations

> "BOT processes commands sequentially — each read/write must complete before the next command is issued. UAS allows pipelined commands, better for concurrent operations."
— [Electronic Design: USB UASP vs BOT](https://www.electronicdesign.com/technologies/embedded/article/21800348/whats-the-difference-between-usb-uasp-and-bot)

### ASM2362 Enclosures Ship BOT-Only

> "The Argon ONE NVMe enclosure with ASM2362 ships with BOT mode enabled by default, even though the hardware supports UASP. Firmware update resolved UASP activation."
— [Martin Rowan: Argon ONE NVMe Analysis](https://www.martinrowan.co.uk/2023/01/argon-one-nvme-board-slower-than-sata/)

### APFS External USB Issues Are Known

> "APFS on external USB drives is not a well-supported configuration on macOS... APFS is optimized for internal SSDs"
— [Apple Community: APFS External Drive Issues](https://discussions.apple.com/thread/250738730)

### EINTR Semantics on macOS

> "When you use signal() to install handlers, interrupted system calls are automatically restarted by the kernel. However, using sigaction() without SA_RESTART creates interruptible syscalls that return EINTR."
— [APUE Chapter 10: Signals](https://notes.shichao.io/apue/ch10/)

macOS's IOUSBMassStorageDriver may use `sigaction()` without `SA_RESTART` for its internal timeout handling, causing writes to return EINTR rather than being retried.

### sg3_utils Explicitly Unsupported on macOS

> "Darwin is not supported because the Apple folks do not want to give their users a pass-through SCSI interface."
— [sg3_utils Documentation](https://sg.danny.cz/sg/sg3_utils.html)

### smartmontools Has No macOS SCSI Support

From `os_darwin.cpp`:
```
"scsi devices are not supported [yet]"
```
smartmontools only implements NVMe and ATA passthrough on macOS, not SCSI.

## APFS TRIM/UNMAP Complication

APFS sends TRIM (UNMAP in SCSI terms) to SSDs. For TRIM to work over USB:
1. Bridge chip must support UNMAP → ASM2362 does ✓
2. Protocol must support it → **BOT does NOT natively; UAS does** ✗
3. macOS must enable it → Only for Monterey+ with UAS ✓

If APFS sends TRIM commands to a BOT-mode device, the command may fail silently or cause protocol desynchronization, contributing to the write failure cascade.

## Firmware Version

Bridge XRAM dump at 0x07F0 (firmware identifier):
```
07f0: 19 05 02 81 16 00
```

Known ASM2362 firmware versions from [station-drivers.com](https://www.station-drivers.com/) and [Win-Raid Forum](https://winraid.level1techs.com/t/asm2362-firmware/35384):
- 181031_81_08_83
- 190306_81_11_08
- 191009_81_0B_20
- 210527_81_3A_00
- 220906_81_0F_84
- 230927_91_00_00 (latest known)

The `81` byte in position 3 appears to be a firmware family identifier. Our firmware's `81` matches the older firmware line. Updating to `230927_91_00_00` (family `91`) may enable UAS mode.

## Diagnostic Test Plan

### Test 1: exFAT Format (Bypass APFS Concurrency)
Format as exFAT (sequential writes, no TRIM). If writes succeed, confirms APFS concurrent write + BOT is the root cause.

### Test 2: Raw Block Device Write
```bash
sudo dd if=/dev/zero of=/dev/rdisk4 bs=1m count=1
```
Bypasses the filesystem entirely. If this fails with EINTR, the issue is below the filesystem (USB driver level).

### Test 3: Disable fseventsd/Spotlight
```bash
sudo mdutil -i off /Volumes/TinylandSSD
touch /Volumes/TinylandSSD/.metadata_never_index
mkdir /Volumes/TinylandSSD/.fseventsd
touch /Volumes/TinylandSSD/.fseventsd/no_log
```
Eliminates signal sources from filesystem watchers.

### Test 4: Firmware Update
Use ASMedia MPTool to update to latest firmware (230927_91_00_00). Check if UAS mode becomes available post-update.

## Impact

This affects a wide class of consumer USB NVMe enclosures:
- **ASM2362** is one of the three most common USB-NVMe bridge chips (alongside JMS583 and RTL9210)
- Many enclosures ship with BOT-only firmware even though the hardware supports UAS
- **macOS users formatting these drives as APFS may experience silent write failures**
- The failure mode (EINTR) is subtle — most tools don't retry, and APFS metadata corruption can result

## References

- [Apple QA1179: Sending SCSI or ATA commands](https://developer.apple.com/library/archive/qa/qa1179/_index.html)
- [OWC: USB Performance on M1 Macs](https://www.owc.com/blog/a-note-about-usb-performance-on-m1-macs)
- [Electronic Design: USB UASP vs BOT](https://www.electronicdesign.com/technologies/embedded/article/21800348/whats-the-difference-between-usb-uasp-and-bot)
- [Martin Rowan: Argon ONE NVMe ASM2362 Analysis](https://www.martinrowan.co.uk/2023/01/argon-one-nvme-board-slower-than-sata/)
- [Apple Community: APFS External Drive Issues](https://discussions.apple.com/thread/250738730)
- [Apple Community: NVMe Enclosure Issues](https://discussions.apple.com/thread/252112565)
- [sg3_utils Documentation](https://sg.danny.cz/sg/sg3_utils.html)
- [smartmontools os_darwin.cpp](https://github.com/smartmontools/smartmontools/blob/master/smartmontools/os_darwin.cpp)
- [cyrozap/usb-to-pcie-re](https://github.com/cyrozap/usb-to-pcie-re)
- [ASM2362 Firmware Archive — Win-Raid](https://winraid.level1techs.com/t/asm2362-firmware/35384)
- [ASMedia Firmware — station-drivers.com](https://www.station-drivers.com/)
- [APUE Chapter 10: Signals](https://notes.shichao.io/apue/ch10/)
- [TRIM on USB External SSD — MacRumors](https://forums.macrumors.com/threads/trim-on-usb-external-ssd-supported-now.2322611/)
- [APFS and TRIM — Eclectic Light](https://eclecticlight.co/2019/08/26/caring-for-ssds-trim-wear-levelling-and-apfs/)
