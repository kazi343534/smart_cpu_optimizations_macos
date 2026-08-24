#include "important_process.h"

#include <algorithm>
#include <cctype>

namespace {

/*
 * Essential macOS components identified by executable name.
 * Small, explicit, reviewable list - deliberately conservative.
 */
const char *kProtectedNames[] = {
    "kernel_task",   // the kernel itself
    "launchd",       // PID 1 - ancestor of all processes
    "WindowServer",  // draws the entire UI; killing it logs everyone out
    "loginwindow",   // login/session management
    "Finder",        // user-facing shell
    "Dock",
    "Spotlight",
    "mds",           // Spotlight metadata server
    "mds_stores",
    "coreaudiod",    // audio daemon
    "bluetoothd",    // Bluetooth daemon
    "configd",       // network configuration daemon
    "distnoted",     // distributed notifications
    "powerd",        // power management
    "securityd",     // security/cryptography services
    "syslogd",       // logging daemon
    "hidd",          // HID (keyboard/mouse) events
};

std::string toLower(std::string s)
{
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    return s;
}

bool inProtectedList(const std::string &name)
{
    const std::string lower = toLower(name);
    for (const char *candidate : kProtectedNames)
        if (lower == toLower(candidate))
            return true;
    return false;
}

} // namespace

ProcessProtector::ProcessProtector(pid_t ownPid)
    : ownPid_(ownPid)
{
}

ProtectionVerdict ProcessProtector::check(const ProcessInfo &p) const
{
    /*
     * Rules are ordered from strongest to weakest; the FIRST match wins
     * and its explanation is shown to the user. Every rule is based on
     * real kernel-provided data (pid, uid, name).
     */

    // Rule 1: never modify ourselves (we would deadlock our own monitor).
    if (p.pid == ownPid_)
        return {true, "the optimizer itself"};

    // Rule 2: PID 1 is sacred - all processes descend from it.
    if (p.pid == 1)
        return {true, "PID 1 (launchd) - ancestor of every process"};

    // Rule 3: root owns the operating system's own machinery.
    if (p.ownerId == 0)
        return {true, "owned by root (system process)"};

    // Rule 4: very low PIDs are early boot-time system processes.
    if (p.pid <= 100)
        return {true, "early boot-time system PID"};

    // Rule 5: known essential user-session components.
    if (inProtectedList(p.name))
        return {true, "essential macOS component (" + p.name + ")"};

    return {false, ""};
}
