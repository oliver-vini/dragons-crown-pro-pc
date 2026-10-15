#include "game_files.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <system_error>
#include <vector>

#include "crypto.h"

namespace dcp {
namespace {

constexpr std::uintmax_t kMaxSmallFile = 4u << 20;

constexpr const char* kImageFiles[] = {"boot.bin", "content.bin", "image.json"};

bool ReadSmallFile(const std::filesystem::path& path, std::string& out) {
    std::error_code ec;
    const std::uintmax_t size = std::filesystem::file_size(path, ec);
    if (ec || size > kMaxSmallFile) {
        return false;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
    out.assign(static_cast<size_t>(size), '\0');
    in.read(out.data(), static_cast<std::streamsize>(size));
    return static_cast<std::uintmax_t>(in.gcount()) == size;
}

uint16_t Le16(const unsigned char* p) { return static_cast<uint16_t>(p[0] | p[1] << 8); }
uint32_t Le32(const unsigned char* p) {
    return static_cast<uint32_t>(p[0]) | static_cast<uint32_t>(p[1]) << 8 | static_cast<uint32_t>(p[2]) << 16 |
           static_cast<uint32_t>(p[3]) << 24;
}

struct SfoEntry {
    uint16_t format = 0;
    std::string value;
};

std::optional<SfoEntry> FindSfoEntry(const std::string& sfo, const char* key) {
    const auto* data = reinterpret_cast<const unsigned char*>(sfo.data());
    const size_t size = sfo.size();
    if (size < 20 || std::memcmp(data, "\0PSF", 4) != 0) {
        return std::nullopt;
    }
    const uint32_t keys = Le32(data + 8), values = Le32(data + 12), count = Le32(data + 16);
    for (uint32_t i = 0; i < count && 20 + static_cast<size_t>(i) * 16 + 16 <= size; ++i) {
        const unsigned char* entry = data + 20 + static_cast<size_t>(i) * 16;
        const uint16_t key_offset = Le16(entry), format = Le16(entry + 2);
        const uint32_t length = Le32(entry + 4), offset = Le32(entry + 12);
        if (static_cast<size_t>(keys) + key_offset >= size || static_cast<size_t>(values) + offset + length > size) {
            continue;
        }
        const char* name = sfo.c_str() + keys + key_offset;
        if (std::string_view(name, strnlen(name, size - keys - key_offset)) == key) {
            return SfoEntry{format, sfo.substr(values + offset, length)};
        }
    }
    return std::nullopt;
}

bool IsRegularNonEmpty(const std::filesystem::path& path) {
    std::error_code ec;
    return std::filesystem::is_regular_file(path, ec) && std::filesystem::file_size(path, ec) > 0 && !ec;
}

GameCheck Result(GameFileState state, std::string detail, std::string sha = {}) {
    GameCheck check;
    check.state = state;
    check.detail = std::move(detail);
    check.eboot_sha256 = std::move(sha);
    return check;
}

} // namespace

std::string SfoString(const std::string& sfo, const char* key) {
    const std::optional<SfoEntry> entry = FindSfoEntry(sfo, key);
    if (!entry || (entry->format != 0x0204 && entry->format != 0x0004)) {
        return {};
    }
    return entry->value.substr(0, entry->value.find('\0'));
}

std::optional<uint32_t> SfoInteger(const std::string& sfo, const char* key, uint32_t absent) {
    const std::optional<SfoEntry> entry = FindSfoEntry(sfo, key);
    if (!entry) {
        return absent;
    }
    if (entry->format != 0x0404 || entry->value.size() != 4) {
        return std::nullopt;
    }
    return Le32(reinterpret_cast<const unsigned char*>(entry->value.data()));
}

std::string JsonString(const std::string& text, const std::string& key) {
    const std::string needle = "\"" + key + "\"";
    size_t at = text.find(needle);
    if (at == std::string::npos) {
        return {};
    }
    at = text.find(':', at + needle.size());
    if (at == std::string::npos) {
        return {};
    }
    at = text.find_first_not_of(" \t\r\n", at + 1);
    if (at == std::string::npos || text[at] != '"') {
        return {};
    }
    const size_t end = text.find('"', at + 1);
    return end == std::string::npos ? std::string{} : text.substr(at + 1, end - at - 1);
}

std::string Sha256Hex(const std::filesystem::path& file) {
    std::ifstream in(file, std::ios::binary);
    if (!in) {
        return {};
    }
    crypto::Sha256Stream stream;
    std::vector<char> block(1u << 20);
    bool ok = true;
    while (ok && in.read(block.data(), static_cast<std::streamsize>(block.size())).gcount() > 0) {
        ok = stream.Update(block.data(), static_cast<size_t>(in.gcount()));
    }
    uint8_t digest[32];
    std::string hex;
    if (ok && in.eof() && stream.Finish(digest)) {
        static const char digits[] = "0123456789abcdef";
        for (const uint8_t byte : digest) {
            hex += digits[byte >> 4];
            hex += digits[byte & 15];
        }
    }
    return hex;
}

const char* StateName(GameFileState state) {
    switch (state) {
    case GameFileState::kMissing: return "missing";
    case GameFileState::kValid: return "valid";
    case GameFileState::kDifferentVersion: return "different version";
    case GameFileState::kReadError: return "read error";
    }
    return "unknown";
}

GameCheck CheckGameTree(const std::filesystem::path& app0, const GameFingerprint& expected) {
    std::error_code ec;
    if (!std::filesystem::is_directory(app0, ec)) {
        return Result(GameFileState::kMissing, "game folder not found");
    }
    std::string sfo;
    if (!ReadSmallFile(app0 / "sce_sys" / "param.sfo", sfo)) {
        return Result(std::filesystem::exists(app0 / "sce_sys" / "param.sfo", ec) ? GameFileState::kReadError
                                                                                  : GameFileState::kMissing,
                      "cannot read sce_sys/param.sfo");
    }
    if (GameCheck identity = CheckSfoIdentity(sfo, expected); identity.state != GameFileState::kValid) {
        return identity;
    }

    for (const char* name : kGameFiles) {
        if (!IsRegularNonEmpty(app0 / name)) {
            return Result(GameFileState::kMissing, std::string("missing ") + name);
        }
    }

    const std::string sha = Sha256Hex(app0 / "eboot.bin");
    if (sha.empty()) {
        return Result(GameFileState::kReadError, "cannot read eboot.bin");
    }
    if (sha != expected.eboot_sha256) {
        return Result(GameFileState::kDifferentVersion, "eboot.bin is not the supported build", sha);
    }
    return Result(GameFileState::kValid, {}, sha);
}

GameCheck CheckSfoIdentity(const std::string& sfo, const GameFingerprint& expected) {
    const struct {
        const char* key;
        std::string_view wanted;
    } identity[] = {
        {"TITLE_ID", expected.title_id},
        {"CONTENT_ID", expected.content_id},
        {"APP_VER", expected.app_ver},
        {"VERSION", expected.sfo_version},
    };
    for (const auto& item : identity) {
        const std::string found = SfoString(sfo, item.key);
        if (found != item.wanted) {
            return Result(GameFileState::kDifferentVersion, std::string("param.sfo ") + item.key + " is " +
                                                                (found.empty() ? "missing" : found));
        }
    }
    return Result(GameFileState::kValid, {});
}

GameCheck CheckGameFiles(const GamePaths& paths, const GameFingerprint& expected) {
    std::error_code ec;
    if (!std::filesystem::is_directory(paths.app0, ec)) {
        return Result(GameFileState::kMissing, "game folder not found");
    }

    const std::filesystem::path marker_file = paths.app0 / kPreparedMarker;
    if (!std::filesystem::exists(marker_file, ec)) {
        return Result(GameFileState::kMissing, "game folder has no preparation marker");
    }
    std::string marker;
    if (!ReadSmallFile(marker_file, marker)) {
        return Result(GameFileState::kReadError, "cannot read the preparation marker");
    }
    const std::string version = JsonString(marker, "version");
    const std::string scope = JsonString(marker, "scope");
    if (version.empty() || scope.empty()) {
        return Result(GameFileState::kMissing, "game preparation did not finish");
    }
    if (version != expected.version) {
        return Result(GameFileState::kDifferentVersion, "prepared version " + version);
    }
    if (scope != "full") {
        return Result(GameFileState::kMissing, "only the " + scope + " files were prepared");
    }

    const GameCheck tree = CheckGameTree(paths.app0, expected);
    if (tree.state != GameFileState::kValid) {
        return tree;
    }
    const std::string& sha = tree.eboot_sha256;
    for (const char* name : kImageFiles) {
        if (!IsRegularNonEmpty(paths.image_dir / name)) {
            return Result(GameFileState::kMissing, std::string("boot image: missing ") + name, sha);
        }
    }
    std::string report;
    if (!ReadSmallFile(paths.image_dir / "image.json", report)) {
        return Result(GameFileState::kReadError, "cannot read the boot image report", sha);
    }
    if (JsonString(report, "title_id") != expected.title_id || JsonString(report, "eboot_sha256") != expected.eboot_sha256) {
        return Result(GameFileState::kDifferentVersion, "the boot image was built from another eboot.bin", sha);
    }
    return Result(GameFileState::kValid, {}, sha);
}

} // namespace dcp
