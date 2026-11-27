# Changelog

## Unreleased

### No spaces in file names
- Renamed the launchers: `CHECK-MY-PC.cmd`, `CV1-MODE-TEST.cmd`, `START-MANUAL-SESSION.cmd`,
  `START-META-DASH.cmd`, `STOP-AND-RESTORE.cmd` (were `CHECK MY PC.cmd`, etc.), so they can be typed in
  PowerShell without quotes. README and script messages updated. ArcRift Control only calls the `.ps1`
  scripts, so it is unaffected. Naming rules are in `CONTRIBUTING.md`.

## 1.6 (2026-11-22)

### Meta Dash & Guardian enabled out of the box
- Ships with `dash-vulkan-flip.txt`, `dash-vulkan-semaphore-fix.txt`, and `vk-layer\arcrift_vk_layer.dll` enabled (without the heavy validation-layer trace file).
- Fixed Vulkan layer handle/device leaks by hooking `vkDestroyImage` and `vkDestroyDevice` (allowing clean Vulkan device recreation) and fixed uninitialized output handle / memory-type fallback edge cases in `AllocateMemory`.
- Made `ApplyDashVulkanFlip` fall back to a unique 27-byte executable-section signature scan if a Meta Horizon update shifts RVA `0x166f17`.
- `-GuardianSetup` / Meta Dash sessions no longer require Steam or SteamVR, now include the Meta Breakpad crash watchdog, 30 s freeze watchdog, `ForceSensorTracking` check, proximity-off pause, and `OVRServer_x64`/`OculusDash` GPU+CPU priority boost, and no longer false-trigger "Guardian saved" on startup when an existing Guardian loads.
- Added `START META DASH.cmd` shortcut.

### Redesigned ArcRift Control UI & DPI scaling fix
- Two switchable built-in UI themes in the top bar: **Arc Glass** (sidebar layout) and **Studio Minimal** (compact top command bar + wide console).
- Viewport-fitted (`100vh`) responsive layout and `1120x700` default window size so the UI scales cleanly at 100%–150% Windows DPI without clipping the session log.
- Made **Start Meta Dash / Guardian** the primary button, kept **Start VR session (SteamVR)** as secondary, and removed the legacy Room Boundary panel.
- Setup now saves `headsetProfile` (`rift-s` / `rift-cv1`) and does not require a scraped USB serial for Rift CV1.

### Bridge performance & reliability
- Switched swapchain to `DXGI_SWAP_EFFECT_FLIP_DISCARD`, `DXGI_SCALING_NONE` on 1:1 native surfaces, and 1-frame waitable latency (`DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT` + `SetMaximumFrameLatency(1)`).
- Replaced per-frame `ReadProcessMemory` syscall in `Display::Present` with zero-syscall x64 SEH pointer read.
- Wrapped bridge window creation in Per-Monitor DPI Awareness v2 (`WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT`).
- Made `Trace()` mutex-guarded with shared file open (`_SH_DENYNO`) to eliminate dropped log lines.
- Hid `native_source_session.exe`'s console window (`-WindowStyle Hidden`) and skipped redundant source-only emergency restore during EDID/mode rollback.

### Intel Arc B580 & Rift CV1 support
- Built and integrated `arcrift_igcl_edid.exe` (Intel driver-level IGCL EDID override with 128/256-byte EDID and `CTL_MAKE_VERSION(1, 0)` fallback) as an automatic fallback when Windows `EDID_OVERRIDE` restarts are ignored (e.g., on Arc B580), with full rollback & recovery `--undo` support.
- Added 256-byte EDID support across `edid_mode.h`, `test-ovr-d3d11.ps1`, `recover-manual-session.ps1`, and `cv1-mode-probe.ps1`.
- Added 256-byte CTA-861 HDMI VSDB (`340 MHz` / `300 MHz` Max TMDS Clock) variants and IGCL fallback to `CV1 MODE TEST.cmd` to address the 165 MHz TMDS cap on strict HDMI 2.0/2.1 drivers.
- Fixed `Get-ArcRiftCv1Override` serial descriptor detection (dynamically locates `0xFF` instead of hardcoding bytes `90..107`).

## Unreleased: Dash Vulkan whitelist experiment (2026-11-22)

