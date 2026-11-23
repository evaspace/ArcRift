// Experimental user-mode backend. No GPU driver patches or firmware writes.
// Reverse-engineered interface definitions: BnuuySolutions/OculusDirectDisplayAdditions (MIT).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi1_3.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <algorithm>
#include <mutex>
#include <vector>
#include <string>
#include <cstdarg>
#include <share.h>
#pragma comment(lib, "advapi32.lib") // registry reads for the opt-in Dash Vulkan trace
#include "ovr_direct_display.h"
#include "texture_summary.h"
#include "arcrift_identity.h"
#include "edid_mode.h"
using Microsoft::WRL::ComPtr;
static HMODULE self;
// Release 1.1: headset/GPU identity comes from arcrift-identity.txt next to this DLL.
static const ArcRiftIdentity& Identity() { static const ArcRiftIdentity id = ArcRiftLoadIdentity(self); return id; }
// Release 1.4: the headset's mode (size, refresh rate) comes from the session's EDID file, not fixed Rift S numbers.
static const ArcRiftEdidMode& Mode() { static const ArcRiftEdidMode mode = ArcRiftLoadSessionMode(self); return mode; }

static void Trace(const char* format, ...) {
    static std::mutex traceLock;
    wchar_t path[MAX_PATH]{};
    GetModuleFileNameW(self, path, MAX_PATH);
    wchar_t* last = wcsrchr(path, L'\\');
    if (!last) return;
    wcscpy_s(last + 1, MAX_PATH - (last + 1 - path), L"arc-rift-bridge.log");
    std::lock_guard<std::mutex> guard(traceLock);
    // Shared open (_SH_DENYNO) prevents dropped lines when the session script polls the log or multiple threads log.
    FILE* file = _wfsopen(path, L"a", _SH_DENYNO);
    if (!file) return;
    fprintf(file, "%llu ", GetTickCount64());
    va_list args;
    va_start(args, format);
    vfprintf(file, format, args);
    va_end(args);
    fputc('\n', file);
    fclose(file);
}

// Reads the first pointer field from Meta's Present descriptor without a per-frame ReadProcessMemory kernel syscall.
static bool ReadFirstPointerSafe(const void* value, void** out) {
    if (!value || !out) return false;
    __try {
        *out = *reinterpret_cast<void* const*>(value);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        *out = nullptr;
        return false;
    }
}

struct PhysicalOutput {
    LUID luid{};
    wchar_t sourceName[32]{};
    RECT rect{};
    DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY technology = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_OTHER; // how Windows says it is connected
};

// Release 1.2: when the headset display cannot be matched, say why (in "why", if given), so a failed session's
// bridge log shows the cause. The checks themselves are unchanged.
static bool LookupFailed(char* why, size_t whySize, const char* format, ...) {
    if (why && whySize) {
        va_list args;
        va_start(args, format);
        vsnprintf(why, whySize, format, args);
        va_end(args);
    }
    return false;
}

static bool GetPhysicalOutput(PhysicalOutput& out, char* why = nullptr, size_t whySize = 0) {
    UINT count = 0, modes = 0;
    if (LONG err = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &count, &modes)) return LookupFailed(why, whySize, "GetDisplayConfigBufferSizes error %ld", err);
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(count);
    std::vector<DISPLAYCONFIG_MODE_INFO> modeData(modes);
    if (LONG err = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &count, paths.data(), &modes, modeData.data(), nullptr)) return LookupFailed(why, whySize, "QueryDisplayConfig error %ld", err);
    if (!Identity().valid) return LookupFailed(why, whySize, "identity file missing or invalid");
    char seen[256] = "";
    char lastMismatch[300] = "";
    for (UINT i = 0; i < count; ++i) {
        size_t used = strlen(seen);
        if (used + 16 < sizeof(seen)) snprintf(seen + used, sizeof(seen) - used, "%s%u", used ? "," : "", paths[i].targetInfo.id);
        if (paths[i].targetInfo.id != Identity().target) continue;
        DISPLAYCONFIG_TARGET_DEVICE_NAME target{};
        target.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(target), paths[i].targetInfo.adapterId, paths[i].targetInfo.id};
        if (LONG err = DisplayConfigGetDeviceInfo(&target.header)) { snprintf(lastMismatch, sizeof(lastMismatch), "target name query error %ld", err); continue; }
        // Release 1.1: exact headset device path from the identity file (stricter than the old prefix check).
        if (!Identity().MonitorMatches(target.monitorDevicePath)) { snprintf(lastMismatch, sizeof(lastMismatch), "monitor path %ls does not match Setup", target.monitorDevicePath); continue; }
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
        source.header = {DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(source), paths[i].sourceInfo.adapterId, paths[i].sourceInfo.id};
        if (LONG err = DisplayConfigGetDeviceInfo(&source.header)) { snprintf(lastMismatch, sizeof(lastMismatch), "source name query error %ld", err); continue; }
        DEVMODEW mode{};
        mode.dmSize = sizeof(mode);
        if (!EnumDisplaySettingsW(source.viewGdiDeviceName, ENUM_CURRENT_SETTINGS, &mode)) { snprintf(lastMismatch, sizeof(lastMismatch), "no current mode for %ls", source.viewGdiDeviceName); continue; }
        out.luid = paths[i].targetInfo.adapterId;
        out.technology = paths[i].targetInfo.outputTechnology;
        wcscpy_s(out.sourceName, source.viewGdiDeviceName);
        out.rect = {mode.dmPosition.x, mode.dmPosition.y, mode.dmPosition.x + LONG(mode.dmPelsWidth), mode.dmPosition.y + LONG(mode.dmPelsHeight)};
        return true;
    }
    if (lastMismatch[0]) return LookupFailed(why, whySize, "headset target %u is active but %s", Identity().target, lastMismatch);
    return LookupFailed(why, whySize, "headset target %u is not an active Windows display (active targets: %s)", Identity().target, seen[0] ? seen : "none");
}

