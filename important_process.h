#ifndef IMPORTANT_PROCESS_H
#define IMPORTANT_PROCESS_H

#include <sys/types.h>
#include <string>

#include "process_monitor.h"

/*
 * The SAFETY layer of the optimizer.
 *
 * OS CONCEPT - why protection matters:
 * Killing or deprioritising the wrong process can freeze the whole system.
 * PID 1 (launchd on macOS) is the ancestor of every user process - harming
 * it can bring the OS down. Root-owned daemons implement essential services
 * (window server, audio, networking, security). This module answers ONE
 * question for every process: "may the optimizer touch this at all?"
 * and always explains WHY, so decisions are auditable.
 */
struct ProtectionVerdict {
    bool protectedProcess = false;
    std::string reason; // empty when not protected
};

class ProcessProtector {
public:
    explicit ProcessProtector(pid_t ownPid);

    /* Decides whether a process must never be modified by the optimizer. */
    ProtectionVerdict check(const ProcessInfo &p) const;

private:
    pid_t ownPid_; // we NEVER optimise ourselves (self-deadlock risk)
};

#endif
