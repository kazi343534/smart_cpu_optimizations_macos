#ifndef PROCESS_CONTROLLER_H
#define PROCESS_CONTROLLER_H

#include <sys/types.h>
#include <csignal>
#include <string>

/*
 * The ONLY module allowed to change how the OS schedules a process.
 *
 * OS CONCEPT - nice values and permissions:
 * Each BSD process has a "nice" value (-20 highest priority .. +19 lowest).
 * setpriority(PRIO_PROCESS, pid, n) is the same syscall the renice(8) tool
 * uses. macOS permission rules:
 *   - you may LOWER the priority (increase nice) of your OWN processes;
 *   - RAISING priority or touching other users' processes needs root,
 *     which the kernel reports as EPERM - we surface that error verbatim
 *     and never pretend an action succeeded.
 * The optimizer only ever deprioritises, so unprivileged use is possible.
 */
enum class ActionResult {
    Success,
    PermissionDenied,
    ProcessGone,
    Failed
};

struct ActionOutcome {
    ActionResult result = ActionResult::Failed;
    int oldNice = 0;        // read from the kernel before the change
    int requestedNice = 0;  // what we asked for
    int actualNice = 0;     // read back AFTER the syscall (verification)
    std::string osError;    // errno text when something failed
};

class ProcessController {
public:
    /* Increases the nice value by `increment` (lowering priority).
       Never decreases it. Verifies success by re-reading the kernel. */
    static ActionOutcome raiseNice(pid_t pid, int increment);

    /* Sends SIGSTOP / SIGCONT - a MANUAL, user-confirmed action.
       OS CONCEPT: SIGSTOP freezes a process (scheduler never picks it,
       RAM stays allocated); SIGCONT resumes it exactly where it was.
       This is the strongest lever we allow, so the UI layer gates it
       behind explicit confirmation and protection checks. */
    static ActionOutcome sendSignal(pid_t pid, int signalNumber);
};

#endif
