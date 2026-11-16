# One bounded integration attempt. Run elevated; never an installation script.
param([switch]$Visual, [switch]$NativeTiming, [switch]$LinkDiagnostics, [switch]$NativeSource, [switch]$Stereo, [switch]$TrackedScene, [switch]$SteamVR,
    [ValidateRange(15,600)][int]$SteamVRSeconds = 30, [switch]$IsolatedHeadsetTrial, [switch]$LegacyCheckpointTrial, [switch]$NoReadbackSteamTrial, [switch]$UserLaunchSteamTrial, [switch]$StartupIdentityHeadsetTrial, [switch]$LegacyCheckpointSteamTrial, [switch]$OriginalSteamVRBaselineTrial, [switch]$DashboardSameIntegrityTrial, [switch]$DashboardNormalUserTrial, [switch]$VRChatTrial, [switch]$ManualSession, [switch]$GuardianSetup,
    [ValidateRange(0,3)][int]$AutoRestartCount = 0, [int]$WaitForHarnessPid = 0)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location -LiteralPath $root
$harnessScript = $PSCommandPath  # this file, for an automatic restart
$harnessParameters = @{}  # this session's switches, so an automatic restart can pass on the same ones
foreach ($kv in $PSBoundParameters.GetEnumerator()) { $harnessParameters[$kv.Key] = $kv.Value }
# Release 1.4: turn off QuickEdit for this window only. With it on, one click in the window starts a text selection
# and PowerShell then blocks on its next line of output until the selection is cleared, freezing every guard. Seen
# 2026-11-15: the loop stopped for 11 minutes on "Headset on" and missed a Meta crash and a Stop & restore.
try {
    Add-Type -Namespace ArcRift -Name ConsoleMode -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int which); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);'
    $consoleIn = [ArcRift.ConsoleMode]::GetStdHandle(-10)
    [uint32]$consoleInMode = 0
    if ([ArcRift.ConsoleMode]::GetConsoleMode($consoleIn, [ref]$consoleInMode)) {
        # ENABLE_EXTENDED_FLAGS (0x80) must be set for the QuickEdit bit (0x40) to be changed.
        [void][ArcRift.ConsoleMode]::SetConsoleMode($consoleIn, (($consoleInMode -bor 0x80) -band (-bnot 0x40)))
    }
} catch {}
if ($WaitForHarnessPid -gt 0) {
    # Release 1.4 automatic restart: the session that started this one must finish exiting (it has already restored
    # and released the folder lock), and SteamVR must be gone, or the start-up checks below refuse to run.
    Write-Host 'Automatic restart after a Meta runtime crash: waiting for the previous session window to close...'
    try { $previousHarness = Get-Process -Id $WaitForHarnessPid -ErrorAction SilentlyContinue; if ($previousHarness) { [void]$previousHarness.WaitForExit(120000) } } catch {}
    $steamVRGoneBy = (Get-Date).AddSeconds(30)
    while ((Get-Process vrserver,vrcompositor,vrmonitor -ErrorAction SilentlyContinue) -and (Get-Date) -lt $steamVRGoneBy) { Start-Sleep -Milliseconds 500 }
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $root ('d3d11-' + $stamp)
New-Item -ItemType Directory -Path $out | Out-Null
$registry = @()
$moves = @()
$createdKeys = @()
$virtualDisabled = $false
$changed = $false
$client = $null
$sourceHelper = $null
$steamStarted = $false
# Release 1.1.2: install folders are looked up (install-paths.ps1) during the identity checks below.
$steamPath = $null
$steamRoot = $null
$steamBin = $null
$metaRuntime = $null
$start = Get-Date
$failed = $false
$metaCrashAt = $null  # set when the session stops because Meta's runtime crashed (decides the automatic restart)
$edidChanged = $false
# Release 1.4 (Rift CV1): the display mode a CV1 session switches to, and whether it has switched.
$modeSwitch = $null
$modeChanged = $false
$sessionLock = $null
$activeSession = Join-Path $root 'active-test.xml'
$sessionLockPath = Join-Path $root 'active-test.lock'
$bridgeName = 'arc_rift_bridge.dll'
$bridgeLogName = 'arc-rift-bridge.log'
$userStopRequested = $false
[long]$bridgeLogOffset = 0
$candidateLogTail = ''
$isolatedRendererTrial = $IsolatedHeadsetTrial -or $StartupIdentityHeadsetTrial
$shortHeadsetTrial = $isolatedRendererTrial -or $LegacyCheckpointTrial
$guardedSteamTrial = $NoReadbackSteamTrial -or $LegacyCheckpointSteamTrial
$guardedTrial = $shortHeadsetTrial -or $guardedSteamTrial
[long]$steamGraphicsOffset = 0
$steamGraphicsTail = ''
$syncHiccupTimes = New-Object System.Collections.Generic.List[datetime]
$syncFloodSince = $null
$bridgeFpsPrevTick = $null
$bridgeFpsPrevFrame = $null
$bridgeLowFpsCount = 0
$headsetOff = $false
$headsetOffSince = $null
$metaLogPath = $null
$trackingForcedChecked = $false  # 1.4: said once whether Meta confirmed ForceSensorTracking
$trackingPauseWarned = $false    # 1.4: said once that Meta paused tracking anyway
[long]$metaLogOffset = 0
$metaLogCheckAt = Get-Date
$metaLastGrowth = Get-Date
$metaCrashDir = Join-Path $env:LOCALAPPDATA 'Oculus\OVRServerBreakpad'
$metaCrashKnown = $null
$metaCrashCheckAt = Get-Date
$presentMonProcess = $null
$steamGraphicsLog = $null
$presentMonGames = @('VRChat.exe')
$presentMonFiles = 0
$nextGameCheck = Get-Date
[long]$vrserverLogOffset = 0
$verifiedParticipantIds = @{}
$script:ArcRiftSteamWorkerProcess = $null
$startupSeed = Join-Path $root 'arc_rift_bridge_startup.dll.identity'
$startupSeedOwned = $false
$dashboardTrialState = $null
$bootstrapServerId = $null
$bootstrapCompositorId = $null
$script:ArcRiftSteamWorkerStartupState = $null
$vrchatWarnings = @{}
$vrchatObservedPids = @{}
$recoveryWatcher = $null
$rollbackVerified = $false
$manualRecoveryFile = Join-Path $out 'manual-recovery-state.json'
$manualDiskCheckAt = Get-Date
# Release 1.1: headset/GPU identity comes from Setup (arcrift-config.json), not from fixed IDs.
$arcConfigError = $null
$gpuNote = $null
$monitorInstance = ''
$targetId = 0
# Release 1.4: what is specific to one headset model lives in a profile instead of being written out through the
# script. Setup may save "headsetProfile" in arcrift-config.json; a config without it is a Rift S, as before.
#   Width/Height/PixelClock: the one display mode a session may apply and must then see on the cable.
#   EdidId: how display_probe.exe prints that EDID's maker and product (d23e = OVR).
#   OwnEdid: $false = the headset shows a placeholder display, so a session gives it a temporary EDID (Rift S).
#            $true  = the headset's own EDID already holds its real mode and serial, so a session only switches
#                     Windows to that mode and back; no EDID is written (Rift CV1).
#   Cable: what the headset's display cable is called in messages.
# The Rift CV1 profile is EXPERIMENTAL: it is built from one tester's compatibility report (Arc B580, HDMI) and no
# CV1 session has been confirmed yet. A CV1 session checks that Windows offers the mode before it changes anything.
$headsetProfiles = @{
    'rift-s' = @{ Name = 'Rift S'; Width = 1440; Height = 2560; PixelClock = 571570000; Hz = 80; EdidId = 'd23e:0012'; OwnEdid = $false; Cable = 'DisplayPort' }
    'rift-cv1' = @{ Name = 'Rift CV1'; Width = 2160; Height = 1200; PixelClock = 296750000; Hz = 90; EdidId = 'd23e:0004'; OwnEdid = $true; Cable = 'HDMI' }
}
$headsetProfile = $headsetProfiles['rift-s']
# The display mode in an EDID's first detailed timing, as display_probe.exe reports a signal.
function Get-ArcRiftEdidMode([byte[]]$Edid) {
    $w = [int]$Edid[56] + (([int]$Edid[58] -band 240) * 16)
    $h = [int]$Edid[59] + (([int]$Edid[61] -band 240) * 16)
    return [pscustomobject]@{
        Width = $w; Height = $h
        TotalWidth = $w + [int]$Edid[57] + (([int]$Edid[58] -band 15) * 256)
        TotalHeight = $h + [int]$Edid[60] + (([int]$Edid[61] -band 15) * 256)
        PixelClock = ([int]$Edid[54] + 256 * [int]$Edid[55]) * 10000
    }
}
# Release 1.4 (Rift CV1): from the modes Windows offers for the headset display ("width height hertz" strings), the
# profile's mode at the refresh rate closest to the profile's (Windows may list 89.998 Hz as 89 or 90); $null if none.
function Select-ArcRiftHeadsetMode([string[]]$Offered) {
    $fit = @($Offered | Where-Object { $_ } | ForEach-Object { $p = $_ -split ' '; [pscustomobject]@{ W = [int]$p[0]; H = [int]$p[1]; Hz = [int]$p[2] } } |
        Where-Object { $_.W -eq $headsetProfile.Width -and $_.H -eq $headsetProfile.Height -and $_.Hz -ge ($headsetProfile.Hz - 1) -and $_.Hz -le ($headsetProfile.Hz + 1) } |
        Sort-Object { [math]::Abs($_.Hz - $headsetProfile.Hz) }, { -$_.Hz })
    if ($fit.Count) { return $fit[0] }
    return $null
}
# Release 1.4 (Rift CV1): the temporary EDID that "CV1 MODE TEST.cmd" found to work on this PC (cv1-override.edid).
# It is only accepted when it is this headset's own EDID with nothing changed that the headset could notice: same
# maker, product and serial, same picture size, same line and frame layout, and a pixel clock within 0.5 %.
function Get-ArcRiftCv1Override([string]$Path, [byte[]]$Own) {
    $o = [IO.File]::ReadAllBytes($Path)
    $sum = 0; foreach ($b in $o) { $sum += $b }
    if ($o.Length -ne 128 -or ($sum % 256) -ne 0) { throw 'cv1-override.edid is damaged. Delete it and run "CV1 MODE TEST.cmd" again. No changes made.' }
    $ownMode = Get-ArcRiftEdidMode $Own
    $newMode = Get-ArcRiftEdidMode $o
    $sameHeadset = $true
    foreach ($i in ((8..15) + (90..107))) { if ($o[$i] -ne $Own[$i]) { $sameHeadset = $false } }
    if (-not $sameHeadset -or $newMode.Width -ne $ownMode.Width -or $newMode.Height -ne $ownMode.Height -or $newMode.TotalWidth -ne $ownMode.TotalWidth -or $newMode.TotalHeight -ne $ownMode.TotalHeight -or [math]::Abs($newMode.PixelClock - $ownMode.PixelClock) -gt ($ownMode.PixelClock * 0.005)) {
        throw 'cv1-override.edid is not for this headset, or changes more than a session allows. Delete it and run "CV1 MODE TEST.cmd" again. No changes made.'
    }
    return ,$o
}
try {
    $arcConfigPath = Join-Path $root 'arcrift-config.json'
    if (-not (Test-Path -LiteralPath $arcConfigPath)) { throw 'No headset setup found. Run Setup in ArcRift Control first (arcrift-config.json is missing).' }
    $arcConfig = Get-Content -LiteralPath $arcConfigPath -Raw | ConvertFrom-Json
    $monitorInstance = [string]$arcConfig.monitorInstance
    $targetId = [int]$arcConfig.targetId
    $profileName = ([string]$arcConfig.headsetProfile).Trim().ToLowerInvariant()
    # Setup does not save a profile yet. A headset display that identifies itself as OVR0004 is a Rift CV1; anything
    # else (the Rift S placeholder display) is a Rift S, as before.
    if (-not $profileName) { $profileName = if ($monitorInstance -match '^(?i)DISPLAY\\OVR0004\\') { 'rift-cv1' } else { 'rift-s' } }
    if (-not $headsetProfiles.ContainsKey($profileName)) { throw ('This ArcRift version has no headset profile called "' + $profileName + '" (arcrift-config.json). Supported: ' + (($headsetProfiles.Keys | Sort-Object) -join ', ') + '. No changes made.') }
    $headsetProfile = $headsetProfiles[$profileName]
    $gpuMatch = [regex]::Match([string]$arcConfig.gpuPnpMatch, '(?i)VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})')
    if ($monitorInstance -notmatch '^(?i)DISPLAY\\[^\\]+\\[^\\]+$' -or $targetId -le 0 -or -not $gpuMatch.Success) { throw 'arcrift-config.json is incomplete. Run Setup in ArcRift Control again.' }
    if ($gpuMatch.Groups[1].Value -ne '8086') { throw 'The GPU saved by Setup is not an Intel GPU; this release only supports Intel Arc.' }
    $identityLines = @(('target=' + $targetId), ('monitor=' + ($monitorInstance -replace '\\', '#') + '#'), ('gpu=' + $gpuMatch.Groups[1].Value + ':' + $gpuMatch.Groups[2].Value))
    # Release 1.3 (other Intel cards): the bridge only accepts the graphics card the headset is really plugged into, by
    # its exact device ID. Setup used to guess that card by name, which can pick the wrong one on a PC with two Intel
    # adapters (processor graphics plus an Arc card). Windows knows the answer: the headset monitor's parent device is
    # the card it is plugged into. Read-only; if it cannot be read, the card saved by Setup is used as before.
    $gpuProblem = $null
    try {
        $headsetAdapter = [string](Get-PnpDeviceProperty -InstanceId $monitorInstance -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data
        $adapterMatch = [regex]::Match($headsetAdapter, '(?i)VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})')
        if ($adapterMatch.Success) {
            $adapterId = ($adapterMatch.Groups[1].Value + ':' + $adapterMatch.Groups[2].Value).ToUpperInvariant()
            $savedId = ($gpuMatch.Groups[1].Value + ':' + $gpuMatch.Groups[2].Value).ToUpperInvariant()
            if ($adapterMatch.Groups[1].Value -ne '8086') {
                $gpuProblem = 'The headset is plugged into a graphics card that is not an Intel card (' + $adapterId + '). Plug its DisplayPort cable into the Intel Arc card, then run Setup again. No changes made.'
            } elseif ($adapterId -ne $savedId) {
                $identityLines += ('gpu=' + $adapterId)
                $gpuNote = 'Note: the headset is plugged into Intel graphics device ' + $adapterId + ', but Setup saved ' + $savedId + '. Using the card it is plugged into. Run Setup again to update the saved card.'
            }
        }
    } catch { }
    if ($gpuProblem) { throw $gpuProblem }
    Set-Content -LiteralPath (Join-Path $root 'arcrift-identity.txt') -Value $identityLines -Encoding Ascii
    # Rift S display mode (EDID) for this headset: public Rift S capture timings + this headset's serial,
    # which Meta uses to pair the display with the headset. Rebuilt every session; never flashed to hardware.
    if ($headsetProfile.OwnEdid) {
        # Rift CV1: the headset display's own EDID, exactly as Windows read it from the headset (its first 128 bytes).
        # It already holds the real mode and the serial Meta pairs the display with, so nothing is made up here and
        # nothing is written to the headset or to Windows. The bridge hands these bytes to Meta.
        $ownEdid = $null
        try { $ownEdid = [byte[]](Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $monitorInstance + '\Device Parameters') -Name EDID -ErrorAction Stop).EDID } catch { }
        if (-not $ownEdid -or $ownEdid.Length -lt 128) { throw ('Windows has no EDID stored for the ' + $headsetProfile.Name + ' display. Plug the headset in (USB and ' + $headsetProfile.Cable + '), then run Setup again. No changes made.') }
        $edidBytes = [byte[]]::new(128)
        [Array]::Copy($ownEdid, $edidBytes, 128)
        $edidSum = 0; for ($i = 0; $i -lt 128; $i++) { $edidSum += $edidBytes[$i] }
        $ownMode = Get-ArcRiftEdidMode $edidBytes
        if (($edidSum % 256) -ne 0 -or $edidBytes[8] -ne 0x3e -or $edidBytes[9] -ne 0xd2 -or $ownMode.Width -ne $headsetProfile.Width -or $ownMode.Height -ne $headsetProfile.Height -or $ownMode.PixelClock -ne $headsetProfile.PixelClock) {
            throw ('The headset display''s own EDID is not the expected ' + $headsetProfile.Name + ' one (' + $headsetProfile.Width + 'x' + $headsetProfile.Height + ', pixel clock ' + $headsetProfile.PixelClock + '); found ' + $ownMode.Width + 'x' + $ownMode.Height + ', pixel clock ' + $ownMode.PixelClock + '. No changes made.')
        }
    } else {
    $serial = ([string]$arcConfig.headsetSerial).Trim()
    if ($serial -notmatch '^[A-Za-z0-9]{6,32}$') { throw 'The headset serial number is missing. Run Setup again with the Meta Horizon app open and the headset connected.' }
    $edidTemplate = '00ffffffffffff003ed2120000000000011d0104a50000000e000000000000000000000000000101010101010101010101010101010145dfa0385100eea5d20cf10c000000000010000000ff0030303030303030303030303030000000fc005269667420530a20202020202000000010000000000000000000000000000000e6'
    $edidBytes = [byte[]]::new(128)
    for ($i = 0; $i -lt 128; $i++) { $edidBytes[$i] = [Convert]::ToByte($edidTemplate.Substring($i * 2, 2), 16) }
    $serialText = if ($serial.Length -ge 13) { $serial.Substring($serial.Length - 13) } else { $serial + "`n" + (' ' * (12 - $serial.Length)) }
    $serialBytes = [Text.Encoding]::ASCII.GetBytes($serialText)
    for ($i = 0; $i -lt 13; $i++) { $edidBytes[77 + $i] = $serialBytes[$i] }
    $edidSum = 0; for ($i = 0; $i -lt 127; $i++) { $edidSum += $edidBytes[$i] }
    $edidBytes[127] = [byte]((256 - ($edidSum % 256)) % 256)
    } # end of the Rift S (temporary EDID) branch
    [IO.File]::WriteAllBytes((Join-Path $root 'rift-s-native-test.edid'), $edidBytes)
    . (Join-Path $root 'install-paths.ps1')
    $metaRuntime = Get-ArcRiftMetaRuntimePath
    if ($SteamVR) {
        $steamPath = Get-ArcRiftSteamPath
        $steamRoot = Get-ArcRiftSteamVRPath $steamPath
        $steamBin = Join-Path $steamRoot 'bin\win64'
        $steamGraphicsLog = Join-Path $steamPath 'logs\vrcompositor.txt'
    }
} catch { $arcConfigError = $_.Exception.Message }
$monitorParent = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $monitorInstance + '\Device Parameters'
$edidKey = $monitorParent + '\EDID_OVERRIDE'
# Release 1.3 (other Intel cards): how display_probe.exe output is read.
#  * A display path is active when bit 0 of its flags is set. The flags are printed in hex, and Windows can set more
#    bits on newer builds and other cards; matching the text "pathFlags=1" made such an active display look inactive.
#  * The headset is matched by its monitor device path as well as its target ID: two graphics adapters (processor
#    graphics plus an Arc card) can use the same target ID for different monitors.
$activePathFlags = 'pathFlags=[0-9a-fA-F]*[13579bdfBDF] '
$headsetPathId = (($monitorInstance -replace '\\', '#') + '#').ToLowerInvariant()
function Get-ActiveLayouts([string]$Text) {
    $layouts = @{}
    $pattern = '(?m)^\s*target=(\d+) [^\r\n]*' + $activePathFlags + '[^\r\n]*\r?\n([^\r\n]*)\r?\n\s*(signal=[^\r\n]+)\r?\n\s*(source=[^\r\n]+)'
    foreach ($m in [regex]::Matches($Text, $pattern)) {
        $path = [regex]::Match($m.Groups[2].Value, 'path=(\S+)')
        $key = $m.Groups[1].Value
        if ($path.Success) { $key += '|' + $path.Groups[1].Value.ToLowerInvariant() }
        $layouts[$key] = $m.Groups[3].Value.Trim() + ' ' + $m.Groups[4].Value.Trim()
    }
    if ($layouts.Count -eq 0) { throw 'No active display layouts parsed.' }
    return $layouts
}
# The key of the headset's entry in a Get-ActiveLayouts result, or $null when the headset from Setup is not active.
function Get-ArcRiftHeadsetLayoutKey($Layouts, [int]$Target) {
    foreach ($key in $Layouts.Keys) {
        if ($key.StartsWith([string]$Target + '|') -and $key.Contains($headsetPathId)) { return $key }
    }
    return $null
}
# Release 1.2: one-line description of the headset display in a display_probe.exe capture, for when the native mode
# did not appear. On a working PC the headset shows name=Rift S, EDID=d23e:0012 (ArcRift's temporary EDID) and
# signal=1440x2560; the original generic EDID means Windows never picked up the temporary display mode.
function Get-ArcRiftHeadsetModeReport([string]$Probe, [int]$Target, [bool]$OverridePresent) {
    $m = [regex]::Match($Probe, '(?m)^\s*target=' + $Target + ' [^\r\n]*' + $activePathFlags + '[^\r\n]*\r?\n\s*name=([^\r\n]*?) path=[^\r\n]*?(?i:' + [regex]::Escape($headsetPathId) + ')[^\r\n]*?EDID=(\S+)\s*\r?\n\s*signal=(\S+)[^\r\n]*?vSync=(\d+)/(\d+)')
    $override = if ($headsetProfile.OwnEdid -and -not $useTemporaryEdid) { 'this headset uses its own EDID, so only the Windows display mode was switched' } elseif ($OverridePresent) { 'temporary EDID is still set' } else { 'temporary EDID is missing from the registry' }
    if (-not $m.Success) { return ('headset display is not active in Windows; ' + $override) }
    $hz = if ([double]$m.Groups[5].Value) { [math]::Round([double]$m.Groups[4].Value / [double]$m.Groups[5].Value, 1) } else { 0 }
    $signal = $m.Groups[3].Value + ' at ' + $hz + ' Hz'
    $name = if ($m.Groups[1].Value) { $m.Groups[1].Value } else { 'no name' }
    if ($headsetProfile.OwnEdid) { return ('the ' + $headsetProfile.Name + ' display (' + $name + ') runs at ' + $signal + '; ' + $override) }
    if ($m.Groups[2].Value -eq $headsetProfile.EdidId) { return ('Windows uses the temporary ' + $headsetProfile.Name + ' EDID (' + $name + ') but the headset runs at ' + $signal + '; ' + $override) }
    return ('Windows still shows the original headset EDID ' + $m.Groups[2].Value + ' (' + $name + ') at ' + $signal + ', so the temporary display mode was not picked up; ' + $override)
}
function Stop-ArcRiftMetaRuntime([int]$TimeoutSeconds = 20) {
    # Stop Meta's runtime without waiting forever: if it hangs, end its processes so rollback can continue.
    $null = & sc.exe stop OVRService
    $svcDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Service OVRService).Status -ne 'Stopped' -and (Get-Date) -lt $svcDeadline) { Start-Sleep -Milliseconds 500 }
    if ((Get-Service OVRService).Status -ne 'Stopped') {
        Write-Output ('Meta runtime did not stop within ' + $TimeoutSeconds + 's; ending its processes so rollback can continue.')
        Get-Process OVRServer_x64,OVRServiceLauncher -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $svcDeadline = (Get-Date).AddSeconds(15)
        while ((Get-Service OVRService).Status -ne 'Stopped' -and (Get-Date) -lt $svcDeadline) { Start-Sleep -Milliseconds 500 }
    }
    if ((Get-Service OVRService).Status -ne 'Stopped') { throw 'Meta runtime service could not be stopped.' }
}
function Get-ArcRiftHeadsetWake([datetime]$NotBefore = [datetime]::MinValue) {
    # From Meta's newest log: is the headset awake, and since when? 'HMD unavailable' means it went to sleep after
    # sitting unused; proximity 0 -> 1 or 'HMD mounted' after that means it woke. No log at all counts as Unknown.
    $log = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Oculus') -Filter 'Service_*.txt' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $log) { return [pscustomobject]@{State='Unknown'; Since=[datetime]::MinValue} }
    [long]$fromStart = 0
    $text = Read-AppendedBridgeLog $log.FullName ([ref]$fromStart)
    $started = $null; $asleep = $null; $woke = $null
    $pattern = '(?m)^(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3}) [^\r\n]*?(Starting Oculus Runtime Service|Broadcasting HMD unavailable event|Proximity state changed \(0 -> 1\)|Broadcasting HMD mounted event)'
    foreach ($m in [regex]::Matches($text, $pattern)) {
        $g = $m.Groups
        # Meta writes day/month, e.g. "02/11 11:06:25.841" for 2 November.
        $t = [datetime]::new((Get-Date).Year, [int]$g[2].Value, [int]$g[1].Value, [int]$g[3].Value, [int]$g[4].Value, [int]$g[5].Value, [int]$g[6].Value)
        if ($t -gt (Get-Date).AddDays(1)) { $t = $t.AddYears(-1) }
        if ($g[7].Value -like 'Starting*') { $started = $t; $asleep = $null; $woke = $null }
        elseif ($g[7].Value -like '*unavailable*') { $asleep = $t; $woke = $null }
        elseif ($asleep -and -not $woke) { $woke = $t }
    }
    # NotBefore: when waiting for a runtime we just started, its log must be the newest one (allow 2 s clock slack).
    if (-not $started -or ($NotBefore -gt [datetime]::MinValue -and $started -lt $NotBefore.AddSeconds(-2))) { return [pscustomobject]@{State='Starting'; Since=[datetime]::MinValue} }
    if ($asleep -and -not $woke) { return [pscustomobject]@{State='Asleep'; Since=$asleep} }
    # Meta briefly reports 'unavailable' ~8-10 s after every start, so a runtime with no wake event yet needs 15 s.
    if ($woke) { return [pscustomobject]@{State='Awake'; Since=$woke; Settle=10} }
    return [pscustomobject]@{State='Awake'; Since=$started; Settle=15}
}
function Wait-ArcRiftHeadsetAwake([datetime]$NotBefore = [datetime]::MinValue, [int]$TimeoutSeconds = 180) {
    # Release 1.1.2: Meta looks for the headset display only once, when its runtime starts. A headset that is asleep
    # (sat unused) or still waking up has no display at that moment, so wait until it has been awake for 10 s.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $told = ''
    while ($true) {
        $wake = Get-ArcRiftHeadsetWake $NotBefore
        if ($wake.State -eq 'Unknown') { return }
        if ($wake.State -eq 'Awake' -and ((Get-Date) - $wake.Since).TotalSeconds -ge $wake.Settle) {
            if ($told) { Write-Output 'Headset is awake.' }
            return
        }
        $message = switch ($wake.State) {
            'Asleep' { 'Headset is asleep: put it on, or pick it up and move it, to wake it. The session continues 10 s after it wakes.' }
            'Awake' { 'Headset is waking up; continuing in a few seconds...' }
            default { 'Waiting for the Meta runtime to start...' }
        }
        if ($message -ne $told) { Write-Output $message; $told = $message }
        if (Test-Path -LiteralPath (Join-Path $out 'session-stop.txt')) { throw 'Stopped by you while waiting for the headset to wake.' }
        if ((Get-Date) -gt $deadline) { throw 'The headset did not wake up within 3 minutes. Put it on until its display lights up, then start the session again.' }
        Start-Sleep -Seconds 1
    }
}
$clientLogFreedTo = 1MB
$clientLogFreeWarned = $false
function Limit-ArcRiftClientLog([string]$Path) {
    # Release 1.1.2: vrcmd --pollposes writes ~40 MB/hour of poses to client.txt. Free the disk space of everything
    # except its first 1 MB and last 8 MB (sparse zeroing; vrcmd keeps writing normally). Never fails the session.
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $length = (Get-Item -LiteralPath $Path).Length
        $freeTo = [long]([math]::Floor(($length - 8MB) / 65536) * 65536)
        if ($freeTo - $script:clientLogFreedTo -lt 64MB) { return }
        if (-not ('ArcRiftSparseLog' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.IO; using System.ComponentModel; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class ArcRiftSparseLog {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, IntPtr input, int inputSize, IntPtr output, int outputSize, out int returned, IntPtr overlapped);
    public static void ZeroRange(string path, long from, long to) {
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) {
            int returned;
            // FSCTL_SET_SPARSE, then FSCTL_SET_ZERO_DATA: the zeroed range stops using disk space.
            if (!DeviceIoControl(file.SafeFileHandle, 0x000900C4, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero)) throw new Win32Exception();
            IntPtr range = Marshal.AllocHGlobal(16);
            try {
                Marshal.WriteInt64(range, 0, from); Marshal.WriteInt64(range, 8, to);
                if (!DeviceIoControl(file.SafeFileHandle, 0x000980C8, range, 16, IntPtr.Zero, 0, out returned, IntPtr.Zero)) throw new Win32Exception();
            } finally { Marshal.FreeHGlobal(range); }
        }
    }
}
'@
        }
        [ArcRiftSparseLog]::ZeroRange($Path, $script:clientLogFreedTo, $freeTo)
        $script:clientLogFreedTo = $freeTo
    } catch {
        if (-not $script:clientLogFreeWarned) { $script:clientLogFreeWarned = $true; Write-Output ('client.txt disk space could not be freed (session unaffected): ' + $_.Exception.Message) }
    }
}
function Stop-ArcRiftPresentMon {
    if (-not $script:presentMonProcess) { return }
    try {
        $pmStop = Start-Process -FilePath (Join-Path $root 'PresentMon.exe') -ArgumentList '--session_name ArcRiftPM --terminate_existing_session' -WindowStyle Hidden -PassThru
        $null = $pmStop.WaitForExit(5000)
        if (-not $script:presentMonProcess.WaitForExit(5000)) { Stop-Process -Id $script:presentMonProcess.Id -Force -ErrorAction SilentlyContinue }
    } catch { Write-Output ('PresentMon stop note (rollback unaffected): ' + $_.Exception.Message) }
    $script:presentMonProcess = $null
}
function Start-ArcRiftPresentMon {
    # Optional read-only frame-timing capture for Meta's server and every game seen so far. Never affects the session.
    try {
        Stop-ArcRiftPresentMon
        $script:presentMonFiles++
        $csv = if ($script:presentMonFiles -eq 1) { 'presentmon.csv' } else { 'presentmon-' + $script:presentMonFiles + '.csv' }
        $names = (@($script:presentMonGames) + 'OVRServer_x64.exe' | ForEach-Object { '--process_name "' + $_ + '"' }) -join ' '
        $pmArgs = $names + ' --output_file "' + (Join-Path $out $csv) + '" --no_console_stats --no_track_input --session_name ArcRiftPM --stop_existing_session'
        $script:presentMonProcess = Start-Process -FilePath (Join-Path $root 'PresentMon.exe') -ArgumentList $pmArgs -WindowStyle Hidden -PassThru
        Write-Output ('Frame-timing recorder (PresentMon) started: ' + $csv + ' in this session folder (' + ($script:presentMonGames -join ', ') + ').')
    } catch { Write-Output ('PresentMon not started (session unaffected): ' + $_.Exception.Message) }
}
function Get-ArcRiftNewMetaCrash {
    # Release 1.4: Meta's runtime writes its own crash report (Breakpad: <id>.dmp, later <id>.dmp.processed, plus
    # <id>.txt) to %LOCALAPPDATA%\Oculus\OVRServerBreakpad when it crashes. Every "Meta stopped responding" stop
    # checked so far was such a crash, on the thread that had just logged StartTracking; the process then lingers
    # with one thread, so it never shows as exited. The first call only remembers the reports already there.
    # Returns the new reports (newest first), or nothing. Only lists the folder; never opens a report.
    $files = @()
    try { if (Test-Path -LiteralPath $script:metaCrashDir) { $files = @(Get-ChildItem -LiteralPath $script:metaCrashDir -File -ErrorAction SilentlyContinue) } } catch {}
    $idOf = { param($f) if ($f.Name -match '^([0-9a-fA-F-]{36})') { $Matches[1].ToLowerInvariant() } else { $f.Name } }
    if ($null -eq $script:metaCrashKnown) {
        $script:metaCrashKnown = @{}
        foreach ($f in $files) { $script:metaCrashKnown[(& $idOf $f)] = $true }
        return
    }
    $new = @($files | Where-Object { -not $script:metaCrashKnown.ContainsKey((& $idOf $_)) } | Sort-Object LastWriteTime -Descending)
    foreach ($f in $new) { $script:metaCrashKnown[(& $idOf $f)] = $true }
    $new
}
function Get-ArcRiftAutoRestartDecision {
    # Release 1.4: whether a session that just ended should start a fresh one by itself. Returns '' to restart, or the
    # sentence to show for not restarting ($null when it was never a candidate: not a manual session, or no Meta crash).
    param([bool]$Manual, [bool]$Guardian, $CrashAt, [bool]$RollbackVerified, [bool]$StopRequested, $ReadyAt, [int]$Count)
    if (-not $Manual -or $Guardian -or -not $CrashAt) { return $null }
    if ($StopRequested) { return $null }  # you pressed Stop & restore: never undo that
    if (-not $RollbackVerified) { return 'Not restarting automatically: the restore was not verified. Use Recover in ArcRift Control.' }
    if (-not $ReadyAt) { return 'Not restarting automatically: Meta crashed before the session was ready. Start a new session from ArcRift Control.' }
    if ((([datetime]$CrashAt) - ([datetime]$ReadyAt)).TotalSeconds -lt 60) { return 'Not restarting automatically: Meta crashed within a minute of the session becoming ready, which is not the known headset-down crash. Start a new session from ArcRift Control.' }
    if ($Count -ge 3) { return 'Not restarting automatically: this was already the third automatic restart in a row. Start a new session from ArcRift Control.' }
    return ''
}
function Start-ArcRiftAutoRestart {
    # Opens the next session in a new window. This window is already elevated, so no administrator prompt appears.
    # Same switches as this session, plus the restart count and this PID (the new session waits for this one to exit).
    if (-not $script:harnessScript -or -not (Test-Path -LiteralPath $script:harnessScript)) { throw 'the session script path is unknown.' }
    $restartArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:harnessScript + '"'))
    foreach ($k in $script:harnessParameters.Keys) {
        if ($k -in 'AutoRestartCount', 'WaitForHarnessPid') { continue }
        $v = $script:harnessParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $restartArgs += '-' + $k } }
        else { $restartArgs += '-' + $k; $restartArgs += [string]$v }
    }
    $restartArgs += '-AutoRestartCount', [string]($AutoRestartCount + 1), '-WaitForHarnessPid', [string]$PID
    $next = Start-Process powershell.exe -ArgumentList ($restartArgs -join ' ') -WorkingDirectory $root -PassThru
    ('Automatic restart ' + ($AutoRestartCount + 1) + ' of 3 started at ' + (Get-Date).ToString('o') + ' as PID ' + $next.Id) | Set-Content -LiteralPath (Join-Path $out 'auto-restart.txt')
    Write-Output ('Restarting automatically in a new window (restart ' + ($AutoRestartCount + 1) + ' of 3). Put the headset on; when it says VR ready, start your game again. Press Stop & restore to end it.')
}
function Save-ArcRiftMetaCrashRecord($Reports) {
    # Notes Meta's crash report in the session folder. The report itself stays where Meta put it.
    try {
        $lines = @()
        $lines += 'Meta runtime (OVRServer_x64) crashed. Seen by ArcRift at ' + (Get-Date).ToString('o') + '.'
        $lines += 'Meta''s own crash report, written at ' + $Reports[0].LastWriteTime.ToString('o') + ':'
        foreach ($r in $Reports) { $lines += '  ' + $r.FullName + ' (' + $r.Length + ' bytes)' }
        $lines += ''
        $lines += 'The crash happened inside Meta''s runtime; its log (Service_*.txt, copied to this folder) ends at the crash.'
        $lines += 'These reports hold private data from Meta''s runtime (including your Meta user ID): do not post them publicly.'
        $lines | Set-Content -LiteralPath (Join-Path $out 'meta-crash.txt')
        Write-Output ('Meta runtime crash recorded in this session folder: meta-crash.txt (Meta''s own report: ' + $Reports[0].Name + ').')
    } catch { Write-Output ('Meta crash record note (restore unaffected): ' + $_.Exception.Message) }
}
function Save-ArcRiftMetaHangRecord {
    # Release 1.4: when the freeze watchdog fires, record what Meta's hung runtime is doing before it is stopped, so the
    # cause can be found. Writes meta-hang-threads.txt (every thread's state and the CPU it used over 1 s: all waiting
    # means a deadlock, one busy thread means a spin; the IDs are the ones in Meta's Service log) and meta-hang.dmp
    # (thread stacks, for WinDbg). Only reads Meta's process. Runs in a child PowerShell with a time limit so it can
    # never hold up the restore; any failure is only noted.
    $job = $null
    try {
        $hung = Get-Process OVRServer_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $hung) { return }
        if ((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($out))).AvailableFreeSpace -lt 3GB) { Write-Output 'Meta hang record skipped: less than 3 GB free.'; return }
        $job = Start-Job -ArgumentList $hung.Id,$out -ScriptBlock {
            param([int]$id, [string]$dir)
            $ErrorActionPreference = 'Stop'
            $notes = @()
            try {
                $before = @{}
                foreach ($t in (Get-Process -Id $id).Threads) { try { $before[$t.Id] = $t.TotalProcessorTime.TotalMilliseconds } catch {} }
                Start-Sleep -Seconds 1
                $busy = 0
                $rows = foreach ($t in (Get-Process -Id $id).Threads) {
                    $cpu = $null; try { $cpu = $t.TotalProcessorTime.TotalMilliseconds } catch {}
                    $state = [string]$t.ThreadState; $why = ''
                    if ($state -eq 'Wait') { try { $why = [string]$t.WaitReason } catch {} }
                    $delta = ''
                    if ($null -ne $cpu -and $before.ContainsKey($t.Id)) { $delta = [math]::Round($cpu - $before[$t.Id]); if ($delta -ge 100) { $busy++ } }
                    $total = ''; if ($null -ne $cpu) { $total = [math]::Round($cpu) }
                    '{0,7}  {1,-10} {2,-18} {3,8} {4,12} {5,10}' -f $t.Id, $state, $why, $t.CurrentPriority, $total, $delta
                }
                $rows = @($rows)
                $head = @()
                $head += 'Meta runtime (OVRServer_x64 PID ' + $id + ') threads at ' + (Get-Date).ToString('o') + ', taken when its log had been silent for 30 s.'
                $head += [string]$rows.Count + ' threads, ' + $busy + ' busy (100 ms or more of CPU in the 1 s sample).'
                $head += ''
                $head += '{0,7}  {1,-10} {2,-18} {3,8} {4,12} {5,10}' -f 'Thread','State','Waiting for','Priority','CPU ms','CPU ms/1s'
                $head + $rows | Set-Content -LiteralPath (Join-Path $dir 'meta-hang-threads.txt')
                $notes += 'meta-hang-threads.txt (' + $rows.Count + ' threads, ' + $busy + ' busy)'
            } catch { $notes += 'thread list failed: ' + $_.Exception.Message }
            $dump = Join-Path $dir 'meta-hang.dmp'
            try {
                Add-Type -Namespace ArcRift -Name HangDump -MemberDefinition '[DllImport("dbghelp.dll", SetLastError = true)] public static extern bool MiniDumpWriteDump(IntPtr process, uint processId, Microsoft.Win32.SafeHandles.SafeFileHandle file, uint dumpType, IntPtr exception, IntPtr userStream, IntPtr callback); [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId); [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);'
                # Open only what the dump needs (query + read memory + duplicate handles). Process.Handle asks for full
                # access and comes back empty when that is refused, which made the first real record fail with a null.
                $proc = [ArcRift.HangDump]::OpenProcess([uint32]0x0450, $false, [uint32]$id)
                if ($proc -eq [IntPtr]::Zero) { throw ('could not open Meta''s process (error {0}); it may already be exiting' -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
                $file = $null
                try {
                    $file = [IO.File]::Create($dump)
                    # Thread stacks plus module globals, handles and the memory the stacks point at: enough to see who
                    # waits on what, without copying the whole process (no full heap).
                    $ok = [ArcRift.HangDump]::MiniDumpWriteDump($proc, [uint32]$id, $file.SafeFileHandle, [uint32]0x1165, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
                    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                } finally { if ($file) { $file.Dispose() }; [void][ArcRift.HangDump]::CloseHandle($proc) }
                if (-not $ok) { throw ('MiniDumpWriteDump error 0x{0:x8}' -f $code) }
                $notes += 'meta-hang.dmp (' + [math]::Round((Get-Item -LiteralPath $dump).Length / 1MB) + ' MB)'
            } catch {
                Remove-Item -LiteralPath $dump -ErrorAction SilentlyContinue
                $notes += 'dump failed: ' + $_.Exception.Message
            }
            $notes -join '; '
        }
        if (Wait-Job $job -Timeout 30) {
            Write-Output ('Meta runtime hang recorded in this session folder: ' + (@(Receive-Job $job) -join '; ') + '. These files hold private data from Meta''s runtime: do not post them publicly.')
        } else {
            Write-Output 'Meta hang record took over 30 s and was abandoned (restore unaffected).'
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $out 'meta-hang.dmp') -ErrorAction SilentlyContinue
        }
    } catch { Write-Output ('Meta hang record note (restore unaffected): ' + $_.Exception.Message) }
    finally { if ($job) { Remove-Job $job -Force -ErrorAction SilentlyContinue } }
}
function Read-AppendedBridgeLog([string]$Path, [ref]$Offset, [switch]$OnlyIfGrown) {
    $stream = $null
    $reader = $null
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        # OnlyIfGrown (bridge log): the bridge opens its log exclusively for every line, so a line it writes while this
        # script has the file open is lost (seen: 4 of 2948 progress lines in one session). Checking the size opens
        # nothing; the file is then only opened right after the bridge has finished a line.
        if ($OnlyIfGrown -and (New-Object IO.FileInfo($Path)).Length -eq $Offset.Value) { return '' }
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if ($stream.Length -lt $Offset.Value) { $Offset.Value = 0L }
        $null = $stream.Seek($Offset.Value,[IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $Offset.Value = $stream.Position
        return $text
    } catch { return '' } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
}
# Release 1.2: refuse to start while SteamVR/VRChat is already open, and say exactly which program and what to do.
# Single line on purpose: the dashboard shows the "TEST STOP: ..." line as the session's reason.
function Assert-ArcRiftNoVRRunning {
    $running = @(Get-Process vrserver,vrcompositor,vrmonitor,vrcmd,VRChat,isolated_presenter_test -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ProcessName + '.exe' } | Sort-Object -Unique)
    if ($running.Count) {
        throw ('SteamVR or VRChat is already running (' + ($running -join ', ') + '). ArcRift starts SteamVR itself: close VRChat and SteamVR, end any of those programs still listed in Task Manager > Details (or restart the PC), then start the session again. No changes made.')
    }
}
Start-Transcript -Path (Join-Path $out 'transcript.txt')
try {
    if ($arcConfigError) { throw $arcConfigError }
    $null = Get-ArcRiftNewMetaCrash  # remember Meta's existing crash reports, so only new ones count

    Write-Output ('Headset display ' + $monitorInstance + ' (target ' + $targetId + ') from Setup.')
    if ($AutoRestartCount -gt 0) { Write-Output ('Automatic restart ' + $AutoRestartCount + ' of 3 after a Meta runtime crash (previous session window PID ' + $WaitForHarnessPid + ').') }
    if ($gpuNote) { Write-Output $gpuNote }
    # Release 1.3 (other Intel cards): record which card, driver and Windows build this session ran on, so a report
    # from an untested card says what it was. Read-only; never fails the session.
    try {
        $osBuild = [Environment]::OSVersion.Version.Build
        $systemInfo = @('Windows build ' + $osBuild)
        foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) { $systemInfo += ('GPU: ' + $g.Name + ' | driver ' + $g.DriverVersion + ' | ' + ($g.PNPDeviceID -replace '&SUBSYS.*$', '')) }
        Set-Content -LiteralPath (Join-Path $out 'system-info.txt') -Value $systemInfo
        if ($osBuild -lt 22000) { Write-Output 'Note: this PC runs Windows 10. ArcRift is only tested on Windows 11; if the headset display mode does not switch, that may be why.' }
    } catch { }
    if ($ManualSession -and -not $VRChatTrial) { throw 'ManualSession requires explicit VRChatTrial/menu-working mode.' }
    if ($VRChatTrial -and -not $DashboardNormalUserTrial) { throw 'VRChatTrial requires the menu-working DashboardNormalUserTrial; other rendering/launch modes refused.' }
    if ($DashboardNormalUserTrial -and (-not ($LegacyCheckpointSteamTrial -and $UserLaunchSteamTrial) -or $OriginalSteamVRBaselineTrial -or $DashboardSameIntegrityTrial)) { throw 'DashboardNormalUserTrial requires exact legacy renderer with normal-user launching, not elevated-baseline/UI-replacement modes.' }
    if ($DashboardSameIntegrityTrial -and -not $OriginalSteamVRBaselineTrial) { throw 'DashboardSameIntegrityTrial requires the original baseline; no other launch or renderer experiment allowed.' }
    if ($OriginalSteamVRBaselineTrial -and (-not $LegacyCheckpointSteamTrial -or $UserLaunchSteamTrial)) { throw 'OriginalSteamVRBaselineTrial requires LegacyCheckpointSteamTrial and forbids the new normal-user launcher.' }
    if ($UserLaunchSteamTrial -and -not $guardedSteamTrial) { throw 'UserLaunchSteamTrial requires a restricted guarded SteamVR trial mode.' }
    if ($SteamVR -and (Test-Path (Join-Path $root 'steamvr-tests-paused.txt')) -and -not ($UserLaunchSteamTrial -or $OriginalSteamVRBaselineTrial)) { throw 'SteamVR trials paused pending transport/launch-privilege investigation. No runtime/display changes made.' }
    if (([int][bool]$IsolatedHeadsetTrial + [int][bool]$LegacyCheckpointTrial + [int][bool]$NoReadbackSteamTrial + [int][bool]$StartupIdentityHeadsetTrial + [int][bool]$LegacyCheckpointSteamTrial) -gt 1) { throw 'Choose only one backend trial.' }
    if ($NoReadbackSteamTrial) {
        if (-not ($Visual -and $NativeTiming -and $NativeSource -and $SteamVR) -or $Stereo -or $TrackedScene -or $LinkDiagnostics) { throw 'NoReadbackSteamTrial requires only Visual/NativeTiming/NativeSource/SteamVR; no game or other render modes.' }
        Assert-ArcRiftNoVRRunning
        if ((Get-FileHash -LiteralPath (Join-Path $root 'arc_rift_bridge.dll') -Algorithm SHA256).Hash -ne 'c9fad8ed975c900d58d39cfce96cdc01608a388ce675f4f6b45fc8e18685a485') { throw 'Saved legacy reference was changed.' }
        $bridgeName = 'arc_rift_bridge_noreadback.dll'
        $bridgeLogName = 'arc-rift-bridge-noreadback.log'
        $SteamVRSeconds = 20
        Write-Output 'Explicit 20-second SteamVR-only A/B trial: legacy rendering path with recurring readbacks disabled. Saved DLL untouched.'
    } elseif ($LegacyCheckpointSteamTrial) {
        if (-not ($Visual -and $NativeTiming -and $NativeSource -and $SteamVR -and ($UserLaunchSteamTrial -or $OriginalSteamVRBaselineTrial)) -or $Stereo -or $TrackedScene -or $LinkDiagnostics) { throw 'LegacyCheckpointSteamTrial requires Visual/NativeTiming/NativeSource/SteamVR and one explicit launch mode; no games or other render modes.' }
        Assert-ArcRiftNoVRRunning
        # Release 1.1: verify every program against release-manifest.json (written by BUILD-RELEASE.cmd).
        $releaseManifestPath = Join-Path $root 'release-manifest.json'
        if (-not (Test-Path -LiteralPath $releaseManifestPath)) { throw 'release-manifest.json is missing. Run BUILD-RELEASE.cmd or reinstall the release.' }
        $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
        foreach ($entry in $releaseManifest.PSObject.Properties) {
            if ((Get-FileHash -LiteralPath (Join-Path $root $entry.Name) -Algorithm SHA256).Hash -ne [string]$entry.Value) { throw ('Release file differs from its manifest: ' + $entry.Name) }
        }
        $SteamVRSeconds = 20
        if ($OriginalSteamVRBaselineTrial -or $DashboardNormalUserTrial) {
            $SteamVRSeconds = 30
            $savedTools = $root
            if ($DashboardNormalUserTrial) {
                if ($VRChatTrial) {
                    Write-Output ('ArcRift session: ' + $headsetProfile.Name + ' bridge with normal-user SteamVR launch. No game files or anti-cheat are touched.')
                    if ($headsetProfile.OwnEdid) { Write-Output ('EXPERIMENTAL: no ' + $headsetProfile.Name + ' session has been confirmed yet. Whatever happens, please send transcript.txt, bridge-log.txt and headset-modes-offered.txt from the newest d3d11 folder (check them for serial numbers first).') }
                } else {
                    Write-Output 'Dashboard IPC trial: EXACT original DLL/native helper/EDID; SteamVR runs as normal user to match Steam. Sequenced diagnostic, 30 seconds, no games, full rollback. Desktop baseline untouched.'
                }
            } else {
                Write-Output 'Original successful SteamVR baseline: exact saved DLL/native helper/EDID, original direct elevated vrstartup/vrcmd sequence, fixed 30 seconds. No new renderer, broker or seed; emergency guards and full rollback retained.'
            }
        } else {
            Write-Output 'User-requested exact saved legacy DLL: guarded 20-second SteamVR-only trial with normal-user launching. No rebuilt renderer, no games, no permanent enablement.'
        }
    } elseif ($LegacyCheckpointTrial) {
        if (-not ($Visual -and $NativeTiming -and $NativeSource -and $Stereo) -or $SteamVR -or $TrackedScene -or $LinkDiagnostics) { throw 'LegacyCheckpointTrial is limited to 12-second stereo labels; no SteamVR or games.' }
        Assert-ArcRiftNoVRRunning
        $expected = 'c9fad8ed975c900d58d39cfce96cdc01608a388ce675f4f6b45fc8e18685a485'
        $saved = Join-Path $root 'checkpoints\near-working-and-isolated-20261031-180448\tested-legacy\arc_rift_bridge.dll'
        if ((Get-FileHash -LiteralPath $saved -Algorithm SHA256).Hash -ne $expected -or (Get-FileHash -LiteralPath (Join-Path $root $bridgeName) -Algorithm SHA256).Hash -ne $expected) { throw 'Legacy DLL does not match saved tested checkpoint; refusing trial.' }
        Write-Output 'User-requested exact checkpoint DLL: 12-second legacy stereo test only. Known sustained instability; no permanent enablement.'
    } elseif ($isolatedRendererTrial) {
        if (-not ($Visual -and $NativeTiming -and $NativeSource -and $Stereo) -or $SteamVR -or $TrackedScene -or $LinkDiagnostics) { throw 'IsolatedHeadsetTrial requires Visual/NativeTiming/NativeSource/Stereo only; no SteamVR, games, or link diagnostics.' }
        Assert-ArcRiftNoVRRunning
        $bridgeName = 'arc_rift_bridge_isolated.dll'
        $bridgeLogName = 'arc-rift-bridge-isolated.log'
        if ($StartupIdentityHeadsetTrial) {
            if (Test-Path -LiteralPath $startupSeed) { throw 'Existing startup seed; refusing to overwrite or delete it.' }
            $bridgeName = 'arc_rift_bridge_startup.dll'
            $bridgeLogName = 'arc-rift-bridge-startup.log'
        }
        Write-Output 'Explicit isolated-only 12-second headset trial; legacy/SteamVR safety gate remains in place.'
    } elseif (Test-Path (Join-Path $root 'live-tests-paused.txt')) { throw 'Live tests paused after desktop corruption. Read live-tests-paused.txt; no runtime/display changes made.' }
    # Release 1.2.1: Guardian setup session. Same display/bridge setup and guards as a normal session, but Meta's Dash
    # is allowed (its Guardian setup shows your room through the headset cameras) and SteamVR is not started.
    if ($GuardianSetup -and -not ($ManualSession -and $VRChatTrial)) { throw 'GuardianSetup is only for the manual ArcRift session.' }
    if ($NativeSource -and -not $NativeTiming) { throw 'NativeSource requires NativeTiming.' }
    if ($Stereo -and -not ($Visual -and $NativeSource)) { throw 'Stereo requires Visual and NativeSource.' }
    if ($TrackedScene -and (-not ($Visual -and $NativeSource) -or $Stereo)) { throw 'TrackedScene requires Visual and NativeSource, without Stereo.' }
    if ($SteamVR -and (-not ($Visual -and $NativeSource) -or $Stereo -or $TrackedScene)) { throw 'SteamVR requires Visual and NativeSource, without other visual modes.' }
    if ($VRChatTrial) {
        . (Join-Path $root 'vrchat-trial-policy.ps1')
        $vrchatSettings = Get-ArcRiftVRChatTrialSettings ([bool]$DashboardNormalUserTrial) ([bool]$ManualSession)
        if (-not $ManualSession) { $SteamVRSeconds = $vrchatSettings.Seconds }
        elseif (-not (Test-Path (Join-Path $root 'native_source_session.exe'))) { throw 'Manual-session native helper missing.' }
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Elevation required.' }
    # Release 1.2.1: if an earlier session never finished cleanup (PC shut down, restarted, crashed or lost power during
    # it, or its window was closed), from this folder or another ArcRift copy, restore it automatically before anything
    # else. Uses that session's own backups and the normal Recover checks; nothing of this session is changed yet.
    if ($ManualSession) {
        . (Join-Path $root 'leftover-session.ps1')
        $leftover = Find-ArcRiftLeftoverSession $root
        if ($leftover) {
            $from = if ($leftover.Foreign) { ' from ' + $leftover.Package } else { '' }
            Write-Output ('The last session' + $from + ' was never restored (usually the PC was shut down or restarted during it). Restoring it automatically first; keep the headset plugged in...')
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'recover-manual-session.ps1') -SessionDirectory $leftover.SessionDirectory
            if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath (Join-Path $leftover.Package 'active-test.xml'))) {
                throw 'Automatic restore of the last session did not finish (see above). Check the headset is plugged in (USB and DisplayPort), close SteamVR and your game, then press Start again.'
            }
            $metaDeadline = (Get-Date).AddSeconds(30)
            while (-not (Get-Process OVRServer_x64 -ErrorAction SilentlyContinue) -and (Get-Date) -lt $metaDeadline) { Start-Sleep -Milliseconds 500 }
            Write-Output 'Last session restored. Continuing with the new session.'
        }
    }
    if ($DashboardSameIntegrityTrial) {
        & (Join-Path $root 'probe-process-integrity.ps1') | Out-File (Join-Path $out 'dashboard-harness-integrity.txt')
        . (Join-Path $root 'dashboard-integrity-trial.ps1')
        . (Join-Path $root 'steamvr-startup-policy.ps1')
        Write-Output 'Additional UI-only dashboard integrity trial. Original tested renderer/launch path unchanged; 30-second limit and full rollback retained.'
    }
    if ($UserLaunchSteamTrial) {
        . (Join-Path $root 'normal-user-steam-launch.ps1')
        . (Join-Path $root 'steamvr-startup-policy.ps1')
        $preflight = Join-Path $out 'user-launch-preflight'
        New-Item -ItemType Directory -Path $preflight | Out-Null
        $workerProof = Start-ArcRiftSteamWorker -EvidenceDirectory $preflight -ProbeOnly
        if ($workerProof.Integrity -ne 8192) { throw 'Normal-user worker preflight failed.' }
        if (-not $GuardianSetup -and -not (Get-Process steam -ErrorAction SilentlyContinue)) { throw 'Steam is not running. Start Steam and sign in, then start the session again; no changes made.' }
        if (-not (Get-Process OVRServer_x64 -ErrorAction SilentlyContinue)) { throw 'Meta runtime is not running. Open the Meta Horizon app with the headset plugged in, then start the session again; no changes made.' }
        foreach ($p in @(Get-Process OVRServer_x64,steam,explorer -ErrorAction Stop)) {
            $rid = [ArcRiftIntegrityProbe]::Integrity($p.Id)
            # Release 1.3: an extra explorer.exe (opened for a folder window) can exit before it is checked. The
            # desktop's own Explorer is checked again when SteamVR is launched through it.
            if ($rid -lt 0 -and $p.Name -eq 'explorer' -and -not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { continue }
            if ($rid -ne 8192) { throw ('Participant is not Medium integrity: ' + $p.Name) }
        }
        if ($VRChatTrial) {
            if ($GuardianSetup) { Write-Output 'EXPERIMENTAL Guardian setup session: Meta Dash is allowed so Meta can run its Guardian setup (room view and controller drawing). SteamVR is not started. Safety guards stay active; when Guardian is saved, press Stop & restore.' }
            elseif ($ManualSession) { Write-Output 'Manual-stop session: no time limit. Safety guards stay active. When done, quit your game and use Stop & restore.' }
            else { Write-Output 'Normal-user preflight passed. Five-minute VRChat observation; user handles normal Steam launch/login. Close VRChat before cutoff. Games are not force-terminated by this harness.' }
        } else {
            Write-Output ('Normal-user worker preflight passed without VR. Live trial is SteamVR-only, no games, fixed ' + $SteamVRSeconds + ' seconds.')
        }
    }
    if ((Get-Service OVRService).Status -ne 'Running') { throw 'Service is not in the expected original running state.' }
    if (Get-Process OculusDash -ErrorAction SilentlyContinue) { throw 'Dash is already running; refusing to interrupt an existing session.' }
    if ((Test-Path -LiteralPath $edidKey) -and (Test-Path -LiteralPath (Join-Path $root 'cv1-probe-active.txt'))) { throw 'A display mode from an interrupted CV1 MODE TEST is still applied to the headset display. Run "CV1 MODE TEST.cmd" again (it removes it first), then start the session; no changes made.' }
    if (Test-Path -LiteralPath $edidKey) { throw 'The headset display mode from an earlier ArcRift session is still applied, but no unrestored session was found to restore it from. Run RECOVER.cmd in the ArcRift folder you used last; no changes made.' }
    # Release 1.1.2: never back up "original" settings over a session that was not restored yet.
    if (Test-Path -LiteralPath $activeSession) { throw 'The previous session was not restored (active-test.xml exists). Run Recover in ArcRift Control or RECOVER.cmd first; no changes made.' }
    # Release 1.3: the lock is "held while open", not "the file exists". A lock file left behind by a session that was
    # ended at the wrong moment used to make every later Start fail (CreateNew); now it is simply taken over.
    try { $sessionLock = [IO.File]::Open($sessionLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch { throw 'Another ArcRift session or recovery is using this folder right now (active-test.lock is in use). Wait for it to finish, then start again; no changes made.' }
    [pscustomobject]@{SessionDirectory=$out; HarnessPid=$PID; Started=(Get-Date)} | Export-Clixml $activeSession
    if ($SteamVR) {
        if (-not (Test-Path (Join-Path $steamBin 'vrcmd.exe'))) { throw 'Installed SteamVR diagnostic is missing.' }
        $existing = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($existing.Count -or (Get-Process vrserver,vrcompositor,vrmonitor -ErrorAction SilentlyContinue)) { throw 'SteamVR already running; refusing to interrupt an existing session.' }
        $steamConfig = Join-Path $steamPath 'config\steamvr.vrsettings'
        if (Test-Path $steamConfig) { Copy-Item -LiteralPath $steamConfig -Destination (Join-Path $out 'steamvr-settings-before.json') }
    }
    & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-baseline.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Baseline display probe failed.' }
    $baselineLayouts = Get-ActiveLayouts (Get-Content (Join-Path $out 'physical-baseline.txt') -Raw)
    if (-not (Get-ArcRiftHeadsetLayoutKey $baselineLayouts $targetId)) { throw ('The headset display saved by Setup is not an active Windows display right now. Check the headset is plugged in (USB and ' + $headsetProfile.Cable + ') and awake with the Meta Horizon app open; if you moved it to another port or changed graphics card, run Setup again. No changes made.') }
    if ($NativeTiming) {
        $monitor = Get-PnpDevice -InstanceId $monitorInstance -PresentOnly
        if ($monitor.Class -ne 'Monitor') { throw 'Verified headset monitor is missing.' }
        $testEdid = [IO.File]::ReadAllBytes((Join-Path $root 'rift-s-native-test.edid'))
        if ($testEdid.Length -ne 128 -or (($testEdid | Measure-Object -Sum).Sum % 256) -ne 0) { throw 'Invalid native test EDID.' }
        # Release 1.4: the mode is read from the EDID and must be exactly the profile's tested mode (Rift S: 1440x2560,
        # pixel clock 571570000, as before). $nativeSignal is how display_probe.exe prints that mode once it is live.
        $nativeMode = Get-ArcRiftEdidMode $testEdid
        if ($nativeMode.Width -ne $headsetProfile.Width -or $nativeMode.Height -ne $headsetProfile.Height -or $nativeMode.PixelClock -ne $headsetProfile.PixelClock) { throw 'Native EDID differs from the previously tested timing.' }
        $nativeSize = [string]$nativeMode.Width + 'x' + $nativeMode.Height
        $nativeSignal = 'signal=' + $nativeSize + ' total=' + $nativeMode.TotalWidth + 'x' + $nativeMode.TotalHeight + ' pixelClock=' + $nativeMode.PixelClock
        $nativeSignalPattern = [regex]::Escape($nativeSignal)
        # $useTemporaryEdid: this session applies a temporary Windows EDID override ($registryEdid) to the headset
        # display. Always for a Rift S. For a Rift CV1 only when Windows does not offer its mode by itself and
        # "CV1 MODE TEST.cmd" has found a temporary EDID that makes this graphics driver offer it.
        $useTemporaryEdid = -not $headsetProfile.OwnEdid
        $registryEdid = $testEdid
        if ($headsetProfile.OwnEdid) {
            # Rift CV1 (experimental): no temporary EDID. The session will ask Windows to switch the headset display to
            # the mode in its own EDID. Everything here only reads and tests, so a graphics card that does not offer
            # the mode stops the session before anything is changed. (First CV1 report, Arc B580 over HDMI: the
            # headset ran at 1920x1080 60 Hz, a mode that is not in its EDID at all.)
            # Windows may round 89.998 Hz down or up and the driver may word the timing differently, so the mode is
            # confirmed by its size and refresh rate, not by the exact pixel clock.
            $nativeSignalPattern = 'signal=' + $nativeSize + ' total=\S+ pixelClock=\d+'
            . (Join-Path $root 'display-mode.ps1')
            $modeSource = [ArcRiftDisplayMode]::Source($headsetPathId)
            if (-not $modeSource) { throw ('Windows has not put the ' + $headsetProfile.Name + ' display on a desktop source, so its display mode cannot be switched. No changes made.') }
            $modeBefore = [ArcRiftDisplayMode]::Current($modeSource)
            $offeredModes = @([ArcRiftDisplayMode]::Modes($modeSource))
            $wantedMode = Select-ArcRiftHeadsetMode $offeredModes
            if (-not $wantedMode) {
                # Arc cards over HDMI have been reported to show a wrong mode list until the display is detected again.
                # Restart the headset's monitor device once and look again. Nothing is written anywhere.
                Write-Output ('Windows does not offer ' + $nativeSize + ' at ' + $headsetProfile.Hz + ' Hz for the headset display. Restarting the headset monitor device once so Windows reads it again...')
                & pnputil.exe /restart-device $monitorInstance | Out-Null
                Start-Sleep -Seconds 3
                $rereadDeadline = (Get-Date).AddSeconds(25)
                $modeSource = $null
                while (-not $modeSource -and (Get-Date) -lt $rereadDeadline) { Start-Sleep -Milliseconds 500; $modeSource = [ArcRiftDisplayMode]::Source($headsetPathId) }
                if ($modeSource) { Start-Sleep -Seconds 3; $modeSource = [ArcRiftDisplayMode]::Source($headsetPathId) }
                if (-not $modeSource) { throw ('The ' + $headsetProfile.Name + ' display did not come back as a Windows display after its monitor device was restarted. Unplug the headset''s ' + $headsetProfile.Cable + ' cable, plug it back in, then start again.') }
                $offeredModes = @([ArcRiftDisplayMode]::Modes($modeSource))
                $wantedMode = Select-ArcRiftHeadsetMode $offeredModes
            }
            (@(('Display source: ' + $modeSource), ('Mode before the session (width height hertz): ' + $modeBefore), 'Modes Windows offers for the headset display:') + $offeredModes) | Set-Content -LiteralPath (Join-Path $out 'headset-modes-offered.txt')
            if ($wantedMode) {
                $modeSwitch = [pscustomobject]@{ Width = $wantedMode.W; Height = $wantedMode.H; Hz = $wantedMode.Hz; Before = $modeBefore; Needed = ($modeBefore -ne ([string]$wantedMode.W + ' ' + $wantedMode.H + ' ' + $wantedMode.Hz)) }
                if ($modeSwitch.Needed) {
                    $modeTest = [ArcRiftDisplayMode]::Set($modeSource, $modeSwitch.Width, $modeSwitch.Height, $modeSwitch.Hz, $true)
                    if ($modeTest -ne 0) { throw ('Windows lists ' + $nativeSize + ' at ' + $modeSwitch.Hz + ' Hz for the headset display but refused a test of it (result ' + $modeTest + '). No changes made.') }
                }
                Write-Output ($headsetProfile.Name + ' (experimental): Windows offers ' + $nativeSize + ' at ' + $modeSwitch.Hz + ' Hz for the headset display' + $(if ($modeSwitch.Needed) { '; the session will switch to it and switch back afterwards.' } else { ' and it is already in use.' }))
            } else {
                # The graphics driver leaves the headset's mode out (first seen on an Arc B580 over HDMI). If
                # "CV1 MODE TEST.cmd" found a temporary EDID that makes the driver offer it, use that, the same way a
                # Rift S session uses its temporary EDID. Otherwise stop here, before anything is changed.
                $offeredParsed = @($offeredModes | Where-Object { $_ } | ForEach-Object { $p = $_ -split ' '; [pscustomobject]@{ W = [int]$p[0]; H = [int]$p[1]; Hz = [int]$p[2] } })
                $sameSize = @($offeredParsed | Where-Object { $_.W -eq $nativeMode.Width -and $_.H -eq $nativeMode.Height } | ForEach-Object { $_.Hz } | Sort-Object -Unique -Descending)
                $largest = $offeredParsed | Sort-Object { $_.W * $_.H }, Hz -Descending | Select-Object -First 1
                $found = if ($sameSize.Count) { 'it offers ' + $nativeSize + ' only at ' + ($sameSize -join ', ') + ' Hz' } elseif ($largest) { 'the largest mode it offers is ' + $largest.W + 'x' + $largest.H + ' at ' + $largest.Hz + ' Hz' } else { 'it offers no modes' }
                $overridePath = Join-Path $root 'cv1-override.edid'
                if (-not (Test-Path -LiteralPath $overridePath)) {
                    throw ('Windows does not offer the ' + $headsetProfile.Name + ' display mode (' + $nativeSize + ' at ' + $headsetProfile.Hz + ' Hz) on this graphics card, also after restarting the headset monitor: ' + $found + '. The graphics driver leaves the mode out. Next: run "CV1 MODE TEST.cmd" in the ArcRift folder (about 3 minutes). It tries display-mode variants on the headset display only, puts everything back, and saves one that works for the next session. Then send its cv1-mode-test file. If the headset goes through an adapter, plug its ' + $headsetProfile.Cable + ' cable straight into the card first. No changes made.')
                }
                $registryEdid = [byte[]](Get-ArcRiftCv1Override $overridePath $testEdid)
                $useTemporaryEdid = $true
                $modeSwitch = [pscustomobject]@{ Width = $nativeMode.Width; Height = $nativeMode.Height; Hz = 0; Before = $modeBefore; Needed = $true }
                Write-Output ($headsetProfile.Name + ' (experimental): Windows does not offer ' + $nativeSize + ' at ' + $headsetProfile.Hz + ' Hz by itself (' + $found + '). Using the temporary display mode that CV1 MODE TEST found (cv1-override.edid); it is removed again afterwards.')
            }
        }
        [IO.File]::WriteAllBytes((Join-Path $out 'original-monitor.edid'), (Get-ItemProperty -LiteralPath $monitorParent -Name EDID).EDID)
        [IO.File]::WriteAllBytes((Join-Path $out 'temporary-native.edid'), $registryEdid)
        @{KeyExisted=$false; Instance=$monitorInstance; Parent=$monitorParent} | Export-Clixml (Join-Path $out 'edid-backup.xml')
    }
    if ($OriginalSteamVRBaselineTrial -or $DashboardNormalUserTrial) {
        & (Join-Path $savedTools 'bridge_selftest.exe') | Out-File (Join-Path $out 'bridge-preflight.txt')
    } elseif ($StartupIdentityHeadsetTrial) {
        & (Join-Path $root 'bridge_selftest_startup.exe') --startup | Out-File (Join-Path $out 'bridge-preflight.txt')
    } elseif ($IsolatedHeadsetTrial) {
        & (Join-Path $root 'bridge_selftest.exe') --isolated | Out-File (Join-Path $out 'bridge-preflight.txt')
    } elseif ($NoReadbackSteamTrial) {
        & (Join-Path $root 'bridge_selftest.exe') --no-readback | Out-File (Join-Path $out 'bridge-preflight.txt')
    } else {
        & (Join-Path $root 'bridge_selftest.exe') | Out-File (Join-Path $out 'bridge-preflight.txt')
    }
    if ($LASTEXITCODE -ne 0) { throw 'Bridge preflight failed.' }
    Get-FileHash -LiteralPath (Join-Path $root $bridgeName) -Algorithm SHA256 | Export-Clixml (Join-Path $out 'backend-hash.xml')
    # Release 1.1.2: the bridge appends to one log forever; start a fresh one once it passes 8 MB (bridge is not loaded yet).
    $bridgeLogPath = Join-Path $root $bridgeLogName
    if ((Test-Path -LiteralPath $bridgeLogPath) -and (Get-Item -LiteralPath $bridgeLogPath).Length -gt 8MB) {
        try { Move-Item -LiteralPath $bridgeLogPath -Destination ($bridgeLogPath -replace '\.log$', '.old.log') -Force } catch { Write-Output ('Bridge log not rotated: ' + $_.Exception.Message) }
    }
    if (Test-Path $bridgeLogPath) { $bridgeLogOffset = (Get-Item $bridgeLogPath).Length }
    [long]$bridgeLogSessionStart = $bridgeLogOffset
    $settings = @(
        @{Path='HKLM:\SOFTWARE\Oculus'; Name='DirectDisplayDLL'; Value=(Join-Path $root $bridgeName); Kind='String'},
        @{Path='HKLM:\SOFTWARE\Oculus'; Name='ForceGPUDriverVersionAcceptance'; Value=1; Kind='DWord'},
        @{Path='HKLM:\SOFTWARE\WOW6432Node\Oculus VR, LLC\Oculus\Config'; Name='PreventDashLaunch'; Value=$(if ($GuardianSetup) { 0 } else { 1 }); Kind='DWord'},
        # Release 1.4: keep Meta's tracking on while the headset is off. Without it Meta stops tracking about 20 s after
        # the headset comes off and sits still ("Setting tracking mode to off"), and starting it again on the next
        # movement is where its runtime crashes (10 of 26 resumes). Meta's own setting: OculusAppFramework.dll reads
        # this DWORD from this key at start-up, logs "Tracking was forced on by regkey." and then never stops tracking.
        @{Path='HKLM:\SOFTWARE\WOW6432Node\Oculus VR, LLC\Oculus'; Name='ForceSensorTracking'; Value=1; Kind='DWord'}
    )
    foreach ($s in $settings) {
        $had = $false; $value = $null; $kind = $null
        if (Test-Path $s.Path) {
            $k = Get-Item $s.Path
            $had = $k.GetValueNames() -contains $s.Name
            if ($had) { $value = $k.GetValue($s.Name); $kind = $k.GetValueKind($s.Name).ToString() }
        } else {
            $p = $s.Path
            while (-not (Test-Path $p)) { $createdKeys += $p; $p = Split-Path $p }
        }
        $registry += [pscustomobject]@{Path=$s.Path; Name=$s.Name; Had=$had; Value=$value; Kind=$kind}
    }
    $registry | Export-Clixml (Join-Path $out 'registry-backup.xml')
    foreach ($name in @('RemoteHeadset.dll','RemoteHeadset_v55.dll','RemoteHeadsetDisco.dll')) {
        $original = Join-Path (Join-Path $metaRuntime 'server-plugins') $name
        $temporary = $original + '.arc-rift-d3d11-disabled'
        if (Test-Path -LiteralPath $temporary) { throw 'Existing temporary plugin file.' }
        if (-not (Test-Path -LiteralPath $original)) {
            # A Meta update can drop or rename a streaming plugin; nothing to disable then.
            Write-Output ('Meta streaming plugin ' + $name + ' is not installed (Meta update?); nothing to disable for it.')
            continue
        }
        $moves += [pscustomobject]@{Original=$original; Temporary=$temporary; Hash=(Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash}
    }
    $moves | Export-Clixml (Join-Path $out 'plugins-backup.xml')
    if ($StartupIdentityHeadsetTrial) {
        & (Join-Path $root 'startup_identity_test.exe') --capture-only $PID | Out-File (Join-Path $out 'startup-identity-capture.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Fresh exact active startup identity capture failed; refusing runtime changes.' }
        $startupSeedOwned = $true
        Copy-Item -LiteralPath $startupSeed -Destination (Join-Path $out 'startup-identity-evidence.bin')
    }
    if ($ManualSession) {
        $virtual=Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -PresentOnly -ErrorAction SilentlyContinue
        $manualState=[pscustomobject]@{ManualSession=$true; Root=$root; OwnerPid=$PID; OwnerCreated=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc().ToString(); VirtualMonitorWasOk=([bool]($virtual -and $virtual.Status -eq 'OK')); CleanupVerified=$false}
        $manualState | ConvertTo-Json | Set-Content $manualRecoveryFile
        $watchArgs='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'watch-manual-session.ps1')+'" -SessionDirectory "'+$out+'"'
        $recoveryWatcher=Start-Process powershell.exe -ArgumentList $watchArgs -PassThru -WindowStyle Hidden
        $null=$recoveryWatcher.Handle
        $watchDeadline=(Get-Date).AddSeconds(5)
        while (-not (Test-Path (Join-Path $out 'manual-watcher-ready.txt'))) {
            if ($recoveryWatcher.HasExited -or (Get-Date) -gt $watchDeadline) { throw 'Independent recovery watcher failed to attach; refusing manual-session runtime changes.' }
            Start-Sleep -Milliseconds 100
        }
    }
    # Release 1.1.2: the usual "first start fails" cause was a headset that had gone to sleep before the session.
    Wait-ArcRiftHeadsetAwake
    $changed = $true
    Stop-ArcRiftMetaRuntime
    foreach ($s in $settings) {
        if (-not (Test-Path $s.Path)) { New-Item $s.Path -Force | Out-Null }
        New-ItemProperty $s.Path -Name $s.Name -Value $s.Value -PropertyType $s.Kind -Force | Out-Null
    }
    foreach ($m in $moves) { Move-Item -LiteralPath $m.Original -Destination $m.Temporary }
    $v = Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -PresentOnly -ErrorAction SilentlyContinue
    if ($v -and $v.FriendlyName -eq 'Meta Virtual Monitor' -and $v.Status -eq 'OK') {
        $virtualDisabled = $true
        Disable-PnpDevice -InstanceId $v.InstanceId -Confirm:$false
    }
    $start = Get-Date
    # Release 1.1.1: Meta looks for displays only once, right when its runtime starts. If the headset display was not
    # there at that moment, retry once (nothing else has been applied to the displays yet).
    for ($metaAttempt = 1; $metaAttempt -le 2; $metaAttempt++) {
        Start-Service OVRService
        $serverId = $null
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Milliseconds 500
            if (-not $GuardianSetup -and (Get-Process OculusDash -ErrorAction SilentlyContinue)) { throw 'Dash started despite suppression; aborting.' }
            $server = Get-Process OVRServer_x64 -ErrorAction SilentlyContinue
            if ($server) {
                if ($serverId -and $server.Id -ne $serverId) { throw 'VR server restarted; aborting.' }
                $serverId = $server.Id
            } elseif ($serverId) { throw 'VR server exited; aborting.' }
        }
        if (-not $serverId) { throw 'VR server did not start.' }
        if (-not $guardedTrial) { break }
        $bootLog = Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset)
        $candidateLogTail += $bootLog
        $enumDeadline = (Get-Date).AddSeconds(8)
        while ($bootLog -notmatch ('Enumerate verified target ' + $targetId + '\b') -and (Get-Date) -lt $enumDeadline) {
            Start-Sleep -Milliseconds 500
            if (-not (Get-Process -Id $serverId -ErrorAction SilentlyContinue)) { throw 'VR server exited; aborting.' }
            if (-not $GuardianSetup -and (Get-Process OculusDash -ErrorAction SilentlyContinue)) { throw 'Dash started despite suppression; aborting.' }
            $moreBootLog = Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset)
            $bootLog += $moreBootLog
            $candidateLogTail += $moreBootLog
        }
        if ($bootLog -match ('Enumerate verified target ' + $targetId + '\b')) { break }
        if ($metaAttempt -eq 1) {
            # Release 1.1.2: restarting the bridge runtime alone never brought the display back (it cannot wake the
            # headset). Wake it with Meta's normal runtime first, then switch to the bridge again right away.
            Write-Output 'Meta did not find the headset display (headset asleep or still waking up). Waking it with the normal Meta runtime, then retrying once...'
            Stop-ArcRiftMetaRuntime
            $originalBackend = $registry | Where-Object Name -eq 'DirectDisplayDLL'
            if ($originalBackend.Had) { New-ItemProperty $originalBackend.Path -Name 'DirectDisplayDLL' -Value $originalBackend.Value -PropertyType $originalBackend.Kind -Force | Out-Null }
            else { Remove-ItemProperty $originalBackend.Path -Name 'DirectDisplayDLL' -ErrorAction SilentlyContinue }
            $normalStart = Get-Date
            Start-Service OVRService
            Wait-ArcRiftHeadsetAwake $normalStart
            Stop-ArcRiftMetaRuntime
            $bridgeSetting = $settings | Where-Object Name -eq 'DirectDisplayDLL'
            New-ItemProperty $bridgeSetting.Path -Name $bridgeSetting.Name -Value $bridgeSetting.Value -PropertyType $bridgeSetting.Kind -Force | Out-Null
            continue
        }
        # Release 1.2: include the bridge's own reason (e.g. headset display not active in Windows) when it logged one.
        $lookupFailures = [regex]::Matches($bootLog, 'headset display not found: ([^\r\n]+)')
        $lookupReason = if ($lookupFailures.Count) { ' Bridge: ' + $lookupFailures[$lookupFailures.Count - 1].Groups[1].Value + '.' } else { '' }
        throw ('Selected backend did not enumerate verified display during runtime startup; refusing timing/render changes.' + $lookupReason)
    }
    if ($LinkDiagnostics) {
        & (Join-Path $root 'igcl_probe.exe') --link-status | Out-File -Encoding utf8 (Join-Path $out 'link-before-native.txt')
        & (Join-Path $root 'hid_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'hid-before-native.txt')
    }
    if ($NativeTiming) {
        # First enumerate the verified output while connected, then change timing.
        # Restarting PnP with the service stopped can hide the display at provider startup.
        & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-display-before-native.txt')
        $nativeFirstWait = 6
        if (-not $useTemporaryEdid) {
            # Rift CV1 (experimental): switch Windows to the mode in the headset's own EDID. The switch is temporary:
            # it is not saved, so Windows goes back to its saved mode on restore, after a restart, or when the headset
            # is unplugged and plugged back in. Meta's runtime was just restarted, so look the display source up again.
            $modeSource = $null
            $sourceDeadline = (Get-Date).AddSeconds(20)
            while ($true) {
                $modeSource = [ArcRiftDisplayMode]::Source($headsetPathId)
                if ($modeSource -or (Get-Date) -gt $sourceDeadline) { break }
                Start-Sleep -Milliseconds 500
            }
            if (-not $modeSource) { throw ('The ' + $headsetProfile.Name + ' display is not an active Windows display after Meta''s runtime restarted; refusing render test.') }
            if ($modeSwitch.Needed) {
                # headset-mode-switched.txt tells Recover that this session switched the display mode.
                ('Switched ' + $modeSource + ' from ' + $modeSwitch.Before + ' to ' + $modeSwitch.Width + ' ' + $modeSwitch.Height + ' ' + $modeSwitch.Hz + ' (width height hertz), temporary.') | Set-Content -LiteralPath (Join-Path $out 'headset-mode-switched.txt')
                $modeChanged = $true
                $modeResult = [ArcRiftDisplayMode]::Set($modeSource, $modeSwitch.Width, $modeSwitch.Height, $modeSwitch.Hz, $false)
                if ($modeResult -ne 0) { throw ('Windows refused to switch the headset display to ' + $nativeSize + ' at ' + $modeSwitch.Hz + ' Hz (result ' + $modeResult + ').') }
                Write-Output ('Headset display switched to its own mode, ' + $nativeSize + ' at ' + $modeSwitch.Hz + ' Hz. Temporary Windows display mode only: no EDID is changed and nothing is written to the headset.')
            } else { Write-Output ('Headset display is already in its own mode, ' + $nativeSize + ' at ' + $modeSwitch.Hz + ' Hz; nothing to switch.') }
            $nativeFirstWait = 2
        } else {
        $edidChanged = $true
        New-Item -Path $edidKey | Out-Null
        New-ItemProperty -LiteralPath $edidKey -Name '0' -Value $registryEdid -PropertyType Binary -Force | Out-Null
        Write-Output ('Temporary published native timing applied ONLY to verified ' + $headsetProfile.Name + ' monitor. Not a firmware write.')
        & pnputil.exe /restart-device $monitorInstance
        if ($LASTEXITCODE -ne 0) { throw 'Headset monitor restart failed.' }
        if ($headsetProfile.OwnEdid) {
            # Rift CV1 with the temporary EDID from CV1 MODE TEST. Unlike a Rift S, the headset display keeps its
            # identity, so Windows comes back in the mode it has saved for it (1920x1080): wait for the display,
            # check that its own mode is offered now, and switch to it. Temporary, as in the branch above.
            $wantedMode = $null
            $modeSource = $null
            $switchDeadline = (Get-Date).AddSeconds(30)
            Start-Sleep -Seconds 3
            while ($true) {
                $modeSource = [ArcRiftDisplayMode]::Source($headsetPathId)
                if ($modeSource) { Start-Sleep -Seconds 2; $wantedMode = Select-ArcRiftHeadsetMode @([ArcRiftDisplayMode]::Modes($modeSource)) }
                if ($wantedMode -or (Get-Date) -gt $switchDeadline) { break }
                Start-Sleep -Milliseconds 500
            }
            if (-not $wantedMode) { throw ('With the temporary display mode from CV1 MODE TEST applied, Windows still does not offer ' + $nativeSize + ' at ' + $headsetProfile.Hz + ' Hz. Run "CV1 MODE TEST.cmd" again and send its report.') }
            $modeSwitch.Hz = $wantedMode.Hz
            if ([ArcRiftDisplayMode]::Current($modeSource) -ne ([string]$modeSwitch.Width + ' ' + $modeSwitch.Height + ' ' + $modeSwitch.Hz)) {
                ('Switched ' + $modeSource + ' from ' + $modeSwitch.Before + ' to ' + $modeSwitch.Width + ' ' + $modeSwitch.Height + ' ' + $modeSwitch.Hz + ' (width height hertz), temporary, with the temporary EDID applied.') | Set-Content -LiteralPath (Join-Path $out 'headset-mode-switched.txt')
                $modeChanged = $true
                $modeResult = [ArcRiftDisplayMode]::Set($modeSource, $modeSwitch.Width, $modeSwitch.Height, $modeSwitch.Hz, $false)
                if ($modeResult -ne 0) { throw ('Windows refused to switch the headset display to ' + $nativeSize + ' at ' + $modeSwitch.Hz + ' Hz (result ' + $modeResult + ').') }
            }
            Write-Output ('Headset display switched to ' + $nativeSize + ' at ' + $modeSwitch.Hz + ' Hz with the temporary display mode from CV1 MODE TEST.')
            $nativeFirstWait = 2
        }
        } # end of the temporary EDID branch (Rift S always; Rift CV1 with cv1-override.edid)
        # Release 1.2: some PCs (seen on an Arc B580) take longer than 6 s to bring the headset back in its native mode
        # after the monitor restart. Check at 6 s as before, then every 2 s; the last capture is kept.
        # Release 1.3: wait up to 45 s (was 20 s). A PC that is ready sooner continues at once, as before.
        $nativeDeadline = (Get-Date).AddSeconds(45)
        Start-Sleep -Seconds $nativeFirstWait
        $nativeWaitTold = $false
        while ($true) {
            & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-display-after-runtime-start.txt')
            $probe = Get-Content (Join-Path $out 'physical-display-after-runtime-start.txt') -Raw
            $match = [regex]::Match($probe, '(?m)^\s*target=' + $targetId + ' [^\r\n]*' + $activePathFlags + '[^\r\n]*\r?\n[^\r\n]*(?i:' + [regex]::Escape($headsetPathId) + ')[^\r\n]*\r?\n\s*' + $nativeSignalPattern + ' vSync=(\d+)/(\d+)')
            if ($match.Success -or (Get-Date) -gt $nativeDeadline) { break }
            if (-not $nativeWaitTold) { Write-Output 'Waiting for the headset to come back in its native display mode...'; $nativeWaitTold = $true }
            Start-Sleep -Seconds 2
        }
        if (-not $match.Success) {
            $modeReport = Get-ArcRiftHeadsetModeReport $probe $targetId (Test-Path -LiteralPath $edidKey)
            $osNote = if ([Environment]::OSVersion.Version.Build -lt 22000) { ' This PC runs Windows 10; ArcRift is only tested on Windows 11.' } else { '' }
            $afterWhat = if ($headsetProfile.OwnEdid) { 'after the display mode switch' } else { 'after the headset monitor restart' }
            throw ('Expected native physical scanout was not confirmed within 45 s ' + $afterWhat + '; refusing render test. Found: ' + $modeReport + '.' + $osNote)
        }
        $hz = [double]$match.Groups[1].Value / [double]$match.Groups[2].Value
        if ($hz -lt ($headsetProfile.Hz - 1) -or $hz -gt ($headsetProfile.Hz + 1)) { throw 'Native scanout refresh rate was unexpected.' }
        Write-Output ('Physical native scanout verified: ' + $nativeSize + ' at ' + $hz + ' Hz.')
    }
    if ($NativeSource) {
        $holdSeconds = 45
        if ($SteamVR) { $holdSeconds = $SteamVRSeconds + 30 }
        if ($VRChatTrial -and -not $ManualSession -and $holdSeconds -ne $vrchatSettings.NativeHoldSeconds) { throw 'VRChat/native-helper time budgets do not match; refusing source apply.' }
        $sourceExe='native_source_test.exe'; $sourceArgs='--hold-managed '+$holdSeconds
        if ($ManualSession) { $sourceExe='native_source_session.exe'; $sourceArgs='--hold-session '+$PID }
        $sourceHelper = Start-Process -FilePath (Join-Path $root $sourceExe) -ArgumentList $sourceArgs -WorkingDirectory $out -RedirectStandardOutput (Join-Path $out 'native-source.txt') -RedirectStandardError (Join-Path $out 'native-source-stderr.txt') -PassThru
        $null = $sourceHelper.Handle
        $readyDeadline = (Get-Date).AddSeconds(5)
        while (-not (Test-Path (Join-Path $out 'native-source-ready.txt'))) {
            if ($sourceHelper.HasExited -or (Get-Date) -gt $readyDeadline) { throw 'Native desktop surface was not verified; refusing render test.' }
            Start-Sleep -Milliseconds 100
        }
        Write-Output 'Native desktop verified. Full EDID/runtime rollback is managed and verified by this harness; source-only timeout restore is NOT guaranteed.'
    }
    if ($GuardianSetup) {
        # Release 1.2.1: Guardian setup. Meta runs it inside Dash; ArcRift only watches and guards, then restores on Stop.
        'Guardian setup session (Meta Dash allowed, SteamVR not started).' | Set-Content (Join-Path $out 'guardian-setup.txt')
        $guardianDir = Join-Path $env:LOCALAPPDATA 'Oculus'
        $guardianSaved = $false
        $dashIds = @{}
        $dashStarts = New-Object System.Collections.Generic.List[datetime]
        $observationStart = Get-Date
        $nextEventCheck = Get-Date
        $readyWritten = $false
        $bridgeFpsPrevTick = $null; $bridgeLowFpsCount = 0
        Write-Output 'Put the headset on. Meta should show its Guardian setup (your room through the headset cameras): follow it and draw your play area with a controller. If Meta shows its home screen instead, open Settings > Guardian > Set up Guardian there.'
        while ($true) {
            if (Test-Path (Join-Path $out 'session-stop.txt')) { $userStopRequested = $true; Write-Output 'User requested stop; performing full rollback.'; break }
            if ($recoveryWatcher.HasExited) { throw 'Independent manual-session recovery watcher exited; stopping session.' }
            if ((Get-Date) -ge $manualDiskCheckAt) {
                $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))
                if ($drive.AvailableFreeSpace -lt 1GB) { throw 'Low disk space: stopping the session.' }
                $manualDiskCheckAt = (Get-Date).AddSeconds(30)
            }
            $server = @(Get-Process OVRServer_x64 -ErrorAction SilentlyContinue)
            if ($server.Count -ne 1 -or $server[0].Id -ne $serverId) { throw 'Meta runtime exited or restarted during Guardian setup.' }
            if ($sourceHelper -and $sourceHelper.HasExited) { throw 'Native source helper exited during Guardian setup.' }
            # Dash may restart on its own; a crash loop means it does not work on this GPU.
            foreach ($d in @(Get-Process OculusDash -ErrorAction SilentlyContinue)) {
                if (-not $dashIds.ContainsKey($d.Id)) {
                    $dashIds[$d.Id] = $true; $dashStarts.Add((Get-Date))
                    ('At ' + (Get-Date).ToString('o') + ': OculusDash PID=' + $d.Id + ' started') | Add-Content (Join-Path $out 'guardian-dash.txt')
                    if ($dashIds.Count -eq 1) { Write-Output 'Meta Dash started.' } else { Write-Output ('Meta Dash restarted (start ' + $dashIds.Count + ').') }
                }
            }
            while ($dashStarts.Count -and ((Get-Date) - $dashStarts[0]).TotalSeconds -gt 120) { $dashStarts.RemoveAt(0) }
            if ($dashStarts.Count -ge 4) { throw 'Meta Dash keeps crashing and restarting on this GPU (4 starts in 2 minutes), so Guardian setup cannot run. Restoring.' }
            if (-not $readyWritten -and ((Get-Date) - $observationStart).TotalSeconds -gt 3) {
                'Guardian setup session running. Optical verification is user-reported.' | Out-File (Join-Path $out 'session-ready.txt')
                $readyWritten = $true
            }
            # Same graphics guards as a normal session.
            $newLog = Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset) -OnlyIfGrown
            $candidateLogTail += $newLog
            if ($candidateLogTail.Length -gt 8192) { $candidateLogTail = $candidateLogTail.Substring($candidateLogTail.Length-8192) }
            if ($candidateLogTail -match '(?i:Renderer failed|Surface failed|Present frame=\d+ result=(?!00000000)[a-f0-9]{8}|Legacy Present health[^\r\n]*slow=1)') { throw 'Headset graphics failure or >100ms presentation stall detected; restoring.' }
            foreach ($m in [regex]::Matches($newLog,'(?m)^(\d+) Output surface frame=(\d+)')) {
                $tick=[double]$m.Groups[1].Value; $frame=[double]$m.Groups[2].Value
                if ($null -ne $bridgeFpsPrevTick -and $frame -gt $bridgeFpsPrevFrame -and $tick -gt $bridgeFpsPrevTick) {
                    $fps=($frame-$bridgeFpsPrevFrame)*1000.0/($tick-$bridgeFpsPrevTick)
                    # Stop only below 5 fps (was 45). A 120-frame sample that slow takes over 24 s to arrive.
                    if ($fps -lt 5) {
                        $bridgeLowFpsCount++
                        ('At ' + (Get-Date).ToString('o') + ': headset output ' + [math]::Round($fps,1) + ' fps (low sample ' + $bridgeLowFpsCount + ')') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                    } else { $bridgeLowFpsCount = 0 }
                    if ($bridgeLowFpsCount -ge 2) { throw 'Headset output dropped below 5 fps for 2 consecutive samples during Guardian setup; restoring.' }
                }
                $bridgeFpsPrevTick=$tick; $bridgeFpsPrevFrame=$frame
            }
            if ((Get-Date) -ge $nextEventCheck) {
                if (@(Get-WinEvent -FilterHashtable @{LogName='System';Id=4101;StartTime=$start} -ErrorAction SilentlyContinue).Count) { throw 'Windows reported a display-driver recovery during Guardian setup.' }
                $nextEventCheck = (Get-Date).AddSeconds(1)
                # Meta logs every Guardian change to GuardianBoundary_*.txt; a mode other than "off" with an outline means it is saved.
                if (-not $guardianSaved) {
                    $gb = Get-ChildItem $guardianDir -Filter 'GuardianBoundary_*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $start } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($gb) {
                        $gbText = Get-Content -LiteralPath $gb.FullName -Raw -ErrorAction SilentlyContinue
                        if ($gbText -match '"mode"\s*:\s*"(?!off")[a-z_]+"' -and $gbText -match '"outerBoundary"\s*:\s*\[\s*\[') {
                            $guardianSaved = $true
                            Copy-Item -LiteralPath $gb.FullName -Destination (Join-Path $out 'guardian-boundary.txt') -ErrorAction SilentlyContinue
                            'Guardian boundary saved by Meta.' | Set-Content (Join-Path $out 'guardian-saved.txt')
                            Write-Output 'Guardian saved by Meta. Take the headset off and press Stop & restore. Your next normal session should show the Guardian.'
                        }
                    }
                }
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $guardianSaved) { Write-Output 'Stopped before Meta saved a Guardian.' }
    } else {
    $clientArgs = '--render'
    if ($Visual) { $clientArgs = '--render-long' }
    if ($Stereo) { $clientArgs = '--stereo-pattern' }
    if ($TrackedScene) { $clientArgs = '--tracked-scene' }
    if ($shortHeadsetTrial) { $clientArgs = '--stereo-short' }
    if ($SteamVR) {
        $steamStarted = $true
        if (Test-Path -LiteralPath $steamGraphicsLog) { $steamGraphicsOffset = (Get-Item -LiteralPath $steamGraphicsLog).Length }
        if ($UserLaunchSteamTrial) {
            if ($DashboardNormalUserTrial) {
                # Release 1.4: a manual session no longer fails its launch on a few SteamVR sync timeouts while starting
                # (one on the very first frame stopped two sessions on 2026-11-15, with SteamVR render resolution at 150 %).
                $client = Start-ArcRiftSteamWorker -EvidenceDirectory $out -WaitForCompositor -MetaServerPid $serverId -SourceHelperPid $sourceHelper.Id -TolerateSyncTimeouts:$ManualSession
                $bootstrapServerId = $script:ArcRiftSteamWorkerStartupState.BootstrapServerId
                $bootstrapCompositorId = $script:ArcRiftSteamWorkerStartupState.BootstrapCompositorId
                if ([int]$script:ArcRiftSteamWorkerStartupState.BootstrapSyncTimeouts -gt 0) {
                    Write-Output ('SteamVR logged ' + [int]$script:ArcRiftSteamWorkerStartupState.BootstrapSyncTimeouts + ' sync timeout line(s) while starting; continuing. Frame-rate, freeze and device-loss guards stay active.')
                }
            } else {
                $client = Start-ArcRiftSteamWorker -EvidenceDirectory $out
            }
            Write-Output ('Normal-user SteamVR startup and diagnostic launched; diagnostic PID=' + $client.Id)
        } else {
            $startup = Start-Process -FilePath (Join-Path $steamBin 'vrstartup.exe') -WorkingDirectory $steamBin -PassThru
            Write-Output ('Starting installed SteamVR; bounded diagnostic only, startup PID=' + $startup.Id)
            if ($DashboardSameIntegrityTrial) {
                # Background diagnostics must NOT race vrstartup to create another server.
                $bootstrapDeadline = (Get-Date).AddSeconds(8)
                $bootstrapState = @{}
                $lastBootstrapSignature = ''
                $bootstrapEventCheck = Get-Date
                while ($true) {
                    $bootServers = @(Get-Process vrserver -ErrorAction SilentlyContinue)
                    $bootCompositors = @(Get-Process vrcompositor -ErrorAction SilentlyContinue)
                    $serverIds = @($bootServers | ForEach-Object { $_.Id })
                    $compositorIds = @($bootCompositors | ForEach-Object { $_.Id })
                    $signature = ($serverIds -join ',') + '/' + ($compositorIds -join ',')
                    if ($signature -ne $lastBootstrapSignature) {
                        $actors = @(Get-Process vrstartup,vrserver,vrcompositor,vrdashboard,vrwebhelper -ErrorAction SilentlyContinue | ForEach-Object {
                            [pscustomobject]@{Name=$_.Name; Pid=$_.Id; Session=$_.SessionId; Integrity=[ArcRiftIntegrityProbe]::Integrity($_.Id)}
                        })
                        [pscustomobject]@{Time=(Get-Date).ToString('o'); ServerIds=$serverIds; CompositorIds=$compositorIds; Actors=$actors} |
                            ConvertTo-Json -Depth 5 -Compress | Add-Content (Join-Path $out 'bootstrap-process-history.jsonl')
                        $lastBootstrapSignature = $signature
                    }
                    $steamGraphicsTail += Read-AppendedBridgeLog $steamGraphicsLog ([ref]$steamGraphicsOffset)
                    if ($steamGraphicsTail.Length -gt 8192) { $steamGraphicsTail = $steamGraphicsTail.Substring($steamGraphicsTail.Length-8192) }
                    if ($steamGraphicsTail -match '(?i:AcquireSync FAILED|ReleaseSync FAILED|WaitForAcquire timed out|DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG)') { throw 'SteamVR synchronization/device error during bootstrap.' }
                    $candidateLogTail += Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset)
                    if ($candidateLogTail.Length -gt 8192) { $candidateLogTail = $candidateLogTail.Substring($candidateLogTail.Length-8192) }
                    if ($candidateLogTail -match '(?i:Renderer failed|Surface failed|Present frame=\d+ result=(?!00000000)[a-f0-9]{8})') { throw 'Backend graphics failure during bootstrap.' }
                    if (Test-Path (Join-Path $out 'session-stop.txt')) { throw 'User requested stop during bootstrap; performing full rollback.' }
                    if ($sourceHelper.HasExited -or -not (Get-Process OVRServer_x64 -ErrorAction SilentlyContinue | Where-Object Id -eq $serverId)) { throw 'Meta server/native source helper exited during bootstrap.' }
                    if ((Get-Date) -ge $bootstrapEventCheck) {
                        if (@(Get-WinEvent -FilterHashtable @{LogName='System';Id=4101;StartTime=$start} -ErrorAction SilentlyContinue).Count) { throw 'Windows display recovery during bootstrap.' }
                        $bootstrapEventCheck = (Get-Date).AddSeconds(1)
                    }
                    if (Test-ArcRiftSteamVRStartup $bootstrapState $serverIds $compositorIds ($steamGraphicsTail -match 'Startup Complete')) {
                        $bootstrapServerId = $bootstrapState.ServerId
                        $bootstrapCompositorId = $bootstrapState.CompositorId
                        Write-Output ('Fresh compositor startup complete; launching background diagnostic only now. Server=' + $bootstrapServerId + ' compositor=' + $bootstrapCompositorId)
                        break
                    }
                    if ((Get-Date) -gt $bootstrapDeadline) { throw 'SteamVR compositor did not become ready within 8 seconds; diagnostic was not launched.' }
                    Start-Sleep -Milliseconds 100
                }
            }
            $client = Start-Process -FilePath (Join-Path $steamBin 'vrcmd.exe') -ArgumentList '--background --info --pollposes --pollcontrollers' -WorkingDirectory $steamBin -RedirectStandardOutput (Join-Path $out 'client.txt') -RedirectStandardError (Join-Path $out 'client-stderr.txt') -PassThru
        }
    } else {
        $client = Start-Process -FilePath (Join-Path $root 'ovr_d3d11_test.exe') -ArgumentList $clientArgs -WorkingDirectory $root -RedirectStandardOutput (Join-Path $out 'client.txt') -RedirectStandardError (Join-Path $out 'client-stderr.txt') -PassThru
    }
    # Retain the native process handle so ExitCode remains available after exit.
    $null = $client.Handle
    & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-display-during-client.txt')
    if ($LinkDiagnostics) {
        & (Join-Path $root 'igcl_probe.exe') --link-status | Out-File -Encoding utf8 (Join-Path $out 'link-during-client.txt')
        & (Join-Path $root 'hid_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'hid-during-client.txt')
    }
    $limit = 15
    if ($Visual) { $limit = 40 }
    if ($SteamVR) { $limit = $SteamVRSeconds }
    if ($shortHeadsetTrial) { $limit = 20 }
    $deadline = (Get-Date).AddSeconds($limit)
    if ($ManualSession) { $deadline=$null }
    $cutoffLabel=if ($ManualSession) { 'manual STOP (no duration cutoff)' } else { $deadline.ToString('HH:mm:ss') }
    if ($VRChatTrial) {
        [pscustomobject]@{Seconds=$(if ($ManualSession) {0} else {$limit}); ManualSession=[bool]$ManualSession; Started=(Get-Date).ToString('o'); Deadline=$(if ($ManualSession) {$null} else {$deadline.ToString('o')}); HarnessPid=$PID; GameLaunchedByHarness=$false} |
            ConvertTo-Json | Set-Content (Join-Path $out 'vrchat-trial-timing.json')
    }
    if ($SteamVR) { Write-Output ('SteamVR stop policy: ' + $cutoffLabel + '. Use Stop & restore in ArcRift Control (or STOP AND RESTORE.cmd) for full rollback; do not close this PowerShell window.') }
    $steamServerId = $bootstrapServerId
    $steamCompositorId = $bootstrapCompositorId
    $steamReady = $false
    $observationStart = Get-Date
    $candidateLastHealth = Get-Date
    $nextEventCheck = Get-Date
    $nextPresenceCheck = Get-Date
    while ($SteamVR -or -not $client.HasExited) {
        # Release 1.1.2: process-presence and token checks once per second, not every loop pass (each listing costs ~12 ms CPU).
        $presenceCheck = (Get-Date) -ge $nextPresenceCheck
        if ($presenceCheck) { $nextPresenceCheck = (Get-Date).AddSeconds(1) }
        if (Test-Path (Join-Path $out 'session-stop.txt')) { $userStopRequested = $true; Write-Output 'User requested early stop; performing full rollback.'; break }
        if ($ManualSession -and $recoveryWatcher.HasExited) { throw 'Independent manual-session recovery watcher exited; stopping session.' }
        if ($ManualSession -and (Get-Date) -ge $manualDiskCheckAt) {
            $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))
            if ($drive.AvailableFreeSpace -lt 1GB) { throw 'Low disk space: stopping manual session before diagnostic logs fill the drive.' }
            Limit-ArcRiftClientLog (Join-Path $out 'client.txt')
            $manualDiskCheckAt=(Get-Date).AddSeconds(30)
        }
        if ($VRChatTrial) {
            $pendingWarnings=@()
            if (-not $ManualSession) { $pendingWarnings=@(Get-ArcRiftVRChatWarnings (($deadline-(Get-Date)).TotalSeconds) $vrchatWarnings) }
            foreach ($warning in $pendingWarnings) {
                Write-Output ('VRCHAT CUTOFF WARNING: ' + $warning + ' seconds or less remain. Exit VRChat before automatic runtime/display cleanup.')
                ('At ' + (Get-Date).ToString('o') + ': ' + $warning + ' seconds or less remain; exit VRChat.') | Add-Content (Join-Path $out 'vrchat-countdown.txt')
            }
            # Process presence only: no game handles, token probing, memory reads or injection.
            foreach ($game in @(if ($presenceCheck) { Get-Process VRChat -ErrorAction SilentlyContinue })) {
                if (-not $vrchatObservedPids.ContainsKey($game.Id)) {
                    $vrchatObservedPids[$game.Id] = $true
                    ('Observed VRChat PID=' + $game.Id + ' at ' + (Get-Date).ToString('o') + '; presence does not prove successful VR rendering.') | Add-Content (Join-Path $out 'vrchat-process-observations.txt')
                    Write-Output 'VRChat process observed. Optical gameplay/comfort must be confirmed by user.'
                }
            }
        }
        if ($UserLaunchSteamTrial) {
            foreach ($p in @(if ($presenceCheck) { Get-Process OVRServer_x64,steam,explorer,vrstartup,vrmonitor,vrserver,vrcompositor,vrcmd -ErrorAction SilentlyContinue })) {
                if (-not $verifiedParticipantIds.ContainsKey($p.Id)) {
                    $rid = [ArcRiftIntegrityProbe]::Integrity($p.Id)
                    ($p.Name + ' PID=' + $p.Id + ' IntegrityRID=' + $rid) | Add-Content (Join-Path $out 'live-participant-integrity.txt')
                    $confirmedExited = $false
                    if ($rid -lt 0) {
                        $freshLauncher = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
                        if (-not $freshLauncher) { $confirmedExited = $true }
                        else {
                            try { $confirmedExited = $freshLauncher.HasExited } catch { $confirmedExited = $false }
                        }
                    }
                    $tokenDecision = Get-ArcRiftParticipantTokenDecision $p.Name $rid $confirmedExited
                    if ($tokenDecision -eq 'ExitedLauncher') {
                        ('Confirmed ' + $p.Name + ' exit PID=' + $p.Id + ' before token check; server/compositor/diagnostic guards remain active.') | Add-Content (Join-Path $out 'live-participant-integrity.txt')
                        continue
                    }
                    $verifiedParticipantIds[$p.Id] = $true
                }
            }
            if ($client.HasExited) { throw 'Normal-user diagnostic exited during SteamVR trial.' }
        }
        if ($guardedTrial) {
            $newLog = Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset) -OnlyIfGrown
            $candidateLogTail += $newLog
            if ($candidateLogTail.Length -gt 8192) { $candidateLogTail = $candidateLogTail.Substring($candidateLogTail.Length-8192) }
            if ($isolatedRendererTrial) {
                if ($candidateLogTail -match '(?i:Isolated[^\r\n]*(?:failed|failure|stalled|exceeded|exception|faulted=1))') { throw 'Isolated backend fault detected; stopping immediately.' }
                if ($newLog -match 'Isolated Present callbacks=') { $candidateLastHealth = Get-Date }
            } else {
                if ($candidateLogTail -match '(?i:Renderer failed|Surface failed|Present frame=\d+ result=(?!00000000)[a-f0-9]{8}|Legacy Present health[^\r\n]*slow=1)') { throw 'Legacy backend graphics failure or >100ms presentation stall detected.' }
                if ($newLog -match 'Present frame=|Output surface frame=|Legacy Present health') { $candidateLastHealth = Get-Date }
                if ($ManualSession) {
                    # Manual session: slow headset output no longer stops the session by itself. Samples under 20 fps are
                    # only noted in sync-hiccups.txt; the one frame-rate stop is the 5 fps limit below ($freezeSeconds).
                    # (Was: stop under 45 fps, then under 20 fps, for 2 consecutive 120-frame samples.)
                    foreach ($m in [regex]::Matches($newLog,'(?m)^(\d+) Output surface frame=(\d+)')) {
                        $tick=[double]$m.Groups[1].Value; $frame=[double]$m.Groups[2].Value
                        if ($null -ne $bridgeFpsPrevTick -and $frame -gt $bridgeFpsPrevFrame -and $tick -gt $bridgeFpsPrevTick) {
                            $fps=($frame-$bridgeFpsPrevFrame)*1000.0/($tick-$bridgeFpsPrevTick)
                            if ($fps -lt 20) {
                                $bridgeLowFpsCount++
                                ('At ' + (Get-Date).ToString('o') + ': headset output ' + [math]::Round($fps,1) + ' fps (low sample ' + $bridgeLowFpsCount + '; session continues)') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                            } else { $bridgeLowFpsCount = 0 }
                        }
                        $bridgeFpsPrevTick=$tick; $bridgeFpsPrevFrame=$frame
                    }
                }
            }
            $warmupSeconds = 5
            if ($guardedSteamTrial) { $warmupSeconds = 12 }
            if ($ManualSession) {
                # v2: pause the freeze check while Meta reports the headset off (proximity sensor / HMD unmounted).
                if ((Get-Date) -ge $metaLogCheckAt) {
                    $metaLogCheckAt = (Get-Date).AddSeconds(1)
                    $metaLogNow = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Oculus') -Filter 'Service_*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $start } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($metaLogNow -and $metaLogNow.FullName -ne $metaLogPath) {
                        if ($metaLogPath) { $metaLogOffset = 0L } else { $metaLogOffset = $metaLogNow.Length }
                        $metaLogPath = $metaLogNow.FullName
                        $metaLastGrowth = Get-Date
                        if (-not $trackingForcedChecked) {
                            # 1.4: Meta logs this once at start-up when it has read ForceSensorTracking. Never fails the session.
                            $trackingForcedChecked = $true
                            try {
                                [long]$metaLogFromStart = 0
                                if ((Read-AppendedBridgeLog $metaLogPath ([ref]$metaLogFromStart)) -match 'Tracking was forced on by regkey') {
                                    Write-Output 'Tracking stays on while the headset is off (Meta setting ForceSensorTracking), so taking it off or putting it down no longer makes Meta pause tracking.'
                                } else {
                                    Write-Output 'Note: Meta''s runtime did not confirm the keep-tracking-on setting (ForceSensorTracking). Putting the headset down for a while may still crash it.'
                                }
                            } catch { Write-Output ('Keep-tracking-on check note (session unaffected): ' + $_.Exception.Message) }
                        }
                    }
                }
                # Meta crash watchdog (1.4): a new report in Meta's own crash folder means its runtime crashed. Seen
                # within 2 s, instead of after 30 s of log silence.
                if ((Get-Date) -ge $metaCrashCheckAt) {
                    $metaCrashCheckAt = (Get-Date).AddSeconds(2)
                    $metaCrashes = @(Get-ArcRiftNewMetaCrash)
                    if ($metaCrashes.Count) { $metaCrashAt = Get-Date; Save-ArcRiftMetaCrashRecord $metaCrashes; throw 'Meta runtime crashed (Meta wrote a crash report; see meta-crash.txt); stopping and restoring so a fresh session can be started.' }
                }
                if ($metaLogPath) {
                    $metaNew = Read-AppendedBridgeLog $metaLogPath ([ref]$metaLogOffset)
                    # v5 freeze watchdog: Meta logs at least every ~15 s even when idle (longest normal gap seen: 13.5 s).
                    # Every stop of this kind checked so far was a crash (above); this stays as the fallback for a real hang.
                    if ($metaNew.Length -gt 0) { $metaLastGrowth = Get-Date }
                    elseif (((Get-Date) - $metaLastGrowth).TotalSeconds -gt 30) {
                        $metaCrashes = @(Get-ArcRiftNewMetaCrash)
                        if ($metaCrashes.Count) { $metaCrashAt = Get-Date; Save-ArcRiftMetaCrashRecord $metaCrashes; throw 'Meta runtime crashed (Meta wrote a crash report; see meta-crash.txt); stopping and restoring so a fresh session can be started.' }
                        Save-ArcRiftMetaHangRecord; throw 'Meta runtime stopped responding (its log was silent for 30 s); stopping and restoring so a fresh session can be started.'
                    }
                    foreach ($metaLine in ($metaNew -split "`r?`n")) {
                        if ($metaLine -match 'Proximity state changed \(1 -> 0\)|Broadcasting HMD unmounted event') {
                            if (-not $headsetOff) {
                                $headsetOff = $true; $headsetOffSince = Get-Date
                                Write-Output 'Headset off: freeze check paused until it is worn again. Other guards stay active.'
                                ('At ' + (Get-Date).ToString('o') + ': headset off, freeze check paused') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                            }
                        } elseif ($metaLine -match 'Proximity state changed \(0 -> 1\)|Broadcasting HMD mounted event') {
                            if ($headsetOff) {
                                $headsetOff = $false
                                $candidateLastHealth = Get-Date; $bridgeFpsPrevTick = $null; $bridgeLowFpsCount = 0
                                Write-Output 'Headset on: freeze check resumes after a 24-second grace period.'
                                ('At ' + (Get-Date).ToString('o') + ': headset on, freeze check resumes') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                            }
                        } elseif ($metaLine -match 'Setting tracking mode to off') {
                            # 1.4: should not happen with ForceSensorTracking. Record it, so a crash that follows can be tied to it.
                            ('At ' + (Get-Date).ToString('o') + ': Meta paused tracking although ForceSensorTracking is set') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                            if (-not $trackingPauseWarned) {
                                $trackingPauseWarned = $true
                                Write-Output 'Note: Meta paused tracking although ForceSensorTracking is set. Picking the headset up may crash Meta''s runtime; the session then restores and restarts by itself.'
                            }
                        }
                    }
                }
                if ($headsetOff -and ((Get-Date)-$headsetOffSince).TotalSeconds -gt 3 -and $newLog -match 'Output surface frame=') {
                    # Frames are flowing again (e.g. proximity bypass on): resume normal checking.
                    $headsetOff = $false; $bridgeFpsPrevTick = $null; $bridgeLowFpsCount = 0
                    ('At ' + (Get-Date).ToString('o') + ': frames flowing while marked off, freeze check resumes') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                }
                if ($headsetOff) { $candidateLastHealth = Get-Date }
            }
            # The bridge logs one line per 120 frames, so the time allowed between lines sets the lowest frame rate a
            # session survives: 3 s = 40 fps for the short guarded trials. Manual sessions allow 24 s = 5 fps, the only
            # frame-rate stop they have (it was 10 s, which stopped anything under 12 fps). A real freeze logs nothing
            # at all, so it now stops after 24 s instead of 10 s.
            $freezeSeconds = 3
            if ($ManualSession) { $freezeSeconds = 24 }
            if (((Get-Date)-$observationStart).TotalSeconds -gt $warmupSeconds -and ((Get-Date)-$candidateLastHealth).TotalSeconds -gt $freezeSeconds) {
                if ($ManualSession) { throw 'Headset output dropped below 5 fps or froze (fewer than 120 frames in 24 s); stopping and restoring.' }
                throw ('Backend presentation health log stopped progressing (no headset frames for ' + $freezeSeconds + ' s).')
            }
            if ($guardedSteamTrial) {
                if ($ManualSession) {
                    # Manual session: tolerate isolated sync hiccups (seen when VRChat launches), stop on floods or device loss.
                    $newSteamGraphics = Read-AppendedBridgeLog $steamGraphicsLog ([ref]$steamGraphicsOffset)
                    foreach ($syncLine in ($newSteamGraphics -split "`r?`n")) {
                        if ($syncLine -match '(?i:DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG)') { throw 'SteamVR reported GPU device removed/hung; aborting.' }
                        if ($syncLine -match '(?i:AcquireSync FAILED|ReleaseSync FAILED|WaitForAcquire timed out)') {
                            $syncNow = Get-Date
                            while ($syncHiccupTimes.Count -and ($syncNow - $syncHiccupTimes[0]).TotalSeconds -gt 30) { $syncHiccupTimes.RemoveAt(0) }
                            if ($syncFloodSince -and $syncHiccupTimes.Count -le 20) {
                                $syncFloodSince = $null
                                Write-Output 'SteamVR sync errors back to normal.'
                            }
                            if ($syncLine -match '(?i:AcquireSync FAILED)') {
                                # one AcquireSync line per hitch, plus any SteamVR hid with [N messages suppressed]
                                $syncAdd = 1
                                if ($syncLine -match '\[(\d+) messages suppressed\]') { $syncAdd += [int]$matches[1] }
                                for ($k = 0; $k -lt $syncAdd; $k++) { $syncHiccupTimes.Add($syncNow) }
                            }
                            while ($syncHiccupTimes.Count -and ($syncNow - $syncHiccupTimes[0]).TotalSeconds -gt 30) { $syncHiccupTimes.RemoveAt(0) }
                            ('At ' + $syncNow.ToString('o') + ' (' + $syncHiccupTimes.Count + ' hitches in last 30s): ' + $syncLine.Trim()) | Add-Content (Join-Path $out 'sync-hiccups.txt')
                            # A slow game (e.g. VRChat CPU-bound in a busy world) floods these too; the headset frame-rate,
                            # stall and device-loss guards cover real presentation trouble, so sync errors are only noted and never stop
                            # the session. (Was: stop after more than 20 in 30 s for 2 minutes.)
                            if ($syncHiccupTimes.Count -gt 20) {
                                if (-not $syncFloodSince) {
                                    $syncFloodSince = $syncNow
                                    Write-Output 'SteamVR sync errors high (game running slowly). Session continues; sync errors alone never stop it. Lower game settings if you can.'
                                }
                            }
                            if ($syncLine -match '(?i:AcquireSync FAILED)' -and $syncLine -match '(?i:OMITTING additional logs)') { Write-Output 'SteamVR sync burst (SteamVR hid further warnings for 30s). Headset frame-rate and stall guards still active.' }
                        }
                    }
                } else {
                    $steamGraphicsTail += Read-AppendedBridgeLog $steamGraphicsLog ([ref]$steamGraphicsOffset)
                    if ($steamGraphicsTail.Length -gt 8192) { $steamGraphicsTail = $steamGraphicsTail.Substring($steamGraphicsTail.Length-8192) }
                    if ($steamGraphicsTail -match '(?i:AcquireSync FAILED|ReleaseSync FAILED|WaitForAcquire timed out|DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG)') { throw 'SteamVR graphics synchronization/device error detected; aborting rather than waiting through corruption.' }
                }
            }
            if ((Get-Date) -ge $nextEventCheck) {
                $displayReset = @(Get-WinEvent -FilterHashtable @{LogName='System';Id=4101;StartTime=$start} -ErrorAction SilentlyContinue)
                if ($displayReset.Count) { throw 'Windows reported a display-driver recovery during trial.' }
                $nextEventCheck = (Get-Date).AddSeconds(1)
            }
        }
        if ($sourceHelper -and $sourceHelper.HasExited) { throw 'Native source helper exited before client finished.' }
        if (-not $ManualSession -and (Get-Date) -gt $deadline) {
            if ($SteamVR) { Write-Output 'SteamVR observation interval complete.'; break }
            throw 'Client time limit reached.'
        }
        # One process listing for all four exit/restart guards (still every pass).
        $watched = @(Get-Process OVRServer_x64,OculusDash,vrserver,vrcompositor -ErrorAction SilentlyContinue)
        $server = $watched | Where-Object Name -eq 'OVRServer_x64'
        if (-not $server -or $server.Id -ne $serverId) { throw 'VR server exited/restarted during client test.' }
        if ($watched | Where-Object Name -eq 'OculusDash') { throw 'Dash appeared during client test.' }
        if ($SteamVR) {
            $ss = $watched | Where-Object Name -eq 'vrserver'
            $sc = $watched | Where-Object Name -eq 'vrcompositor'
            if (($DashboardSameIntegrityTrial -or $DashboardNormalUserTrial) -and (@($ss).Count -gt 1 -or @($sc).Count -gt 1)) { throw 'Multiple SteamVR servers/compositors appeared after bootstrap.' }
            if ($DashboardNormalUserTrial -and -not $dashboardTrialState -and ((Get-Date)-$observationStart).TotalSeconds -gt 3) {
                @(Get-Process vrdashboard,vrwebhelper -ErrorAction SilentlyContinue | ForEach-Object {
                    [pscustomobject]@{Name=$_.Name; Pid=$_.Id; Integrity=[ArcRiftIntegrityProbe]::Integrity($_.Id)}
                }) | ConvertTo-Json | Set-Content (Join-Path $out 'normal-dashboard-tokens.json')
                $dashboardTrialState = [pscustomobject]@{Recorded=$true}
                if ($VRChatTrial) {
                    Write-Output ('SteamVR is starting as your normal user. Stop policy: ' + $cutoffLabel + '.')
                } else {
                    Write-Output 'Normal-user dashboard trial: press LEFT Touch menu button. No game launch.'
                }
            }
            if ($ss) {
                if ($steamServerId -and $steamServerId -ne $ss.Id) { throw 'SteamVR server restarted.' }
                $steamServerId = $ss.Id
            } elseif ($steamServerId) { throw 'SteamVR server exited.' }
            if ($sc) {
                if ($steamCompositorId -and $steamCompositorId -ne $sc.Id) { throw 'SteamVR compositor restarted.' }
                $steamCompositorId = $sc.Id
            } elseif ($steamCompositorId) { throw 'SteamVR compositor exited.' }
            if ($DashboardSameIntegrityTrial -and $ss -and $sc) {
                if (-not $dashboardTrialState -and ((Get-Date)-$observationStart).TotalSeconds -gt 3) {
                    $dashboardTrialState = Invoke-ArcRiftDashboardIntegrityTrial -SteamRoot $steamRoot -EvidenceDirectory $out
                    if ($dashboardTrialState) { Write-Output 'Dashboard token inspection complete. Press the LEFT controller menu button to request SteamVR dashboard; do not launch games.' }
                    elseif (((Get-Date)-$observationStart).TotalSeconds -gt 15) { throw 'Dashboard processes never became available for token inspection.' }
                }
                if ($dashboardTrialState -and $dashboardTrialState.Replaced) {
                    foreach ($p in $dashboardTrialState.Processes) {
                        if ($p.HasExited) { throw ('Replacement dashboard process exited: ' + $p.ProcessName) }
                    }
                }
            }
            if (-not $steamReady -and $ss -and $sc -and ((Get-Date) - $observationStart).TotalSeconds -gt 5 -and (Get-Item (Join-Path $out 'client.txt')).Length -gt 0) {
                $steamReady = $true
                'SteamVR processes running and diagnostic output received. Optical verification is user-reported.' | Out-File (Join-Path $out 'session-ready.txt')
                if ($VRChatTrial) {
                    Write-Output ('VR ready. Start your SteamVR game. Stop policy: ' + $cutoffLabel + '. When done, quit the game and use Stop & restore.')
                    # v3: optional read-only frame-timing capture (PresentMon). Never affects the session.
                    # Release 1.1.2: other SteamVR games are added when SteamVR reports them (see the game check below).
                    if ($ManualSession -and (Test-Path -LiteralPath (Join-Path $root 'PresentMon.exe'))) { Start-ArcRiftPresentMon }
                    # v4: give SteamVR's and Meta's compositors high GPU/CPU priority (SteamVR runs as a normal user, so it
                    # cannot raise its own). Lives only as long as those processes; never fails the session.
                    if ($ManualSession) {
                        try {
                            if (-not ('ArcRiftGpuPriority' -as [type])) {
                                Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class ArcRiftGpuPriority {
    [DllImport("gdi32.dll")] public static extern int D3DKMTSetProcessSchedulingPriorityClass(IntPtr hProcess, int priority);
    [DllImport("gdi32.dll")] public static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr hProcess, out int priority);
}
'@
                            }
                            foreach ($bp in @(Get-Process vrcompositor,OVRServer_x64 -ErrorAction SilentlyContinue)) {
                                $gpuBefore = -1; $null = [ArcRiftGpuPriority]::D3DKMTGetProcessSchedulingPriorityClass($bp.Handle, [ref]$gpuBefore)
                                $gpuStatus = 'kept'
                                if ($gpuBefore -ge 0 -and $gpuBefore -lt 4) { $gpuStatus = 'set HIGH status=0x' + ([ArcRiftGpuPriority]::D3DKMTSetProcessSchedulingPriorityClass($bp.Handle, 4)).ToString('x8') }
                                $gpuAfter = -1; $null = [ArcRiftGpuPriority]::D3DKMTGetProcessSchedulingPriorityClass($bp.Handle, [ref]$gpuAfter)
                                $cpuBefore = $bp.PriorityClass
                                try { if ($bp.PriorityClass -eq 'Normal') { $bp.PriorityClass = 'High' } } catch {}
                                $boostLine = $bp.Name + ' PID=' + $bp.Id + ' GPU priority ' + $gpuBefore + ' -> ' + $gpuAfter + ' (' + $gpuStatus + '; 2=normal 4=high 5=realtime), CPU ' + $cpuBefore + ' -> ' + $bp.PriorityClass
                                Write-Output ('Performance boost: ' + $boostLine)
                                $boostLine | Add-Content (Join-Path $out 'performance-boost.txt')
                            }
                        } catch { Write-Output ('Performance boost skipped (session unaffected): ' + $_.Exception.Message) }
                    }
                } elseif ($guardedSteamTrial) {
                    Write-Output 'SteamVR diagnostic ready. Remain seated; do not launch games during this bounded trial.'
                } else {
                    Write-Output 'SteamVR ready for user trial. Start games normally through Steam; game processes are not managed or terminated by this harness.'
                }
            }
        }
        if ($presentMonProcess -and (Get-Date) -ge $nextGameCheck) {
            # Add any newly connected SteamVR game to the frame-timing capture. Read-only; never fails the session.
            $nextGameCheck = (Get-Date).AddSeconds(2)
            try {
                $newGames = @()
                $vrserverText = Read-AppendedBridgeLog (Join-Path $steamPath 'logs\vrserver.txt') ([ref]$vrserverLogOffset)
                foreach ($m in [regex]::Matches($vrserverText, 'New Connect message from (.+?\.exe) \(VRApplication_Scene\)')) {
                    $exe = [IO.Path]::GetFileName($m.Groups[1].Value)
                    if ($exe -and $exe -notin $presentMonGames -and $exe -notin $newGames) { $newGames += $exe }
                }
                if ($newGames.Count) { $presentMonGames += $newGames; Start-ArcRiftPresentMon }
            } catch { Write-Output ('Game check for frame timing skipped (session unaffected): ' + $_.Exception.Message) }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($SteamVR) {
        Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) } | Select-Object Name,Id,Path | Export-Clixml (Join-Path $out 'steamvr-processes.xml')
        if (-not (Get-Process vrserver -ErrorAction SilentlyContinue) -or -not (Get-Process vrcompositor -ErrorAction SilentlyContinue)) { throw 'SteamVR server/compositor did not remain running; inspect native logs.' }
        Write-Output 'SteamVR interval ended; consult native logs for actual initialization/rendering success.'
    } else {
        if ($userStopRequested -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force -ErrorAction Continue }
        $client.WaitForExit()
        Write-Output ('Client exit=' + $client.ExitCode)
        Get-Content (Join-Path $out 'client.txt') | Select-Object -Last 25
        if ($client.ExitCode -ne 0 -and -not $userStopRequested) { throw 'Diagnostic client failed.' }
        if ($isolatedRendererTrial -and -not $userStopRequested) {
            $candidateLogTail += Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset)
            $health = [regex]::Matches($candidateLogTail,'Isolated Present callbacks=[^\r\n]*presented=(\d+)')
            if (-not $health.Count -or [int]$health[$health.Count-1].Groups[1].Value -lt 1) { throw 'No successful isolated backend presentation confirmed.' }
            if ($candidateLogTail -match '(?i:Isolated[^\r\n]*(?:failed|failure|stalled|exceeded|exception|faulted=1))') { throw 'Isolated backend fault detected at trial end.' }
        }
    }
    } # Release 1.2.1: end of the normal (non-Guardian) session path
} catch {
    $failed = $true
    Write-Output ('TEST STOP: ' + $_.Exception.Message)
} finally {
    Stop-ArcRiftPresentMon
    if ($VRChatTrial -and (Get-Process VRChat -ErrorAction SilentlyContinue)) {
        Write-Output 'VRChat is still running. Restoring display and runtime now; the game is not force-closed. Close it normally.'
    }
    if ($startupSeedOwned) {
        try {
            Remove-Item -LiteralPath $startupSeed -ErrorAction Stop
            if (Test-Path -LiteralPath $startupSeed) { throw 'Startup identity seed remains.' }
            Write-Output 'Owned startup metadata seed removed; no retained identity remains enabled.'
        } catch { $failed = $true; Write-Output ('STARTUP IDENTITY CLEANUP ERROR: ' + $_.Exception.Message) }
    }
    if ($UserLaunchSteamTrial) {
        'Cancel any pending broker launch.' | Set-Content (Join-Path $out 'user-worker-cancel.txt')
        if ($script:ArcRiftSteamWorkerProcess -and -not $script:ArcRiftSteamWorkerProcess.HasExited) {
            try { $script:ArcRiftSteamWorkerProcess.Kill(); $null = $script:ArcRiftSteamWorkerProcess.WaitForExit(2000) }
            catch { $failed = $true; Write-Output ('WORKER CLEANUP ERROR: ' + $_.Exception.Message) }
        }
    }
    if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force -ErrorAction Continue }
    if ($steamStarted) {
        # All SteamVR-root processes were absent at preflight. Never stop Steam itself or games.
        try {
            Get-Process vrmonitor -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $null = $_.CloseMainWindow() }
            Start-Sleep -Seconds 1
            for ($pass = 0; $pass -lt 3; $pass++) {
                $owned = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) })
                if (-not $owned.Count) { break }
                $owned | Stop-Process -Force -ErrorAction Continue
                Start-Sleep -Milliseconds 200
            }
            $remaining = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) })
            if ($remaining.Count) { throw 'Test-started SteamVR processes remain.' }
            foreach ($name in @('vrserver.txt','vrcompositor.txt','vrmonitor.txt','vrstartup.txt','vrdashboard.txt','vrclient_vrdashboard.txt','vrwebhelper_main.txt','vrclient_vrwebhelper_main.txt','vrclient_steam.txt','vrclient_vrcmd.txt','vrclient_vrmonitor.txt')) {
                $log = Join-Path (Join-Path $steamPath 'logs') $name
                if (Test-Path $log) { Copy-Item -LiteralPath $log -Destination $out }
            }
            if (Test-Path $steamConfig) { Copy-Item -LiteralPath $steamConfig -Destination (Join-Path $out 'steamvr-settings-after.json') }
            Write-Output 'Test-started SteamVR processes stopped. No SteamVR settings were explicitly changed by harness.'
        } catch { $failed = $true; Write-Output ('STEAMVR CLEANUP ERROR: ' + $_.Exception.Message) }
    }
    if ($sourceHelper) {
        'Stop and restore source layout.' | Out-File (Join-Path $out 'native-source-stop.txt')
        if (-not $sourceHelper.WaitForExit(6000)) { Stop-Process -Id $sourceHelper.Id -Force -ErrorAction Continue }
        if ($sourceHelper.ExitCode -ne 0) {
            $failed = $true
            Write-Output 'Source helper failed; attempting backup restoration before EDID rollback.'
            if (Test-Path (Join-Path $out 'native-source-backup.bin')) {
                $restore = Start-Process -FilePath (Join-Path $root 'native_source_test.exe') -ArgumentList '--restore' -WorkingDirectory $out -RedirectStandardOutput (Join-Path $out 'native-source-emergency-restore.txt') -PassThru -Wait
                if ($restore.ExitCode -ne 0) { Write-Output 'SOURCE RESTORE ERROR: emergency restoration failed.' }
            }
        }
        Get-Content (Join-Path $out 'native-source.txt') -ErrorAction Continue
    }
    if ($changed) {
        # Release 1.2.1: Guardian setup let Meta's Dash run; close it before and after stopping Meta's runtime.
        if ($GuardianSetup) { Get-Process OculusDash -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Continue }
        try { Stop-ArcRiftMetaRuntime } catch { $failed = $true; Write-Output ('RUNTIME STOP ERROR: ' + $_.Exception.Message) }
        if ($GuardianSetup) { Get-Process OculusDash -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Continue }
        # Only this session's part of the bridge log, not every earlier session's lines again.
        try { [IO.File]::WriteAllText((Join-Path $out 'bridge-log.txt'), (Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogSessionStart))) }
        catch { Write-Output ('Bridge log copy note (rollback unaffected): ' + $_.Exception.Message) }
        Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Oculus') -Filter 'Service_*.txt' | Where-Object { $_.LastWriteTime -ge $start -and $_.Length -gt 0 } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $out -ErrorAction Continue
        }
        foreach ($s in $registry) {
            try {
                if ($s.Had) { New-ItemProperty $s.Path -Name $s.Name -Value $s.Value -PropertyType $s.Kind -Force | Out-Null }
                elseif (Test-Path $s.Path) { Remove-ItemProperty $s.Path -Name $s.Name -ErrorAction SilentlyContinue }
            } catch { $failed = $true; Write-Output ('REGISTRY RESTORE ERROR: ' + $_.Exception.Message) }
        }
        foreach ($m in $moves) {
            try {
                if (Test-Path -LiteralPath $m.Temporary) {
                    if (Test-Path -LiteralPath $m.Original) { throw ('Restore conflict: ' + $m.Original) }
                    Move-Item -LiteralPath $m.Temporary -Destination $m.Original
                }
                if ((Get-FileHash -LiteralPath $m.Original -Algorithm SHA256).Hash -ne $m.Hash) { throw ('Hash mismatch: ' + $m.Original) }
                Write-Output ('Plugin restored/hash verified: ' + [IO.Path]::GetFileName($m.Original))
            } catch { $failed = $true; Write-Output ('PLUGIN RESTORE ERROR: ' + $_.Exception.Message) }
        }
        foreach ($p in $createdKeys) {
            if (Test-Path $p) { $k = Get-Item $p; if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item $p -ErrorAction Continue } }
        }
        if ($virtualDisabled) { Enable-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -Confirm:$false -ErrorAction Continue }
        if ($edidChanged) {
            try {
                Remove-ItemProperty -LiteralPath $edidKey -Name '0' -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $edidKey) {
                    $k = Get-Item -LiteralPath $edidKey
                    if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $edidKey }
                }
                & pnputil.exe /restart-device $monitorInstance
                if ($LASTEXITCODE -ne 0) {
                    # v5: the Rift S display only exists while Meta's runtime runs; start it, then retry.
                    Start-Service OVRService -ErrorAction Continue
                    $monitorRestarted = $false
                    for ($i = 0; $i -lt 20 -and -not $monitorRestarted; $i++) {
                        Start-Sleep -Seconds 2
                        & pnputil.exe /restart-device $monitorInstance
                        if ($LASTEXITCODE -eq 0) { $monitorRestarted = $true }
                    }
                    if (-not $monitorRestarted) { throw 'Monitor restart during rollback failed.' }
                }
                Start-Sleep -Seconds 3
                & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-display-after-rollback.txt')
                Write-Output 'Original absent EDID override restored; monitor restarted.'
            } catch { $failed = $true; Write-Output ('EDID RESTORE ERROR: ' + $_.Exception.Message) }
        }
        if ($modeChanged) {
            # Rift CV1 (experimental): put the headset display back in the mode Windows has saved for it. If Windows
            # does not go back by itself, set the mode from before the session; last, restart the monitor device, which
            # is what brings a Rift S back. The check against the baseline below decides whether it worked.
            try {
                $restoreSource = [ArcRiftDisplayMode]::Source($headsetPathId)
                if ($restoreSource) {
                    $restoreResult = [ArcRiftDisplayMode]::Restore($restoreSource)
                    Start-Sleep -Seconds 3
                    $modeNow = [ArcRiftDisplayMode]::Current($restoreSource)
                    $beforeParts = @($modeSwitch.Before -split ' ')
                    if ($modeNow -ne $modeSwitch.Before -and $beforeParts.Count -eq 3) {
                        $restoreResult = [ArcRiftDisplayMode]::Set($restoreSource, [int]$beforeParts[0], [int]$beforeParts[1], [int]$beforeParts[2], $false)
                        Start-Sleep -Seconds 3
                        $modeNow = [ArcRiftDisplayMode]::Current($restoreSource)
                    }
                    if ($modeNow -ne $modeSwitch.Before) {
                        Write-Output ('Headset display is still at ' + $modeNow + ' (result ' + $restoreResult + '); restarting its monitor device.')
                        & pnputil.exe /restart-device $monitorInstance
                        Start-Sleep -Seconds 3
                    }
                    Write-Output ('Headset display mode put back (was ' + $modeSwitch.Before + ' before the session, width height hertz).')
                } else { Write-Output 'The headset display is not active right now; Windows uses its saved mode when it comes back (the session''s mode was never saved).' }
                & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-display-after-rollback.txt')
            } catch { $failed = $true; Write-Output ('DISPLAY MODE RESTORE ERROR: ' + $_.Exception.Message) }
        }
        Start-Service OVRService -ErrorAction Continue
        try {
            $restored = $false
            for ($attempt = 0; $attempt -lt 10; $attempt++) {
                Start-Sleep -Seconds 1
                & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-after-original-runtime.txt')
                if ($LASTEXITCODE -ne 0) { continue }
                # A probe taken while the display is still settling may list no active layout yet: retry, don't fail.
                try { $afterLayouts = Get-ActiveLayouts (Get-Content (Join-Path $out 'physical-after-original-runtime.txt') -Raw) } catch { continue }
                $same = $afterLayouts.Count -eq $baselineLayouts.Count
                foreach ($id in $baselineLayouts.Keys) { if ($afterLayouts[$id] -ne $baselineLayouts[$id]) { $same = $false } }
                if ($same) { $restored = $true; break }
            }
            if (-not $restored) { throw 'Display source/signal layouts differ from baseline; manual recovery required.' }
            if (Test-Path -LiteralPath $edidKey) { throw 'Temporary EDID override still present.' }
            foreach ($s in $registry) {
                $k = Get-Item $s.Path -ErrorAction SilentlyContinue
                $had = $k -and ($k.GetValueNames() -contains $s.Name)
                if ([bool]$had -ne $s.Had -or ($s.Had -and ($k.GetValue($s.Name) -ne $s.Value -or $k.GetValueKind($s.Name).ToString() -ne $s.Kind))) { throw ('Registry mismatch: ' + $s.Name) }
            }
            if ((Get-Service OVRService).Status -ne 'Running') { throw 'Original runtime service not running.' }
            if ($virtualDisabled -and (Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -PresentOnly).Status -ne 'OK') { throw 'Virtual Monitor was not restored.' }
            Write-Output 'ROLLBACK VERIFIED: all active source/signal layouts match baseline; registry, EDID, service and Virtual Monitor restored.'
            $rollbackVerified=$true
        } catch { $failed = $true; Write-Output ('ROLLBACK VERIFICATION ERROR: ' + $_.Exception.Message) }
    }
    if ($sessionLock) {
        if ($ManualSession -and (Test-Path $manualRecoveryFile)) {
            $state=Get-Content $manualRecoveryFile -Raw | ConvertFrom-Json
            $state.CleanupVerified=$rollbackVerified -or -not $changed
            $state | ConvertTo-Json | Set-Content $manualRecoveryFile
        }
        if (-not $ManualSession -or $rollbackVerified -or -not $changed) { Remove-Item -LiteralPath $activeSession -ErrorAction Continue }
        else { Write-Output 'Manual recovery marker retained. Run RECOVER in this folder after harness exits.' }
        $sessionLock.Dispose()
        Remove-Item -LiteralPath $sessionLockPath -ErrorAction Continue
    }
    # Release 1.4: after the known headset-down Meta crash, start a fresh session by itself (the folder lock and
    # marker are released above). Never after Stop & restore, an unverified restore, or three restarts in a row.
    try {
        $readyItem = Get-Item -LiteralPath (Join-Path $out 'session-ready.txt') -ErrorAction SilentlyContinue
        $restartDecision = Get-ArcRiftAutoRestartDecision -Manual $ManualSession.IsPresent -Guardian $GuardianSetup.IsPresent -CrashAt $metaCrashAt `
            -RollbackVerified $rollbackVerified -StopRequested ($userStopRequested -or (Test-Path -LiteralPath (Join-Path $out 'session-stop.txt'))) `
            -ReadyAt $(if ($readyItem) { $readyItem.LastWriteTime } else { $null }) -Count $AutoRestartCount
        if ($restartDecision -eq '') { Start-ArcRiftAutoRestart }
        elseif ($restartDecision) { Write-Output $restartDecision }
    } catch { Write-Output ('Automatic restart not started: ' + $_.Exception.Message + ' Start a new session from ArcRift Control.') }
    Stop-Transcript
}
if ($failed) { exit 1 }
