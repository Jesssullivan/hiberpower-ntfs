#!/bin/bash
# HiberPower-NTFS: Windows VM Launcher
# Purpose: Start Windows VM with NVMe emulation for hibernate testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES="$PROJECT_DIR/images/qcow2"
QMP_SOCK="/tmp/qmp-hiberpower-$$"
TPM_DIR="/tmp/swtpm-hiberpower-$$"

# Configuration
VIRTIO_ISO="${VIRTIO_ISO:-/usr/share/virtio-win/virtio-win.iso}"
WINDOWS_ISO="${WINDOWS_ISO:-}"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}"
RAM_MB="${RAM_MB:-8192}"
CPUS="${CPUS:-4}"
DISPLAY_TYPE="${DISPLAY_TYPE:-gtk}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -i, --install           Install mode (attach Windows ISO)
    -s, --snapshot NAME     Load snapshot NAME
    -n, --new-nvme          Create fresh NVMe test image
    -d, --display TYPE      Display type: gtk, sdl, none, vnc (default: gtk)
    -h, --help              Show this help

Environment Variables:
    WINDOWS_ISO     Path to Windows ISO (required for install mode)
    VIRTIO_ISO      Path to VirtIO drivers ISO
    OVMF_CODE       Path to OVMF firmware
    RAM_MB          RAM in megabytes (default: 8192)
    CPUS            Number of CPUs (default: 4)

Examples:
    $0                           # Normal start
    $0 -i                        # Install Windows
    $0 -s pre-hibernate          # Load snapshot
    $0 -n                        # Fresh NVMe image
    $0 -d vnc                    # VNC display (for headless)
EOF
    exit 0
}

# Parse arguments
INSTALL_MODE=false
SNAPSHOT=""
NEW_NVME=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--install) INSTALL_MODE=true; shift ;;
        -s|--snapshot) SNAPSHOT="$2"; shift 2 ;;
        -n|--new-nvme) NEW_NVME=true; shift ;;
        -d|--display) DISPLAY_TYPE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