- Meta's runtime (208.0.0.84.535) decides from a hard-coded list, `IsGPUDashVulkanCapable` in `OVRServer_x64.exe`,
  which GPUs can run Dash on Vulkan: listed AMD (`0x1002`) and NVIDIA (`0x10de`) device IDs only. Intel is always
  "incapable" without Vulkan being tried, which is where the A770's `"VulkanCapable": false` comes from.
- Guardian setup session of 22 Nov 15:07 with the unchanged bridge: Meta's compositor worked (both 1440x2560 surfaces
  created, first frame presented), Dash loaded its Home UI and then quit while creating its own Vulkan eye swapchain
  ("Failed to configure Rendering Code: -4"), four times in 5 s. Dash logs nothing before that line.
- New, opt-in: when `dash-vulkan-flip.txt` exists next to `arc_rift_bridge.dll`, the bridge (which runs inside
  OVRServer) patches that one check in OVRServer's memory to answer "capable" (RVA 0x166f1f, `xor r13b,r13b` ->
  `mov r13b,1`). No Meta file is changed. It is applied only when 27 bytes around that spot match runtime
  208.0.0.84.535 exactly (checked unique in the file), so after a Meta update it logs that it was skipped.
  The bridge log says whether it was applied. Without the file the bridge behaves exactly as before.