// Logs a failed headset-display lookup once per distinct reason, so a caller that polls cannot flood the log.
static void TraceLookupFailure(const char* where, const char* why) {
    static std::mutex lock;
    static char last[512] = "";
    char line[512];
    snprintf(line, sizeof(line), "%s: headset display not found: %s", where, why[0] ? why : "unknown reason");
    std::lock_guard<std::mutex> guard(lock);
    if (strcmp(line, last) == 0) return;
    strcpy_s(last, line);
    Trace("%s", line);
}




static bool ReadTestEdid(char* output) { return ArcRiftReadSessionEdid(self, output); }

class Surface final : public OVR::IDirectDisplaySurface {
    OVR_REF_COUNTED_IMPLEMENTATION
public:
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11Texture2D> consumerTexture; // Used only by isolated candidate build.
    HANDLE shared = nullptr;
    bool handleLogged = false;
    void* QueryInterface(uint64_t id) override {
        Trace("Surface %p QueryInterface %llx", this, id);
        if (id == OVR::IID_IDirectDisplaySurface || id == 1 || id == 2) return static_cast<OVR::IDirectDisplaySurface*>(this);
        return nullptr;
    }
    HANDLE GetSurfaceHandle() override {
        if (!handleLogged) { Trace("Surface %p GetSurfaceHandle=%p", this, shared); handleLogged = true; }
        return shared;
    }
};

class Display final : public OVR::IDirectDisplay {
    OVR_REF_COUNTED_IMPLEMENTATION
    std::mutex mutex;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain1> chain;
    HANDLE frameWaitable = nullptr;
    HWND window = nullptr;
    UINT width = 0, height = 0;
    unsigned frames = 0;
    std::vector<Surface*> ownedSurfaces;
    bool unknownPresentLogged = false;
    bool exclusive = false; // between AcquireExclusive and ReleaseExclusive

    void SampleOutput(ID3D11Texture2D* source) {
        TextureSummary s;
        HRESULT hr = SummarizeTexture(device.Get(), context.Get(), source, s);
        Trace("Output surface frame=%u readback=%08lx size=%ux%u pixels=%llu nonblack=%llu green=%llu maxRGBA=%u,%u,%u,%u",
            frames, hr, s.width, s.height, s.pixels, s.nonblack, s.greenDominant,
            s.maxRGB[0], s.maxRGB[1], s.maxRGB[2], s.maxAlpha);
    }

