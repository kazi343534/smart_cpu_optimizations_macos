#include "activity_logger.h"

#include <ctime>
#include <fstream>
#include <iostream>

ActivityLogger::ActivityLogger(const std::string &filePath)
    : filePath_(filePath)
{
}

std::string ActivityLogger::timestamp()
{
    std::time_t now = std::time(nullptr);
    char buffer[32] {0};
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S",
                  std::localtime(&now));
    return buffer;
}

void ActivityLogger::record(const std::string &entry)
{
    const std::string line = "[" + timestamp() + "] " + entry;

    // Append-only file write; failure is reported, never swallowed.
    std::ofstream file(filePath_, std::ios::app);
    if (file.is_open()) {
        file << line << "\n";
    } else {
        std::cerr << "WARNING: cannot open log file " << filePath_ << "\n";
    }

    history_.push_back(line);
    if (history_.size() > kMaxInMemory)
        history_.erase(history_.begin());
}
