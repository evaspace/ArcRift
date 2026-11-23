# ArcRift 1.4: read-only compatibility report for testers (other Intel Arc cards, Oculus Rift CV1).
# It changes nothing: no display, registry, service or device changes. It only reads, and writes one text file
# (compat-report-<time>.txt) next to this script. It does not need administrator rights and never asks a question.
# Serial numbers are masked: the headset's USB serial, the serial inside the headset display's EDID, and the EDIDs
# of all other monitors (only their maker/model and current mode are kept).
param([string]$OutputPath)
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputPath) { $OutputPath = Join-Path $root ('compat-report-' + $stamp + '.txt') }
$report = New-Object System.Collections.Generic.List[string]
$secrets = New-Object System.Collections.Generic.List[string]
function Add-Line([string]$Text = '') { $report.Add($Text) }
function Add-Section([string]$Title) { Add-Line; Add-Line ('=== ' + $Title + ' ===') }

# Intel Arc desktop cards this project knows by device ID. "tested" = a full VR session was confirmed on it.
$arcCards = @{
    '56A0' = 'Arc A770 (tested)'; '56A1' = 'Arc A750 (untested)'; '56A2' = 'Arc A580 (untested)'
    '56A5' = 'Arc A380 (untested)'; '56A6' = 'Arc A310 (untested)'
    'E20B' = 'Arc B580 (untested, one failed report)'; 'E20C' = 'Arc B570 (untested)'
}
# Meta/Oculus USB product IDs as listed by the OpenHMD project; shown as a hint only.
$metaUsb = @{ '0031' = 'Rift CV1 headset'; '0051' = 'Rift S headset'; '0211' = 'Rift CV1 sensor'; '0021' = 'Rift DK2 headset'; '0001' = 'Rift DK1 headset'
    '0330' = 'Rift CV1 audio'; '2031' = 'Rift CV1 hub, USB 2 side'; '3031' = 'Rift CV1 hub, USB 3 side' }
$outputTech = @{ '0' = 'VGA'; '4' = 'DVI'; '5' = 'HDMI'; '6' = 'LVDS'; '9' = 'SDI'; '10' = 'DisplayPort'; '11' = 'DisplayPort (built-in)'; '15' = 'Miracast'; '16' = 'indirect (wired)'; '17' = 'indirect (virtual)' }

