# ArcRift 1.5: Oculus Rift S on Intel Arc

by **funrun** · free and open source (MIT)

![ArcRift Control](docs/arcrift-control.png)

ArcRift runs an **Oculus Rift S** on an **Intel Arc** graphics card, a combination Meta does not support,
so you can play **SteamVR games** (tested with VRChat). It is a community workaround. It is not made or supported
by Meta, Oculus, Intel or Valve.

> **Experimental, use at your own risk.** While a session runs, ArcRift temporarily changes Windows display
> settings, Meta runtime settings and the Rift S display mode, and restores them afterwards. An early
> development version once caused desktop and headset image corruption. Read the safety rules below.

## What you need

- Windows 11
- An **Intel Arc** graphics card with the headset's DisplayPort connected to it.
  **Tested: Arc A770** (Intel driver 32.0.101.9150). Other Intel Arc cards (A750, A580, B580, B570 …) are
  allowed but **untested**; please report how it goes (see *Other Intel Arc cards* under Known issues).
- Oculus Rift S, plugged in (USB + DisplayPort)
- The **Meta Horizon** (Oculus) PC app and **SteamVR** (any Steam library folder works), with **Steam running and signed in**
  when you start a session
- Microsoft Edge (comes with Windows 11; used to show the app window)

## First-time setup

1. Keep this whole folder together, somewhere like `Documents\ArcRift`.
2. If the folder has no `arc_rift_bridge.dll` / `release-manifest.json` (for example a source-only download),
   run **BUILD-RELEASE.cmd** once. It needs the free *Visual Studio 2022 C++ Build Tools*.
3. Open **ArcRift Control.exe** → **Setup**. With the Meta Horizon app open and the headset light on,
   follow the 3 steps (plugged in → unplugged → plugged back in) and press **Save**.
   Setup records which display is your headset and which graphics card it is plugged into (if your PC has more than
   one, plug the headset into the Arc card). Start stays disabled until this is done.

## Playing

1. **Dashboard → Start VR session**, then approve the administrator prompt. A PowerShell window opens.
   **Leave it open**: it restores everything at the end. SteamVR starts automatically.
   If the headset has gone to sleep (it sat unused), the session says so and waits: put it on, or pick it up and
   move it, and it continues 10 s after the headset wakes.
2. When the status says **Running**, start your SteamVR game (for example from Steam in VR mode).
3. Optional: press **Proximity bypass…** and set *Bypass Proximity Sensor Check* to **On** (do this after Running;
   close the Debug Tool before stopping).
4. When you're done: quit the game, then press **Stop & restore** and wait until the session shows as restored.

## Safety rules

- **Never close the administrator PowerShell window** during a session.
- **Never run two copies of ArcRift at the same time.**
- If the PC was shut down or restarted during a session, or that window closed or crashed before cleanup finished,
  the app shows **Needs recovery**. Plug in the headset and just press **Start VR session**: it restores the last
  session automatically, then starts a new one. (Or press **Recover** to only restore it.) This also works when the
  unrestored session came from another ArcRift copy, such as an older release folder next to this one.
  If it shows **Restoring…**, automatic recovery is already running: just wait.
- If Recover finished but **Needs recovery** stays (usually because your monitor setup changed during the session),
  press **Clear…**. It changes nothing; it re-checks that the Meta settings, headset display mode and plugins are
  restored, then clears the warning. Check Windows display settings afterwards.
- If you see lag, smearing or garbled pixels, take the headset off and press **Stop & restore** right away.

## What a session does by itself

- Stops and restores everything on real trouble: the headset frame rate staying below 5 fps (fewer than 120 frames
  in 24 s, which includes a full freeze), the GPU device being lost or hung,
  Meta or SteamVR exiting, a Windows display-driver reset, or low disk space.
- Only notes SteamVR sync errors (a game running slowly) in `sync-hiccups.txt`; they never stop a session by themselves.
- Pauses the freeze check while the headset is off, and resumes it when you put it back on.
- Keeps Meta's tracking on while the headset is off, so Meta does not pause it and then crash when it starts again
  (see *Taking the headset off or putting it down* under Known issues).
- If Meta's runtime crashes, restores everything automatically within about 2 s and notes Meta's own crash report in
  `meta-crash.txt` in the session folder. Then it starts a fresh session by itself in a new window, with no
  administrator prompt: put the headset on, and when it says VR ready, start your game again. It doesn't restart
  after you pressed Stop & restore, if the restore wasn't verified, if Meta crashed within a minute of VR being
  ready, or after three automatic restarts in a row.
