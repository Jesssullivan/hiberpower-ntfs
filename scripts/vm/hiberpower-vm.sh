#!/bin/bash
# HiberPower VM Management Script
# Unified management for headless Windows 10 VM for Frida SP Toolbox capture
#
# Usage:
#   ./scripts/hiberpower-vm.sh setup       - Create disk and floppy image
#   ./scripts/hiberpower-vm.sh install     - Start Windows installation
#   ./scripts/hiberpower-vm.sh start       - Normal boot (post-install)
#   ./scripts/hiberpower-vm.sh novnc       - Start web VNC proxy
#   ./scripts/hiberpower-vm.sh usb-attach  - Reattach ASM2362 USB device
#   ./scripts/hiberpower-vm.sh snapshot    - Create VM snapshot
#   ./scripts/hiberpower-vm.sh status      - Show VM status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$PROJECT_DIR/images"
QCOW2_DIR="$IMAGES_DIR/qcow2"

# QEMU binary (Rocky Linux / RHEL)
QEMU="/usr/libexec/qemu-kvm"

# Configuration
VM_NAME="HiberPower-Frida"
VM_DISK="$QCOW2_DIR/windows-frida.qcow2"
VM_DISK_SIZE="64G"
OVMF_CODE="/usr/share/edk2/ovmf/OVMF_CODE.fd"
OVMF_VARS_TEMPLATE="/usr/share/edk2/ovmf/OVMF_VARS.fd"
OVMF_VARS="$QCOW2_DIR/OVMF_VARS.fd"
VIRTIO_ISO="/usr/share/virtio-win/virtio-win.iso"
AUTOUNATTEND_XML="$IMAGES_DIR/autounattend.xml"
AUTOUNATTEND_FLP="$IMAGES_DIR/autounattend.flp"

# VNC ports
VNC_PORT=5900
NOVNC_PORT=6080

# ASM2362 USB device
ASM2362_VENDOR="0x174c"
ASM2362_PRODUCT="0x2362"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_deps() {
    local missing=()

    if [ ! -x "$QEMU" ]; then
        missing+=("qemu-kvm")
    fi

    if [ ! -f "$OVMF_CODE" ]; then
        missing+=("edk2-ovmf")
    fi

    if [ ! -f "$VIRTIO_ISO" ]; then
        missing+=("virtio-win")
    fi

    if ! command -v mcopy &>/dev/null; then
        missing+=("mtools")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        echo "Install with: sudo dnf install ${missing[*]}"
        exit 1
    fi
}

create_floppy_image() {
    log_info "Creating floppy image with autounattend.xml..."

    if [ ! -f "$AUTOUNATTEND_XML" ]; then
        log_error "autounattend.xml not found at $AUTOUNATTEND_XML"
        exit 1
    fi

    # Create blank floppy image (1.44MB)
    dd if=/dev/zero of="$AUTOUNATTEND_FLP" bs=1024 count=1440 status=none

    # Format as MS-DOS filesystem
    mkfs.msdos -n UNATTEND "$AUTOUNATTEND_FLP" >/dev/null

    # Copy autounattend.xml to floppy using mtools (no root required)
    mcopy -i "$AUTOUNATTEND_FLP" "$AUTOUNATTEND_XML" ::/autounattend.xml

    log_success "Floppy image created: $AUTOUNATTEND_FLP"

    # Verify contents
    log_info "Floppy contents:"
    mdir -i "$AUTOUNATTEND_FLP" ::
}

cmd_setup() {
    log_info "Setting up HiberPower VM infrastructure..."
    echo ""

    check_deps

    # Create directories
    mkdir -p "$QCOW2_DIR"

    # Create VM disk if needed
    if [ ! -f "$VM_DISK" ]; then
        log_info "Creating VM disk ($VM_DISK_SIZE)..."
        qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE"
        log_success "VM disk created: $VM_DISK"
    else
        log_info "VM disk already exists: $VM_DISK"
    fi

    # Create UEFI vars copy
    if [ ! -f "$OVMF_VARS" ]; then
        log_info "Copying OVMF UEFI variables..."
        cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
        log_success "OVMF vars created: $OVMF_VARS"
    fi

    # Create floppy image with autounattend.xml
    create_floppy_image

    echo ""
    log_success "Setup complete!"
    echo ""
    echo "Drive letter mapping during Windows installation:"
    echo "  A: = Floppy (autounattend.xml)"
    echo "  D: = VirtIO drivers ISO"
    echo "  E: = Windows 10 ISO"
    echo "  C: = VirtIO disk (will be created)"
    echo ""
    echo "Next steps:"
    echo "  1. Ensure you have Windows 10 ISO at: $IMAGES_DIR/Win10.iso"
    echo "  2. Start installation: $0 install"
    echo "  3. Monitor via noVNC: $0 novnc"
}

