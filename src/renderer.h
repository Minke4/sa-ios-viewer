// 渲染抽象：几何缓冲 + 材质 + 相机
#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "assets.h"

namespace sa {

struct Vertex {
    float pos[3];
    float normal[3];
    float uv[2];
    float color[4];
};

struct SubMesh {
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
    std::string textureName;
};

struct MeshData {
    std::vector<Vertex> vertices;
    std::vector<uint32_t> indices;
    std::vector<SubMesh> submeshes;
    float bounds[6] = {0, 0, 0, 0, 0, 0};   // min xyz, max xyz
};

// 把解析出的模型整理成可直接上传 GPU 的网格
MeshData buildMesh(const Model &model);

struct Mat4 {
    float m[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};

    static Mat4 identity() { return Mat4(); }
    static Mat4 perspective(float fovYRad, float aspect, float zn, float zf);
    static Mat4 lookAt(const float eye[3], const float target[3], const float up[3]);
    static Mat4 rotationY(float rad);
    static Mat4 rotationX(float rad);
    Mat4 operator*(const Mat4 &o) const;
};

}  // namespace sa
