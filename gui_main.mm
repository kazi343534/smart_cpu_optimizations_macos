/*
 * SMART PROCESS OPTIMIZER - macOS GUI
 * Simple, robust: buttons in a toolbar bar at top, content below.
 */

#import <Cocoa/Cocoa.h>
#include <dispatch/dispatch.h>

#include <algorithm>
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

// ── GraphView ──────────────────────────────────────────────────────

@interface GraphView : NSView {
    NSMutableArray<NSNumber *> *_series;
    NSMutableArray<NSNumber *> *_mIdx;
    NSMutableArray<NSNumber *> *_mKind;
    NSString *_title;
    NSColor *_color;
}
- (instancetype)initWithFrame:(NSRect)f title:(NSString *)t color:(NSColor *)c;
- (void)pushValue:(double)v;
- (void)addMarkerKind:(NSInteger)k;
@end

@implementation GraphView
- (instancetype)initWithFrame:(NSRect)f title:(NSString *)t color:(NSColor *)c {
    self = [super initWithFrame:f];
    if (self) { _series=[NSMutableArray array]; _mIdx=[NSMutableArray array];
        _mKind=[NSMutableArray array]; _title=[t copy]; _color=c; }
    return self;
}
- (void)pushValue:(double)v {
    [_series addObject:@(std::clamp(v, 0.0, 100.0))];
    BOOL shifted = NO;
    while (_series.count > 90) { [_series removeObjectAtIndex:0]; shifted = YES; }
    if (shifted) {
        NSMutableArray *ki=[NSMutableArray array], *kk=[NSMutableArray array];
        for (NSUInteger i=0; i<_mIdx.count; ++i) {
            NSInteger idx=[_mIdx[i] integerValue]-1;
            if (idx>=1) { [ki addObject:@(idx)]; [kk addObject:_mKind[i]]; }
        }
        _mIdx=ki; _mKind=kk;
    }
    [self setNeedsDisplay:YES];
}
- (void)addMarkerKind:(NSInteger)k {
    if (_series.count==0) return;
    [_mIdx addObject:@(_series.count-1)]; [_mKind addObject:@(k)];
    [self setNeedsDisplay:YES];
}
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty; NSRect b=self.bounds;
    [[NSColor colorWithCalibratedWhite:0.99 alpha:1.0] setFill];
    NSBezierPath *bg=[NSBezierPath bezierPathWithRoundedRect:b xRadius:6 yRadius:6];
    [bg fill]; [[NSColor colorWithCalibratedWhite:0.80 alpha:1.0] setStroke];
    [bg setLineWidth:1]; [bg stroke];
    CGFloat w=b.size.width-16, h=b.size.height-34, x0=8, y0=6;
    [[NSColor colorWithCalibratedWhite:0.84 alpha:1.0] setStroke];
    for (int g=1; g<=4; ++g) {
        CGFloat gy=y0+h*g/4.0;
        NSBezierPath *gl=[NSBezierPath bezierPath];
        [gl moveToPoint:NSMakePoint(x0,gy)]; [gl lineToPoint:NSMakePoint(x0+w,gy)];
        gl.lineWidth=0.5; [gl stroke];
    }
    NSUInteger n=_series.count;
    if (n>=2) {
        NSBezierPath *area=[NSBezierPath bezierPath];
        [area moveToPoint:NSMakePoint(x0,y0)];
        for (NSUInteger i=0; i<n; ++i) {
            CGFloat px=x0+w*i/(CGFloat)(n-1);
            CGFloat py=y0+h*[_series[i] doubleValue]/100.0;
            [area lineToPoint:NSMakePoint(px,py)];
        }
        [area lineToPoint:NSMakePoint(x0+w,y0)]; [area closePath];
        [[_color colorWithAlphaComponent:0.20] setFill]; [area fill];
        NSBezierPath *line=[NSBezierPath bezierPath];
        for (NSUInteger i=0; i<n; ++i) {
            CGFloat px=x0+w*i/(CGFloat)(n-1);
            CGFloat py=y0+h*[_series[i] doubleValue]/100.0;
            i==0?[line moveToPoint:NSMakePoint(px,py)]:[line lineToPoint:NSMakePoint(px,py)];
        }
        [_color setStroke]; line.lineWidth=1.6; [line stroke];
        for (NSUInteger m=0; m<_mIdx.count; ++m) {
            NSInteger idx=[_mIdx[m] integerValue];
            if (idx<0||idx>=(NSInteger)n) continue;
            CGFloat mx=x0+w*idx/(CGFloat)(n-1);
            NSColor *mc=[_mKind[m] integerValue]==2?[NSColor systemGreenColor]
                       :[_mKind[m] integerValue]==1?[NSColor systemOrangeColor]:[NSColor systemRedColor];
            NSBezierPath *tri=[NSBezierPath bezierPath];
            [tri moveToPoint:NSMakePoint(mx-4,y0+h-2)];
            [tri lineToPoint:NSMakePoint(mx+4,y0+h-2)];
            [tri lineToPoint:NSMakePoint(mx,y0+h-9)];
            [tri closePath]; [mc setFill]; [tri fill];
        }
    }
    double last=n?[_series.lastObject doubleValue]:-1;
    NSString *label=last>=0?[NSString stringWithFormat:@"%@  %.1f%%",_title,last]:_title;
    [label drawAtPoint:NSMakePoint(x0+2,b.size.height-20)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.15 alpha:1.0]}];
}
@end

