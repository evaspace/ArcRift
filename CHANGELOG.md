# Changelog

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
