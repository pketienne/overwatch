# Plan: VFIO Performance Optimizations (1, 2, 3, 5)

## Context

The current CPU isolation uses systemd `AllowedCPUs` (cgroup-level) and runtime IRQ
affinity writes. This leaves several gaps: kernel threads and managed PCIe interrupts
can still land on vCPU cores 2-7, the periodic 250Hz timer tick fires on those cores
regardless, and QEMU's vCPU threads compete with normal-priority host processes without
real-time scheduling priority. Deep CPU C-states introduce wakeup latency when vCPUs
yield briefly. These are the remaining sources of vCPU scheduling jitter after the
RAM/hugepages fix.

Host: AMD Ryzen 7 9800X3D (8 cores, single CCD, no SMT, single NUMA node).
- Cores 0-1: host + QEMU emulator/IO (HOST_CPUS)
- Cores 2-7: VM vCPU threads (pinned via cputune)

---

## Changes

### 1. GRUB: kernel-level CPU isolation (requires host reboot)

**File:** `/etc/default/grub` on myhost

Add to `GRUB_CMDLINE_LINUX_DEFAULT`:
```
isolcpus=domain,managed_irq,2-7 nohz_full=2-7 rcu_nocbs=2-7
```

Full line becomes:
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on iommu=pt hugepages=24576 isolcpus=domain,managed_irq,2-7 nohz_full=2-7 rcu_nocbs=2-7"
```

- `isolcpus=domain,managed_irq,2-7`: removes cores 2-7 from scheduler load balancing
  and prevents managed PCIe interrupts from landing there (complements existing
  runtime smp_affinity_list writes which don't cover managed IRQs)
- `nohz_full=2-7`: disables the 250Hz periodic timer tick on vCPU cores when only one
  task is running — eliminates 4ms periodic interruptions to the vCPU threads
- `rcu_nocbs=2-7`: required companion to nohz_full; moves RCU callbacks off those cores
  to a dedicated kthread (RCU callbacks otherwise need the tick to process)

After editing: `sudo update-grub`, then reboot.

---

### 2. `ensure_performance_tuning()`: add C-state cap for vCPU cores

**File:** `scripts/host/overwatch.sh` (~line 380)

Add after the governor loop, before the IRQ section:

```bash
    # Cap vCPU cores at C1 — prevent deep C-state entry to reduce wakeup latency
    # state0=POLL, state1=C1 kept; state2+ (C2, C6, etc.) disabled
    for cpu in $(seq 2 7); do
        for state in /sys/devices/system/cpu/cpu${cpu}/cpuidle/state[2-9]/; do
            [ -f "${state}disable" ] && echo 1 > "${state}disable" 2>/dev/null || true
        done
    done
```

Also add at the end of the function:
```bash
    # Disable scheduler autogroup — prevents TTY-based throughput grouping for QEMU
    echo 0 > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || true
```

---

### 3. `ensure_cpu_defaults()`: restore C-states and autogroup on VM stop

**File:** `scripts/host/overwatch.sh` (~line 747)

Add before the governor restore loop:

```bash
    # Re-enable deep C-states on vCPU cores
    for cpu in $(seq 2 7); do
        for state in /sys/devices/system/cpu/cpu${cpu}/cpuidle/state[2-9]/; do
            [ -f "${state}disable" ] && echo 0 > "${state}disable" 2>/dev/null || true
        done
    done
```

Add at the end of the function:
```bash
    echo 1 > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || true
```

---

### 4. New `apply_sched_fifo()` function + call in `_do_start()`

**File:** `scripts/host/overwatch.sh` — add new function after `apply_cpu_isolation()`

```bash
apply_sched_fifo() {
    local qemu_pid count=0
    qemu_pid=$(pgrep -f "qemu-system.*overwatch" 2>/dev/null | head -1) || true
    if [ -z "$qemu_pid" ]; then
        log "SCHED_FIFO: QEMU PID not found, skipping"
        return
    fi
    for tid in $(ls /proc/$qemu_pid/task/ 2>/dev/null); do
        chrt -f -p 1 $tid 2>/dev/null && count=$((count + 1)) || true
    done
    log "SCHED_FIFO: applied to $count QEMU threads (PID $qemu_pid)"
}
```

In `_do_start()`, add immediately after the `ensure_performance_tuning` call (~line 934):
```bash
    apply_sched_fifo
```

No background job needed — fast, synchronous, QEMU is already running at this point.
No cleanup needed on stop — scheduling policy is per-thread and dies with the process.

---

## Deployment sequence

1. Edit `scripts/host/overwatch.sh` (changes 2, 3, 4) locally
2. Deploy script to myhost: `scp scripts/host/overwatch.sh myhost:/tmp/ && ssh myhost "sudo cp /tmp/overwatch.sh /usr/local/bin/overwatch && sudo chmod +x /usr/local/bin/overwatch"`
3. Restart VM: `ssh myhost "sudo systemctl restart overwatch"`
4. Verify runtime changes (while VM is running):
   ```bash
   # C-states capped on core 2
   for s in /sys/devices/system/cpu/cpu2/cpuidle/state*/; do printf "$(basename $s) $(cat ${s}name): disabled=$(cat ${s}disable)\n"; done
   # autogroup disabled
   cat /proc/sys/kernel/sched_autogroup_enabled          # expect: 0
   # SCHED_FIFO on QEMU threads
   for tid in $(ls /proc/$(pgrep -f qemu.*overwatch)/task/ | head -5); do chrt -p $tid; done
   ```
5. Edit GRUB on myhost: `ssh myhost "sudo nano /etc/default/grub"`
6. `ssh myhost "sudo update-grub"`
7. Confirm with user before rebooting host
8. After reboot, verify kernel params:
   ```bash
   cat /proc/cmdline | grep isolcpus   # expect: isolcpus=domain,managed_irq,2-7
   # Cores 2-7 absent from scheduler domain
   cat /sys/devices/system/cpu/isolated  # expect: 2-7
   ```
9. Restart VM and run stress-ng test (2 min, cores 0-1) to validate CPU isolation holds

---

## Rollback

- Runtime changes (2, 3, 5): `sudo systemctl stop overwatch` calls `ensure_cpu_defaults()`
  which restores C-states and autogroup. SCHED_FIFO dies with QEMU.
- GRUB change: if boot fails, hold Shift at boot → GRUB menu → remove isolcpus/nohz_full/rcu_nocbs
  from kernel command line temporarily. Fully reversible.
