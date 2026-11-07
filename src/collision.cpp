#include "collision.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>

namespace sa {

namespace {
bool readAll(const std::string &path, std::vector<uint8_t> &out) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (n <= 0) { std::fclose(f); return false; }
    out.resize((size_t)n);
    const bool ok = std::fread(out.data(), 1, out.size(), f) == out.size();
    std::fclose(f);
    return ok;
}

// 垂直向下射线与三角形求交（返回交点 y）
inline bool hitDown(float px, float pz, const float *a, const float *b,
                    const float *c, float &y) {
    const float x1 = b[0] - a[0], z1 = b[2] - a[2];
    const float x2 = c[0] - a[0], z2 = c[2] - a[2];
    const float det = x1 * z2 - x2 * z1;
    if (std::fabs(det) < 1e-9f) return false;
    const float rx = px - a[0], rz = pz - a[2];
    const float u = (rx * z2 - x2 * rz) / det;
    const float v = (x1 * rz - rx * z1) / det;
    if (u < -1e-4f || v < -1e-4f || u + v > 1.0f + 1e-4f) return false;
    y = a[1] + u * (b[1] - a[1]) + v * (c[1] - a[1]);
    return true;
}

// 水平线段与三角形求交（在脚部高度附近横截面判断）
inline bool segmentBlocks(float ax, float az, float bx, float bz, float y,
                          const float *p0, const float *p1, const float *p2) {
    // 判断三角形是否在高度 y 处被线段穿过：
    // 1) 三角形在 y 方向覆盖该高度
    const float ymin = std::fmin(p0[1], std::fmin(p1[1], p2[1]));
    const float ymax = std::fmax(p0[1], std::fmax(p1[1], p2[1]));
    if (y < ymin - 0.1f || y > ymax) return false;

    // 2) 在 XZ 平面判断线段与三角形相交
    auto cross2 = [](float ox, float oz, float ax2, float az2,
                     float bx2, float bz2) {
        return (ax2 - ox) * (bz2 - oz) - (az2 - oz) * (bx2 - ox);
    };
    const float d1 = cross2(ax, az, bx, bz, p0[0], p0[2]);
    const float d2 = cross2(ax, az, bx, bz, p1[0], p1[2]);
    const float d3 = cross2(ax, az, bx, bz, p2[0], p2[2]);
    const bool hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
    const bool hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);
    if (hasNeg && hasPos) {
        // 线段穿过了三角形所在的直线区域，近似认为阻挡
        return true;
    }
    // 线段端点落在三角形内也算
    auto inside = [&](float px, float pz) {
        const float e1 = cross2(p0[0], p0[2], p1[0], p1[2], px, pz);
        const float e2 = cross2(p1[0], p1[2], p2[0], p2[2], px, pz);
        const float e3 = cross2(p2[0], p2[2], p0[0], p0[2], px, pz);
        const bool n = (e1 < 0) || (e2 < 0) || (e3 < 0);
        const bool p = (e1 > 0) || (e2 > 0) || (e3 > 0);
        return !(n && p);
    };
    return inside(ax, az) || inside(bx, bz);
}
}  // namespace

bool CollisionWorld::load(const std::string &path) {
    std::vector<uint8_t> raw;
    if (!readAll(path, raw) || raw.size() < 16) return false;

    size_t p = 0;
    uint32_t nt = 0, nv = 0;
    std::memcpy(&nt, &raw[p], 4); p += 4;
    std::memcpy(&nv, &raw[p], 4); p += 4;
    if (p + (size_t)nv * 12 + (size_t)nt * 12 > raw.size()) return false;

    verts_.resize((size_t)nv * 3);
    std::memcpy(verts_.data(), &raw[p], (size_t)nv * 12);
    p += (size_t)nv * 12;

    idx_.resize((size_t)nt * 3);
    std::memcpy(idx_.data(), &raw[p], (size_t)nt * 12);
    p += (size_t)nt * 12;

    if (p + 8 + 12 > raw.size()) return false;
    std::memcpy(&gx_, &raw[p], 4); p += 4;
    std::memcpy(&gz_, &raw[p], 4); p += 4;
    std::memcpy(&minX_, &raw[p], 4); p += 4;
    std::memcpy(&minZ_, &raw[p], 4); p += 4;
    std::memcpy(&cell_, &raw[p], 4); p += 4;

    const size_t nCells = (size_t)gx_ * gz_ + 1;
    if (p + nCells * 4 > raw.size()) return false;
    cellStart_.resize(nCells);
    std::memcpy(cellStart_.data(), &raw[p], nCells * 4);
    p += nCells * 4;

    const size_t total = cellStart_.back();
    if (p + total * 4 > raw.size()) return false;
    cellTris_.resize(total);
    std::memcpy(cellTris_.data(), &raw[p], total * 4);

    return !verts_.empty();
}

