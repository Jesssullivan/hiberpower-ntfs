# NVMe Protocol Analysis: Understanding Drive Reformat Resistance

## Executive Summary

This document analyzes NVMe protocol-level mechanisms that can cause a drive to resist reformatting operations. Understanding these mechanisms is critical for diagnosing and potentially recovering drives that appear "stuck" in read-only or otherwise unwritable states.

---

## 1. NVMe Admin Command Set

The NVMe Admin Command Set contains critical commands for drive management. These commands are sent to the Admin Submission Queue (queue ID 0) and are distinct from I/O commands used for normal read/write operations.

### 1.1 Format NVM Command

The **Format NVM** command reformats the media and can optionally perform secure erase operations.

**Key Parameters:**
- **LBAF (LBA Format)**: Specifies the LBA format to use after formatting
- **SES (Secure Erase Settings)**:
  - `0x0`: No secure erase
  - `0x1`: User Data Erase (cryptographic erase if supported)
  - `0x2`: Cryptographic Erase

**Limitations:**
- May fail if the controller does not support formatting individual namespaces (check `ID_CTRL.FNA` bit 0)
- Cannot overcome hardware-level write protection
- Does not clear caches as thoroughly as Sanitize

**nvme-cli command:**
```bash
# Format namespace 1 with no secure erase
nvme format /dev/nvme0 --namespace-id=1 --ses=0

# Format with user data erase
nvme format /dev/nvme0 --namespace-id=1 --ses=1

# Format all namespaces (if FNA bit 0 is set)
nvme format /dev/nvme0 --namespace-id=0xffffffff
```

### 1.2 Sanitize Command (NVMe 1.3+)

The **Sanitize** command provides more comprehensive data removal than Format NVM.

**Key Differences from Format:**
- Clears all caches (guaranteed)
- Resumes automatically after unexpected power loss
- Erases over-provisioned areas
- Supports pattern overwrite (not recommended for NAND due to wear)

**Sanitize Actions:**
- **Block Erase**: Physical NAND block erase
- **Crypto Erase**: Destroys encryption key
- **Overwrite**: Pattern-based overwrite (poor NAND endurance)

**nvme-cli commands:**
```bash
# Check sanitize capabilities
nvme id-ctrl /dev/nvme0 | grep -i sanicap

# Block erase sanitize
nvme sanitize /dev/nvme0 --sanact=2

# Crypto erase sanitize
nvme sanitize /dev/nvme0 --sanact=4

# Check sanitize progress
nvme sanitize-log /dev/nvme0
```

### 1.3 Write Uncorrectable Command

Marks logical blocks as invalid. Subsequent reads return "Unrecovered Read Error" status.

**Use cases:**
- Error injection for testing
- Marking known-bad sectors

**Recovery:**
- A write operation to the affected blocks clears the uncorrectable status

```bash
# Mark blocks as uncorrectable
nvme write-uncor /dev/nvme0n1 --start-block=0 --block-count=1
```

---

## 2. NVMe Controller States That Block Writes

### 2.1 Namespace Write Protection (NVMe 1.4+)

The Namespace Write Protection feature provides protocol-level write blocking that can persist across power cycles.

**Write Protection States:**

| State | Description | Persistence |
|-------|-------------|-------------|
| `No Write Protect` | Normal operation | N/A |
| `Write Protect` | Blocks writes until explicitly disabled | Survives power cycles |
| `Write Protect Until Power Cycle` | Blocks writes until next power cycle | Clears on power cycle |
| `Permanent Write Protect` | **Irreversible** - drive becomes permanently read-only | Forever |

**Feature ID:** `0x84` (Write Protection Config)

**Diagnostic commands:**
```bash
# Check if write protection is supported
nvme id-ctrl /dev/nvme0 | grep -i nwpc

# Get current write protection state
nvme get-feature /dev/nvme0 --feature-id=0x84 --namespace-id=1

# Disable write protection (if not permanent)
nvme set-feature /dev/nvme0 --feature-id=0x84 --value=0 --namespace-id=1

# To make the change persistent across power cycles, add --save
nvme set-feature /dev/nvme0 --feature-id=0x84 --value=0 --namespace-id=1 --save
```