// ── OptimizationChartView ──────────────────────────────────────────

@interface OptimizationChartView : NSView { NSMutableArray<NSDictionary *> *_events; }
- (void)pushBefore:(double)b after:(double)a kind:(NSInteger)k;
@end

@implementation OptimizationChartView
- (instancetype)initWithFrame:(NSRect)f {
    self=[super initWithFrame:f]; if(self) _events=[NSMutableArray array]; return self;
}
- (void)pushBefore:(double)before after:(double)after kind:(NSInteger)k {
    [_events addObject:@{@"before":@(std::clamp(before,0.0,100.0)),
        @"after":@(std::clamp(std::max(after,0.0),0.0,100.0)),
        @"exited":@(after<0),@"kind":@(k)}];
    while (_events.count>12) [_events removeObjectAtIndex:0];
    [self setNeedsDisplay:YES];
}
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty; NSRect b=self.bounds;
    [[NSColor colorWithCalibratedWhite:0.99 alpha:1.0] setFill];
    NSBezierPath *bg=[NSBezierPath bezierPathWithRoundedRect:b xRadius:6 yRadius:6];
    [bg fill]; [[NSColor colorWithCalibratedWhite:0.80 alpha:1.0] setStroke];
    bg.lineWidth=1; [bg stroke];
    CGFloat w=b.size.width-16, h=b.size.height-46, x0=8, y0=8;
    NSDictionary *a1=@{NSFontAttributeName:[NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.15 alpha:1.0]};
    [@"Optimization effect" drawAtPoint:NSMakePoint(x0+2,b.size.height-20) withAttributes:a1];
    NSDictionary *a2=@{NSFontAttributeName:[NSFont systemFontOfSize:9],
        NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.40 alpha:1.0]};
    [@"grey=before  colour=after" drawAtPoint:NSMakePoint(x0+2,b.size.height-32) withAttributes:a2];
    if (_events.count==0) {
        [@"Click Run Smart Optimization" drawAtPoint:NSMakePoint(x0+10,y0+h/2) withAttributes:a2];
        return;
    }
    [[NSColor colorWithCalibratedWhite:0.55 alpha:1.0] setStroke];
    NSBezierPath *ax=[NSBezierPath bezierPath];
    [ax moveToPoint:NSMakePoint(x0,y0)]; [ax lineToPoint:NSMakePoint(x0+w,y0)];
    ax.lineWidth=1; [ax stroke];
    CGFloat gw=w/_events.count, bw=gw*0.30;
    for (NSUInteger i=0; i<_events.count; ++i) {
        NSDictionary *ev=_events[i];
        double before=[ev[@"before"] doubleValue], after=[ev[@"after"] doubleValue];
        NSInteger kind=[ev[@"kind"] integerValue]; BOOL exited=[ev[@"exited"] boolValue];
        CGFloat gx=x0+gw*i+gw*0.19;
        [[NSColor colorWithCalibratedWhite:0.72 alpha:1.0] setFill];
        [[NSBezierPath bezierPathWithRect:NSMakeRect(gx,y0,bw,h*before/100.0)] fill];
        if (!exited) {
            NSColor *col=kind==2?[NSColor systemGreenColor]:kind==1?[NSColor systemOrangeColor]:[NSColor systemRedColor];
            [col setFill];
            [[NSBezierPath bezierPathWithRect:NSMakeRect(gx+bw+1,y0,bw,h*after/100.0)] fill];
        }
    }
}
@end

