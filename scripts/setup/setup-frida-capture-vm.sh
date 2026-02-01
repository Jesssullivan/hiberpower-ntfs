#!/bin/bash
# Setup script for Windows VM with Frida SP Toolbox capture
# Run this to prepare the VM environment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES="$PROJECT_DIR/images/qcow2"

echo "=============================================="
echo "  Frida Capture VM Setup"
echo "=============================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."

check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "  [MISSING] $1"
        return 1
    else
        echo "  [OK] $1"
        return 0
    fi
}

MISSING=0
check_cmd qemu-system-x86_64 || MISSING=1
check_cmd qemu-img || MISSING=1
check_cmd virsh || MISSING=1

if [ $MISSING -eq 1 ]; then
    echo ""
    echo "Install missing packages:"
    echo "  sudo dnf install qemu-kvm qemu-img libvirt virt-manager virtio-win"
    echo ""
fi

# Check OVMF
if [ -f /usr/share/edk2/ovmf/OVMF_CODE.fd ]; then
    echo "  [OK] OVMF UEFI firmware"
else
    echo "  [MISSING] OVMF - install edk2-ovmf"
    MISSING=1
fi

# Check virtio-win
if [ -f /usr/share/virtio-win/virtio-win.iso ]; then
    echo "  [OK] VirtIO drivers"
    VIRTIO_ISO="/usr/share/virtio-win/virtio-win.iso"
else
    echo "  [MISSING] virtio-win - install virtio-win package"
    echo "           Or download: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    VIRTIO_ISO=""
fi

echo ""

# Check for Windows ISO
WIN_ISO=""
for iso in ~/Downloads/Win*.iso /tmp/Win*.iso "$PROJECT_DIR"/*.iso; do
    if [ -f "$iso" ]; then
        WIN_ISO="$iso"
        echo "Found Windows ISO: $WIN_ISO"
        break
    fi
done

if [ -z "$WIN_ISO" ]; then
    echo "No Windows ISO found."
    echo "Download from: https://www.microsoft.com/software-download/windows10"
    echo "Place in ~/Downloads/ or $PROJECT_DIR/"
    echo ""
fi

# Create images directory
mkdir -p "$IMAGES"

# Check ASM2362 device
echo ""
echo "Checking ASM2362 USB device..."
ASM_DEV=$(lsusb | grep "174c:2362" || true)
if [ -n "$ASM_DEV" ]; then
    echo "  [OK] Found: $ASM_DEV"
    USB_BUS=$(echo "$ASM_DEV" | grep -oP 'Bus \K\d+')
    USB_DEV=$(echo "$ASM_DEV" | grep -oP 'Device \K\d+')
    echo "  USB Bus: $USB_BUS, Device: $USB_DEV"
else
    echo "  [WARNING] ASM2362 not found - connect the USB drive"
fi

echo ""
echo "=============================================="
echo "  Setup Commands"
echo "=============================================="
echo ""

# Create VM disk if needed
if [ ! -f "$IMAGES/windows-frida.qcow2" ]; then
    echo "# Create Windows VM disk (60GB):"
    echo "qemu-img create -f qcow2 -o preallocation=metadata $IMAGES/windows-frida.qcow2 60G"
    echo ""
fi

# Copy OVMF vars
if [ ! -f "$IMAGES/OVMF_VARS.fd" ]; then
    echo "# Copy UEFI variables:"
    echo "cp /usr/share/edk2/ovmf/OVMF_VARS.fd $IMAGES/OVMF_VARS.fd"
    echo ""
fi

echo "# Start VM for Windows installation:"
cat << 'INSTALLCMD'
qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -smp 4 \
    -m 8192 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=IMAGES/OVMF_VARS.fd \
    -drive file=IMAGES/windows-frida.qcow2,if=virtio \
    -cdrom /path/to/Windows.iso \
    -drive file=/usr/share/virtio-win/virtio-win.iso,media=cdrom \
    -device qemu-xhci,id=xhci \
    -device usb-tablet \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=tcp::5555-:5555 \
    -display gtk

INSTALLCMD

echo ""
echo "Replace IMAGES with: $IMAGES"
echo "Replace /path/to/Windows.iso with your Windows ISO path"
echo ""

echo "# After Windows is installed, start with USB passthrough:"
cat << 'USBCMD'
qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -smp 4 \
    -m 8192 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=IMAGES/OVMF_VARS.fd \
    -drive file=IMAGES/windows-frida.qcow2,if=virtio \
    -device qemu-xhci,id=xhci \
    -device usb-host,vendorid=0x174c,productid=0x2362 \
    -device usb-tablet \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=tcp::5555-:5555 \
    -display gtk

USBCMD

echo ""
echo "=============================================="
echo "  In Windows VM - Install These:"
echo "=============================================="
echo ""
echo "1. Python 3.x from python.org"
echo "2. pip install frida frida-tools"
echo "3. SP Toolbox from Silicon Power website"
echo ""
echo "4. Copy these files to Windows VM (via shared folder or network):"
echo "   - $PROJECT_DIR/src/frida/hooks.js"
echo "   - $PROJECT_DIR/src/frida/capture.py"
echo ""
echo "5. Run capture:"
echo '   python capture.py spawn "C:\Program Files\SP Toolbox\SPToolbox.exe"'
echo ""
