#include <algorithm>
// DFF 解析：严格按 librw Geometry::streamRead 的字段顺序
#include <cstdio>
#include <cstdlib>
#include <functional>

#include "assets.h"

namespace sa {

namespace {

constexpr uint32_t FLAG_PRELIT = 0x08;
constexpr uint32_t FLAG_TEXTURED = 0x04;
constexpr uint32_t FLAG_TEXTURED2 = 0x80;
constexpr uint32_t FLAG_NATIVE = 0x01000000;

struct ChunkView {
    uint8_t type = 0;
    uint8_t lib = 0;
    const uint8_t *payload = nullptr;
    size_t size = 0;
    std::vector<ChunkView> children;
};

bool isContainer(uint8_t t) {
    switch (t) {
        case 0x10: case 0x0E: case 0x1C: case 0x14: case 0x1A: case 0x11:
        case 0x0F: case 0x20: case 0x08: case 0x2B: case 0x07: case 0x06:
        case 0x1E: case 0x15: case 0x12: case 0x16: case 0x13: case 0x03:
            return true;
        default:
            return false;
    }
}

void parseChunks(const uint8_t *p, size_t n, std::vector<ChunkView> &out) {
    size_t pos = 0;
    while (pos + 12 <= n) {
        const uint32_t typeRaw = rd32(p + pos);
        const uint32_t size = rd32(p + pos + 4);
        // IMG 条目按 2048 字节对齐，尾部用 0 填充；遇到全 0 的伪块即停止
        if (typeRaw == 0 && size == 0) break;
        if ((size_t)size > n - pos - 12) break;
        ChunkView c;
        c.type = (uint8_t)(typeRaw & 0xFF);
        c.lib = (uint8_t)(typeRaw >> 24);
        c.payload = p + pos + 12;
        c.size = size;
        if (isContainer(c.type)) parseChunks(c.payload, size, c.children);
        out.push_back(std::move(c));
        pos += 12 + size;
    }
}

void walk(const ChunkView &c, const std::function<void(const ChunkView &)> &fn) {
    fn(c);
    for (const auto &k : c.children) walk(k, fn);
}

const ChunkView *findChild(const ChunkView &c, uint8_t type) {
    for (const auto &k : c.children)
        if (k.type == type) return &k;
    return nullptr;
}

// 几何：完全按 librw 顺序读
Geometry parseGeometry(const ChunkView &geo, uint32_t version) {
    Geometry g;
    const ChunkView *st = findChild(geo, 0x01);
    if (!st || st->size < 16) return g;

    Reader r(st->payload, st->size);
    uint32_t flags = 0, nTri = 0, nVert = 0, nMorph = 0;
    if (!r.read(&flags) || !r.read(&nTri) || !r.read(&nVert) || !r.read(&nMorph)) return g;
    if (nVert == 0 || nVert > 300000 || nTri > 300000 || nTri == 0) return g;
    if (nMorph == 0 || nMorph > 64) nMorph = 1;

    g.flags = flags;
    g.numTriangles = (int)nTri;
    g.numVertices = (int)nVert;

    // 老版本 RW 才有 SurfaceProperties
    if (version < 0x34000) r.skip(12);

    // 某些模型的 flags 与实际流布局不一致（如 0x200F3 实际只写一套 UV），
    // 因此按候选组合尝试，选「解析后尾部剩余最少且几何合法」的那个。
    struct Layout {
        int uv;        // 实际写入的 UV 套数
        int surface;   // 是否有 surface flags 段
    } layouts[] = {
        {2, 0}, {1, 0}, {0, 0}, {2, 1}, {1, 1}, {0, 1},
    };

    Geometry best;
    bool found = false;
    for (const auto &L : layouts) {
        Reader rr = r;
        Geometry t;
        t.flags = flags;
        t.numTriangles = (int)nTri;
        t.numVertices = (int)nVert;
        if (L.surface) rr.skip((size_t)nVert * 4);

        if (flags & FLAG_PRELIT) {
            const uint8_t *d = rr.take((size_t)nVert * 4);
            if (!d) continue;
            t.prelit.assign(d, d + (size_t)nVert * 4);
        }
        const int tryUv = L.uv;
        for (int s = 0; s < tryUv; ++s) {
            const uint8_t *d = rr.take((size_t)nVert * 8);
            if (!d) break;
            if (s == 0) {
                t.uvs.resize((size_t)nVert * 2);
                std::memcpy(t.uvs.data(), d, (size_t)nVert * 8);
            }
        }
        if (tryUv > 0 && t.uvs.empty()) continue;
        // 三角形
        bool triOk = true;
        t.indices.resize((size_t)nTri * 3);
        t.materialIds.resize((size_t)nTri);
        for (uint32_t i = 0; i < nTri && triOk; ++i) {
            uint32_t a = 0, b = 0;
            if (!rr.read(&a) || !rr.read(&b)) { triOk = false; break; }
            const uint32_t v0 = a >> 16, v1 = a & 0xFFFF, v2 = b >> 16;
            if (v0 >= nVert || v1 >= nVert || v2 >= nVert) { triOk = false; break; }
            t.indices[(size_t)i * 3 + 0] = v0;
            t.indices[(size_t)i * 3 + 1] = v1;
            t.indices[(size_t)i * 3 + 2] = v2;
            t.materialIds[(size_t)i] = (uint16_t)(b & 0xFFFF);
        }
        if (!triOk) continue;

        // morph targets
        bool morphOk = true;
        for (uint32_t m = 0; m < nMorph && morphOk; ++m) {
            float sphere[4];
            int32_t hasV = 0, hasN = 0;
            for (int k = 0; k < 4; ++k)
                if (!rr.read(&sphere[k])) { morphOk = false; break; }
            if (!morphOk) break;
            if (!rr.read(&hasV) || !rr.read(&hasN)) { morphOk = false; break; }
            if (m == 0) std::memcpy(t.sphere, sphere, sizeof(sphere));
            if (hasV) {
                const uint8_t *d = rr.take((size_t)nVert * 12);
                if (!d) { morphOk = false; break; }
                if (m == 0)
                    t.positions.assign((const float *)d, (const float *)d + (size_t)nVert * 3);
            }
            if (hasN) {
                const uint8_t *d = rr.take((size_t)nVert * 12);
                if (!d) { morphOk = false; break; }
                if (m == 0)
                    t.normals.assign((const float *)d, (const float *)d + (size_t)nVert * 3);
            }
        }
        if (!morphOk || t.positions.empty()) continue;

        t.trailing = rr.remaining();
        t.valid = true;
        // 尾部越短越可信
        if (!found || t.trailing < best.trailing) {
            best = std::move(t);
            found = true;
        }
        if (best.trailing == 0) break;
    }

    if (!found) return g;
    Geometry &out = best;

    // 骨骼绑定：扩展块里的 FrameList，hdr[1]==1 时 hdr[2]==hdr[3] 为骨骼 ID
    if (const ChunkView *ext = findChild(geo, 0x03)) {
        for (const auto &k : ext->children) {
            if (k.type != 0x0E || k.size < 16) continue;
            const uint32_t h1 = rd32(k.payload + 4);
            const uint32_t h2 = rd32(k.payload + 8);
            const uint32_t h3 = rd32(k.payload + 12);
            if (h1 == 1 && h2 == h3) out.boneIndex = (int)h2;
            break;
        }
    }

    // 材质列表：取每个材质的纹理名
    const ChunkView *matList = findChild(geo, 0x08);
    if (matList) {
        for (const auto &mat : matList->children) {
            if (mat.type != 0x07) continue;
            ++out.materialCount;
            std::string texName;
            const ChunkView *tex = findChild(mat, 0x06);
            if (tex) {
                for (const auto &k : tex->children) {
                    if (k.type == 0x02 && k.size >= 2) {
                        texName.assign((const char *)k.payload,
                                       strnlen((const char *)k.payload, k.size));
                        break;
                    }
                }
            }
            out.materialTextures.push_back(texName);
        }
    }

    if (getenv("SA_DEBUG"))
        fprintf(stderr, "[geo] v=%d t=%d pos=%zu idx=%zu trail=%zu\n", out.numVertices,
                out.numTriangles, out.positions.size(), out.indices.size(), out.trailing);
    return out;
}

uint32_t readVersion(const ChunkView &top) {
    if (top.lib == 0 && top.size >= 4) return rd32(top.payload);
    return 0x36003;
}

}  // namespace

Model parseDFF(const std::vector<uint8_t> &buf) {
    Model model;
    std::vector<ChunkView> tops;
    parseChunks(buf.data(), buf.size(), tops);
    for (const auto &top : tops) {
        // 骨架
        if (const ChunkView *fl = findChild(top, 0x0E)) {
            if (const ChunkView *st = findChild(*fl, 0x01)) {
                const uint32_t nb = rd32(st->payload);
                const size_t step = 36 + 12 + 4 + 4;
                for (uint32_t i = 0; i < nb; ++i) {
                    const size_t o = 4 + (size_t)i * step;
                    if (o + step > st->size) break;
                    Bone b;
                    for (int k = 0; k < 9; ++k) b.rot[k] = rdf(st->payload + o + k * 4);
                    for (int k = 0; k < 3; ++k) b.pos[k] = rdf(st->payload + o + 36 + k * 4);
                    b.parent = (int)rd32(st->payload + o + 48);
                    model.bones.push_back(b);
                }
            }
        }
        walk(top, [&](const ChunkView &c) {
            if (c.type != 0x0F) return;
            // 几何块的版本继承自其所属 Clump 或自身 struct 头
            Geometry g = parseGeometry(c, 0x36003);
            if (!g.valid) return;
            model.totalTriangles += g.numTriangles;
            model.totalVertices += g.numVertices;
            for (const auto &t : g.materialTextures)
                if (!t.empty()) model.textureNames.push_back(t);
            model.geometries.push_back(std::move(g));
        });
    }
    std::sort(model.textureNames.begin(), model.textureNames.end());
    model.textureNames.erase(std::unique(model.textureNames.begin(), model.textureNames.end()),
                             model.textureNames.end());
    return model;
}

}  // namespace sa
