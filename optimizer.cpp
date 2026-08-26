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
    char buf[180];

    std::snprintf(buf, sizeof(buf),
                  "System pressure      : %s", pressureLevel.c_str());
    out.push_back(buf);

    if (observeOnly) {
        out.push_back("Mode                 : OBSERVE-ONLY (adaptive cooldown)");
        return out;
    }

    if (!actionAttempted || targets.empty()) {
        out.push_back("Decision             : no eligible unrestricted optimization targets found");
        return out;
    }

    std::snprintf(buf, sizeof(buf),
                  "Optimized targets    : %zu processes (Top 3 Priority)",
                  targets.size());
    out.push_back(buf);

    for (size_t i = 0; i < targets.size(); ++i) {
        const auto &t = targets[i];
        std::snprintf(buf, sizeof(buf),
                      "\n[Target %zu/%zu]        : %s (PID %d)",
                      i + 1, targets.size(), t.name.c_str(), static_cast<int>(t.pid));
        out.push_back(buf);
        out.push_back("  Why this process   : " + t.decisionReason);
        out.push_back("  Action attempted   : " + t.actionDescription);
        out.push_back("  OS result          : " + t.actionOutcome);

        if (!t.targetExited) {
            std::snprintf(buf, sizeof(buf),
                          "  Target CPU         : %5.1f%% before -> %5.1f%% after",
                          t.cpuBefore, t.cpuAfter);
            out.push_back(buf);
        } else {
            out.push_back("  Target CPU         : process exited during optimization");
        }
        out.push_back("  Target verdict     : " + t.verdict);
    }

    out.push_back("");
    std::snprintf(buf, sizeof(buf),
                  "System CPU           : %5.1f%% before -> %5.1f%% after",
                  sysCpuBefore, sysCpuAfter);
    out.push_back(buf);
    std::snprintf(buf, sizeof(buf),
                  "Memory used          : %5.1f%% before -> %5.1f%% after",
                  memUsedBefore, memUsedAfter);
    out.push_back(buf);

    out.push_back("Overall cycle verdict: " + improvementVerdict);
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

    // Filter all eligible unrestricted candidates
    std::vector<Analysis> candidates;
    for (const Analysis &a : rows) {
        if (a.eligibleForAction) {
            candidates.push_back(a);
        }
    }

    // Sort candidates by ActionPriority descending, then by CPU% descending
    std::sort(candidates.begin(), candidates.end(),
              [](const Analysis &x, const Analysis &y) {
                  if (x.actionPriority != y.actionPriority)
                      return x.actionPriority > y.actionPriority;
                  return x.cpuPercent > y.cpuPercent;
              });

    // ---- OBSERVE-ONLY mode during adaptive cooldown ----
    if (cooldownCyclesLeft_ > 0) {
        --cooldownCyclesLeft_;
        report.observeOnly = true;
        logger_.record("cycle: observe-only (cooldown " +
                       std::to_string(cooldownCyclesLeft_) + " left), pressure=" +
                       pressure.levelName);
        return report;
    }

    if (candidates.empty()) {
        report.decisionReason = "no eligible unrestricted processes found";
        logger_.record("cycle: no action (" + report.decisionReason +
                       "), pressure=" + pressure.levelName);
        return report;
    }

    // Select up to TOP 3 processes
    const size_t topCount = std::min<size_t>(candidates.size(), 3);
    const int increment = std::min(2 + consecutiveFailures_, 5);

    report.actionAttempted = true;

    for (size_t i = 0; i < topCount; ++i) {
        const Analysis &target = candidates[i];
        TargetActionReport tReport;
        tReport.pid = target.pid;
        tReport.name = target.name;
        tReport.cpuBefore = target.cpuPercent;
        tReport.resourceScore = target.resourceScore;
        tReport.importanceScore = target.importanceScore;
        tReport.decisionReason =
            "class=" + processClassName(target.cls) +
            ", ResourceScore=" + std::to_string(target.resourceScore).substr(0, 5) +
            ", Importance=" + std::to_string(target.importanceScore) +
            " (Rank #" + std::to_string(i + 1) + " Priority)";

        tReport.actionDescription =
            "setpriority(PRIO_PROCESS, " + std::to_string(target.pid) +
            ") nice +" + std::to_string(increment) +
            " (lower scheduling priority)";

        // TOCTOU guard: re-verify identity immediately before acting
        if (!identityMatches(target.pid, target.name)) {
            tReport.actionOutcome =
                "ABORTED - PID identity changed since scan (PID reuse); "
                "refusing to act on an unverified process";
            tReport.verdict = "aborted for safety";
            tReport.success = false;
            logger_.record("aborted: pid=" + std::to_string(target.pid) +
                           " failed identity re-check (suspected PID reuse)");
            report.targets.push_back(tReport);
            continue;
        }

        const ActionOutcome outcome =
            ProcessController::raiseNice(target.pid, increment);

        switch (outcome.result) {
        case ActionResult::Success:
            tReport.actionOutcome = "SUCCESS - nice changed " +
                                   std::to_string(outcome.oldNice) + " -> " +
                                   std::to_string(outcome.actualNice) +
                                   " (verified by read-back)";
            tReport.success = true;
            break;
        case ActionResult::PermissionDenied:
            tReport.actionOutcome =
                "PERMISSION DENIED - macOS refused to modify this process (" +
                outcome.osError + ")";
            tReport.success = false;
            break;
        case ActionResult::ProcessGone:
            tReport.actionOutcome = "process exited before action (" +
                                   outcome.osError + ")";
            tReport.success = false;
            break;
        default:
            tReport.actionOutcome = "FAILED - " + outcome.osError;
            tReport.success = false;
        }

        report.targets.push_back(tReport);
    }

    // Set primary summary fields from the top 1 target for backward-compatibility
    if (!report.targets.empty()) {
        report.targetPid = report.targets[0].pid;
        report.targetName = report.targets[0].name;
        report.targetCpuBefore = report.targets[0].cpuBefore;
        report.decisionReason = report.targets[0].decisionReason;
        report.actionDescription = report.targets[0].actionDescription;
        report.actionOutcome = report.targets[0].actionOutcome;
    }

    // ---- AFTER: second real measurement window ----
    report.sysCpuAfter = resources_.measureCpuUsage(intervalMs);
    processes_.refresh(intervalMs);
    resources_.readMemoryInfo(mem);
    report.memUsedAfter = mem.usedPercent();

    // Re-analyze the AFTER scan to locate fresh numbers for each target
    std::vector<Analysis> afterRows =
        analyzer_.analyze(processes_.processes(), protector_, me);

    size_t successActionCount = 0;

    for (TargetActionReport &t : report.targets) {
        const Analysis *afterTarget = nullptr;
        for (const Analysis &a : afterRows) {
            if (a.pid == t.pid) {
                afterTarget = &a;
                break;
            }
        }

        if (!afterTarget) {
            t.targetExited = true;
            t.cpuAfter = -1.0;
            t.verdict = "EXITED - load resolved";
            t.success = true;
            ++successActionCount;
        } else {
            t.cpuAfter = afterTarget->cpuPercent;
            if (t.cpuAfter <= t.cpuBefore * 0.8 && t.cpuBefore > 1.0) {
                t.verdict = "IMPROVED - target CPU fell >=20% relative";
                t.success = true;
                ++successActionCount;
            } else if (t.actionOutcome.find("SUCCESS") != std::string::npos) {
                t.verdict = "STABLE - priority lowered, load monitored";
                t.success = true;
                ++successActionCount;
            } else {
                t.verdict = "UNMODIFIED - " + t.actionOutcome;
                t.success = false;
            }
        }
    }

    if (!report.targets.empty()) {
        report.targetCpuAfter = report.targets[0].cpuAfter;
        report.targetExited = report.targets[0].targetExited;
    }

    const bool systemImproved = report.sysCpuAfter < report.sysCpuBefore - 1.0;

    // ---- OVERALL VERDICT + ADAPTATION ----
    if (successActionCount > 0 || systemImproved) {
        report.success = true;
        consecutiveFailures_ = 0;
        char vBuf[128];
        std::snprintf(vBuf, sizeof(vBuf),
                      "IMPROVED - %zu/%zu targets optimized successfully%s",
                      successActionCount, report.targets.size(),
                      systemImproved ? ", system CPU dropped" : "");
        report.improvementVerdict = vBuf;
    } else {
        report.success = false;
        ++consecutiveFailures_;
        report.improvementVerdict = "NO MEASURABLE IMPROVEMENT - strategy under watch";
    }

    if (consecutiveFailures_ >= 3) {
        cooldownCyclesLeft_ = 3;
        report.improvementVerdict +=
            " | adaptive back-off: observe-only for next cycles";
        consecutiveFailures_ = 0;
    }

    std::string targetSummary;
    for (const auto &t : report.targets) {
        targetSummary += t.name + "(PID " + std::to_string(t.pid) + ", " +
                         std::to_string(t.cpuBefore).substr(0, 4) + "%->" +
                         std::to_string(t.cpuAfter).substr(0, 4) + "%) ";
    }

    logger_.record(
        "optimization [Top " + std::to_string(report.targets.size()) + "]: " +
        targetSummary + " sysCPU " + std::to_string(report.sysCpuBefore).substr(0, 5) + "->" +
        std::to_string(report.sysCpuAfter).substr(0, 5) +
        " verdict=" + report.improvementVerdict);

    return report;
}
