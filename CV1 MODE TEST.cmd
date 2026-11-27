@echo off
echo ArcRift - Rift CV1 display mode test (experimental)
echo.
echo Use this when Start VR session stops with "Windows does not offer the Rift CV1
echo display mode". It finds out which display modes your graphics driver accepts for
echo the headset.
echo.
echo What it does (about 3 minutes):
echo   - shows Windows a few slightly different display descriptions (EDIDs) for the
echo     headset display only, one after another, and restarts that display each time;
echo   - writes down which ones make Windows offer 2160x1200;
echo   - puts everything back and checks that it is back.
echo Nothing is written to the headset. Your other displays are not changed, but
echo windows may move for a moment each time the headset display restarts.
echo.
echo Stay at the PC: if Windows does not take up a new description by itself, the
echo test window asks you to unplug the headset's HDMI cable and plug it back in
echo (up to a handful of times).
echo.
echo Before you continue: headset plugged in (USB, and HDMI straight into the Arc card),
echo Meta Horizon app open, no VR session running. Approve the administrator prompt.
echo.
pause
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cv1-mode-probe.ps1" %*
echo.
echo Send the cv1-mode-test-....txt file from this folder (it has no serial numbers).
pause
