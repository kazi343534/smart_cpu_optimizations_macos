/*
 * SMART PROCESS OPTIMIZER - macOS GUI
 * Modern High-Performance Native Interface with Rich Telemetry & Graphs
 */

#import <Cocoa/Cocoa.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <unistd.h>
#include <vector>

#include "activity_logger.h"
#include "important_process.h"
#include "optimizer.h"
#include "process_analyzer.h"
#include "process_monitor.h"
#include "resource_monitor.h"
#include "system_info.h"

// ── Color Utilities ────────────────────────────────────────────────
static inline NSColor *RGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}

static inline NSColor *RGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

struct EngineCore {
    explicit EngineCore(const SystemInfo &si)
        : info(si), protector(getpid()), analyzer(info),
          logger("smart_optimizer_activity.log"),
          optimizer(resources, processes, protector, analyzer, logger) {}
    bool init() { return resources.initialize(info) && processes.initialize(info); }
    SystemInfo info;
    ResourceMonitor resources;
    ProcessMonitor processes;
    ProcessProtector protector;
    ProcessAnalyzer analyzer;
    ActivityLogger logger;
    Optimizer optimizer;
};

static NSString *toNS(const std::string &s) {
    return [NSString stringWithUTF8String:s.c_str()];
}

static NSString *makeBar(double pct, int width) {
    NSMutableString *s = [NSMutableString stringWithCapacity:width * 3];
    if (pct < 0) {
        for (int i = 0; i < width; ++i) [s appendString:@"-"];
        return s;
    }
    double clamped = std::clamp(pct, 0.0, 100.0);
    int filled = (int)(clamped / 100.0 * width + 0.5);
    for (int i = 0; i < width; ++i)
        [s appendString:(i < filled ? @"\u2588" : @"\u2591")];
    return s;
}

// ── Multi-Series CPU Telemetry Graph ──────────────────────────────

@interface CpuGraphView : NSView {
    NSMutableArray<NSNumber *> *_totalSeries;
    NSMutableArray<NSNumber *> *_userSeries;
    NSMutableArray<NSNumber *> *_sysSeries;
    NSMutableArray<NSNumber *> *_mIdx;
    NSMutableArray<NSNumber *> *_mKind;
    double _curTotal, _curUser, _curSys;
    double _peakTotal, _avgTotal;
}
- (void)pushTotal:(double)tot user:(double)usr sys:(double)sys;
- (void)addMarkerKind:(NSInteger)k;
@end

@implementation CpuGraphView

- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        _totalSeries = [NSMutableArray array];
        _userSeries  = [NSMutableArray array];
        _sysSeries   = [NSMutableArray array];
        _mIdx        = [NSMutableArray array];
        _mKind       = [NSMutableArray array];
        _curTotal = _curUser = _curSys = 0.0;
        _peakTotal = _avgTotal = 0.0;
    }
    return self;
}

- (void)pushTotal:(double)tot user:(double)usr sys:(double)sys {
    _curTotal = std::clamp(tot, 0.0, 100.0);
    _curUser  = std::clamp(usr, 0.0, 100.0);
    _curSys   = std::clamp(sys, 0.0, 100.0);

    [_totalSeries addObject:@(_curTotal)];
    [_userSeries addObject:@(_curUser)];
    [_sysSeries addObject:@(_curSys)];

    BOOL shifted = NO;
    while (_totalSeries.count > 80) {
        [_totalSeries removeObjectAtIndex:0];
        [_userSeries removeObjectAtIndex:0];
        [_sysSeries removeObjectAtIndex:0];
        shifted = YES;
    }
    if (shifted) {
        NSMutableArray *ki = [NSMutableArray array], *kk = [NSMutableArray array];
        for (NSUInteger i = 0; i < _mIdx.count; ++i) {
            NSInteger idx = [_mIdx[i] integerValue] - 1;
            if (idx >= 0) { [ki addObject:@(idx)]; [kk addObject:_mKind[i]]; }
        }
        _mIdx = ki; _mKind = kk;
    }

    double maxV = 0.0, sumV = 0.0;
    for (NSNumber *n in _totalSeries) {
        double v = [n doubleValue];
        if (v > maxV) maxV = v;
        sumV += v;
    }
    _peakTotal = maxV;
    _avgTotal = _totalSeries.count ? (sumV / _totalSeries.count) : 0.0;

    [self setNeedsDisplay:YES];
}

- (void)addMarkerKind:(NSInteger)k {
    if (_totalSeries.count == 0) return;
    [_mIdx addObject:@(_totalSeries.count - 1)];
    [_mKind addObject:@(k)];
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return NO; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds;

    // Card background
    [RGB(22, 27, 38) setFill];
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:10 yRadius:10];
    [bg fill];
    [RGB(41, 50, 70) setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];

    CGFloat x0 = 42, y0 = 24;
    CGFloat w = b.size.width - x0 - 16;
    CGFloat h = b.size.height - y0 - 38;

    // Header Title
    NSDictionary *titleAttr = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: RGB(241, 245, 249)
    };
    [@"CPU LOAD TELEMETRY" drawAtPoint:NSMakePoint(14, b.size.height - 24) withAttributes:titleAttr];

    // Live Legend Badges in Header
    CGFloat legX = 175;
    CGFloat legY = b.size.height - 23;

    auto drawLegend = [&](NSString *label, NSString *val, NSColor *dotCol) {
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(legX, legY + 2, 7, 7)];
        [dotCol setFill];
        [dot fill];
        legX += 11;
        NSString *str = [NSString stringWithFormat:@"%@: %@", label, val];
        NSDictionary *attr = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: RGB(203, 213, 225)
        };
        [str drawAtPoint:NSMakePoint(legX, legY) withAttributes:attr];
        legX += [str sizeWithAttributes:attr].width + 12;
    };

    drawLegend(@"Total", [NSString stringWithFormat:@"%.1f%%", _curTotal], RGB(16, 185, 129));
    drawLegend(@"User", [NSString stringWithFormat:@"%.1f%%", _curUser], RGB(6, 182, 212));
    drawLegend(@"Kernel", [NSString stringWithFormat:@"%.1f%%", _curSys], RGB(244, 63, 94));
    drawLegend(@"Peak", [NSString stringWithFormat:@"%.1f%%", _peakTotal], RGB(251, 191, 36));

    // Grid Lines & Y-Axis Labels
    NSDictionary *axisAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: RGB(100, 116, 139)
    };
    for (int g = 0; g <= 4; ++g) {
        CGFloat gy = y0 + h * (g / 4.0);
        NSBezierPath *gl = [NSBezierPath bezierPath];
        [gl moveToPoint:NSMakePoint(x0, gy)];
        [gl lineToPoint:NSMakePoint(x0 + w, gy)];
        [RGB(35, 43, 62) setStroke];
        gl.lineWidth = 0.8;
        CGFloat dashes[] = {2.0, 3.0};
        [gl setLineDash:dashes count:2 phase:0];
        [gl stroke];

        NSString *pctStr = [NSString stringWithFormat:@"%3d%%", g * 25];
        [pctStr drawAtPoint:NSMakePoint(6, gy - 5) withAttributes:axisAttr];
    }

    // Time axis label
    [@"-80s" drawAtPoint:NSMakePoint(x0, 8) withAttributes:axisAttr];
    [@"-40s" drawAtPoint:NSMakePoint(x0 + w/2.0 - 10, 8) withAttributes:axisAttr];
    [@"Now" drawAtPoint:NSMakePoint(x0 + w - 22, 8) withAttributes:axisAttr];

    NSUInteger n = _totalSeries.count;
    if (n >= 2) {
        // ── Draw User CPU Area & Line ──
        NSBezierPath *userArea = [NSBezierPath bezierPath];
        [userArea moveToPoint:NSMakePoint(x0, y0)];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_userSeries[i] doubleValue] / 100.0;
            [userArea lineToPoint:NSMakePoint(px, py)];
        }
        [userArea lineToPoint:NSMakePoint(x0 + w, y0)];
        [userArea closePath];
        NSGradient *userGrad = [[NSGradient alloc] initWithStartingColor:RGBA(6, 182, 212, 0.25)
                                                             endingColor:RGBA(6, 182, 212, 0.02)];
        [userGrad drawInBezierPath:userArea angle:90];

        NSBezierPath *userLine = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_userSeries[i] doubleValue] / 100.0;
            i == 0 ? [userLine moveToPoint:NSMakePoint(px, py)] : [userLine lineToPoint:NSMakePoint(px, py)];
        }
        [RGB(6, 182, 212) setStroke];
        userLine.lineWidth = 1.2;
        [userLine stroke];

        // ── Draw Kernel / System CPU Line ──
        NSBezierPath *sysLine = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_sysSeries[i] doubleValue] / 100.0;
            i == 0 ? [sysLine moveToPoint:NSMakePoint(px, py)] : [sysLine lineToPoint:NSMakePoint(px, py)];
        }
        [RGB(244, 63, 94) setStroke];
        sysLine.lineWidth = 1.2;
        [sysLine stroke];

        // ── Draw Total CPU Glowing Curve ──
        NSBezierPath *totArea = [NSBezierPath bezierPath];
        [totArea moveToPoint:NSMakePoint(x0, y0)];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_totalSeries[i] doubleValue] / 100.0;
            [totArea lineToPoint:NSMakePoint(px, py)];
        }
        [totArea lineToPoint:NSMakePoint(x0 + w, y0)];
        [totArea closePath];
        NSGradient *totGrad = [[NSGradient alloc] initWithStartingColor:RGBA(16, 185, 129, 0.30)
                                                           endingColor:RGBA(16, 185, 129, 0.03)];
        [totGrad drawInBezierPath:totArea angle:90];

        NSBezierPath *totLine = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_totalSeries[i] doubleValue] / 100.0;
            i == 0 ? [totLine moveToPoint:NSMakePoint(px, py)] : [totLine lineToPoint:NSMakePoint(px, py)];
        }
        [RGB(16, 185, 129) setStroke];
        totLine.lineWidth = 2.0;
        [totLine stroke];

        // Glowing dot at latest point
        CGFloat lastX = x0 + w;
        CGFloat lastY = y0 + h * [_totalSeries.lastObject doubleValue] / 100.0;
        NSBezierPath *outerGlow = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(lastX - 5, lastY - 5, 10, 10)];
        [RGBA(16, 185, 129, 0.4) setFill];
        [outerGlow fill];
        NSBezierPath *innerDot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(lastX - 3, lastY - 3, 6, 6)];
        [RGB(241, 245, 249) setFill];
        [innerDot fill];

        // ── Markers ──
        for (NSUInteger m = 0; m < _mIdx.count; ++m) {
            NSInteger idx = [_mIdx[m] integerValue];
            if (idx < 0 || idx >= (NSInteger)n) continue;
            CGFloat mx = x0 + w * idx / (CGFloat)(n - 1);
            NSColor *mc = [_mKind[m] integerValue] == 2 ? RGB(16, 185, 129)
                        : [_mKind[m] integerValue] == 1 ? RGB(245, 158, 11) : RGB(239, 68, 68);

            // Vertical marker line
            NSBezierPath *vline = [NSBezierPath bezierPath];
            [vline moveToPoint:NSMakePoint(mx, y0)];
            [vline lineToPoint:NSMakePoint(mx, y0 + h)];
            [mc colorWithAlphaComponent:0.4];
            [vline stroke];

            // Diamond pin at top
            NSBezierPath *pin = [NSBezierPath bezierPath];
            [pin moveToPoint:NSMakePoint(mx, y0 + h)];
            [pin lineToPoint:NSMakePoint(mx + 4, y0 + h - 5)];
            [pin lineToPoint:NSMakePoint(mx, y0 + h - 10)];
            [pin lineToPoint:NSMakePoint(mx - 4, y0 + h - 5)];
            [pin closePath];
            [mc setFill];
            [pin fill];
        }
    }
}
@end

