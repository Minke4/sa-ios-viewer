// 碰撞查询：地面高度 + 水平阻挡
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace sa {

class CollisionWorld {
public:
    bool load(const std::string &path);

    // (x,z) 处地面高度（向下射线取最高）
    bool groundAt(float x, float z, float &outY) const;

    // 从 from 走到 to 是否被墙挡住（水平射线检测）
    bool blocked(float fx, float fz, float tx, float tz, float feetY) const;

    bool valid() const { return !verts_.empty(); }
    int triangleCount() const { return (int)idx_.size() / 3; }
    int vertexCount() const { return (int)verts_.size() / 3; }

private:
    void cellRange(float x0, float z0, float x1, float z1,
                   int &c0, int &c1) const;

    std::vector<float> verts_;
    std::vector<uint32_t> idx_;
    std::vector<uint32_t> cellStart_;
    std::vector<uint32_t> cellTris_;
    int gx_ = 0, gz_ = 0;
    float minX_ = 0, minZ_ = 0, cell_ = 1;
};

}  // namespace sa
