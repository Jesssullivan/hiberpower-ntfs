#!/bin/bash
# Start Windows VM for Frida SP Toolbox capture
# Usage: ./scripts/start-frida-vm.sh [install|run]
#
# NOTE: Consider using ./scripts/hiberpower-vm.sh for unified management
#
# Drive letter mapping during Windows installation:
#   A: = Floppy (autounattend.xml)
#   D: = VirtIO drivers ISO (first CD-ROM)
#   E: = Windows 10 ISO (second CD-ROM)
#   C: = VirtIO disk (created during install)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES="$PROJECT_DIR/images/qcow2"

# QEMU binary location (Rocky Linux / RHEL)
QEMU="/usr/libexec/qemu-kvm"

# VirtIO ISO location
VIRTIO_ISO="/usr/share/virtio-win/virtio-win.iso"

# Floppy image with autounattend.xml
AUTOUNATTEND_FLP="$PROJECT_DIR/images/autounattend.flp"

# Check QEMU exists
if [ ! -x "$QEMU" ]; then
    echo "Error: QEMU not found at $QEMU"
    exit 1
fi

MODE="${1:-run}"

case "$MODE" in
    install)
        echo "Starting VM in INSTALL mode (with Windows ISO)"
        echo ""

        # Check for Windows ISO
        WIN_ISO="${WIN_ISO:-$PROJECT_DIR/images/Win10.iso}"
        if [ ! -f "$WIN_ISO" ]; then
            echo "Windows ISO not found: $WIN_ISO"
            echo "Specify with: WIN_ISO=/path/to/Windows.iso $0 install"
            exit 1
        fi

        # Check for floppy image
        if [ ! -f "$AUTOUNATTEND_FLP" ]; then
            echo "Floppy image not found: $AUTOUNATTEND_FLP"
            echo "Run './scripts/hiberpower-vm.sh setup' to create it"
            exit 1
        fi

        echo "Configuration:"
        echo "  Windows ISO:    $WIN_ISO"
        echo "  VirtIO ISO:     $VIRTIO_ISO (D:)"
        echo "  Floppy image:   $AUTOUNATTEND_FLP (A:)"
        echo ""
        echo "UNATTENDED INSTALLATION - Windows will install automatically"
        echo "User: Admin / Password: hiberpower"
        echo ""
        echo "VNC server will run on port 5900 (for monitoring)"
        echo "Connect with: vncviewer localhost:5900"
        echo "Or start noVNC: ./scripts/start-novnc.sh"
        echo ""

        # Reset OVMF_VARS for clean UEFI state
        cp /usr/share/edk2/ovmf/OVMF_VARS.fd "$IMAGES/OVMF_VARS.fd"

        # Start VM with:
        # - Floppy (A:) with autounattend.xml
        # - VirtIO ISO as first CD-ROM (D:)
        # - Windows ISO as second CD-ROM (E:)
        $QEMU \
            -name "HiberPower-Frida-Install" \
            -enable-kvm \
            -machine q35,accel=kvm \
            -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
            -smp 4 \
            -m 8192 \
            -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
            -drive if=pflash,format=raw,file="$IMAGES/OVMF_VARS.fd" \
            -drive file="$IMAGES/windows-frida.qcow2",if=virtio,format=qcow2 \
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
        ;;

    run)
        echo "Starting VM in RUN mode (with USB passthrough)"
        echo ""

        # Check ASM2362 is connected
        USB_ARGS=""
        if ! lsusb | grep -q "174c:2362"; then
            echo "WARNING: ASM2362 USB device not detected!"
            echo "USB passthrough disabled. Use QEMU monitor to add device later."
            echo ""
        else
            echo "ASM2362 device detected - USB passthrough enabled"
            USB_ARGS="-device usb-host,vendorid=0x174c,productid=0x2362"

            # Note: USB passthrough requires root
            if [ "$EUID" -ne 0 ]; then
                echo "Note: USB passthrough may require root. Try with sudo if it fails."
            fi
        fi

        echo ""
        echo "VNC server will run on port 5900"
        echo "Connect with: vncviewer localhost:5900"
        echo "Or start noVNC: ./scripts/start-novnc.sh"
        echo "QEMU monitor: telnet localhost 4444"
        echo ""

        $QEMU \
            -name "HiberPower-Frida-Capture" \
            -enable-kvm \
            -machine q35,accel=kvm \
            -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
            -smp 4 \
            -m 8192 \
            -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
            -drive if=pflash,format=raw,file="$IMAGES/OVMF_VARS.fd" \
            -drive file="$IMAGES/windows-frida.qcow2",if=virtio,format=qcow2 \
            -device qemu-xhci,id=xhci \
            $USB_ARGS \
            -device usb-tablet \
            -device virtio-net-pci,netdev=net0 \
            -netdev user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=tcp::8080-:8080 \
            -device virtio-vga \
            -vnc :0 \
            -monitor tcp:127.0.0.1:4444,server,nowait
        ;;

    *)
        echo "Usage: $0 [install|run]"
        echo ""
        echo "NOTE: Consider using ./scripts/hiberpower-vm.sh for unified management"
        echo ""
        echo "  install - Start VM with Windows ISO for initial installation"
        echo "            Default: images/Win10.iso or set WIN_ISO=/path/to/Windows.iso"
        echo ""
        echo "  run     - Start VM with USB passthrough for capture"
        echo "            Optional: ASM2362 device connected (may need sudo)"
        echo ""
        exit 1
        ;;
esac