// ── AppDelegate ─────────────────────────────────────────────────────

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@end

@implementation AppDelegate {
    NSTextView  *_output;
    GraphView   *_cpuGraph;
    GraphView   *_memGraph;
    OptimizationChartView *_optGraph;
    NSTextField *_statusLabel;
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

- (void)log:(NSString *)msg {
    [_output.textStorage appendAttributedString:
        [[NSAttributedString alloc] initWithString:msg
            attributes:@{NSFontAttributeName:[NSFont fontWithName:@"Menlo" size:11]}]];
    [_output scrollRangeToVisible:NSMakeRange(_output.string.length, 0)];
}

- (void)setStatus:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusLabel.stringValue = s;
    });
}

// ── SCAN ────────────────────────────────────────────────────────────

- (void)runScan {
    @autoreleasepool {
        NSLog(@"[SCAN] bg work start");
        _eng->processes.refresh(200);
        double sysCpu = _eng->resources.measureCpuUsage(1000);
        _eng->processes.refresh(1000);
        MemoryInfo mem; _eng->resources.readMemoryInfo(mem);
        double memPct = mem.usedPercent();

        std::vector<ProcessInfo> rows = _eng->processes.processes();
        std::sort(rows.begin(), rows.end(),
            [](const ProcessInfo &a, const ProcessInfo &b){ return a.cpuPercent>b.cpuPercent; });

        NSMutableString *table = [NSMutableString
            stringWithFormat:@"\n=== PROCESS SCAN (%zu processes) ===\n"
                               "PID   STATE     CPU%%  GRAPH         MEM(MB)  NAME\n"
                               "--------------------------------------------------------\n",
                               _eng->processes.count()];
        for (size_t i=0; i<rows.size()&&i<20; ++i) {
            const ProcessInfo &p = rows[i];
            NSString *cpuStr = p.cpuPercent<0 ? @"    -" :
                [NSString stringWithFormat:@"%5.1f%%", p.cpuPercent];
            [table appendFormat:@"%-6d %-9s %@  %@  %6.1f  %@\n",
                p.pid, processStateName(p.state).c_str(), cpuStr,
                makeBar(p.cpuPercent, 12),
                p.residentBytes/(1024.0*1024.0),
                toNS(p.name.substr(0,24))];
        }

        NSLog(@"[SCAN] bg done cpu=%.1f mem=%.1f", sysCpu, memPct);
        NSString *tableCopy = [table copy];
        double cv=sysCpu, mv=memPct;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[SCAN] updating UI");
            [self log:tableCopy];
            [self->_cpuGraph pushValue:cv];
            [self->_memGraph pushValue:mv];
            self->_scanBusy = NO;
            self->_statusLabel.stringValue = @"Ready";
            NSLog(@"[SCAN] done, buttons re-enabled");
        });
    }
}

- (void)doScanClick {
    NSLog(@"[SCAN] doScanClick entered, _scanBusy=%d", _scanBusy);
    if (_scanBusy) return;
    _scanBusy = YES;
    _statusLabel.stringValue = @"Scanning...";
    NSLog(@"[SCAN] dispatching to bg queue");
    dispatch_async(_bgQ, ^{ [self runScan]; });
}

// ── OPTIMIZE ────────────────────────────────────────────────────────

