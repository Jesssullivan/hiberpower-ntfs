# Low-Level Linux Tools for NVMe Drive Diagnosis and Recovery

**Last Updated**: 2026-01-21
**Target Audience**: System administrators, data recovery specialists, forensic analysts

This guide covers essential Linux tools for diagnosing and recovering corrupted NVMe drives, including command syntax, expected outputs, and safety considerations.

---

## Table of Contents

1. [Tool Installation](#tool-installation)
2. [nvme-cli - NVMe Management](#nvme-cli---nvme-management)
3. [hdparm - ATA Security and Parameters](#hdparm---ata-security-and-parameters)
4. [sg3_utils - SCSI Commands for USB Drives](#sg3_utils---scsi-commands-for-usb-drives)
5. [blkdiscard - TRIM/UNMAP Commands](#blkdiscard---trimunmap-commands)
6. [wipefs - Signature Removal](#wipefs---signature-removal)
7. [dmsetup - Device Mapper Manipulation](#dmsetup---device-mapper-manipulation)
8. [debugfs - Filesystem Debugging](#debugfs---filesystem-debugging)
9. [Custom Tools in C/Zig](#custom-tools-in-czig)
10. [Diagnostic Workflows](#diagnostic-workflows)
11. [Dangerous Commands Reference](#dangerous-commands-reference)

---

## Tool Installation

### Fedora / RHEL / CentOS / Rocky / Alma

```bash
# Core tools
sudo dnf install nvme-cli hdparm sg3_utils util-linux e2fsprogs device-mapper

# Development tools for custom utilities
sudo dnf install gcc clang zig kernel-devel
```

### Ubuntu / Debian

```bash
# Core tools
sudo apt install nvme-cli hdparm sg3-utils util-linux e2fsprogs dmsetup

# Development tools for custom utilities
sudo apt install gcc clang build-essential linux-headers-$(uname -r)

# Zig (manual install - check https://ziglang.org/download/)
wget https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz
tar xf zig-linux-x86_64-0.13.0.tar.xz
sudo mv zig-linux-x86_64-0.13.0 /opt/zig
echo 'export PATH="/opt/zig:$PATH"' >> ~/.bashrc
```

### Arch Linux

```bash
sudo pacman -S nvme-cli hdparm sg3_utils util-linux e2fsprogs device-mapper

# Development
sudo pacman -S gcc clang zig linux-headers
```

### openSUSE

```bash
sudo zypper install nvme-cli hdparm sg3_utils util-linux e2fsprogs device-mapper

# Development
sudo zypper install gcc clang zig kernel-devel
```

---

## nvme-cli - NVMe Management

`nvme-cli` is the primary tool for interacting with NVMe devices. It provides direct access to NVMe admin and I/O commands.

### Device Discovery

```bash
# List all NVMe devices
nvme list

# Expected output (healthy):
# Node             Model                    Namespace  Usage                      Format           FW Rev
# ---------------- ------------------------ ---------- -------------------------- ---------------- --------
# /dev/nvme0n1     Samsung SSD 980 PRO 1TB  1         1000.20 GB / 1000.20 GB    512   B +  0 B   5B2QGXA7

# List all NVMe subsystems with detailed topology
nvme list-subsys

# List with verbose output
nvme list -v
```

### SMART and Health Information

```bash
# Get SMART log (critical for diagnosis)
nvme smart-log /dev/nvme0

# Expected output (healthy):
# Smart Log for NVME device:nvme0 namespace-id:ffffffff
# critical_warning                    : 0        # <-- 0 means healthy
# temperature                         : 35 C
# available_spare                     : 100%     # <-- Should be >10%
# available_spare_threshold           : 10%
# percentage_used                     : 1%       # <-- Endurance indicator
# data_units_read                     : 12,345,678
# data_units_written                  : 8,765,432
# host_read_commands                  : 234,567,890
# host_write_commands                 : 123,456,789
# controller_busy_time                : 1234
# power_cycles                        : 456
# power_on_hours                      : 7890
# unsafe_shutdowns                    : 12       # <-- High = potential issues
# media_errors                        : 0        # <-- >0 indicates problems
# num_err_log_entries                 : 0        # <-- Error log entries

# Warning signs in SMART output:
# critical_warning > 0     : Drive has critical issues
# available_spare < 10%    : Drive is near end of life
# percentage_used > 100%   : Drive exceeded rated endurance
# media_errors > 0         : Flash cells failing
# unsafe_shutdowns high    : Filesystem corruption likely

# Get SMART with human-readable output
nvme smart-log /dev/nvme0 -H
```

### Error Logs

```bash
# Get error log (essential for debugging)
nvme error-log /dev/nvme0

# Expected output (healthy):
# Error Log Entries for device:nvme0 entries:0
# No errors

# Output (with errors):
# Error Log Entries for device:nvme0 entries:64
# Entry[ 0]
# error_count     : 1
# sqid            : 0
# cmdid           : 0x001c
# status_field    : 0x4004   # <-- Error status code
# parm_err_loc    : 0x0000
# lba             : 0x00000000deadbeef  # <-- Affected LBA
# nsid            : 1
# vs              : 0
# cs              : 0x00000000
# command_specific: 0x00000000

# Decode common status codes:
# 0x4004 - Data Transfer Error
# 0x4005 - Internal Error
# 0x4280 - Write Fault
# 0x4281 - Unrecovered Read Error
# 0x4286 - Access Denied
```

### Identify Controller and Namespace

```bash
# Identify controller (firmware, capabilities)
nvme id-ctrl /dev/nvme0

# Key fields to check:
# vid    : 0x144d (Vendor ID - Samsung)
# ssvid  : 0x144d (Subsystem Vendor ID)
# sn     : S5XXNF0N123456K (Serial Number)
# mn     : Samsung SSD 980 PRO 1TB (Model)
# fr     : 5B2QGXA7 (Firmware Revision)
# oacs   : 0x17 (Optional Admin Command Support)
#   Bit 0: Security Send/Receive supported
#   Bit 1: Format NVM supported
#   Bit 2: Firmware Download/Commit supported
#   Bit 4: Namespace Management supported

# Identify specific namespace
nvme id-ns /dev/nvme0n1

# Key fields:
# nsze   : 1953525168 (Namespace Size in blocks)
# ncap   : 1953525168 (Namespace Capacity)
# nuse   : 1953525168 (Namespace Utilization)
# nlbaf  : 1 (Number of LBA Formats)
# flbas  : 0 (Formatted LBA Size index)
# lbaf 0 : ms:0  lbads:9  rp:0x2 (LBA Format: 512 bytes)
# lbaf 1 : ms:0  lbads:12 rp:0x1 (LBA Format: 4096 bytes)
```

### Firmware Management

```bash
# List firmware slots
nvme fw-log /dev/nvme0

# Download firmware (DANGEROUS - can brick drive)
# nvme fw-download /dev/nvme0 -f firmware.bin

# Activate firmware slot
# nvme fw-activate /dev/nvme0 -s 1 -a 1
```

### Namespace Management

```bash
# List namespaces
nvme list-ns /dev/nvme0

# Get namespace utilization
nvme get-ns-id /dev/nvme0n1

# Create namespace (DANGEROUS - data loss)
# nvme create-ns /dev/nvme0 --nsze=1000000 --ncap=1000000 --flbas=0 --dps=0

# Delete namespace (DANGEROUS - data loss)
# nvme delete-ns /dev/nvme0 -n 1

# Attach namespace to controller
# nvme attach-ns /dev/nvme0 -n 1 -c 0

# Detach namespace
# nvme detach-ns /dev/nvme0 -n 1 -c 0
```

### Format and Secure Erase

```bash
# Format NVM (DANGEROUS - complete data loss)
# This creates a new namespace with specified LBA format

# Dry run - show what would happen
nvme id-ns /dev/nvme0n1 | grep -E "^(lbaf|flbas)"

# Format to 512-byte sectors
# nvme format /dev/nvme0n1 -l 0

# Format to 4096-byte sectors
# nvme format /dev/nvme0n1 -l 1

# Secure erase (crypto erase if supported)
# nvme format /dev/nvme0n1 -s 1  # User Data Erase
# nvme format /dev/nvme0n1 -s 2  # Crypto Erase (fastest, most secure)

# Check if secure erase is supported
nvme id-ctrl /dev/nvme0 | grep fna
# fna : 0x4
#   Bit 0: Format applies to all namespaces
#   Bit 1: Secure Erase applies to all namespaces
#   Bit 2: Crypto Erase supported
```

### Self-Test

```bash
# Start short self-test
nvme device-self-test /dev/nvme0 -s 1

# Start extended self-test
nvme device-self-test /dev/nvme0 -s 2

# Abort self-test
nvme device-self-test /dev/nvme0 -s 0xf

# Get self-test results
nvme self-test-log /dev/nvme0

# Expected output (passed):
# Device Self Test Log for NVME device:nvme0
# Current operation: No device self-test operation in progress
# Current completion: 0%
# Self Test Result[0]:
#   Test Result           : 0x0 Operation completed without error
#   Segment Number        : 0
#   Valid Diagnostic Info : 0x0
#   Power On Hours (POH)  : 7890
```

### Sanitize Operations

```bash
# Check sanitize capabilities
nvme id-ctrl /dev/nvme0 | grep sanicap
# sanicap : 0x7
#   Bit 0: Crypto Erase supported
#   Bit 1: Block Erase supported
#   Bit 2: Overwrite supported

# Get sanitize log
nvme sanitize-log /dev/nvme0

# Start sanitize (DANGEROUS - irreversible data destruction)
# Block erase
# nvme sanitize /dev/nvme0 -a 2

# Crypto erase
# nvme sanitize /dev/nvme0 -a 4

# Overwrite (slowest, most thorough)
# nvme sanitize /dev/nvme0 -a 3
```

### Raw NVMe Commands

```bash
# Read raw admin command (advanced)
# Get log page 0x02 (SMART/Health Information)
nvme admin-passthru /dev/nvme0 --opcode=0x02 --cdw10=0x007f0002 -l 512 -r

# Read specific LBA (for forensics)
nvme read /dev/nvme0n1 -s 0 -c 0 -z 512 -d /tmp/sector0.bin

# Write specific LBA (DANGEROUS)
# nvme write /dev/nvme0n1 -s 0 -c 0 -z 512 -d /tmp/newdata.bin

# Compare data at LBA
nvme compare /dev/nvme0n1 -s 0 -c 0 -z 512 -d /tmp/sector0.bin
```

### NVMe-over-Fabrics (NVMe-oF)

```bash
# Discover NVMe-oF targets
nvme discover -t tcp -a 192.168.1.100 -s 4420

# Connect to remote NVMe
nvme connect -t tcp -n nqn.2014-08.com.example:nvme:target -a 192.168.1.100 -s 4420

# List connected subsystems
nvme list-subsys

# Disconnect
nvme disconnect -n nqn.2014-08.com.example:nvme:target
```

---

## hdparm - ATA Security and Parameters

`hdparm` is primarily for SATA drives but also works with some NVMe-to-SATA bridges and provides useful information about drive parameters.

### Device Information

```bash
# Get drive identification
sudo hdparm -I /dev/sda

# Key sections in output:
# ATA device, with non-removable media
# Model Number:       Samsung SSD 870 EVO 1TB
# Serial Number:      S5XXNF0N123456K
# Firmware Revision:  SVT02B6Q
# Transport:          Serial, ATA8-AST
#
# Standards:
#         Supported: 11 10 9 8 7 6 5
#         Likely used: 11
#
# Commands/features:
#         Enabled Supported:
#            *    SMART feature set
#            *    Security Mode feature set
#            *    Power Management feature set
#            *    Write cache
#            *    WRITE_UNCORRECTABLE_EXT command
#            *    TRIM supported

# Quick info
sudo hdparm -i /dev/sda
```

### ATA Security Status

```bash
# Check security status (critical for locked drives)
sudo hdparm -I /dev/sda | grep -A10 "Security:"

# Output (unlocked, security disabled):
# Security:
#         Master password revision code = 65534
#         supported
#     not enabled
#     not locked
#     not frozen
#         not expired: security count
#         supported: enhanced erase
#         2min for SECURITY ERASE UNIT. 2min for ENHANCED SECURITY ERASE UNIT.

# Output (locked drive):
# Security:
#         Master password revision code = 65534
#         supported
#         enabled
#         locked    # <-- Drive is locked!
#     not frozen
#         not expired: security count

# Output (frozen - normal after boot):
# Security:
#         Master password revision code = 65534
#         supported
#     not enabled
#     not locked
#         frozen    # <-- Cannot change security settings
```

### Security Operations

```bash
# Set user password (DANGEROUS - can lock you out)
# sudo hdparm --user-master u --security-set-pass PASSWORD /dev/sda

# Unlock drive with user password
# sudo hdparm --user-master u --security-unlock PASSWORD /dev/sda

# Unlock drive with master password
# sudo hdparm --user-master m --security-unlock MASTERPASS /dev/sda

# Disable security (requires current password)
# sudo hdparm --user-master u --security-disable PASSWORD /dev/sda

# SECURE ERASE (complete data destruction)
# First, check drive is not frozen
sudo hdparm -I /dev/sda | grep frozen
# If frozen, suspend/resume system to unfreeze

# Set a temporary password
# sudo hdparm --user-master u --security-set-pass TEMP /dev/sda

# Perform secure erase
# sudo hdparm --user-master u --security-erase TEMP /dev/sda

# Enhanced secure erase (if supported)
# sudo hdparm --user-master u --security-erase-enhanced TEMP /dev/sda
```

### Write Protection and Cache

```bash
# Check if write caching is enabled
sudo hdparm -W /dev/sda
# /dev/sda:
#  write-caching =  1 (on)

# Disable write cache (safer for data integrity)
sudo hdparm -W0 /dev/sda

# Enable write cache (better performance)
sudo hdparm -W1 /dev/sda

# Check read-only status
sudo hdparm -r /dev/sda
# /dev/sda:
#  readonly      =  0 (off)

# Set read-only (software protection)
sudo hdparm -r1 /dev/sda

# Remove read-only
sudo hdparm -r0 /dev/sda
```

### Power Management

```bash
# Check power management level
sudo hdparm -B /dev/sda
# /dev/sda:
#  APM_level      = 254  # 1=max power save, 254=max performance

# Set APM level
sudo hdparm -B 254 /dev/sda  # Max performance
sudo hdparm -B 128 /dev/sda  # Balanced
sudo hdparm -B 1 /dev/sda    # Max power saving

# Check standby timeout
sudo hdparm -S /dev/sda

# Put drive in standby
sudo hdparm -y /dev/sda

# Put drive in sleep (requires reset to wake)
sudo hdparm -Y /dev/sda
```

### Timing and Benchmarks

```bash
# Cached read timing
sudo hdparm -T /dev/sda
# /dev/sda:
#  Timing cached reads:   32456 MB in  2.00 seconds = 16228.00 MB/sec

# Buffered disk read timing
sudo hdparm -t /dev/sda
# /dev/sda:
#  Timing buffered disk reads: 1524 MB in  3.00 seconds = 507.67 MB/sec

# Both tests combined
sudo hdparm -Tt /dev/sda
```

### DCO (Device Configuration Overlay)

```bash
# Check for hidden capacity (HPA/DCO)
sudo hdparm -N /dev/sda
# /dev/sda:
#  max sectors   = 1953525168/1953525168, HPA is disabled

# If HPA is enabled, drive capacity is hidden:
# /dev/sda:
#  max sectors   = 1000000000/1953525168, HPA is enabled
#                  ^^^ visible     ^^^ actual

# Remove HPA (restore full capacity)
# sudo hdparm -N p1953525168 /dev/sda
# The 'p' prefix means permanent
```

---

## sg3_utils - SCSI Commands for USB Drives

`sg3_utils` provides SCSI commands that work with USB-attached drives through USB-SATA or USB-NVMe bridges.

### Device Discovery

```bash
# List all SCSI devices
sg_scan -i

# Get detailed device info
sg_inq /dev/sda

# Expected output:
# standard INQUIRY:
#   PQual=0  PDT=0  RMB=0  LU_CONG=0  hot_pluggable=0  version=0x06
#   [ANSI version: SPC-4]
#   [response length]: 36
#   Vendor identification: Samsung
#   Product identification: SSD 870 EVO 1TB
#   Product revision level: SVT0
#   Unit serial number: S5XXNF0N123456K

# Check device type
sg_inq -d /dev/sda
```

### Read Capacity

```bash
# Get device capacity (16-byte command for large drives)
sg_readcap -l /dev/sda

# Output:
# Read Capacity results:
#    Last LBA=1953525167 (0x74706daf), Number of logical blocks=1953525168
#    Logical block length=512 bytes
#    Logical blocks per physical block exponent=0
#    Lowest aligned LBA=0
# Hence:
#    Device size: 1000204886016 bytes, 953869.6 MiB, 1000.20 GB

# Short form (10-byte command)
sg_readcap /dev/sda
```

### SMART via SAT (SCSI to ATA Translation)

```bash
# Get ATA IDENTIFY (through USB bridge)
sg_sat_identify /dev/sda

# Get SMART status
sg_sat_set_features --feature=0xda /dev/sda  # Enable SMART
sg_sat_read_gplog --log=0 --page=0 /dev/sda  # Read SMART log

# Alternative: use smartctl which uses sg3_utils internally
smartctl -d sat -a /dev/sda
smartctl -d sat,auto -a /dev/sda  # Auto-detect SAT type
```

### Error Recovery

```bash
# Read defect list (bad sectors)
sg_reassign --list /dev/sda

# Get logged errors
sg_logs /dev/sda

# Specific log pages:
sg_logs -p 0x2 /dev/sda   # Write Error Counter
sg_logs -p 0x3 /dev/sda   # Read Error Counter
sg_logs -p 0x5 /dev/sda   # Verify Error Counter
sg_logs -p 0x10 /dev/sda  # Self-Test Results
sg_logs -p 0x15 /dev/sda  # Background Scan Results

# Start self-test
sg_senddiag -t /dev/sda           # Short test
sg_senddiag --self-test=1 /dev/sda  # Short foreground
sg_senddiag --self-test=2 /dev/sda  # Extended foreground
```

### Mode Pages (Device Configuration)

```bash
# List all mode pages
sg_modes /dev/sda

# Read specific mode page (e.g., caching)
sg_modes -p 0x08 /dev/sda

# Read/Write Error Recovery page
sg_modes -p 0x01 /dev/sda

# Output:
# >> Caching (SBC), page_control: current
#   IC=0 ABPF=0 CAP=0 DISC=0 SIZE=0 WCE=1 MF=0 RCD=0
#                                    ^^^^ Write Cache Enabled

# Disable write cache (DANGEROUS for performance)
# sg_modes -p 0x08 -s 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 /dev/sda
```

### Write Protection Status

```bash
# Check protection mode page
sg_modes -p 0x00 -s 0 /dev/sda | grep -i protect

# Via VPD page
sg_vpd -p 0xb2 /dev/sda  # Logical Block Provisioning VPD

# Check for software write protect
sg_modes -p 0x00 /dev/sda
# Look for: WP=1 (Write Protect enabled)
```

### Raw SCSI Commands

```bash
# Send raw CDB (Command Descriptor Block)
# Example: TEST UNIT READY
sg_raw -v /dev/sda 00 00 00 00 00 00

# Read specific LBA (READ(10))
# CDB: 28 00 00 00 00 00 00 00 01 00
# Read 1 block at LBA 0
sg_raw -r 512 /dev/sda 28 00 00 00 00 00 00 00 01 00 > /tmp/sector0.bin

# Write specific LBA (DANGEROUS)
# sg_raw -s 512 -i /tmp/newdata.bin /dev/sda 2a 00 00 00 00 00 00 00 01 00
```

### UNMAP (TRIM for SCSI)

```bash
# Check UNMAP support
sg_vpd -p 0xb0 /dev/sda  # Block Limits VPD
# Look for: Maximum unmap LBA count

# Send UNMAP command (DANGEROUS - data loss)
# sg_unmap --lba=0 --num=1000 /dev/sda
```

### Format Unit

```bash
# Check format capabilities
sg_format /dev/sda --info

# Format (DANGEROUS - complete data loss)
# sg_format --format /dev/sda

# Format with specific block size
# sg_format --format --size=4096 /dev/sda

# Low-level format with verification
# sg_format --format --verify /dev/sda
```

---

## blkdiscard - TRIM/UNMAP Commands

`blkdiscard` sends TRIM (for SATA/NVMe) or UNMAP (for SCSI) commands to inform the drive that blocks are no longer in use.

### Basic Usage

```bash
# Discard entire device (DANGEROUS - data loss)
# sudo blkdiscard /dev/nvme0n1

# Discard specific range
# sudo blkdiscard -o 0 -l 1G /dev/nvme0n1  # First 1GB

# Secure discard (if supported)
# sudo blkdiscard -s /dev/nvme0n1

# Verbose output
# sudo blkdiscard -v /dev/nvme0n1
```

### Checking TRIM Support

```bash
# For NVMe
nvme id-ctrl /dev/nvme0 | grep -i oncs
# oncs : 0x1f
#   Bit 0: Compare command supported
#   Bit 1: Write Uncorrectable supported
#   Bit 2: Dataset Management (TRIM) supported  <-- This one
#   Bit 3: Write Zeroes supported
#   Bit 4: Save/Select field in Set/Get Features

# For SATA (via hdparm)
sudo hdparm -I /dev/sda | grep -i trim
#    *    Data Set Management TRIM supported
#    *    Deterministic read data after TRIM

# For SCSI/USB (via sg3_utils)
sg_vpd -p 0xb0 /dev/sda | grep -i unmap
```

### Partition Discard

```bash
# Discard free space on mounted filesystem
sudo fstrim /mountpoint

# Discard all mounted filesystems
sudo fstrim -a

# Verbose with minimum size
sudo fstrim -v --minimum 1M /mountpoint

# Discard specific partition
# sudo blkdiscard /dev/nvme0n1p1
```

### Safety and Verification

```bash
# Dry run (check what would happen)
# blkdiscard doesn't have dry-run, but check support first:
cat /sys/block/nvme0n1/queue/discard_max_bytes
# Should be > 0 for TRIM support

cat /sys/block/nvme0n1/queue/discard_granularity
# Shows minimum discard size

# Verify TRIM is working (read back should be zeros or deterministic)
# 1. Write known pattern
# dd if=/dev/urandom of=/dev/nvme0n1 bs=1M count=1 seek=1000

# 2. Read back and verify pattern
# dd if=/dev/nvme0n1 of=/tmp/before.bin bs=1M count=1 skip=1000

# 3. TRIM the area
# blkdiscard -o 1000M -l 1M /dev/nvme0n1

# 4. Read back and check
# dd if=/dev/nvme0n1 of=/tmp/after.bin bs=1M count=1 skip=1000
# cmp /tmp/before.bin /tmp/after.bin  # Should differ if TRIM works
```

---

## wipefs - Signature Removal

`wipefs` removes filesystem, RAID, and partition table signatures without fully erasing data.

### View Signatures

```bash
# Show all signatures
wipefs /dev/nvme0n1

# Output:
# DEVICE      OFFSET TYPE UUID                                 LABEL
# /dev/nvme0n1 0x438  ext4 12345678-1234-1234-1234-123456789abc mydata
# /dev/nvme0n1 0x0    gpt
# /dev/nvme0n1 0x1fe  PMBR

# With offset in different formats
wipefs -o /dev/nvme0n1

# Show all including unused
wipefs -a /dev/nvme0n1
```

### Remove Signatures

```bash
# Remove all signatures (DANGEROUS - partition table removed)
# sudo wipefs -a /dev/nvme0n1

# Remove specific signature type
# sudo wipefs -t ext4 /dev/nvme0n1

# Remove signature at specific offset
# sudo wipefs -o 0x438 /dev/nvme0n1

# Backup signatures before removal
sudo wipefs -a -b /dev/nvme0n1
# Creates ~/wipefs-*.bak files

# Dry run - show what would be removed
wipefs -n -a /dev/nvme0n1
```

### Common Signature Types

| Type | Description | Location |
|------|-------------|----------|
| `gpt` | GUID Partition Table | Start + end of disk |
| `dos` | MBR partition table | Sector 0 |
| `ext2/3/4` | Linux filesystem | Superblock (0x438) |
| `ntfs` | Windows filesystem | Boot sector |
| `xfs` | XFS filesystem | First sector |
| `btrfs` | Btrfs filesystem | 64KB offset |
| `swap` | Linux swap | First page |
| `lvm2` | LVM metadata | Start of PV |
| `linux_raid` | MD RAID | Various offsets |
| `zfs` | ZFS pool | Multiple locations |

### Recovery After Accidental Wipe

```bash
# If you backed up signatures:
cat ~/wipefs-nvme0n1-*.bak > /dev/nvme0n1

# Manual recovery for GPT:
gdisk /dev/nvme0n1
# Use 'r' for recovery, then 'b' to rebuild backup GPT

# Manual recovery for MBR:
testdisk /dev/nvme0n1
```

---

## dmsetup - Device Mapper Manipulation

`dmsetup` controls the device-mapper kernel driver used for LVM, LUKS, multipath, and other virtual block devices.

### View Device Mapper State

```bash
# List all device-mapper devices
dmsetup ls

# Output:
# fedora-root    (253:0)
# fedora-swap    (253:1)
# luks-12345678  (253:2)

# Detailed table (shows mapping)
dmsetup table

# Output:
# fedora-root: 0 104857600 linear 259:3 2048
# fedora-swap: 0 16777216 linear 259:3 104859648

# Status of all devices
dmsetup status

# Info for specific device
dmsetup info fedora-root

# Dependencies (underlying devices)
dmsetup deps fedora-root
# 1 dependencies  : (259, 3)
```

### Create Custom Mappings

```bash
# Create linear mapping (simple passthrough)
echo "0 $(blockdev --getsz /dev/nvme0n1) linear /dev/nvme0n1 0" | \
    sudo dmsetup create nvme0n1-linear

# Create read-only snapshot
# First, create zero device for COW
echo "0 2097152 zero" | sudo dmsetup create zero-cow
# Then create snapshot
echo "0 $(blockdev --getsz /dev/nvme0n1) snapshot /dev/nvme0n1 /dev/mapper/zero-cow P 8" | \
    sudo dmsetup create nvme0n1-snap

# Create error device (for testing)
echo "0 $(blockdev --getsz /dev/nvme0n1) error" | \
    sudo dmsetup create error-dev
```

### Error Injection for Testing

```bash
# Create device that returns errors for specific sector range
# Format: start_sector num_sectors error
cat << EOF | sudo dmsetup create test-errors
0 1000 linear /dev/nvme0n1 0
1000 100 error
1100 $(( $(blockdev --getsz /dev/nvme0n1) - 1100 )) linear /dev/nvme0n1 1100
EOF

# This creates a device where sectors 1000-1099 return I/O errors
# Useful for testing application error handling
```

### Suspend and Resume

```bash
# Suspend device (pauses I/O)
sudo dmsetup suspend fedora-root

# Resume device
sudo dmsetup resume fedora-root

# Reload table (change mapping)
echo "0 $(blockdev --getsz /dev/nvme0n1) linear /dev/nvme0n1 0" | \
    sudo dmsetup reload fedora-root
sudo dmsetup resume fedora-root
```

### Remove Devices

```bash
# Remove single device
sudo dmsetup remove fedora-root

# Remove all devices (DANGEROUS)
# sudo dmsetup remove_all

# Force remove (may cause data loss)
# sudo dmsetup remove -f fedora-root
```

### Troubleshooting

```bash
# Check why device can't be removed
dmsetup info -c fedora-root
# Open count shows processes using device

# Find processes using device
lsof /dev/mapper/fedora-root
fuser -m /dev/mapper/fedora-root

# Check device-mapper kernel messages
dmesg | grep device-mapper

# Verify dm-mod is loaded
lsmod | grep dm_mod
```

---

## debugfs - Filesystem Debugging

`debugfs` is the ext2/3/4 filesystem debugger. It allows direct manipulation of filesystem structures.

### Opening Filesystem

```bash
# Open in read-only mode (safe)
debugfs /dev/nvme0n1p1

# Open in read-write mode (DANGEROUS)
debugfs -w /dev/nvme0n1p1

# Open with specific superblock
debugfs -s 1 -b 4096 /dev/nvme0n1p1
```

### Filesystem Information

```bash
# Inside debugfs:

# Show superblock
debugfs: show_super_stats
# Or shorter:
debugfs: stats

# Output shows:
# Filesystem volume name:   mydata
# Last mounted on:          /mnt/data
# Filesystem UUID:          12345678-1234-1234-1234-123456789abc
# Filesystem state:         clean
# Errors behavior:          Continue
# Inode count:              61054976
# Block count:              244190208
# Free blocks:              156789012
# Free inodes:              60123456

# List directory
debugfs: ls -l /

# Show inode info
debugfs: stat <2>        # Root inode
debugfs: stat /etc/passwd

# Show block allocation
debugfs: blocks <inode_number>
```

### File Recovery

```bash
# List deleted inodes
debugfs: lsdel

# Output:
#  Inode  Owner  Mode    Size     Blocks   Time deleted
# 123456    0 100644   4096    1/   1 Tue Jan 21 12:00:00 2026

# Undelete file (if blocks not overwritten)
debugfs: undelete <123456> /recovered/myfile.txt

# Dump file by inode (works for deleted files too)
debugfs: dump <123456> /tmp/recovered.bin

# Find inode by filename (if directory entry exists)
debugfs: ncheck 123456
# Returns: 123456 /path/to/original/file
```

### Journal Recovery

```bash
# Show journal superblock
debugfs: logdump

# Dump specific journal transaction
debugfs: logdump -b <block>

# Replay journal entries (for recovery)
# This is usually done automatically at mount
e2fsck -y /dev/nvme0n1p1
```

### Block Operations

```bash
# Read specific block
debugfs: block_dump <block_number>

# Find block usage
debugfs: testb <block_number>
# Output: Block 12345 marked in use (or not in use)

# Check block bitmap
debugfs: dump_bitmap block

# Dump group descriptor
debugfs: show_group_desc

# Find bad blocks
debugfs: dump_badblocks
```

### Dangerous Operations (Read-Write Mode)

```bash
# Set inode field (DANGEROUS)
debugfs: set_inode_field <inode> <field> <value>

# Example: Fix link count
debugfs: set_inode_field <123456> links_count 1

# Clear inode (DANGEROUS - permanent deletion)
debugfs: clri <inode>

# Modify superblock (VERY DANGEROUS)
debugfs: set_super_value <field> <value>

# Write to specific block (VERY DANGEROUS)
debugfs: write /local/file <block>

# Create directory entry
debugfs: link <inode> /path/to/newname

# Remove directory entry
debugfs: unlink /path/to/name
```

### Batch Mode

```bash
# Run commands from script
debugfs -R "stat <2>" /dev/nvme0n1p1

# Multiple commands
debugfs -R "stats" -R "ls /" /dev/nvme0n1p1

# From file
cat << 'EOF' > /tmp/debugfs_commands
stats
ls /
stat <2>
quit
EOF
debugfs -f /tmp/debugfs_commands /dev/nvme0n1p1
```

---

## Custom Tools in C/Zig

When standard tools are insufficient, custom utilities provide direct access to block devices.

### C: Raw Device Reader

```c
// raw_reader.c - Read raw sectors from block device
// Compile: gcc -O2 -o raw_reader raw_reader.c

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/fs.h>

#define SECTOR_SIZE 512

void print_hex(const unsigned char *data, size_t len, off_t offset) {
    for (size_t i = 0; i < len; i += 16) {
        printf("%08lx: ", offset + i);
        for (size_t j = 0; j < 16 && i + j < len; j++) {
            printf("%02x ", data[i + j]);
        }
        printf(" |");
        for (size_t j = 0; j < 16 && i + j < len; j++) {
            unsigned char c = data[i + j];
            printf("%c", (c >= 32 && c < 127) ? c : '.');
        }
        printf("|\n");
    }
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <device> <sector> [count]\n", argv[0]);
        fprintf(stderr, "Example: %s /dev/nvme0n1 0 8\n", argv[0]);
        return 1;
    }

    const char *device = argv[1];
    off_t sector = strtoll(argv[2], NULL, 0);
    int count = (argc > 3) ? atoi(argv[3]) : 1;

    int fd = open(device, O_RDONLY | O_DIRECT);
    if (fd < 0) {
        // Try without O_DIRECT
        fd = open(device, O_RDONLY);
        if (fd < 0) {
            perror("open");
            return 1;
        }
    }

    // Get device size
    unsigned long long device_size;
    if (ioctl(fd, BLKGETSIZE64, &device_size) < 0) {
        perror("ioctl BLKGETSIZE64");
        close(fd);
        return 1;
    }
    printf("Device size: %llu bytes (%llu sectors)\n\n",
           device_size, device_size / SECTOR_SIZE);

    // Allocate aligned buffer for O_DIRECT
    unsigned char *buffer;
    if (posix_memalign((void **)&buffer, 512, count * SECTOR_SIZE) != 0) {
        perror("posix_memalign");
        close(fd);
        return 1;
    }

    off_t offset = sector * SECTOR_SIZE;
    if (lseek(fd, offset, SEEK_SET) < 0) {
        perror("lseek");
        free(buffer);
        close(fd);
        return 1;
    }

    ssize_t bytes_read = read(fd, buffer, count * SECTOR_SIZE);
    if (bytes_read < 0) {
        perror("read");
        printf("Error reading sector %ld: %s\n", sector, strerror(errno));
        // Continue to show partial data if any
    }

    printf("Read %zd bytes from sector %ld (offset 0x%lx):\n\n",
           bytes_read, sector, offset);
    if (bytes_read > 0) {
        print_hex(buffer, bytes_read, offset);
    }

    free(buffer);
    close(fd);
    return (bytes_read < 0) ? 1 : 0;
}
```

### C: NVMe Identify via ioctl

```c
// nvme_identify.c - Send NVMe Identify command via ioctl
// Compile: gcc -O2 -o nvme_identify nvme_identify.c

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/nvme_ioctl.h>

#define NVME_IDENTIFY_CNS_CTRL 0x01

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <nvme_device>\n", argv[0]);
        fprintf(stderr, "Example: %s /dev/nvme0\n", argv[0]);
        return 1;
    }

    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    // Allocate 4KB buffer for identify data
    unsigned char *identify_data;
    if (posix_memalign((void **)&identify_data, 4096, 4096) != 0) {
        perror("posix_memalign");
        close(fd);
        return 1;
    }
    memset(identify_data, 0, 4096);

    // Build NVMe admin command
    struct nvme_admin_cmd cmd = {
        .opcode = 0x06,  // Identify
        .nsid = 0,
        .addr = (unsigned long)identify_data,
        .data_len = 4096,
        .cdw10 = NVME_IDENTIFY_CNS_CTRL,
    };

    if (ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
        perror("ioctl NVME_IOCTL_ADMIN_CMD");
        free(identify_data);
        close(fd);
        return 1;
    }

    // Parse controller identify data
    printf("NVMe Controller Identify Data:\n");
    printf("==============================\n");

    // VID (offset 0, 2 bytes)
    printf("Vendor ID:        0x%04x\n",
           *(unsigned short *)&identify_data[0]);

    // SSVID (offset 2, 2 bytes)
    printf("Subsystem VID:    0x%04x\n",
           *(unsigned short *)&identify_data[2]);

    // Serial Number (offset 4, 20 bytes)
    char sn[21] = {0};
    memcpy(sn, &identify_data[4], 20);
    printf("Serial Number:    %s\n", sn);

    // Model Number (offset 24, 40 bytes)
    char mn[41] = {0};
    memcpy(mn, &identify_data[24], 40);
    printf("Model Number:     %s\n", mn);

    // Firmware Revision (offset 64, 8 bytes)
    char fr[9] = {0};
    memcpy(fr, &identify_data[64], 8);
    printf("Firmware Rev:     %s\n", fr);

    // Total NVM Capacity (offset 280, 16 bytes as 128-bit)
    unsigned long long tnvmcap_lo = *(unsigned long long *)&identify_data[280];
    printf("Total NVM Cap:    %llu bytes (%.2f GB)\n",
           tnvmcap_lo, (double)tnvmcap_lo / 1e9);

    free(identify_data);
    close(fd);
    return 0;
}
```

### Zig: Raw Block Device Reader

```zig
// raw_reader.zig - Read raw sectors from block device
// Compile: zig build-exe -O ReleaseSafe raw_reader.zig

const std = @import("std");
const os = std.os;
const fs = std.fs;

const SECTOR_SIZE: usize = 512;

fn printHex(data: []const u8, base_offset: u64) void {
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        std.debug.print("{x:0>8}: ", .{base_offset + i});

        var j: usize = 0;
        while (j < 16 and i + j < data.len) : (j += 1) {
            std.debug.print("{x:0>2} ", .{data[i + j]});
        }

        // Padding for incomplete lines
        while (j < 16) : (j += 1) {
            std.debug.print("   ", .{});
        }

        std.debug.print(" |", .{});
        j = 0;
        while (j < 16 and i + j < data.len) : (j += 1) {
            const c = data[i + j];
            if (c >= 32 and c < 127) {
                std.debug.print("{c}", .{c});
            } else {
                std.debug.print(".", .{});
            }
        }
        std.debug.print("|\n", .{});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <device> <sector> [count]\n", .{args[0]});
        std.debug.print("Example: {s} /dev/nvme0n1 0 8\n", .{args[0]});
        return;
    }

    const device_path = args[1];
    const sector = try std.fmt.parseInt(u64, args[2], 0);
    const count: usize = if (args.len > 3)
        try std.fmt.parseInt(usize, args[3], 10)
    else
        1;

    const file = try fs.openFileAbsolute(device_path, .{ .mode = .read_only });
    defer file.close();

    // Get device size via ioctl
    const BLKGETSIZE64: u32 = 0x80081272;
    var device_size: u64 = 0;
    const ioctl_result = os.linux.ioctl(file.handle, BLKGETSIZE64, @intFromPtr(&device_size));
    if (ioctl_result == 0) {
        std.debug.print("Device size: {} bytes ({} sectors)\n\n", .{
            device_size,
            device_size / SECTOR_SIZE
        });
    }

    const offset = sector * SECTOR_SIZE;
    const read_size = count * SECTOR_SIZE;

    // Allocate buffer
    const buffer = try allocator.alloc(u8, read_size);
    defer allocator.free(buffer);

    // Seek and read
    try file.seekTo(offset);
    const bytes_read = try file.read(buffer);

    std.debug.print("Read {} bytes from sector {} (offset 0x{x}):\n\n", .{
        bytes_read,
        sector,
        offset
    });

    if (bytes_read > 0) {
        printHex(buffer[0..bytes_read], offset);
    }
}
```

### Zig: NVMe SMART Reader

```zig
// nvme_smart.zig - Read NVMe SMART data via ioctl
// Compile: zig build-exe -O ReleaseSafe nvme_smart.zig

const std = @import("std");
const os = std.os;
const fs = std.fs;

const NvmeAdminCmd = extern struct {
    opcode: u8,
    flags: u8,
    rsvd1: u16,
    nsid: u32,
    cdw2: u32,
    cdw3: u32,
    metadata: u64,
    addr: u64,
    metadata_len: u32,
    data_len: u32,
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,
    timeout_ms: u32,
    result: u32,
};

const NVME_IOCTL_ADMIN_CMD: u32 = 0xC0484E41;

const SmartLog = extern struct {
    critical_warning: u8,
    temperature: [2]u8,
    avail_spare: u8,
    spare_thresh: u8,
    percent_used: u8,
    endurance_grp_critical: u8,
    rsvd7: [25]u8,
    data_units_read: [16]u8,
    data_units_written: [16]u8,
    host_reads: [16]u8,
    host_writes: [16]u8,
    ctrl_busy_time: [16]u8,
    power_cycles: [16]u8,
    power_on_hours: [16]u8,
    unsafe_shutdowns: [16]u8,
    media_errors: [16]u8,
    num_err_log_entries: [16]u8,
    warning_temp_time: u32,
    critical_temp_time: u32,
    temp_sensor: [8]u16,
};

fn readU128(bytes: [16]u8) u128 {
    return @as(u128, bytes[0]) |
           (@as(u128, bytes[1]) << 8) |
           (@as(u128, bytes[2]) << 16) |
           (@as(u128, bytes[3]) << 24) |
           (@as(u128, bytes[4]) << 32) |
           (@as(u128, bytes[5]) << 40) |
           (@as(u128, bytes[6]) << 48) |
           (@as(u128, bytes[7]) << 56);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <nvme_device>\n", .{args[0]});
        std.debug.print("Example: {s} /dev/nvme0\n", .{args[0]});
        return;
    }

    const file = try fs.openFileAbsolute(args[1], .{ .mode = .read_only });
    defer file.close();

    // Allocate page-aligned buffer
    const page_size = 4096;
    const raw_buffer = try std.posix.mmap(
        null,
        page_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(raw_buffer);

    @memset(raw_buffer, 0);

    // Build NVMe admin command for Get Log Page (SMART)
    var cmd = NvmeAdminCmd{
        .opcode = 0x02,  // Get Log Page
        .flags = 0,
        .rsvd1 = 0,
        .nsid = 0xFFFFFFFF,  // Global
        .cdw2 = 0,
        .cdw3 = 0,
        .metadata = 0,
        .addr = @intFromPtr(raw_buffer.ptr),
        .metadata_len = 0,
        .data_len = 512,
        .cdw10 = 0x007F0002,  // Log ID 2 (SMART), NUMD = 127 (512 bytes)
        .cdw11 = 0,
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
        .timeout_ms = 0,
        .result = 0,
    };

    const result = os.linux.ioctl(file.handle, NVME_IOCTL_ADMIN_CMD, @intFromPtr(&cmd));
    if (result != 0) {
        std.debug.print("ioctl failed with error: {}\n", .{result});
        return;
    }

    const smart: *SmartLog = @ptrCast(@alignCast(raw_buffer.ptr));

    std.debug.print("NVMe SMART/Health Information:\n", .{});
    std.debug.print("==============================\n", .{});

    // Critical Warning
    std.debug.print("Critical Warning:       0x{x:0>2}", .{smart.critical_warning});
    if (smart.critical_warning == 0) {
        std.debug.print(" (OK)\n", .{});
    } else {
        std.debug.print(" (WARNING!)\n", .{});
        if (smart.critical_warning & 0x01 != 0)
            std.debug.print("  - Available spare below threshold\n", .{});
        if (smart.critical_warning & 0x02 != 0)
            std.debug.print("  - Temperature above threshold\n", .{});
        if (smart.critical_warning & 0x04 != 0)
            std.debug.print("  - NVM subsystem reliability degraded\n", .{});
        if (smart.critical_warning & 0x08 != 0)
            std.debug.print("  - Media in read-only mode\n", .{});
        if (smart.critical_warning & 0x10 != 0)
            std.debug.print("  - Volatile memory backup failed\n", .{});
    }

    // Temperature (Kelvin to Celsius)
    const temp_k = @as(u16, smart.temperature[0]) | (@as(u16, smart.temperature[1]) << 8);
    const temp_c: i32 = @as(i32, temp_k) - 273;
    std.debug.print("Temperature:            {} C\n", .{temp_c});

    std.debug.print("Available Spare:        {}%\n", .{smart.avail_spare});
    std.debug.print("Spare Threshold:        {}%\n", .{smart.spare_thresh});
    std.debug.print("Percentage Used:        {}%\n", .{smart.percent_used});

    // 128-bit counters (just use lower 64 bits for display)
    const data_read = readU128(smart.data_units_read);
    const data_written = readU128(smart.data_units_written);
    const power_cycles = readU128(smart.power_cycles);
    const power_on_hours = readU128(smart.power_on_hours);
    const unsafe_shutdowns = readU128(smart.unsafe_shutdowns);
    const media_errors = readU128(smart.media_errors);

    // Data units are 512KB each
    std.debug.print("Data Read:              {} GB\n", .{data_read * 512 * 1000 / 1000000000});
    std.debug.print("Data Written:           {} GB\n", .{data_written * 512 * 1000 / 1000000000});
    std.debug.print("Power Cycles:           {}\n", .{power_cycles});
    std.debug.print("Power On Hours:         {}\n", .{power_on_hours});
    std.debug.print("Unsafe Shutdowns:       {}\n", .{unsafe_shutdowns});
    std.debug.print("Media Errors:           {}\n", .{media_errors});
}
```

### Makefile for Custom Tools

```makefile
# Makefile for custom low-level tools

CC = gcc
CFLAGS = -O2 -Wall -Wextra
ZIG = zig

C_TARGETS = raw_reader nvme_identify
ZIG_TARGETS = raw_reader_zig nvme_smart_zig

all: $(C_TARGETS) $(ZIG_TARGETS)

raw_reader: raw_reader.c
	$(CC) $(CFLAGS) -o $@ $<

nvme_identify: nvme_identify.c
	$(CC) $(CFLAGS) -o $@ $<

raw_reader_zig: raw_reader.zig
	$(ZIG) build-exe -O ReleaseSafe -femit-bin=$@ $<

nvme_smart_zig: nvme_smart.zig
	$(ZIG) build-exe -O ReleaseSafe -femit-bin=$@ $<

clean:
	rm -f $(C_TARGETS) $(ZIG_TARGETS) *.o

install: all
	install -m 755 $(C_TARGETS) $(ZIG_TARGETS) /usr/local/bin/

.PHONY: all clean install
```

---

## Diagnostic Workflows

### Initial Drive Assessment

```bash
#!/bin/bash
# drive_assessment.sh - Initial assessment of potentially corrupted drive
# Usage: sudo ./drive_assessment.sh /dev/nvme0

DEVICE=$1

if [ -z "$DEVICE" ]; then
    echo "Usage: $0 <device>"
    exit 1
fi

echo "=== Drive Assessment for $DEVICE ==="
echo "Date: $(date)"
echo

# Detect device type
if [[ "$DEVICE" == /dev/nvme* ]]; then
    DEVICE_TYPE="nvme"
elif [[ "$DEVICE" == /dev/sd* ]]; then
    DEVICE_TYPE="sata"
else
    DEVICE_TYPE="unknown"
fi

echo "Device type: $DEVICE_TYPE"
echo

# Basic identification
echo "=== Device Identification ==="
if [ "$DEVICE_TYPE" = "nvme" ]; then
    nvme list | grep -E "^$DEVICE|Node"
    echo
    nvme id-ctrl "$DEVICE" 2>/dev/null | grep -E "^(sn|mn|fr|tnvmcap)"
else
    hdparm -I "$DEVICE" 2>/dev/null | grep -E "(Model|Serial|Firmware)"
fi
echo

# SMART/Health
echo "=== Health Status ==="
if [ "$DEVICE_TYPE" = "nvme" ]; then
    nvme smart-log "$DEVICE" 2>/dev/null
else
    smartctl -H "$DEVICE" 2>/dev/null
fi
echo

# Error logs
echo "=== Error Log ==="
if [ "$DEVICE_TYPE" = "nvme" ]; then
    nvme error-log "$DEVICE" 2>/dev/null | head -50
else
    smartctl -l error "$DEVICE" 2>/dev/null | head -50
fi
echo

# Filesystem signatures
echo "=== Filesystem Signatures ==="
wipefs "$DEVICE"* 2>/dev/null
echo

# Partition table
echo "=== Partition Table ==="
fdisk -l "$DEVICE" 2>/dev/null
echo

# Device mapper status
echo "=== Device Mapper Status ==="
dmsetup ls 2>/dev/null | grep -v "No devices"
echo

# Kernel messages
echo "=== Recent Kernel Messages (device errors) ==="
dmesg | grep -iE "(nvme|sd[a-z]|error|fail|corrupt)" | tail -30
echo

echo "=== Assessment Complete ==="
```

### Recovery Workflow

```bash
#!/bin/bash
# recovery_workflow.sh - Guided recovery workflow
# Usage: sudo ./recovery_workflow.sh /dev/nvme0n1

DEVICE=$1
BACKUP_DIR="/tmp/recovery_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP_DIR"

echo "=== NVMe Recovery Workflow ==="
echo "Device: $DEVICE"
echo "Backup directory: $BACKUP_DIR"
echo

# Step 1: Preserve evidence
echo "Step 1: Preserving metadata..."
nvme smart-log "$DEVICE" > "$BACKUP_DIR/smart_log.txt" 2>&1
nvme error-log "$DEVICE" > "$BACKUP_DIR/error_log.txt" 2>&1
wipefs "$DEVICE" > "$BACKUP_DIR/signatures.txt" 2>&1
fdisk -l "$DEVICE" > "$BACKUP_DIR/partitions.txt" 2>&1

# Backup partition table
if command -v sgdisk &> /dev/null; then
    sgdisk --backup="$BACKUP_DIR/gpt_backup.bin" "$DEVICE" 2>/dev/null
fi

echo "Metadata saved to $BACKUP_DIR"
echo

# Step 2: Check for critical issues
echo "Step 2: Checking critical status..."
CRITICAL=$(nvme smart-log "$DEVICE" 2>/dev/null | grep "critical_warning" | awk '{print $3}')
if [ "$CRITICAL" != "0" ] && [ -n "$CRITICAL" ]; then
    echo "WARNING: Critical warning flag is set ($CRITICAL)"
    echo "Drive may have serious issues. Proceed with caution."
fi

SPARE=$(nvme smart-log "$DEVICE" 2>/dev/null | grep "available_spare" | awk '{print $3}' | tr -d '%')
if [ -n "$SPARE" ] && [ "$SPARE" -lt 10 ]; then
    echo "WARNING: Available spare is low ($SPARE%)"
    echo "Drive is near end of life."
fi

MEDIA_ERRORS=$(nvme smart-log "$DEVICE" 2>/dev/null | grep "media_errors" | awk '{print $3}')
if [ "$MEDIA_ERRORS" != "0" ] && [ -n "$MEDIA_ERRORS" ]; then
    echo "WARNING: Media errors detected ($MEDIA_ERRORS)"
    echo "Drive has failing flash cells."
fi
echo

# Step 3: Self-test
echo "Step 3: Running short self-test..."
echo "(This may take 1-2 minutes)"
nvme device-self-test "$DEVICE" -s 1 2>/dev/null
sleep 120
nvme self-test-log "$DEVICE" > "$BACKUP_DIR/selftest_log.txt" 2>&1
cat "$BACKUP_DIR/selftest_log.txt"
echo

# Step 4: Recommendations
echo "Step 4: Recommendations"
echo "========================"
echo
echo "Based on assessment, consider these actions:"
echo
echo "1. Image the drive immediately:"
echo "   ddrescue $DEVICE $BACKUP_DIR/image.img $BACKUP_DIR/ddrescue.log"
echo
echo "2. If filesystem is ext4, try repair:"
echo "   fsck.ext4 -n ${DEVICE}p1  # Read-only check first"
echo "   fsck.ext4 -y ${DEVICE}p1  # Repair (if needed)"
echo
echo "3. If filesystem is NTFS:"
echo "   ntfsfix -n ${DEVICE}p1    # Read-only check"
echo "   ntfsfix ${DEVICE}p1       # Fix hibernation flag"
echo
echo "4. For data recovery tools:"
echo "   testdisk $DEVICE          # Partition recovery"
echo "   photorec $DEVICE          # File recovery"
echo
echo "5. If drive is still healthy but slow:"
echo "   nvme format $DEVICE -s 1  # Secure erase (DATA LOSS!)"
echo

echo "=== Workflow Complete ==="
echo "Backup saved to: $BACKUP_DIR"
```

---

## Dangerous Commands Reference

This section catalogs commands that can cause data loss or drive damage. **Use with extreme caution.**

### Data Destruction Commands

| Command | Risk Level | Description |
|---------|------------|-------------|
| `nvme format /dev/nvme0n1` | **CRITICAL** | Formats entire drive, all data lost |
| `nvme sanitize /dev/nvme0 -a 2` | **CRITICAL** | Block erase, unrecoverable |
| `nvme sanitize /dev/nvme0 -a 4` | **CRITICAL** | Crypto erase, instant data destruction |
| `hdparm --security-erase PASS /dev/sda` | **CRITICAL** | ATA secure erase |
| `blkdiscard /dev/nvme0n1` | **HIGH** | TRIMs entire device |
| `wipefs -a /dev/nvme0n1` | **HIGH** | Removes all filesystem signatures |
| `dd if=/dev/zero of=/dev/nvme0n1` | **CRITICAL** | Overwrites all data |
| `sg_format --format /dev/sda` | **CRITICAL** | Low-level SCSI format |

### Firmware/Configuration Commands

| Command | Risk Level | Description |
|---------|------------|-------------|
| `nvme fw-download` | **CRITICAL** | Flash firmware - can brick drive |
| `nvme fw-activate` | **CRITICAL** | Activate firmware slot |
| `hdparm --security-set-pass` | **HIGH** | Can lock drive permanently |
| `nvme set-feature` | **MEDIUM** | May change drive behavior |

### Filesystem Manipulation

| Command | Risk Level | Description |
|---------|------------|-------------|
| `debugfs -w` | **HIGH** | Write mode can corrupt filesystem |
| `debugfs: clri` | **CRITICAL** | Permanently deletes inode |
| `debugfs: set_super_value` | **CRITICAL** | Can corrupt superblock |
| `dmsetup remove_all` | **HIGH** | Removes all device mappings |

### Safe Diagnostic Commands

| Command | Risk Level | Description |
|---------|------------|-------------|
| `nvme list` | **SAFE** | List devices |
| `nvme smart-log` | **SAFE** | Read SMART data |
| `nvme error-log` | **SAFE** | Read error log |
| `nvme id-ctrl` | **SAFE** | Identify controller |
| `nvme device-self-test -s 1` | **SAFE** | Short self-test |
| `hdparm -I` | **SAFE** | Drive identification |
| `wipefs` (no flags) | **SAFE** | Just displays signatures |
| `debugfs` (read-only) | **SAFE** | Filesystem inspection |
| `dmsetup ls` | **SAFE** | List mappings |
| `dmsetup table` | **SAFE** | Show mapping tables |

### Safety Checklist Before Dangerous Operations

1. **Verify target device**: Double-check device name with `lsblk` and `nvme list`
2. **Backup critical data**: Image drive with `ddrescue` if possible
3. **Backup partition table**: `sgdisk --backup` or `sfdisk -d`
4. **Backup filesystem signatures**: `wipefs -a -b` creates backup files
5. **Unmount filesystems**: `umount` all partitions first
6. **Check for open handles**: `lsof` and `fuser`
7. **Disable automounting**: Prevent desktop from remounting
8. **Document current state**: Save SMART logs and partition info

---

## Additional Resources

### Man Pages

- `man nvme` - NVMe CLI manual
- `man hdparm` - ATA parameter utility
- `man sg3_utils` - SCSI utility overview
- `man sg_inq`, `man sg_modes`, etc. - Individual sg3_utils commands
- `man blkdiscard` - Discard utility
- `man wipefs` - Signature removal
- `man dmsetup` - Device mapper control
- `man debugfs` - ext2/3/4 debugger

### Kernel Documentation

- `/usr/share/doc/kernel-doc*/Documentation/block/`
- `/usr/share/doc/kernel-doc*/Documentation/nvme/`
- https://www.kernel.org/doc/html/latest/block/
- https://www.kernel.org/doc/html/latest/driver-api/nvme.html

### Specifications

- NVMe Specification: https://nvmexpress.org/specifications/
- ATA/ATAPI Specification: https://www.t13.org/
- SCSI Specifications: https://www.t10.org/

### Recovery Tools

- **ddrescue** - GNU data recovery tool
- **testdisk** - Partition recovery
- **photorec** - File recovery (carving)
- **foremost** - File carving tool
- **sleuthkit** - Forensic analysis

---

*Document generated for hiberpower-ntfs project diagnostic reference.*
