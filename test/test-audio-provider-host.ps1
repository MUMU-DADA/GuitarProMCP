param([Parameter(Mandatory=$true)][string]$HostDirectory)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
$HostDirectory = [IO.Path]::GetFullPath($HostDirectory)
if (-not $HostDirectory.StartsWith(([IO.Path]::GetFullPath((Join-Path $root '.tools')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Use an isolated host under .tools.' }
if (Test-Path (Join-Path $HostDirectory 'Plugins/generic/guitarpro_mcp.dll')) { throw 'Use a clean host without an installed Provider for loading-order tests.' }
if (Get-Process GuitarPro -ErrorAction SilentlyContinue) { throw 'Close Guitar Pro before the isolated Provider test.' }
. "$root/native/mcp-client.ps1"
$run = Join-Path $root ('artifacts/native-audio-provider-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$checks = 0
$complete = $false
$previousTrack = $null
$envBefore = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_SESSION_FILE','GPMCP_DATA_DIR','GPMCP_BACKGROUND','GPMCP_AUDIO_CONSUMER_DIRECTORY','TEMP','TMP')) { $envBefore[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
function Check($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 40 -Compress }
function Wait-Operation($request, [string]$expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if ($state.status -in @($expected,'error','cancelled')) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq $expected) "Operation did not reach $expected."
    $state
}
function Snapshot([string]$name) {
    $request = [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $data 'consumer-request.txt'),$request)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $state = if (Test-Path (Join-Path $data 'consumer-result.json')) { Get-Content (Join-Path $data 'consumer-result.json') -Raw | ConvertFrom-Json } else { $null }
        if ($state.request -eq $request) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.request -eq $request -and $state.pid -eq $process.Id) 'Consumer did not return the requested in-process snapshot.'
    $state | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $data "$name.json") -Encoding UTF8
    Check ($state.status -eq 'observed' -and $state.abi_version -eq 1) 'Consumer did not negotiate the real Provider ABI.'
    Check ($state.host_sha256 -eq (Get-FileHash (Join-Path $HostDirectory 'GuitarPro.exe')).Hash) 'Provider host hash differs.'
    Check ($state.info_status -eq $state.info_status_field -and $state.enumerate_status -eq $state.enumerate_status_field) 'Status return and output field disagree.'
    Check ($state.abi_mismatch -eq 3 -and $state.short_result -eq 3 -and $state.short_info -eq 3) 'ABI mismatch or truncated structure was accepted.'
    Check ($state.worker_info -eq 4 -and $state.worker_enumerate -eq 4) 'Real Provider accepted a worker-thread call.'
    Check ($state.null_visitor -eq 5) 'Null visitor was not rejected.'
    Check ($state.count -eq @($state.bindings).Count) 'Callback count differs from result.'
    $state
}
try {
    foreach ($order in @('consumer-first','provider-first')) {
        $data = Join-Path $run $order
        New-Item -ItemType Directory -Path $data | Out-Null
        'gpmcp-audio-consumer-test' | Set-Content (Join-Path $data 'isolated-audio-consumer-test')
        $fixture = Join-Path $data 'score.gp'
        Copy-Item "$PSScriptRoot/testdata/minimal.gp" $fixture
        $fixtureHash = (Get-FileHash $fixture).Hash
        $sessionFile = Join-Path $data 'native-session.json'
        $env:QT_PLUGIN_PATH = "$root/.tools/audio-bridge-probe/plugins;$root/.tools/native/plugins"
        $env:QT_QPA_GENERIC_PLUGINS = if ($order -eq 'consumer-first') { 'guitarpro_audio_consumer,guitarpro_mcp' } else { 'guitarpro_mcp,guitarpro_audio_consumer' }
        $env:GPMCP_SESSION_FILE = $sessionFile
        $env:GPMCP_DATA_DIR = $data
        $env:GPMCP_BACKGROUND = '1'
        $env:GPMCP_AUDIO_CONSUMER_DIRECTORY = $data
        $env:TEMP = $data
        $env:TMP = $data
        $process = Start-Process -FilePath (Join-Path $HostDirectory 'GuitarPro.exe') -ArgumentList @('--open',('"' + $fixture + '"')) -WorkingDirectory $HostDirectory -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $data 'stderr.log')
        $null = $process.Handle
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path $sessionFile) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Check (Test-Path $sessionFile) 'Provider did not start after the consumer.'
        $connection = New-McpSession -SessionFile $sessionFile
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            $docs = (Invoke-McpTool $connection gp_documents).documents
            if (@($docs).Count -eq 1) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        Check (@($docs).Count -eq 1 -and -not $docs[0].dirty) 'One clean test score is required.'
        $id = $docs[0].id
        $scoreBefore = Invoke-McpTool $connection gp_score @{document=$id}
        $before = Snapshot 'before'
        Check ($before.info_status -eq 0 -and $before.count -gt 0) 'No real track context was delivered.'
        $track = @($before.bindings | Where-Object document_id -EQ $id)[0]
        Check ($track.track_id -and $track.generation -gt 0 -and $track.struct_size -eq 72) 'Track context lacks identity or generation.'
        if (-not $track.has_chain) { Check ($track.status -eq 2 -and $track.sound_index -eq -1 -and $before.enumerate_status -eq 2) 'Unresolved chain was reported as successful.' }
        $secondClient = New-McpSession -SessionFile $sessionFile
        try { $mcp = Invoke-McpTool $secondClient gp_audio_abi @{document=$id} } finally { Close-McpSession $secondClient }
        Check ($mcp.tracks[0].track_id -eq $track.track_id -and $mcp.generation -eq $track.generation) 'MCP and consumer do not share one Provider identity.'
        $repeat = Snapshot 'repeat'
        Check ((Json $repeat.bindings) -eq (Json $before.bindings)) 'Read-only enumeration changed stable bindings.'
        Check ((Json (Invoke-McpTool $connection gp_score @{document=$id})) -eq (Json $scoreBefore)) 'Enumeration changed score, cursor or undo state.'
        if ($previousTrack) { Check ((Invoke-McpTool $connection gp_audio_abi @{document=$id;operation='resolve';track_id=$previousTrack} -AllowError).reason -eq 'unknown_or_expired_track_id') 'Previous-host handle survived restart.' }
        Invoke-McpTool $connection gp_edit_tracks @{document=$id;operation='duplicate';track=0} | Out-Null
        $changed = Snapshot 'track-added'
        $changedRows = @($changed.bindings | Where-Object document_id -EQ $id)
        Check ($changedRows.Count -eq 2 -and $changedRows[0].generation -gt $track.generation) 'Track topology change did not advance generation.'
        Check ((Invoke-McpTool $connection gp_audio_abi @{document=$id;operation='resolve';track_id=$track.track_id} -AllowError).reason -eq 'unknown_or_expired_track_id') 'Old track handle survived topology change.'
        Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'} | Out-Null
        $undo = Snapshot 'undo'
        Check ($undo.count -eq 1 -and $undo.bindings[0].generation -gt $changedRows[0].generation) 'Undo did not invalidate the changed topology.'
        Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
        $redo = Snapshot 'redo'
        Check ($redo.count -eq 2 -and $redo.generation -gt $undo.generation) 'Redo did not advance the Provider revision.'
        $savedPath = Join-Path $data 'saved.gp'
        Invoke-McpTool $connection gp_save_as @{document=$id;path=$savedPath} | Out-Null
        $saved = Snapshot 'save-as'
        Check ($saved.bindings[0].track_id -eq $redo.bindings[0].track_id -and $saved.bindings[0].score_key -eq $savedPath.Replace('\','/')) 'Save As changed track identity or retained the old path.'
        $copyPath = Join-Path $data 'other.gp'
        Copy-Item $savedPath $copyPath
        $other = (Wait-Operation (Invoke-McpTool $connection gp_open @{path=$copyPath}).request 'opened').document
        Invoke-McpTool $connection gp_activate @{document=$other} | Out-Null
        $multiple = Snapshot 'multiple'
        Check (@($multiple.bindings | Where-Object document_id -EQ $other).Count -eq 2) 'Active document contexts were not isolated.'
        $inactive = Invoke-McpTool $connection gp_audio_abi @{document=$id} -AllowError
        if ($inactive.status -eq 'host_limited') {
            Check ($multiple.enumerate_status -eq 2 -and @($multiple.bindings | Where-Object document_id -EQ $id).Count -eq 0) 'An unavailable inactive conductor was guessed.'
        } else { Check (@($multiple.bindings | Where-Object document_id -EQ $id).Count -eq 2) 'Available inactive contexts were omitted.' }
        Check (@($multiple.bindings | Where-Object { $_.active_document -eq 1 -and $_.document_id -ne $other }).Count -eq 0) 'Wrong document marked active.'
        Invoke-McpTool $connection gp_activate @{document=$id} | Out-Null
        $reactivated = Snapshot 'reactivated'
        $reactivatedRows = @($reactivated.bindings | Where-Object document_id -EQ $id)
        Check ($reactivatedRows.Count -eq 2 -and $reactivatedRows[0].track_id -eq $saved.bindings[0].track_id) 'Reactivation lost the original document identity.'
        Invoke-McpTool $connection gp_activate @{document=$other} | Out-Null
        Wait-Operation (Invoke-McpTool $connection gp_close @{document=$id}).request 'closed' | Out-Null
        $closed = Snapshot 'closed'
        Check (@($closed.bindings | Where-Object document_id -EQ $id).Count -eq 0) 'Closed-document contexts remained in the Provider.'
        Check ((Invoke-McpTool $connection gp_audio_abi @{document=$other;operation='resolve';track_id=$saved.bindings[0].track_id} -AllowError).reason -eq 'unknown_or_expired_track_id') 'Closed-document handle was retained.'
        $previousTrack = $closed.bindings[0].track_id
        Wait-Operation (Invoke-McpTool $connection gp_close @{document=$other}).request 'closed' | Out-Null
        $empty = Snapshot 'empty'
        Check ($empty.info_status -eq 1 -and $empty.enumerate_status -eq 1 -and $empty.count -eq 0) 'No-document state did not return not_ready.'
        Check ((Get-FileHash $fixture).Hash -eq $fixtureHash) 'Original fixture file bytes changed.'
        $windows = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
        $main = @($windows.objects | Where-Object class -EQ 'gp::gui::MainWindow')[0]
        try { Invoke-McpTool $connection gp_close_window @{snapshot=$windows.snapshot;id=$main.id} | Out-Null } catch { if (-not $process.WaitForExit(5000)) { throw } }
        Check ($process.WaitForExit(60000)) 'Host did not exit normally.'
        $process.Refresh()
        Check ($process.ExitCode -eq 0 -and -not (Test-Path $sessionFile)) 'Host exit or descriptor cleanup failed.'
        Check (Test-Path (Join-Path $data 'consumer-exit.json')) 'Consumer did not observe shutdown.'
        $process.Dispose()
        $process = $null
    }
    $complete = $true
} finally {
    foreach ($name in $envBefore.Keys) { [Environment]::SetEnvironmentVariable($name,$envBefore[$name],'Process') }
    @{complete=$complete;checks=$checks;host=$HostDirectory;provider_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash;consumer_sha256=(Get-FileHash "$root/.tools/audio-bridge-probe/plugins/generic/guitarpro_audio_consumer.dll").Hash} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    if ($process -and -not $process.HasExited) { Write-Warning "Test host retained: PID $($process.Id); $run" }
}
Write-Output "PASS: $checks real audio Provider and native consumer checks. Evidence: $run"
