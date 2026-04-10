#!/bin/bash
# VFIO passthrough instrumentation — logs interrupt rate + KVM exit stats
# every second to correlate with Mode 2 loading-screen stalls.
#
# Usage: sudo /usr/local/bin/vfio-instrument <vm-name>
# Stop: Ctrl+C
# Output: /var/log/overwatch/<vm>/vfio-instrument.csv
#
# The CSV has columns:
#   timestamp, irq_total, irq_delta, kvm_exits, kvm_mmio, kvm_pio,
#   kvm_irq_injections, kvm_halt, qemu_cpu_pct
#
# During steady-state gameplay, expect: low irq_delta, steady exits/sec.
# During a loading-screen stall, look for spikes in mmio, irq_injections,
# or drops in halt (indicating the vCPUs can't halt because they're busy).

set -euo pipefail

VM_NAME="${1:?Usage: vfio-instrument <vm-name>}"
LOG_DIR="/var/log/overwatch/${VM_NAME}"
LOG="${LOG_DIR}/vfio-instrument.csv"

mkdir -p "$LOG_DIR"

QEMU_PID=$(pgrep -f "qemu-system-x86_64.*-name.*${VM_NAME}" | head -1)
if [ -z "$QEMU_PID" ]; then
    echo "ERROR: QEMU process for ${VM_NAME} not found" >&2
    exit 1
fi

# Find the vfio MSI vector for the GPU (03:00.0)
IRQ_LINE=$(grep 'vfio-msi\[0\].*0000:03:00.0' /proc/interrupts | awk '{print $1}' | tr -d ':')
if [ -z "$IRQ_LINE" ]; then
    echo "WARNING: No vfio-msi IRQ found for 0000:03:00.0, interrupt tracking disabled" >&2
    IRQ_LINE="NONE"
fi

echo "$(date -Iseconds) vfio-instrument started: VM=${VM_NAME} PID=${QEMU_PID} IRQ=${IRQ_LINE} log=${LOG}" >&2
echo "timestamp,irq_total,irq_delta,kvm_exits,kvm_mmio,kvm_pio,kvm_irq_injections,kvm_halt,qemu_cpu_pct" > "$LOG"

PREV_IRQ=0

while kill -0 "$QEMU_PID" 2>/dev/null; do
    TS=$(date '+%H:%M:%S.%N' | cut -c1-12)

    # Interrupt count for vfio GPU vector
    if [ "$IRQ_LINE" != "NONE" ]; then
        IRQ_NOW=$(awk -v irq="${IRQ_LINE}:" '$1==irq {sum=0; for(i=2;i<=NF-3;i++) sum+=$i; print sum}' /proc/interrupts)
    else
        IRQ_NOW=0
    fi
    IRQ_DELTA=$((IRQ_NOW - PREV_IRQ))
    PREV_IRQ=$IRQ_NOW

    # KVM stats from debugfs
    EXITS=$(cat /sys/kernel/debug/kvm/exits 2>/dev/null || echo 0)
    MMIO=$(cat /sys/kernel/debug/kvm/mmio_exits 2>/dev/null || echo 0)
    PIO=$(cat /sys/kernel/debug/kvm/io_exits 2>/dev/null || echo 0)
    IRQ_INJ=$(cat /sys/kernel/debug/kvm/irq_injections 2>/dev/null || echo 0)
    HALT=$(cat /sys/kernel/debug/kvm/halt_exits 2>/dev/null || echo 0)

    # QEMU CPU usage
    CPU_PCT=$(ps -p "$QEMU_PID" -o %cpu= 2>/dev/null | tr -d ' ')

    echo "$TS,$IRQ_NOW,$IRQ_DELTA,$EXITS,$MMIO,$PIO,$IRQ_INJ,$HALT,${CPU_PCT:-0}" >> "$LOG"

    sleep 1
done

echo "$(date -Iseconds) vfio-instrument stopped: QEMU process ${QEMU_PID} exited" >&2
