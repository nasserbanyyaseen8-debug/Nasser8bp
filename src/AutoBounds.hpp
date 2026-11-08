// NSR 8BP — automatic table-bounds / screen calibration.
// No manual X/Y: derives the on-screen table rect + coordinate transform for ANY
// device/orientation from (1) the game's render-view frame, (2) a felt-color scan
// of a framebuffer snapshot, or (3) an aspect-ratio fit inside the safe area.
#pragma once
#include <cmath>
#include <algorithm>
#include <cstdint>
#include "Engine.hpp"

namespace nsr {

struct ScreenInfo { double w = 0, h = 0, scale = 1; double safeL = 0, safeT = 0, safeR = 0, safeB = 0; };
struct Rect { double x = 0, y = 0, w = 0, h = 0; bool ok = false; };
struct Transform { double ox = 0, oy = 0, scale = 1; };

inline Rect aspectFit(const ScreenInfo& s) {
    double aw = s.w - s.safeL - s.safeR, ah = s.h - s.safeT - s.safeB;
    if (aw <= 0 || ah <= 0) return Rect{};
    const double aspect = W / H; // 2:1
    double tw = aw, th = tw / aspect;
    if (th > ah) { th = ah; tw = th * aspect; }
    tw *= 0.94; th *= 0.94; // small rail margin
    Rect r; r.ok = true;
    r.x = s.safeL + (aw - tw) / 2; r.y = s.safeT + (ah - th) / 2; r.w = tw; r.h = th;
    return r;
}

// Bounding box of felt-green pixels in an RGBA buffer (device pixels).
inline Rect feltScan(const uint8_t* px, int pw, int ph, double scale) {
    if (!px || pw <= 0 || ph <= 0) return Rect{};
    long minx = pw, miny = ph, maxx = -1, maxy = -1, count = 0;
    for (int y = 0; y < ph; y += 2) for (int x = 0; x < pw; x += 2) {
        const uint8_t* p = px + (y * pw + x) * 4;
        int r = p[0], g = p[1], b = p[2];
        if (g > 40 && g > r * 1.25 && g > b * 1.25) { // saturated green felt
            count++; if (x < minx) minx = x; if (x > maxx) maxx = x; if (y < miny) miny = y; if (y > maxy) maxy = y;
        }
    }
    if (count < 200 || maxx <= minx || maxy <= miny) return Rect{};
    Rect r; r.ok = true;
    r.x = minx / scale; r.y = miny / scale; r.w = (maxx - minx) / scale; r.h = (maxy - miny) / scale;
    return r;
}

inline bool plausible(const Rect& r, const ScreenInfo& s) {
    if (!r.ok || r.w <= 0 || r.h <= 0) return false;
    if (r.x < -1 || r.y < -1 || r.x + r.w > s.w + 1 || r.y + r.h > s.h + 1) return false;
    double a = r.w / r.h, want = W / H;
    return a > want * 0.7 && a < want * 1.3; // near 2:1
}

// Prefer an exact hooked view frame, then felt scan, then aspect fit.
inline Rect autoDetect(const ScreenInfo& s, const Rect& viewFrame, const Rect& scan) {
    if (plausible(viewFrame, s)) return viewFrame;
    if (plausible(scan, s)) return scan;
    return aspectFit(s);
}

inline Transform makeTransform(const Rect& r) {
    Transform t; t.ox = r.x; t.oy = r.y;
    t.scale = std::min(r.w / W, r.h / H);
    // center inside rect if aspect slightly off
    t.ox += (r.w - W * t.scale) / 2; t.oy += (r.h - H * t.scale) / 2;
    return t;
}
inline Vec toScreen(const Transform& t, double x, double y) { return { t.ox + x * t.scale, t.oy + y * t.scale }; }
inline Vec toTable(const Transform& t, double sx, double sy) { return { (sx - t.ox) / t.scale, (sy - t.oy) / t.scale }; }

} // namespace nsr