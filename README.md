# Smart Process Optimizer

**NSU CSE323 Operating Systems Course Project**
**Platform: macOS Apple Silicon (ARM64) — MacBookPro17,1, 8 cores, 8 GB RAM**

A C++17 application that reads **real process and system data directly from the
macOS kernel**, scores every running process using a dual-score resource/importance
model, performs **safe, real scheduling actions** via system calls (`setpriority`),
measures whether performance actually improved, and **adapts its strategy from the
results** — all with zero simulation and zero fake data.

---

## What Does This Program Do?

Smart Process Optimizer is an intelligent system resource manager. It continuously
monitors every running process on your Mac, identifies processes that are consuming
too many CPU or memory resources, and safely **lowers their scheduling priority**
so the system runs smoother for the user.

### Key Capabilities

1. **Real-Time Process Scanning** — Reads every process directly from the macOS
   kernel using `sysctl(KERN_PROC_ALL)` and `libproc`. Gets PID, name, state,
   CPU time, memory (RSS), thread count, nice value, and owner UID.

2. **System Resource Monitoring** — Measures actual system-wide CPU utilization
   and memory usage through Mach kernel interfaces (`host_statistics`,
   `host_statistics64`), the same source used by Activity Monitor.

3. **Intelligent Scoring** — Every process is scored on two dimensions:
   - **Resource Score** (how much CPU/memory it uses)
   - **Importance Score** (how critical it is — system processes score high)

4. **Safe Optimization** — Only lowers scheduling priority (`nice` value) of
   user-owned processes. Never kills, never raises priority, never touches
   protected system processes.

5. **Before/After Measurement** — Every optimization is followed by a real
   measurement window to verify whether performance actually improved.

6. **Adaptive Strategy** — The optimizer learns from failures: it increases
   its renice increment on consecutive failures and enters a cooldown mode
   after 3 failures in a row.

7. **Two Interfaces** — Terminal menu UI with Unicode graphics AND a native
   macOS Cocoa GUI with live line charts, bar graphs, and process tables.

---

## How Does Optimization Work?

The optimizer runs in cycles. Each cycle follows this exact sequence:

```
┌─────────────────────────────────────────────────────────────┐
│  STEP 1: MEASURE BEFORE                                      │
│  • Sleep 1 second, capture CPU tick counters                 │
│  • Refresh all process CPU times                             │
│  • Read memory usage (active + wired + compressed)           │
│  • Classify system pressure: NORMAL / ELEVATED / HIGH        │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  STEP 2: ANALYZE EVERY PROCESS                              │
│  • For each of ~500+ processes:                              │
│    ResourceScore = 0.55 × CPU% + 0.30 × MEM% + 0.15 × State │
│    Importance    = 100 (protected) / 80 (nice<0) / 10 (normal)│
│    ActionPriority= ResourceScore × (1 − Importance/100)      │
│  • Eligibility check: own-UID only, not protected, score≥20  │
│  • Pick the ONE process with highest ActionPriority           │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  STEP 3: TOCTOU SAFETY CHECK                                 │
│  • Re-verify target's identity via proc_pidpath()            │
│  • If PID was recycled by another process → ABORT, log it    │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  STEP 4: APPLY ACTION                                        │
│  • setpriority(PRIO_PROCESS, pid, nice + increment)          │
│  • increment = 2 + consecutiveFailures (capped at 5)         │
│  • Read back the new nice value to verify it actually changed │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  STEP 5: MEASURE AFTER                                       │
│  • Sleep 1 second, capture fresh CPU/memory numbers          │
│  • Re-analyze the target process's new CPU%                  │
│  • Compare BEFORE vs AFTER                                   │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  STEP 6: VERDICT + ADAPT                                     │
│  • Target CPU fell ≥20% relative → IMPROVED (success)        │
│  • System CPU dropped ≥1 point   → PARTIAL (success)         │
│  • Nothing changed              → NO IMPROVEMENT (failure)   │
│  • 3 consecutive failures → cooldown: observe-only for 3 cycles│
│  • Log everything to smart_optimizer_activity.log             │
└─────────────────────────────────────────────────────────────┘
```

---

## Which Processes Does It Optimize?

### Eligibility Rules (ALL must be true)