- (void)runOptimize {
    @autoreleasepool {
        NSLog(@"[OPT] bg work start");
        OptimizationReport rpt = _eng->optimizer.runCycle(1000);
        MemoryInfo mem; _eng->resources.readMemoryInfo(mem);

        NSMutableString *text = [NSMutableString
            stringWithString:@"\n=== SMART OPTIMIZATION ===\n"];
        for (const std::string &l : rpt.lines())
            [text appendFormat:@"%@\n", toNS(l)];

        double cv = rpt.sysCpuAfter>=0 ? rpt.sysCpuAfter : rpt.sysCpuBefore;
        double mv = mem.usedPercent();
        double tgtB = rpt.targetCpuBefore;
        double tgtA = rpt.targetExited ? -1.0 : rpt.targetCpuAfter;
        BOOL ok = rpt.success;
        NSInteger kind = 0;
        if (rpt.improvementVerdict.find("IMPROVED")!=std::string::npos) kind=2;
        else if (rpt.improvementVerdict.find("PARTIAL")!=std::string::npos) kind=1;

        NSLog(@"[OPT] bg done ok=%d kind=%ld", ok, (long)kind);
        NSString *textCopy = [text copy];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self log:textCopy];
            [self->_cpuGraph pushValue:cv];
            [self->_memGraph pushValue:mv];
            [self->_cpuGraph addMarkerKind:kind];
            [self->_optGraph pushBefore:tgtB after:tgtA kind:kind];
            self->_optBusy = NO;
            self->_statusLabel.stringValue = ok ? @"Done (improved)" : @"Done (watch)";
            NSLog(@"[OPT] done");
        });
    }
}

- (void)doOptClick {
    NSLog(@"[OPT] doOptClick entered, _optBusy=%d", _optBusy);
    if (_optBusy) return;
    _optBusy = YES;
    _statusLabel.stringValue = @"Optimizing...";
    dispatch_async(_bgQ, ^{ [self runOptimize]; });
}

- (void)doLogClick {
    NSLog(@"[LOG] clicked");
    NSMutableString *t = [NSMutableString stringWithString:@"\n=== ACTIVITY LOG ===\n"];
    const auto &h = _eng->logger.history();
    size_t start = h.size()>30 ? h.size()-30 : 0;
    for (size_t i=start; i<h.size(); ++i)
        [t appendFormat:@"%@\n", toNS(h[i])];
    if (h.empty()) [t appendString:@"(empty)\n"];
    [self log:t];
}