# Cleanup function
cleanup() {
    log "Cleaning up..."
    [ -d "$TPM_DIR" ] && rm -rf "$TPM_DIR"
    pkill -f "swtpm.*$TPM_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Verify prerequisites
check_prereqs() {
    log "Checking prerequisites..."

    # KVM support
    if [ ! -e /dev/kvm ]; then
        error "KVM not available. Check virtualization is enabled in BIOS."
        exit 1
    fi

    # OVMF firmware
    if [ ! -f "$OVMF_CODE" ]; then
        error "OVMF firmware not found at: $OVMF_CODE"
        echo "Install with: sudo dnf install edk2-ovmf (Fedora) or sudo apt install ovmf (Ubuntu)"
        exit 1
    fi

    # Images directory
    if [ ! -d "$IMAGES" ]; then
        log "Creating images directory..."
        mkdir -p "$IMAGES"
    fi

    # OVMF_VARS copy
    if [ ! -f "$IMAGES/OVMF_VARS.fd" ]; then
        log "Creating OVMF_VARS copy..."
        cp /usr/share/edk2/ovmf/OVMF_VARS.fd "$IMAGES/OVMF_VARS.fd" 2>/dev/null || \
        cp /usr/share/OVMF/OVMF_VARS.fd "$IMAGES/OVMF_VARS.fd" 2>/dev/null || \
        { error "Cannot find OVMF_VARS.fd"; exit 1; }
    fi

    # System disk
    if [ ! -f "$IMAGES/windows-system.qcow2" ]; then
        if [ "$INSTALL_MODE" = true ]; then
            log "Creating Windows system disk (80GB)..."
            qemu-img create -f qcow2 \
                -o preallocation=metadata,lazy_refcounts=on \
                "$IMAGES/windows-system.qcow2" 80G
        else
            error "Windows system disk not found. Run with -i to install."
            exit 1
        fi
    fi

    # NVMe test disk
    if [ ! -f "$IMAGES/nvme-test-256g.qcow2" ] || [ "$NEW_NVME" = true ]; then
        log "Creating NVMe test disk (256GB)..."
        qemu-img create -f qcow2 \
            -o preallocation=metadata,lazy_refcounts=on,cluster_size=65536 \
            "$IMAGES/nvme-test-256g.qcow2" 256G
    fi

    # Windows ISO for install
    if [ "$INSTALL_MODE" = true ] && [ ! -f "$WINDOWS_ISO" ]; then
        error "Windows ISO not found. Set WINDOWS_ISO environment variable."
        exit 1
    fi
}

# Start TPM emulator
start_tpm() {
    log "Starting TPM emulator..."
    mkdir -p "$TPM_DIR"

    swtpm socket \
        --tpmstate dir="$TPM_DIR" \
        --ctrl type=unixio,path="$TPM_DIR/swtpm-sock" \
        --tpm2 \
        --log level=1 &

    sleep 1

    if [ ! -S "$TPM_DIR/swtpm-sock" ]; then
        warn "TPM emulator may not have started correctly"
    fi
}

# Build QEMU command
build_qemu_cmd() {
    local cmd=(
        qemu-system-x86_64
        -name "HiberPower-NTFS-Test"
        -enable-kvm
        -machine "q35,accel=kvm"
        -cpu "host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time"
        -smp "$CPUS,sockets=1,cores=$CPUS,threads=1"
        -m "$RAM_MB"

        # UEFI firmware
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$IMAGES/OVMF_VARS.fd"

        # System drive (AHCI/SATA)
        -device "ahci,id=ahci0"
        -drive "file=$IMAGES/windows-system.qcow2,if=none,id=sata0,format=qcow2,cache=writeback"
        -device "ide-hd,drive=sata0,bus=ahci0.0"

        # NVMe test drive
        -drive "file=$IMAGES/nvme-test-256g.qcow2,if=none,id=nvme0,format=qcow2,cache=none"
        -device "nvme,drive=nvme0,serial=HIBERTEST256GB,id=nvme-test"

        # Network
        -device "virtio-net-pci,netdev=net0"
        -netdev "user,id=net0,hostfwd=tcp::3389-:3389"

        # USB
        -device "qemu-xhci,id=xhci"
        -device "usb-tablet"

        # TPM 2.0
        -chardev "socket,id=chrtpm,path=$TPM_DIR/swtpm-sock"
        -tpmdev "emulator,id=tpm0,chardev=chrtpm"
        -device "tpm-tis,tpmdev=tpm0"

        # QMP socket for scripting
        -qmp "unix:$QMP_SOCK,server,nowait"

        # Monitor
        -monitor stdio
    )

    # Display
    case "$DISPLAY_TYPE" in
        none)
            cmd+=(-display none)
            ;;
        vnc)
            cmd+=(-display vnc=:0)
            log "VNC available at :5900"
            ;;
        *)
            cmd+=(-device "qxl-vga,vgamem_mb=64" -display "$DISPLAY_TYPE")
            ;;
    esac

    # Install mode: attach ISOs
    if [ "$INSTALL_MODE" = true ]; then
        cmd+=(-drive "file=$WINDOWS_ISO,media=cdrom,readonly=on")
        [ -f "$VIRTIO_ISO" ] && cmd+=(-drive "file=$VIRTIO_ISO,media=cdrom,readonly=on")
        cmd+=(-boot "d")
    else
        [ -f "$VIRTIO_ISO" ] && cmd+=(-drive "file=$VIRTIO_ISO,media=cdrom,readonly=on")
    fi

    # Load snapshot if specified
    if [ -n "$SNAPSHOT" ]; then
        cmd+=(-loadvm "$SNAPSHOT")
    fi

    echo "${cmd[@]}"
}

# Main
main() {
    log "HiberPower-NTFS Windows VM Launcher"
    log "===================================="

    check_prereqs
    start_tpm

    log "QMP socket: $QMP_SOCK"
    log "Display: $DISPLAY_TYPE"
    [ "$INSTALL_MODE" = true ] && log "Mode: INSTALL"
    [ -n "$SNAPSHOT" ] && log "Loading snapshot: $SNAPSHOT"

    echo ""
    log "Starting QEMU..."
    echo ""

    eval "$(build_qemu_cmd)"
}

main "$@"
