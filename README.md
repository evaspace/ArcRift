# ArcRift 1.6: Oculus Rift S & Rift CV1 on Intel Arc

Free and open source (MIT). Community workaround to run **Oculus Rift S** (and experimental **Rift CV1**) with **Meta Horizon Link / Oculus Dash / Guardian** and **SteamVR** on **Intel Arc** GPUs. Not affiliated with or endorsed by Meta, Oculus, Intel, or Valve.

> **Experimental — use at your own risk.** While a session runs, ArcRift temporarily adjusts Windows display mode/EDID and Meta runtime settings, and restores everything cleanly when you stop. Read the safety rules below.

## What you need
- Windows 11 (recommended)
- An **Intel Arc** graphics card (tested on **Arc A770**; experimental **Arc B580 / B570 / A750 / A580 / A380** support included)
- **Oculus Rift S** (USB 3 + DisplayPort plugged straight into the Arc GPU) or **Oculus Rift CV1** (USB 3 + HDMI plugged straight into the Arc GPU, experimental)
- **Meta Horizon (Oculus)** PC app installed and open
- **Steam & SteamVR** (only required if using SteamVR mode; **not** required for Meta Dash / Guardian / Oculus-native apps)
- Microsoft Edge (built into Windows 11; hosts the ArcRift Control window)

## Quick start
1. **Unzip** this entire folder to a normal location (e.g., `Documents\ArcRift-1.6`). Keep all files together.
2. Open the **Meta Horizon** app with your headset plugged into the Intel Arc card and awake.
3. Open **ArcRift Control.exe** → **Setup** tab:
   - Follow the 3 steps (plugged in → unplugged → plugged back in) and click **Save**.
   - *(Rift CV1 / Arc B580 only: if your session says Windows does not offer `2160x1200 @ 90 Hz`, run `CV1-MODE-TEST.cmd` once before starting a session.)*
4. Go back to the **Dashboard** tab and launch:
   - **Start Meta Dash / Guardian** *(primary)* — runs Meta Horizon Link, Oculus Dash, Guardian setup, and Oculus apps natively on Intel Arc (or double-click `START-META-DASH.cmd`).
   - **Start VR session (SteamVR)** — runs SteamVR games with Dash suppressed (Steam must be running and signed in).
5. Approve the Windows administrator prompt and **leave the PowerShell window open**.
6. **When done:** quit your VR game, then click **Stop & restore** in **ArcRift Control.exe** (or double-click `STOP-AND-RESTORE.cmd`). Wait until rollback finishes (`ROLLBACK VERIFIED`) and the PowerShell window closes on its own.

## What's new in 1.6
- **Meta Dash & native Guardian working on Intel Arc:** Includes `dash-vulkan-flip.txt`, `dash-vulkan-semaphore-fix.txt`, and `vk-layer\arcrift_vk_layer.dll` out of the box (hides incompatible KMT semaphore/fence extensions and provides local fallback memory for failing KMT depth imports).
- **Redesigned ArcRift Control UI with 2 switchable themes:** Choose between **Arc Glass** and **Studio Minimal** in the top-right bar, with viewport-fitted scaling for 1080p–4K and 100%–150% Windows DPI. **Start Meta Dash / Guardian** is now the main launch button.
- **Lower VR latency & bridge optimizations:** `DXGI_SWAP_EFFECT_FLIP_DISCARD`, 1-frame waitable swapchain latency (`SetMaximumFrameLatency(1)`), Per-Monitor DPI Awareness v2, zero-syscall SEH `Present` path, thread-safe shared logging, and resilient signature scanning for Meta runtime updates.
- **Arc B580 & Rift CV1 improvements:** Includes Intel IGCL driver-level EDID override fallback (`arcrift_igcl_edid.exe`), 256-byte EDID support, and CTA-861 HDMI VSDB (`340 MHz` / `300 MHz`) timing tests in `CV1-MODE-TEST.cmd`.
- **Stability fixes:** Hidden `native_source_session.exe` helper window, full Meta crash/freeze/proximity watchdogs and GPU priority boost in Dash/Guardian sessions, and Steam no longer required for Dash/Guardian sessions.

## Safety rules
- **Never close the administrator PowerShell window or press `Ctrl+C`** during a session — always use **Stop & restore** (`STOP-AND-RESTORE.cmd`).
- **Never run two copies of ArcRift at the same time.**
- If a session is interrupted (crash, reboot, or closed window), plug in the headset and click **Recover** (or run `RECOVER.cmd`).

## Testing on Arc B580 / Rift CV1
- Run **CHECK-MY-PC.cmd** (or **Setup → Check my PC**) for a read-only compatibility report (`compat-report-*.txt`, serials masked).
- Run `tools\vk_layer_test\kmt_import_test.exe` to check whether your Arc driver imports D3D11 KMT color textures cleanly for Dash.
- For Rift CV1, run **CV1-MODE-TEST.cmd** if `2160x1200 @ 90 Hz` is missing from Windows display modes.

## Privacy
This release contains **no personal or machine data** (`arcrift-config.json` is generated on your PC during Setup, and `rift-s-native-test.edid` is a blank zero-serial placeholder rebuilt from your headset on each session). Before sharing logs from `d3d11-*` folders publicly, remove personal paths, PC names, and serial numbers.

## Licenses
MIT — see `LICENSE` and `NOTICE.md`.