// ── Window ──────────────────────────────────────────────────────────

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    _bgQ = dispatch_queue_create("spo.bg", DISPATCH_QUEUE_SERIAL);
    _scanBusy = NO;
    _optBusy = NO;

    SystemInfo si;
    if (!loadSystemInfo(si)) { [[NSApplication sharedApplication] terminate:nil]; return; }
    _eng = std::make_unique<EngineCore>(si);
    if (!_eng->init()) { [[NSApplication sharedApplication] terminate:nil]; return; }

    // WINDOW
    _window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 920, 806)
                  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Smart Process Optimizer - CSE323";
    _window.releasedWhenClosed = NO;
    _window.backgroundColor = [NSColor colorWithCalibratedWhite:0.94 alpha:1.0];
    NSView *c = _window.contentView;

    // STATUS + HW INFO (top)
    NSTextField *hw = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 770, 500, 20)];
    hw.stringValue = [NSString stringWithFormat:@"%@ | %d cores | %.0f GB RAM",
        toNS(_eng->info.model), _eng->info.logicalCpuCores,
        _eng->info.totalPhysicalBytes/(1024.0*1024.0*1024.0)];
    hw.bezeled=NO; hw.editable=NO; hw.drawsBackground=NO;
    hw.font=[NSFont systemFontOfSize:11];
    hw.textColor=[NSColor colorWithCalibratedWhite:0.55 alpha:1.0];
    [c addSubview:hw];

    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(660, 770, 244, 20)];
    _statusLabel.stringValue = @"Ready";
    _statusLabel.bezeled=NO; _statusLabel.editable=NO; _statusLabel.drawsBackground=NO;
    _statusLabel.font=[NSFont boldSystemFontOfSize:13];
    _statusLabel.textColor=[NSColor systemBlueColor];
    _statusLabel.alignment=NSTextAlignmentRight;
    [c addSubview:_statusLabel];

    // GRAPHS (y=606..766)
    _cpuGraph = [[GraphView alloc] initWithFrame:NSMakeRect(16,606,289,160)
        title:@"System CPU %" color:[NSColor systemGreenColor]];
    _memGraph = [[GraphView alloc] initWithFrame:NSMakeRect(315,606,290,160)
        title:@"Memory used %" color:[NSColor systemBlueColor]];
    _optGraph = [[OptimizationChartView alloc] initWithFrame:NSMakeRect(615,606,289,160)];
    [c addSubview:_cpuGraph]; [c addSubview:_memGraph]; [c addSubview:_optGraph];

    // BUTTONS - using a toolbar panel at y=590 (between graphs and scroll view)
    CGFloat btnY = 566;
    CGFloat btnH = 32;
    NSButton *scanBtn = [[NSButton alloc] initWithFrame:NSMakeRect(16, btnY, 140, btnH)];
    scanBtn.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Refresh Scan"
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName:[NSColor blackColor]}];
    scanBtn.bezelStyle = NSBezelStyleRounded;
    scanBtn.target = self;
    scanBtn.action = @selector(doScanClick);
    [c addSubview:scanBtn];

    NSButton *optBtn = [[NSButton alloc] initWithFrame:NSMakeRect(166, btnY, 220, btnH)];
    optBtn.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Run Smart Optimization"
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName:[NSColor blackColor]}];
    optBtn.bezelStyle = NSBezelStyleRounded;
    optBtn.target = self;
    optBtn.action = @selector(doOptClick);
    [c addSubview:optBtn];

    NSButton *logBtn = [[NSButton alloc] initWithFrame:NSMakeRect(396, btnY, 110, btnH)];
    logBtn.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Show Log"
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName:[NSColor blackColor]}];
    logBtn.bezelStyle = NSBezelStyleRounded;
    logBtn.target = self;
    logBtn.action = @selector(doLogClick);
    [c addSubview:logBtn];

    NSButton *autoModeCheck = [[NSButton alloc] initWithFrame:NSMakeRect(520, btnY+3, 250, 26)];
    [autoModeCheck setButtonType:NSButtonTypeSwitch];
    autoModeCheck.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Smart Auto Mode (3s)"
            attributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:12],
                         NSForegroundColorAttributeName:[NSColor blackColor]}];
    autoModeCheck.target = self;
    autoModeCheck.action = @selector(autoModeToggle:);
    [c addSubview:autoModeCheck];

    // SCROLL VIEW with output (below buttons)
    NSScrollView *scroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(16, 16, 888, 540)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    _output = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
    _output.editable = NO;
    _output.font = [NSFont fontWithName:@"Menlo" size:11];
    _output.textColor = [NSColor colorWithCalibratedWhite:0.12 alpha:1.0];
    _output.backgroundColor = [NSColor colorWithCalibratedWhite:0.99 alpha:1.0];
    _output.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    scroll.documentView = _output;
    [c addSubview:scroll];

    [self log:@"Smart Process Optimizer ready.\n"
            "Live kernel data: sysctl / Mach host_statistics / libproc.\n"
            "Click Refresh Scan to begin.\n"];

    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // AUTO-START scan
    [self performSelector:@selector(doScanClick) withObject:nil afterDelay:0.5];
}

// ── SMART AUTO MODE ────────────────────────────────────────────────
// Single cycle: scan → optimize → sleep 3s → repeat
// Runs entirely on the bg queue; only UI updates touch main queue.

