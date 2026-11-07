#include "vehicle.h"

#include <cmath>
#include <cstring>
#include <functional>

#include "assets.h"

namespace sa {

int g_nobone = 0;

namespace {

constexpr int YUP = 1;   // 0=保持 SA 的 Z-up，1=转成 Y-up

// SA 车辆是 Z-up（Y 为车长方向，Z 为车高）。
// 渲染端用 Y-up、车头朝 -Z，故映射为：
//   render.x = sa.x        (左右)
//   render.y = sa.z        (车高)
//   render.z = -sa.y       (车长，车头在 -Z)
inline void toRender(float x, float y, float z, float out[3]) {
    out[0] = x;
    out[1] = z;
    out[2] = -y;
}

}  // namespace

bool buildVehicle(const std::vector<uint8_t> &dff, VehicleMesh &out) {
    Model m = parseDFF(dff);
    if (m.geometries.empty()) return false;

    // 骨骼世界变换
    std::vector<Bone> bones = m.bones;
    std::vector<bool> done(bones.size(), false);
    std::vector<float> wrot(bones.size() * 9, 0.0f);
    std::vector<float> wpos(bones.size() * 3, 0.0f);

    std::function<void(int)> compute = [&](int i) {
        if (done[i]) return;
        const Bone &b = bones[i];
        if (b.parent < 0 || b.parent >= (int)bones.size()) {
            std::memcpy(&wrot[i * 9], b.rot, sizeof(b.rot));
            std::memcpy(&wpos[i * 3], b.pos, sizeof(b.pos));
        } else {
            compute(b.parent);
            const float *pr = &wrot[b.parent * 9];
            const float *pp = &wpos[b.parent * 3];
            // RW 的 3x3 变换按列主序存放：元素 (row, col) 在 [col*3 + row]
            for (int row = 0; row < 3; ++row)
                for (int col = 0; col < 3; ++col) {
                    float s = 0;
                    for (int k = 0; k < 3; ++k)
                        s += pr[k * 3 + row] * b.rot[col * 3 + k];
                    wrot[i * 9 + col * 3 + row] = s;
                }
            for (int r = 0; r < 3; ++r) {
                float s = 0;
                for (int k = 0; k < 3; ++k) s += pr[k * 3 + r] * b.pos[k];
                wpos[i * 3 + r] = pp[r] + s;
            }
        }
        done[i] = true;
    };
    for (int i = 0; i < (int)bones.size(); ++i) compute(i);

    struct RawPart {
        uint32_t first, count;
        int bone;
        float cx, cy, cz;
        float radius;
        std::string tex;
    };
    std::vector<RawPart> raw;

    float mn[3] = {1e30f, 1e30f, 1e30f}, mx[3] = {-1e30f, -1e30f, -1e30f};

    for (const auto &g : m.geometries) {
        if (g.positions.empty()) continue;
        const int bone = (g.boneIndex >= 0 && g.boneIndex < (int)bones.size())
                             ? g.boneIndex : -1;
        // SA 车辆的坐标空间规则（实测）：
        //   · 绑定骨骼 0（根）或未绑定的几何体，顶点已是车体世界坐标，不做变换
        //   · 绑定其它骨骼的部件是「以该骨骼为原点的局部坐标」，但几何数据里
        //     往往已经包含了骨骼位置，再叠加平移会重复偏移。
        //     因此只应用旋转（旋转在车辆里通常是单位阵），不平移。
        const bool isLocal = bone > 0;
        const float *R = isLocal ? &wrot[bone * 9] : nullptr;

        const uint32_t baseVert = (uint32_t)out.vertices.size();
        float pmn[3] = {1e30f, 1e30f, 1e30f}, pmx[3] = {-1e30f, -1e30f, -1e30f};
        for (int i = 0; i < g.numVertices; ++i) {
            float p[3] = {g.positions[i * 3], g.positions[i * 3 + 1], g.positions[i * 3 + 2]};
            float w[3];
            if (R && !g_nobone) {
                // 列主序：w[row] = sum_k R[k*3+row] * p[k]
                w[0] = R[0] * p[0] + R[3] * p[1] + R[6] * p[2];
                w[1] = R[1] * p[0] + R[4] * p[1] + R[7] * p[2];
                w[2] = R[2] * p[0] + R[5] * p[1] + R[8] * p[2];
            } else {
                w[0] = p[0]; w[1] = p[1]; w[2] = p[2];
            }
            Vertex v{};
            toRender(w[0], w[1], w[2], v.pos);
            v.normal[0] = 0; v.normal[1] = 0; v.normal[2] = 0;
            if (i * 2 + 1 < (int)g.uvs.size()) {
                v.uv[0] = g.uvs[i * 2];
                v.uv[1] = g.uvs[i * 2 + 1];
            }
            v.color[0] = v.color[1] = v.color[2] = v.color[3] = 1.0f;
            out.vertices.push_back(v);
            for (int k = 0; k < 3; ++k) {
                mn[k] = std::fmin(mn[k], v.pos[k]);
                mx[k] = std::fmax(mx[k], v.pos[k]);
                pmn[k] = std::fmin(pmn[k], v.pos[k]);
                pmx[k] = std::fmax(pmx[k], v.pos[k]);
            }
        }
        RawPart rp;
        rp.first = (uint32_t)out.indices.size();
        rp.count = (uint32_t)g.indices.size();
        rp.bone = bone;
        rp.cx = (pmn[0] + pmx[0]) * 0.5f;
        rp.cy = (pmn[1] + pmx[1]) * 0.5f;
        rp.cz = (pmn[2] + pmx[2]) * 0.5f;
        rp.radius = 0.5f * std::fmax(pmx[0] - pmn[0],
                         std::fmax(pmx[1] - pmn[1], pmx[2] - pmn[2]));
        if (!g.materialTextures.empty()) rp.tex = g.materialTextures[0];
        for (auto idx : g.indices) out.indices.push_back(baseVert + idx);
        raw.push_back(std::move(rp));
    }
    if (out.vertices.empty()) return false;

    std::memcpy(out.bounds, mn, sizeof(mn));
    std::memcpy(out.bounds + 3, mx, sizeof(mx));

    // 面法线
    for (size_t t = 0; t + 2 < out.indices.size(); t += 3) {
        Vertex &a = out.vertices[out.indices[t]];
        Vertex &b = out.vertices[out.indices[t + 1]];
        Vertex &c = out.vertices[out.indices[t + 2]];
        float u[3] = {b.pos[0] - a.pos[0], b.pos[1] - a.pos[1], b.pos[2] - a.pos[2]};
        float v[3] = {c.pos[0] - a.pos[0], c.pos[1] - a.pos[1], c.pos[2] - a.pos[2]};
        float n[3] = {u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2],
                      u[0] * v[1] - u[1] * v[0]};
        for (Vertex *p : {&a, &b, &c}) {
            p->normal[0] += n[0]; p->normal[1] += n[1]; p->normal[2] += n[2];
        }
    }
    for (auto &v : out.vertices) {
        const float L = std::sqrt(v.normal[0] * v.normal[0] + v.normal[1] * v.normal[1] +
                                  v.normal[2] * v.normal[2]);
        if (L > 1e-6f) {
            v.normal[0] /= L; v.normal[1] /= L; v.normal[2] /= L;
        } else {
            v.normal[1] = 1.0f;
        }
    }