### 2.2 Namespace States

NVMe namespaces can exist in various states that affect accessibility:

**Namespace Attachment:**
- Namespaces must be attached to a controller to be accessible
- Detached namespaces are invisible to the host

**Diagnostic commands:**
```bash
# List all namespaces (including unattached)
nvme list-ns /dev/nvme0 --all

# List only attached namespaces
nvme list-ns /dev/nvme0

# Identify namespace state
nvme id-ns /dev/nvme0 --namespace-id=1
```

### 2.3 Controller Ready Timeout (CSTS.RDY)

The Controller Status Register's Ready bit (CSTS.RDY) indicates controller operational state.

**Common failure indicators:**
- `CSTS=0xffffffff`: Controller completely unresponsive (often hardware/PCIe failure)
- `CSTS=0x1`: Controller not ready (may recover after reset or timeout)

**Kernel messages indicating controller issues:**
```
nvme nvme0: controller is down; will reset: CSTS=0xffffffff
nvme nvme0: Device not ready; aborting reset, CSTS=0x1
```

### 2.4 Critical Warning States (Read-Only Mode)

SSDs can enter a firmware-controlled read-only mode when detecting critical issues.

**Critical Warning Bit Flags (from SMART log):**

| Bit | Meaning |
|-----|---------|
| 0 | Available spare capacity below threshold |
| 1 | Temperature exceeded threshold |
| 2 | NVM subsystem reliability degraded |
| 3 | **Media placed in read-only mode** |
| 4 | Volatile memory backup failed |

```bash
# Check critical warning status
nvme smart-log /dev/nvme0

# Human-readable format showing bit breakdown
nvme smart-log /dev/nvme0 -H
```

**Important:** When bit 3 is set, the drive has entered hardware-level read-only mode due to detected faults. This is typically **not recoverable** through software commands.

---

## 3. USB-NVMe Bridge Controller Translation Issues

### 3.1 Common Bridge Chipsets

| Chipset | Vendor | USB Speed | Notes |
|---------|--------|-----------|-------|
| JMS583 | JMicron | USB 3.1 Gen 2 (10Gbps) | Most common, stability issues on A0 revision |
| JMS586 | JMicron | USB 3.2 Gen 2x2 (20Gbps) | RAID support |
| ASM2362 | ASMedia | USB 3.1 Gen 2 (10Gbps) | Generally more stable |
| RTL9210 | Realtek | USB 3.1 Gen 2 (10Gbps) | Alternative option |

### 3.2 Command Translation Limitations

USB-NVMe bridges translate NVMe commands to/from SCSI commands. This creates significant limitations:

**What typically works:**
- Basic read/write operations
- IDENTIFY commands (via SCSI INQUIRY translation)
- SMART data retrieval (via SCSI LOG SENSE)

**What often fails:**
- **Format NVM**: May not pass through USB bridge
- **Sanitize**: Typically blocked or unsupported
- **Security Send/Receive**: Vendor-specific passthrough required
- **Namespace Management**: Usually not exposed
- **Set Features (write protect)**: May not translate

**JMicron JMS583 Specifics:**
- Supports SCSI SECURITY PROTOCOL IN/OUT commands
- Handles ATA PASS THROUGH in vendor-specific way
- May support NVMe passthrough via proprietary commands

### 3.3 SCSI-to-NVMe Translation (SNTL)

The SCSI-to-NVMe Translation Layer was dropped from the Linux kernel in 2017. Current implementations:

- `sg3_utils` provides limited SNTL for basic commands
- No standardized NVMe passthrough over USB exists
- Vendor-specific passthrough varies by chipset

### 3.4 UAS (USB Attached SCSI) Issues

Some bridge chips advertise UAS but behave poorly:

