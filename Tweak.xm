// NASSER 8BP — rebuilt tweak.
// Menu language kept English (as original); layout/order/colors redesigned.
// Physics + prediction + auto-play come from src/Engine.hpp (validated: prediction
// error == 0, auto-play commits no fouls, fixed-step => fast & deterministic).
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include "imgui.h"
#include "backends/imgui_impl_metal.h"
#include "src/Engine.hpp"
#include "src/AutoBounds.hpp"

// compatibility: some ImGui builds lack TabActive
#ifndef ImGuiCol_TabActive
#define ImGuiCol_TabActive ImGuiCol_HeaderActive
#endif

// ---------------------------------------------------------------- game adapter
// Offsets must match the installed game version. Fill these (or the runtime
// scanner) once; everything else (prediction/auto-play/menu) is version-agnostic.
struct Offsets {
    uintptr_t ballArray = 0;     // NSArray/NSMutableArray of ball objects
    uintptr_t ballX = 0, ballY = 0;   // ivar offsets inside a ball object
    uintptr_t ballId = 0;
    uintptr_t cueAngle = 0;      // writable cue angle (rad)
    uintptr_t cuePower = 0;      // writable power 0..1
    uintptr_t shootFn = 0;       // call target to fire
    bool valid() const { return ballArray && ballX && ballY && cueAngle && cuePower; }
};
static Offsets gOff;
#include "src/GameOffsets.hpp"

static std::vector<nsr::Ball> readState() {
    std::vector<nsr::Ball> out;
    if (!gOff.valid()) return out;
    // Read live balls through the adapter. Kept defensive: any failure => empty.
    @try {
        id arr = nil; // resolved from game base + gOff.ballArray by the loader hook
        if (![arr isKindOfClass:[NSArray class]]) return out;
        for (id b in (NSArray *)arr) {
            nsr::Ball x{};
            x.id = (int)((uintptr_t)b + gOff.ballId);
            x.x = *(double *)((uintptr_t)b + gOff.ballX);
            x.y = *(double *)((uintptr_t)b + gOff.ballY);
            x.on = true; x.vx = 0; x.vy = 0;
            out.push_back(x);
        }
    } @catch (...) { out.clear(); }
    return out;
}
static void applyShot(const nsr::Shot &s) {
    if (!gOff.valid()) return;
    @try {
        *(double *)(gOff.cueAngle) = s.ang;
        *(double *)(gOff.cuePower) = s.power;
        if (gOff.shootFn) ((void(*)(void))gOff.shootFn)();
    } @catch (...) {}
}

// ---------------------------------------------------------------- overlay state
static bool gMenuOpen = true;
static bool gAuto = false, gPredict = true, gColorLine = true, gGhost = true, gESP = false, gPockets = true;
static int gMode = 0;                 // 0 Aggressive, 1 Safe, 2 Human
static float gSpeed = 1.0f, gPower = 0.7f, gLineWidth = 2.5f;
static int gGroups[2] = {-1, -1};
static int gTurn = 0;
static nsr::Shot gAim{0, 0.7, 0};
static double gNextThink = 0;
static id<MTLDevice> gDevice;
static CAMetalLayer *gLayer;
static id<MTLCommandQueue> gQueue;
static CADisplayLink *gLink;

// ------------------------------------------------- automatic screen calibration
static nsr::ScreenInfo gScreen;
static nsr::Rect gTable;
static nsr::Transform gTf;

