/*
 * SMART PROCESS OPTIMIZER - CSE323 project
 * Terminal front-end: colored tables, Unicode bar graphs, live dashboard,
 * manual signal control (SIGSTOP/SIGCONT), adaptive optimization.
 * The native GUI front-end lives in gui_main.mm; both drive the same engine.
 */

#include <algorithm>
#include <csignal>
#include <cstdio>
#include <iostream>
#include <unistd.h>
#include <vector>

#include "activity_logger.h"
#include "important_process.h"
#include "optimizer.h"
#include "process_analyzer.h"
#include "process_controller.h"
#include "process_monitor.h"
#include "resource_monitor.h"
#include "system_info.h"

namespace ui {

// ---------- ANSI colors ----------
constexpr const char *RESET = "\033[0m";
constexpr const char *BOLD  = "\033[1m";
constexpr const char *DIM   = "\033[2m";
constexpr const char *CYAN  = "\033[1;36m";
constexpr const char *GREEN = "\033[1;32m";
constexpr const char *YELL  = "\033[1;33m";
constexpr const char *RED   = "\033[1;31m";

inline std::string paint(const std::string &s, const char *color)
{
    return std::string(color) + s + RESET;
}

// ---------- Unicode bar graph ----------
inline std::string bar(double percent, int width)
{
    if (percent < 0)
        return std::string(width, '-');
    double clamped = std::clamp(percent, 0.0, 100.0);
    int filled = static_cast<int>(clamped / 100.0 * width + 0.5);
    filled = std::clamp(filled, 0, width);
    std::string out;
    out.reserve(width * 3);
    for (int i = 0; i < filled; ++i)
        out += "\u2588"; // full block
    for (int i = filled; i < width; ++i)
        out += "\u2591"; // light shade
    return out;
}

inline void clearScreen()
{
    std::cout << "\033[2J\033[H";
}

} // namespace ui

namespace {

constexpr double kMegabyte = 1024.0 * 1024.0;
constexpr double kGigabyte = 1024.0 * 1024.0 * 1024.0;

struct Engine {
    explicit Engine(const SystemInfo &si)
        : info(si)
        , protector(getpid())
        , analyzer(info)
        , logger("smart_optimizer_activity.log")
        , optimizer(resources, processes, protector, analyzer, logger)
    {
    }

    SystemInfo info;
    ResourceMonitor resources;
    ProcessMonitor processes;
    ProcessProtector protector;
    ProcessAnalyzer analyzer;
    ActivityLogger logger;
    Optimizer optimizer;

