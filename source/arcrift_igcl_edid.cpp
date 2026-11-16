// ArcRift 1.4: Intel driver-level EDID override for the headset output.
//
// Why: a session gives the headset its native display mode with Windows' own EDID override (a registry value plus a
// monitor restart). On an Arc B580 that override was reported not to be picked up. Intel's driver has its own,
// documented way to replace an output's EDID: the Intel Graphics Control Library (IGCL, ControlLib.dll, installed
// with the Intel graphics driver). This helper uses it for the headset output only.
//
//   --status    read-only: which EDID the driver uses for the headset output, and whether an override is active
//   --override  replace the headset output's EDID with the session EDID (rift-s-native-test.edid). Not a firmware
//               write: the EDID stored in the headset is untouched (Intel: "no change to EDID stored in Monitor")
//   --undo      remove an override from the headset output (safe to run when there is none)
//
// Intel documents that a Windows EDID override takes precedence over this one, so the session must remove its
// registry override before using --override. The headset is the output whose Windows target ID is in
// arcrift-identity.txt, on a graphics card that file allows; --override also requires that Windows shows that
// exact monitor as an active display on the same card. Nothing else is ever touched.
//
// Exit codes: 0 done, 1 refused or failed, 2 usage, 3 Intel library or headset output not available.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <vector>
#include "arcrift_identity.h"
#include "edid_mode.h"
#define CTL_APIEXPORT
#include "igcl_api.h"

static decltype(&ctlEdidManagement) pEdid = nullptr;

struct EdidRead {
    ctl_result_t result = CTL_RESULT_ERROR_UNINITIALIZED;
    uint32_t flags = 0;
    std::vector<uint8_t> data;
    bool Ok() const { return result == CTL_RESULT_SUCCESS && data.size() >= 128; }
};

static EdidRead ReadEdid(ctl_display_output_handle_t output, ctl_edid_type_t type) {
    EdidRead r;
    ctl_edid_management_args_t a{};
    a.Size = sizeof(a);
    a.OpType = CTL_EDID_MANAGEMENT_OPTYPE_READ_EDID;
    a.EdidType = type;
    r.result = pEdid(output, &a); // pass 1: size
    r.flags = a.OutFlags;
    if (r.result != CTL_RESULT_SUCCESS || a.EdidSize == 0 || a.EdidSize > 4096) return r;
    r.data.resize(a.EdidSize);
    a.pEdidBuf = r.data.data();
    r.result = pEdid(output, &a); // pass 2: data
    r.flags = a.OutFlags;
    if (r.result != CTL_RESULT_SUCCESS) r.data.clear();
    return r;
}

// "OVR0012 1440x2560@80.00" for an EDID, or the reason it could not be read.
static void Describe(const EdidRead& r, char* out, size_t size) {
    if (r.result == CTL_RESULT_ERROR_DATA_NOT_FOUND) { snprintf(out, size, "none"); return; }
    if (!r.Ok()) { snprintf(out, size, "unreadable(%08x%s)", unsigned(r.result), r.result == CTL_RESULT_ERROR_KMD_CALL ? ",needs-admin?" : ""); return; }
    const uint8_t* e = r.data.data();
    unsigned m = (e[8] << 8) | e[9];
    char maker[4] = {char('A' - 1 + ((m >> 10) & 31)), char('A' - 1 + ((m >> 5) & 31)), char('A' - 1 + (m & 31)), 0};
    for (char& c : maker) if (c && (c < 'A' || c > 'Z')) c = '_';
    ArcRiftEdidMode mode = ArcRiftParseEdidMode(e);
    snprintf(out, size, "%s%04X %ux%u@%.2f", maker, unsigned(e[10] | (e[11] << 8)), mode.width, mode.height, mode.hz);
}

