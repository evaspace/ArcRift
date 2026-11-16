function Get-ArcRiftRecoveryLayouts([string]$Text) {
    $layouts = @{}
    # Release 1.3: same reading as Get-ActiveLayouts in test-ovr-d3d11.ps1. Active = bit 0 of the hex path flags (not
    # the text "pathFlags=1"); keyed by target ID and monitor path, since two adapters can share a target ID.
    $pattern = '(?m)^\s*target=(\d+) [^\r\n]*pathFlags=[0-9a-fA-F]*[13579bdfBDF] [^\r\n]*\r?\n([^\r\n]*)\r?\n\s*(signal=[^\r\n]+)\r?\n\s*(source=[^\r\n]+)'
    foreach ($m in [regex]::Matches($Text,$pattern)) {
        $path=[regex]::Match($m.Groups[2].Value,'path=(\S+)')
        $key=$m.Groups[1].Value
        if ($path.Success) { $key+='|'+$path.Groups[1].Value.ToLowerInvariant() }
        $layouts[$key]=$m.Groups[3].Value.Trim()+' '+$m.Groups[4].Value.Trim()
    }
    if (-not $layouts.Count) { throw 'No display layouts parsed; recovery cannot claim success.' }
    return $layouts
}
function Assert-ArcRiftRecoveryScope($Registry,$Plugins,$Edid) {
    $allowed = @(
        'HKLM:\SOFTWARE\Oculus|DirectDisplayDLL',
        'HKLM:\SOFTWARE\Oculus|ForceGPUDriverVersionAcceptance',
        'HKLM:\SOFTWARE\WOW6432Node\Oculus VR, LLC\Oculus\Config|PreventDashLaunch'
    )
    # Release 1.4: sessions also set ForceSensorTracking (Meta keeps tracking on while the headset is off). Sessions
    # from before that have the three settings above only, so a backup holds those three, with or without this one.
    $optional = @('HKLM:\SOFTWARE\WOW6432Node\Oculus VR, LLC\Oculus|ForceSensorTracking')
    # Release 1.1.2: a session skips streaming plugins Meta no longer installs, so 0-3 plugin backups are valid.
    if (@($Registry).Count -lt 3 -or @($Registry).Count -gt 4 -or @($Plugins).Count -gt 3) { throw 'Recovery backup count mismatch.' }
    $pluginFolder = Join-Path (Get-ArcRiftMetaRuntimePath) 'server-plugins'
    $seen = @{}
    foreach ($r in $Registry) {
        $key=$r.Path+'|'+$r.Name
        if (($key -notin $allowed -and $key -notin $optional) -or $seen.ContainsKey($key)) { throw 'Recovery registry scope mismatch.' }
        $seen[$key]=$true
    }
    foreach ($key in $allowed) { if (-not $seen.ContainsKey($key)) { throw 'Recovery registry scope mismatch.' } }
    $seen=@{}
    foreach ($p in $Plugins) {
        $name=[IO.Path]::GetFileName($p.Original)
        $expected=Join-Path $pluginFolder $name
        if ($name -notin @('RemoteHeadset.dll','RemoteHeadset_v55.dll','RemoteHeadsetDisco.dll') -or
            $p.Original -ne $expected -or $p.Temporary -ne ($expected+'.arc-rift-d3d11-disabled') -or
            $p.Hash -notmatch '^[a-fA-F0-9]{64}$' -or $seen.ContainsKey($name)) { throw 'Recovery plugin scope mismatch.' }
        $seen[$name]=$true
    }
    $cfgInstance = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'arcrift-config.json') -Raw | ConvertFrom-Json).monitorInstance
    if ($Edid.KeyExisted -or -not $cfgInstance -or $Edid.Instance -ne $cfgInstance) { throw 'Recovery EDID scope mismatch.' }
}
