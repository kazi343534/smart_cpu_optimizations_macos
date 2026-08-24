#include "process_monitor.h"

#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/errno.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

namespace {

/*
 * Kernel process-state codes that match <sys/proc.h> values (kept local so
 * we never depend on kernel-private headers).
 *
 * MEASURED FINDINGS (verified with diagnostic probes on this Mac):
 * 1) Modern macOS reports SRUN(2) through both kinfo_proc.p_stat and
 *    proc_bsdinfo.pbi_status for nearly every live process - even ones
 *    ps(1) shows as sleeping. True per-thread run states sit behind task
 *    ports that SIP protects for foreign processes. Therefore refresh()
 *    classifies RUNNING vs SLEEPING from REAL scheduler accounting (CPU
 *    actually burned inside the sampling window). Nothing is guessed.
 * 2) A SIGSTOP'd process reports SWAIT(4), NOT SSTOP(6): the probe showed
 *    p_stat 2 -> 4 on SIGSTOP -> 2 again on SIGCONT (ps showed 'T' while
 *    stopped). SWAIT is therefore treated as the practical "stopped" sign.
 */
constexpr int kStatusZombie = 5;
constexpr int kStatusStop   = 6; // classic BSD code - kept for completeness
constexpr int kStatusWait   = 4; // measured: what macOS reports when stopped

ProcessState decodeKernelState(int status)
{
    switch (status) {
    case kStatusZombie: return ProcessState::Zombie;
    case kStatusStop:
    case kStatusWait:   return ProcessState::Stopped;
    default:            return ProcessState::Sleeping; // provisional
    }
}

/* A process is "actively working" when it burned at least this fraction
   of TOTAL machine capacity during the window (1% = ~80 ms CPU per second
   on this 8-core Mac). Well above timer noise, well below full activity. */
constexpr double kActiveCpuThresholdPercent = 1.0;

/*
 * OS CONCEPT - clock units on Apple Silicon:
 * The mach monotonic clock ticks at 24 MHz here, and mach_timebase_info()
 * returns numer=125, denom=3 (measured), i.e. ONE tick = 41.667 ns.
 * The kernel reports per-task CPU time in these RAW TICKS, so every delta
 * MUST be converted before dividing by wall-clock nanoseconds. Skipping
 * this silently understates CPU usage by 41.67x on Apple Silicon.
 */
struct MachTimebase {
    uint64_t numer = 1;
    uint64_t denom = 1;

    MachTimebase()
    {
        mach_timebase_info_data_t tb {};
        if (mach_timebase_info(&tb) == KERN_SUCCESS) {
            numer = tb.numer;
            denom = tb.denom;
        }
    }

    uint64_t toNanoseconds(uint64_t ticks) const
    {
        return ticks * numer / denom;
    }
};

/* Extracts the file name from a full path ("/usr/sbin/distnoted" ->
   "distnoted") without depending on non-reentrant libc helpers. */
std::string baseName(const std::string &path)
{
    size_t slash = path.find_last_of('/');
    return (slash == std::string::npos) ? path : path.substr(slash + 1);
}

uint64_t nanosecondsSinceBoot()
{
    static const MachTimebase kTimebase;
    return kTimebase.toNanoseconds(mach_absolute_time());
}

const MachTimebase kTimebase; // shared converter for CPU-time counters

/*
 * Reads the whole process table with sysctl(KERN_PROC_ALL).
 *
 * OS CONCEPT - why sysctl here?
 * One syscall hands us, for EVERY process at once: pid, parent pid,
 * owner uid, nice value and the TRUE scheduling state. This is exactly
 * what ps(1) uses. The table can change between the size-query and the
 * copy, so we retry on ENOMEM like ps does.
 */
bool readProcessTable(std::vector<kinfo_proc> &out)
{
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};

    for (int attempt = 0; attempt < 8; ++attempt) {
        size_t size = 0;
        if (sysctl(mib, 4, nullptr, &size, nullptr, 0) != 0 || size == 0) {
            std::fprintf(stderr, "sysctl(KERN_PROC_ALL) size failed: %s\n",
                         strerror(errno));
            return false;
        }

        std::vector<kinfo_proc> buffer(size / sizeof(kinfo_proc));
        size_t bytesWanted = buffer.size() * sizeof(kinfo_proc);

        if (sysctl(mib, 4, buffer.data(), &bytesWanted, nullptr, 0) == 0) {
            size_t count = bytesWanted / sizeof(kinfo_proc);
            out.assign(buffer.begin(), buffer.begin() + count);
            return true;
        }

        if (errno != ENOMEM) { // anything else is a hard failure
            std::fprintf(stderr, "sysctl(KERN_PROC_ALL) failed: %s\n",
                         strerror(errno));
            return false;
        }
        // Table grew between our two calls -> retry with fresh size.
    }

