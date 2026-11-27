# Contributing to ArcRift

## File and folder names: no spaces
Every file and folder in this repository is named **without spaces**, so it can be typed or pasted in
PowerShell, cmd and scripts without quotes.

- Launchers users double-click: `UPPER-CASE-WITH-DASHES.cmd` (e.g. `CV1-MODE-TEST.cmd`, `STOP-AND-RESTORE.cmd`).
- Scripts, sources, data files and folders: `lower-case-with-dashes` or `lower_snake_case`, following the
  neighbouring files (e.g. `cv1-mode-probe.ps1`, `arcrift_igcl_edid.cpp`, `vk-layer/`).
- When you rename a file, update every reference to it (`git grep` the old name), including user-facing
  messages in `.ps1` scripts and the README.

## Testing
Changes that touch the headset display, the Meta runtime or a VR session must be run on real hardware
(see "Testing on Arc B580 / Rift CV1" in the README). Say in the pull request which GPU, driver and
headset you tested with, and attach the report the script wrote (they contain no serial numbers).