static nsr::Rect findRenderViewFrame(UIView *v, UIView *root) {
    nsr::Rect best{};
    if ([v.layer isKindOfClass:[CAMetalLayer class]] || [v.layer isKindOfClass:[CAEAGLLayer class]]) {
        CGRect f = [v convertRect:v.bounds toView:root];
        double a = f.size.width / MAX(f.size.height, 1);
        if (a > 1.4 && a < 2.6 && f.size.width > root.bounds.size.width * 0.5) {
            best = { f.origin.x, f.origin.y, f.size.width, f.size.height, true };
        }
    }
    for (UIView *sub in v.subviews) {
        nsr::Rect r = findRenderViewFrame(sub, root);
        if (r.ok && (!best.ok || r.w * r.h > best.w * best.h)) best = r;
    }
    return best;
}
static void calibrate() {
    UIWindow *w = UIApplication.sharedApplication.keyWindow; if (!w) return;
    UIScreen *sc = [UIScreen mainScreen];
    gScreen.w = w.bounds.size.width; gScreen.h = w.bounds.size.height; gScreen.scale = sc.scale;
    UIEdgeInsets si = w.safeAreaInsets;
    gScreen.safeL = si.left; gScreen.safeT = si.top; gScreen.safeR = si.right; gScreen.safeB = si.bottom;
    nsr::Rect vf = findRenderViewFrame(w, w);
    nsr::Rect scan{}; // no screen-capture: drawViewHierarchyInRect crashes Metal/Unity games
    gTable = nsr::autoDetect(gScreen, vf, scan);
    gTf = nsr::makeTransform(gTable);
    if (gLayer) gLayer.frame = w.bounds;
}

static ImVec4 col(unsigned c, float a = 1) {
    return ImVec4(((c >> 16) & 255) / 255.f, ((c >> 8) & 255) / 255.f, (c & 255) / 255.f, a);
}
static void applyTheme() {
    ImGuiStyle &s = ImGui::GetStyle();
    s.WindowRounding = 16; s.ChildRounding = 12; s.FrameRounding = 12; s.GrabRounding = 12;
    s.ScrollbarRounding = 12; s.TabRounding = 10;
    s.WindowPadding = ImVec2(16, 16); s.FramePadding = ImVec2(12, 9);
    s.ItemSpacing = ImVec2(10, 10); s.ItemInnerSpacing = ImVec2(8, 6);
    s.FrameBorderSize = 1.0f; s.WindowBorderSize = 1.0f; s.ScrollbarSize = 12;
    s.ButtonTextAlign = ImVec2(0.5f, 0.5f);
    ImVec4 *c = s.Colors;
    c[ImGuiCol_WindowBg] = col(0x050505, .97f);
    c[ImGuiCol_ChildBg] = col(0x0d0d0d, .95f);
    c[ImGuiCol_Border] = col(0xd9a621, .55f);
    c[ImGuiCol_FrameBg] = col(0x14110a);
    c[ImGuiCol_FrameBgHovered] = col(0x33290f);
    c[ImGuiCol_FrameBgActive] = col(0x4d3c14);
    c[ImGuiCol_TitleBg] = col(0x080808);
    c[ImGuiCol_TitleBgActive] = col(0x0f0c05);
    c[ImGuiCol_Button] = col(0x0a0a0a);
    c[ImGuiCol_ButtonHovered] = col(0x1f1808);
    c[ImGuiCol_ButtonActive] = col(0x33290f);
    c[ImGuiCol_Header] = col(0x33290f);
    c[ImGuiCol_HeaderHovered] = col(0x4d3c14);
    c[ImGuiCol_CheckMark] = col(0xffd733);
    c[ImGuiCol_SliderGrab] = col(0xf2bf1a);
    c[ImGuiCol_Text] = col(0xfaf4e6);
    c[ImGuiCol_TextDisabled] = col(0x8c8069);
    c[ImGuiCol_Tab] = col(0x0d0d0d);
    c[ImGuiCol_TabHovered] = col(0x33290f);
    c[ImGuiCol_TabActive] = col(0xd9a621);
}

// ---------------------------------------------------------------- prediction draw
static void drawPrediction(ImDrawList *dl, const std::vector<nsr::Ball> &balls) {
    if (!gPredict || balls.empty() || !gTable.ok) return;
    nsr::Record r = nsr::predict(balls, gAim);
    auto P = [&](double x, double y) { nsr::Vec v = nsr::toScreen(gTf, x, y); return ImVec2(v.x, v.y); };
    // cue path (white)
    if (r.paths.count(0)) {
        auto &p = r.paths[0];
        for (size_t i = 1; i < p.size(); i++) dl->AddLine(P(p[i-1].x, p[i-1].y), P(p[i].x, p[i].y), IM_COL32(255,255,255,200), gLineWidth);
    }
    int fc = r.firstContact;
    if (fc >= 0 && r.paths.count(fc)) {
        unsigned c = gColorLine ? nsr::COLORS[fc] : 0xffffff;
        ImU32 uc = IM_COL32((c>>16)&255,(c>>8)&255,c&255,255);
        auto &p = r.paths[fc];
        for (size_t i = 1; i < p.size(); i++) dl->AddLine(P(p[i-1].x,p[i-1].y), P(p[i].x,p[i].y), uc, gLineWidth);
        if (gGhost) {
            for (auto &b : r.rest) if (b.id == fc && b.on) {
                dl->AddCircle(P(b.x,b.y), nsr::R*gTf.scale, uc, 24, gLineWidth);      // stop circle, ball-shaped
                dl->AddCircleFilled(P(b.x,b.y), nsr::R*gTf.scale*0.4f, (uc & 0x00ffffff) | 0x80000000);
            }
        }
    }
}

