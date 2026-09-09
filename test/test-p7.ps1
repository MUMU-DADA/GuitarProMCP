param(
    [Parameter(Mandatory=$true)][string]$HostDirectory,
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [ValidateRange(1,1440)][int]$DurationMinutes = 60,
    [ValidateRange(1,10000)][int]$MinimumCycles = 100
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http
$root = Split-Path -Parent $PSScriptRoot
$HostDirectory = (Resolve-Path -LiteralPath $HostDirectory).Path
$PackageDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
if (-not $HostDirectory.StartsWith(([IO.Path]::GetFullPath((Join-Path $root '.tools')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Use an isolated host under .tools.' }
if (@(Get-Process GuitarPro -ErrorAction SilentlyContinue).Count) { throw 'Close Guitar Pro before the exclusive soak test.' }
. "$PackageDirectory/mcp-client.ps1"
$run = Join-Path $root ('artifacts/p7-soak-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$sessionFile = Join-Path $run 'native-session.json'
$manifest = Get-Content -LiteralPath "$PackageDirectory/package.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$sources = @(Get-ChildItem -LiteralPath @((Join-Path $root 'native'),$PSScriptRoot) -File | Where-Object Extension -In @('.ps1','.h','.cpp','.json','.def') | Get-FileHash | Select-Object Path,Hash)
$checks = 0; $cycles = 0; $complete = $false; $failure = $null
$process = $null; $first = $null; $second = $null; $clock = $null; $exitCode = $null
$loaded = @(); $samples = @(); $scale = $null; $held = @(); $started = [DateTime]::UtcNow
$handler = [Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false; $handler.AllowAutoRedirect = $false
$http = [Net.Http.HttpClient]::new($handler)
$http.Timeout = [TimeSpan]::FromSeconds(15)
function Check($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Wait-Operation($session, [string]$request, [string]$expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $state = (Invoke-McpTool $session gp_operation @{request=$request}).operation
        if ($state.status -in @($expected,'error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq $expected) "Unexpected $expected outcome: $($state | ConvertTo-Json -Depth 8 -Compress)"
    return $state.document
}
function Open-Score([string]$path) { Wait-Operation $first (Invoke-McpTool $first gp_open @{path=$path}).request 'opened' }
function Close-Score([string]$document) { Wait-Operation $first (Invoke-McpTool $first gp_close @{document=$document}).request 'closed' | Out-Null }
function Read-Gpif([string]$path) {
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $reader = [IO.StreamReader]::new($archive.GetEntry('Content/score.gpif').Open())
        try { return [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
}
function Concurrent-Titles([string]$left, [string]$right, [string]$value) {
    $requests = @(); $pending = @(); $responses = @()
    try {
        foreach ($pair in @(@{session=$first;document=$left;title="left-$value"},@{session=$second;document=$right;title="right-$value"})) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$pair.session.Url)
            foreach ($key in $pair.session.Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($key,[string]$pair.session.Headers[$key]) }
            $body = @{jsonrpc='2.0';id=($requests.Count+1);method='tools/call';params=@{name='gp_edit_metadata';arguments=@{document=$pair.document;property='Title';value=$pair.title}}} | ConvertTo-Json -Depth 8 -Compress
            $request.Content = [Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8,'application/json')
            $requests += $request
            $pending += $http.SendAsync($request)
        }
        for ($i=0; $i -lt $pending.Count; $i++) {
            $response = $pending[$i].GetAwaiter().GetResult(); $responses += $response
            $result = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            Check ($response.IsSuccessStatusCode -and -not $result.error -and -not $result.result.isError -and $result.id -eq $i+1) 'Concurrent write failed or returned another request.'
        }
        Check ((Invoke-McpTool $second gp_score @{document=$left}).metadata.Title -eq "left-$value") 'First write reached the wrong document.'
        Check ((Invoke-McpTool $first gp_score @{document=$right}).metadata.Title -eq "right-$value") 'Second write reached the wrong document.'
    } finally {
        foreach ($response in $responses) { $response.Dispose() }
        foreach ($request in $requests) { $request.Dispose() }
    }
}
function Sample([string]$phase) {
    $process.Refresh()
    Check (-not $process.HasExited) 'Soak host exited unexpectedly.'
    $sample = @{phase=$phase;utc=[DateTime]::UtcNow.ToString('o');seconds=$clock.Elapsed.TotalSeconds;cycles=$cycles;private_bytes=$process.PrivateMemorySize64;working_set=$process.WorkingSet64;handles=$process.HandleCount;threads=$process.Threads.Count;documents=@((Invoke-McpTool $first gp_documents).documents).Count}
    $script:samples += $sample
    $sample | ConvertTo-Json -Compress | Add-Content -LiteralPath "$run/resources.jsonl" -Encoding UTF8
}
try {
    & "$PackageDirectory/install-plugin.ps1" -InstallDirectory $HostDirectory -PackageDirectory $PackageDirectory -DataDirectory $run | Out-Host
    $saved = @{}
    foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_SESSION_FILE','GPMCP_PORT','GPMCP_DATA_DIR','TEMP','TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
    try {
        foreach ($name in $saved.Keys) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        $env:GPMCP_DATA_DIR = $run; $env:TEMP = $run; $env:TMP = $run
        $process = & "$PackageDirectory/start-installed.ps1" -InstallDirectory $HostDirectory -Background
        $null = $process.Handle
    } finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') } }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path $sessionFile) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $first = New-McpSession -SessionFile $sessionFile
    $second = New-McpSession -SessionFile $sessionFile
    Check ($first.Headers['Mcp-Session-Id'] -ne $second.Headers['Mcp-Session-Id']) 'Expected two independent clients.'
    $loaded = @($process.Modules | Where-Object ModuleName -In @('guitarpro_mcp.dll','guitarpro_mcp_autoload.dll') | ForEach-Object { @{name=$_.ModuleName;path=$_.FileName;sha256=(Get-FileHash $_.FileName).Hash} })
    foreach ($file in $manifest.files) {
        $actual = @($loaded | Where-Object path -EQ (Join-Path $HostDirectory $file.path))
        Check ($actual.Count -eq 1 -and $actual[0].sha256 -eq $file.sha256 -and (Get-FileHash (Join-Path $PackageDirectory $file.path)).Hash -eq $file.sha256) 'Loaded DLL differs from the package.'
    }
    Check (@((Invoke-McpTool $first gp_documents).documents).Count -eq 0) 'Unexpected startup document.'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Sample 'empty'
    foreach ($index in 0..9) {
        $path = Join-Path $run "held-$index.gp"
        Copy-Item "$PSScriptRoot/testdata/minimal.gp" $path
        $held += Open-Score $path
    }
    $large = $held[0]
    foreach ($template in @('Acoustic Piano','Drumkit')) {
        $source = Wait-Operation $first (Invoke-McpTool $first gp_new @{template=$template}).request 'created'
        Invoke-McpTool $first gp_insert_track @{document=$large;source_document=$source;source_track=0} | Out-Null
        Close-Score $source
    }
    foreach ($point in @(@{track=1;staff=0;voice=0;midi=60},@{track=1;staff=1;voice=1;midi=48},@{track=2;staff=0;voice=0;midi=36})) {
        foreach ($axis in @('track','staff','bar','voice')) {
            $index = if ($point.ContainsKey($axis)) { $point[$axis] } else { 0 }
            Invoke-McpTool $first gp_cursor @{document=$large;axis=$axis;index=$index} | Out-Null
        }
        Invoke-McpTool $first gp_edit_note @{document=$large;operation='set';midi=$point.midi} | Out-Null
    }
    $base = @{track=0;staff=0;bar=0;voice=0;beat=0}
    $extent = @{track=0;staff=0;bar=1;voice=0;beat=3}
    Invoke-McpTool $first gp_selection @{document=$large;operation='range';base=$base;extent=$extent;all_tracks=$true} | Out-Null
    $snapshot = Invoke-McpTool $first gp_clipboard @{document=$large;operation='copy'}
    for ($part=0; $part -lt 4; $part++) {
        Invoke-McpTool $first gp_selection @{document=$large;operation='clear'} | Out-Null
        Invoke-McpTool $first gp_cursor @{document=$large;axis='bar';index=0} | Out-Null
        Invoke-McpTool $first gp_clipboard @{document=$large;operation='paste';id=$snapshot.id;repeat=64} | Out-Null
    }
    Invoke-McpTool $first gp_tempo @{document=$large;operation='set';bar=256;value=150;linear=$true} | Out-Null
    Invoke-McpTool $first gp_save_current @{document=$large} | Out-Null
    $xml = Read-Gpif "$run/held-0.gp"
    # GPIF interns identical beats and notes; count their referenced occurrences.
    $voiceMap = @{}; $beatMap = @{}; $beatCount = 0; $noteCount = 0
    foreach ($voice in $xml.SelectNodes('/GPIF/Voices/Voice')) { $voiceMap[$voice.id] = $voice }
    foreach ($beat in $xml.SelectNodes('/GPIF/Beats/Beat')) { $beatMap[$beat.id] = $beat }
    foreach ($bar in $xml.SelectNodes('/GPIF/Bars/Bar')) {
        foreach ($voiceId in ([string]$bar.Voices -split '\s+' | Where-Object { $_ -and $_ -ne '-1' })) {
            foreach ($beatId in ([string]$voiceMap[$voiceId].Beats -split '\s+' | Where-Object { $_ -and $_ -ne '-1' })) {
                Check ($beatMap.ContainsKey($beatId)) 'Saved score has a missing beat reference.'
                $beatCount++
                $noteCount += @([string]$beatMap[$beatId].Notes -split '\s+' | Where-Object { $_ -and $_ -ne '-1' }).Count
            }
        }
    }
    $scale = @{tracks=$xml.SelectNodes('/GPIF/Tracks/Track').Count;master_bars=$xml.SelectNodes('/GPIF/MasterBars/MasterBar').Count;bars=$xml.SelectNodes('/GPIF/Bars/Bar').Count;voices=$xml.SelectNodes('/GPIF/Voices/Voice').Count;beats=$beatCount;notes=$noteCount}
    Check ($scale.tracks -eq 3 -and $scale.master_bars -eq 514 -and $scale.notes -gt 2000) 'Large score did not reach its declared scale.'
    Close-Score $large
    $large = Open-Score "$run/held-0.gp"; $held[0] = $large
    $score = Invoke-McpTool $first gp_score @{document=$large}
    Check ($score.tracks.Count -eq 3 -and $score.tracks[1].staves -eq 2 -and $score.tracks[2].unpitched -and $score.tracks[0].bars -eq 514) 'Large score reopen lost structure.'
    $untouched = @($held | Select-Object -Skip 2 | ForEach-Object { @{id=$_;title=(Invoke-McpTool $first gp_score @{document=$_}).metadata.Title} })
    Sample 'loaded'
    $mixedStart = $clock.Elapsed.TotalSeconds
    do {
        $cycleStart = $clock.Elapsed.TotalSeconds
        $value = [string]($cycles+1)
        Concurrent-Titles $large $held[1] $value
        foreach ($id in @($large,$held[1])) { Invoke-McpTool $first gp_undo_redo @{document=$id;operation='undo'} | Out-Null }
        $path = Join-Path $run "cycle-$value.gp"
        Copy-Item "$PSScriptRoot/testdata/minimal.gp" $path
        $document = Open-Score $path
        Invoke-McpTool $second gp_edit_metadata @{document=$document;property='Title';value="cycle-$value"} | Out-Null
        Invoke-McpTool $first gp_edit_note @{document=$document;operation='set';string=0;fret=7} | Out-Null
        Invoke-McpTool $second gp_save_current @{document=$document} | Out-Null
        $xml = Read-Gpif $path
        Check ($xml.GPIF.Score.Title.InnerText -eq "cycle-$value") 'Saved cycle title differs.'
        Close-Score $document
        Check ((Invoke-McpTool $second gp_edit_metadata @{document=$document;property='Title';value='stale'} -AllowError).error) 'Closed document accepted a stale write.'
        $reopened = Open-Score $path
        $score = Invoke-McpTool $second gp_score @{document=$reopened}
        $bars = Invoke-McpTool $first gp_read_bars @{document=$reopened;bar=0;count=1}
        Check ($score.metadata.Title -eq "cycle-$value" -and -not $score.dirty -and $reopened -ne $document) 'Reopened document identity or title differs.'
        Check (@($bars.bars[0].voices[0].beats[0].notes | Where-Object { $_.string -eq 0 -and $_.fret -eq 7 }).Count -eq 1) 'Saved note did not survive reopen.'
        Close-Score $reopened
        Invoke-McpTool $first gp_activate @{document=$large} | Out-Null
        Invoke-McpTool $first gp_playback @{document=$large;operation='seek';bar=500} | Out-Null
        Invoke-McpTool $first gp_playback @{document=$large;operation='play'} | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(5); $ticks = @()
        do {
            $ticks += (Invoke-McpTool $second gp_playback @{document=$large}).tick
            if (@($ticks | Select-Object -Unique).Count -gt 1) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        Invoke-McpTool $first gp_playback @{document=$large;operation='stop'} | Out-Null
        Check (@($ticks | Select-Object -Unique).Count -gt 1) 'Large score playback did not advance.'
        foreach ($item in $untouched) { Check ((Invoke-McpTool $second gp_score @{document=$item.id}).metadata.Title -eq $item.title) 'An unrelated document changed.' }
        Check (@((Invoke-McpTool $first gp_documents).documents).Count -eq 10) 'Document cycle leaked a document.'
        $cycles++
        if ($cycles % 10 -eq 0) { $second = Reconnect-McpSession $second }
        Sample 'mixed'
        Write-Output ("P7 soak: {0} cycles, {1:N1} mixed minutes, {2} MiB private, {3} handles" -f $cycles,(($clock.Elapsed.TotalSeconds-$mixedStart)/60),[int]($samples[-1].private_bytes/1MB),$samples[-1].handles)
        $next = $cycleStart + 30
        while ($clock.Elapsed.TotalSeconds -lt $next -and $clock.Elapsed.TotalSeconds-$mixedStart -lt $DurationMinutes*60) { Start-Sleep -Milliseconds 1000 }
    } while ($clock.Elapsed.TotalSeconds-$mixedStart -lt $DurationMinutes*60 -or $cycles -lt $MinimumCycles)
    $mixedSeconds = $clock.Elapsed.TotalSeconds-$mixedStart
    foreach ($id in $held) {
        Invoke-McpTool $first gp_save_current @{document=$id} | Out-Null
        Close-Score $id
    }
    Sample 'closed'
    Start-Sleep -Seconds 5
    Sample 'settled'
    Check (@((Invoke-McpTool $first gp_documents).documents).Count -eq 0) 'Final documents were not cleaned up.'
    Close-McpSession $second; $second = $null
    $observed = Invoke-McpTool $first gp_objects @{query='MainWindow';limit=100}
    $main = @($observed.objects | Where-Object class -EQ 'gp::gui::MainWindow')
    try { Invoke-McpTool $first gp_close_window @{snapshot=$observed.snapshot;id=$main[0].id} | Out-Null }
    catch { if (-not $process.WaitForExit(5000)) { throw } }
    Check ($process.WaitForExit(60000)) 'Soak host did not exit normally.'
    $exitCode = $process.ExitCode
    Check ($exitCode -eq 0 -and -not (Test-Path $sessionFile)) 'Soak host exit or descriptor cleanup failed.'
    Check (@(Get-ChildItem $run -Filter 'native-session*.json').Count -eq 0 -and @(Get-ChildItem $run -Filter 'mcp-client-*.json').Count -eq 0) 'Instance files survived normal shutdown.'
    $stale = $false
    try { New-McpSession -SessionFile $sessionFile | Out-Null } catch { $stale = $true }
    Check $stale 'An exited host still accepted a session.'
    $complete = $true
} catch { $failure = $_.Exception.Message; throw }
finally {
    $http.Dispose()
    if ($second) { Close-McpSession $second }
    if ($first) { Close-McpSession $first }
    $evidence = @{complete=$complete;failure=$failure;checks=$checks;cycles=$cycles;mixed_seconds=$mixedSeconds;minimum_cycles=$MinimumCycles;duration_minutes=$DurationMinutes;release_scale=($complete -and $cycles -ge 100 -and $mixedSeconds -ge 3600);started=$started.ToString('o');ended=[DateTime]::UtcNow.ToString('o');scale=$scale;samples=$samples;package=$PackageDirectory;loaded_binaries=$loaded;sources=$sources;host_pid=$(if($process){$process.Id});exit_code=$exitCode;powershell=$PSVersionTable.PSVersion.ToString()}
    $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$run/verification.json" -Encoding UTF8
    if ($process) {
        if (-not $process.HasExited) { Write-Warning "Failed test host retained: PID $($process.Id); $sessionFile" }
        $process.Dispose()
    }
}
Write-Output "PASS: $checks P7 soak checks; $cycles cycles; evidence: $run"
