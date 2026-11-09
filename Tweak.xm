
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <algorithm>
#include <vector>
#include "imgui.h"
#include "backends/imgui_impl_metal.h"
#include "src/Engine.hpp"
#include "src/AutoBounds.hpp"

#ifndef ImGuiCol_TabActive
#define ImGuiCol_TabActive ImGuiCol_HeaderActive
#endif

// ------------------------------------------------------------
// Game adapter
// These remain inactive until the actual game adapter is supplied.
struct Offsets {
    uintptr_t ballArray = 0;
    uintptr_t ballX = 0;
    uintptr_t ballY = 0;
    uintptr_t ballId = 0;
    uintptr_t cueAngle = 0;
    uintptr_t cuePower = 0;
    uintptr_t shootFn = 0;

    bool valid() const {
        return ballArray && ballX && ballY &&
               cueAngle && cuePower;
    }
};

static Offsets gOff;

static std::vector<nsr::Ball> readState() {
    std::vector<nsr::Ball> out;

    // No live game array is available in the supplied source.
    // Return empty rather than dereference an unknown address.
    if (!gOff.valid())
        return out;

    return out;
}

static void applyShot(const nsr::Shot& s) {
    // Deliberately inactive until valid game addresses and
    // the correct calling convention are provided.
    (void)s;
}

// ------------------------------------------------------------
// Overlay state
static bool gMenuOpen = true;
static bool gAuto = false;
static bool gPredict = true;
static bool gColorLine = true;
static bool gGhost = true;
static bool gESP = false;
static bool gPockets = true;

static int gMode = 0; // 0 FIERCE, 1 SAFE, 2 HUMAN

static float gSpeed = 1.0f;
static float gPower = 0.7f;
static float gLineWidth = 2.5f;

static int gGroups[2] = {-1, -1};
static int gTurn = 0;

static nsr::Shot gAim{0, 0.7, 0};
static double gNextThink = 0;

static id<MTLDevice> gDevice;
static CAMetalLayer* gLayer;
static id<MTLCommandQueue> gQueue;

// ------------------------------------------------------------
// Screen calibration
static nsr::ScreenInfo gScreen;
static nsr::Rect gTable;
static nsr::Transform gTf;

static nsr::Rect findRenderViewFrame(UIView* v, UIView* root) {
    nsr::Rect best{};

    if ([v.layer isKindOfClass:[CAMetalLayer class]] ||
        [v.layer isKindOfClass:[CAEAGLLayer class]]) {

        CGRect f = [v convertRect:v.bounds toView:root];
        double a = f.size.width / MAX(f.size.height, 1);

        if (a > 1.4 && a < 2.6 &&
            f.size.width > root.bounds.size.width * 0.5) {
            best = {
                f.origin.x,
                f.origin.y,
                f.size.width,
                f.size.height,
                true
            };
        }
    }

    for (UIView* sub in v.subviews) {
        nsr::Rect r = findRenderViewFrame(sub, root);

        if (r.ok && (!best.ok || r.w * r.h > best.w * best.h))
            best = r;
    }

    return best;
}

static void calibrate() {
    UIWindow* w = UIApplication.sharedApplication.keyWindow;
    if (!w) return;

    UIScreen* sc = UIScreen.mainScreen;

    gScreen.w = w.bounds.size.width;
    gScreen.h = w.bounds.size.height;
    gScreen.scale = sc.scale;

    UIEdgeInsets si = w.safeAreaInsets;

    gScreen.safeL = si.left;
    gScreen.safeT = si.top;
    gScreen.safeR = si.right;
    gScreen.safeB = si.bottom;

    nsr::Rect vf = findRenderViewFrame(w, w);
    nsr::Rect scan{};

    gTable = nsr::autoDetect(gScreen, vf, scan);
    gTf = nsr::makeTransform(gTable);

    if (gLayer)
        gLayer.frame = w.bounds;
}

// ------------------------------------------------------------
// Theme
static ImVec4 col(unsigned c, float a = 1.0f) {
    return ImVec4(
        ((c >> 16) & 255) / 255.0f,
        ((c >> 8) & 255) / 255.0f,
        (c & 255) / 255.0f,
        a
    );
}