function Get-EdidInfo([byte[]]$e) {
    if (-not $e -or $e.Length -lt 128) { return $null }
    $m = ([int]$e[8] -shl 8) -bor [int]$e[9]
    $letters = foreach ($v in @((($m -shr 10) -band 31), (($m -shr 5) -band 31), ($m -band 31))) { if ($v -ge 1 -and $v -le 26) { [string][char](64 + $v) } else { '_' } }
    $sum = 0; for ($i = 0; $i -lt 128; $i++) { $sum += $e[$i] }
    $info = [pscustomobject]@{
        Maker = (-join $letters); Product = ('{0:X4}' -f ([int]$e[10] + 256 * [int]$e[11]))
        Version = ([string]$e[18] + '.' + [string]$e[19]); Year = (1990 + [int]$e[17]); Extensions = [int]$e[126]
        ChecksumOk = (($sum % 256) -eq 0); Length = $e.Length; Name = ''; HasSerialText = $false
        Timings = New-Object System.Collections.Generic.List[string]; Notes = New-Object System.Collections.Generic.List[string]
    }
    function Read-Timing([byte[]]$b, [int]$o) {
        $clock = ([int]$b[$o] + 256 * [int]$b[$o + 1]) * 10000
        if ($clock -eq 0) { return $null }
        $hact = [int]$b[$o + 2] + (([int]$b[$o + 4] -band 0xF0) -shl 4); $hblank = [int]$b[$o + 3] + (([int]$b[$o + 4] -band 0x0F) -shl 8)
        $vact = [int]$b[$o + 5] + (([int]$b[$o + 7] -band 0xF0) -shl 4); $vblank = [int]$b[$o + 6] + (([int]$b[$o + 7] -band 0x0F) -shl 8)
        $total = ($hact + $hblank) * ($vact + $vblank)
        $hz = if ($total) { [math]::Round($clock / $total, 3) } else { 0 }
        $hfront = [int]$b[$o + 8] + (([int]$b[$o + 11] -band 0xC0) -shl 2); $hsync = [int]$b[$o + 9] + (([int]$b[$o + 11] -band 0x30) -shl 4)
        $vfront = ([int]$b[$o + 10] -shr 4) + (([int]$b[$o + 11] -band 0x0C) -shl 2); $vsync = ([int]$b[$o + 10] -band 15) + (([int]$b[$o + 11] -band 0x03) -shl 4)
        return ('{0}x{1} at {2} Hz, pixel clock {3}, total {4}x{5}, h front/sync {6}/{7}, v front/sync {8}/{9}, flags 0x{10:X2}' -f $hact, $vact, $hz, $clock, ($hact + $hblank), ($vact + $vblank), $hfront, $hsync, $vfront, $vsync, [int]$b[$o + 17])
    }
    foreach ($o in 54, 72, 90, 108) {
        if ($e[$o] -ne 0 -or $e[$o + 1] -ne 0) { $t = Read-Timing $e $o; if ($t) { $info.Timings.Add($t) } }
        elseif ($e[$o + 3] -eq 0xFC) { $info.Name = ([Text.Encoding]::ASCII.GetString($e, $o + 5, 13) -replace '[\x00-\x1f]', '').Trim() }
        elseif ($e[$o + 3] -eq 0xFF) { $info.HasSerialText = $true }
    }
    # Extension blocks: CTA-861 (tag 2) may carry more timings and Microsoft's "this is a head-mounted display" block.
    for ($x = 1; $x -le $info.Extensions -and ($x * 128 + 127) -lt $e.Length; $x++) {
        $b = $x * 128
        if ($e[$b] -ne 2) { $info.Notes.Add(('extension block {0}: type 0x{1:X2}' -f $x, [int]$e[$b])); continue }
        $dtd = [int]$e[$b + 2]
        $info.Notes.Add(('extension block {0}: CTA-861 revision {1}' -f $x, [int]$e[$b + 1]))
        if ($dtd -ge 4) {
            $i = $b + 4
            while ($i -lt $b + $dtd) {
                $tag = [int]$e[$i] -shr 5; $len = [int]$e[$i] -band 31
                if ($tag -eq 3 -and $len -ge 3) {
                    $oui = ('{0:X2}-{1:X2}-{2:X2}' -f [int]$e[$i + 3], [int]$e[$i + 2], [int]$e[$i + 1])
                    if ($oui -eq 'CA-12-5C' -and $len -ge 5) { $info.Notes.Add(('Microsoft head-mounted/specialized display block: version {0}, flags 0x{1:X2}' -f [int]$e[$i + 4], [int]$e[$i + 5])) }
                    else { $info.Notes.Add('vendor block ' + $oui) }
                }
                $i += $len + 1
            }
            for ($o = $b + $dtd; $o + 18 -le $b + 127; $o += 18) { $t = Read-Timing $e $o; if (-not $t) { break }; $info.Timings.Add($t + ' (extension)') }
        }
    }
    return $info
}

# A copy of an EDID with its serial numbers blanked and the checksum fixed, so it is still a valid EDID.
function Get-MaskedEdid([byte[]]$e) {
    $c = [byte[]]$e.Clone()
    for ($i = 12; $i -le 15; $i++) { $c[$i] = 0 }
    foreach ($o in 54, 72, 90, 108) {
        if ($c[$o] -eq 0 -and $c[$o + 1] -eq 0 -and $c[$o + 3] -eq 0xFF) {
            for ($i = $o + 5; $i -le $o + 17; $i++) { if ($c[$i] -ne 0x0A -and $c[$i] -ne 0x20) { $c[$i] = 0x30 } }
        }
    }
    $sum = 0; for ($i = 0; $i -lt 127; $i++) { $sum += $c[$i] }
    $c[127] = [byte]((256 - ($sum % 256)) % 256)
    return $c
}
function ConvertTo-Hex([byte[]]$b) { return (-join ($b | ForEach-Object { $_.ToString('x2') })) }
function Test-HeadsetEdid($info) { return ($info -and ($info.Maker -eq 'OVR' -or ($info.Maker -eq 'MS_' -and $info.Product -eq '0001'))) }
function Hide-Secrets([string]$Text) {
    foreach ($s in $secrets) { if ($s) { $Text = $Text.Replace($s, ($s.Substring(0, [math]::Min(4, $s.Length)) + '[masked]')) } }
    if ($env:USERPROFILE) { $Text = $Text.Replace($env:USERPROFILE, '%USERPROFILE%') }
    if ($env:COMPUTERNAME) { $Text = $Text.Replace($env:COMPUTERNAME, '[pc-name]') }
    return $Text
}