- Only `arc_rift_bridge.dll` was rebuilt (same compiler line as BUILD-RELEASE.cmd) and `release-manifest.json`
  rewritten; the other five programs are unchanged. The previous DLL, manifest and source are in
  `backup-before-dash-vulkan-flip\`.
- Checked here: the 27 bytes match OVRServer on disk and occur once; `bridge_selftest.exe` passes with and without
  the file and refuses to patch outside OVRServer.
- Guardian setup session of 22 Nov 15:16 with the flip: the bridge log says it patched, Meta's hardware report now
  says `"VulkanCapable": true`, and Meta's hardware blocker went from `systemHardware` to `nothing` (the Meta app's
  message changed). Dash still quit with the same -4 each launch, so the headset only flashed: every launch started
  the compositor, which presented frames for 0.4-2 s and shut down when Dash quit. So the whitelist was one blocker,
  and Dash's own Vulkan setup is another.

### Dash Vulkan trace (opt-in, needs the Vulkan SDK)
- When `dash-vulkan-trace.txt` exists next to the bridge, the bridge sets the Vulkan SDK's API-dump and validation
  layers in OVRServer's own environment. Dash is started by OVRServer and inherits it, so only Meta's processes are
  traced: no system-wide or registry changes. Logs go to `vulkan-trace\`, one `-apidump.txt` and one
  `-validation.txt` per launch (the bridge renames them every 250 ms because Meta starts Dash several times).
- The layers are found in the Vulkan loader's registered explicit layers or in `%VULKAN_SDK%\Bin`. Without the SDK
  the bridge log says "Vulkan SDK layers not found" and nothing is enabled.
- Checked here: builds without new warnings, `bridge_selftest.exe` passes and refuses to enable it outside OVRServer.
- Guardian setup session of 22 Nov 15:29 (Vulkan SDK 1.4.363.1): Dash inherited it (five launches, one API dump and
  one validation log each). Every Vulkan call returned VK_SUCCESS. The validation layer, and Dash itself, logged
  `vkCreateSemaphore(): ... handleTypes (VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_KMT_BIT) does not support
  VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT`, and Dash quit with -4 34 ms later.

### Cause of Dash's "-4" on Intel Arc, and an opt-in fix
- The semaphore comes from Meta's runtime library inside Dash (`LibOVRRTImpl64_1.dll`), building its "SyncContext"
  with the compositor. It exports a KMT (old global) handle whenever the device lists
  `VK_KHR_external_semaphore_win32`; it never asks whether KMT export works. The Arc driver lists the extension but
  supports NT handles only. `tools\vk_layer_test` shows it on this A770 (driver 0x001963d7): semaphore NT
  exportable=1, KMT exportable=0. NVIDIA and AMD drivers export KMT, which is why this only fails on Arc.
- When the extension is not listed, the same library logs "[Non-fatal] VK_KHR_external_semaphore_win32 not supported,
  using fallback notification synchronization" and carries on.
- New: `vk-layer\arcrift_vk_layer.dll` (`source\arcrift_vk_layer.cpp`), a Vulkan layer that hides only that extension,
  and only after the process has created its Vulkan device: Dash enables the extension when it creates its device,
  and the Vulkan loader refuses a device whose extensions are not listed (seen in the test: -7 when hidden from the
  start). With `dash-vulkan-semaphore-fix.txt` next to the bridge, the bridge enables it (same way as the trace) for
  processes OVRServer starts.
- Checked here with `tools\vk_layer_test`: without the layer 160 extensions and the device is created; with it (and
  the validation layer) the device with Dash's extensions is still created, and the list read afterwards has 159,
  without that extension. The bridge self-test passes. **Not yet checked in a real session:** whether Dash then runs.
- Guardian setup session of 22 Nov 15:40 with the layer: it loaded in every Dash launch and hid the extension after
  Dash's device existed (`vk-layer\arcrift-vk-layer.log`). The KMT semaphore is gone (no `vkCreateSemaphore` in the
  API dump). Dash still quit with -4, now on the first failing Vulkan call of all these runs:
  `vkImportFenceWin32HandleKHR(handleType OPAQUE_WIN32, handle from Meta's compositor)` returns
  `VK_ERROR_INVALID_EXTERNAL_HANDLE`. Meta's fallback imports the compositor's D3D-side sync object into Vulkan as a
  fence; the Arc driver can import such objects only as semaphores (`D3D12_FENCE` importable=1 in the test).
- So both of Meta's Vulkan<->D3D11 sync routes for Dash rely on handle types the Arc driver does not support.
- That fence import has the same kind of guard: when the device does not list `VK_KHR_external_fence_win32`, Meta's
  library logs "[Non-fatal] VK_KHR_external_fence_win32 not supported, using fallback synchronization" and skips it.
  The layer now hides that extension too, the same way (after the device exists). The list can be overridden with
  `ARCRIFT_VK_HIDE_EXTENSIONS` (';'-separated). Checked with `tools\vk_layer_test`: device with Dash's extensions
  still created, the list afterwards has 158 (both hidden), validation layer quiet. If Meta's own fallback also fails,
  the next step is emulating the sync object in the layer.
- **First time Dash ran on Intel Arc:** Guardian setup session of 22 Nov 15:46 with flip + both hidden extensions.
  Dash started once at 15:47:07 and ran for over 5 minutes: Meta's Guardian setup worked through the headset
  cameras (passthrough texture set created 15:48:42, `inside_out_guardian_setup` events) and Meta saved a
  `walls_and_floor` Guardian. Meta's fallback synchronization works.
- New failure: at 15:52:19 Dash crashed (`STATUS_ACCESS_VIOLATION`) right after
  `vkBindImageMemory(): memory is VK_NULL_HANDLE`. The memory came from a failed import of a shared D3D11 texture:
  `vkAllocateMemory(): ... memoryTypeBits is 0x0 with handleType VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT`.
  The Arc driver cannot import old KMT-shared D3D11 textures. One such import already failed harmlessly at Dash's
  start; the one at 15:52 was bound and crashed it. In the next session (15:54) Dash crashed the same way 7 s after
  starting. Next step, not started: make those KMT texture imports work in the layer.
- Cause found and fixed in the layer: the swapchain textures Dash imports (3296x1776 colour + depth, 4x4 colour) come
  in as KMT D3D11 handles. `tools\vk_layer_test\kmt_import_test.cpp` reproduces it on the A770 without Meta: the KMT
  import works for RGBA8 colour and D32 depth, but for D24S8 depth `vkAllocateMemory` returns VK_SUCCESS with a NULL
  memory (both crashing runs ended on a D24S8 import). The layer now gives such an image ordinary device-local
  memory instead and logs "import of image ... gave it local memory instead" in `vk-layer\arcrift-vk-layer.log`.
  Meta's compositor then does not see that depth buffer (only used for ASW/positional timewarp, off on Arc).
  Checked with the test: with the layer all three formats get memory and bind; the extension test still passes.
- The trace now enables only the validation layer. The API dump (6.4 GB for the 5-minute run) needs its own opt-in
  file, `dash-vulkan-apidump.txt`. Bridge rebuilt, manifest rewritten (only the bridge changed), self-test passes.
- `[OVRServer] Set Oculus as Active OpenXR Runtime` is logged at every Meta start, including the 15:46 session where
  Dash ran for 5 minutes, so the OpenXR runtime setting is not what crashed Dash. It is a system-wide setting the
  session does not restore: SteamVR games that use OpenXR now go to Meta's runtime.
- The layer is built separately (it needs the Vulkan SDK's headers) and is not in `release-manifest.json`; the
  session does not verify it. The layer and test were built with:
  `cl /EHsc /std:c++17 /W4 /O2 /MT /LD /I"%VULKAN_SDK%\Include" arcrift_vk_layer.cpp /Fe:..\vk-layer\arcrift_vk_layer.dll`.

## 1.5 (2026-11-15)

This release includes all the 1.4 work below (1.4 was only shared as test builds, never published here; comments marked "Release 1.4" in
the scripts and source belong to this release).

Groundwork for more Intel Arc cards and for the Oculus Rift CV1. Nothing here changes how a Rift S session behaves.

### Fix: taking the headset off no longer makes Meta pause tracking (the crash when it is picked up again)
- What happened, from the 15 Nov 17:53 session's Meta log: headset off at 18:10:06, and 23 s later, with the headset
  lying still, "HMD movement state is toggled to false", "Setting tracking mode to off", "StopTracking". At 18:10:47
  the headset moved, Meta logged "Setting tracking mode to on" and "StartTracking", and wrote its crash report in
  the same second. Every crash checked so far followed that stop and start.
- A session now sets Meta's own `ForceSensorTracking` setting (DWORD 1 in
  `HKLM\SOFTWARE\WOW6432Node\Oculus VR, LLC\Oculus`) before it starts Meta's runtime, and puts it back with the
  other Meta settings at restore. Meta's runtime reads it once at start-up, logs "Tracking was forced on by
  regkey." and then holds tracking on for as long as it runs, so the stop and start never happen.
- How that is known: read from Meta's installed runtime (`OculusAppFramework.dll`, installed 6 Nov). Tracking is
  switched off in one place only, when the last part of the runtime that asked for tracking lets go. With this
  setting the runtime takes one such hold at start-up and keeps it.
- The headset display still switches off when the headset is not worn. Only the cameras and tracking keep running.
- The session window says "Tracking stays on while the headset is off" when Meta's log has that line, and says so
  if it does not. If Meta pauses tracking anyway, the window says so once and `sync-hiccups.txt` gets a line each
  time. The crash watchdog and the automatic restart below stay as they are.
- Recover and Clear accept sessions with or without the new setting. An older ArcRift copy (1.3 or earlier) refuses
  to recover a session started from this one ("Recovery backup count mismatch"): use this folder's Recover.
- Scripts only (`test-ovr-d3d11.ps1`, `session-recovery-policy.ps1`, README); no program was rebuilt.
- Checked here: both scripts parse, and the recovery check accepts old and new sessions and refuses five wrong ones.
- Seen in the two sessions of 15 Nov 18:32 and 18:33: Meta's log has "Tracking was forced on by regkey." and
  "Setting tracking mode to on" at start-up, and both sessions restored the setting. Both stopped as SteamVR
  started, for the reason in the next entry; Meta's log at that moment is line for line the same as in the last
  session without the setting. **Not yet checked:** that tracking stays on with the headset lying still for more
  than 30 s, and that picking it up then no longer crashes Meta's runtime.

### Fix: one SteamVR sync timeout while starting no longer stops a session
- Two sessions in a row (15 Nov 18:32 and 18:33) stopped the moment SteamVR came up, with "Graphics/synchronization
  failure during normal-user bootstrap". Nothing had crashed. SteamVR logged a single "WaitForAcquire timed out"
  on its very first frame, 22 ms after "Startup Complete", and the launch check stopped on any such line. The
  headset was getting frames normally (about 70 a second) until the session shut SteamVR down.
- Both were the first sessions started with SteamVR's render resolution at 150 % (`supersampleScale` 1.5, set
  during the 18:15 session). None of the 29 earlier sessions that reached "VR ready" had that setting, and none had
  the line. They were also the first two with `ForceSensorTracking`, so the logs alone cannot say which of the two
  it was; the render resolution is the likelier one, because that is the only difference on SteamVR's side.