    bool init() { return resources.initialize(info) && processes.initialize(info); }
};

bool scanOnce(Engine &e, int intervalMs)
{
    e.processes.refresh(200);
    e.resources.measureCpuUsage(intervalMs);
    return e.processes.refresh(intervalMs);
}

void printBanner(const SystemInfo &info)
{
    const std::string rule = [](int n) {
        std::string s;
        for (int i = 0; i < n; ++i)
            s += "\u2550";
        return s;
    }(42);
    const std::string top = "\u2554" + rule + "\u2557";
    const std::string bot = "\u255A" + rule + "\u255D";
    auto row = [](const std::string &text) {
        const int pad = 42 - static_cast<int>(text.size());
        const int left = pad / 2;
        return "\u2551" + std::string(left, ' ') + text +
               std::string(pad - left, ' ') + "\u2551";
    };

    std::cout << "\n"
              << ui::paint(top, ui::CYAN) << "\n"
              << ui::paint(row("SMART PROCESS OPTIMIZER"), ui::CYAN) << "\n"
              << ui::paint(row("CSE323 - real OS optimization"), ui::CYAN)
              << "\n"
              << ui::paint(bot, ui::CYAN) << "\n"
              << ui::DIM << " " << info.model << " | "
              << info.logicalCpuCores << " cores | "
              << info.totalPhysicalBytes / kGigabyte << " GB RAM"
              << ui::RESET << "\n";
}

/* ---------------- menu actions ---------------- */

void menuViewProcesses(Engine &e)
{
    if (!scanOnce(e, 1000)) {
        std::cerr << ui::paint("ERROR: process table unavailable", ui::RED) << "\n";
        return;
    }
    std::vector<ProcessInfo> rows = e.processes.processes();
    std::sort(rows.begin(), rows.end(),
              [](const ProcessInfo &a, const ProcessInfo &b) {
                  return a.cpuPercent > b.cpuPercent;
              });

    MemoryInfo mem;
    e.resources.readMemoryInfo(mem);

    std::printf("\n%s%-7s %-5s %-9s %-4s %6s %-26s %9s%s\n",
                ui::BOLD, "PID", "UID", "STATE", "NICE", "CPU%", "CPU GRAPH",
                "MEM(MB)", ui::RESET);

    for (size_t i = 0; i < rows.size() && i < 25; ++i) {
        char cpuBuf[12];
        if (rows[i].cpuPercent < 0)
            snprintf(cpuBuf, sizeof(cpuBuf), "%5s", "-");
        else
            snprintf(cpuBuf, sizeof(cpuBuf), "%4.1f%%", rows[i].cpuPercent);

        const char *stateColor =
            rows[i].state == ProcessState::Running ? ui::GREEN : ui::DIM;

        std::printf("%-7d %-5d %s%-9s%s %-4d %6s %-26s %9.1f%s\n",
                    rows[i].pid, static_cast<int>(rows[i].ownerId),
                    stateColor,
                    processStateName(rows[i].state).c_str(), ui::RESET,
                    rows[i].nice, cpuBuf,
                    ui::bar(rows[i].cpuPercent, 24).c_str(),
                    rows[i].residentBytes / kMegabyte,
                    rows[i].completeData ? "" : " [partial]");
    }
    std::printf("%s%zu processes total | RAM used %.1f%%%s\n",
                ui::DIM, e.processes.count(), mem.usedPercent(), ui::RESET);
}

void menuAnalyzeResources(Engine &e)
{
    if (!scanOnce(e, 1000))
        return;
    const uid_t me = getuid();
    std::vector<Analysis> rows =
        e.analyzer.analyze(e.processes.processes(), e.protector, me);
    std::sort(rows.begin(), rows.end(),
              [](const Analysis &a, const Analysis &b) {
                  return a.actionPriority > b.actionPriority;
              });

    std::printf("\n%s%-22s %-7s %6s %8s %5s %4s %-17s%s\n",
                ui::BOLD, "NAME", "PID", "CPU%", "MEM(MB)", "RS", "IMP",
                "CLASS", ui::RESET);
    for (size_t i = 0; i < rows.size() && i < 15; ++i) {
        const Analysis &a = rows[i];
        const char *clsColor =
            a.cls == ProcessClass::CriticalProtected ? ui::RED :
            a.cls == ProcessClass::ResourceHeavy     ? ui::YELL :
            a.cls == ProcessClass::ImportantActive   ? ui::CYAN :
                                                       ui::DIM;
        std::string cls = processClassName(a.cls);
        std::printf("%-22s %-7d %5.1f %8.1f %5.1f %4d %s%s\n",
                    a.name.substr(0, 22).c_str(), a.pid, a.cpuNorm,
                    a.residentBytes / kMegabyte, a.resourceScore,
                    a.importanceScore,
                    ui::paint(cls.substr(0, 17), clsColor).c_str(),
                    (i == 0 && a.actionPriority > 0)
                        ? ui::paint("  <= candidate", ui::GREEN).c_str() : "");
    }
}

void menuRunOptimization(Engine &e)
{
    std::cout << "\nRunning one adaptive optimization cycle...\n";
    OptimizationReport report = e.optimizer.runCycle(1000);
    std::cout << "\n"
              << ui::paint("\u2500 OPTIMIZATION ANALYSIS "
                           "\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500"
                           "\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500"
                           "\u2500\u2500\u2500\u2500", ui::CYAN)
              << "\n";
    for (const std::string &line : report.lines()) {
        const char *color = ui::RESET;
        if (line.find("IMPROVED") != std::string::npos &&
            line.find("NO ") == std::string::npos)
            color = ui::GREEN;
        else if (line.find("PARTIAL") != std::string::npos)
            color = ui::YELL;
        else if (line.find("NO MEASURABLE") != std::string::npos ||
                 line.find("PERMISSION") != std::string::npos ||
                 line.find("FAILED") != std::string::npos)
            color = ui::RED;
        else if (line.rfind("Target ", 0) == 0 ||
                 line.rfind("Why this", 0) == 0)
            color = ui::BOLD;
        std::cout << ui::paint(line, color) << "\n";
    }
}

void menuHistory(Engine &e)
{
    const auto &h = e.logger.history();
    std::cout << "\n"
              << ui::paint("\u2500 ACTIVITY LOG (" +
                               std::to_string(h.size()) + " entries) ",
                           ui::CYAN)
              << "\n";
    size_t start = h.size() > 20 ? h.size() - 20 : 0;
    for (size_t i = start; i < h.size(); ++i)
        std::cout << h[i] << "\n";
    if (h.empty())
        std::cout << "(empty - run Smart Optimization first)\n";
}

void menuSystemResources(Engine &e)
{
    double load[3] = {0, 0, 0};
    getloadavg(load, 3);
    const double cpu = e.resources.measureCpuUsage(1000);
    MemoryInfo mem;
    if (!e.resources.readMemoryInfo(mem)) {
        std::cerr << ui::paint("ERROR: memory statistics unavailable", ui::RED) << "\n";
        return;
    }

    std::cout << "\n" << ui::paint("SYSTEM RESOURCE OVERVIEW", ui::BOLD) << "\n";
    std::cout << "  CPU " << ui::bar(cpu, 30) << " "
              << cpu << "%\n";
    std::cout << "  RAM " << ui::bar(mem.usedPercent(), 30) << " "
              << mem.usedPercent() << "%\n\n";
    std::printf("  load avg      : %.2f %.2f %.2f\n", load[0], load[1], load[2]);
    std::printf("  active/wired  : %.0f MB / %.0f MB\n",
                mem.activeBytes / kMegabyte, mem.wiredBytes / kMegabyte);
    std::printf("  inactive/free : %.0f MB / %.0f MB\n",
                mem.inactiveBytes / kMegabyte, mem.freeBytes / kMegabyte);
    std::printf("  compressed    : %.0f MB\n", mem.compressedBytes / kMegabyte);
}

void menuLiveDashboard(Engine &e)
{
    std::cout << "\nDashboard ticks (~2 s each). How many ticks? [default 8]: ";
    int ticks = 8;
    if (!(std::cin >> ticks))
        return;
    ticks = std::clamp(ticks, 1, 60);

    std::vector<double> cpuHist;
    for (int t = 0; t < ticks; ++t) {
        const double cpu = e.resources.measureCpuUsage(1000);
        if (!e.processes.refresh(1000))
            break;
        MemoryInfo mem;
        e.resources.readMemoryInfo(mem);

        cpuHist.push_back(cpu);
        if (cpuHist.size() > 14)
            cpuHist.erase(cpuHist.begin());

        ui::clearScreen();
        std::cout << ui::paint("\u2554\u2550 LIVE DASHBOARD "
                               "(\u2551/q then Enter to stop)\u2550\u2557",
                               ui::CYAN)
                  << "\n";

        char line[96];
        snprintf(line, sizeof(line), " CPU %s %5.1f%%", "", cpu);
        std::cout << " CPU " << ui::bar(cpu, 40) << " "
                  << ui::paint(std::to_string(cpu).substr(0, 5) + "%", ui::GREEN)
                  << "   RAM "
                  << ui::bar(mem.usedPercent(), 20) << " "
                  << std::to_string(mem.usedPercent()).substr(0, 5) << "%\n";
        std::cout << ui::paint(" CPU history (oldest -> newest):", ui::DIM)
                  << "\n";
        int idx = 0;
        for (double c : cpuHist) {
            snprintf(line, sizeof(line), "  t-%-2ld %s %5.1f%%",
                    static_cast<long>(cpuHist.size() - 1 - idx),
                    ui::bar(c, 28).c_str(), c);
            std::cout << line << "\n";
            ++idx;
        }

        std::vector<ProcessInfo> rows = e.processes.processes();
        std::sort(rows.begin(), rows.end(),
                  [](const ProcessInfo &a, const ProcessInfo &b) {
                      return a.cpuPercent > b.cpuPercent;
                  });
        std::cout << ui::paint(" Top processes now:", ui::DIM) << "\n";
        for (size_t i = 0; i < rows.size() && i < 5; ++i) {
            snprintf(line, sizeof(line), "  %-20s %7.1f%%  %s",
                     rows[i].name.substr(0, 20).c_str(), rows[i].cpuPercent,
                     "");
            std::cout << line << ui::bar(rows[i].cpuPercent, 16) << "\n";
        }
        std::cout << ui::DIM << " tick " << t + 1 << "/" << ticks
                  << ui::RESET << "\n";
    }
    std::cout << ui::paint("(dashboard ended)", ui::DIM) << "\n";
}

void menuControlProcess(Engine &e)
{
    /*
     * MANUAL signal control - the strongest action we allow.
     * Safety gates: protection verdict first, then the kernel itself is
     * the final authority (EPERM surfaces verbatim for foreign PIDs).
     */
    if (!scanOnce(e, 800)) {
        std::cerr << ui::paint("scan failed", ui::RED) << "\n";
        return;
    }

    std::vector<ProcessInfo> mine;
    for (const ProcessInfo &p : e.processes.processes())
        if (p.ownerId == getuid() && p.state != ProcessState::Zombie)
            mine.push_back(p);
    std::sort(mine.begin(), mine.end(),
              [](const ProcessInfo &a, const ProcessInfo &b) {
                  return a.cpuPercent > b.cpuPercent;
              });

    std::cout << "\nYour busiest processes:\n";
    for (size_t i = 0; i < mine.size() && i < 10; ++i)
        std::printf("  %-7d %-22s %-9s\n", mine[i].pid,
                    mine[i].name.substr(0, 22).c_str(),
                    processStateName(mine[i].state).c_str());

    std::cout << "\nPID to control (0=cancel): ";
    long pid = 0;
    if (!(std::cin >> pid) || pid <= 0)
        return;

    const ProcessInfo *target = nullptr;
    for (const ProcessInfo &p : mine)
        if (p.pid == static_cast<pid_t>(pid))
            target = &p;
    if (!target) {
        std::cout << ui::paint("PID not among your visible processes.", ui::YELL)
                  << "\n";
        return;
    }

    ProtectionVerdict verdict = e.protector.check(*target);
    if (verdict.protectedProcess) {
        std::cout << ui::paint("REFUSED - protected: " + verdict.reason, ui::RED)
                  << "\n";
        return;
    }

    std::cout << "[s]uspend (SIGSTOP) or [r]esume (SIGCONT)? ";
    char choice = ' ';
    std::cin >> choice;
    int sig = (choice == 's') ? SIGSTOP : (choice == 'r') ? SIGCONT : -1;
    if (sig != SIGSTOP && sig != SIGCONT) {
        std::cout << "Invalid choice.\n";
        return;
    }

    ActionOutcome out = ProcessController::sendSignal(target->pid, sig);
    if (out.result == ActionResult::Success) {
        std::cout << ui::paint(std::string("OS result: ") + out.osError,
                               ui::GREEN) << "\n";
        // Verify with a fresh kernel read: did the state really change?
        e.processes.refresh(600);
        for (const ProcessInfo &p : e.processes.processes()) {
            if (p.pid == target->pid) {
                std::cout << "Kernel-verified state now: "
                          << ui::paint(processStateName(p.state),
                                       p.state == ProcessState::Stopped
                                           ? ui::YELL : ui::GREEN)
                          << "\n";
                e.logger.record("manual signal: pid=" + std::to_string(pid) +
                                " (" + target->name + ") " + out.osError +
                                " -> state=" + processStateName(p.state));
                break;
            }
        }
    } else {
        std::cout << ui::paint("OS refused: " + out.osError, ui::RED) << "\n";
        e.logger.record("manual signal FAILED: pid=" + std::to_string(pid) +
                        " " + out.osError);
    }
    std::cout << ui::DIM << "Tip: a suspended process shows 0% CPU and holds "
                           "its RAM; resume it to continue." << ui::RESET << "\n";
}

} // namespace

