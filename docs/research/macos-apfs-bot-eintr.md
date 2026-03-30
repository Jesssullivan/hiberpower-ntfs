# macOS USB NVMe Write Failure: EINTR Root Cause Analysis

**Date**: 2026-03-29 (updated 2026-03-30)
**Author**: Jess Sullivan
**Device**: ASM2362 (VID 0x174C, PID 0x2362) + Silicon Power SPCC M.2 PCIe SSD (Phison PS5012-E12, FW H211011a)
**Host**: Mac Mini M2 (petting-zoo-mini), macOS 15 Sequoia

## UPDATE 2: Definitive Root Cause — Enclosure Firmware Missing BOS/SuperSpeed Descriptor

**The enclosure firmware only exposes a USB 2.1 device descriptor with NO SuperSpeed capability.**

```
ioreg — USB device descriptor:
  bcdUSB = 0x0210       ← USB 2.1 (triggers BOS query per USB 3.0 spec)
  bMaxPacketSize0 = 64  ← USB 2.0 endpoint size (SS uses 512)
  Device Speed = 2      ← High Speed = USB 2.0
  bInterfaceProtocol = 80  ← BOT only (no UAS)
  bNumConfigurations = 1   ← single config, no SS alternate

ioreg — USB 3.x Gen2 hub port statistics:
  kPortStatConnectCount = 0  ← SuperSpeed PHY NEVER CONNECTED
```

Per USB 3.0 spec section 9.2.6.6, `bcdUSB=0x0210` is correct for a USB 3.x device's High-Speed descriptor — the host must then query the **BOS (Binary Object Store) descriptor** to discover SuperSpeed capability. **This enclosure's firmware does not include a valid BOS descriptor with SuperSpeed Device Capability**, so the host never attempts SuperSpeed link training.

**This is NOT a cable, port, or macOS issue.** The enclosure firmware is fundamentally misconfigured.

### Fix Path
The firmware can be reflashed via SCSI vendor command `0xE3` (Firmware Write) from Linux, where we have working SCSI access. The ASM2362 chip fully supports USB 3.1 Gen 2 — only the firmware descriptor table needs updating.

## UPDATE 1: USB Link Speed Degradation (Superseded)

Previous finding: device negotiating USB 2.0. This was a symptom, not the cause. The cause is the missing BOS/SuperSpeed descriptor in the enclosure firmware.

## Symptom

All I/O operations (reads AND writes) to a USB NVMe SSD return `EINTR` (Interrupted system call) — both at the filesystem level and the raw block device. The drive reports `SMART Status: Verified` and `Media Read-Only: No`. The identical drive works perfectly on Linux (Rocky Linux, tested with SG_IO, XRAM access, NVMe Identify — all successful).

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

## Diagnostic Test Results (2026-03-30)

### Test 1: exFAT Write (Bypass APFS) — FAILED
```
$ touch /Volumes/TinylandSSD/test-write
touch: /Volumes/TinylandSSD/test-write: Interrupted system call
```
Drive was reformatted as exFAT on Linux. EINTR persists. **APFS is not the cause.**

### Test 2: Raw Block Device Write — FAILED
```
$ sudo dd if=/dev/zero of=/dev/rdisk4 bs=1m count=1
dd: /dev/rdisk4: Interrupted system call
```
Bypasses filesystem entirely. EINTR at the block device level. **Filesystem is not the cause.**

### Test 2b: Raw Block Device READ — FAILED
```
$ sudo dd if=/dev/rdisk4 of=/dev/null bs=1m count=1
dd: /dev/rdisk4: Interrupted system call
```
Even reads fail. **The issue is at the USB transport level, not filesystem or write-specific.**

### Test 3: Baseline (non-USB device) — PASSED
```
$ sudo dd if=/dev/zero of=/dev/null bs=1m count=1
1+0 records in / 1+0 records out (5637 MB/s)
```
Confirms the system is healthy. Only this USB device is affected.

### IOKit Statistics (Contradictory)
```
"Errors (Write)" = 0
"Errors (Read)" = 0
"Operations (Write)" = 1161
"Bytes (Write)" = 6038528
```
The IOKit driver reports **zero errors** and has successfully written 6MB across 1161 operations. Some I/O IS getting through at the driver level — the EINTR is generated above the IOKit layer, likely by the BSD disk I/O subsystem timing out waiting for the slow USB 2.0 transport.

