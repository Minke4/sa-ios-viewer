// 地面高度查询：用预建的 XZ 网格加速射线检测
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "renderer.h"

namespace sa {

class GroundGrid {
public:
    // 从 ground.bin 加载；mesh 提供顶点与三角形
    bool load(const std::string &path, const MeshData &mesh);

    // 查询 (x,z) 处最高地面高度；找不到返回 false
    bool heightAt(float x, float z, float &outY) const;

    // 查询视线方向是否能站(可选：忽略高度差)
    bool valid() const { return !verts_.empty(); }
    float minX() const { return minX_; }
    float minZ() const { return minZ_; }
    float cellSize() const { return cell_; }
    int cellsX() const { return cellsX_; }
    int cellsZ() const { return cellsZ_; }

private:
    std::vector<float> verts_;      // xyz 连续
    std::vector<uint32_t> idx_;     // 三角形索引
    std::vector<uint32_t> cellStart_;
    std::vector<uint32_t> cellTris_;
    int cellsX_ = 0, cellsZ_ = 0;
    float minX_ = 0, minZ_ = 0, cell_ = 1;
};

}  // namespace sa
