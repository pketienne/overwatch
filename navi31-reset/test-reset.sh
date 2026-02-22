#!/bin/bash
# test-reset.sh — Test the navi31_reset kernel module
#
# This script stops services holding GPU resources, unbinds the GPU from
# amdgpu, performs a MODE1 or BACO reset, rebinds amdgpu, and restarts
# services. Run from SSH — display will go dark during reset.
#
# Usage:
#   sudo ./test-reset.sh [mode1|baco]
#
# Prerequisites:
#   - navi31_reset.ko loaded (insmod navi31_reset.ko)
#   - /dev/navi31-reset exists
#   - Run from SSH (display will temporarily go dark)
#
set -euo pipefail

METHOD="${1:-mode1}"
GPU_PCI="0000:03:00.0"
AUDIO_PCI="0000:03:00.1"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

if [[ ! -e /dev/navi31-reset ]]; then
    echo "ERROR: /dev/navi31-reset not found — load navi31_reset.ko first" >&2
    exit 1
fi

echo "=== Navi 31 Reset Test ==="
echo "Method: $METHOD"
echo "GPU: $GPU_PCI"
echo ""

# Pre-reset status
echo "--- Pre-reset status ---"
cat /dev/navi31-reset
echo "GPU driver: $(basename "$(readlink /sys/bus/pci/devices/$GPU_PCI/driver 2>/dev/null)" 2>/dev/null || echo 'none')"
echo ""

# Stop services that hold GPU I2C/DRM handles
echo "--- Stopping services ---"
OPENRGB_WAS_RUNNING=false
GDM_WAS_RUNNING=false

if systemctl is-active --quiet openrgb 2>/dev/null || pgrep -x openrgb >/dev/null 2>&1; then
    OPENRGB_WAS_RUNNING=true
    systemctl stop openrgb 2>/dev/null || killall openrgb 2>/dev/null || true
    echo "  Stopped OpenRGB (holds I2C/DP-AUX adapters)"
    sleep 1
fi

if systemctl is-active --quiet gdm 2>/dev/null; then
    GDM_WAS_RUNNING=true
    systemctl stop gdm 2>/dev/null || true
    echo "  Stopped GDM (holds DRM card fds)"
    sleep 1
fi

# Verify no DRM consumers remain on our GPU
CARD_NUM=""
for card in /sys/class/drm/card*/; do
    slot=$(cat "$card/device/uevent" 2>/dev/null | grep PCI_SLOT_NAME | cut -d= -f2)
    if [[ "$slot" == "$GPU_PCI" ]]; then
        CARD_NUM=$(basename "$card")
        break
    fi
done

if [[ -n "$CARD_NUM" ]]; then
    USERS=$(lsof "/dev/dri/$CARD_NUM" 2>/dev/null | tail -n +2 || true)
    if [[ -n "$USERS" ]]; then
        echo "  WARNING: processes still using /dev/dri/$CARD_NUM:"
        echo "$USERS" | head -5
    fi
fi
echo ""

# Unbind amdgpu from GPU and audio
echo "--- Unbinding drivers ---"
if [[ -e /sys/bus/pci/devices/$AUDIO_PCI/driver ]]; then
    echo "$AUDIO_PCI" > "/sys/bus/pci/devices/$AUDIO_PCI/driver/unbind" 2>/dev/null || true
    echo "  Unbound audio"
fi
if [[ -e /sys/bus/pci/devices/$GPU_PCI/driver ]]; then
    echo "$GPU_PCI" > "/sys/bus/pci/devices/$GPU_PCI/driver/unbind" 2>/dev/null || true
    echo "  Unbound GPU"
fi
sleep 1

echo "GPU driver: $(basename "$(readlink /sys/bus/pci/devices/$GPU_PCI/driver 2>/dev/null)" 2>/dev/null || echo 'none')"
echo ""

# Perform reset
echo "--- Performing $METHOD reset ---"
START=$(date +%s%N)
echo "$METHOD" > /dev/navi31-reset
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))
echo "  Reset completed in ${ELAPSED}ms"
echo ""

# Post-reset status
echo "--- Post-reset status ---"
cat /dev/navi31-reset
echo ""

# Rebind amdgpu
echo "--- Rebinding amdgpu ---"
echo "$GPU_PCI" > /sys/bus/pci/drivers/amdgpu/bind 2>/dev/null || echo "  WARNING: amdgpu bind failed"
sleep 3
echo "$AUDIO_PCI" > /sys/bus/pci/drivers/snd_hda_intel/bind 2>/dev/null || echo "  (audio bind skipped)"
echo ""

# Restart services
echo "--- Restarting services ---"
if $GDM_WAS_RUNNING; then
    systemctl start gdm 2>/dev/null || true
    echo "  Started GDM"
fi
if $OPENRGB_WAS_RUNNING; then
    systemctl start openrgb 2>/dev/null || true
    echo "  Started OpenRGB"
fi
echo ""

# Final status
echo "--- Final status ---"
cat /dev/navi31-reset
echo "GPU driver: $(basename "$(readlink /sys/bus/pci/devices/$GPU_PCI/driver 2>/dev/null)" 2>/dev/null || echo 'none')"
echo ""
echo "Check dmesg for details: dmesg | grep -E 'navi31_reset|amdgpu' | tail -20"