// ── Multi-Series Memory Breakdown Graph ────────────────────────────

@interface MemoryGraphView : NSView {
    NSMutableArray<NSNumber *> *_activePct;
    NSMutableArray<NSNumber *> *_wiredPct;
    NSMutableArray<NSNumber *> *_compPct;
    NSMutableArray<NSNumber *> *_usedPct;
    double _curActiveGB, _curWiredGB, _curCompGB, _curFreeGB, _curTotalGB;
    double _curUsedPercent;
}
- (void)pushMemory:(const MemoryInfo &)mem;
@end

@implementation MemoryGraphView

- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        _activePct = [NSMutableArray array];
        _wiredPct  = [NSMutableArray array];
        _compPct   = [NSMutableArray array];
        _usedPct   = [NSMutableArray array];
        _curActiveGB = _curWiredGB = _curCompGB = _curFreeGB = _curTotalGB = 0.0;
        _curUsedPercent = 0.0;
    }
    return self;
}

- (void)pushMemory:(const MemoryInfo &)mem {
    const double GB = 1024.0 * 1024.0 * 1024.0;
    _curTotalGB  = mem.totalBytes / GB;
    _curActiveGB = mem.activeBytes / GB;
    _curWiredGB  = mem.wiredBytes / GB;
    _curCompGB   = mem.compressedBytes / GB;
    _curFreeGB   = mem.freeBytes / GB;
    _curUsedPercent = mem.usedPercent();

    double tot = mem.totalBytes > 0 ? (double)mem.totalBytes : 1.0;
    [_activePct addObject:@(100.0 * mem.activeBytes / tot)];
    [_wiredPct addObject:@(100.0 * mem.wiredBytes / tot)];
    [_compPct addObject:@(100.0 * mem.compressedBytes / tot)];
    [_usedPct addObject:@(_curUsedPercent)];

    while (_usedPct.count > 80) {
        [_activePct removeObjectAtIndex:0];
        [_wiredPct removeObjectAtIndex:0];
        [_compPct removeObjectAtIndex:0];
        [_usedPct removeObjectAtIndex:0];
    }

    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return NO; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds;

    [RGB(22, 27, 38) setFill];
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:10 yRadius:10];
    [bg fill];
    [RGB(41, 50, 70) setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];

    CGFloat x0 = 42, y0 = 24;
    CGFloat w = b.size.width - x0 - 16;
    CGFloat h = b.size.height - y0 - 38;

    NSDictionary *titleAttr = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: RGB(241, 245, 249)
    };
    [@"MEMORY DISTRIBUTION" drawAtPoint:NSMakePoint(14, b.size.height - 24) withAttributes:titleAttr];

    CGFloat legX = 185;
    CGFloat legY = b.size.height - 23;

    auto drawLegend = [&](NSString *label, NSString *val, NSColor *dotCol) {
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(legX, legY + 2, 7, 7)];
        [dotCol setFill];
        [dot fill];
        legX += 11;
        NSString *str = [NSString stringWithFormat:@"%@: %@", label, val];
        NSDictionary *attr = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: RGB(203, 213, 225)
        };
        [str drawAtPoint:NSMakePoint(legX, legY) withAttributes:attr];
        legX += [str sizeWithAttributes:attr].width + 12;
    };

    drawLegend(@"Used", [NSString stringWithFormat:@"%.1f GB (%.0f%%)", (_curActiveGB+_curWiredGB+_curCompGB), _curUsedPercent], RGB(236, 72, 153));
    drawLegend(@"Active", [NSString stringWithFormat:@"%.1fG", _curActiveGB], RGB(56, 189, 248));
    drawLegend(@"Wired", [NSString stringWithFormat:@"%.1fG", _curWiredGB], RGB(168, 85, 247));
    drawLegend(@"Comp", [NSString stringWithFormat:@"%.1fG", _curCompGB], RGB(245, 158, 11));

    // Grid & Axis
    NSDictionary *axisAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: RGB(100, 116, 139)
    };
    for (int g = 0; g <= 4; ++g) {
        CGFloat gy = y0 + h * (g / 4.0);
        NSBezierPath *gl = [NSBezierPath bezierPath];
        [gl moveToPoint:NSMakePoint(x0, gy)];
        [gl lineToPoint:NSMakePoint(x0 + w, gy)];
        [RGB(35, 43, 62) setStroke];
        gl.lineWidth = 0.8;
        CGFloat dashes[] = {2.0, 3.0};
        [gl setLineDash:dashes count:2 phase:0];
        [gl stroke];

        NSString *pctStr = [NSString stringWithFormat:@"%3d%%", g * 25];
        [pctStr drawAtPoint:NSMakePoint(6, gy - 5) withAttributes:axisAttr];
    }

    [@"-80s" drawAtPoint:NSMakePoint(x0, 8) withAttributes:axisAttr];
    [@"-40s" drawAtPoint:NSMakePoint(x0 + w/2.0 - 10, 8) withAttributes:axisAttr];
    [@"Now" drawAtPoint:NSMakePoint(x0 + w - 22, 8) withAttributes:axisAttr];

    NSUInteger n = _usedPct.count;
    if (n >= 2) {
        // Active RAM area
        NSBezierPath *actArea = [NSBezierPath bezierPath];
        [actArea moveToPoint:NSMakePoint(x0, y0)];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_activePct[i] doubleValue] / 100.0;
            [actArea lineToPoint:NSMakePoint(px, py)];
        }
        [actArea lineToPoint:NSMakePoint(x0 + w, y0)];
        [actArea closePath];
        NSGradient *actGrad = [[NSGradient alloc] initWithStartingColor:RGBA(56, 189, 248, 0.25)
                                                            endingColor:RGBA(56, 189, 248, 0.02)];
        [actGrad drawInBezierPath:actArea angle:90];

        // Wired RAM Line
        NSBezierPath *wiredLine = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_wiredPct[i] doubleValue] / 100.0;
            i == 0 ? [wiredLine moveToPoint:NSMakePoint(px, py)] : [wiredLine lineToPoint:NSMakePoint(px, py)];
        }
        [RGB(168, 85, 247) setStroke];
        wiredLine.lineWidth = 1.4;
        [wiredLine stroke];

        // Total Used RAM Line & Fill
        NSBezierPath *usedArea = [NSBezierPath bezierPath];
        [usedArea moveToPoint:NSMakePoint(x0, y0)];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_usedPct[i] doubleValue] / 100.0;
            [usedArea lineToPoint:NSMakePoint(px, py)];
        }
        [usedArea lineToPoint:NSMakePoint(x0 + w, y0)];
        [usedArea closePath];
        NSGradient *usedGrad = [[NSGradient alloc] initWithStartingColor:RGBA(236, 72, 153, 0.28)
                                                             endingColor:RGBA(236, 72, 153, 0.02)];
        [usedGrad drawInBezierPath:usedArea angle:90];

        NSBezierPath *usedLine = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_usedPct[i] doubleValue] / 100.0;
            i == 0 ? [usedLine moveToPoint:NSMakePoint(px, py)] : [usedLine lineToPoint:NSMakePoint(px, py)];
        }
        [RGB(236, 72, 153) setStroke];
        usedLine.lineWidth = 2.0;
        [usedLine stroke];

        // Latest indicator point
        CGFloat lastX = x0 + w;
        CGFloat lastY = y0 + h * [_usedPct.lastObject doubleValue] / 100.0;
        NSBezierPath *outerGlow = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(lastX - 5, lastY - 5, 10, 10)];
        [RGBA(236, 72, 153, 0.4) setFill];
        [outerGlow fill];
        NSBezierPath *innerDot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(lastX - 3, lastY - 3, 6, 6)];
        [RGB(241, 245, 249) setFill];
        [innerDot fill];
    }
}
@end

