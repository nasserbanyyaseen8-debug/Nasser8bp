// NSR 8BP — runtime offset resolver (version-resilient, best-effort).
// The repo contains NO game binary/headers, so exact hardcoded offsets for a
// specific Miniclip build (e.g. 56.33.0) cannot be fabricated here. Instead we
// resolve ivar offsets BY NAME at runtime via the ObjC runtime, which adapts
// across game versions as long as the ivar/class names persist. Everything is
// guarded: if a name is not found the offset stays 0 and the feature disables
// safely (never crashes the host game).
//
// To obtain EXACT hardcoded offsets for 56.33.0, dump the game binary:
//   class-dump --arch arm64 Pool.app/Pool > pool.h
// or Frida:
//   ObjC.enumerateLoadedClasses({ onMatch(c){ if(/PowerBar|VisualCue|Ball|Table/i.test(c)) console.log(c); }, onComplete(){} });
//   const ivars = ObjC.classes.GamePowerBarView.$ivars; // read names+offsets
// then fill gOff manually. The resolver below automates the name-based part.
#pragma once
#include <objc/runtime.h>
#include <objc/message.h>
#include <cstring>
#include <cctype>
#include <string>

static bool nsrNameHas(const char* hay, const char* needle) {
    if (!hay || !needle) return false;
    std::string h(hay), n(needle);
    for (auto& c : h) c = (char)std::tolower((unsigned char)c);
    for (auto& c : n) c = (char)std::tolower((unsigned char)c);
    return h.find(n) != std::string::npos;
}

// Find an ivar whose name contains `needle`; return its byte offset.
static bool nsrIvarOffset(Class cls, const char* needle, uintptr_t& out) {
    if (!cls) return false;
    unsigned int count = 0;
    Ivar* ivars = class_copyIvarList(cls, &count);
    bool found = false;
    for (unsigned int i = 0; i < count; i++) {
        const char* name = ivar_getName(ivars[i]);
        if (nsrNameHas(name, needle)) {
            out = (uintptr_t)ivar_getOffset(ivars[i]);
            found = true;
            break;
        }
    }
    if (ivars) free(ivars);
    return found;
}

static Class nsrFindClass(const char* const* candidates, int n) {
    unsigned int count = 0;
    Class* classes = objc_copyClassList(&count);
    Class best = Nil;
    for (unsigned int i = 0; i < count && !best; i++) {
        const char* name = class_getName(classes[i]);
        for (int k = 0; k < n; k++) {
            if (nsrNameHas(name, candidates[k])) { best = classes[i]; break; }
        }
    }
    if (classes) free(classes);
    return best;
}

// Resolve cue power/angle and ball position/id ivar offsets by name.
static void resolveGameOffsets(Offsets& g) {
    @try {
        const char* powerCls[] = { "GamePowerBarView", "VisualCue", "PowerBarView", "MCPowerBar" };
        Class pc = nsrFindClass(powerCls, 4);
        if (pc) {
            nsrIvarOffset(pc, "power", g.cuePower);
            nsrIvarOffset(pc, "angle", g.cueAngle);
            if (!g.cueAngle) nsrIvarOffset(pc, "aim", g.cueAngle);
        }
        const char* ballCls[] = { "MCBall", "BPBall", "Ball" };
        Class bc = nsrFindClass(ballCls, 3);
        if (bc) {
            uintptr_t px = 0, py = 0;
            if (nsrIvarOffset(bc, "position", px)) { g.ballX = px; g.ballY = px + 8; }
            else { nsrIvarOffset(bc, "posx", g.ballX); nsrIvarOffset(bc, "posy", g.ballY);
                   if (!g.ballX) nsrIvarOffset(bc, "_x", g.ballX);
                   if (!g.ballY) nsrIvarOffset(bc, "_y", g.ballY); }
            nsrIvarOffset(bc, "number", g.ballId);
            if (!g.ballId) nsrIvarOffset(bc, "ballid", g.ballId);
            if (!g.ballId) nsrIvarOffset(bc, "_id", g.ballId);
        }
    } @catch (...) { /* never crash host */ }
}