    static LRESULT CALLBACK Proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
        return DefWindowProcW(hwnd, msg, wp, lp);
    }

    HRESULT InitializeRenderer(UINT w, UINT h) {
        if (chain) return width == w && height == h ? S_OK : E_INVALIDARG;
        PhysicalOutput output;
        if (!GetPhysicalOutput(output)) return DXGI_ERROR_NOT_FOUND;
        ComPtr<IDXGIFactory1> factory;
        HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
        if (FAILED(hr)) return hr;
        ComPtr<IDXGIAdapter1> adapter;
        for (UINT i = 0;; ++i) {
            ComPtr<IDXGIAdapter1> candidate;
            if (factory->EnumAdapters1(i, &candidate) == DXGI_ERROR_NOT_FOUND) break;
            if (!candidate) break;
            DXGI_ADAPTER_DESC1 desc{};
            candidate->GetDesc1(&desc);
            if (memcmp(&desc.AdapterLuid, &output.luid, sizeof(LUID)) == 0 && Identity().GpuAllowed(desc.VendorId, desc.DeviceId)) { adapter = candidate; break; }
        }
        if (!adapter) return DXGI_ERROR_NOT_FOUND;
        if (!device) {
            hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context);
            if (FAILED(hr)) return hr;
        } else {
            ComPtr<IDXGIDevice> dxgiDevice;
            ComPtr<IDXGIAdapter> actualAdapter;
            DXGI_ADAPTER_DESC actualDesc{};
            hr = device.As(&dxgiDevice);
            if (SUCCEEDED(hr)) hr = dxgiDevice->GetAdapter(&actualAdapter);
            if (SUCCEEDED(hr)) hr = actualAdapter->GetDesc(&actualDesc);
            if (FAILED(hr) || memcmp(&actualDesc.AdapterLuid, &output.luid, sizeof(LUID)) != 0) return DXGI_ERROR_INVALID_CALL;
        }
        WNDCLASSW wc{};
        wc.hInstance = self;
        wc.lpszClassName = L"ArcRiftExperimentalBridge";
        wc.lpfnWndProc = Proc;
        RegisterClassW(&wc);
        // Ensure exact 1:1 physical pixel placement regardless of Windows DPI scaling on mixed-DPI setups.
        using SetThreadDpiFn = DPI_AWARENESS_CONTEXT(WINAPI*)(DPI_AWARENESS_CONTEXT);
        auto setDpi = reinterpret_cast<SetThreadDpiFn>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetThreadDpiAwarenessContext"));
        DPI_AWARENESS_CONTEXT prevDpi = setDpi ? setDpi(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) : nullptr;
        const LONG rectW = output.rect.right - output.rect.left;
        const LONG rectH = output.rect.bottom - output.rect.top;
        window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT,
            wc.lpszClassName, L"ArcRift headset display backend",
            WS_POPUP, output.rect.left, output.rect.top, rectW, rectH, nullptr, nullptr, self, nullptr);
        const DWORD winErr = window ? ERROR_SUCCESS : GetLastError();
        if (setDpi && prevDpi) setDpi(prevDpi);
        if (!window) return HRESULT_FROM_WIN32(winErr);
        ComPtr<IDXGIFactory2> factory2;
        hr = factory.As(&factory2);
        if (FAILED(hr)) return hr;
        DXGI_SWAP_CHAIN_DESC1 desc{};
        desc.Width = w;
        desc.Height = h;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        // FLIP_DISCARD + SCALING_NONE (on 1:1 native surface) + waitable latency=1 enables DWM Independent Flip and cuts queued latency.
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        desc.Scaling = (rectW == LONG(w) && rectH == LONG(h)) ? DXGI_SCALING_NONE : DXGI_SCALING_STRETCH;
        desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        desc.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
        hr = factory2->CreateSwapChainForHwnd(device.Get(), window, &desc, nullptr, nullptr, &chain);
        if (FAILED(hr)) {
            desc.Flags = 0;
            desc.Scaling = DXGI_SCALING_STRETCH;
            hr = factory2->CreateSwapChainForHwnd(device.Get(), window, &desc, nullptr, nullptr, &chain);
        }
        if (FAILED(hr)) return hr;
        if (desc.Flags & DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT) {
            ComPtr<IDXGISwapChain2> chain2;
            if (SUCCEEDED(chain.As(&chain2))) {
                chain2->SetMaximumFrameLatency(1);
                frameWaitable = chain2->GetFrameLatencyWaitableObject();
            }
        }
        factory->MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER);
        width = w;
        height = h;
        ShowWindow(window, SW_SHOWNOACTIVATE);
        DWORD sessionId = 0;
        ProcessIdToSessionId(GetCurrentProcessId(), &sessionId);
        wchar_t desktop[128]{};
        DWORD needed = 0;
        GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME, desktop, sizeof(desktop), &needed);
        ComPtr<IDXGIOutput> containing;
        DXGI_OUTPUT_DESC actual{};
        hr = chain->GetContainingOutput(&containing);
        if (SUCCEEDED(hr)) containing->GetDesc(&actual);
        Trace("Window session=%lu desktop=%ls visible=%d intended=%ls containing=%ls rect=%ld,%ld,%ld,%ld outputHR=%08lx",
            sessionId, desktop, IsWindowVisible(window), output.sourceName, actual.DeviceName,
            output.rect.left, output.rect.top, output.rect.right, output.rect.bottom, hr);
        Trace("Renderer initialized %ux%u, verified physical target %u", w, h, Identity().target);
        return S_OK;
    }
