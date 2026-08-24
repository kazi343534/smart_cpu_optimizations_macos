#include "optimizer.h"

#include <libproc.h>
#include <algorithm>
#include <cstdio>
#include <unistd.h>

namespace {

/*
 * OS CONCEPT - TOCTOU race on PID reuse:
 * Between the scan that selected this PID and the syscall we are about to
 * make, the OS may have recycled the PID for a DIFFERENT process
 * (PIDs are handed out round-robin). Acting blindly would modify an
 * innocent victim - potentially our own ancestor shell. Production-grade
 * tools therefore re-verify identity immediately before acting.
 */
bool identityMatches(pid_t pid, const std::string &expectedName)
{
    char pathBuf[PROC_PIDPATHINFO_MAXSIZE] {0};
    if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) <= 0)
        return false; // cannot confirm identity -> refuse

    const std::string path(pathBuf);
    const size_t slash = path.find_last_of('/');
    const std::string current =
        slash == std::string::npos ? path : path.substr(slash + 1);
    return current == expectedName;
}

} // namespace

std::vector<std::string> OptimizationReport::lines() const
{
    std::vector<std::string> out;
    char buf[160];

    std::snprintf(buf, sizeof(buf),
                  "System pressure      : %s", pressureLevel.c_str());
    out.push_back(buf);

    if (observeOnly) {
        out.push_back("Mode                 : OBSERVE-ONLY (adaptive cooldown)");
        return out;
    }

    if (!actionAttempted) {
        out.push_back("Decision             : no eligible optimization target");
        return out;
    }

    std::snprintf(buf, sizeof(buf), "Target               : %s (PID %d)",
                  targetName.c_str(), static_cast<int>(targetPid));
    out.push_back(buf);
    out.push_back("Why this process     : " + decisionReason);
    out.push_back("Action attempted     : " + actionDescription);
    out.push_back("OS result            : " + actionOutcome);

    if (!targetExited) {
        std::snprintf(buf, sizeof(buf),
                      "Target CPU  before   : %5.1f%%   after: %5.1f%%",
                      targetCpuBefore, targetCpuAfter);
        out.push_back(buf);
    }
    std::snprintf(buf, sizeof(buf),
                  "System CPU  before   : %5.1f%%   after: %5.1f%%",
                  sysCpuBefore, sysCpuAfter);
    out.push_back(buf);
    std::snprintf(buf, sizeof(buf),
                  "Memory used before   : %5.1f%%   after: %5.1f%%",
                  memUsedBefore, memUsedAfter);
    out.push_back(buf);

    out.push_back("Verdict              : " + improvementVerdict);
    return out;
}

Optimizer::Optimizer(ResourceMonitor &resources,
                     ProcessMonitor &processes,
                     ProcessProtector &protector,
                     const ProcessAnalyzer &analyzer,
                     ActivityLogger &logger)
    : resources_(resources)
    , processes_(processes)
    , protector_(protector)
    , analyzer_(analyzer)
    , logger_(logger)
{
}

Optimizer::Pressure Optimizer::assessPressure(double sysCpuPercent,
                                              double memPercent)
{
    /* Adaptive thresholds: the busier the machine, the more aggressively
       the optimizer is allowed to act. */
    Pressure p;
    if (sysCpuPercent >= 80.0 || memPercent >= 85.0) {
        p.levelName = "HIGH";
        p.high = true;
    } else if (sysCpuPercent >= 60.0 || memPercent >= 75.0) {
        p.levelName = "ELEVATED";
    } else {
        p.levelName = "NORMAL";
    }
    return p;
}

