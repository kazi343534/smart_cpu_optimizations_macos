#include "system_info.h"

#include <sys/sysctl.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

/*
 * Generic helper: asks the kernel for one sysctl variable into a fixed-size
 * buffer. Returns false and prints the REAL OS error when unavailable.
 */
bool readSysctlBuffer(const char *name, void *buffer, size_t bufferSize)
{
    size_t size = bufferSize;
    if (sysctlbyname(name, buffer, &size, nullptr, 0) != 0) {
        std::fprintf(stderr, "sysctl(%s) failed: %s\n", name, std::strerror(errno));
        return false;
    }
    return true;
}

/*
 * String-valued sysctl variables have unknown length, so we call sysctl once
 * with nullptr to ask "how big are you?", then once more to fetch the value.
 */
bool readSysctlString(const char *name, std::string &out)
{
    size_t size = 0;
    if (sysctlbyname(name, nullptr, &size, nullptr, 0) != 0 || size == 0) {
        std::fprintf(stderr, "sysctl(%s) failed: %s\n", name, std::strerror(errno));
        return false;
    }
    std::vector<char> buffer(size);
    if (sysctlbyname(name, buffer.data(), &size, nullptr, 0) != 0) {
        std::fprintf(stderr, "sysctl(%s) failed: %s\n", name, std::strerror(errno));
        return false;
    }
    out.assign(buffer.data()); // stops at the NUL terminator
    return true;
}

} // namespace

bool loadSystemInfo(SystemInfo &info)
{
    bool ok = true;

    ok = readSysctlString("hw.model", info.model) && ok;
    ok = readSysctlString("hw.machine", info.architecture) && ok;

    uint64_t ramBytes = 0;
    if (readSysctlBuffer("hw.memsize", &ramBytes, sizeof(ramBytes)))
        info.totalPhysicalBytes = ramBytes;
    else
        ok = false;

    int cores = 0;
    if (readSysctlBuffer("hw.ncpu", &cores, sizeof(cores)))
        info.logicalCpuCores = cores;
    else
        ok = false;

    unsigned int pageSize = 0;
    if (readSysctlBuffer("hw.pagesize", &pageSize, sizeof(pageSize)))
        info.pageSizeBytes = pageSize;
    else
        ok = false;

    return ok;
}
