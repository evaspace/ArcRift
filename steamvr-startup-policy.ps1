# Pure startup state policy; no process or graphics operations.
function Test-ArcRiftSteamVRStartup {
    param([hashtable]$State, [int[]]$ServerIds, [int[]]$CompositorIds, [bool]$FreshStartupComplete)
    if ($ServerIds.Count -gt 1 -or $CompositorIds.Count -gt 1) { throw 'Multiple SteamVR server/compositor processes during startup.' }
    foreach ($pair in @(@('ServerId', $ServerIds), @('CompositorId', $CompositorIds))) {
        $key = $pair[0]
        $ids = @($pair[1])
        if ($State[$key]) {
            if ($ids.Count -ne 1 -or $ids[0] -ne $State[$key]) { throw ('SteamVR startup process exited/restarted: ' + $key) }
        } elseif ($ids.Count -eq 1) { $State[$key] = $ids[0] }
    }
    return $ServerIds.Count -eq 1 -and $CompositorIds.Count -eq 1 -and $FreshStartupComplete
}

# Release 1.4: what SteamVR's compositor log says about a launch, as the number of sync-timeout lines in it. A lost or
# hung GPU device always fails the launch. Sync timeouts fail it too, unless the caller tolerates them: a manual
# session does, up to $Limit lines (one hitch writes up to three), because a running manual session only notes these
# and its frame-rate, freeze and device-loss guards cover real trouble. Seen 2026-11-15 with SteamVR's render
# resolution at 150 %: one "WaitForAcquire timed out" on the very first frame, 22 ms after "Startup Complete".
function Get-ArcRiftBootstrapSyncCount {
    param([string]$GraphicsTail, [bool]$TolerateSyncTimeouts, [int]$Limit = 6)
    if ($GraphicsTail -match '(?i:DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG)') { throw 'Graphics/synchronization failure during normal-user bootstrap.' }
    $count = [regex]::Matches($GraphicsTail, '(?i:AcquireSync FAILED|ReleaseSync FAILED|WaitForAcquire timed out)').Count
    if ($count -and -not $TolerateSyncTimeouts) { throw 'Graphics/synchronization failure during normal-user bootstrap.' }
    if ($count -gt $Limit) { throw ('Graphics/synchronization failure during normal-user bootstrap (' + $count + ' SteamVR sync errors while starting).') }
    return $count
}

function Read-ArcRiftStartupLog {
    param([string]$Path, [ref]$Offset)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if ($stream.Length -lt $Offset.Value) { $Offset.Value = 0L }
        $null = $stream.Seek($Offset.Value,[IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $Offset.Value = $stream.Position
        return $text
    } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
}

# vrstartup is a short-lived bootstrapper, NOT the pinned server/compositor.
# Any participant that exited before its token could be read (e.g. Steam restarting itself) is skipped;
# its replacement gets a new PID and is checked on its own. Server/compositor/diagnostic exits have their own guards.
function Get-ArcRiftParticipantTokenDecision {
    param([string]$Name, [int]$Integrity, [bool]$ConfirmedExited)
    if ($Integrity -eq 8192) { return 'VerifiedMedium' }
    if ($Integrity -lt 0 -and $ConfirmedExited) { return 'ExitedLauncher' }
    throw ('Unexpected participant token: ' + $Name + ' RID=' + $Integrity)
}
