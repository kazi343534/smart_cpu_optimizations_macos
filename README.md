# Smart Process Optimizer

**NSU CSE323 Operating Systems Course Project**  
**Platform: macOS Apple Silicon (ARM64) — MacBookPro17,1, 8 cores, 8 GB RAM**  

[![Watch Demo Video](https://img.shields.io/badge/Google%20Drive-Watch%20Demo%20Video%20(4:59)-4285F4?style=for-the-badge&logo=googledrive&logoColor=white)](https://drive.google.com/file/d/1N7y2BzGSoYYYDn8Czxz1FlbFoh8sr9tn/view)
[![macOS Platform](https://img.shields.io/badge/Platform-macOS%20Apple%20Silicon-black?style=for-the-badge&logo=apple)](https://drive.google.com/file/d/1N7y2BzGSoYYYDn8Czxz1FlbFoh8sr9tn/view)
[![Language](https://img.shields.io/badge/Language-C%2B%2B17%20%7C%20Obj--C%2B%2B-00599C?style=for-the-badge&logo=c%2B%2B)](https://drive.google.com/file/d/1N7y2BzGSoYYYDn8Czxz1FlbFoh8sr9tn/view)
[![Course](https://img.shields.io/badge/Course-NSU%20CSE323%20OS-red?style=for-the-badge)](https://drive.google.com/file/d/1N7y2BzGSoYYYDn8Czxz1FlbFoh8sr9tn/view)

A C++17 application that reads **real process and system data directly from the macOS kernel**, scores every running process using a dual-score resource/importance model, performs **safe, real scheduling actions** via system calls (`setpriority`), measures whether performance actually improved, and **adapts its strategy from the results** — all with zero simulation and zero fake data.

---

## 🎥 Project Video Presentation & Live Demonstration

> [!TIP]
> **Faculty & Reviewer Quick Link:** Click the banner below or use the direct link to watch the complete 5-minute video presentation and live system demonstration.

[![Watch Live Demonstration Video](assets/video_preview_banner.png)](https://drive.google.com/file/d/1N7y2BzGSoYYYDn8Czxz1FlbFoh8sr9tn/view)

### 🔗 Direct Video Link
👉 **[Click Here to Open / Watch the Full Video on Google Drive](https://drive.google.com/file/d/1N7y2BzGSoYYYDn8Czxz1FlbFoh8sr9tn/view)**

---

### ⚡ Live UI & Optimization Telemetry Preview

![Smart Process Optimizer Live GUI Demo](assets/gui_live_demo.gif)

---

### ⏱️ Video Presentation Highlights & Timestamps

| Timestamp | Topic | Description |
|-----------|-------|-------------|
| **0:00 – 0:45** | **System & Architecture Overview** | Hardware detection via `sysctlbyname` and live kernel telemetry via Mach interfaces (`host_statistics`, `host_statistics64`). |
| **0:45 – 1:40** | **Process Table & Dual-Score Model** | Live enumeration of 450+ processes via `libproc`/`sysctl(KERN_PROC_ALL)` and dual scoring (Resource Score vs. Importance Score). |
| **1:40 – 2:45** | **High-Pressure Detection & Top 3 Targets** | Automatic classification of system pressure and dynamic candidate prioritization among user processes. |
| **2:45 – 3:50** | **Safe Renicing & TOCTOU Guard** | Execution of `setpriority()` system call, read-back verification, and `proc_pidpath()` safety checks. |
| **3:50 – 4:59** | **Before/After Verification & Charts** | Verification of real CPU drops, multi-series dynamic Cocoa graphs, and adaptive feedback loop cooldown. |

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

Among all eligible user-owned processes, the optimizer selects and deprioritizes the **Top 3 processes with the highest ActionPriority and CPU usage**. It does not require an artificial >20% CPU barrier, ensuring smooth system-wide optimization whenever user tasks compete for CPU cycles, while respecting importance and system protection constraints.

### What Action Is Taken?

**Only one action: lower scheduling priority via `setpriority()`.**

```c
setpriority(PRIO_PROCESS, targetPID, currentNice + increment)
```

- `PRIO_PROCESS` = affect only this one process
- `currentNice + increment` = make it slightly less urgent to the scheduler
- `increment` starts at +2, grows to +5 with consecutive failures
- Acts concurrently on the **Top 3** highest priority candidate processes

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
  StateFactor = 100.0 if RUNNING, 25.0 if SLEEPING, 0.0 if STOPPED

ImportanceScore:
  100 = CRITICAL/PROTECTED (kernel_task, launchd, WindowServer, etc.)
   80 = IMPORTANT (nice < 0, system services)
   10 = NORMAL (ordinary user processes)

ActionPriority = ResourceScore × (1 − ImportanceScore/100)
```

### Why These Weights?

- **CPU = 0.55**: The primary resource we can control via nice values
- **MEM = 0.30**: Memory hogs slow the whole system, but we can't reclaim it
- **State = 0.15**: Running processes contribute more pressure than sleeping ones

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
# Option 1: Using the interactive build & run script
./run.sh

# Option 2: Build & run Terminal UI manually
clang++ -std=c++17 -Wall -Wextra *.cpp -o smart_optimizer
./smart_optimizer

# Option 3: Build & run Native macOS GUI manually
clang++ -std=c++17 -Wall -fobjc-arc gui_main.mm \
  system_info.cpp resource_monitor.cpp process_monitor.cpp \
  process_analyzer.cpp important_process.cpp process_controller.cpp \
  optimizer.cpp activity_logger.cpp -framework Cocoa -o smart_optimizer_gui
./smart_optimizer_gui
```

---

## File Map

| File | Purpose |
|------|---------|
| `main.cpp` | Terminal menu UI — 8 options, ANSI colors, Unicode bars |
| `gui_main.mm` | Native macOS GUI — AppKit/Cocoa, 5 live telemetry charts, dynamic layout |
| `system_info.h/.cpp` | Read hardware info via sysctlbyname (model, cores, RAM, page size) |
| `resource_monitor.h/.cpp` | System-wide CPU% and memory via Mach host_statistics |
| `process_monitor.h/.cpp` | Full process table via sysctl + libproc, per-process CPU% |
| `process_analyzer.h/.cpp` | Dual-score model: ResourceScore + ImportanceScore |
| `important_process.h/.cpp` | 5 protection rules with detailed reasons |
| `process_controller.h/.cpp` | setpriority() + kill() wrappers with errno mapping |
| `optimizer.h/.cpp` | Decision engine: Top 3 candidate selection, TOCTOU guard, feedback loop |
| `activity_logger.h/.cpp` | Timestamped audit log (file + in-memory history) |
| `run.sh` | Interactive build and launch launcher script |
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

## GUI Features & Rich Telemetry

- **Multi-Series CPU Telemetry Graph (Top-Left)** — Live 80-sample history rendering Total CPU (Emerald `#10b981`), User Space CPU (Cyan `#06b6d4`), and Kernel/System CPU (Rose `#f43f5e`) with smooth vertical gradient fills, grid lines, Y-axis markers, optimization event marker pins, and header stats (Current, User, Kernel, Peak).
- **Multi-Series Memory Distribution Graph (Top-Right)** — Detailed RAM accounting displaying Active RAM (Azure `#38bdf8`), Wired Kernel RAM (Purple `#a855f7`), Compressed RAM (Amber `#f59e0b`), and Total Used RAM (Neon Pink `#ec4899`) with live GB/percentage badges.
- **Optimization Impact Analysis Chart (Middle-Left)** — Dual-column before/after bar chart comparing target process CPU% before and after renice actions, complete with percentage savings delta badges (e.g. `▼ -35% CPU`), target process name & PID labels, and outcome-coded gradients.
- **Top 5 CPU Processes Mini-Bar Widget (Middle-Right)** — Live real-time meters showing top CPU consuming tasks with PID, process name, state badges (🟢 RUN / 🔵 SLEEP), and dynamic heatmaps (Teal → Cyan → Amber → Crimson).
- **System Pressure & Load Trend Graph (Bottom-Right)** — Dedicated telemetry card sized at 2/3 width of the main graphs, visualizing concurrent CPU load & RAM pressure curves, live pressure badges (`NORMAL` / `ELEVATED` / `HIGH`), and glowing live data points.
- **Terminal Console (Bottom-Left)** — Syntax-highlighted dark console log taking the remaining bottom width, displaying real-time scan tables and optimization audit reports.
- **Responsive Dynamic Layout Architecture** — Uses top-anchoring (`layoutSubviews` + `NSWindowDelegate`) below macOS window controls, ensuring crisp, gap-free rendering on any display size (MacBook Pro 13", 14", 16", or external monitors) with full window resizing support.
- **Dark Glassmorphism UI & Controls** — Modern slate obsidian theme (`#0f1219` / `#161b26`), styled toolbar buttons (⚡ Refresh Scan, 🚀 Run Smart Optimization, 📋 Show Log, 🧹 Clear Log, ⏱️ Smart Auto Mode 3s cycle).