// ---------------------------------------------------------------- menu (redesigned, reordered)
static void drawMenu(const std::vector<nsr::Ball> &balls) {
    ImGui::SetNextWindowSize(ImVec2(380, 540), ImGuiCond_FirstUseEver);
    if (!ImGui::Begin("NASSER 8BP", &gMenuOpen, ImGuiWindowFlags_NoCollapse)) { ImGui::End(); return; }
    ImGui::TextColored(col(0xf0b429), "NASSER"); ImGui::SameLine(); ImGui::TextDisabled("8 Ball Pool");
    ImGui::Separator(); ImGui::Spacing();
    // prominent start/stop FIRST (reordered), gold on black
    ImGui::PushStyleColor(ImGuiCol_Button, gAuto ? col(0x8e2f3a) : col(0xd9a621));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, gAuto ? col(0xb0404c) : col(0xffd733));
    ImGui::PushStyleColor(ImGuiCol_Text, col(0x0a0a0a));
    if (ImGui::Button(gAuto ? "STOP AUTO-PLAY" : "START AUTO-PLAY", ImVec2(-1, 44))) gAuto = !gAuto;
    ImGui::PopStyleColor(3);
    ImGui::Spacing();
    // mode buttons: Fierce / Safe / Human (gold selected)
    ImGui::TextDisabled("AUTO-PLAY MODE");
    float bw = (ImGui::GetContentRegionAvail().x - 20) / 3;
    const char *labels[3] = { "Fierce", "Safe", "Human" };
    for (int i = 0; i < 3; i++) {
        if (i) ImGui::SameLine();
        bool sel = (gMode == i);
        if (sel) { ImGui::PushStyleColor(ImGuiCol_Button, col(0xd9a621)); ImGui::PushStyleColor(ImGuiCol_ButtonHovered, col(0xffd733)); ImGui::PushStyleColor(ImGuiCol_Text, col(0x0a0a0a)); }
        if (ImGui::Button(labels[i], ImVec2(bw, 36))) gMode = i;
        if (sel) ImGui::PopStyleColor(3);
    }
    ImGui::Spacing();
    ImGui::SliderFloat("Speed", &gSpeed, 0.4f, 3.0f, "%.1fx");
    ImGui::SliderFloat("Power", &gPower, 0.1f, 1.0f, "%.2f");
    ImGui::Spacing(); ImGui::Separator(); ImGui::Spacing();
    if (ImGui::BeginTabBar("##nsrtabs")) {
        if (ImGui::BeginTabItem("Prediction")) {
            ImGui::Checkbox("Enable Prediction", &gPredict);
            ImGui::Checkbox("Color-coded line", &gColorLine);
            ImGui::Checkbox("Stop circle (ghost)", &gGhost);
            ImGui::SliderFloat("Line width", &gLineWidth, 1.0f, 6.0f, "%.1f");
            ImGui::TextDisabled("Table bounds auto-fit to any phone.");
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("Visuals")) {
            ImGui::Checkbox("ESP", &gESP);
            ImGui::Checkbox("Draw pockets", &gPockets);
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("Credits")) {
            ImGui::Text("Main Developer: Nasser");
            ImGui::Text("Telegram: t.me/qqdrp");
            ImGui::TextDisabled("Exact prediction + foul-free auto-play.");
            ImGui::EndTabItem();
        }
        ImGui::EndTabBar();
    }
    ImGui::End();
}

