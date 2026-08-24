#include "process_controller.h"

#include <sys/resource.h>
#include <algorithm>
#include <cerrno>
#include <cstring>

namespace {

/* macOS allows nice in [-20, 20]; +19 is the practical lowest priority. */
constexpr int kMaxNice = 19;

ActionResult mapErrno(int err)
{
    switch (err) {
    case EPERM: return ActionResult::PermissionDenied;
    case ESRCH: return ActionResult::ProcessGone;
    default:    return ActionResult::Failed;
    }
}

/* getpriority returns -1 BOTH for "value is -1" AND for errors, so the
   errno flag must be cleared before every call - a classic syscall trap. */
int readNice(pid_t pid, bool &ok)
{
    errno = 0;
    int value = getpriority(PRIO_PROCESS, pid);
    ok = !(value == -1 && errno != 0);
    return value;
}

} // namespace

ActionOutcome ProcessController::raiseNice(pid_t pid, int increment)
{
    ActionOutcome out;

    if (increment <= 0) {
        out.result = ActionResult::Failed;
        out.osError = "refusing non-positive increment (we never raise priority)";
        return out;
    }

    bool ok = false;
    out.oldNice = readNice(pid, ok);
    if (!ok) {
        out.result = mapErrno(errno); // cannot even READ it -> do not act
        out.osError = strerror(errno);
        return out;
    }

    out.requestedNice = std::min(out.oldNice + increment, kMaxNice);
    if (out.requestedNice == out.oldNice) {
        // Already at the floor - report success-with-no-change honestly.
        out.actualNice = out.oldNice;
        out.result = ActionResult::Success;
        return out;
    }

    if (setpriority(PRIO_PROCESS, pid, out.requestedNice) != 0) {
        out.result = mapErrno(errno);
        out.osError = strerror(errno);
        return out;
    }

    out.actualNice = readNice(pid, ok); // verify the kernel really applied it
    if (!ok)
        out.actualNice = out.oldNice;

    out.result = out.actualNice == out.requestedNice
                     ? ActionResult::Success
                     : ActionResult::Failed;
    if (out.result == ActionResult::Failed)
        out.osError = "kernel did not confirm the new nice value";
    return out;
}

ActionOutcome ProcessController::sendSignal(pid_t pid, int signalNumber)
{
    ActionOutcome out;

    // Only the two lifecycle signals are ever allowed through.
    if (signalNumber != SIGSTOP && signalNumber != SIGCONT) {
        out.result = ActionResult::Failed;
        out.osError = "refusing signal other than SIGSTOP/SIGCONT";
        return out;
    }

    bool ok = false;
    out.oldNice = readNice(pid, ok); // also proves the process exists
    if (!ok) {
        out.result = mapErrno(errno);
        out.osError = strerror(errno);
        return out;
    }

    /*
     * OS CONCEPT - signals:
     * kill() is misleadingly named: it DELIVERS any signal. SIGSTOP/SIGCONT
     * are kernel-level (cannot be caught or ignored by the target), which
     * is exactly why we gate them behind manual confirmation.
     */
    if (kill(pid, signalNumber) != 0) {
        out.result = mapErrno(errno);
        out.osError = strerror(errno);
        return out;
    }

    out.result = ActionResult::Success;
    out.osError = signalNumber == SIGSTOP ? "SIGSTOP delivered"
                                          : "SIGCONT delivered";
    return out;
}