OptimizationReport Optimizer::runCycle(int intervalMs)
{
    OptimizationReport report;

    // ---- BEFORE: baseline pass + one real measurement window ----
    processes_.refresh(200); // establish CPU-time baselines

    report.sysCpuBefore = resources_.measureCpuUsage(intervalMs);
    processes_.refresh(intervalMs);

    MemoryInfo mem;
    resources_.readMemoryInfo(mem);
    report.memUsedBefore = mem.usedPercent();

    const Pressure pressure =
        assessPressure(report.sysCpuBefore, report.memUsedBefore);
    report.pressureLevel = pressure.levelName;

    // ---- ANALYZE everything we just measured ----
    const uid_t me = getuid();
    std::vector<Analysis> rows =
        analyzer_.analyze(processes_.processes(), protector_, me);

    // Adaptive eligibility: HIGH pressure widens the candidate pool from
    // RESOURCE-HEAVY down to NORMAL-class processes as well.
    const double minScore = pressure.high
                                ? ProcessAnalyzer::kNormalResourceScore
                                : ProcessAnalyzer::kHeavyResourceScore;

    const Analysis *target = nullptr;
    for (const Analysis &a : rows) {
        if (!a.eligibleForAction || a.resourceScore < minScore)
            continue;
        if (!target || a.actionPriority > target->actionPriority)
            target = &a;
    }

    // ---- OBSERVE-ONLY mode during adaptive cooldown ----
    if (cooldownCyclesLeft_ > 0) {
        --cooldownCyclesLeft_;
        report.observeOnly = true;
        logger_.record("cycle: observe-only (cooldown " +
                       std::to_string(cooldownCyclesLeft_) + " left), pressure=" +
                       pressure.levelName);
        return report;
    }

    if (!target) {
        report.decisionReason = pressure.high
                                    ? "even relaxed threshold met nothing eligible"
                                    : "no RESOURCE-HEAVY eligible process";
        logger_.record("cycle: no action (" + report.decisionReason +
                       "), pressure=" + pressure.levelName);
        return report;
    }

    report.actionAttempted = true;
    report.targetPid = target->pid;
    report.targetName = target->name;
    report.targetCpuBefore = target->cpuPercent;
    report.decisionReason =
        "class=" + processClassName(target->cls) +
        ", ResourceScore=" + std::to_string(target->resourceScore).substr(0, 5) +
        ", Importance=" + std::to_string(target->importanceScore) +
        ", highest ActionPriority among eligible";

    // ---- ACTION: deprioritise only, increment grows with failures ----
    const int increment = std::min(2 + consecutiveFailures_, 5);
    report.actionDescription =
        "setpriority(PRIO_PROCESS, " + std::to_string(target->pid) +
        ") nice +" + std::to_string(increment) +
        " (lower scheduling priority)";

    // TOCTOU guard: re-verify the target's identity right before acting.
    if (!identityMatches(target->pid, target->name)) {
        report.actionOutcome =
            "ABORTED - PID identity changed since scan (PID reuse); "
            "refusing to act on an unverified process";
        report.improvementVerdict = "action aborted for safety";
        logger_.record("aborted: pid=" + std::to_string(report.targetPid) +
                       " failed identity re-check (suspected PID reuse)");
        return report;
    }

    const ActionOutcome outcome =
        ProcessController::raiseNice(target->pid, increment);

    switch (outcome.result) {
    case ActionResult::Success:
        report.actionOutcome = "SUCCESS - nice changed " +
                               std::to_string(outcome.oldNice) + " -> " +
                               std::to_string(outcome.actualNice) +
                               " (verified by read-back)";
        break;
    case ActionResult::PermissionDenied:
        report.actionOutcome =
            "PERMISSION DENIED - macOS refused to modify this process (" +
            outcome.osError + ")";
        break;
    case ActionResult::ProcessGone:
        report.actionOutcome = "process exited before action (" +
                               outcome.osError + ")";
        break;
    default:
        report.actionOutcome = "FAILED - " + outcome.osError;
    }

    // ---- AFTER: second real measurement window ----
    report.sysCpuAfter = resources_.measureCpuUsage(intervalMs);
    processes_.refresh(intervalMs);
    resources_.readMemoryInfo(mem);
    report.memUsedAfter = mem.usedPercent();

    // Re-analyze the AFTER scan to locate the target's fresh numbers.
    std::vector<Analysis> afterRows =
        analyzer_.analyze(processes_.processes(), protector_, me);
    const Analysis *afterTarget = nullptr;
    for (const Analysis &a : afterRows)
        if (a.pid == target->pid)
            afterTarget = &a;

    bool targetImproved = false;
    if (!afterTarget) {
        report.targetExited = true;
        report.targetCpuAfter = -1;
    } else {
        report.targetCpuAfter = afterTarget->cpuPercent;
        if (report.targetCpuAfter <= report.targetCpuBefore * 0.8)
            targetImproved = true; // >=20% relative drop
    }
    const bool systemImproved = report.sysCpuAfter < report.sysCpuBefore - 1.0;

    // ---- VERDICT + ADAPTATION ----
    if (outcome.result != ActionResult::Success) {
        report.improvementVerdict = "action not applied - nothing to verify";
        report.success = false;
        ++consecutiveFailures_; // permission errors count toward back-off too
    } else if (report.targetExited) {
        report.improvementVerdict =
            "target exited after renice - load resolved (cannot attribute)";
        report.success = true;
        consecutiveFailures_ = 0;
    } else if (targetImproved) {
        report.improvementVerdict =
            "IMPROVED - target CPU fell >=20% relative";
        report.success = true;
        consecutiveFailures_ = 0;
    } else if (systemImproved) {
        report.improvementVerdict =
            "PARTIAL - system-wide CPU fell, target unchanged";
        report.success = true;
        consecutiveFailures_ = 0;
    } else {
        report.improvementVerdict =
            "NO MEASURABLE IMPROVEMENT - strategy stays under watch";
        report.success = false;
        ++consecutiveFailures_;
    }

    if (consecutiveFailures_ >= 3) {
        cooldownCyclesLeft_ = 3;
        report.improvementVerdict +=
            " | adaptive back-off: observe-only for next cycles";
        consecutiveFailures_ = 0;
    }

    logger_.record(
        "optimization: pid=" + std::to_string(report.targetPid) + " (" +
        report.targetName + ") action=[" + report.actionDescription +
        "] result=[" + report.actionOutcome + "]" +
        " sysCPU " + std::to_string(report.sysCpuBefore).substr(0, 5) + "->" +
        std::to_string(report.sysCpuAfter).substr(0, 5) +
        " verdict=" + report.improvementVerdict);
    return report;
}
