# ArcRift 1.4 (Rift CV1, experimental): find out which display modes the graphics driver accepts for the CV1.
#
# Why: on the first tester's Arc B580 (HDMI) Windows does not offer the CV1's only mode, 2160x1200 at 90 Hz, so a
# session cannot start. Windows builds a display's mode list from its EDID, and the graphics driver then removes what
# it will not output. This script shows Windows slightly different EDIDs for the headset display, one after another,
# and records for each one whether the driver now offers 2160x1200. That says what the driver objects to.
#
# What it changes, and puts back before it ends:
#   * a Windows EDID override for the headset display only (the same mechanism a Rift S session and the CRU tool
#     use; a registry value, nothing is written to the headset), and
#   * the headset's monitor device is restarted after each variant so Windows reads it.
# "usable" variants keep the CV1's exact picture size and line/frame layout; only they are ever really switched on,
# for a few seconds, to read the signal back. The other variants change the timing and are only listed, never output.
# If a usable variant works it is saved as cv1-override.edid, which a CV1 session then uses as its temporary EDID.
# Meta's runtime, SteamVR and all other displays are not touched. Needs administrator rights.
param([switch]$CleanupOnly)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$started = Get-Date
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $elevatedArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"' + $(if ($CleanupOnly) { ' -CleanupOnly' } else { '' })
    try { $child = Start-Process powershell.exe -Verb RunAs -ArgumentList $elevatedArgs -PassThru }
    catch { Write-Output 'Administrator approval is needed (the test restarts the headset monitor device). Nothing was changed.'; exit 1 }
    $null = $child.Handle; $child.WaitForExit()
    $newest = Get-ChildItem -LiteralPath $root -Filter 'cv1-mode-test-*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $started } | Sort-Object Name | Select-Object -Last 1
    if ($newest) {
        $show = $false
        foreach ($line in (Get-Content -LiteralPath $newest.FullName)) {
            if ($line -eq '=== Summary ===') { $show = $true } elseif ($line -like '=== *') { $show = $false }
            if ($show) { Write-Output $line }
        }
        Write-Output ''
        Write-Output ('Report written: ' + $newest.FullName)
    } else { Write-Output 'No report was written (the test window closed early or failed to start).' }
    exit $child.ExitCode
}

