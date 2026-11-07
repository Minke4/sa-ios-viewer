// 批量验证：对 IMG 内所有 DFF 解析，统计成功率
#include <chrono>
#include <cstdio>
#include <vector>

#include "assets.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "用法: %s <IMG> [抽样数]\n", argv[0]);
        return 1;
    }
    sa::ImgArchive img;
    if (!img.open(argv[1])) {
        std::fprintf(stderr, "打不开 %s\n", argv[1]);
        return 2;
    }
    size_t limit = argc > 2 ? (size_t)std::atol(argv[2]) : SIZE_MAX;

    std::vector<const sa::ImgEntry *> dffs;
    for (const auto &e : img.entries()) {
        std::string n = e.name;
        for (auto &c : n) c = (char)tolower((unsigned char)c);
        if (n.size() > 4 && n.compare(n.size() - 4, 4, ".dff") == 0) dffs.push_back(&e);
    }
    std::printf("DFF 总数 %zu\n", dffs.size());
    if (dffs.size() > limit) dffs.resize(limit);

    size_t ok = 0, noGeo = 0, bad = 0;
    long long tris = 0, verts = 0, trailing = 0;
    auto t0 = std::chrono::steady_clock::now();
    std::vector<uint8_t> data;
    for (const auto *e : dffs) {
        if (!img.readEntry(e->name, data)) { ++bad; continue; }
        sa::Model m = sa::parseDFF(data);
        if (m.geometries.empty()) { ++noGeo; continue; }
        ++ok;
        tris += m.totalTriangles;
        verts += m.totalVertices;
        for (const auto &g : m.geometries) trailing += (long long)g.trailing;
    }
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - t0).count();
    std::printf("成功 %zu, 无几何 %zu, 读取失败 %zu\n", ok, noGeo, bad);
    std::printf("三角形 %lld, 顶点 %lld, 尾部字节合计 %lld\n", tris, verts, trailing);
    std::printf("耗时 %lld ms (%.2f ms/模型)\n", (long long)ms, (double)ms / dffs.size());
    return 0;
}
