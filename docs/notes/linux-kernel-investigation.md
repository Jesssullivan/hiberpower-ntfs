# Linux Kernel Investigation: USB NVMe Write Failures

## Overview

This document investigates why `dd if=/dev/zero of=/dev/sdX` might fail to write to an NVMe drive connected via USB, covering the Linux block layer, USB storage drivers, SCSI/ATA translation, and diagnostic approaches.

---

## 1. Linux Block Layer Error Handling and Reporting

### How Write Errors Are Handled

The Linux block layer provides several levels of error handling:

1. **Request completion status**: When an I/O operation completes, the block layer receives a status code indicating success or failure
2. **Error propagation**: Errors are propagated up through the storage stack (block layer -> filesystem/application)
3. **Retry mechanisms**: Some errors trigger automatic retries at the driver level

### Critical Issue: Transient vs. Permanent Failures

A fundamental problem exists with write error handling during writeback operations:
- An application can read a block where a write error occurred and get the **old data** without receiving any error indication
- If the error was transient, data is **silently lost**
- Different filesystems handle permanent errors inconsistently

For more details on kernel-level I/O error handling improvements, see [LWN: Improved block-layer error handling](https://lwn.net/Articles/724307/) and [LWN: Handling I/O errors in the kernel](https://lwn.net/Articles/757123/).

### dmesg Patterns to Look For

```bash
# Common I/O error patterns
dmesg | grep -E "(I/O error|blk_update_request|Buffer I/O error)"

# Specific patterns:
# "blk_update_request: I/O error, dev sdX, sector NNNN"
# "Buffer I/O error on device sdX, logical block NNNN"
# "Buffer I/O error on dev sdX, logical block NNNN, lost async page write"
# "end_request: I/O error, dev sdX, sector NNNN"
```

The "lost async page write" message is particularly serious as it indicates **actual data loss**.

### SCSI/ATA Specific Error Messages

```bash
# ATA/SCSI error patterns
dmesg | grep -E "(ata.*exception|ata.*error|sd.*sense|SCSI error)"

# Common patterns:
# "ata1: exception frozen"
# "sd X:0:0:0: [sdX] Sense Key : Medium Error [current]"
# "sd X:0:0:0: [sdX] Add. Sense: Unrecovered read error"
```

---

## 2. USB Mass Storage vs UAS (USB Attached SCSI)

### Protocol Differences

| Feature | USB Mass Storage (BOT) | UAS |
|---------|------------------------|-----|
| Protocol | Bulk-Only Transport | USB Attached SCSI |
| Command queuing | Single command | Multiple commands |
| Performance | Lower | Higher |
| Kernel driver | `usb-storage` | `uas` |
| Stability | Generally more stable | Can have chipset-specific issues |

### Common UAS Problems

Many USB-to-NVMe bridge chips advertise UAS support but behave poorly with the `uas` driver:
- Random I/O errors and device resets
- Poor SMART passthrough
- Device disconnections under load
- Slow write performance

### Identifying Which Driver is Active

```bash
# Check if UAS or usb-storage is bound
lsusb -tv

# Look for:
# - "USB Mass Storage device detected" -> usb-storage (BOT)
# - "uas" in the driver column -> UAS driver
```

### Disabling UAS (Workaround)

**Method 1: Temporary (current session)**
```bash
# Find vendor:product ID
lsusb
# Example: Bus 002 Device 003: ID 0bda:9210 Realtek Semiconductor Corp.

# Unload drivers and reload with quirks
sudo rmmod uas
sudo rmmod usb-storage
sudo modprobe usb-storage quirks=0bda:9210:u
```

**Method 2: Persistent configuration**
```bash
# Create /etc/modprobe.d/disable-uas.conf
echo "options usb-storage quirks=VENDOR:PRODUCT:u" | sudo tee /etc/modprobe.d/disable-uas.conf

# Quirk flags:
# u = IGNORE_UAS (force usb-storage instead of uas)
# m = MAX_SECTORS_64 (limit transfer size to 32KB)
# mu = combine both (common for problematic enclosures)

# Update initramfs
sudo update-initramfs -u  # Debian/Ubuntu
sudo dracut -f           # RHEL/Fedora
```

**Method 3: Kernel command line**
```bash
# Add to GRUB_CMDLINE_LINUX in /etc/default/grub
usb-storage.quirks=VENDOR:PRODUCT:u
```

### Known Problematic Chipsets

| Chipset | Vendor:Product | Known Issues |
|---------|----------------|--------------|
| RTL9210/RTL9210B | 0bda:9210 | USB2 fallback, firmware-dependent stability |
| JMS583 | 152d:0583 | Heat issues, power problems, SMART passthrough |
| ASM2362 | 174c:2362 | Power management issues, USB disconnects |
| JMicron JMS578 | 152d:a578 | UAS issues, translation problems |
| ASMedia ASM1053 | 174c:55aa | Not actually UAS capable despite advertising |

For detailed information, see [DEV.to: Workaround for using UAS USB3 storage on Linux](https://dev.to/vast-cow/workaround-for-using-uas-usb3-storage-on-linux-3b5p) and [How to disable USB Attached Storage (UAS)](https://leo.leung.xyz/wiki/How_to_disable_USB_Attached_Storage_(UAS)).

---

## 3. SCSI/ATA Command Translation in USB Bridges

### How Translation Works

USB storage devices use SCSI commands over the wire, even for SATA/NVMe drives. The USB bridge chip performs SAT (SCSI to ATA Translation):

```
Application -> Block Layer -> SCSI Layer -> USB Layer -> Bridge Chip -> NVMe/SATA Drive
```

### Translation Issues

1. **Incomplete implementation**: Many bridge chips implement only a subset of SAT commands
2. **Race conditions**: Concurrent ATA passthrough commands can confuse bridge chips
3. **Error reporting**: ATA error codes may not translate correctly to SCSI sense data
4. **SMART passthrough**: Often broken or limited to single device

### ATA Error Handling Limitations

From the kernel documentation:
- READ and WRITE commands report CHS/LBA of the first failed sector
- The amount of transferred data on error completion is **indeterminate**
- Sectors preceding the failed sector **cannot be assumed** to have been transferred successfully
- HSM (Host State Machine) violations require a device reset to restore known state

See [libATA Developer's Guide](https://docs.kernel.org/driver-api/libata.html) for detailed information on the ATA translation layer.

---

## 4. Write Protection Detection

### Checking Write Protection Status

```bash
# Check dmesg for write protect status
dmesg | grep -i "write protect"
# Look for: "sd X:0:0:0: [sdX] Write Protect is on/off"

# Check sysfs read-only flag
cat /sys/block/sdX/ro
# 0 = read-write, 1 = read-only

# Check with blockdev
blockdev --getro /dev/sdX
# 0 = read-write, 1 = read-only

# Force rescan of device attributes
echo 1 > /sys/block/sdX/device/rescan
```

### Write Protection Sources

1. **Physical switch**: Some enclosures have a physical write-protect switch
2. **Firmware**: Bridge firmware may report write protection
3. **Drive firmware**: The NVMe drive itself may be in read-only mode
4. **Kernel**: Software write protection via blockdev or mount options

### Examining Block Device Attributes

```bash
# Key sysfs entries for a block device
ls -la /sys/block/sdX/

# Important files:
cat /sys/block/sdX/ro              # Read-only flag
cat /sys/block/sdX/size            # Size in 512-byte sectors
cat /sys/block/sdX/removable       # Is device removable
cat /sys/block/sdX/queue/hw_sector_size      # Hardware sector size
cat /sys/block/sdX/queue/logical_block_size  # Logical block size
cat /sys/block/sdX/queue/write_cache         # Write cache status

# Device-specific info
cat /sys/block/sdX/device/vendor   # Device vendor string
cat /sys/block/sdX/device/model    # Device model string
cat /sys/block/sdX/device/state    # Device state (running, blocked, etc.)
```

See the [Linux kernel sysfs-block documentation](https://www.kernel.org/doc/Documentation/ABI/stable/sysfs-block) for a complete list of attributes.

---

## 5. Block Device Caching and Bypass

### The Caching Problem

By default, `dd` uses buffered I/O:
1. Data is written to the kernel page cache
2. The `dd` command returns "success" when data is in cache
3. Actual writes happen asynchronously later
4. If writes fail during writeback, the **error may not be reported**

### dd Options for Synchronous Writes

| Option | Behavior | Performance |
|--------|----------|-------------|
| (none) | Buffered I/O, returns when in cache | Fastest, unreliable |
| `conv=fsync` | Single fsync at end | Fast, catches final errors |
| `oflag=dsync` | Sync after each block (O_DSYNC) | Slow, catches all errors |
| `oflag=sync` | Same as dsync | Slow |
| `oflag=direct` | Bypass page cache (O_DIRECT) | Medium, still needs sync |
| `oflag=direct,sync` | Bypass cache + sync each block | Slowest, most reliable |

### Recommended dd Commands

**For maximum reliability (catching all errors):**
```bash
# Synchronous writes with cache bypass
dd if=/dev/zero of=/dev/sdX bs=1M status=progress oflag=direct,sync

# Or with conv=fsync (sync at end, faster)
dd if=/dev/zero of=/dev/sdX bs=4M status=progress conv=fsync oflag=direct
```

**For debugging write issues:**
```bash
# Write with full synchronization, small blocks for granular error detection
dd if=/dev/zero of=/dev/sdX bs=512 count=1000 oflag=direct,sync

# Verify writes happened
sync
```

### Important: conv=sync vs oflag=sync

These are **completely different**:
- `conv=sync`: Pads incomplete input blocks with NULs (unrelated to disk sync)
- `oflag=sync` / `oflag=dsync`: Uses O_SYNC flag for synchronous I/O
- `conv=fsync`: Calls fsync() before closing file

For a detailed explanation, see [dd, bs= and why you should use conv=fsync](https://abbbi.github.io/dd/).

### Forcing Disk Cache Flush

```bash
# Sync all filesystems and block devices
sync

# Force flush on specific device (requires hdparm)
hdparm -F /dev/sdX

# Via blkdev_issue_flush (requires writing code or using specific tools)
# This sends SYNCHRONIZE_CACHE SCSI command
```

---

## 6. Why Writes Might Appear to Succeed But Not Persist

### Scenario 1: Buffered I/O Without Sync

```bash
# This can return "success" while data is still in RAM
dd if=/dev/zero of=/dev/sdX bs=4M count=100
# dd returns, data in page cache
# USB device disconnects or errors during writeback
# Data is lost, no error reported to dd
```

**Solution:** Use `conv=fsync` or `oflag=sync`

### Scenario 2: Fake/Counterfeit Storage

Counterfeit USB drives report larger capacity than they actually have:
- Controller chip modified to report false capacity
- Writes beyond real capacity wrap around or fail silently
- Data appears to write but cannot be read back

**Detection tools:**
```bash
# Install f3 (Fight Fake Flash)
# Debian/Ubuntu:
sudo apt install f3

# Test drive (destructive - erases data)
sudo f3probe --destructive /dev/sdX

# Non-destructive but slower:
f3write /mnt/usb    # Write test files
f3read /mnt/usb     # Verify test files
```

See [Check Real USB Capacity in Linux Terminal](https://www.linuxbabe.com/command-line/f3-usb-capacity-fake-usb-test-linux) and [CapacityTester](https://github.com/c0xc/CapacityTester) for more information.

### Scenario 3: Bridge Chip Translation Errors

The USB bridge chip may:
- Report write success before data reaches the drive
- Have firmware bugs that corrupt writes
- Fail to properly translate error responses

**Diagnostics:**
```bash
# Compare what was written
dd if=/dev/zero of=/dev/sdX bs=1M count=10 conv=fsync oflag=direct
dd if=/dev/sdX of=/tmp/readback bs=1M count=10
cmp /dev/zero /tmp/readback
# Should show: cmp: EOF on /dev/zero (if data matches)
```

### Scenario 4: Device Going Offline During Write

```bash
# Check for device disconnect/reconnect in dmesg
dmesg | grep -E "(USB disconnect|usb.*reset|sd.*attached)"
```

---

## 7. Diagnostic Commands Reference

### Full System Diagnosis

```bash
#!/bin/bash
# Save as: diagnose-usb-storage.sh

DEVICE=${1:-/dev/sdb}

echo "=== USB Device Info ==="
lsusb -tv

echo -e "\n=== dmesg (last 50 lines, storage-related) ==="
dmesg | grep -E "(usb|scsi|sd|ata|blk_update)" | tail -50

echo -e "\n=== Block Device Attributes ==="
echo "Read-only: $(cat /sys/block/$(basename $DEVICE)/ro)"
echo "Size: $(cat /sys/block/$(basename $DEVICE)/size) sectors"
echo "Removable: $(cat /sys/block/$(basename $DEVICE)/removable)"

echo -e "\n=== Queue Attributes ==="
echo "HW Sector Size: $(cat /sys/block/$(basename $DEVICE)/queue/hw_sector_size)"
echo "Logical Block Size: $(cat /sys/block/$(basename $DEVICE)/queue/logical_block_size)"

echo -e "\n=== SMART Status (if available) ==="
smartctl -a $DEVICE 2>/dev/null || echo "SMART not available"

echo -e "\n=== Write Protect Status ==="
dmesg | grep -i "write protect" | tail -5

echo -e "\n=== Current I/O Stats ==="
cat /sys/block/$(basename $DEVICE)/stat
```

### blktrace for Deep I/O Analysis

```bash
# Install blktrace
sudo apt install blktrace    # Debian/Ubuntu
sudo dnf install blktrace    # Fedora/RHEL

# Basic real-time tracing
sudo btrace /dev/sdX

# More detailed: capture and analyze
sudo blktrace -d /dev/sdX -o trace_output &
# Run your dd command
dd if=/dev/zero of=/dev/sdX bs=1M count=10 conv=fsync
# Stop blktrace (Ctrl+C or kill)
kill %1

# Parse the trace
blkparse -i trace_output -o trace_readable.txt

# Analyze with btt (Block Trace Toolkit)
btt -i trace_output.blktrace.0

# Filter for specific events (writes only)
sudo blktrace -d /dev/sdX -a write -o - | blkparse -i -
```

### blktrace Output Interpretation

Key event codes:
- **Q**: Queued (request added to queue)
- **G**: Get request (request allocated)
- **I**: Inserted (request inserted into device queue)
- **D**: Issued (request sent to driver)
- **C**: Complete (request completed) - **check for errors here**
- **R**: Requeue (request requeued after error)

Example output:
```
  8,0    3     1     0.000000000 12345  Q  WS 0 + 8 [dd]
  8,0    3     2     0.000001234 12345  G  WS 0 + 8 [dd]
  8,0    3     3     0.000002345 12345  I  WS 0 + 8 [dd]
  8,0    3     4     0.000003456 12345  D  WS 0 + 8 [dd]
  8,0    3     5     0.001234567 12345  C  WS 0 + 8 [0]   <- [0] = success
```

Error indication: A non-zero value in brackets at the end of a Complete line indicates an error.

See [Linux Block I/O Tracing](https://www.collabora.com/news-and-blog/blog/2017/03/28/linux-block-io-tracing/) for detailed blktrace usage.

### Testing Write Reliability

```bash
# Write known pattern and verify
DEVICE=/dev/sdX
TESTFILE=/tmp/testpattern

# Create test pattern
dd if=/dev/urandom of=$TESTFILE bs=1M count=10

# Write with full sync
dd if=$TESTFILE of=$DEVICE bs=1M conv=fsync oflag=direct

# Read back
dd if=$DEVICE of=/tmp/readback bs=1M count=10

# Compare
md5sum $TESTFILE /tmp/readback
# Should match if writes persisted correctly
```

---

## 8. Troubleshooting Flowchart

```
dd write fails or data doesn't persist
            |
            v
    Check dmesg for errors
            |
     +------+------+
     |             |
  Errors       No errors
     |             |
     v             v
Check error type   Check if using sync
     |                    |
+----+----+         +-----+-----+
|         |         |           |
I/O err   Write     No sync     Has sync
          Protect              |
|         |         |           |
v         v         v           v
Check:    Check:    Add:        Check for
- UAS     - dmesg   conv=fsync  fake drive
- Bridge  - ro flag or          (use f3probe)
- Cable   - switch  oflag=sync
                               |
                               v
                           Still fails?
                               |
                               v
                           Use blktrace
                           for analysis
```

---

## 9. Quick Reference: Essential Commands

```bash
# Check write protect status
dmesg | grep -i "write protect"
cat /sys/block/sdX/ro
blockdev --getro /dev/sdX

# Monitor I/O errors in real-time
dmesg -wH | grep -E "(error|I/O|blk_update)"

# Force synchronous write with dd
dd if=/dev/zero of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress

# Check which USB driver is used
lsusb -tv | grep -A5 "your device"

# Disable UAS for problematic device
echo "options usb-storage quirks=VENDOR:PRODUCT:u" | sudo tee /etc/modprobe.d/disable-uas.conf

# Test for fake capacity
sudo f3probe --destructive /dev/sdX

# Real-time block I/O trace
sudo btrace /dev/sdX

# Flush disk write cache
sync
hdparm -F /dev/sdX

# Force device rescan
echo 1 > /sys/block/sdX/device/rescan
```

---

## References

- [LWN: Improved block-layer error handling](https://lwn.net/Articles/724307/)
- [LWN: Handling I/O errors in the kernel](https://lwn.net/Articles/757123/)
- [libATA Developer's Guide](https://docs.kernel.org/driver-api/libata.html)
- [Linux kernel sysfs-block documentation](https://www.kernel.org/doc/Documentation/ABI/stable/sysfs-block)
- [DEV.to: Workaround for using UAS USB3 storage on Linux](https://dev.to/vast-cow/workaround-for-using-uas-usb3-storage-on-linux-3b5p)
- [How to disable USB Attached Storage (UAS)](https://leo.leung.xyz/wiki/How_to_disable_USB_Attached_Storage_(UAS))
- [dd, bs= and why you should use conv=fsync](https://abbbi.github.io/dd/)
- [Ensuring data reaches disk - LWN](https://lwn.net/Articles/457667/)
- [Linux Block I/O Tracing - Collabora](https://www.collabora.com/news-and-blog/blog/2017/03/28/linux-block-io-tracing/)
- [blktrace manual page](https://man7.org/linux/man-pages/man8/blktrace.8.html)
- [How to force disk cache flush on Linux](https://utcc.utoronto.ca/~cks/space/blog/linux/ForceDiskFlushes)
- [f3 - Fight Fake Flash](https://www.linuxbabe.com/command-line/f3-usb-capacity-fake-usb-test-linux)
- [CapacityTester for detecting fake USB drives](https://github.com/c0xc/CapacityTester)
- [SCSI/ATA Translation - Wikipedia](https://en.wikipedia.org/wiki/SCSI_/_ATA_Translation)
- [NVMe USB Enclosure chipset comparison](https://www.ozbargain.com.au/node/581372)
- [Level1Techs: RTL9210B chipset issues](https://forum.level1techs.com/t/nvme-to-usb-3-1-enclosure-buggy-in-linux-rtl9210b-chipset/199752)