Set-Location -LiteralPath $root
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $root ('cv1-mode-test-' + $stamp + '.txt')
$markerPath = Join-Path $root 'cv1-probe-active.txt'
$report = New-Object System.Collections.Generic.List[string]
$summary = New-Object System.Collections.Generic.List[string]
function Add-Line([string]$Text = '') { $report.Add($Text); Write-Host $Text }
function Add-Section([string]$Title) { Add-Line; Add-Line ('=== ' + $Title + ' ===') }
$restoredNote = 'not reached'
$exitCode = 1
$instance = $null
$key = $null
try {
    . (Join-Path $root 'display-mode.ps1')
    . (Join-Path $root 'session-recovery-policy.ps1')
    $probeExe = Join-Path $root 'display_probe.exe'
    if (-not (Test-Path -LiteralPath $probeExe)) { throw 'display_probe.exe is not in this folder; keep this script inside the ArcRift folder.' }
    if (Test-Path -LiteralPath (Join-Path $root 'active-test.xml')) { throw 'An ArcRift session is running or was not restored (active-test.xml). Stop or recover it first. Nothing was changed.' }

    # The CV1's display: the one from Setup if that is a CV1, else the only connected OVR0004 monitor.
    try { $instance = [string](Get-Content -LiteralPath (Join-Path $root 'arcrift-config.json') -Raw -ErrorAction Stop | ConvertFrom-Json).monitorInstance } catch { $instance = $null }
    if ($instance -notmatch '^(?i)DISPLAY\\OVR0004\\[^\\]+$') {
        $found = @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'DISPLAY\OVR0004\*' })
        if ($found.Count -ne 1) { throw ('Expected exactly one connected Rift CV1 display (OVR0004); found ' + $found.Count + '. Plug the headset in (USB and HDMI). Nothing was changed.') }
        $instance = $found[0].InstanceId
    }
    $pathId = (($instance -replace '\\', '#') + '#').ToLowerInvariant()
    $params = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $instance + '\Device Parameters'
    $key = $params + '\EDID_OVERRIDE'

    $igclExe = Join-Path $root 'arcrift_igcl_edid.exe'
    $script:igclUsed = $false
    function Remove-Override {
        if (Test-Path -LiteralPath $key) {
            Remove-ItemProperty -LiteralPath $key -Name '0' -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $key -Name '1' -ErrorAction SilentlyContinue
            $item = Get-Item -LiteralPath $key
            if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) { Remove-Item -LiteralPath $key }
        }
        if ($script:igclUsed -and (Test-Path -LiteralPath $igclExe)) {
            & $igclExe --undo | Out-Null
            $script:igclUsed = $false
        }
    }
    function Write-Override([byte[]]$Edid) {
        if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key }
        $blk0 = [byte[]]::new(128); [Array]::Copy($Edid, 0, $blk0, 0, 128)
        $null = New-ItemProperty -LiteralPath $key -Name '0' -Value $blk0 -PropertyType Binary -Force
        if ($Edid.Length -eq 256) {
            $blk1 = [byte[]]::new(128); [Array]::Copy($Edid, 128, $blk1, 0, 128)
            $null = New-ItemProperty -LiteralPath $key -Name '1' -Value $blk1 -PropertyType Binary -Force
        } else {
            Remove-ItemProperty -LiteralPath $key -Name '1' -ErrorAction SilentlyContinue
        }
    }
    function Restart-Headset {
        & pnputil.exe /restart-device $instance | Out-Null
        $code = $LASTEXITCODE
        Start-Sleep -Seconds 3
        return $code
    }
    # The headset's display source once Windows has it on the desktop again (it drops out during a monitor restart).
    function Wait-Source([int]$Seconds = 25) {
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ($true) {
            $s = [ArcRiftDisplayMode]::Source($pathId)
            if ($s) { Start-Sleep -Seconds 2; $again = [ArcRiftDisplayMode]::Source($pathId); if ($again) { return $again } }
            if ((Get-Date) -gt $deadline) { return $null }
            Start-Sleep -Milliseconds 500
        }
    }
    function Get-ProbeText { return ((& $probeExe 2>&1 | ForEach-Object { [string]$_ }) -join "`r`n") }
    # How Windows presents the headset display right now: the name from the EDID it uses and the signal on the cable.
    function Get-HeadsetState {
        $text = Get-ProbeText
        $active = [regex]::Match($text, '(?s)DisplayConfig flags=22.*?(?=DisplayManager targets|\z)').Value
        $entry = '(?m)^\s*target=(\d+) [^\r\n]*\r?\n\s*name=([^\r\n]*?) path=([^\r\n]*?) EDID=(\S+)(?:\s*\r?\n\s*signal=(\S+) total=(\S+) pixelClock=(\d+) vSync=(\d+)/(\d+))?'
        foreach ($m in [regex]::Matches($active, $entry)) {
            if (-not $m.Groups[3].Value.ToLowerInvariant().Contains($pathId)) { continue }
            $hz = if ($m.Groups[9].Success -and [double]$m.Groups[9].Value) { [math]::Round([double]$m.Groups[8].Value / [double]$m.Groups[9].Value, 3) } else { 0 }
            return [pscustomobject]@{ Name = $m.Groups[2].Value; Size = $m.Groups[5].Value; Total = $m.Groups[6].Value; Clock = $m.Groups[7].Value; Hz = $hz }
        }
        return $null
    }
    function Format-Modes([string[]]$Modes) {
        $parsed = @($Modes | ForEach-Object { $p = $_ -split ' '; [pscustomobject]@{ W = [int]$p[0]; H = [int]$p[1]; Hz = [int]$p[2] } })
        $sizes = @($parsed | Group-Object { [string]$_.W + 'x' + $_.H } | Sort-Object { $_.Group[0].W * $_.Group[0].H }, { $_.Group[0].W } -Descending)
        return (($sizes | ForEach-Object { $_.Name + '@' + ((@($_.Group.Hz) | Sort-Object -Unique -Descending) -join '/') }) -join ', ')
    }

    # A leftover override from an earlier run of this test that was cut off: remove it before reading anything.
    if (Test-Path -LiteralPath $key) {
        if (-not (Test-Path -LiteralPath $markerPath)) { throw 'The headset display already has a Windows EDID override that this test did not create (an ArcRift session''s display mode, or CRU). Run RECOVER.cmd, or remove it with CRU, first. Nothing was changed.' }
        Write-Host 'Removing the override left behind by an earlier, interrupted run of this test...'
        Remove-Override; $null = Restart-Headset; $null = Wait-Source
    }
    # A leftover Intel driver-level (IGCL) override from an earlier run that was cut off is not in the registry, so the
    # check above misses it, and the EDID check below then stops with "not the expected Rift CV1 one". --undo is safe
    # when there is none (it answers nothingToUndo=1).
    if ((Test-Path -LiteralPath $igclExe) -and (Test-Path -LiteralPath (Join-Path $root 'arcrift-identity.txt'))) {
        $undoOut = ((& $igclExe --undo 2>&1 | ForEach-Object { [string]$_ }) -join ' ')
        if ($undoOut -match 'op=undo ok=1' -and $undoOut -notmatch 'nothingToUndo=1') {
            Write-Host 'Removed the Intel driver-level EDID override left behind by an earlier, interrupted run of this test...'
            $null = Restart-Headset; $null = Wait-Source
        }
    }
    Remove-Item -LiteralPath $markerPath -ErrorAction SilentlyContinue
    if ($CleanupOnly) { $restoredNote = 'cleanup only'; $exitCode = 0; Write-Host 'Cleanup done.'; return }

    $own = [byte[]](Get-ItemProperty -LiteralPath $params -Name EDID -ErrorAction Stop).EDID
    if (-not $own -or $own.Length -lt 128) { throw 'Windows has no EDID stored for the headset display. Nothing was changed.' }
    $base = [byte[]]::new(128); [Array]::Copy($own, $base, 128)
    $sum = 0; foreach ($b in $base) { $sum += $b }
    $ownW = [int]$base[56] + (([int]$base[58] -band 0xF0) -shl 4); $ownH = [int]$base[59] + (([int]$base[61] -band 0xF0) -shl 4)
    $ownClock = ([int]$base[54] + 256 * [int]$base[55]) * 10000
    if (($sum % 256) -ne 0 -or $base[8] -ne 0x3e -or $base[9] -ne 0xd2 -or $ownW -ne 2160 -or $ownH -ne 1200 -or $ownClock -ne 296750000) { throw ('The headset display''s EDID is not the expected Rift CV1 one (found ' + $ownW + 'x' + $ownH + ', pixel clock ' + $ownClock + '). Nothing was changed.') }

    # ---- the EDID variants ----
    function Set-Checksum([byte[]]$e) {
        $s = 0; for ($i = 0; $i -lt 127; $i++) { $s += $e[$i] }; $e[127] = [byte]((256 - ($s % 256)) % 256)
        if ($e.Length -eq 256) {
            $s1 = 0; for ($i = 128; $i -lt 255; $i++) { $s1 += $e[$i] }; $e[255] = [byte]((256 - ($s1 % 256)) % 256)
        }
    }
    function Set-Name([byte[]]$e, [string]$Name) {
        foreach ($o in 72, 90, 108) {
            if ($e[$o] -eq 0 -and $e[$o + 1] -eq 0 -and $e[$o + 3] -eq 0xFC) {
                $text = [Text.Encoding]::ASCII.GetBytes($Name.Substring(0, [math]::Min(13, $Name.Length)))
                for ($i = 0; $i -lt 13; $i++) { $e[$o + 5 + $i] = if ($i -lt $text.Length) { $text[$i] } elseif ($i -eq $text.Length) { 0x0A } else { 0x20 } }
            }
        }
    }
    # Appends a clean 128-byte CTA-861 rev 3 extension block with an HDMI 1.4 VSDB (OUI 00-0C-03) declaring
    # Max_TMDS_Clock = $MaxTmdsMhz (in 5 MHz steps, e.g. 300 or 340 MHz) so strict HDMI 2.0/2.1 drivers (such as
    # Intel Arc B580) do not clamp the link to single-link DVI's 165 MHz cap.
    function Add-HdmiVsdbBlock([byte[]]$Base128, [int]$MaxTmdsMhz) {
        $out = [byte[]]::new(256)
        [Array]::Copy($Base128, 0, $out, 0, 128)
        $out[126] = 1
        $out[128] = 0x02 # CTA-861 tag
        $out[129] = 0x03 # revision 3
        $out[130] = 0x0C # DTD offset (4-byte header + 8-byte HDMI VSDB)
        $out[131] = 0x00 # flags (RGB only, 0 native DTDs)
        $out[132] = 0x67 # Vendor-Specific Data Block (tag=3, len=7)
        $out[133] = 0x03; $out[134] = 0x0C; $out[135] = 0x00 # IEEE OUI 00-0C-03 (HDMI Licensing)
        $out[136] = 0x10; $out[137] = 0x00 # Source Physical Address 1.0.0.0
        $out[138] = 0x00 # AI / deep color flags
        $out[139] = [byte]([math]::Floor($MaxTmdsMhz / 5)) # Max_TMDS_Clock in 5 MHz units
        Set-Checksum $out
        return ,$out
    }
    # Writes the first detailed timing. Clock in units of 10 kHz. Image size, border and sync flags stay as they are.
    function Set-Timing([byte[]]$e, [int]$Clock, [int]$HBlank, [int]$VBlank, [int]$HFront, [int]$HSync, [int]$VFront, [int]$VSync) {
        $e[54] = [byte]($Clock -band 0xFF); $e[55] = [byte](($Clock -shr 8) -band 0xFF)
        $e[56] = [byte](2160 -band 0xFF); $e[57] = [byte]($HBlank -band 0xFF); $e[58] = [byte](((2160 -shr 8) -shl 4) -bor ($HBlank -shr 8))
        $e[59] = [byte](1200 -band 0xFF); $e[60] = [byte]($VBlank -band 0xFF); $e[61] = [byte](((1200 -shr 8) -shl 4) -bor ($VBlank -shr 8))
        $e[62] = [byte]($HFront -band 0xFF); $e[63] = [byte]($HSync -band 0xFF)
        $e[64] = [byte]((($VFront -band 0x0F) -shl 4) -bor ($VSync -band 0x0F))
        $e[65] = [byte]((($HFront -shr 8) -shl 6) -bor (($HSync -shr 8) -shl 4) -bor (($VFront -shr 4) -shl 2) -bor ($VSync -shr 4))
    }
    function New-Variant([string]$Tag, [string]$What, [bool]$Usable, [int]$Hz, [scriptblock]$Change, [int]$HdmiMaxTmdsMhz = 0) {
        $e = [byte[]]$base.Clone()
        # Clear extension count on 128-byte variants so Windows never sees a dangling extension count without block 1.
        $e[126] = 0
        if ($Change) { & $Change $e }
        # The name carries this run's number, so a description left over from an earlier run cannot pass for this one.
        # The EDID name field holds only 13 characters: 'Rift hdmi340 NN' (15) was cut to 'Rift hdmi340 ', so the
        # name read back never matched and every picked-up override was reported as NOT picked up. Keep it short.
        $name = 'R ' + $Tag + ' ' + $runId
        Set-Name $e $name
        if ($HdmiMaxTmdsMhz -gt 0) { $e = Add-HdmiVsdbBlock $e $HdmiMaxTmdsMhz }
        else { Set-Checksum $e }
        return [pscustomobject]@{ Tag = $Tag; What = $What; Usable = $Usable; Hz = $Hz; Name = $name; Edid = $e }
    }
    function Get-Name([byte[]]$e) {
        foreach ($o in 72, 90, 108) { if ($e[$o] -eq 0 -and $e[$o + 1] -eq 0 -and $e[$o + 3] -eq 0xFC) { return ([Text.Encoding]::ASCII.GetString($e, $o + 5, 13) -replace '[\x00-\x1f]', '').Trim() } }
        return ''
    }
    $ownName = Get-Name $base
    $runId = (Get-Date).ToString('ss')
    $script:replugs = 0
    # First report from a B580: after the first override, restarting the monitor device no longer made Windows read a
    # new one (it kept showing the previous name), so the later variants were never really tried. When that happens,
    # ask for the HDMI cable to be unplugged and plugged back in, which always makes Windows read the display again.
    function Request-Replug([string]$Why) {
        Write-Host ''
        Write-Host ('>>> ' + $Why)
        Write-Host '>>> Unplug the headset''s HDMI cable from the graphics card, wait 3 seconds, plug it back in.'
        $null = Read-Host '>>> Then press Enter here'
        $script:replugs++
        Start-Sleep -Seconds 5
    }
    # The CV1's own timing: 2160x1200, 80 blank columns (front 8, sync 32), 272 blank lines (front 50, sync 2), 296.75 MHz.
    $variants = @(
        (New-Variant 'hdmi340' 'own exact timing + CTA-861 HDMI VSDB (Max TMDS 340 MHz) to unlock >165 MHz HDMI clocks on strict drivers (Arc B580)' $true 90 $null 340)
        (New-Variant 'hdmi300' 'own exact timing (297.00 MHz standard HDMI clock) + CTA-861 HDMI VSDB (Max TMDS 300 MHz)' $true 90 { param($e) Set-Timing $e 29700 80 272 8 32 50 2 } 300)
        (New-Variant 'own' 'the headset''s own EDID again, 128-byte base block only (control: is an override picked up at all?)' $true 90 $null)
        (New-Variant 'c297' 'same picture and layout, pixel clock 297.00 MHz instead of 296.75 (a standard HDMI clock; 90.07 Hz)' $true 90 { param($e) Set-Timing $e 29700 80 272 8 32 50 2 })
        (New-Variant 'rb' 'ordinary monitor blanking (160 columns, 35 lines), 257.87 MHz, 90 Hz' $false 90 { param($e) Set-Timing $e 25787 160 35 48 32 3 10 })
        (New-Variant '60hz' 'own layout at 60 Hz, 197.84 MHz' $false 60 { param($e) Set-Timing $e 19784 80 272 8 32 50 2 })
        (New-Variant '59rb' 'short blanking at 59 Hz, 163.22 MHz (under the 165 MHz limit of simple adapters and DVI)' $false 59 { param($e) Set-Timing $e 16322 80 35 8 32 3 10 })
    )

    Add-Line 'ArcRift Rift CV1 display-mode test'
    Add-Line ('Report format 2, ArcRift 1.6, written ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + '. No serial numbers are in this file.')
    Add-Section 'System'
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Add-Line ($os.Caption + ', build ' + $os.BuildNumber)
        foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) { Add-Line ($g.Name + ' | driver ' + $g.DriverVersion + ' | ' + ([regex]::Match([string]$g.PNPDeviceID, '(?i)VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}').Value)) }
    } catch { Add-Line ('System details not readable: ' + $_.Exception.Message) }

    Add-Section 'Before'
    $source = [ArcRiftDisplayMode]::Source($pathId)
    if (-not $source) { throw 'Windows does not have the headset display on the desktop right now (open the Meta Horizon app, put the headset on for a few seconds). Nothing was changed.' }
    $baseline = Get-ArcRiftRecoveryLayouts (Get-ProbeText)
    $before = Get-HeadsetState
    if (-not $before) { throw 'display_probe.exe does not list the headset display as an active display. Nothing was changed.' }
    Add-Line ('Headset display ' + ($instance -replace '^DISPLAY\\', '') + ' on ' + $source + ', name "' + $before.Name + '", signal ' + $before.Size + ' total ' + $before.Total + ' clock ' + $before.Clock + ' at ' + $before.Hz + ' Hz')
    Add-Line ('Offered now: ' + (Format-Modes @([ArcRiftDisplayMode]::Modes($source))))

    Add-Section 'Variants'
    $results = New-Object System.Collections.Generic.List[object]
    # First a plain monitor restart with no override: does the mode list change by itself?
    $plan = @([pscustomobject]@{ Tag = 'restart'; What = 'no override, only a restart of the headset''s monitor device'; Usable = $true; Hz = 90; Name = $before.Name; Edid = $null }) + $variants
    'Created by cv1-mode-probe.ps1; removed when the test has put everything back.' | Set-Content -LiteralPath $markerPath
    foreach ($v in $plan) {
        Add-Line ('[' + $v.Tag + '] ' + $v.What)
        $r = [pscustomobject]@{ Tag = $v.Tag; Usable = $v.Usable; PickedUp = $false; Tested = $false; Offered = $false; OfferedHz = ''; Test = $null; Output = $false; Signal = '' }
        $results.Add($r)
        if ($v.Edid) {
            if ($script:igclUsed -and (Test-Path -LiteralPath $igclExe)) { & $igclExe --undo | Out-Null; $script:igclUsed = $false }
            Write-Override ([byte[]]$v.Edid)
        }
        $restart = Restart-Headset
        $source = Wait-Source
        if (-not $source) { Add-Line ('    the headset display did not come back onto the desktop within 25 s (monitor restart result ' + $restart + ')'); continue }
        $state = Get-HeadsetState
        $r.PickedUp = [bool]($state -and ([string]$state.Name).Trim() -eq ([string]$v.Name).Trim())
        if ($v.Edid -and -not $r.PickedUp -and (Test-Path -LiteralPath $igclExe)) {
            # Arc B580 fallback: try Intel IGCL driver-level EDID override before asking for an HDMI re-plug.
            # Ensure arcrift-identity.txt matches this CV1 monitor and its Intel parent adapter.
            $uidMatch = [regex]::Match($instance, '(?i)UID(\d+)')
            $parentPnp = ''
            try { $parentPnp = [string](Get-PnpDeviceProperty -InstanceId $instance -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data } catch {}
            $gpuM = [regex]::Match($parentPnp, '(?i)VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})')
            if ($uidMatch.Success -and $gpuM.Success -and $gpuM.Groups[1].Value -eq '8086') {
                $idLines = @(
                    ('target=' + $uidMatch.Groups[1].Value),
                    ('monitor=' + ($instance -replace '\\', '#') + '#'),
                    ('gpu=' + ($gpuM.Groups[1].Value + ':' + $gpuM.Groups[2].Value).ToUpperInvariant())
                )
                Set-Content -LiteralPath (Join-Path $root 'arcrift-identity.txt') -Value $idLines -Encoding Ascii
                Remove-Override
                $null = Restart-Headset
                $null = Wait-Source 15
                $tmpEdid = Join-Path $root 'cv1-probe-temp.edid'
                [IO.File]::WriteAllBytes($tmpEdid, [byte[]]$v.Edid)
                $igclOut = & $igclExe --override --edid $tmpEdid --replace 2>&1
                Remove-Item -LiteralPath $tmpEdid -ErrorAction SilentlyContinue
                if ($LASTEXITCODE -eq 0) {
                    $script:igclUsed = $true
                    Add-Line ('    trying Intel driver-level EDID override (IGCL): ' + (($igclOut | Select-Object -Last 1) -as [string]))
                    Start-Sleep -Seconds 4
                    $source = Wait-Source 20
                    $state = if ($source) { Get-HeadsetState } else { $null }
                    $r.PickedUp = [bool]($state -and ([string]$state.Name).Trim() -eq ([string]$v.Name).Trim())
                }
            }
        }
        for ($try = 1; $v.Edid -and -not $r.PickedUp -and $try -le 2; $try++) {
            Request-Replug ('[' + $v.Tag + '] Windows is still using the previous display description (it shows "' + $(if ($state) { $state.Name }) + '").')
            $source = Wait-Source 40
            $state = if ($source) { Get-HeadsetState } else { $null }
            $r.PickedUp = [bool]($state -and ([string]$state.Name).Trim() -eq ([string]$v.Name).Trim())
        }
        if (-not $source) { Add-Line '    the headset display did not come back onto the desktop after re-plugging'; continue }
        if ($v.Edid) { Add-Line ('    override picked up by Windows: ' + $(if ($r.PickedUp) { 'yes' } else { 'NO (Windows shows the name "' + $(if ($state) { $state.Name }) + '")' })) }
        if ($v.Edid -and -not $r.PickedUp) { Add-Line '    NOT TESTED: Windows never used this description, so this says nothing about the variant.'; continue }
        $r.Tested = $true
        $modes = @([ArcRiftDisplayMode]::Modes($source))
        Add-Line ('    offered: ' + (Format-Modes $modes))
        $sameSize = @($modes | ForEach-Object { $p = $_ -split ' '; if ($p[0] -eq '2160' -and $p[1] -eq '1200') { [int]$p[2] } } | Sort-Object -Unique -Descending)
        $r.OfferedHz = ($sameSize -join '/')
        $pick = @($sameSize | Where-Object { $_ -ge ($v.Hz - 1) -and $_ -le ($v.Hz + 1) } | Sort-Object { [math]::Abs($_ - $v.Hz) }, { -$_ })
        if (-not $pick.Count) { Add-Line ('    2160x1200: ' + $(if ($sameSize.Count) { 'offered only at ' + $r.OfferedHz + ' Hz' } else { 'NOT offered' })); continue }
        $r.Offered = $true
        $r.Test = [ArcRiftDisplayMode]::Set($source, 2160, 1200, [int]$pick[0], $true)
        Add-Line ('    2160x1200: OFFERED at ' + $r.OfferedHz + ' Hz; test of ' + $pick[0] + ' Hz: ' + $(if ($r.Test -eq 0) { 'accepted' } else { 'refused (result ' + $r.Test + ')' }))
        if (-not $v.Usable -or $r.Test -ne 0) { continue }
        # A usable variant: switch it on for a few seconds and read the signal back, then return to the saved mode.
        $set = [ArcRiftDisplayMode]::Set($source, 2160, 1200, [int]$pick[0], $false)
        Start-Sleep -Seconds 3
        $live = Get-HeadsetState
        $null = [ArcRiftDisplayMode]::Restore($source)
        Start-Sleep -Seconds 2
        if ($live) { $r.Signal = $live.Size + ' total ' + $live.Total + ' clock ' + $live.Clock + ' at ' + $live.Hz + ' Hz' }
        $r.Output = [bool]($set -eq 0 -and $live -and $live.Size -eq '2160x1200' -and $live.Total -eq '2240x1472' -and $live.Hz -ge 89 -and $live.Hz -le 91)
        Add-Line ('    switched on (result ' + $set + '): signal ' + $(if ($r.Signal) { $r.Signal } else { 'not readable' }) + ' -> ' + $(if ($r.Output) { 'WORKS' } else { 'not the wanted signal' }))
        if ($r.Output) { Add-Line '    A usable variant works; the remaining variants are skipped.'; break }
    }

    Add-Section 'Restore'
    Remove-Override
    $restart = Restart-Headset
    $source = Wait-Source
    $afterState = Get-HeadsetState
    if ($afterState -and ([string]$afterState.Name).Trim() -ne $ownName) {
        Request-Replug ('Putting things back: Windows is still using a test description (it shows "' + $afterState.Name + '").')
        $source = Wait-Source 40
    }
    $matched = $false
    for ($i = 0; $i -lt 15 -and -not $matched; $i++) {
        Start-Sleep -Seconds 1
        try { $after = Get-ArcRiftRecoveryLayouts (Get-ProbeText) } catch { continue }
        $matched = $after.Count -eq $baseline.Count
        foreach ($id in $baseline.Keys) { if ($after[$id] -ne $baseline[$id]) { $matched = $false } }
    }
    $overrideGone = -not (Test-Path -LiteralPath $key)
    if ($overrideGone) { Remove-Item -LiteralPath $markerPath -ErrorAction SilentlyContinue }
    $restoredNote = if ($matched -and $overrideGone) { 'yes: the override is removed and every display matches how it was before the test' } elseif ($overrideGone) { 'the override is removed, but a display differs from before the test (check Windows display settings)' } else { 'NO: the override is still there; run this test again, it removes it first' }
    $afterState = Get-HeadsetState
    $ownBack = [bool]($afterState -and ([string]$afterState.Name).Trim() -eq $ownName)
    if (-not $ownBack) { $restoredNote += '. Windows still shows a test description for the headset ("' + $(if ($afterState) { $afterState.Name }) + '"); it has the headset''s own timing and goes away when the headset is re-plugged or the PC restarts' }
    Add-Line ('Everything put back: ' + $restoredNote)
    Add-Line ('HDMI re-plugs asked for: ' + $script:replugs)
    if ($afterState) { Add-Line ('Headset display now: name "' + $afterState.Name + '", signal ' + $afterState.Size + ' at ' + $afterState.Hz + ' Hz') }

    # ---- summary ----
    $working = @($results | Where-Object { $_.Usable -and $_.Output })
    $offeredTags = @($results | Where-Object { $_.Offered } | ForEach-Object { $_.Tag })
    $pickedUp = @($results | Where-Object { $_.Tag -ne 'restart' -and $_.PickedUp }).Count
    $overridePath = Join-Path $root 'cv1-override.edid'
    if ($working.Count -and $working[0].Tag -eq 'restart') {
        $summary.Add('RESULT: after a plain restart of the headset monitor, Windows offered and output 2160x1200 at 90 Hz. A VR session does that restart by itself: press Start VR session again.')
    } elseif ($working.Count) {
        $chosen = $variants | Where-Object { $_.Tag -eq $working[0].Tag }
        $savedEdid = [byte[]]$chosen.Edid.Clone()
        if ($ownName) { Set-Name $savedEdid $ownName; Set-Checksum $savedEdid }
        [IO.File]::WriteAllBytes($overridePath, $savedEdid)
        $summary.Add('RESULT: variant [' + $chosen.Tag + '] works: Windows offered and output ' + $working[0].Signal + '.')
        $summary.Add('It is saved as cv1-override.edid (' + $savedEdid.Length + ' bytes; contains the headset serial, do not post that file). Press Start VR session again: the session now uses it as a temporary display mode.')
    } elseif ($pickedUp -eq 0) {
        $summary.Add('RESULT: Windows did not pick up any EDID override for the headset display on this PC, even after re-plugging, so this route cannot work here.')
    } elseif ($offeredTags.Count) {
        $summary.Add('RESULT: no variant the headset can use was accepted. The driver did accept 2160x1200 with changed timing: [' + ($offeredTags -join '], [') + ']. Please send this file; it shows what the driver objects to.')
    } else {
        $testedTags = @($results | Where-Object { $_.Tag -ne 'restart' -and $_.Tested } | ForEach-Object { $_.Tag })
        $skippedTags = @($results | Where-Object { $_.Tag -ne 'restart' -and -not $_.Tested } | ForEach-Object { $_.Tag })
        $summary.Add('RESULT: 2160x1200 was not offered with any variant that Windows really used: [' + ($testedTags -join '], [') + '].' + $(if ($skippedTags.Count) { ' Not tested (Windows never used them): [' + ($skippedTags -join '], [') + '].' }) + ' Please send this file.')
    }
    $summary.Add('Everything put back: ' + $restoredNote)
    if (-not $working.Count) { $summary.Add('If the headset''s HDMI cable goes through any adapter, say so when you send this; plugged straight into the card''s HDMI port is the only tested way.') }
    $exitCode = if ($matched -and $overrideGone) { 0 } else { 1 }
} catch {
    Add-Line ('TEST STOPPED: ' + $_.Exception.Message)
    $summary.Add('TEST STOPPED: ' + $_.Exception.Message)
    # Never leave an override behind.
    try {
        if ($script:igclUsed -and (Test-Path -LiteralPath $igclExe)) { & $igclExe --undo | Out-Null; $script:igclUsed = $false }
        if ($key -and (Test-Path -LiteralPath $key) -and (Test-Path -LiteralPath $markerPath)) {
            Remove-ItemProperty -LiteralPath $key -Name '0' -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $key -Name '1' -ErrorAction SilentlyContinue
            $item = Get-Item -LiteralPath $key
            if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) { Remove-Item -LiteralPath $key }
            & pnputil.exe /restart-device $instance | Out-Null
            if (-not (Test-Path -LiteralPath $key)) { Remove-Item -LiteralPath $markerPath -ErrorAction SilentlyContinue; $summary.Add('The override was removed and the headset monitor restarted.') }
        }
    } catch { $summary.Add('Cleanup problem: ' + $_.Exception.Message + '. Run this test again; it removes a leftover override first.') }
} finally {
    if (-not $CleanupOnly) {
        $all = New-Object System.Collections.Generic.List[string]
        $head = [math]::Min(2, $report.Count)
        for ($i = 0; $i -lt $head; $i++) { $all.Add($report[$i]) }
        $all.Add(''); $all.Add('=== Summary ===')
        foreach ($line in $summary) { $all.Add($line) }
        for ($i = $head; $i -lt $report.Count; $i++) { $all.Add($report[$i]) }
        [IO.File]::WriteAllLines($reportPath, [string[]]$all, (New-Object Text.UTF8Encoding($false)))
    }
}
exit $exitCode
