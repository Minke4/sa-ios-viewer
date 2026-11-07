// 精简资源包加载：读取预烘焙的 mesh.bin + PNG 贴图
// 目录结构: <bundle>/mesh.bin, <bundle>/meta.json, <bundle>/tex/*.png
#pragma once

#include <string>
#include <vector>

#include "renderer.h"

namespace sa {

struct PackTexture {
    std::string name;
    int width = 0, height = 0;
    std::vector<uint8_t> rgba;
};

struct PackInfo {
    std::string model;
    int vertexCount = 0;
    int triangleCount = 0;
    float bounds[6] = {0, 0, 0, 0, 0, 0};
    std::vector<SubMesh> submeshes;
    std::vector<PackTexture> textures;
    MeshData mesh;
    bool loaded = false;
    std::string error;
};

// 加载资源包；basePath 是包含 mesh.bin 的目录
bool loadBundle(const std::string &basePath, PackInfo &out);

}  // namespace sa
