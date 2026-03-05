# Stress Testing and Issue Reproduction

Synthetic loads let you reproduce failure modes without needing a game
session. The main advantage over gaming: no server connectivity variable,
faster feedback, and a controlled stop/start loop. If a stress test
produces the same failure, the failure is in the VM stack, not Blizzard.

---

## 1. GPU TDR stability (FurMark or Unigine Heaven, inside VM)

**What it tests:** Whether the GPU passthrough configuration can sustain
maximum GPU load without triggering `VidSchiCheckHwProgress` timeouts.
This is the gameplay TDR failure mode.

**Why it's useful:** OW2 sessions are variable — a match disconnect could
be server-side, Ricochet, or GPU. FurMark removes all those variables: if
it crashes, the GPU config is unstable. If it runs clean for 15 minutes,
the GPU is fine and any OW2 crashes are server or application problems.

### Setup

- **FurMark**: Download from `geeks3d.com`. Free. Explicit GPU stress tool
  — renders a furry torus at max framerate, no framerate cap, maximum heat.
- **Unigine Heaven**: Download from `benchmark.unigine.com`. More
  representative of a game workload. Less brutal than FurMark.

### Test procedure

1. Start the VM, launch FurMark or Heaven, run for 15 minutes.
2. After the run, check for new TDR dumps:
   ```powershell
   Get-ChildItem C:\Windows\LiveKernelReports\WATCHDOG\ |
       Sort-Object LastWriteTime | Select-Object -Last 5 Name,LastWriteTime
   ```
3. No new dumps = GPU configuration is stable under sustained load.
   New dump = `VidSchiCheckHwProgress` timeout; see mitigations below.

### Interpreting results

| Outcome | Conclusion |
|---|---|
| Clean run, no dumps | GPU passthrough is stable; OW2 disconnects are server/network |
| Dump within 5 min | GPU config is unstable; check huge pages, graphics settings |
| Dump after 10+ min | Marginal stability; likely thermal or power delivery |

### Mitigations if FurMark produces dumps

1. Verify `HugePages_Free = 0` on the host after VM start (`grep HugePages_Free /proc/meminfo`)
2. Lower in-game resolution or quality settings to reduce GPU command throughput
3. Try driver 32.0.23027.2005 (next tested version after current 32.0.23017.1001)
4. Check host swap is zero during the run (`free -h`)

---

## 2. VCPU scheduling pressure (stress-ng on host cores 0-1)

**What it tests:** Whether the CPU isolation is robust — specifically,
whether the QEMU emulator thread competing for cores 0-1 can cause frame
stalls or TDRs in the guest vCPU threads on cores 2-7.

**Background:** `AllowedCPUs` confines all host processes (including the
QEMU emulator thread) to cores 0-1. The emulator thread handles interrupt
injection into the guest and MMIO emulation. If cores 0-1 are saturated by
host work, interrupt delivery backs up. The vCPU threads on cores 2-7
continue executing but can't process pending interrupts, which stalls any
guest code that was waiting for I/O completion or a timer tick.

In gameplay, any sub-TDR stall (GPU misses WDDM heartbeat briefly, recovers
before the full TDR fires) produces a visible freeze "blip". Saturating
cores 0-1 with `stress-ng` simulates the worst case of this.

### Prerequisites

```bash
# Install on myhost if not present
sudo apt install stress-ng
```

### Test procedure

Run this on the host (myhost) while actively gaming in the VM:

```bash
# Saturate cores 0-1 — where the QEMU emulator thread lives
sudo stress-ng --cpu 2 --taskset 0,1 --cpu-method matrixprod \
    --metrics-brief --timeout 120s
```

Run for 2 minutes while playing. Note any blips, freezes, or disconnects
during the window.

### Monitoring during the test

Open a second terminal on the host while stress-ng runs:

```bash
# Watch per-core utilization — cores 0-1 should be saturated (100%),
# cores 2-7 should be unaffected (showing VM guest load, not 100%)
mpstat -P ALL 1

# Watch VCPU placement — vCPUs should stay on cores 2-7 throughout
watch -n1 'virsh vcpuinfo overwatch | grep -E "VCPU|CPU Affinity|CPU Time"'
```