Add-Line 'ArcRift compatibility report (read-only; nothing on this PC was changed)'
Add-Line ('Report format 2, ArcRift 1.6, written ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
Add-Line 'Serial numbers are masked. Other monitors are listed by model and mode only. Please still read it before posting.'

# ---------- Windows ----------
Add-Section 'Windows'
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
    Add-Line ($os.Caption + ', build ' + $os.BuildNumber + '.' + $ubr + ', ' + $os.OSArchitecture)
} catch { Add-Line ('Windows build ' + [Environment]::OSVersion.Version.Build) }

# ---------- graphics cards ----------
Add-Section 'Graphics cards'
$arcFound = $false
try {
    foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
        $id = [regex]::Match([string]$g.PNPDeviceID, '(?i)VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})(&SUBSYS_[0-9A-F]{8})?(&REV_[0-9A-F]{2})?')
        $known = ''
        if ($id.Success -and $id.Groups[1].Value -eq '8086') {
            $card = $arcCards[$id.Groups[2].Value.ToUpperInvariant()]
            if ($card) { $known = ' | known as: ' + $card; $arcFound = $true } else { $known = ' | Intel card not in ArcRift''s list' }
        }
        $date = ''; if ($g.DriverDate) { $date = ' (' + ([datetime]$g.DriverDate).ToString('yyyy-MM-dd') + ')' }
        $pnp = if ($id.Success) { $id.Value.ToUpperInvariant() } else { [string]$g.PNPDeviceID }
        Add-Line ($g.Name + ' | driver ' + $g.DriverVersion + $date + ' | ' + $pnp + $known)
    }
} catch { Add-Line ('Could not list graphics cards: ' + $_.Exception.Message) }

# ---------- Meta runtime ----------
Add-Section 'Meta (Oculus) runtime'
$metaServerRunning = [bool](Get-Process OVRServer_x64 -ErrorAction SilentlyContinue)
try {
    $svc = Get-Service OVRService -ErrorAction Stop
    Add-Line ('OVRService: ' + $svc.Status + ' | OVRServer running: ' + $metaServerRunning + ' | Meta app window open: ' + [bool](Get-Process OculusClient -ErrorAction SilentlyContinue))
    $image = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\OVRService' -ErrorAction SilentlyContinue).ImagePath
    if ($image -match '^\s*"?([^"]+)\\OVRServiceLauncher\.exe') {
        $server = Join-Path $matches[1] 'OVRServer_x64.exe'
        if (Test-Path -LiteralPath $server) {
            $serverFile = Get-Item -LiteralPath $server
            $version = @($serverFile.VersionInfo.FileVersion, $serverFile.VersionInfo.ProductVersion) | Where-Object { $_ } | Select-Object -First 1
            Add-Line ('Runtime: version ' + $(if ($version) { $version } else { 'not stated' }) + ', OVRServer_x64.exe dated ' + $serverFile.LastWriteTime.ToString('yyyy-MM-dd'))
        }
    }
} catch { Add-Line 'OVRService was not found: the Meta Horizon (Oculus) PC app does not seem to be installed.' }
$oculusKey = Get-ItemProperty 'HKLM:\SOFTWARE\Oculus' -ErrorAction SilentlyContinue
$backend = if ($oculusKey -and $oculusKey.DirectDisplayDLL) { Split-Path -Leaf ([string]$oculusKey.DirectDisplayDLL) } else { 'not set (Meta default)' }
Add-Line ('Display backend override: ' + $backend + ' | ArcRift session marker present: ' + (Test-Path -LiteralPath (Join-Path $root 'active-test.xml')))