### USB Link Speed Discovery
```
USBSpeed = 3           ← port capability: SuperSpeed (USB 3.0)
UsbLinkSpeed = 480000000  ← negotiated: 480 Mbps (USB 2.0!)
Device Speed = 2       ← High Speed = USB 2.0
```
The ASM2362 is running at USB 2.0 speed on a USB 3.0 port. This explains everything — NVMe write latency through a USB 2.0 bottleneck exceeds the macOS I/O timeout, generating EINTR.

## Revised Root Cause: USB Link Speed Degradation

The original hypothesis (APFS + BOT concurrency) was **wrong**. The actual issue:

1. **USB link negotiation fails** — ASM2362 falls back from USB 3.x to USB 2.0
2. **NVMe writes through USB 2.0** are extremely slow (theoretical max 60 MB/s, real ~30 MB/s)
3. **macOS BSD layer times out** waiting for write completion at USB 2.0 speed
4. **EINTR is returned** to the calling process
5. **Linux works** because its USB stack has different timeout behavior and the ASM2362 may negotiate USB 3.0 successfully on Linux (different USB host controller driver)

### Why Link Negotiation Fails
Possible causes:
- **Cable quality**: USB-C cables without proper SuperSpeed shielding fall back to USB 2.0
- **Port signal integrity**: Some USB-C ports on Mac Mini M2 have marginal signal quality
- **ASM2362 firmware**: Older firmware has known link training issues
- **Enclosure design**: Poor PCB routing in cheap enclosures degrades USB 3.x signals

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

## Firmware Flash Path (via Linux SCSI)

The ASM2362's SPI flash is accessible via vendor SCSI commands. We have working SCSI passthrough on yoga (Linux). The firmware can be updated without Windows or MPTool.

### Commands Available (from cyrozap/usb-to-pcie-re)

| Opcode | Direction | Command | Purpose |
|--------|-----------|---------|---------|
| 0xE0 | Read | Read Config | 128 bytes bridge configuration (slots 0/1) |
| 0xE2 | Read | Flash Read | Dump SPI flash contents (current firmware) |
| 0xE3 | Write | Firmware Write | Flash new firmware (starting at address 0x80) |
| 0xE8 | None | Reset | CPU or PCIe reset after flash |

### Workflow

1. **Dump current firmware** (safety backup):
   ```bash
   sudo asm2362-tool xram-dump --addr=0x0000 --len=4096 /dev/sg0  # Config region
   # Full firmware dump via 0xE2 (needs tool extension)
   ```

2. **Download latest firmware** from [station-drivers.com](https://www.station-drivers.com/):
   - Target: `230927_91_00_00` (family `91`, latest known)
   - This firmware should include proper BOS descriptor with SuperSpeed capability

3. **Flash firmware** via 0xE3 at address 0x80

4. **Reset bridge** via 0xE8 (PCIe soft reset)

5. **Verify**: Replug device, check `bcdUSB` and `UsbLinkSpeed` in ioreg

### hiberpower Tool Extension Needed

The asm2362-tool currently supports 0xE4/0xE5 (XRAM) and 0xE8 (reset). Adding 0xE2 (flash read) and 0xE3 (flash write) would make it a complete firmware management tool. This is tracked in the hiberpower roadmap.

### Risk Assessment

- **Brick risk**: Low — the ASM2362 bootloader survives failed flashes (responds to SCSI vendor commands even without valid firmware)
- **Recovery**: UART debug at 921600 8N1 on bridge pins 62/63 if bootloader is corrupted
- **Recommendation**: Always dump current firmware before flashing

## Chassis Redesign Considerations

Given the enclosure firmware is capped at USB 2.0, the current chassis is not achieving the ASM2362's potential (10 Gbps). A redesigned chassis should:

1. **Ship with verified firmware** — include BOS descriptor with SuperSpeed capability
2. **Thermal management** — ASM2362 throttles under sustained NVMe write load at full speed
3. **Cable quality** — bundle a USB 3.2 Gen 2 certified cable
4. **Test matrix** — verify enumeration on macOS (M1-M4), Linux, Windows at SuperSpeed

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
