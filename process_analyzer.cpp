#include "process_analyzer.h"

#include <algorithm>

std::string processClassName(ProcessClass cls)
{
    switch (cls) {
    case ProcessClass::CriticalProtected: return "CRITICAL/PROTECTED";
    case ProcessClass::ImportantActive:   return "IMPORTANT/ACTIVE";
    case ProcessClass::ResourceHeavy:     return "RESOURCE-HEAVY";
    case ProcessClass::Normal:            return "NORMAL";
    case ProcessClass::BackgroundIdle:    return "BACKGROUND/IDLE";
    }
    return "?";
}

ProcessAnalyzer::ProcessAnalyzer(const SystemInfo &info)
{
    totalRamBytes_ = info.totalPhysicalBytes > 0 ? info.totalPhysicalBytes : 1;
    logicalCores_ = info.logicalCpuCores > 0 ? info.logicalCpuCores : 1;
}

double ProcessAnalyzer::stateFactorOf(ProcessState state)
{
    switch (state) {
    case ProcessState::Running: return 100.0; // actively consuming cycles
    case ProcessState::Sleeping: return 25.0; // idle, mostly holding RAM
    case ProcessState::Stopped:  return 0.0;  // suspended by a signal
    case ProcessState::Zombie:   return 0.0;  // dead, awaiting reaping
    default:                     return 50.0; // unknown - middle ground
    }
}

int ProcessAnalyzer::importanceScoreOf(const ProcessInfo &p,
                                       const ProtectionVerdict &verdict)
{
    if (verdict.protectedProcess)
        return 100; // untouchable

    /*
     * A NEGATIVE nice value means someone deliberately gave this process
     * HIGHER scheduling priority - the optimizer must respect that wish.
     * Everything else starts at low importance (it is just a program).
     */
    if (p.nice < 0)
        return 80;

    return 10;
}

ProcessClass ProcessAnalyzer::classify(double resourceScore,
                                       int importanceScore, bool isProtected)
{
    if (isProtected)
        return ProcessClass::CriticalProtected;
    if (importanceScore >= kImportantImportance)
        return ProcessClass::ImportantActive;
    if (resourceScore >= kHeavyResourceScore)
        return ProcessClass::ResourceHeavy;
    if (resourceScore >= kNormalResourceScore)
        return ProcessClass::Normal;
    return ProcessClass::BackgroundIdle;
}

std::vector<Analysis> ProcessAnalyzer::analyze(
    const std::vector<ProcessInfo> &processes,
    const ProcessProtector &protector,
    uid_t currentUid) const
{
    std::vector<Analysis> results;
    results.reserve(processes.size());

    for (const ProcessInfo &p : processes) {
        Analysis a;
        a.pid = p.pid;
        a.name = p.name;
        a.cpuPercent = p.cpuPercent;
        a.residentBytes = p.residentBytes;

        // ---- normalise raw measurements to 0..100 scales ----
        a.cpuNorm = std::clamp(p.cpuPercent < 0 ? 0.0 : p.cpuPercent, 0.0, 100.0);
        a.memNorm = 100.0 * static_cast<double>(p.residentBytes) /
                    static_cast<double>(totalRamBytes_);
        a.stateFactor = stateFactorOf(p.state);

        a.resourceScore = 0.55 * a.cpuNorm + 0.30 * a.memNorm +
                          0.15 * a.stateFactor;

        const ProtectionVerdict verdict = protector.check(p);
        a.protectionReason = verdict.reason;
        a.importanceScore = importanceScoreOf(p, verdict);

        a.cls = classify(a.resourceScore, a.importanceScore,
                         verdict.protectedProcess);

        /*
         * Eligibility for REAL actions:
         * - protection verdict forbids protected processes
         * - zombies must never be signalled (their parent must reap them)
         * - incomplete data means we would act blindly - refuse
         * - macOS only permits nice changes on YOUR OWN processes
         */
        a.eligibleForAction = !verdict.protectedProcess &&
                              p.completeData &&
                              p.cpuPercent >= 0.0 &&
                              p.state != ProcessState::Zombie &&
                              p.ownerId == currentUid;

        a.actionPriority = a.eligibleForAction
                               ? a.resourceScore * (1.0 - a.importanceScore / 100.0)
                               : 0.0;

        results.push_back(std::move(a));
    }

    return results;
}
