#pragma once
// ArcRift 1.4: the headset's display mode is read from the session's EDID file (its first detailed timing) instead
// of being fixed to the Rift S numbers. The session script writes and checks that file before anything loads it, so
// the bridge, the desktop-size helper and the script all work from the same mode. For the Rift S this gives exactly
// the values that used to be written out in the code: 1440x2560, 80 Hz.
#include <windows.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cwchar>

struct ArcRiftEdidMode {
    unsigned width = 0, height = 0;
    unsigned totalWidth = 0, totalHeight = 0;
    unsigned long long pixelClock = 0; // Hz
    double hz = 0;                     // exact, e.g. 79.99972
    int nominalHz = 0;                 // rounded, e.g. 80
    bool valid = false;
};

// e: the 128-byte base EDID block.
inline ArcRiftEdidMode ArcRiftParseEdidMode(const unsigned char* e) {
    ArcRiftEdidMode m;
    if (!e) return m;
    const unsigned char* d = e + 54; // first detailed timing descriptor
    m.pixelClock = (d[0] + 256ull * d[1]) * 10000ull;
    m.width = d[2] + ((d[4] & 0xF0u) << 4);
    m.height = d[5] + ((d[7] & 0xF0u) << 4);
    m.totalWidth = m.width + d[3] + ((d[4] & 0x0Fu) << 8);
    m.totalHeight = m.height + d[6] + ((d[7] & 0x0Fu) << 8);
    if (!m.pixelClock || !m.width || !m.height) return m;
    m.hz = double(m.pixelClock) / (double(m.totalWidth) * double(m.totalHeight));
    m.nominalHz = int(std::lround(m.hz));
    m.valid = m.nominalHz >= 30 && m.nominalHz <= 240;
    return m;
}

// Reads the session's EDID file from the folder of "module" (nullptr = this program) into a 256-byte buffer:
// supports 128-byte base EDIDs (Rift S; trailing 128 bytes zeroed) and 256-byte EDIDs with one CTA-861 extension
// block (Rift CV1 / HDMI VSDB). Fails unless base block (and extension block, if present) checksum cleanly and match OVR.
inline bool ArcRiftReadEdidFile(const wchar_t* path, char* output256, size_t* outSize = nullptr) {
    if (!path || !output256) return false;
    FILE* file = nullptr;
    if (_wfopen_s(&file, path, L"rb") != 0 || !file) return false;
    memset(output256, 0, 256);
    size_t count = fread(output256, 1, 256, file);
    int extra = fgetc(file);
    fclose(file);
    if (extra != EOF || (count != 128 && count != 256)) return false;
    unsigned sum = 0;
    for (size_t i = 0; i < 128; ++i) sum += static_cast<unsigned char>(output256[i]);
    if (sum % 256 != 0 || static_cast<unsigned char>(output256[8]) != 0x3e || static_cast<unsigned char>(output256[9]) != 0xd2) return false;
    if (count == 256) {
        unsigned extSum = 0;
        for (size_t i = 128; i < 256; ++i) extSum += static_cast<unsigned char>(output256[i]);
        if (extSum % 256 != 0 || static_cast<unsigned char>(output256[126]) < 1) return false;
    }
    if (outSize) *outSize = count;
    return true;
}

inline bool ArcRiftReadSessionEdid(HMODULE module, char* output256, size_t* outSize = nullptr) {
    wchar_t path[MAX_PATH]{};
    DWORD n = GetModuleFileNameW(module, path, MAX_PATH);
    if (!n || n >= MAX_PATH) return false;
    wchar_t* last = wcsrchr(path, L'\\');
    if (!last || wcscpy_s(last + 1, MAX_PATH - (last + 1 - path), L"rift-s-native-test.edid")) return false;
    return ArcRiftReadEdidFile(path, output256, outSize);
}

inline ArcRiftEdidMode ArcRiftLoadSessionMode(HMODULE module) {
    char edid[256];
    if (!ArcRiftReadSessionEdid(module, edid)) return ArcRiftEdidMode{};
    return ArcRiftParseEdidMode(reinterpret_cast<const unsigned char*>(edid));
}