// ── System Pressure & Load Trend Graph (Bottom Right) ─────────────

@interface PressureTrendView : NSView {
    NSMutableArray<NSNumber *> *_cpuSeries;
    NSMutableArray<NSNumber *> *_memSeries;
    double _curCpu, _curMem;
    NSString *_curLevel;
}
- (void)pushCpu:(double)cpu mem:(double)mem pressure:(NSString *)lvl;
@end

@implementation PressureTrendView

- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        _cpuSeries = [NSMutableArray array];
        _memSeries = [NSMutableArray array];
        _curCpu = _curMem = 0.0;
        _curLevel = @"NORMAL";
    }
    return self;
}

- (void)pushCpu:(double)cpu mem:(double)mem pressure:(NSString *)lvl {
    _curCpu = std::clamp(cpu, 0.0, 100.0);
    _curMem = std::clamp(mem, 0.0, 100.0);
    if (lvl && lvl.length > 0) _curLevel = lvl;

    [_cpuSeries addObject:@(_curCpu)];
    [_memSeries addObject:@(_curMem)];

    while (_cpuSeries.count > 60) {
        [_cpuSeries removeObjectAtIndex:0];
        [_memSeries removeObjectAtIndex:0];
    }
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return NO; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds;

    // Card background
    [RGB(22, 27, 38) setFill];
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:10 yRadius:10];
    [bg fill];
    [RGB(41, 50, 70) setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];

    CGFloat x0 = 36, y0 = 20;
    CGFloat w = b.size.width - x0 - 12;
    CGFloat h = b.size.height - y0 - 34;

    // Header Title
    NSDictionary *titleAttr = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:11],
        NSForegroundColorAttributeName: RGB(241, 245, 249)
    };
    [@"PRESSURE & LOAD" drawAtPoint:NSMakePoint(12, b.size.height - 22) withAttributes:titleAttr];

    // Status Pill on top right
    NSColor *lvlCol = [_curLevel isEqualToString:@"NORMAL"] ? RGB(16, 185, 129)
                    : [_curLevel isEqualToString:@"ELEVATED"] ? RGB(245, 158, 11) : RGB(239, 68, 68);
    NSString *pillStr = [NSString stringWithFormat:@"%@", _curLevel];
    NSDictionary *pillAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: lvlCol
    };
    CGFloat pw = [pillStr sizeWithAttributes:pillAttr].width + 10;
    CGFloat px = b.size.width - pw - 10;
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(px, b.size.height - 22, pw, 15) xRadius:7 yRadius:7];
    [[lvlCol colorWithAlphaComponent:0.2] setFill];
    [pill fill];
    [pillStr drawAtPoint:NSMakePoint(px + 5, b.size.height - 21) withAttributes:pillAttr];

    // Grid Lines & Labels
    NSDictionary *axisAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: RGB(100, 116, 139)
    };
    for (int g = 0; g <= 3; ++g) {
        CGFloat gy = y0 + h * (g / 3.0);
        NSBezierPath *gl = [NSBezierPath bezierPath];
        [gl moveToPoint:NSMakePoint(x0, gy)];
        [gl lineToPoint:NSMakePoint(x0 + w, gy)];
        [RGB(35, 43, 62) setStroke];
        gl.lineWidth = 0.8;
        CGFloat dashes[] = {2.0, 3.0};
        [gl setLineDash:dashes count:2 phase:0];
        [gl stroke];

        NSString *pctStr = [NSString stringWithFormat:@"%3d%%", g * 33];
        [pctStr drawAtPoint:NSMakePoint(4, gy - 5) withAttributes:axisAttr];
    }

    // Legend dots at bottom
    NSDictionary *legAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: RGB(203, 213, 225)
    };
    NSString *cpuLeg = [NSString stringWithFormat:@"CPU %.0f%%", _curCpu];
    NSString *memLeg = [NSString stringWithFormat:@"RAM %.0f%%", _curMem];
    
    // CPU legend
    NSBezierPath *cDot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x0, 6, 6, 6)];
    [RGB(16, 185, 129) setFill];
    [cDot fill];
    [cpuLeg drawAtPoint:NSMakePoint(x0 + 10, 4) withAttributes:legAttr];
    
    // Mem legend
    CGFloat memLegX = x0 + [cpuLeg sizeWithAttributes:legAttr].width + 20;
    NSBezierPath *mDot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(memLegX, 6, 6, 6)];
    [RGB(236, 72, 153) setFill];
    [mDot fill];
    [memLeg drawAtPoint:NSMakePoint(memLegX + 10, 4) withAttributes:legAttr];

    NSUInteger n = _cpuSeries.count;
    if (n >= 2) {
        // CPU Pressure Area & Line
        NSBezierPath *cpuArea = [NSBezierPath bezierPath];
        [cpuArea moveToPoint:NSMakePoint(x0, y0)];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_cpuSeries[i] doubleValue] / 100.0;
            [cpuArea lineToPoint:NSMakePoint(px, py)];
        }
        [cpuArea lineToPoint:NSMakePoint(x0 + w, y0)];
        [cpuArea closePath];
        NSGradient *cpuGrad = [[NSGradient alloc] initWithStartingColor:RGBA(16, 185, 129, 0.28)
                                                           endingColor:RGBA(16, 185, 129, 0.02)];
        [cpuGrad drawInBezierPath:cpuArea angle:90];

        NSBezierPath *cpuLine = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_cpuSeries[i] doubleValue] / 100.0;
            i == 0 ? [cpuLine moveToPoint:NSMakePoint(px, py)] : [cpuLine lineToPoint:NSMakePoint(px, py)];
        }
        [RGB(16, 185, 129) setStroke];
        cpuLine.lineWidth = 1.6;
        [cpuLine stroke];

        // Mem Pressure Line
        NSBezierPath *memLine = [NSBezierPath bezierPath];
        for (NSUInteger i = 0; i < n; ++i) {
            CGFloat px = x0 + w * i / (CGFloat)(n - 1);
            CGFloat py = y0 + h * [_memSeries[i] doubleValue] / 100.0;
            i == 0 ? [memLine moveToPoint:NSMakePoint(px, py)] : [memLine lineToPoint:NSMakePoint(px, py)];
        }
        [RGB(236, 72, 153) setStroke];
        memLine.lineWidth = 1.4;
        [memLine stroke];

        // End Dot
        CGFloat lastX = x0 + w;
        CGFloat lastY = y0 + h * [_cpuSeries.lastObject doubleValue] / 100.0;
        NSBezierPath *glow = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(lastX - 4, lastY - 4, 8, 8)];
        [RGBA(16, 185, 129, 0.5) setFill];
        [glow fill];
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(lastX - 2.5, lastY - 2.5, 5, 5)];
        [RGB(241, 245, 249) setFill];
        [dot fill];
    }
}
@end

