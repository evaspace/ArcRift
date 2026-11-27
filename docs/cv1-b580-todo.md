# Rift CV1 on Arc B580 — log and TODO

Tracking what has been tried to get a **Rift CV1 (HDMI)** working on an **Intel Arc B580**, what worked, what was
ruled out, and what is left. Newest findings first in each section.

## Test machine
| Item | Value |
|---|---|
| GPU | Sparkle Intel Arc B580 Titan OC 12 GB (`VEN_8086&DEV_E20B`) |
| Driver | 32.0.101.9175 (earlier report: 32.0.101.9034) |
| Headset | Oculus Rift CV1, HDMI straight into the card, USB 3 |
| OS | Windows 11 Pro 25H2, build 26200 |
| CPU / board | Ryzen 5 5600, Gigabyte B550M DS3H R2 (ReBAR: to confirm) |
| ArcRift | 1.6 + fork branches `fix/cv1-probe-edid-name-length`, `chore/no-spaces-in-filenames` (merged in `dev`) |

## Status
- [x] Windows sees the CV1 as `OVR0004`, `\\.\DISPLAY2`, but only offers **1920x1080 @ 60 Hz** by itself.
- [x] Windows EDID override (registry `EDID_OVERRIDE`) **is applied** on the B580 (needs an HDMI re-plug, then a
      monitor restart).
- [x] The driver **offers and accepts 2160x1200 @ 90 Hz** with a wider horizontal blank (see results).
- [ ] The CV1 panel shows a picture with such a mode. **Never tried yet** (next step).
- [ ] An ArcRift session runs on the CV1 (Dash / desktop view / SteamVR).

## Results of `CV1-MODE-TEST` (27 Nov 2026, driver 32.0.101.9175)
CV1 native timing: 2160x1200 active, **80** blank columns (front 8, sync 32), **272** blank lines (front 50, sync 2),
296.75 MHz, 90 Hz.

| Variant | H blank | V blank | Clock | HDMI VSDB | 2160x1200@90 offered? |
|---|---|---|---|---|---|
| own (CV1 EDID) | 80 | 272 | 296.75 | – | ❌ |
| hdmi340 | 80 | 272 | 296.75 | 340 MHz | ❌ |
| hdmi300 | 80 | 272 | 297.00 | 300 MHz | ❌ |
| c297 | 80 | 272 | 297.00 | – | ❌ |
| 60hz | 80 | 272 | 197.84 (60 Hz) | – | ❌ |
| vb35 | 80 | 35 | 248.98 | – | ❌ |
| 59rb | 80 | 35 | 163.22 (59 Hz) | – | ❌ |
| hb100 | 100 | 272 | 299.40 | 340 MHz | ❌ |
| hb120 | 120 | 272 | 302.05 | 340 MHz | ❌ |
| **hb160** | **160** | **272** | **307.35** | 340 MHz | ✅ offered, mode test accepted |
| **rb** | **160** | **35** | **257.87** | – | ✅ offered, mode test accepted |

**Conclusion so far:** the driver needs a horizontal blank somewhere between **121 and 160** pixels. The pixel clock,
the 300/340 MHz limits, the HDMI VSDB and the vertical blank do **not** matter. `hb160` keeps the CV1's own 272
blank lines, so it is the closest accepted mode to the panel's native timing.

## Ideas ruled out
- **Bad cable / HDMI 1.4 clock cap** — 163 MHz with 80 columns is refused too; 307 MHz with 160 columns is fine.
- **Missing HDMI VSDB (TMDS 165 MHz cap)** — adding a CTA-861 VSDB with 300/340 MHz changes nothing.
- **Non-standard 296.75 MHz clock** — 297.00 MHz (`c297`, `hdmi300`) is refused the same way.
- **Long vertical blank (272 lines)** — accepted with 160 columns (`hb160`).
- **Intel IGCL driver-level EDID override (`arcrift_igcl_edid.exe`)** — every call returns `0x40000017`
  (`CTL_RESULT_ERROR_KMD_CALL`) on this driver, also as administrator. The Windows registry override works, so it
  is not needed. Kept as a fallback, but the probe now puts the Windows override back when IGCL fails.

## Bugs found and fixed in the fork
- EDID name truncated to 13 characters, so every applied override was reported "NOT picked up".
- Leftover IGCL override / stale cached EDID made the test stop with "not the expected Rift CV1 one".
- IGCL fallback removed the Windows override before failing, so every second variant was "NOT TESTED".
- Re-plug alone shows the headset's own EDID; one more monitor restart after it applies the override.
- Launchers renamed without spaces (`CV1-MODE-TEST.cmd`, …).

## To test next
1. [ ] **Find the exact minimum horizontal blank:** variants hb128, hb136, hb144, hb152 (keep 272 lines).
       Smaller = closer to the panel's native line timing.
2. [ ] **Does the limit come from HDMI audio / data islands?** Try 80 columns with a CTA-861 block that declares
       **no audio** (and/or plain DVI without a CTA block, already refused as `own`): depends on what Intel's
       display code requires (research running).
3. [ ] **Output test on the headset:** switch the CV1 to `hb160` (2320x1472 total, 307.35 MHz) for a few seconds and
       look inside: picture, black, or flicker? Needs a probe mode that outputs a non-native variant, and the session
       check in `test-ovr-d3d11.ps1` (`Get-ArcRiftCv1Override`: same totals, clock ±0.5 %) relaxed behind an opt-in.
4. [ ] **Desktop view in VR:** once the panel shows a picture, start `START-META-DASH.cmd` and open the desktop in
       Dash.
5. [ ] **SteamVR session** with a simple game.
6. [ ] **Linux route (same PC, dual boot):** Monado + OpenHMD Rift CV1 driver on Mesa/xe, where modes can be forced
       with a modeline. Check whether the Linux Intel driver has the same blanking limit.
7. [ ] Check that **Resizable BAR** is enabled in the BIOS (Arc performance).

## Ideas not tested
- DisplayPort → HDMI active adapter (the CV1 is HDMI only; would change which link limits apply).
- Older/newer Intel drivers (the A770 that works runs 32.0.101.9150).
- CRU (Custom Resolution Utility) instead of the script: same registry mechanism, unlikely to differ.

## Community report (draft for issue #1 on funrun45/ArcRift — not posted)
> GPU: Arc B580 (Sparkle Titan) · Driver: 32.0.101.9175 · Headset: **Rift CV1** (HDMI direct) · Windows 11 25H2
> (26200) · ArcRift 1.6 + fixes · Setup found headset: yes · Session started: not yet.
> CV1 MODE TEST: the B580 refuses the CV1's native 2160x1200@90 timing (80 blank columns). It offers it with a
> horizontal blank of 160 (with the CV1's own 272 blank lines, 307.35 MHz). 100 and 120 are refused. IGCL EDID
> calls fail with 0x40000017. Fixes for the probe are on https://github.com/evaspace/ArcRift (branch
> `fix/cv1-probe-edid-name-length`).