- A manual session now carries on when SteamVR logs up to six sync-timeout lines while starting (one hitch writes
  up to three) and says so in the session window. That matches what a running manual session has done since 1.3:
  sync errors are noted, and the frame-rate, freeze and device-loss guards decide. More than six lines, a lost or
  hung GPU device, or a bridge error still stop the launch. The short test modes keep the old strict check.
- Scripts only (`steamvr-startup-policy.ps1`, `normal-user-steam-worker.ps1`, `normal-user-steam-launch.ps1`,
  `test-ovr-d3d11.ps1`).
- Checked here: the scripts parse, and the new check against the real SteamVR logs of both stopped sessions (old
  rule stops, new rule carries on with 1 line), a good session's log, and made-up cases for six lines, nine lines
  and device loss. **Not yet checked in a real session.**

### New: automatic restart after a Meta runtime crash
- When a manual session stops because Meta's runtime crashed, it restores as before, then opens a fresh session in a
  new window. That window is started by the already-elevated session, so there is no administrator prompt. The new
  session waits for the old window to exit and for SteamVR to close, and says "Automatic restart N of 3". The old
  session folder gets `auto-restart.txt`.
- It does not restart after Stop & restore, if the restore was not verified, if Meta crashed before or within a
  minute of the session becoming ready (not the known headset-down crash), or after three restarts in a row. In each
  of those cases it says why. Your game loses VR at the crash either way and has to be started again.
