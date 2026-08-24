#!/bin/bash
# ============================================================
#  SMART PROCESS OPTIMIZER - live demonstration script
#  Builds both binaries, creates a REAL CPU load, runs two
#  adaptive optimization cycles, shows the audit log, cleans up.
# ============================================================
set -u
cd "$(dirname "$0")"

HOG=""
cleanup() { [ -n "$HOG" ] && kill "$HOG" 2>/dev/null; }
trap cleanup EXIT

echo "[1/4] Building (terminal + GUI) ..."
clang++ -std=c++17 -Wall -Wextra *.cpp -o smart_optimizer || exit 1
clang++ -std=c++17 -Wall -fobjc-arc gui_main.mm \
  system_info.cpp resource_monitor.cpp process_monitor.cpp \
  process_analyzer.cpp important_process.cpp process_controller.cpp \
  optimizer.cpp activity_logger.cpp -framework Cocoa \
  -o smart_optimizer_gui || exit 1
echo "      builds OK"

echo "[2/4] Starting a real CPU hog ('yes') ..."
yes > /dev/null &
HOG=$!
sleep 1
echo "      hog pid: $HOG"

echo "[3/4] Running TWO adaptive optimization cycles + history view ..."
printf '3\n3\n4\n6\n' | ./smart_optimizer

echo "[4/4] Done - hog stopped. Full audit trail: smart_optimizer_activity.log"
