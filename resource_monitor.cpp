#include "resource_monitor.h"

#include <mach/host_info.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <chrono>
#include <cstdio>
#include <thread>

/*
 * OS CONCEPT - Mach ports:
 * On macOS many kernel services are reached through "ports" (message queues).
 * mach_host_self() returns a send-right to the HOST port, which represents
 * the whole machine. We fetch it once and reuse it for every query.
 */
bool ResourceMonitor::initialize(const SystemInfo &info)
{
    hostPort_ = mach_host_self();
    if (hostPort_ == MACH_PORT_NULL)
        return false;

    pageSize_ = info.pageSizeBytes;
    totalRamBytes_ = info.totalPhysicalBytes;

    hasPrevious_ = captureCpuSnapshot(previous_);
    return hasPrevious_ && pageSize_ > 0 && totalRamBytes_ > 0;
}

bool ResourceMonitor::captureCpuSnapshot(CpuSnapshot &out)
{
    host_cpu_load_info_data_t load;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;

    kern_return_t result =
        host_statistics(hostPort_, HOST_CPU_LOAD_INFO,
                        reinterpret_cast<host_info_t>(&load), &count);
    if (result != KERN_SUCCESS) {
        std::fprintf(stderr, "host_statistics(CPU) failed: %s\n",
                     mach_error_string(result));
        return false;
    }

    out.user   = load.cpu_ticks[CPU_STATE_USER];
    out.system = load.cpu_ticks[CPU_STATE_SYSTEM];
    out.idle   = load.cpu_ticks[CPU_STATE_IDLE];
    out.nice   = load.cpu_ticks[CPU_STATE_NICE];
    return true;
}

double ResourceMonitor::measureCpuUsage(int intervalMs)
{
    /*
     * Two real samples define a real measurement window:
     *   sample A = previous snapshot (or a fresh one on first call)
     *   sleep(intervalMs) lets the kernel run and accumulate more ticks
     *   sample B = fresh snapshot
     * The percentage is derived ONLY from these kernel counters - there is
     * no estimation or simulation involved.
     */
    CpuSnapshot before;
    if (hasPrevious_)
        before = previous_;
    else if (!captureCpuSnapshot(before))
        return -1.0;

    std::this_thread::sleep_for(std::chrono::milliseconds(intervalMs));

    CpuSnapshot after;
    if (!captureCpuSnapshot(after))
        return -1.0;

    previous_ = after;
    hasPrevious_ = true;

    uint64_t totalDelta = after.total() - before.total();
    uint64_t busyDelta = after.busy() - before.busy();

    if (totalDelta == 0)
        return 0.0; // no ticks elapsed at all

    return 100.0 * static_cast<double>(busyDelta) /
           static_cast<double>(totalDelta);
}

bool ResourceMonitor::measureCpuDetailed(int intervalMs, CpuBreakdown &out)
{
    CpuSnapshot before;
    if (hasPrevious_)
        before = previous_;
    else if (!captureCpuSnapshot(before))
        return false;

    if (intervalMs > 0)
        std::this_thread::sleep_for(std::chrono::milliseconds(intervalMs));

    CpuSnapshot after;
    if (!captureCpuSnapshot(after))
        return false;

    previous_ = after;
    hasPrevious_ = true;

    uint64_t totalDelta = after.total() - before.total();
    if (totalDelta == 0) {
        out = CpuBreakdown{};
        return true;
    }

    uint64_t busyDelta = after.busy() - before.busy();
    uint64_t userDelta = after.user - before.user;
    uint64_t systemDelta = after.system - before.system;
    uint64_t idleDelta = after.idle - before.idle;
    uint64_t niceDelta = after.nice - before.nice;

    out.totalPercent = 100.0 * static_cast<double>(busyDelta) / static_cast<double>(totalDelta);
    out.userPercent = 100.0 * static_cast<double>(userDelta) / static_cast<double>(totalDelta);
    out.systemPercent = 100.0 * static_cast<double>(systemDelta) / static_cast<double>(totalDelta);
    out.idlePercent = 100.0 * static_cast<double>(idleDelta) / static_cast<double>(totalDelta);
    out.nicePercent = 100.0 * static_cast<double>(niceDelta) / static_cast<double>(totalDelta);
    return true;
}

bool ResourceMonitor::readMemoryInfo(MemoryInfo &out)
{
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;

    kern_return_t result =
        host_statistics64(hostPort_, HOST_VM_INFO64,
                          reinterpret_cast<host_info_t>(&vm), &count);
    if (result != KERN_SUCCESS) {
        std::fprintf(stderr, "host_statistics64(memory) failed: %s\n",
                     mach_error_string(result));
        return false;
    }

    const uint64_t page = pageSize_;
    out.activeBytes     = static_cast<uint64_t>(vm.active_count) * page;
    out.inactiveBytes   = static_cast<uint64_t>(vm.inactive_count) * page;
    out.wiredBytes      = static_cast<uint64_t>(vm.wire_count) * page;
    out.compressedBytes = static_cast<uint64_t>(vm.compressor_page_count) * page;
    out.freeBytes       = static_cast<uint64_t>(vm.free_count) * page;
    out.totalBytes      = totalRamBytes_;
    return true;
}
