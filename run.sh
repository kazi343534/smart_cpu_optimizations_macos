#!/bin/bash
# Smart Process Optimizer — Build & Run Script
# Builds both terminal and GUI versions, then lets you choose.

cd "$(dirname "$0")"

echo "=========================================="
echo "  Smart Process Optimizer - CSE323"
echo "  NSU Operating Systems Project"
echo "=========================================="
echo ""

# Build terminal version
echo "[1/2] Building terminal UI..."
clang++ -std=c++17 -Wall -Wextra \
  system_info.cpp resource_monitor.cpp process_monitor.cpp \
  process_analyzer.cpp important_process.cpp process_controller.cpp \
  optimizer.cpp activity_logger.cpp main.cpp \
  -o smart_optimizer 2>&1
if [ $? -eq 0 ]; then
    echo "  ✓ Terminal UI built successfully"
else
    echo "  ✗ Terminal UI build failed"
fi

# Build GUI version
echo "[2/2] Building native macOS GUI..."
clang++ -std=c++17 -Wall -fobjc-arc \
  gui_main.mm system_info.cpp resource_monitor.cpp process_monitor.cpp \
  process_analyzer.cpp important_process.cpp process_controller.cpp \
  optimizer.cpp activity_logger.cpp \
  -framework Cocoa -o smart_optimizer_gui 2>&1
if [ $? -eq 0 ]; then
    echo "  ✓ macOS GUI built successfully"
else
    echo "  ✗ macOS GUI build failed"
fi

echo ""
echo "=========================================="
echo "  Choose an option:"
echo "=========================================="
echo "  1) Terminal UI (text menu in terminal)"
echo "  2) Native GUI (window with graphs)"
echo "  3) Both"
echo "  4) Exit"
echo "=========================================="
read -p "Enter choice [1-4]: " choice

case $choice in
    1)
        echo ""
        echo "Starting Terminal UI..."
        ./smart_optimizer
        ;;
    2)
        echo ""
        echo "Starting macOS GUI..."
        ./smart_optimizer_gui &
        echo "GUI launched. Check your screen for the window."
        ;;
    3)
        echo ""
        echo "Starting both..."
        ./smart_optimizer_gui &
        echo "GUI launched."
        echo ""
        echo "Starting Terminal UI..."
        ./smart_optimizer
        ;;
    4)
        echo "Goodbye!"
        exit 0
        ;;
    *)
        echo "Invalid choice. Starting Terminal UI..."
        ./smart_optimizer
        ;;
esac
