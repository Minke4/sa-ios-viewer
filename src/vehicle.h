// 车辆加载：DFF → 按骨骼绑定的部件网格
// SA 的车辆是「骨骼 + 多 Geometry」结构，每个 Geometry 的扩展块里
// 记录了它绑定的骨骼索引（FrameList: hdr[1]==1 时 hdr[2]==hdr[3]==骨骼ID）。
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "renderer.h"

namespace sa {

struct VehiclePart {
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
    int bone = 0;              // 绑定的骨骼索引
    std::string textureName;
};

struct VehicleMesh {
    std::vector<Vertex> vertices;
    std::vector<uint32_t> indices;
    std::vector<VehiclePart> parts;
    float bounds[6] = {0, 0, 0, 0, 0, 0};
    // 车轮骨骼索引（自动识别：位于车体四角、直径最小的圆形部件）
    int wheels[4] = {-1, -1, -1, -1};   // 左前 右前 左后 右后
    float wheelRadius[4] = {0, 0, 0, 0};
    bool valid = false;
};

// 解析车辆 DFF，把各部件按骨骼变换烘焙到车体空间
bool buildVehicle(const std::vector<uint8_t> &dff, VehicleMesh &out);

}  // namespace sa
