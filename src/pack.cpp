#include "pack.h"

#include <zlib.h>

#include <cstdio>
#include <cstring>
#include <map>
#include <sstream>

namespace sa {

namespace {

bool readFile(const std::string &path, std::vector<uint8_t> &out) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    const long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (n < 0) { std::fclose(f); return false; }
    out.resize((size_t)n);
    const size_t got = std::fread(out.data(), 1, out.size(), f);
    std::fclose(f);
    return got == out.size();
}

// 极简 PNG 解码：支持 8 位 RGB/RGBA、非隔行（贴图导出即是这种）
bool decodePNG(const std::vector<uint8_t> &png, PackTexture &tex) {
    if (png.size() < 8 || png[0] != 0x89 || png[1] != 'P') return false;
    size_t pos = 8;
    int width = 0, height = 0, bitDepth = 0, colorType = 0;
    std::vector<uint8_t> idat;

    while (pos + 8 <= png.size()) {
        const uint32_t len = ((uint32_t)png[pos] << 24) | ((uint32_t)png[pos + 1] << 16) |
                             ((uint32_t)png[pos + 2] << 8) | png[pos + 3];
        const char *type = (const char *)&png[pos + 4];
        const uint8_t *data = &png[pos + 8];
        if (pos + 12 + len > png.size()) break;

        if (std::memcmp(type, "IHDR", 4) == 0 && len >= 13) {
            width = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
            height = (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7];
            bitDepth = data[8];
            colorType = data[9];
            if (data[12] != 0) return false;  // 隔行不支持
        } else if (std::memcmp(type, "IDAT", 4) == 0) {
            idat.insert(idat.end(), data, data + len);
        } else if (std::memcmp(type, "IEND", 4) == 0) {
            break;
        }
        pos += 12 + len;
    }
    if (width <= 0 || height <= 0 || bitDepth != 8) return false;
    const int channels = (colorType == 6) ? 4 : (colorType == 2) ? 3 : 0;
    if (!channels) return false;

    const size_t rawSize = (size_t)height * (1 + (size_t)width * channels);
    std::vector<uint8_t> raw(rawSize);
    uLongf outLen = (uLongf)rawSize;
    if (uncompress(raw.data(), &outLen, idat.data(), (uLong)idat.size()) != Z_OK) return false;
    if (outLen != rawSize) return false;

    // 反滤波
    const size_t stride = (size_t)width * channels;
    std::vector<uint8_t> pixels(stride * height);
    for (int y = 0; y < height; ++y) {
        const uint8_t *src = &raw[(size_t)y * (stride + 1)];
        const uint8_t filter = src[0];
        const uint8_t *in = src + 1;
        uint8_t *dst = &pixels[(size_t)y * stride];
        const uint8_t *prev = y > 0 ? &pixels[(size_t)(y - 1) * stride] : nullptr;
        for (size_t x = 0; x < stride; ++x) {
            const int a = x >= (size_t)channels ? dst[x - channels] : 0;
            const int b = prev ? prev[x] : 0;
            const int c = (prev && x >= (size_t)channels) ? prev[x - channels] : 0;
            int v = in[x];
            switch (filter) {
                case 0: break;
                case 1: v += a; break;
                case 2: v += b; break;
                case 3: v += (a + b) / 2; break;
                case 4: {
                    const int p = a + b - c;
                    const int pa = std::abs(p - a), pb = std::abs(p - b), pc = std::abs(p - c);
                    v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
                    break;
                }
                default: return false;
            }
            dst[x] = (uint8_t)v;
        }
    }

    tex.width = width;
    tex.height = height;
    tex.rgba.resize((size_t)width * height * 4);
    for (size_t i = 0; i < (size_t)width * height; ++i) {
        if (channels == 4) {
            std::memcpy(&tex.rgba[i * 4], &pixels[i * 4], 4);
        } else {
            tex.rgba[i * 4 + 0] = pixels[i * 3 + 0];
            tex.rgba[i * 4 + 1] = pixels[i * 3 + 1];
            tex.rgba[i * 4 + 2] = pixels[i * 3 + 2];
            tex.rgba[i * 4 + 3] = 255;
        }
    }
    return true;
}

// 极简 JSON 提取（只取本项目需要的字段，避免引入依赖）
std::string jsonStr(const std::string &s, const std::string &key) {
    const std::string pat = "\"" + key + "\"";
    size_t p = s.find(pat);
    if (p == std::string::npos) return "";
    p = s.find(':', p);
    if (p == std::string::npos) return "";
    p = s.find('"', p);
    if (p == std::string::npos) return "";
    const size_t e = s.find('"', p + 1);
    return e == std::string::npos ? "" : s.substr(p + 1, e - p - 1);
}

}  // namespace