**Symptoms:**
- Random I/O errors
- Resets and disconnects
- Poor SMART passthrough

**Workaround:**
```bash
# Disable UAS for problematic device (add to kernel boot parameters)
usb-storage.quirks=VENDOR_ID:PRODUCT_ID:u

# Example for a specific device
usb-storage.quirks=152d:0583:u
```

### 3.5 Recommendation for Admin Commands

**Critical:** Many NVMe admin commands (Format, Sanitize, Security) will fail through USB enclosures. For recovery operations:

1. **Connect the drive directly to an M.2 slot or PCIe adapter**
2. Use native NVMe interface, not USB bridge
3. USB enclosures are only reliable for basic data access

---

## 4. NVMe Security Features

### 4.1 TCG Opal Overview

TCG Opal is the primary self-encrypting drive (SED) standard for consumer/prosumer NVMe drives.

**Key Concepts:**
- **Media Encryption Key (MEK)**: Encrypts all data on drive
- **Key Encryption Key (KEK)**: Encrypts the MEK
- **Authentication Key**: User password that derives KEK
- **Locking Range**: Portion of drive controlled by a password

**Lock States:**
- **Unlocked**: Normal read/write access
- **Locked**: Drive powered off or locked by command
- **MBR Shadowing**: Pre-boot authentication environment

### 4.2 TCG Discovery

```bash
# Install sedutil
# https://github.com/Drive-Trust-Alliance/sedutil

# Query TCG capabilities (Level 0 Discovery)
sedutil-cli --query /dev/nvme0

# Scan for Opal-compliant drives
sedutil-cli --scan
```

### 4.3 Opal Drive States That Block Access

| State | Description | Recovery |
|-------|-------------|----------|
| Locked | Normal lock state | Provide password |
| Locking Enabled | Drive will lock on power cycle | Disable locking or keep unlocked |
| MBR Done = False | PBA required | Complete pre-boot auth |
| PSID Reset Required | Password lost | Factory reset with PSID (destroys data) |

### 4.4 Unlocking and Recovery Commands

```bash
# Unlock a locked drive
sedutil-cli --setlockingrange 0 RW <password> /dev/nvme0

# Disable locking entirely
sedutil-cli --disablelockingrange 0 <password> /dev/nvme0

# Factory reset using PSID (DESTROYS ALL DATA)
# PSID is typically printed on drive label
sedutil-cli --yesIreallywanttoERASEALLmydatausingthePSID <PSID> /dev/nvme0
```

### 4.5 ATA Security (Legacy)

Some NVMe drives also support ATA Security commands for compatibility:

**States:**
- Security Enabled
- Security Locked
- Security Frozen (prevents lock state changes until power cycle)

**Note:** ATA Security is less common on modern NVMe drives; TCG Opal is preferred.

---

## 5. Controller Firmware States

### 5.1 Persistent States Across Power Cycles

The following states can persist:

| State | Persistence | Reset Method |
|-------|-------------|--------------|
| Namespace Write Protect | Yes (unless Until Power Cycle) | Set Feature command |
| TCG Opal Lock | Yes | Password or PSID |
| Critical Warning Flags | Yes | Cannot be cleared (hardware state) |
| Firmware Slot Selection | Yes | Firmware Activate command |
| Feature Settings (with --save) | Yes | Set Feature without --save |

### 5.2 Firmware-Triggered Read-Only Mode

SSDs enter read-only mode as a protective measure when:

1. **NAND wear exhaustion**: Percentage used approaches/exceeds 100%
2. **Media errors**: Uncorrectable errors exceed threshold
3. **Available spare depletion**: Spare blocks exhausted
4. **Temperature damage**: Prolonged thermal throttling
5. **Firmware fault**: Internal error triggers protection

**This state is typically permanent and indicates impending drive failure.**

### 5.3 Controller Reset Methods

