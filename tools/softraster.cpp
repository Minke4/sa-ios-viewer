// 软件光栅化：用与 Metal 着色器相同的数学做离线渲染，
// 用于在无 GPU 环境（iSH）中验证相机/变换/光照/UV 是否正确。
// 输出 PPM（P6），再由 Python 转 PNG。
#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <vector>

#include "assets.h"
#include "renderer.h"

struct VSOut {
    float clip[4];
    float world[3];
    float uv[2];
};

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "用法: %s <IMG> <模型> [宽] [高] [yaw] [pitch]\n", argv[0]);
        return 1;
    }
    const int W = argc > 3 ? std::atoi(argv[3]) : 800;
    const int H = argc > 4 ? std::atoi(argv[4]) : 800;
    float yaw = argc > 5 ? (float)std::atof(argv[5]) : 0.6f;
    float pitch = argc > 6 ? (float)std::atof(argv[6]) : 0.35f;

    sa::ImgArchive img;
    if (!img.open(argv[1])) { std::fprintf(stderr, "IMG 打不开\n"); return 2; }
    std::vector<uint8_t> data;
    if (!img.readEntry(argv[2], data)) { std::fprintf(stderr, "模型不存在\n"); return 3; }
    sa::Model model = sa::parseDFF(data);
    if (model.geometries.empty()) { std::fprintf(stderr, "无几何体\n"); return 4; }
    sa::MeshData mesh = sa::buildMesh(model);
    std::printf("网格 %zu 顶点 %zu 索引\n", mesh.vertices.size(), mesh.indices.size());

    // 相机（与 metal_backend.mm 完全一致）
    const float cx = (mesh.bounds[0] + mesh.bounds[3]) * 0.5f;
    const float cy = (mesh.bounds[1] + mesh.bounds[4]) * 0.5f;
    const float cz = (mesh.bounds[2] + mesh.bounds[5]) * 0.5f;
    const float dx = mesh.bounds[3] - mesh.bounds[0];
    const float dy = mesh.bounds[4] - mesh.bounds[1];
    const float dz = mesh.bounds[5] - mesh.bounds[2];
    const float radius = std::sqrt(dx * dx + dy * dy + dz * dz) * 0.5f;
    const float dist = radius * 2.2f;

    const float cp = std::cos(pitch), sp = std::sin(pitch);
    const float cyaw = std::cos(yaw), syaw = std::sin(yaw);
    const float eye[3] = {cx + dist * cp * syaw, cy + dist * sp, cz + dist * cp * cyaw};
    const float target[3] = {cx, cy, cz};
    const float up[3] = {0, 1, 0};

    const float aspect = (float)W / (float)H;
    sa::Mat4 proj = sa::Mat4::perspective(1.0f, aspect, dist * 0.01f + 0.05f, dist * 20.0f + 2000.0f);
    sa::Mat4 view = sa::Mat4::lookAt(eye, target, up);
    sa::Mat4 mvp = proj * view;

    auto transform = [](const sa::Mat4 &m, const float v[4], float out[4]) {
        for (int i = 0; i < 4; ++i) {
            out[i] = 0;
            for (int k = 0; k < 4; ++k) out[i] += m.m[k * 4 + i] * v[k];
        }
    };

    std::vector<float> color((size_t)W * H * 3);
    for (size_t i = 0; i < color.size(); i += 3) {
        color[i] = 0.07f; color[i + 1] = 0.09f; color[i + 2] = 0.12f;
    }
    std::vector<float> depth((size_t)W * H, 1e30f);

    const float light[3] = {-0.4f, -0.85f, -0.3f};
    float ln = std::sqrt(light[0] * light[0] + light[1] * light[1] + light[2] * light[2]);
    const float L[3] = {light[0] / ln, light[1] / ln, light[2] / ln};
    const float ambient = 0.45f;

    size_t drawn = 0;
    for (size_t t = 0; t + 2 < mesh.indices.size(); t += 3) {
        VSOut v[3];
        bool behind = false;
        for (int k = 0; k < 3; ++k) {
            const auto &vv = mesh.vertices[mesh.indices[t + k]];
            float p[4] = {vv.pos[0], vv.pos[1], vv.pos[2], 1.0f};
            transform(mvp, p, v[k].clip);
            v[k].world[0] = vv.pos[0]; v[k].world[1] = vv.pos[1]; v[k].world[2] = vv.pos[2];
            v[k].uv[0] = vv.uv[0]; v[k].uv[1] = vv.uv[1];
            if (v[k].clip[3] <= 0.001f) behind = true;
        }
        if (behind) continue;

        float sx[3], sy[3], sz[3];
        for (int k = 0; k < 3; ++k) {
            float ndc[3] = {v[k].clip[0] / v[k].clip[3], v[k].clip[1] / v[k].clip[3],
                            v[k].clip[2] / v[k].clip[3]};
            sx[k] = (ndc[0] * 0.5f + 0.5f) * W;
            sy[k] = (1.0f - (ndc[1] * 0.5f + 0.5f)) * H;
            sz[k] = ndc[2];
        }
        const float area = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0]);
        if (std::fabs(area) < 1e-9f) continue;

        // 法线
        float e1[3], e2[3], n[3];
        for (int k = 0; k < 3; ++k) {
            e1[k] = v[1].world[k] - v[0].world[k];
            e2[k] = v[2].world[k] - v[0].world[k];
        }
        n[0] = e1[1] * e2[2] - e1[2] * e2[1];
        n[1] = e1[2] * e2[0] - e1[0] * e2[2];
        n[2] = e1[0] * e2[1] - e1[1] * e2[0];
        float nl = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (nl < 1e-9f) continue;
        for (int k = 0; k < 3; ++k) n[k] /= nl;
        const float ndl = std::fabs(n[0] * L[0] + n[1] * L[1] + n[2] * L[2]);
        const float lit = ambient + (1.0f - ambient) * ndl;

        const int minx = std::max(0, (int)std::floor(std::min({sx[0], sx[1], sx[2]})));
        const int maxx = std::min(W - 1, (int)std::ceil(std::max({sx[0], sx[1], sx[2]})));
        const int miny = std::max(0, (int)std::floor(std::min({sy[0], sy[1], sy[2]})));
        const int maxy = std::min(H - 1, (int)std::ceil(std::max({sy[0], sy[1], sy[2]})));
        for (int py = miny; py <= maxy; ++py) {
            for (int px = minx; px <= maxx; ++px) {
                const float fx = px + 0.5f, fy = py + 0.5f;
                float w0 = ((sx[1] - fx) * (sy[2] - fy) - (sx[2] - fx) * (sy[1] - fy)) / area;
                float w1 = ((sx[2] - fx) * (sy[0] - fy) - (sx[0] - fx) * (sy[2] - fy)) / area;
                float w2 = 1.0f - w0 - w1;
                if (w0 < 0 || w1 < 0 || w2 < 0) continue;
                const float z = w0 * sz[0] + w1 * sz[1] + w2 * sz[2];
                const size_t di = (size_t)py * W + px;
                if (z >= depth[di]) continue;
                depth[di] = z;
                float shade = lit;
                if (nl > 0) shade = std::pow(lit, 1.0f / 1.1f);
                color[di * 3 + 0] = 0.62f * shade;
                color[di * 3 + 1] = 0.75f * shade;
                color[di * 3 + 2] = 0.85f * shade;
            }
        }
        ++drawn;
    }
    std::printf("绘制 %zu 个三角形\n", drawn);

    FILE *f = std::fopen("/tmp/sa_soft.ppm", "wb");
    std::fprintf(f, "P6\n%d %d\n255\n", W, H);
    for (size_t i = 0; i < (size_t)W * H; ++i) {
        unsigned char px[3];
        for (int k = 0; k < 3; ++k) {
            float c = color[i * 3 + k];
            c = c < 0 ? 0 : (c > 1 ? 1 : c);
            px[k] = (unsigned char)(c * 255.0f + 0.5f);
        }
        std::fwrite(px, 1, 3, f);
    }
    std::fclose(f);
    std::printf("输出 /tmp/sa_soft.ppm\n");
    return 0;
}