// ── Optimization Impact Chart ──────────────────────────────────────

@interface OptimizationChartView : NSView {
    NSMutableArray<NSDictionary *> *_events;
}
- (void)pushBefore:(double)b after:(double)a kind:(NSInteger)k name:(NSString *)name pid:(pid_t)pid;
@end

@implementation OptimizationChartView

- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        _events = [NSMutableArray array];
    }
    return self;
}

- (void)pushBefore:(double)before after:(double)after kind:(NSInteger)k name:(NSString *)name pid:(pid_t)pid {
    [_events addObject:@{
        @"before": @(std::clamp(before, 0.0, 100.0)),
        @"after":  @(std::clamp(std::max(after, 0.0), 0.0, 100.0)),
        @"exited": @(after < 0),
        @"kind":   @(k),
        @"name":   name ?: @"Process",
        @"pid":    @(pid)
    }];
    while (_events.count > 10) [_events removeObjectAtIndex:0];
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return NO; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds;

    [RGB(22, 27, 38) setFill];
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:10 yRadius:10];
    [bg fill];
    [RGB(41, 50, 70) setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];

    CGFloat x0 = 42, y0 = 32;
    CGFloat w = b.size.width - x0 - 16;
    CGFloat h = b.size.height - y0 - 44;

    NSDictionary *titleAttr = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: RGB(241, 245, 249)
    };
    [@"OPTIMIZATION IMPACT ANALYSIS" drawAtPoint:NSMakePoint(14, b.size.height - 24) withAttributes:titleAttr];

    NSDictionary *subAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: RGB(148, 163, 184)
    };
    [@"Target CPU%:  [Grey: Before]  [Color: After]" drawAtPoint:NSMakePoint(240, b.size.height - 23) withAttributes:subAttr];

    // Grid lines & Y-Axis
    NSDictionary *axisAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: RGB(100, 116, 139)
    };
    for (int g = 0; g <= 4; ++g) {
        CGFloat gy = y0 + h * (g / 4.0);
        NSBezierPath *gl = [NSBezierPath bezierPath];
        [gl moveToPoint:NSMakePoint(x0, gy)];
        [gl lineToPoint:NSMakePoint(x0 + w, gy)];
        [RGB(35, 43, 62) setStroke];
        gl.lineWidth = 0.8;
        CGFloat dashes[] = {2.0, 3.0};
        [gl setLineDash:dashes count:2 phase:0];
        [gl stroke];

        NSString *pctStr = [NSString stringWithFormat:@"%3d%%", g * 25];
        [pctStr drawAtPoint:NSMakePoint(6, gy - 5) withAttributes:axisAttr];
    }

    if (_events.count == 0) {
        NSDictionary *emptyAttr = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: RGB(100, 116, 139)
        };
        [@"Click 'Run Smart Optimization' to generate comparison telemetry"
            drawAtPoint:NSMakePoint(x0 + 20, y0 + h / 2.0 - 6) withAttributes:emptyAttr];
        return;
    }

    CGFloat gw = w / _events.count;
    CGFloat bw = std::min(gw * 0.32, 22.0);

    for (NSUInteger i = 0; i < _events.count; ++i) {
        NSDictionary *ev = _events[i];
        double before = [ev[@"before"] doubleValue];
        double after  = [ev[@"after"] doubleValue];
        NSInteger kind = [ev[@"kind"] integerValue];
        BOOL exited   = [ev[@"exited"] boolValue];
        NSString *name = ev[@"name"];

        CGFloat cx = x0 + gw * i + gw * 0.5;
        CGFloat bx1 = cx - bw - 2;
        CGFloat bx2 = cx + 2;

        // Before Bar (Slate grey)
        CGFloat bh1 = std::max(h * before / 100.0, 2.0);
        NSBezierPath *bar1 = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx1, y0, bw, bh1) xRadius:3 yRadius:3];
        [RGB(100, 116, 139) setFill];
        [bar1 fill];

        // After Bar
        if (!exited) {
            CGFloat bh2 = std::max(h * after / 100.0, 2.0);
            NSBezierPath *bar2 = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx2, y0, bw, bh2) xRadius:3 yRadius:3];
            NSColor *afterCol = (kind == 2) ? RGB(16, 185, 129)
                              : (kind == 1) ? RGB(245, 158, 11) : RGB(239, 68, 68);
            [afterCol setFill];
            [bar2 fill];

            // Savings badge / delta text
            double delta = before - after;
            if (delta > 0.5) {
                NSString *delStr = [NSString stringWithFormat:@"-%.0f%%", delta];
                NSDictionary *delAttr = @{
                    NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightBold],
                    NSForegroundColorAttributeName: RGB(16, 185, 129)
                };
                CGFloat txtW = [delStr sizeWithAttributes:delAttr].width;
                [delStr drawAtPoint:NSMakePoint(cx - txtW / 2.0, y0 + std::max(bh1, bh2) + 4) withAttributes:delAttr];
            }
        } else {
            // Exited tag
            NSString *exStr = @"Exited";
            NSDictionary *exAttr = @{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:7.5 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: RGB(56, 189, 248)
            };
            [exStr drawAtPoint:NSMakePoint(bx2, y0 + 4) withAttributes:exAttr];
        }

        // Process Name Label below bar
        NSString *shortName = name.length > 7 ? [name substringToIndex:7] : name;
        NSDictionary *lblAttr = @{
            NSFontAttributeName: [NSFont systemFontOfSize:8 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: RGB(148, 163, 184)
        };
        CGFloat lblW = [shortName sizeWithAttributes:lblAttr].width;
        [shortName drawAtPoint:NSMakePoint(cx - lblW / 2.0, 10) withAttributes:lblAttr];
    }
}
@end

// ── Top 5 CPU Processes Mini-Bar Widget ───────────────────────────

@interface TopProcessesView : NSView {
    NSMutableArray<NSDictionary *> *_topRows;
}
- (void)updateTopProcesses:(const std::vector<ProcessInfo> &)rows;
@end

@implementation TopProcessesView

- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        _topRows = [NSMutableArray array];
    }
    return self;
}

- (void)updateTopProcesses:(const std::vector<ProcessInfo> &)rows {
    [_topRows removeAllObjects];
    for (size_t i = 0; i < rows.size() && i < 5; ++i) {
        const auto &p = rows[i];
        [_topRows addObject:@{
            @"pid": @(p.pid),
            @"name": toNS(p.name.length() > 18 ? p.name.substr(0, 18) : p.name),
            @"cpu": @(std::max(p.cpuPercent, 0.0)),
            @"state": toNS(processStateName(p.state)),
            @"memMB": @(p.residentBytes / (1024.0 * 1024.0))
        }];
    }
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds;

    [RGB(22, 27, 38) setFill];
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:10 yRadius:10];
    [bg fill];
    [RGB(41, 50, 70) setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];

    NSDictionary *titleAttr = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: RGB(241, 245, 249)
    };
    [@"TOP CPU PROCESSES" drawAtPoint:NSMakePoint(14, 12) withAttributes:titleAttr];

    NSDictionary *subAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: RGB(148, 163, 184)
    };
    [@"Live Kernel Ranking" drawAtPoint:NSMakePoint(b.size.width - 130, 14) withAttributes:subAttr];

    if (_topRows.count == 0) {
        NSDictionary *emptyAttr = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: RGB(100, 116, 139)
        };
        [@"Awaiting scan data..." drawAtPoint:NSMakePoint(20, b.size.height / 2.0 - 8) withAttributes:emptyAttr];
        return;
    }

    CGFloat rowY = 34;
    CGFloat rowH = 26;

    for (NSUInteger i = 0; i < _topRows.count; ++i) {
        NSDictionary *p = _topRows[i];
        NSString *name = p[@"name"];
        pid_t pid = [p[@"pid"] intValue];
        double cpu = [p[@"cpu"] doubleValue];
        double memMB = [p[@"memMB"] doubleValue];
        NSString *state = p[@"state"];

        // PID & Name
        NSString *infoStr = [NSString stringWithFormat:@"%5d  %-16@", pid, name];
        NSDictionary *nameAttr = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: RGB(241, 245, 249)
        };
        [infoStr drawAtPoint:NSMakePoint(14, rowY) withAttributes:nameAttr];

        // State Badge
        NSColor *badgeCol = [state isEqualToString:@"Running"] ? RGB(16, 185, 129) : RGB(56, 189, 248);
        NSBezierPath *stateBadge = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(180, rowY, 48, 14) xRadius:3 yRadius:3];
        [[badgeCol colorWithAlphaComponent:0.18] setFill];
        [stateBadge fill];
        NSDictionary *stateAttr = @{
            NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: badgeCol
        };
        [state drawAtPoint:NSMakePoint(185, rowY + 1) withAttributes:stateAttr];

        // Bar background & fill
        CGFloat barX = 236;
        CGFloat barW = b.size.width - barX - 110;
        CGFloat barH = 10;
        NSBezierPath *barTrack = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(barX, rowY + 2, barW, barH) xRadius:3 yRadius:3];
        [RGB(35, 43, 62) setFill];
        [barTrack fill];

        CGFloat fillW = std::clamp(barW * (cpu / 100.0), 3.0, barW);
        NSBezierPath *barFill = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(barX, rowY + 2, fillW, barH) xRadius:3 yRadius:3];

        NSColor *barCol = (cpu > 40.0) ? RGB(239, 68, 68)
                        : (cpu > 15.0) ? RGB(245, 158, 11)
                        : (cpu > 5.0)  ? RGB(6, 182, 212) : RGB(16, 185, 129);
        [barCol setFill];
        [barFill fill];

        // CPU% & Mem
        NSString *metricStr = [NSString stringWithFormat:@"%5.1f%%  %4.0fM", cpu, memMB];
        NSDictionary *metricAttr = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: barCol
        };
        [metricStr drawAtPoint:NSMakePoint(b.size.width - 98, rowY) withAttributes:metricAttr];

        rowY += rowH;
    }
}
@end

