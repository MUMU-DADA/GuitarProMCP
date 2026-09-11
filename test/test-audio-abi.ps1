param(
    [string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json",
    [int]$Frames = 64,
    [switch]$RequireProbe,
    [switch]$RequireBoundChain
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-audio-abi-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$checks = 0
$hostLimited = @()
$chainEvidence = @()
$complete = $false
function Check($condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
function Json($value) { ConvertTo-Json -InputObject $value -Depth 40 -Compress }
function Has-Property($value, [string]$name) { return $null -ne ($value.PSObject.Properties | Where-Object Name -EQ $name) }
try {
    Check ($Frames -ge 1 -and $Frames -le 4096) 'Frames must be in the native probe range 1..4096.'
    $documents = Invoke-McpTool $connection gp_documents
    # Full regression keeps several saved documents open; bind this probe to
    # the active document instead of assuming the first tab owns an RSE
    # conductor.  Standalone runs still fall back to the first document.
    $document = @($documents.documents | Where-Object active | Select-Object -First 1)[0]
    if (-not $document) { $document = @($documents.documents | Select-Object -First 1)[0] }
    Check ($document.id) 'Audio ABI verification requires an open document.'

    $state1 = Invoke-McpTool $connection gp_audio_abi @{document=$document.id;operation='state'} -AllowError
    $state1 | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $run 'state-before.json') -Encoding UTF8
    Check ($state1.status -in @('verified','experimental','host_limited')) 'Audio ABI returned an unknown overall status.'
    Check ($state1.rse_abi_verified -eq $true -and $state1.audio_abi_verified -eq $true) 'Verified 8.1.1.17 RSE/AMAudio hashes were not reported.'
    Check ($state1.handle_policy -eq 'opaque_process_local_revalidated') 'Audio handles are not reported as revalidated opaque capabilities.'
    Check ($state1.track_binding_status -eq 'verified' -and @($state1.tracks).Count -gt 0) 'No verified core Track binding was returned.'

    $trackIds = @{}
    foreach ($track in @($state1.tracks)) {
        $parsed = [guid]::Empty
        Check ([guid]::TryParse([string]$track.track_id, [ref]$parsed)) "track_id is not a UUID: $($track.track_id)"
        Check (-not $trackIds.ContainsKey([string]$track.track_index)) "Duplicate track index: $($track.track_index)"
        $trackIds[[string]$track.track_index] = [string]$track.track_id
        $resolvedTrack = Invoke-McpTool $connection gp_audio_abi @{document=$document.id;operation='resolve';track_id=$track.track_id} -AllowError
        Check ($resolvedTrack.status -eq 'verified' -and $resolvedTrack.track_id -eq $track.track_id -and $resolvedTrack.track_index -eq $track.track_index) "track_id did not resolve to its original core Track: $($track.track_id)"
    }
    $state2 = Invoke-McpTool $connection gp_audio_abi @{document=$document.id;operation='state'} -AllowError
    foreach ($track in @($state2.tracks)) {
        Check ($trackIds[[string]$track.track_index] -eq [string]$track.track_id) "track_id changed during repeated state read: $($track.track_index)"
    }
    $state2 | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $run 'state-after.json') -Encoding UTF8

    $chains = @($state1.tracks | ForEach-Object { @($_.chains) } | Where-Object { $_.chain_id })
    if ($chains.Count -eq 0) {
        $hostLimited += 'bound_chain'
        Check ($state1.chain_mapping_status -eq 'host_limited') 'Missing RSE chains did not report host_limited.'
        if ($RequireBoundChain) { throw 'RequireBoundChain was specified, but this host did not expose a Conductor Sound/EffectsChain.' }
    }
    foreach ($chain in $chains) {
        $resolved = Invoke-McpTool $connection gp_audio_abi @{document=$document.id;operation='resolve';chain_id=$chain.chain_id} -AllowError
        Check ($resolved.status -eq 'verified' -and $resolved.chain_id -eq $chain.chain_id) "chain_id did not resolve: $($chain.chain_id)"
        Check ($resolved.track_id -eq $trackIds[[string]$resolved.track_index]) "chain_id resolved to the wrong track: $($chain.chain_id)"
        $chainEvidence += @{chain_id=$chain.chain_id;track_id=$resolved.track_id;track_index=$resolved.track_index;sound_index=$resolved.sound_index;chain_index=$resolved.chain_index}
        if ($RequireBoundChain -or $RequireProbe) {
            $boundProbe = Invoke-McpTool $connection gp_audio_abi @{document=$document.id;operation='buffer_probe';chain_id=$chain.chain_id;frames=$Frames} -AllowError
            Check ($boundProbe.status -eq 'verified' -and $boundProbe.process_source -eq 'bound_track_chain') 'Bound EffectsChain probe did not complete.'
            Check ($boundProbe.write_roundtrip -and $boundProbe.lock_roundtrip -and $boundProbe.process_dsp_invoked -and $boundProbe.process_changed) 'Bound EffectsChain probe missed an audio boundary check.'
            $boundProbe | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run ('bound-probe-' + $chain.chain_id + '.json')) -Encoding UTF8
        }
    }

    $probes = @(1..3 | ForEach-Object { Invoke-McpTool $connection gp_audio_abi @{document=$document.id;operation='buffer_probe';frames=$Frames} -AllowError })
    $probe = $probes[-1]
    $probes | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run 'buffer-probe.json') -Encoding UTF8
    if ($probe.status -eq 'verified') {
        foreach ($candidate in $probes) { Check ($candidate.status -eq 'verified') 'Repeated AudioBuffer probe did not remain verified.' }
        Check ($probe.frames -eq $Frames -and $probe.channels -eq 2) 'AudioBuffer dimensions differ from the requested probe.'
        Check ($probe.write_roundtrip -and $probe.lock_roundtrip -and $probe.process_dsp_invoked -and $probe.process_changed) 'IAudioBuffer/DSP probe did not prove the writable boundary.'
        Check ($probe.process_source -in @('bound_track_chain','converted_core_sound_chain')) 'Unknown EffectsChain probe source.'
    } else {
        $hostLimited += 'buffer_probe'
        Check ($probe.status -eq 'host_limited' -and $probe.reason) 'A failed buffer probe did not explain the host limitation.'
        if ($RequireProbe) { throw "RequireProbe was specified, but buffer_probe returned host_limited: $($probe.reason)" }
    }

    $unknown = Invoke-McpTool $connection gp_audio_abi @{document=$document.id;operation='resolve';chain_id='00000000-0000-0000-0000-000000000000'} -AllowError
    Check ($unknown.status -eq 'error' -and $unknown.reason -eq 'unknown_or_expired_chain_id') 'Unknown chain_id was accepted.'
    $unknownTrack = Invoke-McpTool $connection gp_audio_abi @{document=$document.id;operation='resolve';track_id='00000000-0000-0000-0000-000000000000'} -AllowError
    Check ($unknownTrack.status -eq 'error' -and $unknownTrack.reason -eq 'unknown_or_expired_track_id') 'Unknown track_id was accepted.'
    $knownTrack = [string](@($state1.tracks | Select-Object -First 1)[0].track_id)
    $foreign = Invoke-McpTool $connection gp_audio_abi @{document='11111111-1111-1111-1111-111111111111';operation='resolve';track_id=$knownTrack} -AllowError
    Check ($foreign.status -eq 'error' -and $foreign.reason -eq 'stale_track_id') 'A track_id was accepted for an unavailable/foreign document.'
    $probeVerified = $probe.status -eq 'verified'
    $complete = $probeVerified -and $chains.Count -gt 0
    @{complete=$complete;checks=$checks;host_limited=$hostLimited;document=$document.id;chains=$chainEvidence;
        source=(Get-FileHash (Join-Path $root 'native/guitarpro_audio.h')).Hash;
        plugin_sha256=(Get-FileHash (Join-Path $root '.tools/native/plugins/generic/guitarpro_mcp.dll') -ErrorAction SilentlyContinue).Hash} |
        ConvertTo-Json -Depth 30 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    Write-Output "PASS: $checks audio ABI checks. Host-limited: $($hostLimited -join ', '); Evidence: $run"
} finally {
    try { Close-McpSession $connection } catch {}
    if (-not (Test-Path (Join-Path $run 'verification.json'))) {
        @{complete=$false;checks=$checks;host_limited=$hostLimited} |
            ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    }
}
