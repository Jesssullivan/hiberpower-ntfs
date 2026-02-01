# HiberPower-NTFS: Low-Level NVMe Corruption Research

**Timeline**: 20 weeks
**Start Date**: 2026-01-21

## Problem Statement

A 256GB NVMe SSD connected via USB exhibits persistent corruption believed to originate from Windows NTFS hibernate/fast boot state. The drive resists all standard reformatting attempts:

- `fdisk` / `gdisk` - partition table changes don't persist
- `dd if=/dev/zero of=/dev/sdX` - fails to successfully write zeros
- ntfs-3g utilities - unable to repair or reformat
- Standard Linux disk utilities (GNOME Disks, etc.)

**Key Observation**: The failure of `dd` to write zeros suggests controller-level or firmware-level issues, not merely filesystem corruption.

## Research Objectives

### 1. Investigation Phase
- Use LLDB and low-level debugging to examine register/memory block states
- Investigate NVMe controller behavior and command responses
- Identify potential pointer overflows or lock states
- Examine USB-NVMe bridge behavior (if applicable)

### 2. Reproduction Phase
- Create reproducible test environment (qcow2/disk image)
- Document exact Windows hibernate/fast boot states that trigger corruption
- Develop methodology to reliably recreate the issue

### 3. Recovery/Resolution Phase
- Architect low-level fix or recovery mechanism
- Successfully zero or reformat the drive
- Document the solution

### 4. Documentation Phase
- Research paper with TikZ diagrams
- Reproducible methodology for other researchers

## Technical Approach

### Languages Under Consideration
- **Zig** - Memory safety with low-level control
- **C** - Direct hardware access, widest driver support
- **Hare** - Modern systems programming
- **Verilog** - If FPGA-based analysis needed
- **Rust** - Memory safety with low-level capabilities

### Tools & Frameworks
- LLDB for debugging
- nvme-cli for NVMe commands
- blktrace/blkparse for I/O tracing
- QEMU/KVM for virtualized testing
- Custom tooling as needed

## Hardware Details

- **Device**: 256GB NVMe SSD
- **Interface**: USB (likely USB-NVMe bridge controller)
- **Original OS**: Windows (with hibernate/fast boot enabled)
- **Current Host**: Linux

## Research Questions

1. What NVMe admin commands does the controller reject/ignore?
2. Is the USB-NVMe bridge contributing to the issue?
3. What state does Windows hibernate leave the drive in?
4. Can NVMe secure erase bypass the corruption?
5. Are there firmware-level locks preventing writes?
6. How does the controller respond to TRIM/UNMAP commands?

## Initial Commands to Try

```bash
# Identify the device
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
lsusb -v | grep -A 20 "Mass Storage"
nvme list
nvme id-ctrl /dev/nvmeXnY

# Check NVMe capabilities
nvme id-ns /dev/nvmeXnY -n 1
nvme get-feature /dev/nvmeXnY -f 0x06  # Volatile Write Cache
nvme get-log /dev/nvmeXnY -i 1 -l 512  # Error log

# Attempt secure erase (if supported)
nvme format /dev/nvmeXnY --ses=1  # User data erase
nvme format /dev/nvmeXnY --ses=2  # Cryptographic erase

# Check for write protection
hdparm -r /dev/sdX
blockdev --getro /dev/sdX

# Examine partition table at byte level
xxd /dev/sdX | head -100
```

## File Structure

```
hiberpower-ntfs/
├── PROJECT.md           # This file
├── docs/
│   ├── paper/          # LaTeX + TikZ research paper
│   └── notes/          # Investigation notes
├── src/
│   ├── tools/          # Custom diagnostic tools
│   └── tests/          # Reproduction tests
├── data/
│   ├── dumps/          # Raw data captures
│   └── logs/           # Command outputs and traces
└── images/
    └── qcow2/          # Disk images for reproduction
```

## Team/Agent Responsibilities

1. **NVMe Protocol Analysis** - Deep dive into NVMe spec and controller commands
2. **NTFS/Windows Research** - Hibernate state, fast boot, and corruption patterns
3. **Linux Kernel/Driver** - Why dd fails, kernel messages, driver behavior
4. **Low-Level Tools** - nvme-cli, hdparm, sg_utils, custom tooling
5. **Reproduction Environment** - QEMU/qcow2 test setup
6. **Literature Review** - Existing research on similar issues