```bash
# NVMe controller reset (Linux kernel)
echo 1 > /sys/class/nvme/nvme0/reset_controller

# Full rescan of NVMe devices
echo 1 > /sys/bus/pci/rescan

# NVMe subsystem reset (more aggressive)
nvme reset /dev/nvme0

# Power cycle (physical)
# Most reliable reset method - requires removing power completely
```

---

## 6. NVMe Namespace Management

### 6.1 Namespace Lifecycle

```
[Capacity] --> create-ns --> [Allocated] --> attach-ns --> [Attached/Accessible]
                                  ^                              |
                                  |                              v
                             delete-ns <-- detach-ns <-- [Detached/Inaccessible]
```

### 6.2 Namespace Commands

```bash
# List all namespaces
nvme list-ns /dev/nvme0 --all

# Create a new namespace
nvme create-ns /dev/nvme0 --nsze=<size_blocks> --ncap=<capacity_blocks> --flbas=0 --dps=0

# Attach namespace to controller
nvme attach-ns /dev/nvme0 --namespace-id=1 --controllers=0

# Detach namespace from controller
nvme detach-ns /dev/nvme0 --namespace-id=1 --controllers=0

# Delete namespace
nvme delete-ns /dev/nvme0 --namespace-id=1

# Reset controller to recognize changes
nvme reset /dev/nvme0
```

### 6.3 Namespace Issues That Block Operations

- **Namespace not attached**: Commands may fail with INVALID_NS
- **Namespace write protected**: Write operations blocked
- **Namespace in format operation**: May be temporarily unavailable

---

## 7. Comprehensive Diagnostic Procedure

### 7.1 Initial Assessment

```bash
#!/bin/bash
# NVMe Drive Diagnostic Script
DEVICE=${1:-/dev/nvme0}

echo "=== NVMe Drive Diagnostic Report ==="
echo "Device: $DEVICE"
echo "Date: $(date)"
echo

echo "=== Controller Identification ==="
nvme id-ctrl $DEVICE | head -30

echo
echo "=== Namespace List ==="
nvme list-ns $DEVICE --all

echo
echo "=== SMART/Health Log ==="
nvme smart-log $DEVICE

echo
echo "=== Error Log ==="
nvme error-log $DEVICE --log-entries=10

echo
echo "=== Firmware Log ==="
nvme fw-log $DEVICE

echo
echo "=== Supported Features ==="
nvme id-ctrl $DEVICE | grep -E "oacs|oncs|fna|vwc|nwpc|sanicap"

echo
echo "=== Write Protection Status ==="
nvme get-feature $DEVICE --feature-id=0x84 --namespace-id=1 2>/dev/null || echo "Write protection feature not supported or accessible"
```

### 7.2 Key Fields to Check

**From `id-ctrl`:**
- `oacs`: Optional Admin Command Support (format, sanitize support)
- `oncs`: Optional NVM Command Support
- `fna`: Format NVM Attributes (formatting scope)
- `sanicap`: Sanitize Capabilities
- `nwpc`: Namespace Write Protection Capabilities

**From `smart-log`:**
- `critical_warning`: Non-zero indicates issues
- `percentage_used`: Drive wear level
- `available_spare`: Remaining spare blocks
- `media_errors`: Uncorrectable error count

### 7.3 Recovery Flowchart

```
Drive won't format/write
         |
         v
[Check SMART critical_warning]
         |
    Bit 3 set? --> YES --> Drive in hardware read-only mode
         |                         |
         NO                        v
         |              [Backup data immediately]
         v              [Drive likely failing - replace]
[Check write protection]
         |
    Protected? --> YES --> [nvme set-feature to disable]
         |                          |
         NO                         v
         |              [If permanent, drive is bricked]
         v
[Check TCG Opal lock]
         |
    Locked? --> YES --> [Use sedutil to unlock]
         |                       |
         NO                      v
         |              [If password lost, PSID reset]
         v
[Check USB bridge]
         |
    Via USB? --> YES --> [Connect directly to M.2/PCIe]
         |                        |
         NO                       v
         |              [USB bridges block admin commands]
         v
[Try controller reset]
         |
         v
[Try format command]
         |
         v
[Try sanitize command]
         |
    Failed? --> YES --> [Check error code, firmware issue likely]
         |
         NO
         v
    [Success]
```