int main()
{
    SystemInfo info;
    if (!loadSystemInfo(info)) {
        std::fprintf(stderr, "ERROR: could not read hardware facts.\n");
        return 1;
    }

    Engine engine(info);
    if (!engine.init()) {
        std::fprintf(stderr, "ERROR: could not initialise monitoring.\n");
        return 1;
    }

    while (true) {
        printBanner(engine.info);
        std::cout
            << " " << ui::paint("[1]", ui::CYAN) << " View Processes"
            << "   " << ui::paint("[2]", ui::CYAN) << " Analyze Resources"
            << "   " << ui::paint("[3]", ui::CYAN) << " Smart Optimization\n"
            << " " << ui::paint("[4]", ui::CYAN) << " History"
            << "         " << ui::paint("[5]", ui::CYAN)
            << " System Resources " << ui::paint("[6]", ui::CYAN)
            << " Live Dashboard\n"
            << " " << ui::paint("[7]", ui::CYAN) << " Control Process"
            << "  " << ui::paint("[8]", ui::CYAN) << " Exit\n"
            << " Choice: ";

        int choice = 0;
        if (!(std::cin >> choice))
            break;

        switch (choice) {
        case 1: menuViewProcesses(engine); break;
        case 2: menuAnalyzeResources(engine); break;
        case 3: menuRunOptimization(engine); break;
        case 4: menuHistory(engine); break;
        case 5: menuSystemResources(engine); break;
        case 6: menuLiveDashboard(engine); break;
        case 7: menuControlProcess(engine); break;
        case 8: std::cout << "Bye.\n"; return 0;
        default: std::cout << "Unknown option.\n"; break;
        }
    }
    return 0;
}