- If Meta's runtime stops responding for 30 s without crashing, restores everything automatically. Just before it
  does, it saves what the frozen runtime was doing (`meta-hang-threads.txt` and `meta-hang.dmp`, about 50 MB) in the
  session folder.
- Records frame timings with PresentMon (`presentmon.csv` in each session folder). Delete `PresentMon.exe`
  to turn this off.

## Room boundary

Meta's Guardian cannot be set up on Intel Arc. Its setup screen is part of Meta's Dash, and Dash draws with Vulkan,
which Meta does not support on Arc cards: tested on an A770, Dash quits on every launch ("Failed to configure
Rendering Code: -4"). Only Meta's software can use the Rift S cameras, so there is no room view either. Instead,
ArcRift draws the boundary itself. There are two ways to make one.

**Quick box (no controller needed):** while the session shows **Running**, pick a size next to **Box around me**
(width × depth, 1.5 × 1.5 m up to 4 × 3 m) and press it. You have 10 seconds: put the headset on, stand in the
middle of your play space and face forward. Two beeps mean a box of that size is placed around you, lined up with
the way you face. The box also becomes SteamVR's play area: its centre becomes the centre of your play space and the
way you faced becomes forward, so games get the full box (before 1.3 they only got the part of it that fitted around
SteamVR's old centre). If SteamVR does not accept that, the box is placed as before and `boundary-log.txt` says so.

**Traced outline (exact shape):**

1. While the session shows **Running**, clear your play space and press **Draw boundary** in the *Room boundary* card.
2. Wear the headset pushed up on your forehead, cameras facing forward: you see the room under it, and its cameras
   still track your controller.
3. At the edge of your play space, **hold the trigger** on either controller and trace the edge at waist height
   while you walk around it. The controller buzzes as it records. Letting go early just pauses.
4. Come back to where you started, or let go once you have gone all the way round (at least 3 m). Two beeps mean
   it is saved. (**Finish now** ends early with what was recorded.)

Remember the exact spot where you first pulled the trigger and which way the controller pointed (tape on the floor
or a table corner works well). Cyan grid walls fade in when your head or hands get within about 75 cm of an edge, and
SteamVR games get the play area. Without Guardian, the Rift S forgets the room between sessions, so each new session
starts with no boundary: press **Use saved boundary** and follow what it says (for a box: stand in the middle facing
the same way; for a traced outline: hold a controller on your starting spot pointing the same way and pull the
trigger). Or just make it again. If a boundary does not appear or a trigger press is not picked up, `boundary-log.txt`
records what SteamVR saw (controllers, tracking, headset height).
**Remove boundary** takes it away and puts back SteamVR's previous boundary data. No
Meta or SteamVR settings are changed, and Meta's SteamVR driver replaces the boundary data with its own placeholder
every time SteamVR starts.

## Known issues

- **First start after the headset sat unused:** Meta looks for the headset display only once, when its runtime
  starts, and a sleeping headset has none. Since 1.1.2 the session waits for the headset to wake first, and if Meta
  still misses the display it wakes the headset with Meta's normal runtime and retries once.

- **Other Intel Arc cards (B580 and others) are still untested.** One report from an Arc B580 on Windows 10: the
  headset stayed at 1920x1080 at 60 Hz because the temporary Rift S display mode was not picked up, so the session
  stopped and restored. There is no fix for that yet. Since 1.3 a session waits up to 45 s for the mode, finds the
  headset's graphics card by where it is plugged in (PCs with processor graphics plus an Arc card), and writes
  `system-info.txt` (card, driver, Windows build) into the session folder. If it fails on your card, please send
  that file with `transcript.txt` and the `physical-display-*.txt` files.

- **Testers wanted (other Arc cards, Rift CV1).** Run **CHECK MY PC.cmd** and send the `compat-report-….txt` it
  writes. It only reads: nothing on the PC is changed, no session is started, and no administrator rights are
  needed. The report says which graphics card and driver you have, how Windows presents the headset display
  (normal display, hidden head-mounted display, or not there), which display modes Windows offers for it, the
  headset display's EDID and the Meta runtime's lines about the headset. Serial numbers are masked and other monitors are listed by model only; please still
  read it before posting it publicly.

- **Rift CV1: experimental and unconfirmed.** A CV1 (HDMI) can be set up and started like a Rift S, but no CV1
  session has worked yet and the developer has no CV1 to test with. A CV1 session writes no EDID: it only asks
  Windows to switch the headset display to its own mode (2160x1200 at 90 Hz) and back. If Windows does not offer
  that mode on your card, the session stops before changing anything and says so. Plug the HDMI cable straight
  into the Arc card (no adapter) and the headset's USB into a USB 3 port. Whatever happens, please send
  `transcript.txt`, `bridge-log.txt` and `headset-modes-offered.txt` from the newest `d3d11-…` folder.
  **If the session says Windows does not offer the Rift CV1 display mode** (seen on an Arc B580), run
  **CV1 MODE TEST.cmd** (about 3 minutes, needs administrator approval). It tries a few temporary display
  descriptions on the headset display only, puts everything back, and writes `cv1-mode-test-….txt` (no serial
  numbers): please send that file. If it finds one that works it saves `cv1-override.edid`, and the next session
  uses it. That file contains your headset serial; don't post it.

- **Taking the headset off or putting it down:** about 20 s after the headset comes off and sits still, Meta pauses
  tracking, and starting it again when the headset moves can crash Meta's runtime. Since 1.5 a session tells Meta to
  keep tracking on the whole time (Meta's own `ForceSensorTracking` setting, taken away again when the session
  restores). The session window says "Tracking stays on while the headset is off" once Meta has confirmed it. The
  headset display still switches off when you take it off; only the cameras and tracking keep running.
  **Not yet confirmed in a real session.** If Meta's runtime crashes anyway, ArcRift notices within a couple of
  seconds, restores, and starts a fresh session by itself; your game loses VR and needs starting again. The Debug
  Tool's proximity bypass does **not** stop the pause (tested 15 Nov with the bypass on and the Debug Tool open).
  Covering the headset's proximity sensor does, because Meta never pauses while it thinks the headset is worn; the
  display then stays lit, so keep the lenses out of sunlight and remove the cover afterwards. Why Meta's runtime
  crashes when tracking starts again is not known. Meta saves its own crash report in
  `%LOCALAPPDATA%\Oculus\OVRServerBreakpad`, and the session folder gets `meta-crash.txt` saying which one it is.
  The report holds your Meta user ID, so don't post it publicly.
- **Busy VRChat worlds** are mostly limited by the CPU: lower *Maximum Shown Avatars*, hide *Very Poor* avatars,
  and enable the particle limiter.
- **No ASW:** Meta's frame smoothing (ASW) does not run on Intel Arc.
- The upstream project this builds on warns that Meta's runtime can, rarely, need a PC restart.

## Folder contents

| Item | Purpose |
|---|---|
| `ArcRift Control.exe` | The app: status, start/stop, recovery, setup |
| `START MANUAL SESSION.cmd`, `STOP AND RESTORE.cmd`, `RECOVER.cmd` | The same actions without the app |
| `CHECK MY PC.cmd`, `compat-report.ps1` | Read-only compatibility report for testers (see Known issues) |
| `test-ovr-d3d11.ps1` and the other `.ps1` files | The session script that sets up, guards and restores |
| `display-mode.ps1` | Reads and switches one display's Windows mode (Rift CV1 sessions only) |
| `CV1 MODE TEST.cmd`, `cv1-mode-probe.ps1` | Rift CV1 only: finds a display mode the graphics driver accepts (see Known issues) |
| `cv1-override.edid` | Written by CV1 MODE TEST when it finds a working mode; contains the headset serial |
| `arc_rift_bridge.dll`, `native_source_*.exe`, `display_probe.exe`, `bridge_selftest.exe`, `arcrift_boundary.exe` | Bridge and helpers (built by `BUILD-RELEASE.cmd`) |
| `boundary-saved.txt`, `boundary-status.json`, `boundary-log.txt` | Your saved room boundary and the boundary helper's status/log |
| `release-manifest.json` | SHA-256 of each program; a session refuses to start if any differs |
| `rift-s-native-test.edid` | The Rift S display mode applied during a session |
| `arcrift-config.json`, `arcrift-identity.txt` | Written by Setup / the session: your headset and GPU |
| `source\`, `app-source\` | Full source code |
| `d3d11-…` folders | One per session: logs, frame timings, cleanup results |

## Privacy

Session folders (`d3d11-…`), `arcrift-config.json` and `arcrift-identity.txt` contain device IDs, and
Meta's logs contain your headset serial. **Don't post them publicly**; when asking for help, share only
the lines you need. `meta-hang.dmp` is a copy of part of the Meta runtime's memory and can hold account details:
never post it publicly.

## Licences and credits

MIT, copyright (c) 2026 funrun (`LICENSE`). Builds on Bnuuy Solutions' OculusDirectDisplayAdditions (MIT).
Full credits, third-party licences and the trademark notice are in `NOTICE.md`.
Not affiliated with or endorsed by Meta, Oculus, Intel or Valve.
