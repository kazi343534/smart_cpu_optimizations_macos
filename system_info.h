#ifndef SYSTEM_INFO_H
#define SYSTEM_INFO_H

#include <cstdint>
#include <string>

/*
 * SystemInfo holds permanent hardware facts about this machine.
 *
 * OS CONCEPT:
 * "sysctl" is a BSD/macOS kernel interface (a real system call) that lets
 * user programs read (and sometimes change) kernel variables such as
 * hardware descriptions, limits and tunables.
 * We only READ values here - we never modify kernel state.
 */
struct SystemInfo {
    std::string model;           // e.g. "Mac14,2" (hw.model)
    std::string architecture;    // e.g. "arm64"   (hw.machine)
    uint64_t totalPhysicalBytes = 0; // installed RAM (hw.memsize)
    int logicalCpuCores = 0;     // performance + efficiency cores (hw.ncpu)
    unsigned int pageSizeBytes = 0;  // VM page size: 16 KB on Apple Silicon
};

/* Loads every field using sysctlbyname(). Returns false if any read fails. */
bool loadSystemInfo(SystemInfo &info);

#endif
