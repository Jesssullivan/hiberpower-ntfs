#!/bin/bash
# Start noVNC web proxy for headless VM access
#
# This script starts a WebSocket proxy that allows browser-based VNC access
# to the HiberPower Windows VM.
#
# Usage: ./scripts/start-novnc.sh [vnc_port] [web_port]
#
# Defaults:
#   VNC port:  5900 (QEMU VNC server)
#   Web port:  6080 (noVNC web interface)
#
# Access: http://localhost:6080/vnc.html

set -e

VNC_PORT="${1:-5900}"
WEB_PORT="${2:-6080}"

# Check for websockify
if ! command -v websockify &>/dev/null; then
    echo "Error: websockify not found"
    echo ""
    echo "Install with:"
    echo "  sudo dnf install python3-websockify"
    echo ""
    exit 1
fi

# Find noVNC web files
NOVNC_WEB=""
for path in /usr/share/novnc /usr/share/noVNC /usr/share/webapps/novnc; do
    if [ -d "$path" ]; then
        NOVNC_WEB="$path"
        break
    fi
done

if [ -z "$NOVNC_WEB" ]; then
    echo "Warning: noVNC web files not found"
    echo ""
    echo "Install with:"
    echo "  sudo dnf install novnc"
    echo ""
    echo "Starting websockify in proxy-only mode..."
    echo "You can connect with a WebSocket-capable VNC client to: ws://localhost:$WEB_PORT"
    echo ""
    echo "Press Ctrl+C to stop"
    websockify $WEB_PORT localhost:$VNC_PORT
else
    echo "Starting noVNC web interface..."
    echo ""
    echo "Access in browser: http://localhost:$WEB_PORT/vnc.html"
    echo ""
    echo "Proxying localhost:$VNC_PORT -> localhost:$WEB_PORT"
    echo "Press Ctrl+C to stop"
    echo ""
    websockify --web="$NOVNC_WEB" $WEB_PORT localhost:$VNC_PORT
fi
