param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-audio-stream-host-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $run | Out-Null
$checks = 0
$complete = $false
$connection = $null
$streamId = ''
$playing = $false
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 30 -Compress }
try {
    $connection = New-McpSession -SessionFile $SessionFile
    $documents = Invoke-McpTool $connection gp_documents
    $document = @($documents.documents | Where-Object active | Select-Object -First 1)[0]
    if (-not $document) { $document = @($documents.documents | Select-Object -First 1)[0] }
    Assert ($document -and $document.id) 'P14 host stream test requires an open native document.'

    $state = Invoke-McpTool $connection gp_audio_stream @{operation='state'}
    Assert ($state.status -eq 'ready' -and $state.pcm_available -eq $true) 'P14 stream provider was not ready in the Guitar Pro process.'

    $started = Invoke-McpTool $connection gp_audio_stream @{operation='start';document=$document.id;backend='process_loopback';layers=@('track','effects','mix','endpoint');max_frames=512;max_bytes=65536}
    $streamId = [string]$started.stream_id
    Assert ($started.status -eq 'running' -and $streamId) 'P14 host stream did not start.'
    Assert ($started.capture_scope -eq 'process_loopback' -and $started.sample_rate -gt 0 -and $started.channels -gt 0) 'P14 host stream did not bind process loopback format.'
    Assert (@($started.layer_states | Where-Object { $_.layer -eq 'endpoint' -and $_.status -eq 'observed' }).Count -eq 1) 'Endpoint observation was not reported.'
    Assert (@($started.layer_states | Where-Object { $_.layer -eq 'track' -and $_.status -eq 'not_observed' }).Count -eq 1) 'Unobserved internal layer was not reported explicitly.'

    $play = Invoke-McpTool $connection gp_playback @{document=$document.id;operation='play'} -AllowError
    Assert (-not $play.error) 'P14 host playback could not be started for the realtime observation.'
    $playing = $true
    Start-Sleep -Milliseconds 500
    $snapshot = Invoke-McpTool $connection gp_audio_stream @{operation='snapshot';stream_id=$streamId}
    Assert ($snapshot.status -eq 'running' -and $snapshot.frame_count -gt 0 -and $snapshot.window.frames -gt 0) 'P14 host snapshot did not observe realtime frames.'
    Assert ($snapshot.window.rms -gt 0.0001 -and $snapshot.window.peak -gt 0.001) 'P14 host snapshot did not observe non-silent Guitar Pro output.'
    Assert ($snapshot.window.non_finite -eq 0 -and $snapshot.sample_rate -gt 0 -and $snapshot.frames_per_block -eq 256) 'P14 host snapshot metrics were invalid.'

    $read = Invoke-McpTool $connection gp_audio_stream @{operation='read';stream_id=$streamId;max_frames=128;max_bytes=32768}
    Assert ($read.status -eq 'running' -and $read.frames -gt 0 -and $read.pcm_available -and @($read.chunks).Count -gt 0) 'P14 host PCM read returned no bounded data.'
    Assert (@($read.chunks | Where-Object { $_.format -eq 'f32le' -and $_.layer -eq 'endpoint' }).Count -eq @($read.chunks).Count) 'P14 host PCM chunk metadata was invalid.'

    $diagnosis = Invoke-McpTool $connection gp_audio_stream @{operation='diagnose';stream_id=$streamId}
    Assert ($diagnosis.diagnostic_status -eq 'ok' -and @($diagnosis.checks).Count -eq 5) 'P14 host diagnostics did not complete.'
    $recovered = Invoke-McpTool $connection gp_audio_stream @{operation='recover';stream_id=$streamId}
    Assert ($recovered.recovered -eq $true -and $recovered.status -eq 'running' -and $recovered.capture_scope -eq 'process_loopback') 'P14 host recovery did not restart the process loopback.'
    $stopped = Invoke-McpTool $connection gp_audio_stream @{operation='stop';stream_id=$streamId}
    Assert ($stopped.status -eq 'stopped' -and $stopped.state -eq 'stopped' -and -not $stopped.pcm_available) 'P14 host stream did not stop.'
    Invoke-McpTool $connection gp_playback @{document=$document.id;operation='stop'} -AllowError | Out-Null
    $playing = $false
    $complete = $true
    @{complete=$complete;checks=$checks;document=$document.id;state=$state;started=$started;playback=$play;snapshot=$snapshot;read=$read;diagnosis=$diagnosis;recovered=$recovered;stopped=$stopped;plugin_sha256=(Get-FileHash (Join-Path $root '.tools/native/plugins/generic/guitarpro_mcp.dll')).Hash} |
        ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    Write-Output "PASS: $checks P14 host MCP stream checks. Evidence: $run"
} finally {
    if ($connection) {
        if ($streamId) { try { Invoke-McpTool $connection gp_audio_stream @{operation='stop';stream_id=$streamId} -AllowError | Out-Null } catch {} }
        if ($playing) { try { Invoke-McpTool $connection gp_playback @{document=$document.id;operation='stop'} -AllowError | Out-Null } catch {} }
        try { Close-McpSession $connection } catch {}
    }
    if (-not (Test-Path -LiteralPath (Join-Path $run 'verification.json'))) {
        @{complete=$complete;checks=$checks} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    }
}