cmd_install() {
    log_info "Starting Windows 10 installation..."
    echo ""

    # Check for Windows ISO
    WIN_ISO="${WIN_ISO:-$IMAGES_DIR/Win10.iso}"
    if [ ! -f "$WIN_ISO" ]; then
        log_error "Windows ISO not found: $WIN_ISO"
        echo "Specify with: WIN_ISO=/path/to/Windows.iso $0 install"
        exit 1
    fi

    # Check other required files
    if [ ! -f "$VM_DISK" ]; then
        log_error "VM disk not found. Run '$0 setup' first."
        exit 1
    fi

    if [ ! -f "$AUTOUNATTEND_FLP" ]; then
        log_warn "Floppy image not found. Creating..."
        create_floppy_image
    fi

    # Reset OVMF vars for clean UEFI state
    log_info "Resetting UEFI variables for fresh install..."
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"

    echo ""
    log_info "Configuration:"
    echo "  Windows ISO:    $WIN_ISO"
    echo "  VirtIO ISO:     $VIRTIO_ISO"
    echo "  Floppy image:   $AUTOUNATTEND_FLP"
    echo "  VM disk:        $VM_DISK"
    echo ""
    echo "UNATTENDED INSTALLATION"
    echo "  User: Admin"
    echo "  Password: hiberpower"
    echo ""
    echo "VNC available at: localhost:$VNC_PORT"
    echo "For web access, run in another terminal: $0 novnc"
    echo ""
    log_info "Starting QEMU..."

    # Start VM with:
    # - Floppy (A:) with autounattend.xml
    # - VirtIO ISO first CD-ROM (D:)
    # - Windows ISO second CD-ROM (E:)
    $QEMU \
        -name "$VM_NAME-Install" \
        -enable-kvm \
        -machine q35,accel=kvm \
        -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
        -smp 4 \
        -m 8192 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$VM_DISK",if=virtio,format=qcow2 \
        -fda "$AUTOUNATTEND_FLP" \
        -drive file="$VIRTIO_ISO",media=cdrom,index=0 \
        -drive file="$WIN_ISO",media=cdrom,index=1 \
        -device qemu-xhci,id=xhci \
        -device usb-tablet \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::3389-:3389 \
        -device virtio-vga \
        -vnc :0 \
        -monitor tcp:127.0.0.1:4444,server,nowait \
        -boot menu=on
}

cmd_start() {
    log_info "Starting Windows 10 VM..."
    echo ""

    if [ ! -f "$VM_DISK" ]; then
        log_error "VM disk not found. Run '$0 setup' and '$0 install' first."
        exit 1
    fi

    # Check for ASM2362
    local usb_args=""
    if lsusb 2>/dev/null | grep -q "174c:2362"; then
        log_success "ASM2362 device detected - USB passthrough enabled"
        usb_args="-device usb-host,vendorid=$ASM2362_VENDOR,productid=$ASM2362_PRODUCT"

        if [ "$EUID" -ne 0 ]; then
            log_warn "USB passthrough may require root. Run with sudo if it fails."
        fi
    else
        log_warn "ASM2362 device not detected. USB passthrough disabled."
        echo "Connect the device and use '$0 usb-attach' to add it later."
    fi

    echo ""
    echo "VNC available at: localhost:$VNC_PORT"
    echo "For web access, run in another terminal: $0 novnc"
    echo "QEMU monitor available at: telnet localhost 4444"
    echo ""
    log_info "Starting QEMU..."

    $QEMU \
        -name "$VM_NAME-Capture" \
        -enable-kvm \
        -machine q35,accel=kvm \
        -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
        -smp 4 \
        -m 8192 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$VM_DISK",if=virtio,format=qcow2 \
        -device qemu-xhci,id=xhci \
        $usb_args \
        -device usb-tablet \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=tcp::8080-:8080 \
        -device virtio-vga \
        -vnc :0 \
        -monitor tcp:127.0.0.1:4444,server,nowait
}