---

## 8. Specific nvme-cli Commands Reference

### 8.1 Information Gathering

```bash
# List all NVMe devices
nvme list

# Controller identification (capabilities, firmware version)
nvme id-ctrl /dev/nvme0

# Namespace identification
nvme id-ns /dev/nvme0 --namespace-id=1

# SMART/Health information
nvme smart-log /dev/nvme0

# Error log
nvme error-log /dev/nvme0 --log-entries=16

# Firmware slot information
nvme fw-log /dev/nvme0

# All supported log pages
nvme get-log /dev/nvme0 --log-id=0 --log-len=4096

# Effects log (what commands change)
nvme effects-log /dev/nvme0
```

### 8.2 Feature Management

```bash
# List all features
nvme get-feature /dev/nvme0 --feature-id=0 --sel=0

# Get specific feature
nvme get-feature /dev/nvme0 --feature-id=<id>

# Set feature (temporary)
nvme set-feature /dev/nvme0 --feature-id=<id> --value=<val>

# Set feature (persistent across power cycles)
nvme set-feature /dev/nvme0 --feature-id=<id> --value=<val> --save

# Common feature IDs:
# 0x01 - Arbitration
# 0x02 - Power Management
# 0x04 - Temperature Threshold
# 0x05 - Error Recovery
# 0x06 - Volatile Write Cache
# 0x84 - Write Protection Config
```

### 8.3 Format and Sanitize

```bash
# Format (WARNING: destroys data)
nvme format /dev/nvme0 --namespace-id=1 --ses=0  # No secure erase
nvme format /dev/nvme0 --namespace-id=1 --ses=1  # User data erase
nvme format /dev/nvme0 --namespace-id=1 --ses=2  # Crypto erase

# Format with specific LBA size
nvme format /dev/nvme0 --namespace-id=1 --lbaf=1  # Use LBA format 1

# Sanitize (WARNING: destroys all data including over-provisioning)
nvme sanitize /dev/nvme0 --sanact=1  # Exit failure mode
nvme sanitize /dev/nvme0 --sanact=2  # Block erase
nvme sanitize /dev/nvme0 --sanact=3  # Overwrite
nvme sanitize /dev/nvme0 --sanact=4  # Crypto erase

# Check sanitize progress
nvme sanitize-log /dev/nvme0
```

### 8.4 Namespace Management

```bash
# Create namespace
nvme create-ns /dev/nvme0 --nsze=1000000 --ncap=1000000 --flbas=0 --dps=0

# Attach namespace to controller 0
nvme attach-ns /dev/nvme0 --namespace-id=1 --controllers=0

# Detach namespace
nvme detach-ns /dev/nvme0 --namespace-id=1 --controllers=0

# Delete namespace
nvme delete-ns /dev/nvme0 --namespace-id=1

# List controllers
nvme list-ctrl /dev/nvme0
```

### 8.5 Security Commands

```bash
# Get security state (requires direct connection, not USB)
nvme security-recv /dev/nvme0 --secp=0 --spsp=0 --size=2048

# Security send (for TCG operations)
nvme security-send /dev/nvme0 --secp=<protocol> --spsp=<specific> --file=<data>
```

### 8.6 Controller Management

```bash
# Reset controller
nvme reset /dev/nvme0

# Subsystem reset
nvme subsystem-reset /dev/nvme0

# Device self-test (short)
nvme device-self-test /dev/nvme0 --namespace-id=1 --self-test-code=1

# Device self-test (extended)
nvme device-self-test /dev/nvme0 --namespace-id=1 --self-test-code=2

# Check self-test results
nvme self-test-log /dev/nvme0
```

---

## 9. Common Error Codes and Meanings

### 9.1 Status Code Types (SCT)