- For a few seconds between the two sessions ArcRift Control shows no session. A Start pressed then is refused
  safely ("active-test.lock is in use"), and Stop & restore works again once the new session shows Starting.
- Why: the proximity bypass does not stop the crash (tested 15 Nov 16:53, bypass on and the Debug Tool open; Meta
  still paused tracking and crashed on resume).
- Checked here: all ten restart decisions, the exact command line passed on, the refusal when the script path is
  unknown, and the wait for the previous window. **Not yet checked in a real crash.**

### Fix: a click in the session window no longer freezes the session's guards
- The elevated session window had Windows' QuickEdit on. One click in it starts a text selection, and the session
  then waits at its next line of output until the selection is cleared. In the 15 Nov 16:32 session it waited
  11 minutes on "Headset on" (16:34:58 to 16:46:08). It missed a Meta crash at 16:41:30 and a Stop & restore at
  16:45:17, then stopped as "below 5 fps" because the frame check compared against 16:34:58.
- The session now turns QuickEdit off for its own window only. Text can still be selected from the window menu
  (Edit > Mark), which pauses it the same way, so don't leave a selection there.
- Checked here: in a new console window QuickEdit went from on to off, and the other console settings didn't change.

### New: Meta runtime crashes are caught directly
- The "Meta runtime stopped responding" stops were crashes, not freezes. Each of the four checked (14 Nov 18:42,
  15 Nov 12:31, 13:51 and 15:11) matches, to the second, a crash report Meta's runtime wrote for itself in
  `%LOCALAPPDATA%\Oculus\OVRServerBreakpad`. The crashing thread is always the one that had just logged
  "StartTracking" after the headset sat still. Every report since 31 Oct has the same code (0xC0000025, no
  address), which is what Meta's crash reporter records for a pure virtual function call. The process then lingers
  with one thread, so it never showed as exited and only the 30 s log-silence check caught it.
- A manual session now checks Meta's crash folder every 2 s. A new report stops and restores at once, with
  "Meta runtime crashed" as the reason, and `meta-crash.txt` in the session folder names the report. ArcRift only
  lists the folder; the report stays where Meta put it. The 30 s silence check stays as a fallback for a real hang,
  and it also checks for a crash report first.
- The hang record's dump (below) now opens Meta's process for exactly what a dump needs. Before, it asked for
  `Process.Handle`, which came back empty on the first real stop ("Cannot convert null to type System.IntPtr").
- Scripts only (`test-ovr-d3d11.ps1`, README); no program was rebuilt.

