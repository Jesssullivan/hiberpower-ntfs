# QEMU/qcow2 Test Environment for NVMe Corruption Reproduction

**Purpose**: Reproduce and analyze NVMe corruption caused by Windows hibernate/fast boot states.

**Created**: 2026-01-21

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [QEMU NVMe Device Emulation](#qemu-nvme-device-emulation)
3. [qcow2 Image Creation](#qcow2-image-creation)
4. [Windows VM Setup](#windows-vm-setup)
5. [Hibernate and Fast Boot Configuration](#hibernate-and-fast-boot-configuration)
6. [Capturing Drive State](#capturing-drive-state)
7. [Power Loss Simulation](#power-loss-simulation)
8. [USB Passthrough vs Emulated NVMe](#usb-passthrough-vs-emulated-nvme)
9. [Snapshotting for Reproducible Testing](#snapshotting-for-reproducible-testing)
10. [Automation Scripts](#automation-scripts)
11. [Disk State Comparison Tools](#disk-state-comparison-tools)

---

## Prerequisites

### Required Packages (Fedora/RHEL)

```bash
# QEMU and KVM
sudo dnf install qemu-kvm qemu-img libvirt virt-manager

# Additional tools
sudo dnf install nvme-cli blktrace swtpm swtpm-tools

# For Windows installation
sudo dnf install virtio-win
```

### Required Packages (Debian/Ubuntu)

```bash
sudo apt install qemu-kvm qemu-utils libvirt-daemon-system virt-manager
sudo apt install nvme-cli blktrace swtpm swtpm-tools
```

### Windows ISO

Download Windows 10/11 ISO from Microsoft:
- https://www.microsoft.com/software-download/windows10
- https://www.microsoft.com/software-download/windows11

### VirtIO Drivers

```bash
# Fedora - drivers are at /usr/share/virtio-win/
# Or download directly:
wget https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
```

---

## QEMU NVMe Device Emulation

### NVMe Controller Options

QEMU's NVMe emulation supports numerous options for realistic testing:

```bash
# Basic NVMe device options
-device nvme,drive=<drive_id>,serial=<serial>

# Full option set
-device nvme,\
    drive=nvme0,\
    serial=DEADBEEF12345678,\
    id=nvme0,\
    logical_block_size=512,\
    physical_block_size=4096,\
    mdts=7,\
    max_ioqpairs=4,\
    msix_qsize=32,\
    aerl=3,\
    aer_max_queued=64
```

### Key NVMe Parameters

| Parameter | Description | Default | Recommended for Testing |
|-----------|-------------|---------|------------------------|
| `serial` | NVMe serial number | Required | Custom string for identification |
| `mdts` | Max data transfer size (2^n * 4KB) | 7 | 7 (512KB) |
| `max_ioqpairs` | Max I/O queue pairs | 64 | 4-8 for debugging |
| `logical_block_size` | LBA size in bytes | 512 | 512 |
| `physical_block_size` | Physical sector size | 512 | 4096 (matches real NVMe) |
| `msix_qsize` | MSI-X queue size | 32 | 32 |
| `zoned` | Zoned namespace support | off | off |

### NVMe Namespace Options

```bash
# NVMe with separate namespace configuration
-device nvme,id=nvme-ctrl0,serial=HIBERTEST001
-device nvme-ns,drive=nvme0n1,bus=nvme-ctrl0,nsid=1,\
    logical_block_size=512,\
    physical_block_size=4096
```

---

## qcow2 Image Creation

### Directory Setup

```bash
mkdir -p /home/jsullivan2/git/hiberpower-ntfs/images/qcow2
cd /home/jsullivan2/git/hiberpower-ntfs/images/qcow2
```

### Create System Drive (for Windows OS)

```bash
# Windows system drive - 80GB, preallocation for consistent performance
qemu-img create -f qcow2 \
    -o preallocation=metadata,lazy_refcounts=on,cluster_size=65536 \
    windows-system.qcow2 80G
```

### Create Test NVMe Drive (simulates the corrupted drive)

```bash
# Test NVMe drive - 256GB to match real device
qemu-img create -f qcow2 \
    -o preallocation=metadata,lazy_refcounts=on,cluster_size=65536 \
    nvme-test-256g.qcow2 256G

# Create pristine baseline copy
cp nvme-test-256g.qcow2 nvme-test-256g-baseline.qcow2
```

### qcow2 Options Explained

| Option | Value | Purpose |
|--------|-------|---------|
| `preallocation=metadata` | Preallocate metadata | Faster writes, more consistent |
| `lazy_refcounts=on` | Defer refcount updates | Better crash consistency testing |
| `cluster_size=65536` | 64KB clusters | Better performance for large files |

### Creating Images That Simulate Corruption States

```bash
# Create image with specific NTFS state
# Step 1: Create base image
qemu-img create -f qcow2 nvme-hibernated.qcow2 256G

# Step 2: After Windows hibernates (captured state)
qemu-img create -f qcow2 \
    -b nvme-hibernated.qcow2 \
    -F qcow2 \
    nvme-hibernated-overlay.qcow2

# Step 3: Create "corrupted" variant for testing
qemu-img create -f qcow2 \
    -b nvme-hibernated.qcow2 \
    -F qcow2 \
    nvme-corruption-test.qcow2
```

---

## Windows VM Setup

### Complete QEMU Command Line

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/start-windows-vm.sh

IMAGES="/home/jsullivan2/git/hiberpower-ntfs/images/qcow2"
VIRTIO_ISO="/usr/share/virtio-win/virtio-win.iso"
# Or use downloaded: VIRTIO_ISO="$IMAGES/virtio-win.iso"

qemu-system-x86_64 \
    -name "HiberPower-NTFS-Test" \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -smp 4,sockets=1,cores=4,threads=1 \
    -m 8192 \
    \
    `# UEFI firmware for Windows 11 compatibility` \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=$IMAGES/OVMF_VARS.fd \
    \
    `# System drive (SATA/AHCI for OS)` \
    -device ahci,id=ahci0 \
    -drive file=$IMAGES/windows-system.qcow2,if=none,id=sata0,format=qcow2,cache=writeback \
    -device ide-hd,drive=sata0,bus=ahci0.0 \
    \
    `# NVMe test drive - the corruption target` \
    -drive file=$IMAGES/nvme-test-256g.qcow2,if=none,id=nvme0,format=qcow2,cache=none \
    -device nvme,drive=nvme0,serial=HIBERTEST256GB,id=nvme-test \
    \
    `# VirtIO drivers ISO` \
    -drive file=$VIRTIO_ISO,media=cdrom,readonly=on \
    \
    `# Network` \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389 \
    \
    `# Display` \
    -device qxl-vga,vgamem_mb=64 \
    -display gtk \
    \
    `# USB for input` \
    -device qemu-xhci,id=xhci \
    -device usb-tablet \
    \
    `# TPM 2.0 (required for Windows 11)` \
    -chardev socket,id=chrtpm,path=/tmp/swtpm-sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    \
    `# QMP monitor for scripting` \
    -qmp unix:/tmp/qmp-sock,server,nowait \
    \
    `# QEMU monitor` \
    -monitor stdio
```

### Setup UEFI Variables

```bash
# Copy OVMF variables template for the VM
cp /usr/share/edk2/ovmf/OVMF_VARS.fd $IMAGES/OVMF_VARS.fd
```

### Setup TPM Emulator (for Windows 11)

```bash
# Start swtpm before QEMU
mkdir -p /tmp/mytpm
swtpm socket --tpmstate dir=/tmp/mytpm \
    --ctrl type=unixio,path=/tmp/swtpm-sock \
    --tpm2 \
    --log level=20
```

### Minimal Command for Quick Testing

```bash
# Simplified command for initial testing
qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host \
    -smp 4 \
    -m 8192 \
    -drive file=windows-system.qcow2,if=virtio \
    -drive file=nvme-test-256g.qcow2,if=none,id=nvme0 \
    -device nvme,drive=nvme0,serial=HIBERTEST001 \
    -display gtk
```

---

## Hibernate and Fast Boot Configuration

### Windows Configuration via Registry

After Windows installation, configure hibernate and fast boot:

```powershell
# Enable Hibernate
powercfg /hibernate on

# Set hibernate file type (full vs reduced)
# Full = complete memory dump, better for testing
powercfg /h /type full

# Verify hibernate settings
powercfg /a
```

### Disable/Enable Fast Startup (for controlled testing)

```powershell
# Via PowerShell (Run as Administrator)

# Check current state
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled

# Disable Fast Startup
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -Value 0

# Enable Fast Startup
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -Value 1
```

### Configure NVMe Drive for Testing

```powershell
# Disable write caching on test NVMe (optional - for some tests)
# Disk Management > Right-click drive > Properties > Policies > Disable write caching

# Initialize and format the test NVMe
Get-Disk | Where-Object PartitionStyle -eq 'RAW'
Initialize-Disk -Number <disk_number> -PartitionStyle GPT
New-Partition -DiskNumber <disk_number> -UseMaximumSize -AssignDriveLetter
Format-Volume -DriveLetter <letter> -FileSystem NTFS -NewFileSystemLabel "TestNVMe"
```

### Create Test Data on NVMe

```powershell
# Create known data patterns for corruption detection
$testPath = "E:\TestData"  # Adjust drive letter
New-Item -ItemType Directory -Path $testPath -Force

# Create files with known content
1..100 | ForEach-Object {
    $content = "Test file $_" + ("`n" * 1000)
    $content | Out-File "$testPath\testfile_$_.txt"
}

# Create checksum file
Get-ChildItem $testPath -File | ForEach-Object {
    $hash = Get-FileHash $_.FullName -Algorithm SHA256
    "$($hash.Hash) $($_.Name)"
} | Out-File "$testPath\checksums.txt"
```

---

## Capturing Drive State

### Before Hibernation

```bash
# From QEMU monitor (Ctrl+Alt+2 or via QMP)

# Create snapshot before hibernate
(qemu) savevm pre-hibernate

# Or via QMP
echo '{"execute":"human-monitor-command","arguments":{"command-line":"savevm pre-hibernate"}}' | \
    socat - UNIX-CONNECT:/tmp/qmp-sock
```

### QEMU Monitor Commands for State Capture

```bash
# Connect to QMP socket
socat - UNIX-CONNECT:/tmp/qmp-sock

# Initialize QMP
{"execute": "qmp_capabilities"}

# Create snapshot
{"execute": "human-monitor-command", "arguments": {"command-line": "savevm hibernate-state-1"}}

# List snapshots
{"execute": "human-monitor-command", "arguments": {"command-line": "info snapshots"}}

# Load snapshot
{"execute": "human-monitor-command", "arguments": {"command-line": "loadvm hibernate-state-1"}}
```

### Export Raw NVMe State

```bash
# Convert qcow2 to raw for analysis
qemu-img convert -f qcow2 -O raw \
    nvme-test-256g.qcow2 \
    nvme-test-256g-state1.raw

# Create compressed backup
qemu-img convert -f qcow2 -O qcow2 -c \
    nvme-test-256g.qcow2 \
    nvme-test-256g-state1-compressed.qcow2
```

### Capture NTFS Metadata

```bash
# After shutting down VM or with snapshot
# Mount qcow2 using NBD

sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 nvme-test-256g.qcow2
sudo fdisk -l /dev/nbd0

# Mount read-only for analysis
sudo mkdir -p /mnt/nvme-analysis
sudo mount -o ro /dev/nbd0p1 /mnt/nvme-analysis

# Capture NTFS metadata
sudo ntfsinfo -m /dev/nbd0p1 > ntfs-metadata.txt
sudo ntfscluster -a /dev/nbd0p1 > ntfs-clusters.txt

# Unmount and disconnect
sudo umount /mnt/nvme-analysis
sudo qemu-nbd --disconnect /dev/nbd0
```

---

## Power Loss Simulation

### Method 1: QEMU Monitor Kill

```bash
# Abrupt termination (simulates power loss)
# From QEMU monitor:
(qemu) quit

# Or via QMP:
echo '{"execute":"quit"}' | socat - UNIX-CONNECT:/tmp/qmp-sock

# Or kill QEMU process
pkill -9 qemu-system-x86
```

### Method 2: Controlled Power Events

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/simulate-power-loss.sh

QMP_SOCK="/tmp/qmp-sock"

send_qmp() {
    echo "$1" | socat - UNIX-CONNECT:$QMP_SOCK
}

# Initialize QMP
send_qmp '{"execute":"qmp_capabilities"}'

# Create pre-power-loss snapshot
echo "Creating pre-power-loss snapshot..."
send_qmp '{"execute":"human-monitor-command","arguments":{"command-line":"savevm pre-power-loss"}}'

sleep 2

# Trigger Windows hibernate (send ACPI event)
echo "Sending ACPI power button (triggers hibernate)..."
send_qmp '{"execute":"system_powerdown"}'

# Wait for hibernate to start writing
sleep 5

# Simulate power loss during hibernate
echo "Simulating power loss NOW..."
send_qmp '{"execute":"quit"}'
```

### Method 3: Timed Power Loss During Write

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/timed-power-loss.sh

QMP_SOCK="/tmp/qmp-sock"
DELAY_SECONDS=${1:-3}  # Default 3 seconds

send_qmp() {
    echo "$1" | socat - UNIX-CONNECT:$QMP_SOCK 2>/dev/null
}

echo "Waiting $DELAY_SECONDS seconds before power loss..."
sleep $DELAY_SECONDS

echo "POWER LOSS NOW!"
send_qmp '{"execute":"quit"}'

# Alternative: SIGKILL the QEMU process
# pkill -9 qemu-system-x86
```

### Method 4: Inject I/O Errors

```bash
# QEMU supports blkdebug for I/O error injection
# Create blkdebug config file

cat > /tmp/blkdebug.conf << 'EOF'
[inject-error]
event = "write_aio"
errno = 5
once = off
immediately = off
sector = 1000
EOF

# Use blkdebug driver
qemu-system-x86_64 \
    ... \
    -drive driver=blkdebug,config=/tmp/blkdebug.conf,image.driver=qcow2,image.file.filename=nvme-test-256g.qcow2,if=none,id=nvme0 \
    -device nvme,drive=nvme0,serial=HIBERTEST001
```

---

## USB Passthrough vs Emulated NVMe

### USB Passthrough (Real Device Testing)

```bash
# Find USB device
lsusb
# Example output: Bus 001 Device 005: ID 0781:5588 SanDisk Corp. ...

# Passthrough USB device
qemu-system-x86_64 \
    ... \
    -device qemu-xhci,id=xhci \
    -device usb-host,vendorid=0x0781,productid=0x5588

# Or by bus/device number
    -device usb-host,hostbus=1,hostaddr=5
```

### USB-NVMe Bridge Emulation

```bash
# QEMU doesn't directly emulate USB-NVMe bridges
# Workaround: Use usb-storage with backing file

qemu-system-x86_64 \
    ... \
    -drive file=nvme-test-256g.qcow2,if=none,id=usbdisk0,format=qcow2 \
    -device qemu-xhci,id=xhci \
    -device usb-storage,drive=usbdisk0,removable=on
```

### Comparison

| Feature | Emulated NVMe | USB Passthrough | USB-Storage Emulation |
|---------|---------------|-----------------|----------------------|
| NVMe Commands | Full | Real hardware | None (SCSI) |
| USB Bridge Behavior | No | Yes | Partial |
| Snapshotting | Yes | No | Yes |
| Reproducibility | High | Low | Medium |
| Speed | Fast | Hardware | Medium |
| Corruption Simulation | Easy | Real | Easy |

### Recommendation for Testing

1. **Use emulated NVMe** for:
   - Initial reproduction attempts
   - Snapshotting and state capture
   - Controlled corruption testing

2. **Use USB passthrough** for:
   - Validating findings on real hardware
   - Testing actual USB-NVMe bridge behavior
   - Final verification

---

## Snapshotting for Reproducible Testing

### Snapshot Strategy

```
Baseline (Clean Windows + Formatted NVMe)
    |
    +-- Pre-Hibernate (Data written to NVMe)
    |       |
    |       +-- Hibernate-Complete (Normal shutdown)
    |       |
    |       +-- Hibernate-Interrupted (Power loss during hibernate)
    |       |
    |       +-- Post-Resume (After waking from hibernate)
    |
    +-- Corruption-Triggered (Specific state that causes issues)
```

### Creating Snapshot Chain

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/create-snapshot-chain.sh

IMAGES="/home/jsullivan2/git/hiberpower-ntfs/images/qcow2"
QMP_SOCK="/tmp/qmp-sock"

send_qmp() {
    echo "$1" | socat - UNIX-CONNECT:$QMP_SOCK
}

init_qmp() {
    send_qmp '{"execute":"qmp_capabilities"}'
}

create_snapshot() {
    local name="$1"
    local desc="$2"
    echo "Creating snapshot: $name - $desc"
    send_qmp "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"savevm $name\"}}"
    sleep 2
}

# Initialize
init_qmp

# Snapshot chain
create_snapshot "baseline" "Clean Windows installation with formatted NVMe"
echo "Press Enter after installing Windows and formatting NVMe..."
read

create_snapshot "data-written" "Test data written to NVMe"
echo "Press Enter after writing test data to NVMe..."
read

create_snapshot "pre-hibernate" "About to hibernate"
echo "Press Enter just before initiating hibernate..."
read

create_snapshot "post-hibernate" "After hibernate complete (VM stopped)"
echo "Hibernate now. Press Enter after VM stops..."
read
```

### External Snapshot Management

```bash
# Create external snapshot (keeps base image unchanged)
qemu-img create -f qcow2 \
    -b nvme-test-256g.qcow2 \
    -F qcow2 \
    nvme-test-256g-experiment1.qcow2

# Check snapshot info
qemu-img info nvme-test-256g-experiment1.qcow2

# Commit changes back to base (if desired)
qemu-img commit nvme-test-256g-experiment1.qcow2

# Rebase to different backing file
qemu-img rebase -b nvme-test-256g-baseline.qcow2 nvme-test-256g-experiment1.qcow2
```

### Snapshot Comparison

```bash
# Compare two snapshot states
qemu-img compare nvme-test-256g-state1.qcow2 nvme-test-256g-state2.qcow2

# Get differences in raw form
qemu-img convert -f qcow2 -O raw nvme-test-256g-state1.qcow2 state1.raw
qemu-img convert -f qcow2 -O raw nvme-test-256g-state2.qcow2 state2.raw
cmp -l state1.raw state2.raw | head -100
```

---

## Automation Scripts

### Master Test Script

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/run-hibernate-test.sh

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES="$PROJECT_DIR/images/qcow2"
LOGS="$PROJECT_DIR/data/logs"
QMP_SOCK="/tmp/qmp-sock-$$"
TPM_DIR="/tmp/swtpm-$$"

# Cleanup on exit
cleanup() {
    echo "Cleaning up..."
    [ -S "$QMP_SOCK" ] && rm -f "$QMP_SOCK"
    [ -d "$TPM_DIR" ] && rm -rf "$TPM_DIR"
    pkill -f "swtpm.*$TPM_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Create directories
mkdir -p "$LOGS" "$TPM_DIR"

# Start TPM emulator
echo "Starting TPM emulator..."
swtpm socket --tpmstate dir="$TPM_DIR" \
    --ctrl type=unixio,path="$TPM_DIR/swtpm-sock" \
    --tpm2 &
sleep 1

# QMP helper
send_qmp() {
    echo "$1" | timeout 5 socat - UNIX-CONNECT:"$QMP_SOCK" 2>/dev/null || true
}

# Start QEMU
start_vm() {
    local snapshot_name="${1:-}"
    local extra_args=""

    if [ -n "$snapshot_name" ]; then
        extra_args="-loadvm $snapshot_name"
    fi

    qemu-system-x86_64 \
        -name "HiberPower-Test" \
        -enable-kvm \
        -machine q35,accel=kvm \
        -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
        -smp 4 \
        -m 8192 \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file="$IMAGES/OVMF_VARS.fd" \
        -drive file="$IMAGES/windows-system.qcow2",if=none,id=sata0,format=qcow2 \
        -device ahci,id=ahci0 \
        -device ide-hd,drive=sata0,bus=ahci0.0 \
        -drive file="$IMAGES/nvme-test-256g.qcow2",if=none,id=nvme0,format=qcow2,cache=none \
        -device nvme,drive=nvme0,serial=HIBERTEST001 \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0 \
        -display none \
        -daemonize \
        -qmp unix:"$QMP_SOCK",server,nowait \
        -chardev socket,id=chrtpm,path="$TPM_DIR/swtpm-sock" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0 \
        $extra_args

    sleep 3
    send_qmp '{"execute":"qmp_capabilities"}'
}

# Test scenarios
run_test() {
    local test_name="$1"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="$LOGS/${test_name}_${timestamp}.log"

    echo "Running test: $test_name"
    echo "Log file: $log_file"

    {
        echo "=== Test: $test_name ==="
        echo "Timestamp: $(date)"
        echo ""

        case "$test_name" in
            "normal-hibernate")
                start_vm "data-written"
                echo "Sending ACPI power button..."
                send_qmp '{"execute":"system_powerdown"}'
                sleep 30  # Wait for hibernate
                ;;

            "interrupted-hibernate")
                start_vm "data-written"
                echo "Sending ACPI power button..."
                send_qmp '{"execute":"system_powerdown"}'
                sleep 5  # Interrupt during hibernate
                echo "Forcing quit..."
                send_qmp '{"execute":"quit"}'
                ;;

            "power-loss-writing")
                start_vm "data-written"
                sleep 10
                echo "Forcing quit during operation..."
                send_qmp '{"execute":"quit"}'
                ;;
        esac

        echo ""
        echo "Test complete: $(date)"
    } | tee "$log_file"
}

# Main
echo "HiberPower-NTFS Test Runner"
echo "=========================="

case "${1:-help}" in
    normal)
        run_test "normal-hibernate"
        ;;
    interrupted)
        run_test "interrupted-hibernate"
        ;;
    power-loss)
        run_test "power-loss-writing"
        ;;
    *)
        echo "Usage: $0 {normal|interrupted|power-loss}"
        exit 1
        ;;
esac
```

### Image Analysis Script

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/analyze-image.sh

set -euo pipefail

IMAGE="${1:?Usage: $0 <qcow2-image>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/data/dumps"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$OUTPUT_DIR"

echo "Analyzing: $IMAGE"
echo "Output directory: $OUTPUT_DIR"

# Connect via NBD
echo "Connecting image via NBD..."
sudo modprobe nbd max_part=16
NBD_DEV="/dev/nbd0"

# Ensure clean state
sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
sleep 1

sudo qemu-nbd --connect="$NBD_DEV" --read-only "$IMAGE"
sleep 2

# Partition info
echo "=== Partition Table ===" | tee "$OUTPUT_DIR/partition_${TIMESTAMP}.txt"
sudo fdisk -l "$NBD_DEV" | tee -a "$OUTPUT_DIR/partition_${TIMESTAMP}.txt"

# First 1MB (MBR/GPT area)
echo "=== First 1MB (hex dump) ==="
sudo dd if="$NBD_DEV" bs=1M count=1 2>/dev/null | xxd > "$OUTPUT_DIR/first_1mb_${TIMESTAMP}.hex"
echo "Saved to: $OUTPUT_DIR/first_1mb_${TIMESTAMP}.hex"

# For each partition
for part in ${NBD_DEV}p*; do
    if [ -b "$part" ]; then
        part_num=$(echo "$part" | grep -oP 'p\K\d+')
        echo "=== Partition $part_num ===" | tee -a "$OUTPUT_DIR/partition_${TIMESTAMP}.txt"

        # Try to identify filesystem
        sudo blkid "$part" | tee -a "$OUTPUT_DIR/partition_${TIMESTAMP}.txt"

        # NTFS specific analysis
        if sudo blkid "$part" | grep -q "ntfs"; then
            echo "Detected NTFS, running ntfsinfo..."
            sudo ntfsinfo -m "$part" > "$OUTPUT_DIR/ntfs_info_p${part_num}_${TIMESTAMP}.txt" 2>&1 || true

            # Check for hibernate flag
            echo "Checking NTFS hibernate flag..."
            sudo ntfs-3g.probe --readonly "$part" 2>&1 | tee -a "$OUTPUT_DIR/ntfs_hibernate_${TIMESTAMP}.txt" || true
        fi
    fi
done

# Disconnect
sudo qemu-nbd --disconnect "$NBD_DEV"

echo ""
echo "Analysis complete. Files saved to: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"/*_${TIMESTAMP}*
```

### Batch Testing Script

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/batch-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES="$PROJECT_DIR/images/qcow2"
RESULTS="$PROJECT_DIR/data/logs/batch_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$RESULTS"

echo "Batch Test Suite for HiberPower-NTFS"
echo "====================================="
echo "Results directory: $RESULTS"

# Test matrix
declare -A TESTS=(
    ["baseline"]="Clean state verification"
    ["hibernate-normal"]="Normal hibernate cycle"
    ["hibernate-fast-boot"]="With fast boot enabled"
    ["hibernate-interrupted-early"]="Power loss 2s into hibernate"
    ["hibernate-interrupted-mid"]="Power loss 5s into hibernate"
    ["hibernate-interrupted-late"]="Power loss 10s into hibernate"
    ["resume-interrupted"]="Power loss during resume"
)

# Run each test
for test_name in "${!TESTS[@]}"; do
    desc="${TESTS[$test_name]}"
    echo ""
    echo "Test: $test_name - $desc"
    echo "----------------------------------------"

    # Create fresh overlay for this test
    test_image="$IMAGES/test-${test_name}.qcow2"
    qemu-img create -f qcow2 -b "$IMAGES/nvme-test-256g-baseline.qcow2" -F qcow2 "$test_image"

    # Run test (implement based on test type)
    # ...

    # Analyze result
    "$SCRIPT_DIR/analyze-image.sh" "$test_image" > "$RESULTS/${test_name}.log" 2>&1

    echo "Complete. Log: $RESULTS/${test_name}.log"
done

echo ""
echo "Batch testing complete!"
echo "Results in: $RESULTS"
```

---

## Disk State Comparison Tools

### Binary Diff Script

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/compare-states.sh

set -euo pipefail

IMAGE1="${1:?Usage: $0 <image1.qcow2> <image2.qcow2>}"
IMAGE2="${2:?Usage: $0 <image1.qcow2> <image2.qcow2>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/data/dumps/compare_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUTPUT_DIR"

echo "Comparing disk states:"
echo "  Image 1: $IMAGE1"
echo "  Image 2: $IMAGE2"
echo "  Output:  $OUTPUT_DIR"
echo ""

# Method 1: qemu-img compare
echo "=== QEMU Image Comparison ==="
qemu-img compare "$IMAGE1" "$IMAGE2" && echo "Images are identical" || echo "Images differ"

# Method 2: Convert to raw and compare
echo ""
echo "=== Converting to raw for detailed comparison ==="
RAW1="$OUTPUT_DIR/image1.raw"
RAW2="$OUTPUT_DIR/image2.raw"

echo "Converting image 1..."
qemu-img convert -f qcow2 -O raw "$IMAGE1" "$RAW1"

echo "Converting image 2..."
qemu-img convert -f qcow2 -O raw "$IMAGE2" "$RAW2"

# Checksum comparison
echo ""
echo "=== Checksums ==="
echo "Image 1: $(sha256sum "$RAW1" | cut -d' ' -f1)"
echo "Image 2: $(sha256sum "$RAW2" | cut -d' ' -f1)"

# Find differing sectors
echo ""
echo "=== Finding differing sectors ==="
cmp -l "$RAW1" "$RAW2" 2>/dev/null | head -1000 > "$OUTPUT_DIR/byte_diffs.txt" || true

if [ -s "$OUTPUT_DIR/byte_diffs.txt" ]; then
    echo "First differing byte: $(head -1 "$OUTPUT_DIR/byte_diffs.txt" | awk '{print $1}')"
    echo "Total differing bytes: $(wc -l < "$OUTPUT_DIR/byte_diffs.txt")"

    # Extract first differing region
    first_diff=$(head -1 "$OUTPUT_DIR/byte_diffs.txt" | awk '{print $1}')
    sector=$((first_diff / 512))
    echo ""
    echo "First differing sector: $sector"
    echo "Hex dump of first difference (image 1):"
    dd if="$RAW1" bs=512 skip=$sector count=1 2>/dev/null | xxd | head -20
    echo ""
    echo "Hex dump of first difference (image 2):"
    dd if="$RAW2" bs=512 skip=$sector count=1 2>/dev/null | xxd | head -20
else
    echo "No differences found at byte level"
fi

# Cleanup (optional - comment out to keep raw files)
# rm -f "$RAW1" "$RAW2"

echo ""
echo "Comparison complete. Results in: $OUTPUT_DIR"
```

### NTFS Hibernate Flag Checker

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/check-ntfs-hibernate.sh

set -euo pipefail

IMAGE="${1:?Usage: $0 <qcow2-image>}"

echo "Checking NTFS hibernate/dirty flags in: $IMAGE"
echo ""

# Connect via NBD
sudo modprobe nbd max_part=16
sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
sudo qemu-nbd --connect=/dev/nbd0 --read-only "$IMAGE"
sleep 2

# Find NTFS partitions
for part in /dev/nbd0p*; do
    if [ -b "$part" ]; then
        fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null || true)
        if [ "$fs_type" = "ntfs" ]; then
            echo "=== $part (NTFS) ==="

            # Check hibernate flag using ntfs-3g.probe
            echo "Hibernate status:"
            sudo ntfs-3g.probe --readonly "$part" 2>&1 || true

            # Alternative: check $Volume flags directly
            echo ""
            echo "Attempting to read \$Volume metadata:"
            sudo ntfsinfo -f "\$Volume" "$part" 2>&1 | head -30 || true

            # Check for hiberfil.sys
            echo ""
            echo "Checking for hiberfil.sys:"
            sudo ntfs-3g -o ro "$part" /mnt 2>/dev/null && {
                if [ -f /mnt/hiberfil.sys ]; then
                    echo "  Found: hiberfil.sys ($(stat -c%s /mnt/hiberfil.sys) bytes)"
                else
                    echo "  Not found"
                fi
                sudo umount /mnt
            } || echo "  Could not mount to check"

            echo ""
        fi
    fi
done

# Disconnect
sudo qemu-nbd --disconnect /dev/nbd0

echo "Check complete."
```

### Sector Hash Comparison

```bash
#!/bin/bash
# File: /home/jsullivan2/git/hiberpower-ntfs/scripts/sector-hash-compare.sh

set -euo pipefail

IMAGE1="${1:?Usage: $0 <image1> <image2> [sector_size] [max_sectors]}"
IMAGE2="${2:?Usage: $0 <image1> <image2> [sector_size] [max_sectors]}"
SECTOR_SIZE="${3:-4096}"
MAX_SECTORS="${4:-1000000}"

echo "Comparing sector hashes"
echo "  Sector size: $SECTOR_SIZE bytes"
echo "  Max sectors: $MAX_SECTORS"
echo ""

# Connect both images via NBD
sudo modprobe nbd max_part=1

sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
sudo qemu-nbd --disconnect /dev/nbd1 2>/dev/null || true

sudo qemu-nbd --connect=/dev/nbd0 --read-only "$IMAGE1"
sudo qemu-nbd --connect=/dev/nbd1 --read-only "$IMAGE2"
sleep 2

# Compare sector by sector
diff_count=0
for i in $(seq 0 $MAX_SECTORS); do
    hash1=$(sudo dd if=/dev/nbd0 bs=$SECTOR_SIZE skip=$i count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
    hash2=$(sudo dd if=/dev/nbd1 bs=$SECTOR_SIZE skip=$i count=1 2>/dev/null | sha256sum | cut -d' ' -f1)

    if [ "$hash1" != "$hash2" ]; then
        echo "Sector $i differs"
        ((diff_count++))

        if [ $diff_count -gt 100 ]; then
            echo "... (more than 100 differences, stopping)"
            break
        fi
    fi

    # Progress every 10000 sectors
    if [ $((i % 10000)) -eq 0 ] && [ $i -gt 0 ]; then
        echo "Progress: checked $i sectors, $diff_count differences found"
    fi
done

# Cleanup
sudo qemu-nbd --disconnect /dev/nbd0
sudo qemu-nbd --disconnect /dev/nbd1

echo ""
echo "Comparison complete: $diff_count differing sectors found"
```

---

## Appendix: QEMU Command Reference

### Quick Reference: QEMU NVMe Options

```
-device nvme Options:
    drive=<id>              Block device ID (required)
    serial=<string>         NVMe serial number (required)
    id=<string>             Device ID for QEMU
    mdts=<n>                Max data transfer size: 2^n * 4KB (default: 7 = 512KB)
    max_ioqpairs=<n>        Max I/O queue pairs (default: 64)
    msix_qsize=<n>          MSI-X queue size (default: 32)
    aerl=<n>                Async event request limit (default: 3)
    aer_max_queued=<n>      Max queued async events (default: 64)
    logical_block_size=<n>  LBA size in bytes (default: 512)
    physical_block_size=<n> Physical sector size (default: 512)
    zoned=<bool>            Enable zoned namespace (default: off)
    zoned.zasl=<n>          Zone append size limit
```

### Quick Reference: qcow2 Options

```
qemu-img create -f qcow2 Options:
    -o preallocation=off|metadata|falloc|full
    -o lazy_refcounts=on|off
    -o cluster_size=<bytes>     (512 to 2M, default 65536)
    -o backing_file=<file>
    -o backing_fmt=<format>
    -o compat=0.10|1.1
    -o encryption=on|off
```

### Quick Reference: QMP Commands

```json
// Capabilities handshake (required first)
{"execute": "qmp_capabilities"}

// VM control
{"execute": "quit"}
{"execute": "stop"}
{"execute": "cont"}
{"execute": "system_reset"}
{"execute": "system_powerdown"}

// Snapshots (via human monitor)
{"execute": "human-monitor-command", "arguments": {"command-line": "savevm <name>"}}
{"execute": "human-monitor-command", "arguments": {"command-line": "loadvm <name>"}}
{"execute": "human-monitor-command", "arguments": {"command-line": "delvm <name>"}}
{"execute": "human-monitor-command", "arguments": {"command-line": "info snapshots"}}

// Block device info
{"execute": "query-block"}
{"execute": "query-blockstats"}
```

---

## Troubleshooting

### Common Issues

**1. KVM permission denied**
```bash
sudo usermod -aG kvm $USER
# Log out and back in
```

**2. OVMF not found**
```bash
# Fedora
sudo dnf install edk2-ovmf

# Ubuntu
sudo apt install ovmf
```

**3. NBD module not loaded**
```bash
sudo modprobe nbd max_part=16
# Make persistent:
echo "nbd max_part=16" | sudo tee /etc/modules-load.d/nbd.conf
```

**4. NTFS mount fails with "Windows is hibernated"**
```bash
# This is expected! It means we successfully triggered the hibernate state
# Use read-only mount or remove hibernate flag:
sudo ntfs-3g -o remove_hiberfile /dev/nbd0p1 /mnt  # DESTRUCTIVE
```

**5. QEMU hangs on start**
```bash
# Check KVM support
lsmod | grep kvm
cat /proc/cpuinfo | grep vmx  # Intel
cat /proc/cpuinfo | grep svm  # AMD
```

---

## References

- [QEMU NVMe Emulation Documentation](https://www.qemu.org/docs/master/system/devices/nvme.html)
- [QEMU qcow2 Format](https://www.qemu.org/docs/master/interop/qcow2.html)
- [QEMU Monitor Commands](https://www.qemu.org/docs/master/system/monitor.html)
- [QEMU Machine Protocol (QMP)](https://www.qemu.org/docs/master/interop/qmp-intro.html)
- [Windows Power Management](https://docs.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby)
- [NTFS-3G Documentation](https://www.tuxera.com/community/ntfs-3g-manual/)
