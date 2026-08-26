#ifndef RESOURCE_MONITOR_H
#define RESOURCE_MONITOR_H

#include <cstdint>
#include <mach/port.h>

#include "system_info.h"

/*
 * OS CONCEPT - how macOS reports system-wide CPU load:
 * The kernel counts scheduling TICKS spent per CPU state
 * (user / system / idle / nice). The kernel never hands out a ready-made
 * "CPU percent". Percentages must be computed by taking two snapshots of
 * those counters and dividing the differences:
 *
 *     CPU% = busyTicksDelta / allTicksDelta * 100
 *
 * We get the counters through the Mach interface host_statistics(), the same
 * source used by tools like top and Activity Monitor.
 */
struct CpuSnapshot {
    uint64_t user = 0;
    uint64_t system = 0;
    uint64_t idle = 0;
    uint64_t nice = 0;

    uint64_t total() const { return user + system + idle + nice; }
    uint64_t busy() const { return user + system + nice; }
};

/*
 * Detailed CPU utilization breakdown (User vs Kernel/System vs Nice vs Idle)
 * measured directly from kernel Mach host_statistics CPU ticks.
 */
struct CpuBreakdown {
    double totalPercent = 0.0;
    double userPercent = 0.0;
    double systemPercent = 0.0;
    double idlePercent = 0.0;
    double nicePercent = 0.0;
};

/*
 * OS CONCEPT - virtual memory accounting:
 * macOS manages physical RAM in fixed-size PAGES (16 KB on Apple Silicon).
 * host_statistics64() reports how many pages are currently:
 *   active     - recently used by running processes
 *   wired      - locked in RAM, can never be paged out (kernel, drivers)
 *   inactive   - not used recently, still resident, candidate for reclaim
 *   compressed - squeezed by the memory compressor instead of being swapped
 *   free       - unused
 * Multiplying page counts by the page size converts them into bytes.
 */
struct MemoryInfo {
    uint64_t activeBytes = 0;
    uint64_t wiredBytes = 0;
    uint64_t inactiveBytes = 0;
    uint64_t compressedBytes = 0;
    uint64_t freeBytes = 0;
    uint64_t totalBytes = 0;

    /* Close approximation of the "Memory Used" value in Activity Monitor:
       memory that processes/kernel actively occupy right now. */
    uint64_t usedBytes() const { return activeBytes + wiredBytes + compressedBytes; }
    double usedPercent() const
    {
        return totalBytes ? 100.0 * static_cast<double>(usedBytes()) /
                                static_cast<double>(totalBytes)
                          : 0.0;
    }
};

/*
 * ResourceMonitor reads system-wide CPU and memory pressure from the kernel.
 * It keeps the previous CPU snapshot internally so every call to
 * measureCpuUsage() measures a REAL time window, not a made-up number.
 */
class ResourceMonitor {
public:
    /* Stores hardware facts and takes the first CPU tick snapshot as a
       baseline. Must be called once before any measurement. */
    bool initialize(const SystemInfo &info);

    /* Waits intervalMs milliseconds, then returns the REAL CPU utilisation
       (percent, 0..100+) measured between the previous snapshot and a fresh
       one. Returns -1.0 when the kernel counters are unavailable. */
    double measureCpuUsage(int intervalMs);

    /* Measures detailed CPU breakdown (total, user, system, idle, nice) over intervalMs. */
    bool measureCpuDetailed(int intervalMs, CpuBreakdown &out);

    /* Immediate RAM statistics. Never blocks. */
    bool readMemoryInfo(MemoryInfo &out);

private:
    bool captureCpuSnapshot(CpuSnapshot &out);

    mach_port_t hostPort_ = MACH_PORT_NULL; // Mach "handle" to this machine
    unsigned int pageSize_ = 0;
    uint64_t totalRamBytes_ = 0;
    CpuSnapshot previous_;
    bool hasPrevious_ = false;
};

#endif