void CollisionWorld::cellRange(float x0, float z0, float x1, float z1,
                               int &c0, int &c1) const {
    int ax = (int)((x0 - minX_) / cell_);
    int az = (int)((z0 - minZ_) / cell_);
    int bx = (int)((x1 - minX_) / cell_);
    int bz = (int)((z1 - minZ_) / cell_);
    ax = std::max(0, std::min(ax, gx_ - 1));
    bx = std::max(0, std::min(bx, gx_ - 1));
    az = std::max(0, std::min(az, gz_ - 1));
    bz = std::max(0, std::min(bz, gz_ - 1));
    c0 = az * gx_ + ax;
    c1 = bz * gx_ + bx;
}

bool CollisionWorld::groundAt(float x, float z, float &outY) const {
    if (!valid()) return false;
    bool found = false;
    float best = -1e30f;
    const int cx = (int)((x - minX_) / cell_);
    const int cz = (int)((z - minZ_) / cell_);
    if (cx < 0 || cz < 0 || cx >= gx_ || cz >= gz_) return false;
    const size_t ci = (size_t)cz * gx_ + cx;
    for (uint32_t k = cellStart_[ci]; k < cellStart_[ci + 1]; ++k) {
        const uint32_t t = cellTris_[k];
        if ((size_t)t * 3 + 2 >= idx_.size()) continue;
        const float *a = &verts_[(size_t)idx_[t * 3] * 3];
        const float *b = &verts_[(size_t)idx_[t * 3 + 1] * 3];
        const float *c = &verts_[(size_t)idx_[t * 3 + 2] * 3];
        float y;
        if (hitDown(x, z, a, b, c, y) && y > best) { best = y; found = true; }
    }
    if (found) outY = best;
    return found;
}

bool CollisionWorld::blocked(float fx, float fz, float tx, float tz,
                             float feetY) const {
    if (!valid()) return false;
    int c0, c1;
    const float mx0 = std::min(fx, tx) - 0.5f, mx1 = std::max(fx, tx) + 0.5f;
    const float mz0 = std::min(fz, tz) - 0.5f, mz1 = std::max(fz, tz) + 0.5f;
    cellRange(mx0, mz0, mx1, mz1, c0, c1);
    const int ax = c0 % gx_, az = c0 / gx_;
    const int bx = c1 % gx_, bz = c1 / gx_;
    for (int cz = az; cz <= bz; ++cz) {
        for (int cx = ax; cx <= bx; ++cx) {
            const size_t ci = (size_t)cz * gx_ + cx;
            for (uint32_t k = cellStart_[ci]; k < cellStart_[ci + 1]; ++k) {
                const uint32_t t = cellTris_[k];
                if ((size_t)t * 3 + 2 >= idx_.size()) continue;
                const float *a = &verts_[(size_t)idx_[t * 3] * 3];
                const float *b = &verts_[(size_t)idx_[t * 3 + 1] * 3];
                const float *c = &verts_[(size_t)idx_[t * 3 + 2] * 3];
                if (segmentBlocks(fx, fz, tx, tz, feetY + 0.9f, a, b, c))
                    return true;
            }
        }
    }
    return false;
}

}  // namespace sa
