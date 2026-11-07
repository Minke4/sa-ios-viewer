// 本地验证工具：直接读 IMG 解析模型，与 Python 版结果对照
#include <cstdio>
#include <cstring>

#include "assets.h"

int main(int argc, char **argv) {
    if (argc < 4) {
        std::fprintf(stderr, "用法: %s <IMG> <模型名> <DXF/TEX 检查模式>\n", argv[0]);
        return 1;
    }
    sa::ImgArchive img;
    if (!img.open(argv[1])) {
        std::fprintf(stderr, "打不开 IMG: %s\n", argv[1]);
        return 2;
    }
    std::printf("IMG: %zu 个条目\n", img.entries().size());

    sa::AssetStore store;
    store.mount(argv[1]);
    sa::Model m;
    if (!store.loadModel(argv[2], m)) {
        std::fprintf(stderr, "解析模型失败: %s\n", argv[2]);
        return 3;
    }
    std::printf("模型 %s: %zu 几何体, %d 顶点, %d 三角形\n", argv[2],
                m.geometries.size(), m.totalVertices, m.totalTriangles);
    for (size_t i = 0; i < m.geometries.size(); ++i) {
        const auto &g = m.geometries[i];
        std::printf("  geom%zu: v=%d t=%d uv=%zu normals=%zu trailing=%zu mats=%d\n",
                    i, g.numVertices, g.numTriangles, g.uvs.size() / 2,
                    g.normals.size() / 3, g.trailing, g.materialCount);
    }
    for (const auto &t : m.textureNames) std::printf("  tex: %s\n", t.c_str());
    return 0;
}