public:
    ~Display() override {
        if (frameWaitable) CloseHandle(frameWaitable);
        for (auto surface : ownedSurfaces) surface->Release();
        if (window) DestroyWindow(window);
    }
    void* QueryInterface(uint64_t id) override {
        Trace("Display QueryInterface %llx", id);
        if (id == OVR::IID_IDirectDisplay || id == 1 || id == 2) return static_cast<OVR::IDirectDisplay*>(this);
        return nullptr;
    }
    ovrResult GetProperties(ovrDisplayProperties* props) override {
        Trace("GetProperties");
        if (!props) return ovrError_InvalidParameter;
        memset(props, 0, sizeof(*props));
        // The output is physically verified; never substitute another monitor.
        PhysicalOutput output;
        char why[400] = "";
        if (!GetPhysicalOutput(output, why, sizeof(why))) { TraceLookupFailure("GetProperties", why); return ovrError_Unsupported; }
        memcpy(props->Luid.Reserved, &output.luid, sizeof(output.luid));
        // Release 1.4: report HDMI or DVI when Windows says so (Rift CV1 uses HDMI); everything else stays DisplayPort,
        // which is what the Rift S has always been reported as.
        props->OutputType = output.technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI ? ovrDisplayOutput_HDMI :
            output.technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DVI ? ovrDisplayOutput_DVI : ovrDisplayOutput_DP;
        props->DongleType = ovrDisplayDongle_None;
        props->UniqueId = Identity().target;
        return ReadTestEdid(props->EdidData) ? ovrSuccess : ovrError_Unsupported;
    }
    // Release 1.2.1: Meta builds a new compositor (with a new D3D11 device) when an app such as Dash connects. It
    // releases the display first, then acquires it again. Drop everything tied to the old device so nothing from two
    // devices is ever mixed, then rebuild on the new one. Our references only: Meta keeps its own on old surfaces.
    void ResetRenderer() {
        if (frameWaitable) { CloseHandle(frameWaitable); frameWaitable = nullptr; }
        chain.Reset();
        if (window && IsWindow(window)) {
            DWORD owner = GetWindowThreadProcessId(window, nullptr);
            if (owner == GetCurrentThreadId()) DestroyWindow(window);
            else { ShowWindowAsync(window, SW_HIDE); PostMessageW(window, WM_CLOSE, 0, 0); } // closed by its own thread
        }
        window = nullptr;
        for (auto surface : ownedSurfaces) surface->Release();
        ownedSurfaces.clear();
        context.Reset();
        device.Reset();
        width = height = 0;
        frames = 0;
        unknownPresentLogged = false;
    }
    ovrResult AcquireExclusive(::IUnknown* supplied) override {
        std::lock_guard<std::mutex> guard(mutex);
        if (!supplied) return ovrError_InvalidParameter;
        ComPtr<ID3D11Device> suppliedDevice;
        HRESULT hr = supplied->QueryInterface(IID_PPV_ARGS(&suppliedDevice));
        Trace("AcquireExclusive supplied D3D11 device QI=%08lx: composited, not hardware direct mode", hr);
        if (FAILED(hr)) return ovrError_Unsupported;
        if (device && suppliedDevice.Get() != device.Get()) {
            if (exclusive) {
                // Never switch devices while the current owner still holds the display.
                Trace("AcquireExclusive device changed while renderer active; refusing stale device reuse");
                return ovrError_Unsupported;
            }
            Trace("AcquireExclusive new device after release: rebuilding renderer for the new compositor");
            ResetRenderer();
        }
        device = suppliedDevice;
        device->GetImmediateContext(&context);
        exclusive = true;
        return ovrSuccess;
    }
    ovrResult ReleaseExclusive() override {
        std::lock_guard<std::mutex> guard(mutex);
        exclusive = false;
        Trace("ReleaseExclusive");
        return ovrSuccess;
    }
    ovrResult CreateSurface(ovrModeDesc* mode, OVR::IDirectDisplaySurface** out) override {
        if (!mode || !out) return ovrError_InvalidParameter;
        *out = nullptr;
        Trace("CreateSurface %dx%d rate=%d/%d format=%d", mode->Resolution.w, mode->Resolution.h,
            mode->RefreshRate.Numerator, mode->RefreshRate.Denominator, mode->Format);
        // Release 1.4: the only accepted mode is the one in the session's EDID, within 1 Hz (Rift S: 1440x2560, 79-81 Hz).
        const ArcRiftEdidMode& native = Mode();
        if (!native.valid) { Trace("CreateSurface: session EDID missing or invalid; refusing"); return ovrError_Unsupported; }
        if (mode->Resolution.w != int(native.width) || mode->Resolution.h != int(native.height) || mode->RefreshRate.Denominator <= 0 ||
            mode->RefreshRate.Numerator < (native.nominalHz - 1) * mode->RefreshRate.Denominator || mode->RefreshRate.Numerator > (native.nominalHz + 1) * mode->RefreshRate.Denominator ||
            (mode->Format != OVR_FORMAT_R8G8B8A8_UNORM && mode->Format != OVR_FORMAT_R8G8B8A8_UNORM_SRGB)) return ovrError_Unsupported;
        std::lock_guard<std::mutex> guard(mutex);
        HRESULT hr = InitializeRenderer(native.width, native.height);
        if (FAILED(hr)) { Trace("Renderer failed %08lx", hr); return ovrError_Unsupported; }
        auto surface = new Surface;
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = width;
        desc.Height = height;
        desc.MipLevels = desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE;
        desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
        hr = device->CreateTexture2D(&desc, nullptr, &surface->texture);
        ComPtr<IDXGIResource> resource;
        if (SUCCEEDED(hr)) hr = surface->texture.As(&resource);
        if (SUCCEEDED(hr)) hr = resource->GetSharedHandle(&surface->shared);
        if (FAILED(hr)) { Trace("Surface failed %08lx", hr); surface->Release(); return ovrError_Unsupported; }
        *out = surface;
        surface->AddRef();
        ownedSurfaces.push_back(surface);
        Trace("Created surface=%p shared=%p", surface, surface->shared);
        return ovrSuccess;
    }
    ovrResult Present(void* value, void* auxiliary) override {
        if (!value) return ovrError_InvalidParameter;
        std::lock_guard<std::mutex> guard(mutex);
        if (!chain) return ovrError_Unsupported;
        Surface* surface = nullptr;
        for (auto known : ownedSurfaces) if (value == known) { surface = known; break; }
        if (!surface) {
            void* firstPointer = nullptr;
            if (ReadFirstPointerSafe(value, &firstPointer)) {
                for (auto known : ownedSurfaces) if (firstPointer == known) { surface = known; break; }
            }
            if (frames == 0 || (!surface && !unknownPresentLogged))
                Trace("Present descriptor=%p firstPointer=%p verifiedSurface=%p auxiliary=%p", value, firstPointer, surface, auxiliary);
            if (!surface) { unknownPresentLogged = true; return ovrError_Unsupported; }
        }
        if (frames == 0) Trace("First presented verified surface=%p shared=%p", surface, surface->shared);
        if (frameWaitable) WaitForSingleObject(frameWaitable, 50);
        ComPtr<ID3D11Texture2D> back;
        HRESULT hr = chain->GetBuffer(0, IID_PPV_ARGS(&back));
        if (FAILED(hr)) return ovrError_Unsupported;
        context->CopyResource(back.Get(), surface->texture.Get());
        // Release 1.1.2: one full readback at frame 30 proves output; after that only a cheap progress line every
        // 120 frames (the session uses it for its fps/freeze checks). A recurring readback stalled this thread for a frame.
        if (frames == 30) SampleOutput(back.Get());
        else if (frames != 0 && frames % 120 == 0) Trace("Output surface frame=%u readback=skipped", frames);
        hr = chain->Present(1, 0);
        if (frames++ == 0 || FAILED(hr)) Trace("Present frame=%u result=%08lx", frames, hr);
        MSG message{};
        while (PeekMessageW(&message, window, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
        return SUCCEEDED(hr) ? ovrSuccess : ovrError_Unsupported;
    }
    ovrResult GetPresentStateTimeout(int) override { return ovrSuccess; }
    ovrResult GetPresentStats(ovrPresentStats* stats) override {
        if (!stats) return ovrError_InvalidParameter;
        memset(stats, 0, sizeof(*stats));
        stats->RefreshRate = {Mode().valid ? int(std::llround(Mode().hz * 1000.0)) : 80000, 1000};
        return ovrSuccess;
    }
    ovrResult GetPresentState(ovrBool* state) override { if (!state) return ovrError_InvalidParameter; *state = ovrFalse; return ovrSuccess; }
    ovrResult GetHdcpState(ovrBool* state) override {
        // Do not falsely claim encryption on this composited display path.
        if (!state) return ovrError_InvalidParameter;
        *state = ovrFalse;
        return ovrSuccess;
    }
};


class Provider final : public OVR::IDirectDisplayAPI {
    OVR_REF_COUNTED_IMPLEMENTATION
    Display* display = new Display;
public:
    ~Provider() override { display->Release(); }
    void* QueryInterface(uint64_t id) override {
        if (id == OVR::IID_IDirectDisplayAPI || id == 1 || id == 2) return static_cast<OVR::IDirectDisplayAPI*>(this);
        return nullptr;
    }
    ovrResult EnableDirectDisplay(ovrBool enable) override { Trace("EnableDirectDisplay %d: no OS mode changes", enable); return ovrSuccess; }
    ovrResult Enumerate(uint32_t index, OVR::IDirectDisplay** out) override {
        if (!out) return ovrError_InvalidParameter;
        *out = nullptr;
        if (index != 0) return ovrError_Unsupported;
        if (!Identity().valid) { Trace("Identity file arcrift-identity.txt missing or invalid; refusing to enumerate"); return ovrError_Unsupported; }
        PhysicalOutput output;
        char why[400] = "";
        // Release 1.4 note: do not wait here for a late headset display. Meta powers the headset display on only after this
        // call returns (session of 2026-11-13 20:14: an 8 s wait here delayed the power-on by 8 s and still failed).
        if (!GetPhysicalOutput(output, why, sizeof(why))) { TraceLookupFailure("Enumerate", why); return ovrError_Unsupported; }
        display->AddRef();
        *out = display;
        Trace("Enumerate verified target %u", Identity().target);
        return ovrSuccess;
    }
    ovrResult GetName(char* name) override {
        if (!name) return ovrError_InvalidParameter;
        strcpy_s(name, 128, "ArcRiftLab (experimental composited)");
        return ovrSuccess;
    }
};

// Experiment (opt-in): Meta's OVRServer decides from a hard-coded list (IsGPUDashVulkanCapable) which GPUs can run
// Dash on Vulkan: some AMD and NVIDIA device IDs only, Intel always "incapable". When dash-vulkan-flip.txt exists next
// to this DLL, patch that one decision in OVRServer's memory so it answers "capable". Nothing on disk is changed, and it
// is applied only when OVRServer's bytes match the build this was read from, so a Meta update turns it off by itself.
static void ApplyDashVulkanFlip() {
    wchar_t flag[MAX_PATH]{};
    GetModuleFileNameW(self, flag, MAX_PATH);
    wchar_t* last = wcsrchr(flag, L'\\');
    if (!last) return;
    wcscpy_s(last + 1, MAX_PATH - (last + 1 - flag), L"dash-vulkan-flip.txt");
    if (GetFileAttributesW(flag) == INVALID_FILE_ATTRIBUTES) return;

    wchar_t host[MAX_PATH]{};
    GetModuleFileNameW(nullptr, host, MAX_PATH);
    const wchar_t* hostName = wcsrchr(host, L'\\');
    hostName = hostName ? hostName + 1 : host;
    if (_wcsicmp(hostName, L"OVRServer_x64.exe") != 0) { Trace("DashVulkanFlip: requested, but host is %ls; not patched", hostName); return; }

    // Meta Horizon runtime 208.0.0.84.535: IsGPUDashVulkanCapable starts at RVA 0x166ee0. At RVA 0x166f1f it clears
    // its answer (xor r13b,r13b) and sets it again only for listed AMD (0x1002) / NVIDIA (0x10de) device IDs; the
    // function returns r13b. Replacing the clear with "mov r13b,1" makes it answer "capable" for any GPU.
    static const unsigned char expected[] = {
        0xC7, 0x44, 0x24, 0x48, 0x00, 0x00, 0x00, 0x00, // mov dword [rsp+48h],0
        0x45, 0x32, 0xED,                               // xor r13b,r13b   <- patched
        0x81, 0xF9, 0x02, 0x10, 0x00, 0x00,             // cmp ecx,1002h
        0x74, 0x35,                                     // je
        0x81, 0xF9, 0xDE, 0x10, 0x00, 0x00,             // cmp ecx,10DEh
        0x75, 0x69};                                    // jne
    static const unsigned char patch[] = {0x41, 0xB5, 0x01}; // mov r13b,1
    const size_t signatureRva = 0x166f17, patchOffset = 8;

    auto base = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
    if (!base) return;
    auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) { Trace("DashVulkanFlip: unexpected DOS header; not patched"); return; }
    auto nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) { Trace("DashVulkanFlip: unexpected NT header; not patched"); return; }

    unsigned char* site = nullptr;
    size_t matchedRva = 0;
    if (signatureRva + sizeof(expected) <= nt->OptionalHeader.SizeOfImage) {
        unsigned char* fast = base + signatureRva;
        if (memcmp(fast, expected, patchOffset) == 0 && memcmp(fast + patchOffset, patch, sizeof(patch)) == 0) {
            Trace("DashVulkanFlip: already patched at RVA 0x%zx", signatureRva + patchOffset);
            return;
        }
        if (memcmp(fast, expected, sizeof(expected)) == 0) {
            site = fast;
            matchedRva = signatureRva;
        }
    }
    // Fallback if a Meta runtime update shifted the RVA: scan executable sections for the exact 27-byte signature,
    // and only patch if it occurs uniquely in the entire image.
    if (!site) {
        const IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
        size_t matches = 0;
        for (WORD s = 0; s < nt->FileHeader.NumberOfSections; ++s) {
            if (!(sec[s].Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
            const size_t secStart = sec[s].VirtualAddress;
            const size_t secSize = (std::min)(size_t(sec[s].Misc.VirtualSize), size_t(nt->OptionalHeader.SizeOfImage - secStart));
            if (secStart >= nt->OptionalHeader.SizeOfImage || secSize < sizeof(expected)) continue;
            const unsigned char* p = base + secStart;
            for (size_t off = 0; off + sizeof(expected) <= secSize; ++off) {
                if (memcmp(p + off, expected, patchOffset) == 0 &&
                    memcmp(p + off + patchOffset, patch, sizeof(patch)) == 0 &&
                    memcmp(p + off + patchOffset + sizeof(patch), expected + patchOffset + sizeof(patch), sizeof(expected) - patchOffset - sizeof(patch)) == 0) {
                    Trace("DashVulkanFlip: already patched at RVA 0x%zx", secStart + off + patchOffset);
                    return;
                }
                if (memcmp(p + off, expected, sizeof(expected)) == 0) {
                    site = base + secStart + off;
                    matchedRva = secStart + off;
                    ++matches;
                }
            }
        }
        if (matches != 1) {
            Trace("DashVulkanFlip: OVRServer signature matched %zu times (Meta changed code?); not patched", matches);
            return;
        }
    }
    DWORD oldProtect = 0;
    if (!VirtualProtect(site + patchOffset, sizeof(patch), PAGE_EXECUTE_READWRITE, &oldProtect)) {
        Trace("DashVulkanFlip: VirtualProtect failed %lu; not patched", GetLastError());
        return;
    }
    memcpy(site + patchOffset, patch, sizeof(patch));
    VirtualProtect(site + patchOffset, sizeof(patch), oldProtect, &oldProtect);
    FlushInstructionCache(GetCurrentProcess(), site + patchOffset, sizeof(patch));
    Trace("DashVulkanFlip: patched IsGPUDashVulkanCapable in OVRServer memory (RVA 0x%zx xor r13b,r13b -> mov r13b,1)", matchedRva + patchOffset);
}

// Experiment (opt-in): Vulkan trace for Meta's Dash. Dash quits with "Failed to configure Rendering Code: -4" inside
// its own Vulkan setup and logs nothing about why. When dash-vulkan-trace.txt exists next to this DLL, OVRServer's own
// environment gets the Vulkan SDK's API-dump and validation layers switched on. Dash is launched by OVRServer and
// inherits that environment, so only Meta's processes are traced: no system-wide variables. Needs the Vulkan SDK.
// Every Dash launch gets its own log files under vulkan-trace\ (a fixed name would be overwritten by the next launch).
static std::wstring BesideBridge(const wchar_t* name) {
    wchar_t path[MAX_PATH]{};
    GetModuleFileNameW(self, path, MAX_PATH);
    wchar_t* last = wcsrchr(path, L'\\');
    if (!last) return L"";
    last[1] = 0;
    return std::wstring(path) + name;
}

static bool FileExists(const std::wstring& path) { return !path.empty() && GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES; }

static std::wstring FindVulkanLayer(const wchar_t* jsonName) {
    // 1. Explicit layers registered with the Vulkan loader.
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Khronos\\Vulkan\\ExplicitLayers", 0, KEY_READ, &key) == ERROR_SUCCESS) {
        for (DWORD i = 0;; ++i) {
            wchar_t name[1024]{};
            DWORD length = 1024;
            LONG r = RegEnumValueW(key, i, name, &length, nullptr, nullptr, nullptr, nullptr);
            if (r == ERROR_NO_MORE_ITEMS) break;
            if (r != ERROR_SUCCESS) continue;
            const wchar_t* base = wcsrchr(name, L'\\');
            if (base && _wcsicmp(base + 1, jsonName) == 0 && FileExists(name)) { RegCloseKey(key); return name; }
        }
        RegCloseKey(key);
    }
    // 2. <VULKAN_SDK>\Bin. The SDK installer sets VULKAN_SDK; this process may have started before that, so also read
    //    it from the machine and user environment in the registry.
    wchar_t sdk[MAX_PATH]{};
    DWORD size = sizeof(sdk);
    DWORD n = GetEnvironmentVariableW(L"VULKAN_SDK", sdk, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        sdk[0] = 0;
        if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment", L"VULKAN_SDK",
                RRF_RT_REG_SZ, nullptr, sdk, &size) != ERROR_SUCCESS) {
            size = sizeof(sdk);
            if (RegGetValueW(HKEY_CURRENT_USER, L"Environment", L"VULKAN_SDK", RRF_RT_REG_SZ, nullptr, sdk, &size) != ERROR_SUCCESS) sdk[0] = 0;
        }
    }
    if (sdk[0]) {
        std::wstring path = std::wstring(sdk) + L"\\Bin\\" + jsonName;
        if (FileExists(path)) return path;
    }
    return L"";
}

