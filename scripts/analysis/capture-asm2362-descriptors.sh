#!/bin/bash
# Capture a read-only ASM2362 descriptor/config bundle on Linux.
# Purpose: standardize the artifact set needed to compare degraded vs healthy
# transport states for the same enclosure/firmware path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/data/captures/asm2362-descriptor-$TIMESTAMP}"
VIDPID="${VIDPID:-174c:2362}"
DEVICE="${1:-}"

mkdir -p "$OUTPUT_DIR"

TOOL=""
if [ -x "$PROJECT_DIR/zig-out/bin/asm2362-tool" ]; then
    TOOL="$PROJECT_DIR/zig-out/bin/asm2362-tool"
elif command -v asm2362-tool >/dev/null 2>&1; then
    TOOL="$(command -v asm2362-tool)"
fi

run_capture() {
    local name="$1"
    shift
    local file="$OUTPUT_DIR/$name.txt"

    {
        printf '$'
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf '\n'
        "$@"
    } >"$file" 2>&1 || true
}

maybe_capture() {
    local probe="$1"
    shift
    local name="$1"
    if command -v "$probe" >/dev/null 2>&1; then
        run_capture "$@"
    else
        printf 'missing command: %s\n' "$probe" >"$OUTPUT_DIR/$name.txt"
    fi
}

{
    echo "ASM2362 Descriptor Bundle"
    echo "timestamp=$TIMESTAMP"
    echo "vidpid=$VIDPID"
    if [ -n "$DEVICE" ]; then
        echo "device=$DEVICE"
    fi
    if [ -n "$TOOL" ]; then
        echo "tool=$TOOL"
    else
        echo "tool=missing"
    fi
} >"$OUTPUT_DIR/manifest.txt"

echo "=== ASM2362 Descriptor Bundle ==="
echo "Output: $OUTPUT_DIR"
echo "VID:PID: $VIDPID"
if [ -n "$DEVICE" ]; then
    echo "Block device: $DEVICE"
fi
echo ""

maybe_capture lsusb lsusb lsusb
maybe_capture lsusb lsusb_tree lsusb -t
maybe_capture lsusb lsusb_verbose lsusb -v -d "$VIDPID"
maybe_capture usb-devices usb_devices usb-devices

if [ -n "$DEVICE" ]; then
    maybe_capture lsblk lsblk lsblk -o NAME,SIZE,MODEL,TRAN,VENDOR,SERIAL "$DEVICE"
    maybe_capture udevadm udevadm udevadm info --query=all --name "$DEVICE"
    maybe_capture smartctl smartctl_info smartctl -d sntasmedia -i "$DEVICE"
fi

if [ -n "$TOOL" ] && [ -n "$DEVICE" ]; then
    run_capture asm_probe "$TOOL" probe "$DEVICE"
    run_capture asm_config_image0 "$TOOL" config-read "$DEVICE" --image=0
    run_capture asm_config_image1 "$TOOL" config-read "$DEVICE" --image=1
fi

echo "Bundle complete."
echo ""
echo "Key files:"
echo "  $OUTPUT_DIR/lsusb_tree.txt"
echo "  $OUTPUT_DIR/lsusb_verbose.txt"
if [ -n "$DEVICE" ]; then
    echo "  $OUTPUT_DIR/asm_config_image0.txt"
    echo "  $OUTPUT_DIR/asm_config_image1.txt"
fi