# ---------- headset USB devices ----------
Add-Section 'Meta/Oculus USB devices (VID_2833)'
$usb = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '(?i)VID_2833' })
$usbHeadset = $false
if ($usb.Count -eq 0) { Add-Line 'None connected.' }
foreach ($d in ($usb | Sort-Object InstanceId)) {
    $parts = $d.InstanceId -split '\\'
    # A real serial has letters and digits; placeholder IDs such as 0000000000 are not serials (and would match EDID hex).
    if ($parts.Count -eq 3 -and $parts[2] -notmatch '&' -and $parts[2] -match '^(?=.*[A-Za-z])(?=.*\d)[A-Za-z0-9]{8,}$') { if (-not $secrets.Contains($parts[2])) { $secrets.Add($parts[2]) } }
}
$usbGroups = $usb | Group-Object { ([regex]::Match($_.InstanceId, '(?i)PID_([0-9A-F]{4})')).Groups[1].Value.ToUpperInvariant() }
foreach ($grp in $usbGroups) {
    $hint = $metaUsb[$grp.Name]; if (-not $hint) { $hint = 'unknown model' }
    if ($hint -like '*headset*') { $usbHeadset = $true }
    $classes = ($grp.Group | Group-Object Class | ForEach-Object { $_.Name + ' x' + $_.Count }) -join ', '
    $bad = @($grp.Group | Where-Object { $_.Status -ne 'OK' }).Count
    Add-Line ('PID_' + $grp.Name + ' (' + $hint + '): ' + $grp.Count + ' devices [' + $classes + '], not OK: ' + $bad)
}

