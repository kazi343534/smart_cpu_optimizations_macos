#ifndef OPTIMIZER_H
#define OPTIMIZER_H

#include <sys/types.h>
#include <string>
#include <vector>

#include "activity_logger.h"
#include "important_process.h"
#include "process_analyzer.h"
#include "process_controller.h"
#include "process_monitor.h"
#include "resource_monitor.h"

/*
 * Action and verification outcome for one target process.
 */
struct TargetActionReport {
    pid_t pid = 0;
    std::string name;
    double cpuBefore = -1.0;
    double cpuAfter = -1.0;
    bool targetExited = false;
    double resourceScore = 0.0;
    int importanceScore = 0;
    std::string decisionReason;
    std::string actionDescription;
    std::string actionOutcome;
    bool success = false;
    std::string verdict;
};

/*
 * One complete optimization cycle result covering up to TOP 3 processes.
 * Everything the terminal UI or GUI needs to display WHAT was done and WHY.
 */
struct OptimizationReport {
    bool actionAttempted = false;
    bool observeOnly = false;       // cooldown active -> no actions this cycle
    bool targetExited = false;      // vanished before verification
    std::string targetName;
    pid_t targetPid = 0;

    std::string pressureLevel;      // NORMAL / ELEVATED / HIGH
    std::string decisionReason;     // why targets were chosen
    std::string actionDescription;  // what we attempted
    std::string actionOutcome;      // incl. raw OS error text on failure

    double sysCpuBefore = -1, sysCpuAfter = -1;
    double memUsedBefore = -1, memUsedAfter = -1;
    double targetCpuBefore = -1, targetCpuAfter = -1;

    bool success = false;
    std::string improvementVerdict;

    /* Up to TOP 3 optimized target details */
    std::vector<TargetActionReport> targets;

    /* Multi-line human-readable rendering shared by both frontends. */
    std::vector<std::string> lines() const;
};

/*
 * ADAPTIVE HYBRID RESOURCE-AWARE OPTIMIZER
 *
 * Cycle:
 *   measure BEFORE -> analyze -> pick target by ActionPriority ->
 *   apply safe renice -> measure AFTER -> compare -> log -> adapt
 *
 * Adaptation rules (all state changes are logged):
 *   - renice increment grows with consecutive failures (+2..+5)
 *   - 3 failures in a row => strategy demoted to OBSERVE-ONLY for 3 cycles
 *   - under HIGH pressure, NORMAL-class processes become eligible too
 */
class Optimizer {
public:
    Optimizer(ResourceMonitor &resources,
              ProcessMonitor &processes,
              ProcessProtector &protector,
              const ProcessAnalyzer &analyzer,
              ActivityLogger &logger);

    OptimizationReport runCycle(int intervalMs);

private:
    struct Pressure {
        std::string levelName;
        bool high = false;
    };
    static Pressure assessPressure(double sysCpuPercent, double memPercent);

    ResourceMonitor &resources_;
    ProcessMonitor &processes_;
    ProcessProtector &protector_;
    const ProcessAnalyzer &analyzer_;
    ActivityLogger &logger_;

    int consecutiveFailures_ = 0;
    int cooldownCyclesLeft_ = 0;
};

#endif
