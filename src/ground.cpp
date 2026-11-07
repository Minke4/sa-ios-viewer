#include "ground.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>

namespace sa {

namespace {
inline bool readAll(const std::string &path, std::vector<uint8_t> &out) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (n <= 0) { std::fclose(f); return false; }
    out.resize((size_t)n);
    size_t got = std::fread(out.data(), 1, out.size(), f);
    std::fclose(f);
    return got == out.size();
}
}  // namespace

bool GroundGrid::load(const std::string &path, const MeshData &mesh) {
    std::vector<uint8_t> raw;
    if (!readAll(path, raw) || raw.size() < 24) return false;

    size_t p = 0;
    std::memcpy(&cellsX_, &raw[p], 4); p += 4;
    std::memcpy(&cellsZ_, &raw[p], 4); p += 4;
    std::memcpy(&minX_, &raw[p], 4); p += 4;
    std::memcpy(&minZ_, &raw[p], 4); p += 4;
    std::memcpy(&cell_, &raw[p], 4); p += 4;
    if (cellsX_ <= 0 || cellsZ_ <= 0 || cell_ <= 0) return false;

    const size_t nCells = (size_t)cellsX_ * cellsZ_ + 1;
    if (p + nCells * 4 > raw.size()) return false;
    cellStart_.resize(nCells);
    std::memcpy(cellStart_.data(), &raw[p], nCells * 4);
    p += nCells * 4;

    const size_t total = cellStart_.back();
    if (p + total * 4 > raw.size()) return false;
    cellTris_.resize(total);
    std::memcpy(cellTris_.data(), &raw[p], total * 4);

    // 顶点与索引来自 mesh
    verts_.clear();
    verts_.reserve(mesh.vertices.size() * 3);
    for (const auto &v : mesh.vertices) {
        verts_.push_back(v.pos[0]);
        verts_.push_back(v.pos[1]);
        verts_.push_back(v.pos[2]);
    }
    idx_ = mesh.indices;
    return !verts_.empty();
}

// 垂直射线（向下）与三角形求交，返回最高的 y
static bool rayTriDown(float px, float pz, const float *a, const float *b,
                       const float *c, float &outY) {
    // 在 XZ 平面上做重心坐标判断，重心坐标即 y 的插值权重
    const float x1 = b[0] - a[0], z1 = b[2] - a[2];
    const float x2 = c[0] - a[0], z2 = c[2] - a[2];
    const float det = x1 * z2 - x2 * z1;
    if (std::fabs(det) < 1e-9f) return false;

    const float rx = px - a[0], rz = pz - a[2];
    const float u = (rx * z2 - x2 * rz) / det;
    const float v = (x1 * rz - rx * z1) / det;
    if (u < -1e-4f || v < -1e-4f || u + v > 1.0f + 1e-4f) return false;

    outY = a[1] + u * (b[1] - a[1]) + v * (c[1] - a[1]);
    return true;
}

bool GroundGrid::heightAt(float x, float z, float &outY) const {
    if (!valid()) return false;
    const int cx = (int)((x - minX_) / cell_);
    const int cz = (int)((z - minZ_) / cell_);
    if (cx < 0 || cz < 0 || cx >= cellsX_ || cz >= cellsZ_) return false;

    const size_t cellIdx = (size_t)cz * cellsX_ + cx;
    const uint32_t s = cellStart_[cellIdx];
    const uint32_t e = cellStart_[cellIdx + 1];

    bool found = false;
    float best = -1e30f;
    for (uint32_t k = s; k < e; ++k) {
        const uint32_t t = cellTris_[k];
        if ((size_t)t * 3 + 2 >= idx_.size()) continue;
        const uint32_t i0 = idx_[t * 3], i1 = idx_[t * 3 + 1], i2 = idx_[t * 3 + 2];
        const float *pa = &verts_[(size_t)i0 * 3];
        const float *pb = &verts_[(size_t)i1 * 3];
        const float *pc = &verts_[(size_t)i2 * 3];
        float y;
        if (rayTriDown(x, z, pa, pb, pc, y) && y > best) {
            best = y;
            found = true;
        }
    }
    if (found) outY = best;
    return found;
}

}  // namespace sa