// ── Header Information View ────────────────────────────────────────

@interface SystemHeaderView : NSView
@property (nonatomic, copy) NSString *hwString;
@property (nonatomic, copy) NSString *pressureString;
@property (nonatomic, copy) NSString *statusString;
@property (nonatomic, assign) NSInteger runningCount;
@property (nonatomic, assign) NSInteger sleepingCount;
@property (nonatomic, assign) NSInteger stoppedCount;
@property (nonatomic, assign) NSInteger protectedCount;
@end

@implementation SystemHeaderView

- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        _hwString = @"Apple Silicon | macOS Kernel";
        _pressureString = @"NORMAL";
        _statusString = @"Ready";
        _runningCount = _sleepingCount = _stoppedCount = _protectedCount = 0;
    }
    return self;
}

- (BOOL)isFlipped { return NO; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds;

    [RGB(22, 27, 38) setFill];
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:10 yRadius:10];
    [bg fill];
    [RGB(41, 50, 70) setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];

    // Hardware Info (Left)
    NSDictionary *appTitleAttr = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:13],
        NSForegroundColorAttributeName: RGB(241, 245, 249)
    };
    // Title — comfortably placed inside the 50px header
    [@"SMART PROCESS OPTIMIZER" drawAtPoint:NSMakePoint(14, b.size.height - 20) withAttributes:appTitleAttr];

    NSDictionary *hwAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: RGB(148, 163, 184)
    };
    // Hardware string — 8px above bottom
    [_hwString drawAtPoint:NSMakePoint(14, 8) withAttributes:hwAttr];

    // Process State Summary Badges — vertically centred
    CGFloat badgeX = 330;
    CGFloat badgeY = 16;

    auto drawPill = [&](NSString *title, NSInteger count, NSColor *color) {
        NSString *str = [NSString stringWithFormat:@"%@ %ld", title, (long)count];
        NSDictionary *attr = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: color
        };
        CGFloat pw = [str sizeWithAttributes:attr].width + 14;
        NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(badgeX, badgeY, pw, 18) xRadius:9 yRadius:9];
        [[color colorWithAlphaComponent:0.18] setFill];
        [pill fill];
        [str drawAtPoint:NSMakePoint(badgeX + 7, badgeY + 2) withAttributes:attr];
        badgeX += pw + 8;
    };

    drawPill(@"🟢 RUN", _runningCount, RGB(16, 185, 129));
    drawPill(@"🔵 SLEEP", _sleepingCount, RGB(56, 189, 248));
    if (_stoppedCount > 0) drawPill(@"🟠 STOP", _stoppedCount, RGB(245, 158, 11));
    drawPill(@"🛡️ PROTECTED", _protectedCount, RGB(168, 85, 247));

    // Status & Pressure Badge (Right)
    NSColor *pressCol = [_pressureString isEqualToString:@"NORMAL"] ? RGB(16, 185, 129)
                      : [_pressureString isEqualToString:@"ELEVATED"] ? RGB(245, 158, 11) : RGB(239, 68, 68);

    CGFloat pressX = b.size.width - 230;
    NSString *pressStr = [NSString stringWithFormat:@"PRESSURE: %@", _pressureString];
    NSDictionary *pressAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: pressCol
    };
    CGFloat prW = [pressStr sizeWithAttributes:pressAttr].width + 16;
    NSBezierPath *prPill = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(pressX, badgeY, prW, 18) xRadius:9 yRadius:9];
    [[pressCol colorWithAlphaComponent:0.18] setFill];
    [prPill fill];
    [pressStr drawAtPoint:NSMakePoint(pressX + 8, badgeY + 2) withAttributes:pressAttr];

    // Status label
    NSDictionary *stAttr = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: RGB(56, 189, 248)
    };
    CGFloat stW = [_statusString sizeWithAttributes:stAttr].width;
    [_statusString drawAtPoint:NSMakePoint(b.size.width - stW - 16, b.size.height - 20) withAttributes:stAttr];
}
@end

// ── AppDelegate ─────────────────────────────────────────────────────

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@end

@implementation AppDelegate {
    NSTextView  *_output;
    NSScrollView *_scrollView;
    CpuGraphView *_cpuGraph;
    MemoryGraphView *_memGraph;
    OptimizationChartView *_optGraph;
    TopProcessesView *_topView;
    PressureTrendView *_pressureGraph;
    SystemHeaderView *_headerView;
    NSButton *_scanBtn;
    NSButton *_optBtn;
    NSButton *_logBtn;
    NSButton *_clrBtn;
    NSButton *_autoModeCheck;
    dispatch_queue_t _bgQ;
    std::unique_ptr<EngineCore> _eng;
    BOOL _scanBusy;
    BOOL _optBusy;
    NSTimer *_autoTimer;
    BOOL _autoModeRunning;
}

- (void)dealloc {
    [_autoTimer invalidate];
}

- (void)logAttributedString:(NSAttributedString *)attrStr {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_output.textStorage appendAttributedString:attrStr];
        [self->_output scrollRangeToVisible:NSMakeRange(self->_output.string.length, 0)];
    });
}

- (void)logWithStyle:(NSString *)msg color:(NSColor *)col bold:(BOOL)bold {
    NSFont *font = bold ? [NSFont fontWithName:@"Menlo-Bold" size:11] : [NSFont fontWithName:@"Menlo" size:11];
    if (!font) font = [NSFont monospacedSystemFontOfSize:11 weight:bold ? NSFontWeightBold : NSFontWeightRegular];
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:msg
        attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: col ?: RGB(203, 213, 225)
        }];
    [self logAttributedString:as];
}

- (void)log:(NSString *)msg {
    [self logWithStyle:msg color:RGB(203, 213, 225) bold:NO];
}

- (void)setStatus:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_headerView.statusString = s;
        [self->_headerView setNeedsDisplay:YES];
    });
}

// ── SCAN ────────────────────────────────────────────────────────────