### New: record of a frozen Meta runtime
- When the freeze watchdog fires (Meta's log silent for 30 s, usually after picking up a headset that sat still),
  the session now saves two files in the session folder before it stops Meta and restores: `meta-hang-threads.txt`
  (every thread's state and the CPU it used over 1 s; the thread numbers match Meta's `Service_….txt` log) and
  `meta-hang.dmp` (thread stacks, for WinDbg; about 50 MB, not the whole process).
- It only reads Meta's process, takes about 2 s, runs with a 30 s limit and is skipped with less than 3 GB free.
  If it fails, the session says so and restores as before.
- Checked here: against the idle Meta runtime on the A770 PC (93 threads, 50 MB dump, 1.9 s, runtime kept running).
  **Not yet checked on a real freeze**, and not from the administrator session window.
- Why: across all saved logs, Meta's tracking was paused and resumed 26 times; 10 froze, always right after
  "StartTracking" and before its vision start-up lines. The bridge is not being called at that moment. The cause
  inside Meta's runtime is unknown.

### New: compatibility report for testers
- **CHECK MY PC.cmd** writes `compat-report-….txt`: graphics card and driver, how Windows presents the headset
  display, the headset display's EDID, and the Meta runtime's lines about the headset. It only reads, needs no
  administrator rights and starts no session. Serial numbers are masked.
- It works when dropped into a 1.3 folder as well (it uses the `display_probe.exe` that is already there).
- **Report format 2** adds the display modes Windows offers for the headset display, and says whether the mode in
  the headset's own EDID is in use, only offered, or missing. It also names the Rift CV1's audio and hub USB
  devices and repeats Meta's "headset is on a USB 2 port" warning in the summary.
- First Rift CV1 report (Arc B580, HDMI, format 1): Windows uses the CV1 as a normal desktop display, which is
  what a session needs, but runs it at 1920x1080 60 Hz. That mode is not in the CV1's EDID, whose only mode is
  2160x1200 at 90 Hz. Format 1 could not tell whether the driver still offers 2160x1200; format 2 can. The CV1's
  EDID already carries the headset serial, so a CV1 session should not need a temporary EDID at all.

### Experimental: Rift CV1 session (untested)
Built from that one report. **No CV1 session has been run yet**, and the developer has no CV1 or B580.
- A headset display that identifies itself as OVR0004 is treated as a Rift CV1 (`rift-cv1` profile in
  `test-ovr-d3d11.ps1`); everything else is a Rift S, as before. Setup needs no change.
- A CV1 session writes **no EDID**. The bridge gives Meta the headset display's own EDID as Windows read it, and
  the session asks Windows to switch that display to 2160x1200 at 90 Hz (89 to 91), then back afterwards. The
  switch is temporary and never saved (new `display-mode.ps1`).
- Before anything is changed, the session checks that Windows offers that mode and passes a test of it. If not, it
  stops with "No changes made" and leaves the list of offered modes in `headset-modes-offered.txt`.
- Restore: Windows' saved mode first, then the mode from before the session, then a monitor restart; the usual
  comparison against the baseline decides. Recover does the same for a CV1 session that was cut off.
- Scripts only: no program was rebuilt, so `release-manifest.json` is unchanged. Checked here: the scripts parse,
  the Rift S path writes byte-identical EDID and identity files, and a real temporary switch and restore of the
  Rift S placeholder display on the A770 (1920x1080 to 1280x720 and back, once by Windows' saved mode and once
  by setting the old mode) left all three displays matching the baseline within 1 s. That placeholder has only
  one timing, so the test changed the desktop size while the signal stayed 1920x1080; a switch that changes the
  signal itself, which is what the CV1 needs, is not checked. Neither is anything on a CV1.

### Experimental: Rift CV1 mode test (untested on a real CV1)
First CV1 session attempt (Arc B580, HDMI, 2026-11-15): it stopped before changing anything, as designed.
Windows does not offer 2160x1200 at 90 Hz there; the largest mode offered is 1920x1080 at 60 Hz. So the graphics
driver leaves the CV1's only mode out, and nobody knows yet what it objects to. The tester confirmed the HDMI
cable goes straight into the B580's HDMI port with no adapter, so an adapter's 165 MHz limit is not the cause.
- **CV1 MODE TEST.cmd** (`cv1-mode-probe.ps1`) finds that out. It gives the headset display a series of temporary
  Windows EDID overrides (the mechanism a Rift S session and the CRU tool use), restarts the headset's monitor
  device after each, and records whether Windows now offers 2160x1200. Then it removes the override and checks
  every display against how it was before.
  - Variants the headset could not tell from its own mode ("usable"): its own EDID again, a 297.00 MHz pixel
    clock instead of 296.75, and its own timing without the frequency-limits entry. Only these are ever switched
    on, for a few seconds, to read the signal back.
  - Variants that only show what the driver objects to (never output): wider line blanking, shorter frame
    blanking, both, 60 Hz, and 59 Hz under 165 MHz.
  - A usable variant that works is saved as `cv1-override.edid`.
- A CV1 session that does not find its mode offered now (1) restarts the headset's monitor device once and looks
  again, then (2) uses `cv1-override.edid` as a temporary EDID, like a Rift S session, and switches the mode, or
  (3) stops with "No changes made" and says to run CV1 MODE TEST. The override file is only accepted if it is this
  headset's own EDID with the same picture size and layout and a pixel clock within 0.5 %.
- Checked here: scripts parse; Rift S EDID and identity files are still byte-identical; the EDID variants decode
  to the intended timings; the override check accepts exactly the usable variants; and the whole test ran against
  a simulated CV1 with six pretend driver behaviours (nothing accepted, clock variant, plain restart, changed
  timings only, overrides ignored, everything). **Not checked: any of it on a real CV1 or a B580.**

- **First real run of the mode test (B580, 2026-11-15) was inconclusive.** Windows kept showing the first
  description ("Rift own") for every later variant, so only the control was really tried: after the first
  override, restarting the monitor device no longer made Windows read a new one on that PC. The test's summary
  wrongly said the driver had refused every variant. What it does show: with the headset's own description the
  B580 offers exactly one mode, 1920x1080 at 60 Hz.
- Mode test, report format 2: each variant's name carries the run's number, the test checks Windows really uses
  it, and when it does not it asks for the HDMI cable to be unplugged and plugged back in. A variant Windows
  never used is reported as NOT TESTED. Fewer variants (own, 297 MHz, ordinary blanking, 60 Hz, 59 Hz). Checked
  only in the simulation, including a simulated PC that behaves like that B580.
- Open: a CV1 session that uses `cv1-override.edid` applies it with the same monitor restart, so on that PC it
  may need the same re-plug. Not handled yet.

### Headset mode is no longer written out in the code
- The bridge and the desktop-size helper read the headset's display mode from the session's EDID file instead of
  fixed Rift S numbers (new `source/edid_mode.h`). For the Rift S that is the same 1440x2560 at 80 Hz as before.
- The session script keeps headset-specific values in a profile (`headsetProfile` in `arcrift-config.json`; a
  config without it is a Rift S). Only the Rift S profile exists so far.
- The bridge reports HDMI to Meta when Windows says the headset is on HDMI (Rift CV1); DisplayPort otherwise.
- Rebuilt on 2026-11-13 and confirmed with one short Rift S session on the A770 (startup, display mode, SteamVR,
  rollback; no game was run).

### Faster start when the headset display is a moment late
- Meta asks for the headset display only once, about a second after its runtime starts. If the Rift S display was
  still switching back on at that moment, the session used to fall back to "wake the headset and retry", which
  adds about 70 s (seen in 4 of the last 10 sessions). The bridge now waits up to 8 s for the display to appear
  before answering "not found". A headset that is really asleep still goes through the retry, 8 s later.
- **Not confirmed yet:** it needs a session started after the headset has sat unused. The bridge log then shows
  `headset display became active after … ms` if the wait helped, or `still not active after … ms` if it did not.

### Other Intel Arc cards
- The app knows the A380, A580, A750, A770, B570 and B580 by device ID and says what is known about each one
  (only the A770 is tested). Setup has a **Check my PC** button that writes the compatibility report.
  `ArcRift Control.exe` was rebuilt with it for 1.5 (2026-11-15).
- Experimental, **not used by a session yet**: `source/arcrift_igcl_edid.cpp`, a helper that replaces the headset
  output's EDID through Intel's own driver library instead of Windows' EDID override. It is meant as a fallback
  for the B580 report, where Windows' override was not picked up. It is not in `BUILD-RELEASE.cmd` or the
  manifest, and its override/undo have never been run. It needs Intel's `igcl_api.h`, which is not part of the
  release (see `NOTICE.md`).

## 1.3 (2026-11-13)

Covers everything since 1.1.2, including the in-between builds 1.2 and 1.2.1, which were never published.

### New: room boundary
Meta's Guardian cannot be set up on Intel Arc (its setup runs inside Meta's Dash, which needs Vulkan, and Meta
does not support Vulkan on Arc cards). ArcRift now draws a boundary itself with a new helper, `arcrift_boundary.exe`.
- **Box around me**: pick a size (1.5 × 1.5 m up to 4 × 3 m), stand in the middle facing forward, and a box is placed
  around you. The box also becomes SteamVR's play area, centred where you stood and facing the way you faced, so
  games get the whole box.