static void applyTheme() {
    ImGuiStyle& s = ImGui::GetStyle();

    s.WindowRounding = 14;
    s.FrameRounding = 9;
    s.GrabRounding = 9;
    s.ScrollbarRounding = 9;

    s.WindowPadding = ImVec2(14, 14);
    s.FramePadding = ImVec2(10, 7);
    s.ItemSpacing = ImVec2(9, 9);

    ImVec4* c = s.Colors;

    c[ImGuiCol_WindowBg] = col(0x0a0f0d, 0.96f);
    c[ImGuiCol_ChildBg] = col(0x111a16, 0.9f);
    c[ImGuiCol_Border] = col(0x24382f);
    c[ImGuiCol_FrameBg] = col(0x1c2a24);
    c[ImGuiCol_FrameBgHovered] = col(0x166b4a);
    c[ImGuiCol_FrameBgActive] = col(0x0e5c3f);
    c[ImGuiCol_TitleBg] = col(0x0a4230);
    c[ImGuiCol_TitleBgActive] = col(0x0e5c3f);
    c[ImGuiCol_Button] = col(0xf0b429, 0.85f);
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

// ------------------------------------------------------------
// Prediction drawing
static void drawPrediction(
    ImDrawList* dl,
    const std::vector<nsr::Ball>& balls
) {
    if (!gPredict || balls.empty() || !gTable.ok)
        return;

    nsr::Record r = nsr::predict(balls, gAim);

    auto P = [](double x, double y) {
        nsr::Vec v = nsr::toScreen(gTf, x, y);
        return ImVec2((float)v.x, (float)v.y);
    };

    if (r.paths.count(0)) {
        auto& p = r.paths[0];

        for (size_t i = 1; i < p.size(); i++) {
            dl->AddLine(
                P(p[i - 1].x, p[i - 1].y),
                P(p[i].x, p[i].y),
                IM_COL32(255, 255, 255, 200),
                gLineWidth
            );
        }
    }

    int fc = r.firstContact;

    if (fc >= 0 && fc < 16 && r.paths.count(fc)) {
        unsigned c = gColorLine ? nsr::COLORS[fc] : 0xffffff;

        ImU32 uc = IM_COL32(
            (c >> 16) & 255,
            (c >> 8) & 255,
            c & 255,
            255
        );

        auto& p = r.paths[fc];

        for (size_t i = 1; i < p.size(); i++) {
            dl->AddLine(
                P(p[i - 1].x, p[i - 1].y),
                P(p[i].x, p[i].y),
                uc,
                gLineWidth
            );
        }

        if (gGhost) {
            for (auto& b : r.rest) {
                if (b.id == fc && b.on) {
                    dl->AddCircle(
                        P(b.x, b.y),
                        nsr::R * gTf.scale,
                        uc,
                        24,
                        gLineWidth
                    );

                    dl->AddCircleFilled(
                        P(b.x, b.y),
                        nsr::R * gTf.scale * 0.4f,
                        (uc & 0x00ffffff) | 0x80000000
                    );
                }
            }
        }
    }
}

// ------------------------------------------------------------
// Menu
static void drawMenu(const std::vector<nsr::Ball>& balls) {
    (void)balls;

    ImGui::SetNextWindowSize(
        ImVec2(380, 540),
        ImGuiCond_FirstUseEver
    );

    if (!ImGui::Begin(
        "NASSER 8BP",
        &gMenuOpen,
        ImGuiWindowFlags_NoCollapse
    )) {
        ImGui::End();
        return;
    }

    ImGui::TextColored(col(0xf0b429), "NASSER");
    ImGui::SameLine();
    ImGui::TextDisabled("8 Ball Pool");

    ImGui::Separator();
    ImGui::Spacing();

    // PLAY STYLE dropdown
    static const char* modes[] = {
        "FIERCE",
        "SAFE",
        "HUMAN"
    };

    gMode = std::clamp(gMode, 0, 2);

    ImGui::TextDisabled("PLAY STYLE");

    if (ImGui::BeginCombo("##playstyle", modes[gMode])) {
        for (int i = 0; i < 3; i++) {
            bool selected = (gMode == i);

            if (ImGui::Selectable(modes[i], selected))
                gMode = i;

            if (selected)
                ImGui::SetItemDefaultFocus();
        }

        ImGui::EndCombo();
    }

    ImGui::Spacing();

    ImGui::PushStyleColor(
        ImGuiCol_Button,
        gAuto ? col(0x8e2f3a) : col(0xf0b429)
    );

    ImGui::PushStyleColor(
        ImGuiCol_ButtonHovered,
        gAuto ? col(0xb0404c) : col(0xffd766)
    );

    if (ImGui::Button(
        gAuto ? "STOP AUTO-PLAY" : "START AUTO-PLAY",
        ImVec2(-1, 40)
    )) {
        gAuto = !gAuto;
        gNextThink = 0;
    }

    ImGui::PopStyleColor(2);

    ImGui::SliderFloat("Speed", &gSpeed, 0.4f, 3.0f, "%.1fx");
    ImGui::SliderFloat("Power", &gPower, 0.1f, 1.0f, "%.2f");

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();

    if (ImGui::BeginTabBar("##nsrtabs")) {
        if (ImGui::BeginTabItem("Prediction")) {
            ImGui::Checkbox("Enable Prediction", &gPredict);
            ImGui::Checkbox("Color-coded line", &gColorLine);
            ImGui::Checkbox("Stop circle (ghost)", &gGhost);

            ImGui::SliderFloat(
                "Line width",
                &gLineWidth,
                1.0f,
                6.0f,
                "%.1f"
            );

            ImGui::TextDisabled(
                "Table bounds auto-fit to any phone."
            );

            ImGui::EndTabItem();
        }

        if (ImGui::BeginTabItem("Visuals")) {
            ImGui::Checkbox("ESP", &gESP);
            ImGui::Checkbox("Draw pockets", &gPockets);
            ImGui::EndTabItem();
        }

        if (ImGui::BeginTabItem("Credits")) {
            ImGui::Text("NASSER");
            ImGui::TextDisabled("Prediction and training interface");
            ImGui::EndTabItem();
        }

        ImGui::EndTabBar();
    }

    ImGui::End();
}

// ------------------------------------------------------------
// Decision timing
static double decisionDelay() {
    double baseDelay = 0.12;

    switch (gMode) {
        case 0: baseDelay = 0.12; break;
        case 1: baseDelay = 0.55; break;
        case 2: baseDelay = 0.95; break;
    }

    return baseDelay / std::max(0.25f, gSpeed);
}

// ------------------------------------------------------------
// Render loop
static void renderFrame() {
    if (!gLayer || !gQueue)
        return;

    if (!ImGui::GetCurrentContext())
        return;

    @try {
        UIWindow* cw = UIApplication.sharedApplication.keyWindow;

        if (cw &&
            (cw.bounds.size.width != gScreen.w ||
             cw.bounds.size.height != gScreen.h)) {
            calibrate();
        }

        id<CAMetalDrawable> dr = [gLayer nextDrawable];
        if (!dr) return;

        MTLRenderPassDescriptor* rp =
            [MTLRenderPassDescriptor renderPassDescriptor];

        rp.colorAttachments[0].texture = dr.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionLoad;

        ImGui_ImplMetal_NewFrame(rp);
        ImGui::NewFrame();

        std::vector<nsr::Ball> balls = readState();

        // Auto-play remains inactive until readState and applyShot
        // are connected to the real game adapter.
        if (gAuto && !balls.empty() && !nsr::moving(balls)) {
            double now = CACurrentMediaTime();

            if (now >= gNextThink) {
                nsr::Shot s = nsr::chooseShot(
                    balls,
                    gGroups,
                    gTurn,
                    gMode
                );

                gAim = s;
                applyShot(s);
                gNextThink = now + decisionDelay();
            }
        }

        if (gMenuOpen)
            drawMenu(balls);

        ImDrawList* dl = ImGui::GetBackgroundDrawList();
        drawPrediction(dl, balls);

        ImGui::Render();

        id<MTLCommandBuffer> cb = [gQueue commandBuffer];

        id<MTLRenderCommandEncoder> enc =
            [cb renderCommandEncoderWithDescriptor:rp];

        ImGui_ImplMetal_RenderDrawData(
            ImGui::GetDrawData(),
            cb,
            enc
        );

        [enc endEncoding];
        [cb presentDrawable:dr];
        [cb commit];

    } @catch (...) {
        // Keep the host application alive.
    }
}

// ------------------------------------------------------------
// Install
static void installOverlay() {
    @try {
        gDevice = MTLCreateSystemDefaultDevice();
        if (!gDevice) return;

        gQueue = [gDevice newCommandQueue];
        if (!gQueue) return;

        UIWindow* w = UIApplication.sharedApplication.keyWindow;
        if (!w) return;

        gLayer = [CAMetalLayer layer];

        gLayer.device = gDevice;
        gLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        gLayer.framebufferOnly = NO;
        gLayer.opaque = NO;
        gLayer.frame = w.bounds;
        gLayer.presentsWithTransaction = NO;

        [w.layer addSublayer:gLayer];

        calibrate();

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIDeviceOrientationDidChangeNotification
            object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification* n) {
                calibrate();
            }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification* n) {
                calibrate();
            }];

        ImGui::CreateContext();
        applyTheme();

        if (!ImGui_ImplMetal_Init(gDevice)) {
            gLayer = nil;
            return;
        }

        static dispatch_source_t timer =
            dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER,
                0,
                0,
                dispatch_get_main_queue()
            );

        dispatch_source_set_timer(
            timer,
            dispatch_time(DISPATCH_TIME_NOW, 0),
            (1.0 / 60.0) * NSEC_PER_SEC,
            0
        );

        dispatch_source_set_event_handler(timer, ^{
            renderFrame();
        });

        dispatch_resume(timer);

    } @catch (...) {
        gLayer = nil;
        gQueue = nil;
    }
}

%ctor {
    @autoreleasepool {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                @try {
                    installOverlay();
                } @catch (...) {
                }
            }
        );
    }
}