| Rule | Reason |
|------|--------|
| Must belong to the current user (`getuid()`) | Cannot and should not modify other users' processes |
| Must NOT be a protected process (see below) | System stability depends on these |
| ResourceScore must exceed threshold (≥20) | Only resource-heavy processes qualify |
| Must have measurable CPU usage | No point deprioritizing idle processes |

### Protected Processes (NEVER touched)

| Protection Rule | Processes |
|----------------|-----------|
| PID ≤ 100 | Kernel threads and early-boot processes |
| PID 1 (launchd) | macOS init system — killing it = instant crash |
| Root-owned processes | Only root can modify root processes anyway |
| Own PID | The optimizer cannot modify itself |
| Named in essentials list | `kernel_task`, `launchd`, `WindowServer`, `loginwindow`, `spotlight`, `fs_usage`, `Activity Monitor` |
| nice < 0 | Already prioritized by the system for a reason |

### Target Selection

Among all eligible processes, the optimizer picks the **single process with the
highest ActionPriority score**. This ensures we always act on the biggest resource
consumer first, while respecting importance constraints.

### What Action Is Taken?

**Only one action: lower scheduling priority via `setpriority()`.**

```c
setpriority(PRIO_PROCESS, targetPID, currentNice + increment)
```

- `PRIO_PROCESS` = affect only this one process
- `currentNice + increment` = make it slightly less urgent to the scheduler
- `increment` starts at +2, grows to +5 with consecutive failures

**What we NEVER do:**
- Never kill processes (`kill()`)
- Never send signals (`SIGSTOP`/`SIGCONT` — reserved for manual control only)
- Never raise priority
- Never modify memory allocation
- Never access process memory or inject code

---

## System Calls and OS Interfaces Used

| System Call | Purpose | Module |
|-------------|---------|--------|
| `sysctl(KERN_PROC_ALL)` | Get list of all running processes | process_monitor |
| `sysctlbyname()` | Read hardware info (model, cores, RAM) | system_info |
| `proc_listpids()` | Alternative PID enumeration via libproc | process_monitor |
| `proc_pidpath()` | Get full executable path for a PID | process_monitor, optimizer |
| `proc_pidinfo(PROC_PIDTASKINFO)` | Get per-process CPU time, RSS, threads | process_monitor |
| `host_statistics()` | Read system-wide CPU tick counters | resource_monitor |
| `host_statistics64()` | Read system-wide memory page counts | resource_monitor |
| `getpriority()` | Read a process's current nice value | process_controller |
| `setpriority()` | Change a process's scheduling priority | process_controller |
| `getuid()` | Get current user ID for eligibility check | optimizer |
| `kill()` | Send SIGSTOP/SIGCONT (manual control only) | process_controller |
| `mach_absolute_time()` | High-resolution timing for measurements | resource_monitor |

---

## Scoring Model (Detailed)

```
ResourceScore = 0.55 × CPU% + 0.30 × MEM% + 0.15 × StateFactor

Where:
  CPU%     = measured system-wide CPU utilization (0-100)
  MEM%     = memory used / total memory × 100 (0-100)
  StateFactor = 1.0 if RUNNING, 0.5 if SLEEPING, 0.3 if STOPPED

ImportanceScore:
  100 = CRITICAL/PROTECTED (kernel_task, launchd, WindowServer, etc.)
   80 = IMPORTANT (nice < 0, system services)
   10 = NORMAL (ordinary user processes)

ActionPriority = ResourceScore × (1 − ImportanceScore/100)

Classification Thresholds:
  kHeavyResourceScore = 20  (≈ one full core on 8-core Mac)
  kNormalResourceScore = 12 (used under HIGH pressure)
  kImportantImportance = 60
```

### Why These Weights?

- **CPU = 0.55**: The primary resource we can control via nice values
- **MEM = 0.30**: Memory hogs slow the whole system, but we can't reclaim it
- **State = 0.15**: Running processes contribute more pressure than sleeping ones

### Why threshold = 20?

On an 8-core Mac, one fully busy core = 12.5% of total capacity. A process
using ≥15-20% CPU is consuming at least one core's worth. The scoring formula
with typical memory usage pushes heavy processes above 20, making this a
natural threshold.

---

## macOS-Specific Findings (Experimental Results)