- (void)runScan {
    @autoreleasepool {
        _eng->processes.refresh(200);
        CpuBreakdown cpuBd;
        _eng->resources.measureCpuDetailed(1000, cpuBd);
        _eng->processes.refresh(1000);
        MemoryInfo mem;
        _eng->resources.readMemoryInfo(mem);

        std::vector<ProcessInfo> rows = _eng->processes.processes();
        std::sort(rows.begin(), rows.end(),
            [](const ProcessInfo &a, const ProcessInfo &b){ return a.cpuPercent > b.cpuPercent; });

        // Process State counts
        NSInteger nRun = 0, nSleep = 0, nStop = 0;
        for (const auto &p : rows) {
            if (p.state == ProcessState::Running) ++nRun;
            else if (p.state == ProcessState::Sleeping) ++nSleep;
            else if (p.state == ProcessState::Stopped) ++nStop;
        }

        NSMutableAttributedString *logBlock = [[NSMutableAttributedString alloc] init];
        auto appendText = [&](NSString *str, NSColor *col, BOOL bold) {
            NSFont *font = bold ? [NSFont fontWithName:@"Menlo-Bold" size:11] : [NSFont fontWithName:@"Menlo" size:11];
            if (!font) font = [NSFont monospacedSystemFontOfSize:11 weight:bold ? NSFontWeightBold : NSFontWeightRegular];
            [logBlock appendAttributedString:[[NSAttributedString alloc] initWithString:str
                attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: col}]];
        };

        appendText([NSString stringWithFormat:@"\n=== PROCESS SCAN (%zu processes) ===\n", _eng->processes.count()],
                   RGB(56, 189, 248), YES);
        appendText(@"PID     STATE      CPU%   ACTIVITY BAR       MEM(MB)  NAME\n", RGB(148, 163, 184), YES);
        appendText(@"----------------------------------------------------------------------\n", RGB(51, 65, 85), NO);

        for (size_t i = 0; i < rows.size() && i < 20; ++i) {
            const ProcessInfo &p = rows[i];
            NSString *cpuStr = p.cpuPercent < 0 ? @"    -" :
                [NSString stringWithFormat:@"%5.1f%%", p.cpuPercent];

            NSColor *rowCol = (p.cpuPercent > 30.0) ? RGB(244, 63, 94)
                            : (p.cpuPercent > 10.0) ? RGB(251, 191, 36)
                            : (p.cpuPercent > 2.0)  ? RGB(56, 189, 248) : RGB(203, 213, 225);

            NSString *line = [NSString stringWithFormat:@"%-7d %-10s %@  %@  %7.1f  %@\n",
                p.pid, processStateName(p.state).c_str(), cpuStr,
                makeBar(p.cpuPercent, 14),
                p.residentBytes / (1024.0 * 1024.0),
                toNS(p.name.substr(0, 24))];
            appendText(line, rowCol, p.cpuPercent > 20.0);
        }

        std::vector<ProcessInfo> rowsCopy = rows;
        MemoryInfo memCopy = mem;
        CpuBreakdown cpuCopy = cpuBd;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self logAttributedString:logBlock];
            [self->_cpuGraph pushTotal:cpuCopy.totalPercent user:cpuCopy.userPercent sys:cpuCopy.systemPercent];
            [self->_memGraph pushMemory:memCopy];
            [self->_topView updateTopProcesses:rowsCopy];
            [self->_pressureGraph pushCpu:cpuCopy.totalPercent mem:memCopy.usedPercent() pressure:self->_headerView.pressureString];

            self->_headerView.runningCount = nRun;
            self->_headerView.sleepingCount = nSleep;
            self->_headerView.stoppedCount = nStop;
            self->_headerView.protectedCount = 20;
            self->_headerView.pressureString = (cpuCopy.totalPercent > 80.0 || memCopy.usedPercent() > 85.0) ? @"HIGH"
                                             : (cpuCopy.totalPercent > 50.0 || memCopy.usedPercent() > 70.0) ? @"ELEVATED" : @"NORMAL";
            self->_headerView.statusString = @"Ready";
            [self->_headerView setNeedsDisplay:YES];
            self->_scanBusy = NO;
        });
    }
}

- (void)doScanClick {
    if (_scanBusy) return;
    _scanBusy = YES;
    _headerView.statusString = @"Scanning...";
    [_headerView setNeedsDisplay:YES];
    dispatch_async(_bgQ, ^{ [self runScan]; });
}

// ── OPTIMIZE ────────────────────────────────────────────────────────

- (void)runOptimize {
    @autoreleasepool {
        OptimizationReport rpt = _eng->optimizer.runCycle(1000);
        MemoryInfo mem;
        _eng->resources.readMemoryInfo(mem);

        NSMutableAttributedString *logBlock = [[NSMutableAttributedString alloc] init];
        auto appendText = [&](NSString *str, NSColor *col, BOOL bold) {
            NSFont *font = bold ? [NSFont fontWithName:@"Menlo-Bold" size:11] : [NSFont fontWithName:@"Menlo" size:11];
            if (!font) font = [NSFont monospacedSystemFontOfSize:11 weight:bold ? NSFontWeightBold : NSFontWeightRegular];
            [logBlock appendAttributedString:[[NSAttributedString alloc] initWithString:str
                attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: col}]];
        };

        appendText(@"\n=== SMART OPTIMIZATION REPORT ===\n", RGB(16, 185, 129), YES);
        for (const std::string &l : rpt.lines()) {
            NSColor *lineCol = RGB(203, 213, 225);
            if (l.find("TARGET") != std::string::npos) lineCol = RGB(251, 191, 36);
            else if (l.find("IMPROVED") != std::string::npos) lineCol = RGB(16, 185, 129);
            else if (l.find("REASON") != std::string::npos) lineCol = RGB(56, 189, 248);
            appendText([NSString stringWithFormat:@"%@\n", toNS(l)], lineCol, NO);
        }

        double cv = rpt.sysCpuAfter >= 0 ? rpt.sysCpuAfter : rpt.sysCpuBefore;
        BOOL ok = rpt.success;
        NSInteger cycleKind = 0;
        if (rpt.improvementVerdict.find("IMPROVED") != std::string::npos) cycleKind = 2;
        else if (rpt.improvementVerdict.find("PARTIAL") != std::string::npos) cycleKind = 1;

        std::vector<TargetActionReport> targetsCopy = rpt.targets;
        MemoryInfo memCopy = mem;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self logAttributedString:logBlock];
            [self->_cpuGraph pushTotal:cv user:cv*0.7 sys:cv*0.3];
            [self->_memGraph pushMemory:memCopy];
            [self->_cpuGraph addMarkerKind:cycleKind];
            [self->_pressureGraph pushCpu:cv mem:memCopy.usedPercent() pressure:toNS(rpt.pressureLevel)];

            if (targetsCopy.empty()) {
                // If no targets were selected
                double tgtB = rpt.targetCpuBefore;
                double tgtA = rpt.targetExited ? -1.0 : rpt.targetCpuAfter;
                [self->_optGraph pushBefore:tgtB after:tgtA kind:cycleKind name:toNS(rpt.targetName) pid:rpt.targetPid];
            } else {
                for (const auto &t : targetsCopy) {
                    double tgtB = t.cpuBefore;
                    double tgtA = t.targetExited ? -1.0 : t.cpuAfter;
                    NSInteger tKind = 0;
                    if (t.verdict.find("IMPROVED") != std::string::npos || t.verdict.find("EXITED") != std::string::npos) tKind = 2;
                    else if (t.verdict.find("STABLE") != std::string::npos) tKind = 1;
                    [self->_optGraph pushBefore:tgtB after:tgtA kind:tKind name:toNS(t.name) pid:t.pid];
                }
            }

            self->_optBusy = NO;
            self->_headerView.statusString = ok ? @"Optimized (Improved)" : @"Optimized (Watch)";
            self->_headerView.pressureString = toNS(rpt.pressureLevel);
            [self->_headerView setNeedsDisplay:YES];
        });
    }
}

- (void)doOptClick {
    if (_optBusy) return;
    _optBusy = YES;
    _headerView.statusString = @"Optimizing...";
    [_headerView setNeedsDisplay:YES];
    dispatch_async(_bgQ, ^{ [self runOptimize]; });
}

- (void)doLogClick {
    NSMutableAttributedString *logBlock = [[NSMutableAttributedString alloc] init];
    auto appendText = [&](NSString *str, NSColor *col, BOOL bold) {
        NSFont *font = bold ? [NSFont fontWithName:@"Menlo-Bold" size:11] : [NSFont fontWithName:@"Menlo" size:11];
        if (!font) font = [NSFont monospacedSystemFontOfSize:11 weight:bold ? NSFontWeightBold : NSFontWeightRegular];
        [logBlock appendAttributedString:[[NSAttributedString alloc] initWithString:str
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: col}]];
    };

    appendText(@"\n=== SYSTEM ACTIVITY LOG HISTORY ===\n", RGB(168, 85, 247), YES);
    const auto &h = _eng->logger.history();
    size_t start = h.size() > 30 ? h.size() - 30 : 0;
    for (size_t i = start; i < h.size(); ++i) {
        appendText([NSString stringWithFormat:@"%@\n", toNS(h[i])], RGB(203, 213, 225), NO);
    }
    if (h.empty()) appendText(@"(activity log is currently empty)\n", RGB(100, 116, 139), NO);
    [self logAttributedString:logBlock];
}

- (void)doClearClick {
    _output.string = @"";
    [self logWithStyle:@"Console cleared.\n" color:RGB(100, 116, 139) bold:NO];
}

// ── Window Setup ────────────────────────────────────────────────────