- (void)autoCycleStep {
    if (!_autoModeRunning) return;

    dispatch_async(_bgQ, ^{
        @autoreleasepool {
            // ── STEP 1: Refresh Scan ──
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusLabel.stringValue = @"Auto: Scanning...";
            });
            self->_eng->processes.refresh(200);
            double sysCpu = self->_eng->resources.measureCpuUsage(1000);
            self->_eng->processes.refresh(1000);
            MemoryInfo mem; self->_eng->resources.readMemoryInfo(mem);
            double memPct = mem.usedPercent();

            std::vector<ProcessInfo> rows = self->_eng->processes.processes();
            std::sort(rows.begin(), rows.end(),
                [](const ProcessInfo &a, const ProcessInfo &b){ return a.cpuPercent>b.cpuPercent; });

            NSMutableString *table = [NSMutableString
                stringWithFormat:@"\n=== PROCESS SCAN (%zu processes) ===\n"
                                   "PID   STATE     CPU%%  GRAPH         MEM(MB)  NAME\n"
                                   "--------------------------------------------------------\n",
                                   self->_eng->processes.count()];
            for (size_t i=0; i<rows.size()&&i<20; ++i) {
                const ProcessInfo &p = rows[i];
                NSString *cpuStr = p.cpuPercent<0 ? @"    -" :
                    [NSString stringWithFormat:@"%5.1f%%", p.cpuPercent];
                [table appendFormat:@"%-6d %-9s %@  %@  %6.1f  %@\n",
                    p.pid, processStateName(p.state).c_str(), cpuStr,
                    makeBar(p.cpuPercent, 12),
                    p.residentBytes/(1024.0*1024.0),
                    toNS(p.name.substr(0,24))];
            }
            NSString *tableCopy = [table copy];
            double cv=sysCpu, mv=memPct;

            // Update UI with scan results
            dispatch_async(dispatch_get_main_queue(), ^{
                [self log:tableCopy];
                [self->_cpuGraph pushValue:cv];
                [self->_memGraph pushValue:mv];
                self->_statusLabel.stringValue = @"Auto: Optimizing...";
            });

            // ── STEP 2: Smart Optimization (using fresh data) ──
            OptimizationReport rpt = self->_eng->optimizer.runCycle(1000);
            MemoryInfo mem2; self->_eng->resources.readMemoryInfo(mem2);

            NSMutableString *text = [NSMutableString
                stringWithString:@"\n=== SMART OPTIMIZATION ===\n"];
            for (const std::string &l : rpt.lines())
                [text appendFormat:@"%@\n", toNS(l)];

            double cv2 = rpt.sysCpuAfter>=0 ? rpt.sysCpuAfter : rpt.sysCpuBefore;
            double mv2 = mem2.usedPercent();
            double tgtB = rpt.targetCpuBefore;
            double tgtA = rpt.targetExited ? -1.0 : rpt.targetCpuAfter;
            NSInteger kind = 0;
            if (rpt.improvementVerdict.find("IMPROVED")!=std::string::npos) kind=2;
            else if (rpt.improvementVerdict.find("PARTIAL")!=std::string::npos) kind=1;

            NSString *textCopy = [text copy];

            // Update UI with optimization results
            dispatch_async(dispatch_get_main_queue(), ^{
                [self log:textCopy];
                [self->_cpuGraph pushValue:cv2];
                [self->_memGraph pushValue:mv2];
                [self->_cpuGraph addMarkerKind:kind];
                [self->_optGraph pushBefore:tgtB after:tgtA kind:kind];
                self->_statusLabel.stringValue = @"Auto: Waiting 3s...";

                // ── STEP 3: Schedule next cycle after 3 seconds ──
                if (self->_autoModeRunning) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                            [self autoCycleStep];
                        });
                } else {
                    self->_statusLabel.stringValue = @"Ready";
                }
            });
        }
    });
}

- (IBAction)autoModeToggle:(id)sender {
    NSButton *btn = sender;
    NSLog(@"[AUTO] toggle state=%ld", (long)btn.state);
    if (btn.state == NSControlStateValueOn) {
        _autoModeRunning = YES;
        [self log:@"\n▶ Smart Auto Mode ON — scan → optimize → 3s → repeat\n"];
        _statusLabel.stringValue = @"Auto: Starting...";
        // Start first cycle immediately
        [self autoCycleStep];
    } else {
        _autoModeRunning = NO;
        [_autoTimer invalidate]; _autoTimer = nil;
        _statusLabel.stringValue = @"Ready";
        [self log:@"\n■ Smart Auto Mode OFF\n"];
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