    // 车轮识别：小圆盘部件，位于车身四角
    const float cx = (mn[0] + mx[0]) * 0.5f;
    const float cz = (mn[2] + mx[2]) * 0.5f;
#if YUP
    const float halfLen = (mx[2] - mn[2]) * 0.5f;
    const float halfWid = (mx[0] - mn[0]) * 0.5f;
    const int AX_LAT = 0, AX_LON = 2;
#else
    const float halfLen = (mx[1] - mn[1]) * 0.5f;
    const float halfWid = (mx[0] - mn[0]) * 0.5f;
    const int AX_LAT = 0, AX_LON = 1;
#endif
    for (int i = 0; i < 4; ++i) { out.wheels[i] = -1; out.wheelRadius[i] = 0.0f; }

    const float centerLon = AX_LON == 2 ? cz : (mn[1] + mx[1]) * 0.5f;
    for (size_t i = 0; i < raw.size(); ++i) {
        const RawPart &rp = raw[i];
        const int tris = (int)(rp.count / 3);
        if (tris < 6 || tris > 200) continue;
        if (rp.radius > 0.75f) continue;
        const float lat = (AX_LAT == 0 ? rp.cx : rp.cy) - cx;
        const float lon = (AX_LON == 2 ? rp.cz : rp.cy) - centerLon;
        if (std::fabs(lat) < halfWid * 0.45f) continue;
        if (std::fabs(lon) < halfLen * 0.35f) continue;
        const bool front = lon > 0;      // SA 的 +Y 为车头
        const bool right = lat > 0;
        const int slot = (front ? 0 : 2) + (right ? 1 : 0);
        if (out.wheels[slot] < 0) {
            out.wheels[slot] = (int)i;
            out.wheelRadius[slot] = rp.radius;
        }
    }

    for (const auto &rp : raw) {
        VehiclePart p;
        p.firstIndex = rp.first;
        p.indexCount = rp.count;
        p.bone = rp.bone;
        p.textureName = rp.tex;
        out.parts.push_back(std::move(p));
    }
    out.valid = true;
    return true;
}

}  // namespace sa
