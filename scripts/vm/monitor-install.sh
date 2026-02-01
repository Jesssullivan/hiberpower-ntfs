#!/bin/bash
# Monitor Windows VM installation progress
# Usage: ./scripts/monitor-install.sh

echo "Monitoring Windows unattended installation..."
echo "VM credentials: Admin / hiberpower"
echo ""
echo "Checking every 30 seconds for RDP availability (indicates Windows is ready)"
echo "Press Ctrl+C to stop monitoring"
echo ""

START_TIME=$(date +%s)

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    MINUTES=$((ELAPSED / 60))
    SECONDS=$((ELAPSED % 60))

    # Check if QEMU is still running
    if ! pgrep -f "qemu-kvm.*HiberPower" > /dev/null; then
        echo ""
        echo "[${MINUTES}m ${SECONDS}s] QEMU process not found - VM may have crashed or been stopped"
        exit 1
    fi

    # Check if RDP is actually responding (not just port forwarding)
    if python3 "$(dirname "$0")/check-rdp.py" localhost 3389 2>/dev/null; then
        echo ""
        echo "[${MINUTES}m ${SECONDS}s] SUCCESS: RDP port 3389 is responding!"
        echo "Windows installation appears complete."
        echo ""
        echo "Next steps:"
        echo "  1. Stop this VM: pkill -f 'qemu-kvm.*HiberPower'"
        echo "  2. Start with USB passthrough: ./scripts/start-frida-vm.sh run"
        echo "  3. Connect via RDP: xfreerdp /v:localhost:3389 /u:Admin /p:hiberpower"
        exit 0
    fi

    # Progress indicator
    printf "\r[%dm %02ds] Waiting for Windows installation... (VM running, RDP not yet available)" "$MINUTES" "$SECONDS"

    sleep 30
done
