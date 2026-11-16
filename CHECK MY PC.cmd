@echo off
echo ArcRift compatibility check - read-only, changes nothing on this PC.
echo.
echo Before you continue:
echo   1. Plug in the headset: USB, and its display cable into the Intel Arc card
echo      (Rift S: DisplayPort. Rift CV1: HDMI, plus at least one sensor).
echo   2. Open the Meta Horizon (Oculus) PC app.
echo   3. Put the headset on for a few seconds so it wakes up, then take it off.
echo.
pause
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0compat-report.ps1"
echo.
echo Send the compat-report-....txt file from this folder. Serial numbers are masked,
echo but please read it once before posting it anywhere public.
pause