static std::wstring traceDirectory;

static DWORD WINAPI RotateVulkanTraceNames(LPVOID) {
    // Runs for the life of OVRServer (the module is pinned). Each process OVRServer starts copies the names current
    // at that moment, so launches more than 250 ms apart write separate files.
    for (;;) {
        SYSTEMTIME t{};
        GetLocalTime(&t);
        wchar_t stamp[32]{};
        swprintf_s(stamp, L"%02u%02u%02u-%03u", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
        std::wstring validation = traceDirectory + L"\\" + stamp + L"-validation.txt";
        std::wstring apiDump = traceDirectory + L"\\" + stamp + L"-apidump.txt";
        SetEnvironmentVariableW(L"VK_KHRONOS_VALIDATION_LOG_FILENAME", validation.c_str());
        SetEnvironmentVariableW(L"VK_LUNARG_API_DUMP_LOG_FILENAME", apiDump.c_str());
        SetEnvironmentVariableW(L"VK_APIDUMP_LOG_FILENAME", apiDump.c_str());
        Sleep(250);
    }
}

// Experiment (opt-in): Dash semaphore fix. Meta's library inside Dash exports a GPU semaphore as an old KMT handle
// whenever the device lists VK_KHR_external_semaphore_win32; the Arc driver lists it but can only export NT handles
// (tools\vk_layer_test confirms: KMT exportable=0, NT exportable=1), and Dash quits with -4. Without the extension
// listed, the library uses its own fallback ("[Non-fatal] ... using fallback notification synchronization").
// When dash-vulkan-semaphore-fix.txt exists, processes OVRServer starts load vk-layer\arcrift_vk_layer.dll, which hides
// that one extension once the process has created its Vulkan device (source\arcrift_vk_layer.cpp).
static void ApplyDashVulkanLayers() {
    const bool fix = FileExists(BesideBridge(L"dash-vulkan-semaphore-fix.txt"));
    const bool trace = FileExists(BesideBridge(L"dash-vulkan-trace.txt"));
    if (!fix && !trace) return;
    wchar_t host[MAX_PATH]{};
    GetModuleFileNameW(nullptr, host, MAX_PATH);
    const wchar_t* hostName = wcsrchr(host, L'\\');
    hostName = hostName ? hostName + 1 : host;
    if (_wcsicmp(hostName, L"OVRServer_x64.exe") != 0) { Trace("DashVulkanLayers: requested, but host is %ls; not enabled", hostName); return; }

    std::wstring fixLayer, validation, apiDump;
    if (fix) {
        fixLayer = BesideBridge(L"vk-layer\\arcrift_vk_layer.json");
        if (!FileExists(fixLayer) || !FileExists(BesideBridge(L"vk-layer\\arcrift_vk_layer.dll"))) {
            Trace("DashVulkanFix: vk-layer\\arcrift_vk_layer.json or .dll missing; fix not enabled");
            fixLayer.clear();
        }
    }
    if (trace) {
        validation = FindVulkanLayer(L"VkLayer_khronos_validation.json");
        // The API dump logs every call of every frame: 6.4 GB for a 5-minute Dash run (22 Nov 15:47). Only with its own
        // opt-in file, dash-vulkan-apidump.txt, next to dash-vulkan-trace.txt.
        if (FileExists(BesideBridge(L"dash-vulkan-apidump.txt"))) apiDump = FindVulkanLayer(L"VkLayer_api_dump.json");
        if (validation.empty() && apiDump.empty()) Trace("DashVulkanTrace: Vulkan SDK layers not found (install the Vulkan SDK); trace not enabled");
    }

    std::wstring layers, layerPaths;
    auto add = [&](const std::wstring& json, const wchar_t* layerName) {
        if (json.empty()) return;
        if (!layers.empty()) layers += L";";
        layers += layerName;
        std::wstring dir = json.substr(0, json.find_last_of(L'\\'));
        if (layerPaths.find(dir) == std::wstring::npos) { if (!layerPaths.empty()) layerPaths += L";"; layerPaths += dir; }
    };
    add(apiDump, L"VK_LAYER_LUNARG_api_dump");                // first = closest to Dash: logs what Dash sees
    add(fixLayer, L"VK_LAYER_ARCRIFT_semaphore_fallback");
    add(validation, L"VK_LAYER_KHRONOS_validation");
    if (layers.empty()) return;
    SetEnvironmentVariableW(L"VK_INSTANCE_LAYERS", layers.c_str());
    SetEnvironmentVariableW(L"VK_ADD_LAYER_PATH", layerPaths.c_str());
    if (validation.empty() && apiDump.empty()) {
        Trace("DashVulkanLayers: enabled for processes OVRServer starts. layers=%ls paths=%ls", layers.c_str(), layerPaths.c_str());
        return;
    }

    traceDirectory = BesideBridge(L"vulkan-trace");
    CreateDirectoryW(traceDirectory.c_str(), nullptr);

    // Fallback settings file with fixed names, for layer versions that ignore the per-launch variables below.
    std::wstring settings = traceDirectory + L"\\vk_layer_settings.txt";
    FILE* file = nullptr;
    if (_wfopen_s(&file, settings.c_str(), L"w") == 0 && file) {
        fprintf(file, "khronos_validation.debug_action = VK_DBG_LAYER_ACTION_LOG_MSG\n");
        fprintf(file, "khronos_validation.report_flags = error,warn\n");
        fprintf(file, "khronos_validation.log_filename = %ls\\fixed-validation.txt\n", traceDirectory.c_str());
        fprintf(file, "lunarg_api_dump.file = true\n");
        fprintf(file, "lunarg_api_dump.log_filename = %ls\\fixed-apidump.txt\n", traceDirectory.c_str());
        fprintf(file, "lunarg_api_dump.output_format = text\n");
        fprintf(file, "lunarg_api_dump.detailed = true\n");
        fprintf(file, "lunarg_api_dump.flush = true\n");
        fclose(file);
    }

    SetEnvironmentVariableW(L"VK_LAYER_SETTINGS_PATH", settings.c_str());
    SetEnvironmentVariableW(L"VK_KHRONOS_VALIDATION_DEBUG_ACTION", L"VK_DBG_LAYER_ACTION_LOG_MSG");
    SetEnvironmentVariableW(L"VK_KHRONOS_VALIDATION_REPORT_FLAGS", L"error;warn");
    SetEnvironmentVariableW(L"VK_LUNARG_API_DUMP_FILE", L"true");
    SetEnvironmentVariableW(L"VK_LUNARG_API_DUMP_OUTPUT_FORMAT", L"text");
    SetEnvironmentVariableW(L"VK_APIDUMP_OUTPUT_FORMAT", L"text");
    SetEnvironmentVariableW(L"VK_LUNARG_API_DUMP_DETAILED", L"true");
    SetEnvironmentVariableW(L"VK_LUNARG_API_DUMP_FLUSH", L"true"); // keep output even if Dash is killed

    // The name-rotating thread outlives every caller, so keep this DLL loaded for the life of the process.
    HMODULE pinned = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&ApplyDashVulkanLayers), &pinned);
    HANDLE thread = CreateThread(nullptr, 0, RotateVulkanTraceNames, nullptr, 0, nullptr);
    if (thread) CloseHandle(thread);
    Trace("DashVulkanTrace: enabled for processes OVRServer starts. layers=%ls paths=%ls output=%ls",
        layers.c_str(), layerPaths.c_str(), traceDirectory.c_str());
}

OVR_EXPORT ovrResult DirectDisplayInitialize(uint64_t id, OVR::IDirectDisplayAPI** out) {
    Trace("DirectDisplayInitialize requested IID=%llx", id);
    ApplyDashVulkanFlip();
    ApplyDashVulkanLayers();
    if (!out) return ovrError_InvalidParameter;
    *out = nullptr;
    if (id != OVR::IID_IDirectDisplayAPI) return ovrError_Unsupported;
    *out = new Provider;
    return ovrSuccess;
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) { self = module; DisableThreadLibraryCalls(module); }
    return TRUE;
}
