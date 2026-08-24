#ifndef ACTIVITY_LOGGER_H
#define ACTIVITY_LOGGER_H

#include <string>
#include <vector>

/*
 * Optimization history / audit trail.
 * Every decision, action attempt and measured outcome is appended to a
 * log file with a wall-clock timestamp, so the project can PROVE that
 * real measurements happened (nothing exists only in memory).
 * A bounded copy stays in RAM for instant menu access.
 */
class ActivityLogger {
public:
    explicit ActivityLogger(const std::string &filePath);

    /* Appends one timestamped entry to file + history. */
    void record(const std::string &entry);

    const std::vector<std::string> &history() const { return history_; }

private:
    static std::string timestamp();

    std::string filePath_;
    std::vector<std::string> history_;
    static constexpr size_t kMaxInMemory = 500;
};

#endif