- (void)layoutSubviews {
    if (!_window) return;
    NSRect bounds = _window.contentView.bounds;
    CGFloat W = bounds.size.width;
    CGFloat H = bounds.size.height;
    if (W <= 100 || H <= 100) return;

    const CGFloat margin = 16.0;
    const CGFloat gap = 8.0;
    const CGFloat topPad = 36.0; // Space below top window controls / traffic lights
    const CGFloat hdrH = 48.0;
    const CGFloat btnH = 32.0;

    // 1. Top Header: pinned to the top of the window
    CGFloat hdrY = H - topPad - hdrH;
    _headerView.frame = NSMakeRect(margin, hdrY, W - 2 * margin, hdrH);

    // Dynamic graph sizing based on window height
    CGFloat availH = hdrY - gap - btnH - gap - margin;
    CGFloat graphH = std::clamp((availH * 0.52 - gap) / 2.0, 135.0, 210.0);
    CGFloat graphW = (W - 2 * margin - gap) / 2.0;

    // 2. Row 1 Graphs (CPU Load & Memory Distribution)
    CGFloat row1Y = hdrY - gap - graphH;
    _cpuGraph.frame = NSMakeRect(margin, row1Y, graphW, graphH);
    _memGraph.frame = NSMakeRect(margin + graphW + gap, row1Y, graphW, graphH);

    // 3. Row 2 Graphs (Optimization Impact & Top CPU Processes)
    CGFloat row2Y = row1Y - gap - graphH;
    _optGraph.frame = NSMakeRect(margin, row2Y, graphW, graphH);
    _topView.frame = NSMakeRect(margin + graphW + gap, row2Y, graphW, graphH);

    // 4. Buttons Toolbar
    CGFloat btnY = row2Y - gap - btnH;
    _scanBtn.frame = NSMakeRect(margin, btnY, 140, btnH);
    _optBtn.frame = NSMakeRect(margin + 148, btnY, 205, btnH);
    _logBtn.frame = NSMakeRect(margin + 361, btnY, 115, btnH);
    _clrBtn.frame = NSMakeRect(margin + 484, btnY, 105, btnH);
    _autoModeCheck.frame = NSMakeRect(margin + 597, btnY + 3, 240, 26);

    // 5. Bottom Section:
    // New graph in the bottom-right corner with width = 2/3 of previous graph
    CGFloat extraGraphW = std::round(graphW * (2.0 / 3.0));
    CGFloat logY = margin;
    CGFloat logH = std::max(btnY - gap - logY, 90.0);
    CGFloat logW = W - 2 * margin - extraGraphW - gap;

    // Terminal Log Console (Bottom Left)
    _scrollView.frame = NSMakeRect(margin, logY, logW, logH);

    // New Pressure & Load Graph (Bottom Right Corner)
    CGFloat extraGraphX = margin + logW + gap;
    _pressureGraph.frame = NSMakeRect(extraGraphX, logY, extraGraphW, logH);
}

- (void)windowDidResize:(NSNotification *)notification {
    [self layoutSubviews];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    _bgQ = dispatch_queue_create("spo.bg", DISPATCH_QUEUE_SERIAL);
    _scanBusy = NO;
    _optBusy = NO;

    SystemInfo si;
    if (!loadSystemInfo(si)) { [[NSApplication sharedApplication] terminate:nil]; return; }
    _eng = std::make_unique<EngineCore>(si);
    if (!_eng->init()) { [[NSApplication sharedApplication] terminate:nil]; return; }

    // WINDOW — Responsive, centered, modern dark theme
    _window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1060, 720)
                  styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable|NSWindowStyleMaskFullSizeContentView)
                    backing:NSBackingStoreBuffered defer:NO];
    _window.titleVisibility = (NSWindowTitleVisibility)1; // NSWindowTitleVisibilityHidden
    _window.titlebarAppearsTransparent = YES;
    _window.title = @"Smart Process Optimizer - Live Kernel Monitor";
    _window.releasedWhenClosed = NO;
    _window.backgroundColor = RGB(15, 18, 25);
    _window.delegate = self;
    _window.minSize = NSMakeSize(880, 580);
    NSView *c = _window.contentView;

    // 1. TOP HEADER VIEW
    _headerView = [[SystemHeaderView alloc] initWithFrame:NSMakeRect(16, 620, 1028, 48)];
    _headerView.hwString = [NSString stringWithFormat:@"%@ | %d Cores | %.0f GB RAM (Page: %d KB)",
        toNS(_eng->info.model), _eng->info.logicalCpuCores,
        _eng->info.totalPhysicalBytes / (1024.0 * 1024.0 * 1024.0),
        _eng->info.pageSizeBytes / 1024];
    [c addSubview:_headerView];

    // 2. ROW 1 GRAPHS (CPU + Memory)
    _cpuGraph = [[CpuGraphView alloc] initWithFrame:NSMakeRect(16, 450, 510, 160)];
    _memGraph = [[MemoryGraphView alloc] initWithFrame:NSMakeRect(534, 450, 510, 160)];
    [c addSubview:_cpuGraph];
    [c addSubview:_memGraph];

    // 3. ROW 2 GRAPHS (Opt Impact + Top Processes)
    _optGraph = [[OptimizationChartView alloc] initWithFrame:NSMakeRect(16, 280, 510, 160)];
    _topView  = [[TopProcessesView alloc] initWithFrame:NSMakeRect(534, 280, 510, 160)];
    [c addSubview:_optGraph];
    [c addSubview:_topView];

    // 4. BUTTONS TOOLBAR
    _scanBtn = [[NSButton alloc] initWithFrame:NSMakeRect(16, 240, 140, 32)];
    _scanBtn.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"⚡ Refresh Scan"
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: [NSColor whiteColor]}];
    _scanBtn.bezelStyle = NSBezelStyleRounded;
    _scanBtn.target = self;
    _scanBtn.action = @selector(doScanClick);
    [c addSubview:_scanBtn];

    _optBtn = [[NSButton alloc] initWithFrame:NSMakeRect(164, 240, 205, 32)];
    _optBtn.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"🚀 Run Smart Optimization"
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: [NSColor whiteColor]}];
    _optBtn.bezelStyle = NSBezelStyleRounded;
    _optBtn.target = self;
    _optBtn.action = @selector(doOptClick);
    [c addSubview:_optBtn];

    _logBtn = [[NSButton alloc] initWithFrame:NSMakeRect(377, 240, 115, 32)];
    _logBtn.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"📋 Show Log"
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: [NSColor whiteColor]}];
    _logBtn.bezelStyle = NSBezelStyleRounded;
    _logBtn.target = self;
    _logBtn.action = @selector(doLogClick);
    [c addSubview:_logBtn];

    _clrBtn = [[NSButton alloc] initWithFrame:NSMakeRect(500, 240, 105, 32)];
    _clrBtn.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"🧹 Clear Log"
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: [NSColor whiteColor]}];
    _clrBtn.bezelStyle = NSBezelStyleRounded;
    _clrBtn.target = self;
    _clrBtn.action = @selector(doClearClick);
    [c addSubview:_clrBtn];

    _autoModeCheck = [[NSButton alloc] initWithFrame:NSMakeRect(613, 243, 240, 26)];
    [_autoModeCheck setButtonType:NSButtonTypeSwitch];
    _autoModeCheck.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Smart Auto Mode (3s cycle)"
            attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
                         NSForegroundColorAttributeName: RGB(56, 189, 248)}];
    _autoModeCheck.target = self;
    _autoModeCheck.action = @selector(autoModeToggle:);
    [c addSubview:_autoModeCheck];

    // 5. TERMINAL CONSOLE SCROLL VIEW
    _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 16, 700, 216)];
    _scrollView.hasVerticalScroller = YES;
    _scrollView.borderType = NSBezelBorder;

    _output = [[NSTextView alloc] initWithFrame:_scrollView.contentView.bounds];
    _output.editable = NO;
    _output.font = [NSFont fontWithName:@"Menlo" size:11];
    _output.textColor = RGB(203, 213, 225);
    _output.backgroundColor = RGB(13, 16, 23);
    _output.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.documentView = _output;
    [c addSubview:_scrollView];

    // 6. BOTTOM RIGHT PRESSURE GRAPH (2/3 size of top graphs)
    _pressureGraph = [[PressureTrendView alloc] initWithFrame:NSMakeRect(724, 16, 320, 216)];
    [c addSubview:_pressureGraph];

    // Apply layout dynamically
    [self layoutSubviews];

    [self logWithStyle:@"=== SMART PROCESS OPTIMIZER INITIALIZED ===\n" color:RGB(16, 185, 129) bold:YES];
    [self log:@"Live Mach host_statistics & proc_pidinfo telemetry ready.\n"
              "Multi-series graphs: Total/User/Kernel CPU, Active/Wired/Compressed RAM.\n"
              "Click 'Refresh Scan' or toggle 'Smart Auto Mode' to stream live telemetry.\n"];

    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Auto-start initial scan
    [self performSelector:@selector(doScanClick) withObject:nil afterDelay:0.5];
}

// ── SMART AUTO MODE ────────────────────────────────────────────────