- **Draw boundary**: hold a controller's trigger and trace the edge of your play space for an exact shape.
- Cyan grid walls fade in when your head or hands come within about 75 cm of an edge.
- **Use saved boundary** brings a box or traced outline back in a later session. **Remove boundary** takes it away
  and puts back SteamVR's previous boundary data.
- `boundary-log.txt` records what SteamVR saw (controllers, tracking, headset height) when something doesn't work.
- Asking for Meta Guardian setup now gives a clear message instead of starting a session that can only crash.

### Session stopping
- A session now stops on low frame rate only when the headset is below **5 fps** (fewer than 120 frames in 24 s,
  which includes a full freeze). Before, it stopped below 45 fps twice in a row, or after 3 s with no frames.
- SteamVR sync errors (a game running slowly) are only written to `sync-hiccups.txt`. They no longer stop a
  session.

### Recovery
- If the PC was shut down, restarted or crashed during a session, just press **Start VR session**: the session
  restores the unrestored session first, then starts a new one.
- This also works when the unrestored session came from another ArcRift copy, such as an older release folder.
- A session that ended in its first seconds, before it changed anything, no longer leaves a "Needs recovery" marker
  that blocks Start.
- A leftover `active-test.lock` from an interrupted session no longer makes every later Start fail.
- The recovery check reads active displays the same way as the session script, and keeps two graphics adapters
  with the same display target ID apart.

