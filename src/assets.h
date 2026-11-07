// SA 资源读取层 —— IMG 归档 / DFF / TXD
// 仅供本地合法持有的游戏文件使用；不内嵌任何原作资源。
#pragma once

#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace sa {

// ---------------------------------------------------------------- 小工具
struct Reader {
    const uint8_t *p = nullptr;
    size_t n = 0;
    size_t off = 0;

    Reader() = default;
    Reader(const uint8_t *data, size_t size) : p(data), n(size) {}

    bool eof() const { return off >= n; }
    size_t remaining() const { return n > off ? n - off : 0; }

    template <class T>
    bool read(T *out) {
        if (off + sizeof(T) > n) return false;
        std::memcpy(out, p + off, sizeof(T));
        off += sizeof(T);
        return true;
    }
    bool skip(size_t k) {
        if (off + k > n) return false;
        off += k;
        return true;
    }
    const uint8_t *take(size_t k) {
        if (off + k > n) return nullptr;
        const uint8_t *r = p + off;
        off += k;
        return r;
    }
};

inline uint32_t rd32(const uint8_t *d) {
    uint32_t v;
    std::memcpy(&v, d, 4);
    return v;
}
inline uint16_t rd16(const uint8_t *d) {
    uint16_t v;
    std::memcpy(&v, d, 2);
    return v;
}
inline float rdf(const uint8_t *d) {
    float v;
    std::memcpy(&v, d, 4);
    return v;
}

// ---------------------------------------------------------------- IMG 归档
struct ImgEntry {
    std::string name;
    uint32_t offset = 0;   // 字节
    uint32_t size = 0;     // 字节
};

class ImgArchive {
public:
    bool open(const std::string &path);
    bool readEntry(const std::string &name, std::vector<uint8_t> &out) const;
    const ImgEntry *find(const std::string &name) const;
    const std::vector<ImgEntry> &entries() const { return entries_; }

private:
    std::string path_;
    std::vector<ImgEntry> entries_;
    std::unordered_map<std::string, size_t> index_;
};

// ---------------------------------------------------------------- 纹理
struct Texture {
    std::string name;
    int width = 0, height = 0;
    int levels = 1;
    int depth = 0;
    int rasterType = 0;      // 1=4444 2=1555 3=565 4=8888
    std::string d3dFormat;   // "DXT1"/"DXT3"/"DXT5"/"8888"...
    std::vector<uint8_t> data;      // mip0 原始数据
    std::vector<uint8_t> palette;   // ARGB8888
    bool hasAlpha = false;

    // 解码为 RGBA8；失败返回空
    std::vector<uint8_t> decodeRGBA() const;
};

std::vector<Texture> parseTXD(const std::vector<uint8_t> &buf);

// ---------------------------------------------------------------- 几何
struct Geometry {
    uint32_t flags = 0;
    int numTriangles = 0;
    int numVertices = 0;
    std::vector<float> positions;   // 3 * n
    std::vector<float> normals;     // 3 * n（可能为空）
    std::vector<float> uvs;         // 2 * n（可能为空）
    std::vector<uint8_t> prelit;    // 4 * n（可能为空）
    std::vector<uint32_t> indices;  // 3 * t（已展开的三角形索引）
    std::vector<uint16_t> materialIds;  // t（每个三角形的材质索引）
    float sphere[4] = {0, 0, 0, 0};
    int materialCount = 0;
    std::vector<std::string> materialTextures;   // 每个几何体的材质贴图名
    bool valid = false;
    size_t trailing = 0;            // 解析后剩余字节（正确时应为 0）
};

struct Model {
    std::vector<Geometry> geometries;
    std::vector<std::string> textureNames;   // 去重后的贴图需求
    int totalTriangles = 0;
    int totalVertices = 0;
};

// 解析 DFF；version 取自顶层 Clump 子块的 struct 版本
Model parseDFF(const std::vector<uint8_t> &buf);

// ---------------------------------------------------------------- 便捷加载
class AssetStore {
public:
    bool mount(const std::string &imgPath);
    bool loadModel(const std::string &name, Model &out) const;
    bool loadTexture(const std::string &name, Texture &out) const;
    // 在指定 TXD 中按纹理名取一张
    bool loadTextureFrom(const std::string &txdName, const std::string &texName,
                         Texture &out) const;
    // 模型优先在本 IMG 找，其次在 fallback（通常 gta3.img）
    std::shared_ptr<ImgArchive> primary, fallback;

private:
    static std::string lower(std::string s);
};

}  // namespace sa
