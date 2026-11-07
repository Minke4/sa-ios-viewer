#include "assets.h"

namespace sa {

std::string AssetStore::lower(std::string s) {
    for (auto &c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

bool AssetStore::mount(const std::string &imgPath) {
    auto a = std::make_shared<ImgArchive>();
    if (!a->open(imgPath)) return false;
    if (primary) fallback = a;
    else primary = a;
    return true;
}

bool AssetStore::loadModel(const std::string &name, Model &out) const {
    std::vector<uint8_t> data;
    bool ok = false;
    if (primary && primary->readEntry(name, data)) ok = true;
    else if (fallback && fallback->readEntry(name, data)) ok = true;
    if (!ok) return false;
    out = parseDFF(data);
    return !out.geometries.empty();
}

bool AssetStore::loadTexture(const std::string &name, Texture &out) const {
    std::vector<uint8_t> data;
    if (!(primary && primary->readEntry(name, data)) &&
        !(fallback && fallback->readEntry(name, data)))
        return false;
    auto list = parseTXD(data);
    if (list.empty()) return false;
    out = std::move(list.front());
    return true;
}

bool AssetStore::loadTextureFrom(const std::string &txdName,
                                 const std::string &texName, Texture &out) const {
    std::vector<uint8_t> data;
    if (!(primary && primary->readEntry(txdName, data)) &&
        !(fallback && fallback->readEntry(txdName, data)))
        return false;
    auto list = parseTXD(data);
    const std::string want = lower(texName);
    for (auto &t : list) {
        if (lower(t.name) == want) { out = std::move(t); return true; }
    }
    return false;
}

}  // namespace sa
