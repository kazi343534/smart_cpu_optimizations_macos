#ifndef PROCESS_ANALYZER_H
#define PROCESS_ANALYZER_H

#include <sys/types.h>
#include <cstdint>
#include <string>
#include <vector>

#include "important_process.h"
#include "process_monitor.h"
#include "system_info.h"

/*
 * OS CONCEPT - turning raw measurements into decisions:
 * The kernel gives us percentages and bytes; the optimizer needs a single
 * comparable number per process. We compute TWO independent scores:
 *
 * 1) RESOURCE SCORE - "how much pressure does this process cause?"
 *      ResourceScore = 0.55*CPU% + 0.30*MEM% + 0.15*StateFactor
 *
 *    Weight justification:
 *    - CPU gets the LARGEST weight because it is the resource we can
 *      actually act on safely (nice values influence the BSD scheduler
 *      directly). Memory of a live process cannot be reclaimed without
 *      killing it.
 *    - Memory is second: big RSS indicates pressure but mostly RANKS
 *      candidates rather than drives action.
 *    - State is smallest: a RUNNING process causes more pressure than an
 *      identical SLEEPING one; zombies/stopped contribute nothing.
 *
 * 2) IMPORTANCE SCORE - "how dangerous would touching it be?" (0..100)
 *      protected by rules -> 100, nice<0 (user raised priority) -> 80,
 *      ordinary process -> 10.
 *
 * Both scores are derived ONLY from kernel-reported data.
 */
enum class ProcessClass {
    CriticalProtected, // never modify - show as protected
    ImportantActive,   // report/recommend only
    Normal,
    ResourceHeavy,     // prime optimization candidate
    BackgroundIdle     // leave alone, already low impact
};

std::string processClassName(ProcessClass cls);

/* Everything decided about one process, kept together for display+log. */
struct Analysis {
    pid_t pid = 0;
    std::string name;

    double cpuPercent = 0.0;
    uint64_t residentBytes = 0;

    double cpuNorm = 0.0;
    double memNorm = 0.0;
    double stateFactor = 0.0;
    double resourceScore = 0.0;

    int importanceScore = 0;
    std::string protectionReason;

    ProcessClass cls = ProcessClass::BackgroundIdle;
    bool eligibleForAction = false;
    double actionPriority = 0.0; // higher = better optimization candidate
};

class ProcessAnalyzer {
public:
    /* Calibration (see comments in process_analyzer.cpp for the math):
       one fully-busy core on this 8-core Mac = 12.5% machine capacity,
       so RS ~= 20 flags a dedicated single-core hog. */
    static constexpr double kHeavyResourceScore = 20.0;
    static constexpr double kNormalResourceScore = 12.0;
    static constexpr int kImportantImportance = 60;

    explicit ProcessAnalyzer(const SystemInfo &info);

    /* Analyses every process; caller supplies its own uid so we only ever
       mark processes WE are allowed to modify as eligible. */
    std::vector<Analysis> analyze(const std::vector<ProcessInfo> &processes,
                                  const ProcessProtector &protector,
                                  uid_t currentUid) const;

private:
    static double stateFactorOf(ProcessState state);
    static int importanceScoreOf(const ProcessInfo &p,
                                 const ProtectionVerdict &verdict);
    static ProcessClass classify(double resourceScore, int importanceScore,
                                 bool isProtected);

    uint64_t totalRamBytes_ = 1;
    int logicalCores_ = 1;
};

#endif
