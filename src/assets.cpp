#include "assets.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <functional>

namespace sa {

// ---------------------------------------------------------------- IMG
static std::string lowerAscii(std::string s) {
    for (auto &c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

bool ImgArchive::open(const std::string &path) {
    path_ = path;
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;

    char magic[4];
    f.read(magic, 4);
    if (std::memcmp(magic, "VER2", 4) != 0) return false;

    uint32_t count = 0;
    f.read((char *)&count, 4);
    if (count == 0 || count > 1000000) return false;

    f.seekg(0, std::ios::end);
    const size_t fileSize = (size_t)f.tellg();
    f.seekg(8);

    entries_.reserve(count);
    std::vector<uint8_t> rec(32);
    for (uint32_t i = 0; i < count; ++i) {
        f.read((char *)rec.data(), 32);
        if (!f) break;
        uint32_t sector = rd32(rec.data());
        uint32_t sectors = rd32(rec.data() + 4);
        const uint32_t off = sector * 2048u;
        const uint32_t sz = sectors * 2048u;
        if ((size_t)off + sz > fileSize) continue;
        char nm[25] = {0};
        std::memcpy(nm, rec.data() + 8, 24);
        std::string name(nm);
        if (name.empty()) continue;
        index_[lowerAscii(name)] = entries_.size();
        entries_.push_back({name, off, sz});
    }
    return !entries_.empty();
}

const ImgEntry *ImgArchive::find(const std::string &name) const {
    auto it = index_.find(lowerAscii(name));
    if (it == index_.end()) return nullptr;
    return &entries_[it->second];
}

bool ImgArchive::readEntry(const std::string &name, std::vector<uint8_t> &out) const {
    const ImgEntry *e = find(name);
    if (!e) return false;
    std::ifstream f(path_, std::ios::binary);
    if (!f) return false;
    f.seekg(e->offset);
    out.resize(e->size);
    f.read((char *)out.data(), e->size);
    return (bool)f || f.gcount() == (std::streamsize)e->size;
}

// ---------------------------------------------------------------- TXD
static void decodeDXT1(const uint8_t *src, size_t srcLen, int w, int h,
                       std::vector<uint8_t> &out, bool dxt3) {
    out.assign((size_t)w * h * 4, 0);
    const int bw = (w + 3) / 4, bh = (h + 3) / 4;
    const int blockSize = dxt3 ? 16 : 8;
    for (int by = 0; by < bh; ++by) {
        for (int bx = 0; bx < bw; ++bx) {
            const size_t o = ((size_t)by * bw + bx) * blockSize;
            if (o + blockSize > srcLen) return;
            const uint8_t *blk = src + o;
            uint64_t alphaBits = 0;
            if (dxt3) alphaBits = (uint64_t)blk[0] | ((uint64_t)blk[1] << 8) |
                                  ((uint64_t)blk[2] << 16) | ((uint64_t)blk[3] << 24) |
                                  ((uint64_t)blk[4] << 32) | ((uint64_t)blk[5] << 40) |
                                  ((uint64_t)blk[6] << 48) | ((uint64_t)blk[7] << 56);
            const uint8_t *c = blk + (dxt3 ? 8 : 0);
            const uint16_t c0 = rd16(c), c1 = rd16(c + 2);
            const uint32_t bits = rd32(c + 4);
            uint8_t col[4][4];
            auto expand = [](uint16_t v, uint8_t *dst) {
                const int r = (v >> 11) & 0x1F, g = (v >> 5) & 0x3F, b = v & 0x1F;
                dst[0] = (uint8_t)((r << 3) | (r >> 2));
                dst[1] = (uint8_t)((g << 2) | (g >> 4));
                dst[2] = (uint8_t)((b << 3) | (b >> 2));
                dst[3] = 255;
            };
            expand(c0, col[0]);
            expand(c1, col[1]);
            if (c0 > c1 || dxt3) {
                for (int k = 0; k < 3; ++k) {
                    col[2][k] = (uint8_t)((2 * col[0][k] + col[1][k]) / 3);
                    col[3][k] = (uint8_t)((col[0][k] + 2 * col[1][k]) / 3);
                }
                col[2][3] = col[3][3] = 255;
            } else {
                for (int k = 0; k < 3; ++k)
                    col[2][k] = (uint8_t)((col[0][k] + col[1][k]) / 2);
                col[2][3] = 255;
                col[3][0] = col[3][1] = col[3][2] = col[3][3] = 0;
            }
            for (int i = 0; i < 16; ++i) {
                const int px = bx * 4 + (i % 4), py = by * 4 + (i / 4);
                if (px >= w || py >= h) continue;
                const int idx = (bits >> (2 * i)) & 3;
                uint8_t *dst = &out[((size_t)py * w + px) * 4];
                dst[0] = col[idx][0];
                dst[1] = col[idx][1];
                dst[2] = col[idx][2];
                dst[3] = dxt3 ? (uint8_t)(((alphaBits >> (4 * i)) & 0xF) * 17)
                              : col[idx][3];
            }
        }
    }
}

std::vector<uint8_t> Texture::decodeRGBA() const {
    const int w = width, h = height;
    if (w <= 0 || h <= 0 || data.empty()) return {};
    std::vector<uint8_t> out((size_t)w * h * 4, 0);

    if (d3dFormat == "DXT1") {
        decodeDXT1(data.data(), data.size(), w, h, out, false);
        return out;
    }
    if (d3dFormat == "DXT3" || d3dFormat == "DXT5") {
        // DXT5 的 alpha 块与 DXT3 不同；此处按 DXT3 处理颜色部分
        decodeDXT1(data.data(), data.size(), w, h, out, true);
        return out;
    }
    if (!palette.empty() && (size_t)w * h <= data.size()) {
        // 调色板（ARGB8888）
        const int pals = (int)(palette.size() / 4);
        for (int i = 0; i < w * h; ++i) {
            const int idx = data[i];
            if (idx >= pals) continue;
            const uint8_t *p = &palette[(size_t)idx * 4];
            out[(size_t)i * 4 + 0] = p[2];
            out[(size_t)i * 4 + 1] = p[1];
            out[(size_t)i * 4 + 2] = p[0];
            out[(size_t)i * 4 + 3] = p[3];
        }
        return out;
    }
    if (rasterType == 3 && data.size() >= (size_t)w * h * 2) {
        for (int i = 0; i < w * h; ++i) {
            const uint16_t v = rd16(&data[(size_t)i * 2]);
            const int r = (v >> 11) & 0x1F, g = (v >> 5) & 0x3F, b = v & 0x1F;
            out[(size_t)i * 4 + 0] = (uint8_t)((r << 3) | (r >> 2));
            out[(size_t)i * 4 + 1] = (uint8_t)((g << 2) | (g >> 4));
            out[(size_t)i * 4 + 2] = (uint8_t)((b << 3) | (b >> 2));
            out[(size_t)i * 4 + 3] = 255;
        }
        return out;
    }
    if (data.size() >= (size_t)w * h * 4) {
        // BGRA8888
        for (int i = 0; i < w * h; ++i) {
            const uint8_t *s = &data[(size_t)i * 4];
            out[(size_t)i * 4 + 0] = s[2];
            out[(size_t)i * 4 + 1] = s[1];
            out[(size_t)i * 4 + 2] = s[0];
            out[(size_t)i * 4 + 3] = hasAlpha ? s[3] : 255;
        }
        return out;
    }
    return {};
}

// ---- RenderWare 块遍历（与 Python 版同一规则）
struct Chunk {
    uint8_t type = 0;
    uint8_t lib = 0;
    const uint8_t *payload = nullptr;
    size_t size = 0;
    std::vector<Chunk> children;
};

static bool isContainer(uint8_t t) {
    switch (t) {
        case 0x10: case 0x0E: case 0x1C: case 0x14: case 0x1A: case 0x11:
        case 0x0F: case 0x20: case 0x08: case 0x2B: case 0x07: case 0x06:
        case 0x1E: case 0x15: case 0x12: case 0x16: case 0x13: case 0x03:
            return true;
        default:
            return false;
    }
}

static void parseChunks(const uint8_t *p, size_t n, std::vector<Chunk> &out) {
    size_t pos = 0;
    while (pos + 12 <= n) {
        const uint32_t typeRaw = rd32(p + pos);
        const uint32_t size = rd32(p + pos + 4);
        const uint8_t lib = (uint8_t)(typeRaw >> 24);
        const uint8_t type = (uint8_t)(typeRaw & 0xFF);
        if ((size_t)size > n - pos - 12) break;
        Chunk c;
        c.type = type;
        c.lib = lib;
        c.payload = p + pos + 12;
        c.size = size;
        if (isContainer(type)) parseChunks(c.payload, size, c.children);
        out.push_back(std::move(c));
        pos += 12 + size;
    }
}

static void walk(const Chunk &c, const std::function<void(const Chunk &)> &fn) {
    fn(c);
    for (const auto &k : c.children) walk(k, fn);
}

std::vector<Texture> parseTXD(const std::vector<uint8_t> &buf) {
    std::vector<Texture> out;
    std::vector<Chunk> tops;
    parseChunks(buf.data(), buf.size(), tops);
    for (const auto &t : tops) {
        walk(t, [&](const Chunk &c) {
            if (c.type != 0x15 || c.lib != 0 || c.size < 88) return;
            for (const auto &k : c.children) {
                if (k.type != 0x01) continue;
                const uint8_t *d = k.payload;
                const size_t n = k.size;
                if (n < 88) return;
                Texture tex;
                tex.name.assign((const char *)d + 8, strnlen((const char *)d + 8, 32));
                tex.width = (int)rd16(d + 80);
                tex.height = (int)rd16(d + 82);
                tex.depth = d[84];
                tex.levels = d[85] ? d[85] : 1;
                tex.rasterType = d[86];
                tex.hasAlpha = d[87] != 0;
                const uint32_t fmt = rd32(d + 76);
                switch (fmt) {
                    case 0x31545844: tex.d3dFormat = "DXT1"; break;
                    case 0x33545844: tex.d3dFormat = "DXT3"; break;
                    case 0x35545844: tex.d3dFormat = "DXT5"; break;
                    default: break;
                }
                if (tex.d3dFormat.empty()) {
                    switch (tex.rasterType) {
                        case 1: tex.d3dFormat = "4444"; break;
                        case 2: tex.d3dFormat = "1555"; break;
                        case 3: tex.d3dFormat = "565"; break;
                        case 4: tex.d3dFormat = "8888"; break;
                        default: tex.d3dFormat = "8888"; break;
                    }
                }
                size_t p = 88;
                const uint32_t rasterFormat = rd32(d + 72);
                if ((rasterFormat & 0x2000) && p + 4 <= n) {
                    const uint32_t pal = rd32(d + p);
                    p += 4;
                    if (p + (size_t)pal * 4 <= n) {
                        tex.palette.assign(d + p, d + p + (size_t)pal * 4);
                        p += (size_t)pal * 4;
                    }
                }
                for (int lv = 0; lv < tex.levels; ++lv) {
                    if (p + 4 > n) break;
                    const uint32_t sz = rd32(d + p);
                    p += 4;
                    if (lv == 0 && p + sz <= n) tex.data.assign(d + p, d + p + sz);
                    p += sz;
                }
                out.push_back(std::move(tex));
            }
        });
    }
    return out;
}

}  // namespace sa