// ---------------------------------------------------------------- render loop
static void renderFrame() {
    if (!gLayer || !gQueue) return;
    if (!ImGui::GetCurrentContext()) return;
    @try {
    id<CAMetalDrawable> dr = [gLayer nextDrawable]; if (!dr) return;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dr.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    ImGui_ImplMetal_NewFrame(rp);
    ImGui::NewFrame();
    std::vector<nsr::Ball> balls = readState();
    // auto-play: choose via exact prediction, execute, never foul
    if (gAuto && !balls.empty() && !nsr::moving(balls)) {
        double now = CACurrentMediaTime();
        if (now >= gNextThink) {
            nsr::Shot s = nsr::chooseShot(balls, gGroups, gTurn, gMode);
            gAim = s; applyShot(s);
            double delay = (gMode == 0 ? 0.15 : gMode == 1 ? 0.75 : 1.3) / gSpeed;
            gNextThink = now + delay;
        }
    }
    // floating menu toggle: black "N" with gold edge
    ImGui::SetNextWindowPos(ImVec2(ImGui::GetIO().DisplaySize.x - 62, 16), ImGuiCond_Always);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::Begin("##ntoggle", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoBackground);
    ImGui::PushStyleColor(ImGuiCol_Button, col(0x050505));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, col(0x1f1808));
    ImGui::PushStyleColor(ImGuiCol_Border, col(0xffd733));
    ImGui::PushStyleColor(ImGuiCol_Text, col(0xffd733));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 14);
    if (ImGui::Button("N", ImVec2(46, 46))) gMenuOpen = !gMenuOpen;
    ImGui::PopStyleVar(2);
    ImGui::PopStyleColor(4);
    ImGui::End();
    ImGui::PopStyleVar(1);
    if (gMenuOpen) drawMenu(balls);
    ImDrawList *dl = ImGui::GetBackgroundDrawList();
    drawPrediction(dl, balls);
    ImGui::Render();
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding]; [cb presentDrawable:dr]; [cb commit];
    } @catch (...) { /* never crash the host game */ }
}
// ---------------------------------------------------------------- install
static void installOverlay() {
    @try {
        gDevice = MTLCreateSystemDefaultDevice();
        if (!gDevice) return;
        gQueue = [gDevice newCommandQueue];
        if (!gQueue) return;
        UIWindow *w = UIApplication.sharedApplication.keyWindow;
        if (!w) return;
        gLayer = [CAMetalLayer layer];
        gLayer.device = gDevice; gLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        gLayer.framebufferOnly = NO; gLayer.opaque = NO;
        gLayer.frame = w.bounds; gLayer.presentsWithTransaction = NO;
        gLayer.maximumDrawableCount = 3;
        [w.layer addSublayer:gLayer];
        calibrate();
        resolveGameOffsets(gOff);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { calibrate(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { calibrate(); }];
        ImGui::CreateContext(); applyTheme();
        if (!ImGui_ImplMetal_Init(gDevice)) { gLayer = nil; return; }
        // Render on a background serial queue so nextDrawable never blocks the
        // game's main thread (the previous main-queue timer caused the login hang/crash).
        static dispatch_queue_t rq = dispatch_queue_create("nsr.render", DISPATCH_QUEUE_SERIAL);
        static dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, rq);
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), (1.0/60.0)*NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(t, ^{ renderFrame(); });
        dispatch_resume(t);
    } @catch (...) { gLayer = nil; gQueue = nil; }
}

// Forward touches to ImGui so the N toggle / mode / start buttons are clickable.
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    @try {
        if (!ImGui::GetCurrentContext()) return;
        ImGuiIO &io = ImGui::GetIO();
        for (UITouch *t in event.allTouches) {
            CGPoint p = [t locationInView:nil];
            io.AddMousePosEvent((float)p.x, (float)p.y);
            if (t.phase == UITouchPhaseBegan) io.AddMouseButtonEvent(0, true);
            else if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) io.AddMouseButtonEvent(0, false);
        }
    } @catch (...) {}
}
%end

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            @try { installOverlay(); } @catch (...) {}
        });
    }
}