cmd_novnc() {
    log_info "Starting noVNC web proxy..."

    # Check for websockify
    if ! command -v websockify &>/dev/null; then
        log_error "websockify not found"
        echo "Install with: sudo dnf install python3-websockify"
        exit 1
    fi

    # Find noVNC web files
    local novnc_web=""
    for path in /usr/share/novnc /usr/share/noVNC /usr/share/webapps/novnc; do
        if [ -d "$path" ]; then
            novnc_web="$path"
            break
        fi
    done

    if [ -z "$novnc_web" ]; then
        log_warn "noVNC web files not found, running websockify only"
        echo "Install with: sudo dnf install novnc"
        echo ""
        echo "Starting websockify proxy (WebSocket only, no HTML client)..."
        echo "Connect with a VNC client to: ws://localhost:$NOVNC_PORT"
        websockify $NOVNC_PORT localhost:$VNC_PORT
    else
        echo ""
        echo "noVNC web interface starting at:"
        echo "  http://localhost:$NOVNC_PORT/vnc.html"
        echo ""
        echo "Press Ctrl+C to stop"
        echo ""
        websockify --web="$novnc_web" $NOVNC_PORT localhost:$VNC_PORT
    fi
}

cmd_usb_attach() {
    log_info "Attaching ASM2362 USB device..."

    if ! lsusb 2>/dev/null | grep -q "174c:2362"; then
        log_error "ASM2362 device not detected!"
        echo "Connect the USB-NVMe bridge and try again."
        exit 1
    fi

    # Send device_add command to QEMU monitor
    if ! nc -z localhost 4444 2>/dev/null; then
        log_error "QEMU monitor not accessible on port 4444"
        echo "Is the VM running?"
        exit 1
    fi

    echo "device_add usb-host,vendorid=$ASM2362_VENDOR,productid=$ASM2362_PRODUCT,id=asm2362" | nc localhost 4444

    log_success "USB device attach command sent"
    echo "Check VM to verify device is recognized"
}

cmd_snapshot() {
    local name="${1:-$(date +%Y%m%d-%H%M%S)}"

    log_info "Creating snapshot: $name"

    if [ ! -f "$VM_DISK" ]; then
        log_error "VM disk not found"
        exit 1
    fi

    qemu-img snapshot -c "$name" "$VM_DISK"
    log_success "Snapshot '$name' created"

    echo ""
    log_info "Available snapshots:"
    qemu-img snapshot -l "$VM_DISK"
}

cmd_status() {
    echo "HiberPower VM Status"
    echo "===================="
    echo ""

    # Check QEMU process
    if pgrep -f "qemu.*$VM_NAME" &>/dev/null; then
        log_success "VM is running"
    else
        log_info "VM is not running"
    fi

    # Check VNC port
    if nc -z localhost $VNC_PORT 2>/dev/null; then
        log_success "VNC available on port $VNC_PORT"
    else
        log_info "VNC not available"
    fi

    # Check noVNC
    if nc -z localhost $NOVNC_PORT 2>/dev/null; then
        log_success "noVNC available at http://localhost:$NOVNC_PORT/vnc.html"
    else
        log_info "noVNC not running"
    fi

    # Check ASM2362
    echo ""
    if lsusb 2>/dev/null | grep -q "174c:2362"; then
        log_success "ASM2362 device detected on host"
        lsusb | grep "174c:2362"
    else
        log_warn "ASM2362 device not detected on host"
    fi

    # Show disk info
    echo ""
    if [ -f "$VM_DISK" ]; then
        log_info "VM disk: $VM_DISK"
        qemu-img info "$VM_DISK" 2>/dev/null | grep -E "^(virtual size|disk size|Snapshot)"
    fi
}

usage() {
    echo "HiberPower VM Management Script"
    echo ""
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  setup         Create VM disk and floppy image"
    echo "  install       Start Windows installation (requires Windows ISO)"
    echo "  start         Start VM for normal operation"
    echo "  novnc         Start web-based VNC proxy"
    echo "  usb-attach    Attach ASM2362 USB device to running VM"
    echo "  snapshot [n]  Create VM snapshot (optional name)"
    echo "  status        Show VM and device status"
    echo ""
    echo "Environment variables:"
    echo "  WIN_ISO       Path to Windows 10 ISO (default: images/Win10.iso)"
    echo ""
    echo "Quick start:"
    echo "  1. $0 setup"
    echo "  2. $0 install        # Start installation"
    echo "  3. $0 novnc          # (in another terminal) Web VNC access"
    echo "  4. $0 start          # After install complete"
}

# Main entry point
case "${1:-}" in
    setup)
        cmd_setup
        ;;
    install)
        cmd_install
        ;;
    start)
        cmd_start
        ;;
    novnc)
        cmd_novnc
        ;;
    usb-attach|usb)
        cmd_usb_attach
        ;;
    snapshot|snap)
        shift
        cmd_snapshot "$@"
        ;;
    status)
        cmd_status
        ;;
    *)
        usage
        exit 1
        ;;
esac