# ---------- monitors ----------
Add-Section 'Monitors Windows knows'
$headsetMonitors = @()
$monitors = @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'DISPLAY\*' })
foreach ($mon in ($monitors | Sort-Object { -not $_.Present }, InstanceId)) {
    $present = [bool]$mon.Present
    $params = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $mon.InstanceId + '\Device Parameters'
    $edid = $null
    try { $edid = [byte[]](Get-ItemProperty -LiteralPath $params -Name EDID -ErrorAction Stop).EDID } catch { }
    $info = Get-EdidInfo $edid
    $isHeadset = Test-HeadsetEdid $info
    if (-not $present -and -not $isHeadset) { continue } # old, unplugged ordinary monitors are not interesting
    $parent = ''
    try { $parent = [regex]::Match([string](Get-PnpDeviceProperty -InstanceId $mon.InstanceId -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data, '(?i)VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}').Value.ToUpperInvariant() } catch { }
    $override = Test-Path -LiteralPath ($params + '\EDID_OVERRIDE')
    $state = if ($present) { 'connected' } else { 'NOT connected now (seen before)' }
    Add-Line ($mon.InstanceId + ' | ' + $state + ' | status ' + $mon.Status + ' | plugged into ' + $(if ($parent) { $parent } else { 'unknown' }) + ' | Windows EDID override present: ' + $override)
    if (-not $info) { Add-Line '    no EDID stored'; continue }
    Add-Line ('    EDID ' + $info.Maker + $info.Product + ' "' + $info.Name + '" v' + $info.Version + $(if ($info.Year -le (Get-Date).Year + 1) { ', year ' + $info.Year } else { '' }) + ', ' + $info.Length + ' bytes, extensions ' + $info.Extensions + ', checksum ok: ' + $info.ChecksumOk + $(if ($isHeadset) { '   <-- headset display' } else { '' }))
    foreach ($t in $info.Timings) { Add-Line ('    timing: ' + $t) }
    foreach ($n in $info.Notes) { Add-Line ('    ' + $n) }
    if ($isHeadset) {
        if ($present) { $headsetMonitors += [pscustomobject]@{ Instance = $mon.InstanceId; Info = $info; Parent = $parent } }
        Add-Line ('    full EDID, serial masked: ' + (ConvertTo-Hex (Get-MaskedEdid $edid)))
        if ($override) {
            try {
                $o = [byte[]](Get-ItemProperty -LiteralPath ($params + '\EDID_OVERRIDE') -Name '0' -ErrorAction Stop).'0'
                $oi = Get-EdidInfo $o
                if ($oi) { Add-Line ('    override in use: ' + $oi.Maker + $oi.Product + ' "' + $oi.Name + '"'); foreach ($t in $oi.Timings) { Add-Line ('    override timing: ' + $t) } }
            } catch { }
        }
    }
}
if ($monitors.Count -eq 0) { Add-Line 'No monitors could be listed.' }

# ---------- display modes Windows offers for the headset display (report format 2) ----------
# The first Rift CV1 report (Arc B580, HDMI) showed the headset running at 1920x1080 60 Hz, a mode that is not in its
# EDID at all, while its only EDID mode (2160x1200 90 Hz) was not in use. What decides the next step is whether the
# graphics driver still OFFERS that mode (then a session can simply switch to it) or has removed it. This asks Windows
# for the list, the same one "Advanced display settings" shows. Read-only: nothing is tested or changed.
Add-Section 'Display modes Windows offers for the headset display'
$modeResults = @{}
if ($headsetMonitors.Count -eq 0) { Add-Line 'No headset display is connected.' }
else {
    try {
        if (-not ('ArcRiftModeList' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ArcRiftModeList {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevicesW(string device, uint index, ref DISPLAY_DEVICE info, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettingsExW(string device, int mode, ref DEVMODE info, uint flags);
    // For the monitor whose device path contains monitorPathPart (lower case): the display source it is on, its
    // current mode, then every mode Windows offers for it, as "width height hertz". Empty when it is not on a source.
    public static string[] Read(string monitorPathPart) {
        var lines = new List<string>();
        for (uint a = 0; ; a++) {
            var adapter = new DISPLAY_DEVICE(); adapter.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevicesW(null, a, ref adapter, 0)) break;
            for (uint m = 0; ; m++) {
                var monitor = new DISPLAY_DEVICE(); monitor.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevicesW(adapter.DeviceName, m, ref monitor, 1)) break; // 1: return the device interface path
                if ((monitor.DeviceID ?? "").ToLowerInvariant().IndexOf(monitorPathPart, StringComparison.Ordinal) < 0) continue;
                lines.Add("source " + adapter.DeviceName);
                var mode = new DEVMODE(); mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                if (EnumDisplaySettingsExW(adapter.DeviceName, -1, ref mode, 0)) lines.Add("current " + mode.dmPelsWidth + " " + mode.dmPelsHeight + " " + mode.dmDisplayFrequency);
                var seen = new HashSet<string>();
                for (int i = 0; ; i++) {
                    mode = new DEVMODE(); mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                    if (!EnumDisplaySettingsExW(adapter.DeviceName, i, ref mode, 0)) break;
                    string key = mode.dmPelsWidth + " " + mode.dmPelsHeight + " " + mode.dmDisplayFrequency;
                    if (seen.Add(key)) lines.Add("mode " + key);
                }
                return lines.ToArray();
            }
        }
        return lines.ToArray();
    }
}
'@
        }
        foreach ($h in $headsetMonitors) {
            $pathId = (($h.Instance -replace '\\', '#') + '#').ToLowerInvariant()
            $label = $h.Info.Maker + $h.Info.Product
            $own = if ($h.Info.Timings.Count) { [regex]::Match($h.Info.Timings[0], '^(\d+)x(\d+) ') } else { $null }
            $result = [pscustomobject]@{ Listed = $false; OwnSize = ''; OwnRates = @(); Largest = ''; Current = '' }
            if ($own -and $own.Success) { $result.OwnSize = $own.Groups[1].Value + 'x' + $own.Groups[2].Value }
            $modeResults[$h.Instance] = $result
            $lines = @([ArcRiftModeList]::Read($pathId))
            $source = ($lines | Where-Object { $_ -like 'source *' } | Select-Object -First 1) -replace '^source ', ''
            if (-not $source) { Add-Line ($label + ': Windows has not put it on a display source (not an active desktop display), so there is no mode list.'); continue }
            $current = ($lines | Where-Object { $_ -like 'current *' } | Select-Object -First 1) -split ' '
            if ($current.Count -eq 4) { $result.Current = $current[1] + 'x' + $current[2] + ' at ' + $current[3] + ' Hz' }
            $modes = @($lines | Where-Object { $_ -like 'mode *' } | ForEach-Object { $p = $_ -split ' '; [pscustomobject]@{ W = [int]$p[1]; H = [int]$p[2]; Hz = [int]$p[3] } })
            Add-Line ($label + ' on ' + $source + ': now ' + $(if ($result.Current) { $result.Current } else { 'unknown' }) + '; ' + $modes.Count + ' modes offered')
            if ($modes.Count -eq 0) { continue }
            $result.Listed = $true
            $sizes = @($modes | Group-Object { [string]$_.W + 'x' + $_.H } | Sort-Object { $_.Group[0].W * $_.Group[0].H }, { $_.Group[0].W } -Descending)
            foreach ($s in $sizes) { Add-Line ('    ' + $s.Name + ': ' + ((@($s.Group.Hz) | Sort-Object -Unique -Descending) -join ', ') + ' Hz') }
            $result.Largest = $sizes[0].Name
            if ($result.OwnSize) {
                # Either orientation counts: Windows lists a rotated display's modes the way they are shown.
                $turned = $own.Groups[2].Value + 'x' + $own.Groups[1].Value
                $result.OwnRates = @($modes | Where-Object { ([string]$_.W + 'x' + $_.H) -in $result.OwnSize, $turned } | ForEach-Object { $_.Hz } | Sort-Object -Unique -Descending)
                if ($result.OwnRates.Count) { Add-Line ('    The size in the headset''s own EDID, ' + $result.OwnSize + ', IS offered (' + ($result.OwnRates -join ', ') + ' Hz).') }
                else { Add-Line ('    The size in the headset''s own EDID, ' + $result.OwnSize + ', is NOT offered.') }
            }
        }
    } catch { Add-Line ('Could not read the mode list: ' + $_.Exception.Message) }
}

# ---------- display probe ----------
Add-Section 'display_probe.exe (how Windows presents each display)'
$probeText = ''
$probeExe = Join-Path $root 'display_probe.exe'
if (Test-Path -LiteralPath $probeExe) {
    try {
        $probeLines = @(& $probeExe 2>&1 | ForEach-Object { [string]$_ })
        $kept = foreach ($line in $probeLines) {
            # DisplayManager prints each monitor's whole EDID. Keep the headset's (serial masked), cut all others short.
            $m = [regex]::Match($line, '^(\s*EDID=)([0-9a-fA-F]{256,})\s*$')
            if (-not $m.Success) { $line; continue }
            $hex = $m.Groups[2].Value
            $bytes = [byte[]]::new([int]($hex.Length / 2))
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
            if (Test-HeadsetEdid (Get-EdidInfo $bytes)) { $m.Groups[1].Value + (ConvertTo-Hex (Get-MaskedEdid $bytes)) + ' (serial masked)' }
            else { $m.Groups[1].Value + $hex.Substring(0, 24) + '...(rest removed)' }
        }
        $probeText = ($kept -join "`r`n")
        foreach ($line in $kept) { Add-Line $line }
    } catch { Add-Line ('display_probe.exe failed: ' + $_.Exception.Message) }
} else { Add-Line 'display_probe.exe is not in this folder; keep this script inside the ArcRift folder.' }

# ---------- Meta log lines about the headset display ----------
Add-Section 'Meta runtime log (display/headset lines only, newest log)'
$usb2Warned = $false
try {
    $log = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Oculus') -Filter 'Service_*.txt' -ErrorAction Stop | Sort-Object Name | Select-Object -Last 1
    if ($log) {
        Add-Line ('From ' + $log.Name)
        $stream = [IO.File]::Open($log.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [math]::Min($stream.Length, 4MB)
            $null = $stream.Seek(-$take, 'End')
            $buffer = [byte[]]::new($take); $null = $stream.Read($buffer, 0, $take)
        } finally { $stream.Dispose() }
        $wanted = '(?i)\b(hmd|edid|hdmi|displayport|direct ?display|display adapter|gpu|graphics|headset display|rift)\b'
        $unwanted = '(?i)token|account|email|http|user ?id|\bauth|\[Analytics\]|Package|\[LibraryItem\]|\[Registry\]'
        # Meta repeats the same few lines every 15 s. Keep each distinct message once (its newest copy) with a count.
        $counts = @{}; $newest = @{}; $order = New-Object System.Collections.Generic.List[string]
        foreach ($line in (([Text.Encoding]::UTF8.GetString($buffer) -split "`r?`n") | Where-Object { $_ -match $wanted -and $_ -notmatch $unwanted })) {
            $key = $line -replace '^\S+ \S+ \[\s*\d+\]\s*', ''
            if ($counts.ContainsKey($key)) { $null = $order.Remove($key) }
            $counts[$key] = 1 + [int]$counts[$key]; $newest[$key] = $line; $order.Add($key)
        }
        $usb2Warned = [bool]($order | Where-Object { $_ -match '(?i)HMD detected on USB2 port' })
        $lines = @($order | Select-Object -Last 50)
        foreach ($key in $lines) {
            $l = $newest[$key]; if ($l.Length -gt 260) { $l = $l.Substring(0, 260) + '...' }
            if ($counts[$key] -gt 1) { $l += '   (x' + $counts[$key] + ')' }
            # Anything that looks like a serial number (long mixed letters+digits) is masked as well.
            $l = [regex]::Replace($l, '\b(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*\d)[A-Z0-9]{10,24}\b', { param($x) $x.Value.Substring(0, 4) + '[masked]' })
            Add-Line $l
        }
        if ($lines.Count -eq 0) { Add-Line 'No matching lines.' }
    } else { Add-Line 'No Meta runtime log found.' }
} catch { Add-Line ('Meta runtime log not readable: ' + $_.Exception.Message) }

# ---------- summary (inserted near the top) ----------
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('')
$summary.Add('=== Summary ===')
if (-not $arcFound) { $summary.Add('Graphics: no Intel Arc card from ArcRift''s list was found.') }
if (-not $metaServerRunning) { $summary.Add('NOTE: Meta''s runtime was not running. The headset display often only appears while the Meta Horizon app is open and the headset is awake: open it, put the headset on for a few seconds, and run this again.') }
if ($headsetMonitors.Count -eq 0) {
    if ($usbHeadset -or $usb.Count) { $summary.Add('Headset: its USB devices are connected, but Windows sees NO headset display right now (display off, cable not on this card, or not detected).') }
    else { $summary.Add('Headset: not found (no Meta/Oculus USB devices and no headset display).') }
}
$active = [regex]::Match($probeText, '(?s)DisplayConfig flags=22.*?(?=DisplayManager targets|\z)').Value
$allPaths = [regex]::Match($probeText, '(?s)DisplayConfig flags=1 .*?(?=DisplayConfig flags=22|\z)').Value
$entry = '(?m)^\s*target=(\d+) available=(\d) pathFlags=([0-9a-fA-F]+) status=([0-9a-fA-F]+) HMD=(\d) tech=(\d+)[^\r\n]*\r?\n\s*name=([^\r\n]*?) path=([^\r\n]*?) EDID=(\S+)(?:\s*\r?\n\s*signal=(\S+) total=(\S+) pixelClock=(\d+) vSync=(\d+)/(\d+))?'
foreach ($h in $headsetMonitors) {
    $pathId = (($h.Instance -replace '\\', '#') + '#').ToLowerInvariant()
    $kind = switch ($h.Info.Maker + $h.Info.Product) { 'OVR0004' { 'Rift CV1' } 'OVR0012' { 'Rift S' } 'MS_0001' { 'Rift S (placeholder display, normal before a session)' } default { 'Oculus display ' + $h.Info.Maker + $h.Info.Product } }
    $card = $arcCards[($h.Parent -replace '.*DEV_', '')]; if (-not $card) { $card = $h.Parent }
    $summary.Add('Headset display: ' + $kind + ', plugged into ' + $card + '. Its own EDID offers: ' + $(if ($h.Info.Timings.Count) { $h.Info.Timings[0] } else { 'no detailed timing' }))
    $found = $null
    foreach ($m in [regex]::Matches($active, $entry)) { if ($m.Groups[8].Value.ToLowerInvariant().Contains($pathId)) { $found = $m; break } }
    $usage = [regex]::Match($probeText, '(?im)^\s*target=\d+ connected=1 usage=(\d+) path=[^\r\n]*' + [regex]::Escape($pathId))
    $usageHmd = $usage.Success -and $usage.Groups[1].Value -ne '0'
    if ($found) {
        $tech = $outputTech[$found.Groups[6].Value]; if (-not $tech) { $tech = 'type ' + $found.Groups[6].Value }
        $hz = if ($found.Groups[14].Success -and [double]$found.Groups[14].Value) { [math]::Round([double]$found.Groups[13].Value / [double]$found.Groups[14].Value, 2) } else { 0 }
        if ($found.Groups[5].Value -eq '1' -or $usageHmd) { $summary.Add('  RESULT B: Windows treats it as a head-mounted display and keeps it off the desktop (connection: ' + $tech + ').') }
        elseif ($found.Groups[10].Success) { $summary.Add('  RESULT A: Windows uses it as a normal desktop display, ' + $found.Groups[10].Value + ' at ' + $hz + ' Hz over ' + $tech + '.') }
        else { $summary.Add('  Windows lists it over ' + $tech + ' but reports no signal for it.') }
        # Report format 2: is the headset's own mode in use, only offered, or not offered at all?
        $mr = $modeResults[$h.Instance]
        # (Not for the Rift S placeholder display: its EDID is not the headset's real mode.)
        if ($mr -and $mr.Listed -and $mr.OwnSize -and $h.Info.Maker -eq 'OVR' -and $found.Groups[5].Value -ne '1' -and -not $usageHmd) {
            $ownTurned = (($mr.OwnSize -split 'x')[1] + 'x' + ($mr.OwnSize -split 'x')[0])
            if ($found.Groups[10].Success -and $found.Groups[10].Value -in $mr.OwnSize, $ownTurned) { $summary.Add('  MODE OK: it is running at the size in its own EDID (' + $mr.OwnSize + ').') }
            elseif ($mr.OwnRates.Count) { $summary.Add('  MODE AVAILABLE: Windows offers the size in its own EDID (' + $mr.OwnSize + ' at ' + ($mr.OwnRates -join ', ') + ' Hz) but is not using it right now.') }
            else { $summary.Add('  MODE MISSING: Windows does not offer the size in its own EDID (' + $mr.OwnSize + '); the largest offered is ' + $mr.Largest + '. The graphics driver left it out. If the headset is on an adapter (for example DisplayPort to HDMI) instead of straight into the card, say so when sending this.') }
        }
    } elseif ([regex]::Matches($allPaths, $entry) | Where-Object { $_.Groups[8].Value.ToLowerInvariant().Contains($pathId) }) {
        $summary.Add('  RESULT C: Windows sees it connected, but it is not an active desktop display' + $(if ($usageHmd) { ' (marked as head-mounted)' } else { '' }) + '.')
    } else { $summary.Add('  Windows has a monitor device for it, but display_probe did not list it.') }
}
if ($usb2Warned) { $summary.Add('NOTE: Meta''s runtime says the headset is on a USB 2 port, which it calls unsupported. Use a USB 3 port (usually blue) if the PC has one.') }
$report.InsertRange(3, $summary)

$final = foreach ($line in $report) { Hide-Secrets $line }
[IO.File]::WriteAllLines($OutputPath, [string[]]$final, (New-Object Text.UTF8Encoding($false)))
foreach ($line in $summary) { Write-Output (Hide-Secrets $line) }
Write-Output ''
Write-Output ('Report written: ' + $OutputPath)
