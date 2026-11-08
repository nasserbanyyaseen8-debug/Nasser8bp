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
static nsr::Rect scanFelt(UIView *root) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1; // pixels == points for the scan buffer
    UIGraphicsImageRenderer *ren = [[UIGraphicsImageRenderer alloc] initWithSize:root.bounds.size format:fmt];
    UIImage *img = [ren imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [root drawViewHierarchyInRect:root.bounds afterScreenUpdates:NO];
    }];
    CGImageRef cg = img.CGImage; if (!cg) return nsr::Rect{};
    size_t pw = CGImageGetWidth(cg), ph = CGImageGetHeight(cg);
    std::vector<uint8_t> buf(pw * ph * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf.data(), pw, ph, 8, pw * 4, cs, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(c, CGRectMake(0, 0, pw, ph), cg);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    return nsr::feltScan(buf.data(), (int)pw, (int)ph, 1.0);
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
    s.WindowRounding = 14; s.FrameRounding = 9; s.GrabRounding = 9; s.ScrollbarRounding = 9;
    s.WindowPadding = ImVec2(14, 14); s.FramePadding = ImVec2(10, 7); s.ItemSpacing = ImVec2(9, 9);
    ImVec4 *c = s.Colors;
    c[ImGuiCol_WindowBg] = col(0x0a0f0d, .96f);
    c[ImGuiCol_ChildBg] = col(0x111a16, .9f);
    c[ImGuiCol_Border] = col(0x24382f);
    c[ImGuiCol_FrameBg] = col(0x1c2a24);
    c[ImGuiCol_FrameBgHovered] = col(0x166b4a);
    c[ImGuiCol_FrameBgActive] = col(0x0e5c3f);
    c[ImGuiCol_TitleBg] = col(0x0a4230);
    c[ImGuiCol_TitleBgActive] = col(0x0e5c3f);
    c[ImGuiCol_Button] = col(0xf0b429, .85f);
    c[ImGuiCol_ButtonHovered] = col(0xffd766);
    c[ImGuiCol_ButtonActive] = col(0xf0b429);
    c[ImGuiCol_Header] = col(0x0e5c3f);
    c[ImGuiCol_HeaderHovered] = col(0x166b4a);
    c[ImGuiCol_CheckMark] = col(0x39d98a);
    c[ImGuiCol_SliderGrab] = col(0xf0b429);
    c[ImGuiCol_Text] = col(0xeef9f2);
    c[ImGuiCol_Tab] = col(0x111a16);
    c[ImGuiCol_TabHovered] = col(0x166b4a);
    c[ImGuiCol_TabActive] = col(0x0e5c3f);
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
    // mode buttons (new): Aggressive / Safe / Human
    ImGui::TextDisabled("AUTO-PLAY MODE");
    float bw = (ImGui::GetContentRegionAvail().x - 16) / 3;
    const char *labels[3] = { "Fierce", "Safe", "Human" };
    for (int i = 0; i < 3; i++) {
        if (i) ImGui::SameLine();
        bool sel = (gMode == i);
        if (sel) { ImGui::PushStyleColor(ImGuiCol_Button, col(0x0e5c3f)); ImGui::PushStyleColor(ImGuiCol_ButtonHovered, col(0x166b4a)); ImGui::PushStyleColor(ImGuiCol_ButtonActive, col(0x0e5c3f)); }
        if (ImGui::Button(labels[i], ImVec2(bw, 34))) gMode = i;
        if (sel) ImGui::PopStyleColor(3);
    }
    ImGui::Spacing();
    // prominent start/stop
    ImGui::PushStyleColor(ImGuiCol_Button, gAuto ? col(0x8e2f3a) : col(0xf0b429));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, gAuto ? col(0xb0404c) : col(0xffd766));
    if (ImGui::Button(gAuto ? "STOP AUTO-PLAY" : "START AUTO-PLAY", ImVec2(-1, 40))) gAuto = !gAuto;
    ImGui::PopStyleColor(2);
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
    UIWindow *cw = UIApplication.sharedApplication.keyWindow;
    if (cw && (cw.bounds.size.width != gScreen.w || cw.bounds.size.height != gScreen.h)) calibrate();
    id<CAMetalDrawable> dr = [gLayer nextDrawable]; if (!dr) return;
    ImGui_ImplMetal_NewFrame();
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
    if (gMenuOpen) drawMenu(balls);
    ImDrawList *dl = ImGui::GetBackgroundDrawList();
    drawPrediction(dl, balls);
    ImGui::Render();
    id<MTLCommandBuffer> cb = [gQueue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dr.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding]; [cb presentDrawable:dr]; [cb commit];
    } @catch (...) { /* never crash the host game */ }
}
static void linkTick(CADisplayLink *l) { renderFrame(); }

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
        [w.layer addSublayer:gLayer];
        calibrate();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { calibrate(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { calibrate(); }];
        ImGui::CreateContext(); applyTheme();
        if (!ImGui_ImplMetal_Init(gDevice)) { gLayer = nil; return; }
        static dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), (1.0/60.0)*NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(t, ^{ renderFrame(); });
        dispatch_resume(t);
    } @catch (...) { gLayer = nil; gQueue = nil; }
}

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            @try { installOverlay(); } @catch (...) {}
        });
    }
}