bool loadBundle(const std::string &basePath, PackInfo &out) {
    std::vector<uint8_t> mesh;
    if (!readFile(basePath + "/mesh.bin", mesh)) {
        out.error = "mesh.bin 读取失败";
        return false;
    }
    if (mesh.size() < 8) { out.error = "mesh.bin 过短"; return false; }

    size_t p = 0;
    uint32_t vcount = 0;
    std::memcpy(&vcount, &mesh[p], 4); p += 4;
    const size_t needV = (size_t)vcount * 12 * sizeof(float);
    if (p + needV + 4 > mesh.size()) { out.error = "mesh.bin 顶点区越界"; return false; }
    const float *vertPtr = (const float *)&mesh[p];
    p += needV;
    uint32_t icount = 0;
    std::memcpy(&icount, &mesh[p], 4); p += 4;
    const size_t needI = (size_t)icount * sizeof(uint32_t);
    if (p + needI > mesh.size()) { out.error = "mesh.bin 索引区越界"; return false; }
    const uint32_t *idxPtr = (const uint32_t *)&mesh[p];

    out.vertexCount = (int)vcount;
    out.triangleCount = (int)(icount / 3);

    // 读取 meta.json（子网格与包围盒）
    std::vector<uint8_t> metaRaw;
    if (readFile(basePath + "/meta.json", metaRaw)) {
        std::string meta(metaRaw.begin(), metaRaw.end());
        // bounds
        const size_t b = meta.find("\"bounds\"");
        if (b != std::string::npos) {
            size_t q = meta.find('[', b);
            if (q != std::string::npos) {
                ++q;
                for (int i = 0; i < 6; ++i) {
                    while (q < meta.size() && (meta[q] == ' ' || meta[q] == '\n' || meta[q] == ',')) ++q;
                    char *end = nullptr;
                    out.bounds[i] = std::strtof(meta.c_str() + q, &end);
                    if (end) q = (size_t)(end - meta.c_str());
                }
            }
        }
        // submeshes: 反复查找 "first"/"count"/"tex"
        size_t sp = meta.find("\"submeshes\"");
        if (sp != std::string::npos) {
            size_t cur = sp;
            for (;;) {
                const size_t f = meta.find("\"first\"", cur);
                if (f == std::string::npos) break;
                const size_t c = meta.find("\"count\"", f);
                if (c == std::string::npos) break;
                const size_t t = meta.find("\"tex\"", c);
                if (t == std::string::npos) break;
                SubMesh sm;
                sm.firstIndex = (uint32_t)std::atoi(meta.c_str() + meta.find(':', f) + 1);
                sm.indexCount = (uint32_t)std::atoi(meta.c_str() + meta.find(':', c) + 1);
                sm.textureName = jsonStr(meta.substr(t, 128), "tex");
                out.submeshes.push_back(sm);
                cur = t + 5;
            }
        }
    }

    // 复制顶点与索引
    out.vertexCount = (int)vcount;
    out.triangleCount = (int)(icount / 3);
    out.mesh.vertices.resize(vcount);
    std::memcpy(out.mesh.vertices.data(), vertPtr, needV);
    out.mesh.indices.assign(idxPtr, idxPtr + icount);
    out.mesh.submeshes = out.submeshes;
    std::memcpy(out.mesh.bounds, out.bounds, sizeof(out.bounds));

    // 贴图
    for (const auto &sm : out.submeshes) {
        if (sm.textureName.empty()) continue;
        bool dup = false;
        for (const auto &t : out.textures)
            if (t.name == sm.textureName) { dup = true; break; }
        if (dup) continue;
        std::vector<uint8_t> png;
        if (!readFile(basePath + "/tex/" + sm.textureName + ".png", png)) continue;
        PackTexture pt;
        pt.name = sm.textureName;
        if (decodePNG(png, pt)) out.textures.push_back(std::move(pt));
    }

    out.model = basePath;
    out.loaded = true;
    return true;
}

}  // namespace sa