Expected host-side behavior during stress:
- Cores 0-1: ~100% user+sys (stress-ng + emulator thread contending)
- Cores 2-7: normal guest load (~30-80% depending on scene)
- vCPUs: pinned to cores 2-7, not migrated

### Interpreting results

| Guest behavior during stress | Conclusion |
|---|---|
| No blips, smooth gameplay | CPU isolation is robust; emulator thread on 2 cores is sufficient |
| Blips correlate with stress window | Emulator thread is a bottleneck; interrupt injection is latency-sensitive |
| TDR dump generated | Core 0-1 saturation is sufficient to cause a full WDDM timeout; emulator thread needs more headroom |

If blips correlate: the emulator thread needs dedicated core headroom beyond what AllowedCPUs provides under stress. Options to explore would be reserving a dedicated core for the emulator (not currently implemented) or reducing other host work on cores 0-1.

### After the test

```bash
# Confirm stress-ng has exited (it should stop after --timeout)
pgrep stress-ng

# Check for new TDR dumps generated during the window
ssh myhost "sudo virsh qemu-agent-command overwatch '{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell\",\"arg\":[\"-Command\",\"Get-ChildItem C:\\\\Windows\\\\LiveKernelReports\\\\WATCHDOG\\\\ | Sort-Object LastWriteTime | Select-Object -Last 5 Name,LastWriteTime | Format-Table -AutoSize\"],\"capture-output\":true}}'" | python3 -c "
import json,sys,base64
d=json.load(sys.stdin)['return']
print(json.dumps(d))
" 2>/dev/null
```

### Distinguishing emulator thread pressure from vCPU pressure

The two failure modes look similar (both produce blips and potentially
TDR dumps) but have different host-side signatures:

- **Emulator thread pressure** (this test): cores 0-1 are saturated,
  cores 2-7 have normal load. The vCPU threads are executing but their
  interrupt delivery is delayed.
- **vCPU preemption** (what happened before `<cputune>` was added): cores
  2-7 would show host scheduler preempting vCPU threads. This required
  `virsh vcpuinfo` showing vCPUs migrating off their pinned cores.

With `<cputune>` in place, the second case should no longer occur. This
test specifically probes the first case.

---

## 3. Host memory pressure (observation only — do not reproduce)

**What it tested:** Whether host swap activity (kswapd) competing with
VCPU threads for CPU time causes GPU TDR pressure.

**Status: fixed.** VM RAM was reduced from 88GiB to 48GiB on a 96GiB
host, eliminating swap entirely. This was the primary driver of gameplay
TDR crashes prior to 2026-03-02.

**Do not reproduce** by reducing hugepages — this restores a known-bad
state that caused multiple crashes per session. If you suspect memory
pressure has returned (e.g., after adding RAM-heavy background services):

### Signs of memory pressure (without intentionally inducing it)

```bash
# On the host, while VM is running:
free -h                          # swap > 0 means pressure is back
grep HugePages_Free /proc/meminfo # should be 0 after VM fully starts

# Watch kswapd CPU usage
top -d1 -p $(pgrep kswapd)       # any sustained CPU% from kswapd is bad
```

### Expected healthy state

```
swap:          0B used            # zero swap used
HugePages_Free: 0                 # all 24,576 pages allocated to VM
kswapd:        0.0% CPU          # idle
```

### If memory pressure returns

1. Check what's consuming host RAM beyond the VM: `ps aux --sort=-%mem | head`
2. If the host has new persistent background services, reclaim from the VM:
   update `<memory unit='GiB'>` in `overwatch.xml` and `hugepages=` in GRUB
3. Reboot the host to reallocate huge pages at the new count
4. Verify with `grep HugePages_Free /proc/meminfo` after VM start

See [CPU Pinning case study](case-studies.md#cpu-pinning-frame-pacing-vs-frame-rate-observed-2026-03-02)
for the original investigation.