    std::fprintf(stderr, "sysctl(KERN_PROC_ALL): table kept changing\n");
    return false;
}

} // namespace

std::string processStateName(ProcessState state)
{
    switch (state) {
    case ProcessState::Running:  return "RUNNING";
    case ProcessState::Sleeping: return "SLEEPING";
    case ProcessState::Zombie:   return "ZOMBIE";
    case ProcessState::Stopped:  return "STOPPED";
    default:                     return "UNKNOWN";
    }
}

bool ProcessMonitor::initialize(const SystemInfo &info)
{
    logicalCores_ = info.logicalCpuCores > 0 ? info.logicalCpuCores : 1;
    return true;
}

bool ProcessMonitor::refresh(int intervalMs)
{
    /*
     * Measurement window:
     *   t0 ---- sleep(intervalMs) ---- sample everything ---- t1
     * Wall time comes from a monotonic clock, CPU deltas come from the
     * kernel's accumulated per-task nanosecond counters. Nothing estimated.
     */
    const uint64_t windowStart = nanosecondsSinceBoot();
    std::this_thread::sleep_for(std::chrono::milliseconds(intervalMs));

    std::vector<kinfo_proc> table;
    if (!readProcessTable(table))
        return false;

    std::vector<ProcessInfo> fresh;
    fresh.reserve(table.size());
    std::unordered_map<pid_t, uint64_t> updatedCpuTimes;
    updatedCpuTimes.reserve(table.size());

    for (const kinfo_proc &kp : table) {
        const pid_t pid = kp.kp_proc.p_pid;
        if (pid <= 0)
            continue; // skip kernel slot 0 / garbage entries

        ProcessInfo p;
        p.pid       = pid;
        p.parentPid = kp.kp_eproc.e_ppid;
        p.ownerId   = kp.kp_eproc.e_ucred.cr_uid;
        p.nice      = kp.kp_proc.p_nice;
        p.state     = decodeKernelState(static_cast<int>(kp.kp_proc.p_stat));
        p.name      = kp.kp_proc.p_comm; // BSD command name fallback

        // Real executable path -> friendly name (overrides truncated comm).
        char pathBuf[PROC_PIDPATHINFO_MAXSIZE] {0};
        if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) > 0)
            p.name = baseName(pathBuf);

        /*
         * Task layer: thread count, resident RAM and ACCUMULATED CPU time
         * in nanoseconds. When the kernel refuses (protected/zombie/
         * hardened process) we keep the sysctl data above, mark the row
         * [partial], and never invent numbers.
         */
        struct proc_taskinfo task {};
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) > 0 &&
            (task.pti_total_user + task.pti_total_system) > 0) {

            p.threadCount   = static_cast<int>(task.pti_threadnum);
            p.residentBytes = task.pti_resident_size;

            const uint64_t totalRawTicks =
                task.pti_total_user + task.pti_total_system;
            updatedCpuTimes[pid] = totalRawTicks; // becomes next window's baseline

            auto previous = lastCpuNanoseconds_.find(pid);
            if (previous != lastCpuNanoseconds_.end()) {
                const uint64_t windowEnd = nanosecondsSinceBoot();
                const uint64_t wallNs =
                    windowEnd > windowStart ? windowEnd - windowStart : 1;
                const uint64_t cpuDeltaTicks =
                    totalRawTicks > previous->second ? totalRawTicks - previous->second : 0;
                const uint64_t cpuDeltaNs = kTimebase.toNanoseconds(cpuDeltaTicks);

                p.cpuPercent = 100.0 *
                    static_cast<double>(cpuDeltaNs) /
                    (static_cast<double>(wallNs) * logicalCores_);
            } else {
                p.cpuPercent = -1.0; // first sighting: no baseline yet
            }

            /*
             * State inference from REAL scheduler behaviour:
             * the kernel flags already told us zombie/stopped. Everything
             * else reads as "runnable" on modern macOS, so we classify by
             * measured work: burned >=1% of machine capacity this window
             * => RUNNING, otherwise it was waiting => SLEEPING.
             */
            if (p.state == ProcessState::Sleeping &&
                p.cpuPercent >= kActiveCpuThresholdPercent)
                p.state = ProcessState::Running;
        } else {
            p.completeData = false;
            p.cpuPercent   = -1.0;
        }

        fresh.push_back(std::move(p));
    }

    lastCpuNanoseconds_ = std::move(updatedCpuTimes); // prunes dead PIDs too
    processes_ = std::move(fresh);
    return true;
}
