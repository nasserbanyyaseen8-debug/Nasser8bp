
#pragma once

#include <vector>
#include <map>
#include <cmath>
#include <algorithm>
#include <limits>

namespace nsr {

constexpr double W = 1000;
constexpr double H = 500;
constexpr double R = 13;
constexpr double POCKET = 24;

constexpr double DECEL = 140;
constexpr double CUSH = 0.85;
constexpr double BALL_REST = 0.96;

constexpr double DT = 1.0 / 240.0;
constexpr double MAXV = 1500;
constexpr double MAXT = 8;

constexpr double PI = 3.14159265358979323846;

struct Vec {
    double x = 0;
    double y = 0;
};

struct Ball {
    int id = -1;
    double x = 0;
    double y = 0;
    double vx = 0;
    double vy = 0;
    bool on = true;
};

struct Shot {
    double ang = 0;
    double power = 0.7;
    int target = -1;
};

struct Record {
    std::map<int, std::vector<Vec>> paths;
    std::vector<Ball> rest;
    int firstContact = -1;
    int pocketed = 0;
    bool scratch = false;
};

static const Vec POCKETS[6] = {
    {0, 0},
    {W / 2, 0},
    {W, 0},
    {0, H},
    {W / 2, H},
    {W, H}
};

static const unsigned COLORS[16] = {
    0xffffff,
    0xffff00,
    0x0000ff,
    0xff0000,
    0x800080,
    0xff8000,
    0x008000,
    0x800000,
    0x000000,
    0xffff00,
    0x0000ff,
    0xff0000,
    0x800080,
    0xff8000,
    0x008000,
    0x800000
};

inline double length(double x, double y) {
    return std::sqrt(x * x + y * y);
}

inline double distance(const Ball& a, const Ball& b) {
    return length(a.x - b.x, a.y - b.y);
}

inline double clamp(double v, double lo, double hi) {
    return std::max(lo, std::min(hi, v));
}

inline int groupOf(int id) {
    if (id >= 1 && id <= 7) return 0;
    if (id >= 9 && id <= 15) return 1;
    if (id == 8) return 2;
    return -1;
}

inline std::vector<Ball> rackBalls() {
    std::vector<Ball> b;

    b.push_back({0, 250, 390, 0, 0, true});

    const double cx = 750;
    const double cy = 250;
    const double d = R * 2.02;

    int ids[15] = {
        1, 9, 2, 10, 8,
        3, 11, 4, 12, 5,
        13, 6, 14, 7, 15
    };

    int k = 0;

    for (int row = 0; row < 5; row++) {
        for (int col = 0; col <= row; col++) {
            double x = cx + row * d * 0.866025403784;
            double y = cy + (col - row * 0.5) * d;

            b.push_back({
                ids[k++], x, y, 0, 0, true
            });
        }
    }

    return b;
}

inline bool moving(const std::vector<Ball>& balls) {
    for (const auto& b : balls) {
        if (!b.on) continue;

        if (std::abs(b.vx) > 0.5 ||
            std::abs(b.vy) > 0.5)
            return true;
    }

    return false;
}

inline int remaining(
    const std::vector<Ball>& balls,
    int group
) {
    int n = 0;

    for (const auto& b : balls) {
        if (b.on && groupOf(b.id) == group)
            n++;
    }

    return n;
}

inline std::vector<int> legalTargets(
    const std::vector<Ball>& balls,
    const int groups[2],
    int turn
) {
    std::vector<int> out;

    if (turn < 0 || turn > 1)
        return out;

    int group = groups[turn];

    if (group < 0 || group > 1)
        group = 0;

    bool cleared = remaining(balls, group) == 0;

    for (const auto& b : balls) {
        if (!b.on || b.id == 0)
            continue;

        if (cleared) {
            if (b.id == 8)
                out.push_back(b.id);
        } else if (groupOf(b.id) == group) {
            out.push_back(b.id);
        }
    }

    return out;
}

// ------------------------------------------------------------
// Physics: original constants and equations retained.
inline void stepWorld(
    std::vector<Ball>& balls,
    Record* rec = nullptr
) {
    for (auto& b : balls) {
        if (!b.on) continue;

        double speed = length(b.vx, b.vy);

        if (speed > 0) {
            double drop = DECEL * DT;

            if (speed <= drop) {
                b.vx = 0;
                b.vy = 0;
            } else {
                double factor = (speed - drop) / speed;
                b.vx *= factor;
                b.vy *= factor;
            }
        }

        b.x += b.vx * DT;
        b.y += b.vy * DT;

        if (rec) {
            rec->paths[b.id].push_back({b.x, b.y});
        }

        for (const auto& p : POCKETS) {
            if (length(b.x - p.x, b.y - p.y) < POCKET) {
                b.on = false;
                b.vx = 0;
                b.vy = 0;

                if (rec) {
                    rec->pocketed++;

                    if (b.id == 0)
                        rec->scratch = true;
                }

                break;
            }
        }

        if (!b.on) continue;

        if (b.x < R) {
            b.x = R;
            b.vx = std::abs(b.vx) * CUSH;
        }

        if (b.x > W - R) {
            b.x = W - R;
            b.vx = -std::abs(b.vx) * CUSH;
        }

        if (b.y < R) {
            b.y = R;
            b.vy = std::abs(b.vy) * CUSH;
        }

        if (b.y > H - R) {
            b.y = H - R;
            b.vy = -std::abs(b.vy) * CUSH;
        }
    }

    for (size_t i = 0; i < balls.size(); i++) {
        Ball& a = balls[i];

        if (!a.on) continue;

        for (size_t j = i + 1; j < balls.size(); j++) {
            Ball& b = balls[j];

            if (!b.on) continue;

            double dx = b.x - a.x;
            double dy = b.y - a.y;
            double d = length(dx, dy);

            if (d <= 0 || d >= R * 2)
                continue;

            double nx = dx / d;
            double ny = dy / d;

            double overlap = R * 2 - d;

            a.x -= nx * overlap * 0.5;
            a.y -= ny * overlap * 0.5;

            b.x += nx * overlap * 0.5;
            b.y += ny * overlap * 0.5;

            double rvx = a.vx - b.vx;
            double rvy = a.vy - b.vy;

            double along = rvx * nx + rvy * ny;

            if (along > 0) {
                double impulse = along * BALL_REST;

                a.vx -= impulse * nx;
                a.vy -= impulse * ny;

                b.vx += impulse * nx;
                b.vy += impulse * ny;

                if (rec && rec->firstContact < 0) {
                    if (a.id == 0)
                        rec->firstContact = b.id;
                    else if (b.id == 0)
                        rec->firstContact = a.id;
                }
            }
        }
    }
}

inline void applyShot(
    std::vector<Ball>& balls,
    const Shot& shot
) {
    for (auto& b : balls) {
        if (b.id != 0 || !b.on)
            continue;

        b.vx = std::cos(shot.ang) *
               clamp(shot.power, 0, 1) * MAXV;

        b.vy = std::sin(shot.ang) *
               clamp(shot.power, 0, 1) * MAXV;

        break;
    }
}

inline Record simulate(
    const std::vector<Ball>& input,
    const Shot& shot
) {
    Record rec;
    rec.rest = input;

    for (const auto& b : input) {
        if (b.on)
            rec.paths[b.id].push_back({b.x, b.y});
    }

    applyShot(rec.rest, shot);

    double t = 0;

    while (t < MAXT && moving(rec.rest)) {
        stepWorld(rec.rest, &rec);
        t += DT;
    }

    return rec;
}

inline Record predict(
    const std::vector<Ball>& balls,
    const Shot& shot
) {
    return simulate(balls, shot);
}

inline bool pathClear(
    const std::vector<Ball>& balls,
    const Ball& cue,
    const Ball& target,
    double tx,
    double ty
) {
    double dx = tx - cue.x;
    double dy = ty - cue.y;
    double len2 = dx * dx + dy * dy;

    if (len2 < 1)
        return false;

    for (const auto& b : balls) {
        if (!b.on || b.id == 0 || b.id == target.id)
            continue;

        double px = b.x - cue.x;
        double py = b.y - cue.y;

        double u = clamp(
            (px * dx + py * dy) / len2,
            0,
            1
        );

        double qx = cue.x + u * dx;
        double qy = cue.y + u * dy;

        if (length(b.x - qx, b.y - qy) < R * 2.1)
            return false;
    }

    return true;
}

// ------------------------------------------------------------
// Mode-aware shot selection. Physics is not modified.
inline Shot chooseShot(
    const std::vector<Ball>& balls,
    const int groups[2],
    int turn,
    int mode
) {
    Shot best{0, 0.55, -1};

    if (balls.empty() || turn < 0 || turn > 1)
        return best;

    const Ball* cuePtr = nullptr;

    for (const auto& b : balls) {
        if (b.on && b.id == 0) {
            cuePtr = &b;
            break;
        }
    }

    if (!cuePtr)
        return best;

    const Ball& cue = *cuePtr;

    int group = groups[turn];

    if (group < 0 || group > 1)
        group = 0;

    std::vector<int> targets =
        legalTargets(balls, groups, turn);

    if (targets.empty())
        return best;

    mode = std::max(0, std::min(2, mode));

    double bestScore = -std::numeric_limits<double>::max();

    for (int targetId : targets) {
        const Ball* targetPtr = nullptr;

        for (const auto& b : balls) {
            if (b.on && b.id == targetId) {
                targetPtr = &b;
                break;
            }
        }

        if (!targetPtr)
            continue;

        const Ball& target = *targetPtr;

        for (const auto& pocket : POCKETS) {
            double pdx = pocket.x - target.x;
            double pdy = pocket.y - target.y;

            double plen = length(pdx, pdy);

            if (plen < 1)
                continue;

            double ux = pdx / plen;
            double uy = pdy / plen;

            double gx = target.x - ux * R * 2.0;
            double gy = target.y - uy * R * 2.0;

            double dx = gx - cue.x;
            double dy = gy - cue.y;

            double shotLength = length(dx, dy);

            if (shotLength < 1)
                continue;

            if (!pathClear(
                balls, cue, target, gx, gy
            ))
                continue;

            double angle = std::atan2(dy, dx);

            double cut = std::abs(
                ux * (-dx / shotLength) +
                uy * (-dy / shotLength)
            );

            double power = clamp(
                0.32 + shotLength / 1800.0,
                0.32,
                0.92
            );

            if (mode == 0)
                power = clamp(power + 0.12, 0.4, 1.0);

            if (mode == 1)
                power = clamp(power - 0.10, 0.25, 0.72);

            if (mode == 2)
                power = clamp(power, 0.30, 0.82);

            Shot candidate{angle, power, targetId};

            Record result = simulate(balls, candidate);

            int ownPots = 0;
            int opponentPots = 0;

            for (const auto& original : balls) {
                if (!original.on || original.id == 0)
                    continue;

                bool stillOn = false;

                for (const auto& finalBall : result.rest) {
                    if (finalBall.id == original.id &&
                        finalBall.on) {
                        stillOn = true;
                        break;
                    }
                }

                if (!stillOn) {
                    if (groupOf(original.id) == group)
                        ownPots++;

                    if (groupOf(original.id) == 1 - group)
                        opponentPots++;
                }
            }

            bool legalContact =
                result.firstContact == targetId;

            double score = 0;

            if (!legalContact)
                score -= 500;

            if (result.scratch)
                score -= 1000;

            if (targetId == 8)
                score += 10;

            score += ownPots * 100.0;
            score -= opponentPots * 35.0;

            score -= (1.0 - cut) * 35.0;
            score -= power * 12.0;

            if (mode == 0) {
                score += ownPots * ownPots * 55.0;
                score += ownPots >= 2 ? 120.0 : 0.0;
            }
            else if (mode == 1) {
                score += ownPots == 1 ? 140.0 : 0.0;
                score -= ownPots > 1 ? ownPots * 65.0 : 0.0;
                score -= power * 30.0;
            }
            else {
                score += ownPots == 1 ? 75.0 : 0.0;
                score -= std::abs(power - 0.62) * 35.0;
                score -= cut * 8.0;
            }

            if (score > bestScore) {
                bestScore = score;
                best = candidate;
            }
        }
    }

    if (best.target >= 0)
        return best;

    // Conservative fallback: choose a reachable legal target.
    double nearest = std::numeric_limits<double>::max();

    for (int targetId : targets) {
        for (const auto& b : balls) {
            if (!b.on || b.id != targetId)
                continue;

            double d = distance(cue, b);

            if (d < nearest) {
                nearest = d;

                best.ang = std::atan2(
                    b.y - cue.y,
                    b.x - cue.x
                );

                best.power = mode == 0 ? 0.65 :
                             mode == 1 ? 0.40 : 0.52;

                best.target = targetId;
            }
        }
    }

    return best;
}

} // namespace nsr
