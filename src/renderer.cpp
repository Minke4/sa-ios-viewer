#include "renderer.h"

#include <cmath>
#include <cstring>

namespace sa {

Mat4 Mat4::operator*(const Mat4 &o) const {
    Mat4 r;
    for (int i = 0; i < 4; ++i) {
        for (int j = 0; j < 4; ++j) {
            float s = 0;
            for (int k = 0; k < 4; ++k) s += m[k * 4 + j] * o.m[i * 4 + k];
            r.m[i * 4 + j] = s;
        }
    }
    return r;
}

Mat4 Mat4::perspective(float fovY, float aspect, float zn, float zf) {
    Mat4 r;
    std::memset(r.m, 0, sizeof(r.m));
    const float f = 1.0f / std::tan(fovY * 0.5f);
    r.m[0] = f / aspect;
    r.m[5] = f;
    r.m[10] = zf / (zn - zf);
    r.m[11] = -1.0f;
    r.m[14] = (zf * zn) / (zn - zf);
    return r;
}

Mat4 Mat4::lookAt(const float eye[3], const float target[3], const float up[3]) {
    float zf[3] = {eye[0] - target[0], eye[1] - target[1], eye[2] - target[2]};
    float l = std::sqrt(zf[0] * zf[0] + zf[1] * zf[1] + zf[2] * zf[2]);
    if (l < 1e-6f) l = 1;
    for (auto &v : zf) v /= l;
    float xf[3] = {up[1] * zf[2] - up[2] * zf[1], up[2] * zf[0] - up[0] * zf[2],
                   up[0] * zf[1] - up[1] * zf[0]};
    l = std::sqrt(xf[0] * xf[0] + xf[1] * xf[1] + xf[2] * xf[2]);
    if (l < 1e-6f) l = 1;
    for (auto &v : xf) v /= l;
    float yf[3] = {zf[1] * xf[2] - zf[2] * xf[1], zf[2] * xf[0] - zf[0] * xf[2],
                   zf[0] * xf[1] - zf[1] * xf[0]};

    Mat4 r;
    r.m[0] = xf[0]; r.m[4] = xf[1]; r.m[8] = xf[2]; r.m[12] = -(xf[0] * eye[0] + xf[1] * eye[1] + xf[2] * eye[2]);
    r.m[1] = yf[0]; r.m[5] = yf[1]; r.m[9] = yf[2]; r.m[13] = -(yf[0] * eye[0] + yf[1] * eye[1] + yf[2] * eye[2]);
    r.m[2] = zf[0]; r.m[6] = zf[1]; r.m[10] = zf[2]; r.m[14] = -(zf[0] * eye[0] + zf[1] * eye[1] + zf[2] * eye[2]);
    r.m[3] = 0; r.m[7] = 0; r.m[11] = 0; r.m[15] = 1;
    return r;
}

Mat4 Mat4::rotationY(float rad) {
    Mat4 r;
    const float c = std::cos(rad), s = std::sin(rad);
    r.m[0] = c; r.m[2] = -s;
    r.m[8] = s; r.m[10] = c;
    return r;
}

Mat4 Mat4::rotationX(float rad) {
    Mat4 r;
    const float c = std::cos(rad), s = std::sin(rad);
    r.m[5] = c; r.m[6] = s;
    r.m[9] = -s; r.m[10] = c;
    return r;
}

MeshData buildMesh(const Model &model) {
    MeshData md;
    float mn[3] = {1e30f, 1e30f, 1e30f}, mx[3] = {-1e30f, -1e30f, -1e30f};

    for (const auto &g : model.geometries) {
        const uint32_t baseVertex = (uint32_t)md.vertices.size();
        const int nv = g.numVertices;
        for (int i = 0; i < nv; ++i) {
            Vertex v{};
            v.pos[0] = g.positions[i * 3 + 0];
            v.pos[1] = g.positions[i * 3 + 1];
            v.pos[2] = g.positions[i * 3 + 2];
            if (i * 3 + 2 < (int)g.normals.size()) {
                v.normal[0] = g.normals[i * 3 + 0];
                v.normal[1] = g.normals[i * 3 + 1];
                v.normal[2] = g.normals[i * 3 + 2];
            }
            if (i * 2 + 1 < (int)g.uvs.size()) {
                v.uv[0] = g.uvs[i * 2 + 0];
                v.uv[1] = g.uvs[i * 2 + 1];
            }
            v.color[0] = v.color[1] = v.color[2] = v.color[3] = 1.0f;
            if (i * 4 + 3 < (int)g.prelit.size()) {
                v.color[0] = g.prelit[i * 4 + 0] / 255.0f;
                v.color[1] = g.prelit[i * 4 + 1] / 255.0f;
                v.color[2] = g.prelit[i * 4 + 2] / 255.0f;
                v.color[3] = g.prelit[i * 4 + 3] / 255.0f;
            }
            for (int k = 0; k < 3; ++k) {
                mn[k] = std::fmin(mn[k], v.pos[k]);
                mx[k] = std::fmax(mx[k], v.pos[k]);
            }
            md.vertices.push_back(v);
        }

        // 按三角形自带的 materialId 分组，每个材质一个子网格
        const size_t triCount = g.indices.size() / 3;
        const size_t matCount = g.materialTextures.empty() ? 1 : g.materialTextures.size();
        std::vector<std::vector<uint32_t>> byMat(matCount);
        for (size_t t = 0; t < triCount; ++t) {
            size_t m = 0;
            if (t < g.materialIds.size()) {
                const size_t id = g.materialIds[t];
                m = id < matCount ? id : 0;
            }
            auto &dst = byMat[m];
            dst.push_back(baseVertex + g.indices[t * 3 + 0]);
            dst.push_back(baseVertex + g.indices[t * 3 + 1]);
            dst.push_back(baseVertex + g.indices[t * 3 + 2]);
        }
        for (size_t m = 0; m < matCount; ++m) {
            if (byMat[m].empty()) continue;
            SubMesh sm;
            sm.firstIndex = (uint32_t)md.indices.size();
            sm.indexCount = (uint32_t)byMat[m].size();
            sm.textureName = g.materialTextures.empty() ? "" : g.materialTextures[m];
            md.indices.insert(md.indices.end(), byMat[m].begin(), byMat[m].end());
            md.submeshes.push_back(sm);
        }
    }
    std::memcpy(md.bounds, mn, sizeof(mn));
    std::memcpy(md.bounds + 3, mx, sizeof(mx));
    return md;
}

}  // namespace sa
