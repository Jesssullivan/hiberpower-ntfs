#!/bin/bash
# Run Wine application in headless mode using Xvfb inside Podman container
# Usage: ./scripts/run-wine-headless.sh [exe_path] [args...]
#
# NOTE: USB passthrough is NOT available in container mode.
# For SP Toolbox to communicate with the ASM2362 device, use
# the Windows VM approach with QEMU USB passthrough instead.

set -e

CONTAINER_IMAGE="docker.io/scottyhardy/docker-wine:latest"
WINE_PREFIX="/home/wineuser/.wine"

# Default to notepad as a test if no exe specified
EXE_PATH="${1:-notepad}"
shift 2>/dev/null || true
EXE_ARGS="$@"

# Check if we have a local file to mount
HOST_FILE=""
CONTAINER_FILE=""
MOUNT_OPT=""

if [[ "$EXE_PATH" == /* ]] || [[ "$EXE_PATH" == ./* ]]; then
    # Local file path - need to mount it
    HOST_FILE="$(realpath "$EXE_PATH" 2>/dev/null || echo "")"
    if [[ -f "$HOST_FILE" ]]; then
        BASENAME=$(basename "$HOST_FILE")
        CONTAINER_FILE="/tmp/app/$BASENAME"
        MOUNT_OPT="-v $HOST_FILE:$CONTAINER_FILE:ro"
        EXE_PATH="$CONTAINER_FILE"
        echo "[*] Mounting $HOST_FILE to $CONTAINER_FILE"
    fi
fi

# Persistent wine prefix directory
WINE_DATA_DIR="${HOME}/.cache/wine-headless"
mkdir -p "$WINE_DATA_DIR"

echo "[*] Starting Wine in headless mode (Xvfb)"
echo "[*] Container: $CONTAINER_IMAGE"
echo "[*] Executable: $EXE_PATH $EXE_ARGS"
echo ""

# Run with Xvfb
podman run --rm \
    -v "$WINE_DATA_DIR:$WINE_PREFIX" \
    $MOUNT_OPT \
    "$CONTAINER_IMAGE" \
    bash -c "
        # Start Xvfb in background
        Xvfb :99 -screen 0 1024x768x16 &
        XVFB_PID=\$!
        sleep 2

        export DISPLAY=:99

        # Run Wine
        wine '$EXE_PATH' $EXE_ARGS
        EXIT_CODE=\$?

        # Cleanup
        kill \$XVFB_PID 2>/dev/null || true
        exit \$EXIT_CODE
    "

echo ""
echo "[*] Wine session complete"