- (void)autoCycleStep {
    if (!_autoModeRunning) return;

    dispatch_async(_bgQ, ^{
        @autoreleasepool {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_headerView.statusString = @"Auto: Scanning...";
                [self->_headerView setNeedsDisplay:YES];
            });

            self->_eng->processes.refresh(200);
            CpuBreakdown cpuBd;
            self->_eng->resources.measureCpuDetailed(1000, cpuBd);
            self->_eng->processes.refresh(1000);
            MemoryInfo mem;
            self->_eng->resources.readMemoryInfo(mem);

            std::vector<ProcessInfo> rows = self->_eng->processes.processes();
            std::sort(rows.begin(), rows.end(),
                [](const ProcessInfo &a, const ProcessInfo &b){ return a.cpuPercent > b.cpuPercent; });

            NSInteger nRun = 0, nSleep = 0, nStop = 0;
            for (const auto &p : rows) {
                if (p.state == ProcessState::Running) ++nRun;
                else if (p.state == ProcessState::Sleeping) ++nSleep;
                else if (p.state == ProcessState::Stopped) ++nStop;
            }

            NSMutableAttributedString *logBlock = [[NSMutableAttributedString alloc] init];
            auto appendText = [&](NSString *str, NSColor *col, BOOL bold) {
                NSFont *font = bold ? [NSFont fontWithName:@"Menlo-Bold" size:11] : [NSFont fontWithName:@"Menlo" size:11];
                if (!font) font = [NSFont monospacedSystemFontOfSize:11 weight:bold ? NSFontWeightBold : NSFontWeightRegular];
                [logBlock appendAttributedString:[[NSAttributedString alloc] initWithString:str
                    attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: col}]];
            };

            appendText([NSString stringWithFormat:@"\n=== [AUTO SCAN] (%zu processes) ===\n", self->_eng->processes.count()],
                       RGB(56, 189, 248), YES);
            appendText(@"PID     STATE      CPU%   ACTIVITY BAR       MEM(MB)  NAME\n", RGB(148, 163, 184), YES);
            appendText(@"----------------------------------------------------------------------\n", RGB(51, 65, 85), NO);

            for (size_t i = 0; i < rows.size() && i < 15; ++i) {
                const ProcessInfo &p = rows[i];
                NSString *cpuStr = p.cpuPercent < 0 ? @"    -" :
                    [NSString stringWithFormat:@"%5.1f%%", p.cpuPercent];
                NSColor *rowCol = (p.cpuPercent > 30.0) ? RGB(244, 63, 94)
                                : (p.cpuPercent > 10.0) ? RGB(251, 191, 36)
                                : (p.cpuPercent > 2.0)  ? RGB(56, 189, 248) : RGB(203, 213, 225);
                NSString *line = [NSString stringWithFormat:@"%-7d %-10s %@  %@  %7.1f  %@\n",
                    p.pid, processStateName(p.state).c_str(), cpuStr,
                    makeBar(p.cpuPercent, 14),
                    p.residentBytes / (1024.0 * 1024.0),
                    toNS(p.name.substr(0, 24))];
                appendText(line, rowCol, p.cpuPercent > 20.0);
            }

            std::vector<ProcessInfo> rowsCopy = rows;
            MemoryInfo memCopy = mem;
            CpuBreakdown cpuCopy = cpuBd;

            dispatch_async(dispatch_get_main_queue(), ^{
                [self logAttributedString:logBlock];
                [self->_cpuGraph pushTotal:cpuCopy.totalPercent user:cpuCopy.userPercent sys:cpuCopy.systemPercent];
                [self->_memGraph pushMemory:memCopy];
                [self->_topView updateTopProcesses:rowsCopy];
                [self->_pressureGraph pushCpu:cpuCopy.totalPercent mem:memCopy.usedPercent() pressure:self->_headerView.pressureString];
                self->_headerView.runningCount = nRun;
                self->_headerView.sleepingCount = nSleep;
                self->_headerView.stoppedCount = nStop;
                self->_headerView.pressureString = (cpuCopy.totalPercent > 80.0 || memCopy.usedPercent() > 85.0) ? @"HIGH"
                                                 : (cpuCopy.totalPercent > 50.0 || memCopy.usedPercent() > 70.0) ? @"ELEVATED" : @"NORMAL";
                self->_headerView.statusString = @"Auto: Optimizing...";
                [self->_headerView setNeedsDisplay:YES];
            });

            // Step 2: Optimization Cycle
            OptimizationReport rpt = self->_eng->optimizer.runCycle(1000);
            MemoryInfo mem2;
            self->_eng->resources.readMemoryInfo(mem2);

            NSMutableAttributedString *optBlock = [[NSMutableAttributedString alloc] init];
            [optBlock appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"\n=== [AUTO OPTIMIZATION] ===\n"
                    attributes:@{NSFontAttributeName: [NSFont fontWithName:@"Menlo-Bold" size:11] ?: [NSFont boldSystemFontOfSize:11],
                                 NSForegroundColorAttributeName: RGB(16, 185, 129)}]];

            for (const std::string &l : rpt.lines()) {
                NSColor *lineCol = RGB(203, 213, 225);
                if (l.find("TARGET") != std::string::npos) lineCol = RGB(251, 191, 36);
                else if (l.find("IMPROVED") != std::string::npos) lineCol = RGB(16, 185, 129);
                else if (l.find("REASON") != std::string::npos) lineCol = RGB(56, 189, 248);
                [optBlock appendAttributedString:[[NSAttributedString alloc]
                    initWithString:[NSString stringWithFormat:@"%@\n", toNS(l)]
                        attributes:@{NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont systemFontOfSize:11],
                                     NSForegroundColorAttributeName: lineCol}]];
            }

            double cv2 = rpt.sysCpuAfter >= 0 ? rpt.sysCpuAfter : rpt.sysCpuBefore;
            NSInteger cycleKind = 0;
            if (rpt.improvementVerdict.find("IMPROVED") != std::string::npos) cycleKind = 2;
            else if (rpt.improvementVerdict.find("PARTIAL") != std::string::npos) cycleKind = 1;

            std::vector<TargetActionReport> targets2Copy = rpt.targets;
            MemoryInfo mem2Copy = mem2;

            dispatch_async(dispatch_get_main_queue(), ^{
                [self logAttributedString:optBlock];
                [self->_cpuGraph pushTotal:cv2 user:cv2*0.7 sys:cv2*0.3];
                [self->_memGraph pushMemory:mem2Copy];
                [self->_cpuGraph addMarkerKind:cycleKind];
                [self->_pressureGraph pushCpu:cv2 mem:mem2Copy.usedPercent() pressure:toNS(rpt.pressureLevel)];

                if (targets2Copy.empty()) {
                    double tgtB = rpt.targetCpuBefore;
                    double tgtA = rpt.targetExited ? -1.0 : rpt.targetCpuAfter;
                    [self->_optGraph pushBefore:tgtB after:tgtA kind:cycleKind name:toNS(rpt.targetName) pid:rpt.targetPid];
                } else {
                    for (const auto &t : targets2Copy) {
                        double tgtB = t.cpuBefore;
                        double tgtA = t.targetExited ? -1.0 : t.cpuAfter;
                        NSInteger tKind = 0;
                        if (t.verdict.find("IMPROVED") != std::string::npos || t.verdict.find("EXITED") != std::string::npos) tKind = 2;
                        else if (t.verdict.find("STABLE") != std::string::npos) tKind = 1;
                        [self->_optGraph pushBefore:tgtB after:tgtA kind:tKind name:toNS(t.name) pid:t.pid];
                    }
                }

                self->_headerView.statusString = @"Auto: Waiting 3s...";
                [self->_headerView setNeedsDisplay:YES];

                if (self->_autoModeRunning) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                            [self autoCycleStep];
                        });
                } else {
                    self->_headerView.statusString = @"Ready";
                    [self->_headerView setNeedsDisplay:YES];
                }
            });
        }
    });
}

- (IBAction)autoModeToggle:(id)sender {
    NSButton *btn = sender;
    if (btn.state == NSControlStateValueOn) {
        _autoModeRunning = YES;
        [self logWithStyle:@"\n▶ Smart Auto Mode ENABLED — scanning and adapting every 3s\n" color:RGB(16, 185, 129) bold:YES];
        _headerView.statusString = @"Auto: Starting...";
        [_headerView setNeedsDisplay:YES];
        [self autoCycleStep];
    } else {
        _autoModeRunning = NO;
        [_autoTimer invalidate]; _autoTimer = nil;
        _headerView.statusString = @"Ready";
        [_headerView setNeedsDisplay:YES];
        [self logWithStyle:@"\n■ Smart Auto Mode DISABLED\n" color:RGB(245, 158, 11) bold:YES];
    }
}

@end

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSMenu *menuBar = [[NSMenu alloc] init];
        NSMenuItem *item = [[NSMenuItem alloc] init];
        [menuBar addItem:item];
        NSMenu *appMenu = [[NSMenu alloc] init];
        [appMenu addItem:[[NSMenuItem alloc]
            initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"]];
        item.submenu = appMenu;
        app.mainMenu = menuBar;
        [app run];
    }
    return 0;
}