// The graphics card Windows shows the Setup headset monitor on (active display, exact monitor path).
static bool WindowsHeadsetAdapter(const ArcRiftIdentity& id, LUID& luid) {
    UINT paths = 0, modes = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &paths, &modes)) return false;
    std::vector<DISPLAYCONFIG_PATH_INFO> p(paths);
    std::vector<DISPLAYCONFIG_MODE_INFO> m(modes);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &paths, p.data(), &modes, m.data(), nullptr)) return false;
    for (UINT i = 0; i < paths; ++i) {
        if (p[i].targetInfo.id != id.target) continue;
        DISPLAYCONFIG_TARGET_DEVICE_NAME name{};
        name.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(name), p[i].targetInfo.adapterId, p[i].targetInfo.id};
        if (DisplayConfigGetDeviceInfo(&name.header) || !id.MonitorMatches(name.monitorDevicePath)) continue;
        luid = p[i].targetInfo.adapterId;
        return true;
    }
    return false;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    enum { Status, Override, Undo } op;
    if (argc == 2 && !strcmp(argv[1], "--status")) op = Status;
    else if (argc == 2 && !strcmp(argv[1], "--override")) op = Override;
    else if (argc == 2 && !strcmp(argv[1], "--undo")) op = Undo;
    else { puts("Usage: arcrift_igcl_edid --status | --override | --undo"); return 2; }
    const char* opName = op == Status ? "status" : op == Override ? "override" : "undo";

    const ArcRiftIdentity id = ArcRiftLoadIdentity(nullptr);
    if (!id.valid) { printf("RESULT op=%s ok=0 reason=identity-missing (run Setup; arcrift-identity.txt not found or incomplete)\n", opName); return 1; }
    char sessionEdid[256]{};
    if (op == Override && !ArcRiftReadSessionEdid(nullptr, sessionEdid)) { printf("RESULT op=%s ok=0 reason=session-edid-missing-or-invalid\n", opName); return 1; }
    LUID windowsLuid{};
    const bool windowsActive = WindowsHeadsetAdapter(id, windowsLuid);
    if (op == Override && !windowsActive) { printf("RESULT op=%s ok=0 reason=headset-not-an-active-windows-display\n", opName); return 1; }

    HMODULE lib = LoadLibraryExW(L"ControlLib.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!lib) { printf("RESULT op=%s ok=0 reason=intel-control-library-missing error=%lu\n", opName, GetLastError()); return 3; }
#define PROC(name) auto p_##name = reinterpret_cast<decltype(&name)>(GetProcAddress(lib, #name));
    PROC(ctlInit)
    PROC(ctlClose)
    PROC(ctlEnumerateDevices)
    PROC(ctlEnumerateDisplayOutputs)
    PROC(ctlGetDeviceProperties)
    PROC(ctlGetDisplayProperties)
    PROC(ctlEdidManagement)
    if (!p_ctlInit || !p_ctlClose || !p_ctlEnumerateDevices || !p_ctlEnumerateDisplayOutputs || !p_ctlGetDeviceProperties || !p_ctlGetDisplayProperties || !p_ctlEdidManagement) {
        printf("RESULT op=%s ok=0 reason=intel-control-library-too-old\n", opName);
        return 3;
    }
    pEdid = p_ctlEdidManagement;
    ctl_init_args_t init{};
    init.Size = sizeof(init);
    init.AppVersion = CTL_IMPL_VERSION;
    ctl_api_handle_t api = nullptr;
    ctl_result_t result = p_ctlInit(&init, &api);
    if (result != CTL_RESULT_SUCCESS) { printf("RESULT op=%s ok=0 reason=intel-control-library-init-failed result=%08x\n", opName, unsigned(result)); return 3; }

    // Find the headset output: an allowed Intel card (and, when Windows shows the headset, exactly that card),
    // and the output whose Windows target ID is the one from Setup.
    ctl_display_output_handle_t headset = nullptr;
    ctl_display_properties_t headsetProps{};
    uint32_t deviceCount = 0;
    if (p_ctlEnumerateDevices(api, &deviceCount, nullptr) == CTL_RESULT_SUCCESS && deviceCount && deviceCount <= 32) {
        std::vector<ctl_device_adapter_handle_t> devices(deviceCount);
        if (p_ctlEnumerateDevices(api, &deviceCount, devices.data()) == CTL_RESULT_SUCCESS) {
            for (auto device : devices) {
                ctl_device_adapter_properties_t props{};
                LUID luid{};
                props.Size = sizeof(props);
                props.pDeviceID = &luid;
                props.device_id_size = sizeof(luid);
                if (p_ctlGetDeviceProperties(device, &props) != CTL_RESULT_SUCCESS) continue;
                if (!id.GpuAllowed(props.pci_vendor_id, props.pci_device_id)) continue;
                if (windowsActive && memcmp(&luid, &windowsLuid, sizeof(LUID)) != 0) continue;
                uint32_t n = 0;
                if (p_ctlEnumerateDisplayOutputs(device, &n, nullptr) != CTL_RESULT_SUCCESS || !n || n > 256) continue;
                std::vector<ctl_display_output_handle_t> outputs(n);
                if (p_ctlEnumerateDisplayOutputs(device, &n, outputs.data()) != CTL_RESULT_SUCCESS) continue;
                for (uint32_t i = 0; i < n && !headset; ++i) {
                    ctl_display_properties_t d{};
                    d.Size = sizeof(d);
                    if (p_ctlGetDisplayProperties(outputs[i], &d) != CTL_RESULT_SUCCESS) continue;
                    if (d.Os_display_encoder_handle.WindowsDisplayEncoderID != id.target) continue;
                    headset = outputs[i];
                    headsetProps = d;
                    printf("Headset output: %s device=%04x target=%u type=%d attached=%u active=%u\n", props.name, props.pci_device_id, id.target,
                        int(d.Type), !!(d.DisplayConfigFlags & CTL_DISPLAY_CONFIG_FLAG_DISPLAY_ATTACHED), !!(d.DisplayConfigFlags & CTL_DISPLAY_CONFIG_FLAG_DISPLAY_ACTIVE));
                }
                if (headset) break;
            }
        }
    }
    int exitCode = 1;
    if (!headset) {
        printf("RESULT op=%s ok=0 reason=headset-output-not-found target=%u windowsActive=%d\n", opName, id.target, windowsActive);
        exitCode = 3;
    } else {
        EdidRead current = ReadEdid(headset, CTL_EDID_TYPE_CURRENT);
        const bool overridden = current.Ok() && (current.flags & CTL_EDID_MANAGEMENT_OUT_FLAG_SUPPLIED_EDID);
        char currentText[80], monitorText[80], overrideText[80];
        Describe(current, currentText, sizeof(currentText));
        Describe(ReadEdid(headset, CTL_EDID_TYPE_MONITOR), monitorText, sizeof(monitorText));
        Describe(ReadEdid(headset, CTL_EDID_TYPE_OVERRIDE), overrideText, sizeof(overrideText));
        printf("Before: current=[%s]%s monitor=[%s] override=[%s]\n", currentText, overridden ? " (driver override active)" : "", monitorText, overrideText);
        if (op == Status) {
            // The driver only answers EDID reads from an administrator process; without that, say so instead of "ok".
            if (current.Ok()) printf("RESULT op=status ok=1 overrideActive=%d current=[%s] monitor=[%s]\n", overridden, currentText, monitorText);
            else printf("RESULT op=status ok=0 reason=edid-not-readable result=%08x (run as administrator)\n", unsigned(current.result));
            exitCode = current.Ok() ? 0 : 1;
        } else if (op == Override) {
            const bool supportedType = headsetProps.Type == CTL_DISPLAY_OUTPUT_TYPES_DISPLAYPORT || headsetProps.Type == CTL_DISPLAY_OUTPUT_TYPES_HDMI;
            if (!supportedType) printf("RESULT op=override ok=0 reason=output-type-not-supported type=%d\n", int(headsetProps.Type));
            else if (!(headsetProps.DisplayConfigFlags & CTL_DISPLAY_CONFIG_FLAG_DISPLAY_ATTACHED)) puts("RESULT op=override ok=0 reason=headset-not-attached");
            else if (overridden && current.data.size() == 128 && memcmp(current.data.data(), sessionEdid, 128) == 0) { puts("RESULT op=override ok=1 already=1"); exitCode = 0; }
            else if (overridden) puts("RESULT op=override ok=0 reason=another-override-is-active (run --undo first)");
            else {
                ctl_edid_management_args_t a{};
                a.Size = sizeof(a);
                a.OpType = CTL_EDID_MANAGEMENT_OPTYPE_OVERRIDE_EDID;
                a.EdidType = CTL_EDID_TYPE_OVERRIDE;
                a.EdidSize = 128;
                a.pEdidBuf = reinterpret_cast<uint8_t*>(sessionEdid);
                result = pEdid(headset, &a);
                printf("RESULT op=override ok=%d result=%08x flags=%x windowsNotified=%d\n", result == CTL_RESULT_SUCCESS, unsigned(result), unsigned(a.OutFlags),
                    !!(a.OutFlags & CTL_EDID_MANAGEMENT_OUT_FLAG_OS_CONN_NOTIFICATION));
                exitCode = result == CTL_RESULT_SUCCESS ? 0 : 1;
            }
        } else { // Undo
            if (current.Ok() && !overridden) { puts("RESULT op=undo ok=1 nothingToUndo=1"); exitCode = 0; }
            else {
                ctl_edid_management_args_t a{};
                a.Size = sizeof(a);
                a.OpType = CTL_EDID_MANAGEMENT_OPTYPE_UNDO_OVERRIDE_EDID;
                a.EdidType = CTL_EDID_TYPE_OVERRIDE;
                result = pEdid(headset, &a);
                const bool done = result == CTL_RESULT_SUCCESS || result == CTL_RESULT_ERROR_DATA_NOT_FOUND;
                printf("RESULT op=undo ok=%d result=%08x flags=%x windowsNotified=%d\n", done, unsigned(result), unsigned(a.OutFlags),
                    !!(a.OutFlags & CTL_EDID_MANAGEMENT_OUT_FLAG_OS_CONN_NOTIFICATION));
                exitCode = done ? 0 : 1;
            }
        }
    }
    p_ctlClose(api);
    FreeLibrary(lib);
    return exitCode;
}