| SCT | Name | Description |
|-----|------|-------------|
| 0x0 | Generic | Generic command errors |
| 0x1 | Command Specific | Command-specific errors |
| 0x2 | Media/Data Integrity | Media and data errors |
| 0x3 | Path Related | Fabric/path errors |
| 0x7 | Vendor Specific | Vendor-defined errors |

### 9.2 Common Status Codes (SC)

| Error | SCT:SC | Meaning |
|-------|--------|---------|
| INVALID_OPCODE | 0:0x01 | Command not supported by controller |
| INVALID_FIELD | 0:0x02 | Invalid parameter in command |
| INVALID_NS | 1:0x0b | Namespace doesn't exist or is invalid |
| INVALID_FORMAT | 1:0x0a | LBA format not supported |
| WRITE_FAULT | 2:0x80 | Write operation failed |
| NS_WRITE_PROTECTED | 1:0x20 | Namespace is write protected |
| FORMAT_IN_PROGRESS | 1:0x10 | Format operation already in progress |

---

## 10. Sources and References

### Official Specifications
- [NVM Command Set Specification](https://nvmexpress.org/specification/nvm-command-set-specification/)
- [NVM Express Base Specification 2.0e](https://nvmexpress.org/wp-content/uploads/NVM-Express-Base-Specification-2.0e-2024.07.29-Ratified.pdf)
- [NVMe 1.4 Features Overview](https://nvmexpress.org/wp-content/uploads/October-2019-NVMe-1.4-Features-amd-Compliance-Everything-You-Need-to-Know.pdf)
- [TCG Storage and NVMe White Paper](https://nvmexpress.org/wp-content/uploads/TCGandNVMe_Joint_White_Paper-TCG_Storage_Opal_and_NVMe_FINAL.pdf)

### Tools and Documentation
- [nvme-cli GitHub Repository](https://github.com/linux-nvme/nvme-cli)
- [nvme-cli Man Pages](https://manpages.debian.org/testing/nvme-cli/nvme.1.en.html)
- [SEDutil - Self Encrypting Drive Utility](https://sedutil.com/)
- [Arch Wiki - NVMe](https://wiki.archlinux.org/title/Solid_state_drive/NVMe)
- [Arch Wiki - Memory Cell Clearing](https://wiki.archlinux.org/title/Solid_state_drive/Memory_cell_clearing)

### Technical Articles
- [NVMe Management, Error Reporting and Logging](https://nvmexpress.org/wp-content/uploads/June-2020-NVMe%E2%84%A2-SSD-Management-Error-Reporting-and-Logging-Capabilities.pdf)
- [AnandTech - NVMe 1.4 Features](https://www.anandtech.com/show/14543/nvme-14-specification-published/2)
- [NVMe Namespaces Overview](https://nvmexpress.org/resource/nvme-namespaces/)
- [Managing NVMe Namespaces](https://narasimhan-v.github.io/2020/06/12/Managing-NVMe-Namespaces.html)

### USB Bridge Information
- [JMicron JMS583 Datasheet](https://edit.wpgdadawant.com/uploads/news_file/blog/2020/997/tech_files/PDS-17001_JMS583_Datasheet_(Rev._1.0).pdf)
- [JMicron USB-PCIe Bridge Products](https://www.jmicron.com/products/list/13)
- [nvme-cli Issue #437 - SCSI Tunnelling](https://github.com/linux-nvme/nvme-cli/issues/437)
- [sedutil JMS583 Support PR](https://github.com/Drive-Trust-Alliance/sedutil/pull/315)

### Troubleshooting Resources
- [DiskTuna - Write Protected NVMe](https://www.disktuna.com/a-write-protected-ssd-nvme-read-only/)
- [tinyapps.org - NVMe Sanitize](https://tinyapps.org/docs/nvme-sanitize.html)
- [tinyapps.org - NVMe Secure Erase](https://tinyapps.org/docs/nvme-secure-erase.html)

---

*Document generated: 2026-01-21*
*For use with hiberpower-ntfs drive recovery investigation*
