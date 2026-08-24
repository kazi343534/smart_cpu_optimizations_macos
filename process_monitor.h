#ifndef PROCESS_MONITOR_H
#define PROCESS_MONITOR_H

#include <sys/types.h>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "system_info.h"

/*
 * OS CONCEPT - process states:
 * Every process sits in a kernel state (see <sys/proc.h>): runnable/running,
 * sleeping (waiting for an event), stopped (signalled), or zombie (dead but
 * not yet collected by its parent). We expose them read-only here.
 */
enum class ProcessState {
    Running,
    Sleeping,
    Zombie,
    Stopped,
    Unknown
};

/* Human-readable name for a state (for tables and logs). */
std::string processStateName(ProcessState state);

/*
 * One REAL process, as reported by the kernel.
 * No field is invented: every value comes from a system interface.
 */
struct ProcessInfo {
    pid_t pid = 0;
    pid_t parentPid = 0;
    std::string name;                 // executable name (proc_pidpath fallback: BSD comm)
    ProcessState state = ProcessState::Unknown;
    /* State source policy (verified against ps on modern macOS):
       ZOMBIE / STOPPED  -> straight from kernel flags (trustworthy).
       RUNNING           -> measurably consumed >=1% of machine CPU in the
                            sampling window (real scheduler accounting).
       SLEEPING          -> alive but did no measurable work this window.
       The kernel's raw "runnable" flag is unreliable on current macOS
       (it reports SRUN for almost every live process). */
    int nice = 0;                     // scheduling nice value (-20 highest .. +19 lowest)
    uid_t ownerId = 0;                // owning user id (0 = root)
    uint64_t residentBytes = 0;       // physical RAM held right now (RSS)
    int threadCount = 0;
    double cpuPercent = 0.0;          // measured over the refresh window
                                      // (negative => no previous sample yet)
    bool completeData = true;         // false when the kernel refuses task info
};

/*
 * OS CONCEPT - measuring per-process CPU%:
 * The kernel accumulates the CPU time each task consumes (nanoseconds,
 * readable with proc_pidinfo(PROC_PIDTASKINFO)). There is no direct
 * "percent" value anywhere. We therefore remember every process's
 * accumulated time, wait one real time window, and compute:
 *
 *     CPU% = deltaCpuTime / (deltaWallTime * coreCount) * 100
 *
 * which yields the same scale Activity Monitor uses (100% = one full machine).
 */
class ProcessMonitor {
public:
    /* Stores hardware context needed for CPU% math. Call once. */
    bool initialize(const SystemInfo &info);

    /* Sleeps intervalMs, then samples the whole process table and computes
       fresh CPU% values against the PREVIOUS refresh. Returns false only if
       the process list itself cannot be read. */
    bool refresh(int intervalMs);

    const std::vector<ProcessInfo> &processes() const { return processes_; }
    size_t count() const { return processes_.size(); }

private:
    std::vector<pid_t> listPids() const;

    int logicalCores_ = 1;
    std::unordered_map<pid_t, uint64_t> lastCpuNanoseconds_;
    std::vector<ProcessInfo> processes_;
};

#endif