### 1. Apple Silicon Mach Tick Units
On Apple Silicon, `pti_total_user` and `pti_total_system` in `proc_pidinfo`
are in **raw Mach ticks** (24 MHz), NOT nanoseconds. We verified:
- Process accumulated 23,970,968 ticks in 1.004 seconds
- Conversion: 23,970,968 × 125 / 3 = nanoseconds → 0.999 seconds
- Ignoring this conversion understates CPU usage by exactly **41.67×**

### 2. Unreliable Process State Flags
`kinfo_proc.p_stat` returns SRUN (2) for nearly ALL live processes on
modern macOS, even sleeping ones. WindowServer shows 'S' in `ps` while
p_stat=2. Solution: state is inferred from measured CPU consumption:
- Consumed ≥1% CPU in window → RUNNING
- Consumed <1% CPU → SLEEPING
- ZOMBIE/STOPPED from kernel flags (reliable)

### 3. SIGSTOP Shows as SWAIT, Not SSTOP
After sending SIGSTOP, `p_stat` reads 4 (SWAIT), not 6 (SSTOP).
Verified: p_stat goes 2 → 4 → 2 across stop/continue cycle, while
`ps` correctly shows 'T' when stopped.

### 4. PID-Reuse TOCTOU Race
Between scanning and acting, the OS can recycle a PID for a different
process. Discovered live: a "fresh" hog reported nice=19. Fixed:
identity is re-verified via `proc_pidpath()` immediately before every
syscall; mismatches abort the action and are logged as safety events.

---

## Build & Run

```bash
# Terminal UI (text menu with ANSI colors)
clang++ -std=c++17 -Wall -Wextra *.cpp -o smart_optimizer
./smart_optimizer

# Native macOS GUI (AppKit/Cocoa window with graphs)
clang++ -std=c++17 -Wall -fobjc-arc gui_main.mm \
  system_info.cpp resource_monitor.cpp process_monitor.cpp \
  process_analyzer.cpp important_process.cpp process_controller.cpp \
  optimizer.cpp activity_logger.cpp -framework Cocoa -o smart_optimizer_gui
./smart_optimizer_gui

# Or run everything with one command:
./demo.sh
```

---

## File Map

| File | Purpose |
|------|---------|
| `main.cpp` | Terminal menu UI — 8 options, ANSI colors, Unicode bars |
| `gui_main.mm` | Native macOS GUI — AppKit/Cocoa, live line charts, buttons |
| `system_info.h/.cpp` | Read hardware info via sysctlbyname (model, cores, RAM, page size) |
| `resource_monitor.h/.cpp` | System-wide CPU% and memory via Mach host_statistics |
| `process_monitor.h/.cpp` | Full process table via sysctl + libproc, per-process CPU% |
| `process_analyzer.h/.cpp` | Dual-score model: ResourceScore + ImportanceScore |
| `important_process.h/.cpp` | 5 protection rules with detailed reasons |
| `process_controller.h/.cpp` | setpriority() + kill() wrappers with errno mapping |
| `optimizer.h/.cpp` | Decision engine: target selection, TOCTOU guard, feedback loop |
| `activity_logger.h/.cpp` | Timestamped audit log (file + in-memory history) |
| `demo.sh` | One-command live demonstration script |

---

## Safety Guarantees

1. **Never kills any process** — only adjusts scheduling priority
2. **Never modifies root/PID≤100/essential processes** — hardcoded protection
3. **Only own-UID processes** — cannot and will not affect other users
4. **Every syscall checked** — EPERM, ESRCH, EACCES all reported honestly
5. **Read-back verification** — confirms nice value actually changed after setpriority
6. **TOCTOU guard** — re-identifies target via proc_pidpath before acting
7. **Adaptive back-off** — 3 failures → observe-only cooldown prevents thrashing
8. **Full audit trail** — every decision logged to file with timestamps

---

## GUI Features

- **System CPU %** — live line chart, green, updates every scan
- **Memory used %** — live line chart, blue, updates every scan
- **Optimization effect** — before/after bar chart, color-coded by result
- **Process table** — top 20 processes with PID, state, CPU%, bar graph, memory, name
- **Refresh Scan** — manual scan button
- **Run Smart Optimization** — one-click optimization cycle
- **Show Log** — display recent activity log entries
- **Auto refresh** — toggle 3-second automatic scanning