### Other Intel Arc cards (B580 and others)
These cards are still untested, and the one B580 report (headset stuck at 1920x1080 60 Hz) is **not fixed yet**.
This release adds:
- The bridge now checks that the headset is plugged into the graphics card it expects, using what Windows reports.
  This fixes PCs that have processor graphics plus an Arc card, where Setup could pick the wrong one.
- The session waits up to 45 s (was 6 s, then 20 s) for the headset's native display mode. PCs that are ready
  sooner carry on straight away.
- Each session folder gets a `system-info.txt` (graphics card, driver, Windows build) for bug reports.
- When the headset display can't be matched, the bridge log and session log say why.

### Fixes
- Start no longer fails on PCs that run more than one `explorer.exe` (for example with "Launch folder windows in a
  separate process" turned on). Only the Explorer that owns the desktop is checked.
- The bridge handles Meta rebuilding its compositor (with a new D3D11 device) cleanly, without mixing resources from
  the old and new devices.
- A session won't start while SteamVR or VRChat is already open, and it names the program to close.

### Build
- `BUILD-RELEASE.cmd` also builds `arcrift_boundary.exe`, and `release-manifest.json` now includes its hash.
- Includes Valve's OpenVR header (`source/openvr/openvr.h`, BSD-3-Clause, unmodified). At runtime the boundary
  helper loads SteamVR's own `openvr_api.dll`.

## 1.1.2 (2026-11-02)
- Waits for a sleeping headset to wake before switching Meta over, and retries with Meta's normal runtime if needed.
- No more full-frame GPU readback every 1.5 s; SteamVR's pose log is trimmed so long sessions don't fill the disk.
- A Steam restart or update no longer ends the session; SteamVR works from any Steam library.
- Lighter watchdog, PresentMon for any game, the **Restoring…** status and the **Clear…** button.

## 1.1.1 (2026-11-01)
- Retries automatically when the headset is still waking up; game-neutral app UI; screenshot in the README.

## 1.1.0
- First public release: Oculus Rift S on Intel Arc (source, scripts, docs).
