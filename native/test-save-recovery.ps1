param([Parameter(Mandatory=$true)][string]$Exe)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Exe = (Resolve-Path -LiteralPath $Exe).Path
if (-not $Exe.StartsWith(([IO.Path]::GetFullPath((Join-Path $root '.tools')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Use an isolated host under .tools.' }
. "$PSScriptRoot/mcp-client.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$probe = Join-Path $root '.tools/save-fault-probe/plugins/generic/guitarpro_save_fault_probe.dll'
if (-not (Test-Path -LiteralPath $probe)) { throw 'Build native/build-save-fault-probe.ps1 first.' }
$runId = [guid]::NewGuid().ToString('N')
$run = Join-Path $root ('artifacts/save-recovery-' + $runId)
$sessionFile = Join-Path $run 'session/native-session.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $sessionFile) | Out-Null
'gpmcp-save-fault-test' | Set-Content -LiteralPath (Join-Path $run 'isolated-save-fault-test') -Encoding ASCII
$fixture = Join-Path $PSScriptRoot 'testdata/minimal.gp'
$fixtureHash = (Get-FileHash -LiteralPath $fixture).Hash
$targetName = 'gpmcp-save-recovery-' + $runId + '.gp'
$target = Join-Path $run $targetName
$targetName | Set-Content -LiteralPath (Join-Path $run 'target-name') -Encoding ASCII
$backupTarget = Join-Path $env:APPDATA ('Arobas Music/guitarpro8/backups/' + $targetName)
if (Test-Path -LiteralPath $backupTarget) { throw 'The unique native backup target already exists.' }
$control = Join-Path $run 'control.json'
$checks = 0; $passed = $false; $observations = @(); $connection = $null; $process = $null
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Set-Fault([string]$mode = '', [int]$writer = 1) {
    $request = [guid]::NewGuid().ToString()
    @{request=$request;mode=$mode;writer=$writer} | ConvertTo-Json -Compress | Set-Content -LiteralPath $control -Encoding ASCII
    return $request
}
function Wait-Operation([string]$request, [string]$expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if ($state.status -in @('opened','closed','created','error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($state.status -eq $expected) "Unexpected operation: $($state | ConvertTo-Json -Depth 8 -Compress)"
    return $state
}
function Title([string]$path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$xml = $reader.ReadToEnd(); $xml.GPIF.Score.Title.InnerText } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}
$saved = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_DATA_DIR','GPMCP_SESSION_FILE','GPMCP_BACKGROUND','GPMCP_SAVE_FAULT_DIRECTORY','TEMP','TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
try {
    Set-Fault | Out-Null
    try {
        $env:QT_PLUGIN_PATH = (Join-Path $root '.tools/native/plugins') + ';' + (Join-Path $root '.tools/save-fault-probe/plugins')
        $env:QT_QPA_GENERIC_PLUGINS = 'guitarpro_mcp,guitarpro_save_fault_probe'
        $env:GPMCP_DATA_DIR = Split-Path -Parent $sessionFile
        $env:GPMCP_SESSION_FILE = $sessionFile
        $env:GPMCP_SAVE_FAULT_DIRECTORY = $run
        $env:GPMCP_BACKGROUND = '1'
        $env:TEMP = $run; $env:TMP = $run
        $process = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $run 'host.stderr.log')
        $null = $process.Handle
    } finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') } }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if (Test-Path -LiteralPath $sessionFile) { break }
        if ($process.HasExited) { throw 'Fault-test host exited before connecting.' }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $connection = New-McpSession -SessionFile $sessionFile
    Assert ([bool](Get-Content -LiteralPath (Join-Path $run 'probe.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -EQ 'ready')) 'Fault probe did not load.'
    $cases = @(
        @{name='copy-existing';tool='gp_save';mode='write';writer=1;existing=$true},
        @{name='as-existing';tool='gp_save_as';mode='write';writer=1;existing=$true},
        @{name='current-write';tool='gp_save_current';mode='write';writer=2;existing=$true},
        @{name='as-new';tool='gp_save_as';mode='write';writer=1;existing=$false},
        @{name='as-native-invalid';tool='gp_save_as';mode='corrupt';writer=2;existing=$true},
        @{name='as-invalid';tool='gp_save_as';mode='post_validate';writer=2;existing=$true},
        @{name='current-invalid';tool='gp_save_current';mode='post_validate';writer=2;existing=$true},
        @{name='save-close';tool='gp_close';mode='write';writer=2;existing=$true},
        @{name='recovery-locked';tool='gp_save_as';mode='recovery';writer=1;existing=$true}
    )
    foreach ($case in $cases) {
        Set-Fault | Out-Null
        Start-Sleep -Milliseconds 100
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
        if ($case.existing) { Copy-Item -LiteralPath $fixture -Destination $target }
        $source = if ($case.tool -eq 'gp_save_current') { $target } else { Join-Path $run ($case.name + '-source.gp') }
        if ($source -ne $target) { Copy-Item -LiteralPath $fixture -Destination $source }
        $open = Invoke-McpTool $connection gp_open @{path=$source}
        $id = (Wait-Operation $open.request 'opened').document
        $title = 'Unsaved recovery check: ' + $case.name
        Invoke-McpTool $connection gp_edit_metadata @{document=$id;property='Title';value=$title} | Out-Null
        $request = Set-Fault $case.mode $case.writer
        $arguments = @{document=$id}
        if ($case.tool -ne 'gp_save_current') { $arguments.path = $target; $arguments.overwrite = [bool]$case.existing }
        if ($case.tool -eq 'gp_close') { $arguments.unsaved = 'save' }
        $scheduled = Invoke-McpTool $connection $case.tool $arguments -NoWait
        Assert ($scheduled.status -eq 'scheduled' -and $scheduled.request) 'Save did not return a tracked request.'
        $deadline = [DateTime]::UtcNow.AddSeconds(12)
        $cancelled = $false
        do {
            $state = (Invoke-McpTool $connection gp_operation @{request=$scheduled.request}).operation
            if ($state.status -in @('saved','error','cancelled','closed')) { break }
            $dialog = Invoke-McpTool $connection gp_dialogs
            if ($dialog.blocked -and -not $cancelled) {
                $observations += @{case=$case.name;dialog=$dialog}
                Assert ((Invoke-McpTool $connection gp_edit_metadata @{document=$id;property='Artist';value='Must not apply'} -AllowError).error) 'Pending save permitted another mutation.'
                $cancel = Invoke-McpTool $connection gp_cancel @{request=$scheduled.request}
                Assert ($cancel.status -eq 'cancelling') 'Native save dialog did not accept cancellation.'
                $cancelled = $true
            }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        $failed = if ($case.tool -eq 'gp_close') { $state.save } else { $state.result }
        $events = @(Get-Content -LiteralPath (Join-Path $run 'probe.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object request -EQ $request)
        $observations += @{case=$case;request=$request;operation=$state;result=$failed;probe=$events}
        Assert ([bool]$failed.error) "$($case.name): native save unexpectedly succeeded."
        if ($case.mode -in @('corrupt','post_validate')) {
            Assert (@($events | Where-Object { $_.event -eq 'output_corrupted' -and $_.writer -eq $case.writer -and $_.corrupted -and $_.bytes_before -gt 4 -and $_.bytes_after -eq $_.bytes_before }).Count -eq 1) 'Equal-size output corruption did not occur in the selected native write.'
            if ($case.mode -eq 'post_validate') {
                Assert ([bool]($events | Where-Object native_clean_observed)) 'Native clean state was not observed before output corruption.'
                Assert ($failed.error -like 'Native output validation failed*') 'Corrupt native output did not reach post-save validation.'
            } else { Assert ($failed.error -like 'Native document save did not complete*') 'Host did not reject corrupted native output.' }
        } else {
            Assert (@($events | Where-Object { $_.event -eq 'write_failed' -and $_.writer -eq $case.writer -and $_.bytes_written -gt 0 }).Count -eq 1) 'No partial native write was observed before failure.'
        }
        Assert ($failed.save_path_restored -and $failed.opened_path_restored -and $failed.dirty_state_restored -and $failed.dirty) 'Failed save did not restore paths and unsaved state.'
        $document = (Invoke-McpTool $connection gp_documents).documents | Where-Object id -EQ $id
        Assert ([IO.Path]::GetFullPath($document.save_path) -eq $source -and [IO.Path]::GetFullPath($document.opened_path) -eq $source -and $document.dirty) 'Document readback differs from recovery result.'
        Assert ((Invoke-McpTool $connection gp_score @{document=$id}).metadata.Title -eq $title) 'Failure changed unsaved score content.'
        if ($case.mode -eq 'recovery') {
            Assert (-not $failed.file_restored -and [bool]$failed.recovery_path) 'Locked recovery falsely reported restoration or lost backup location.'
            Assert ((Get-FileHash -LiteralPath $failed.recovery_path).Hash -eq $fixtureHash) 'Recovery backup differs from original file.'
        } elseif ($case.existing) {
            Assert ($failed.file_restored -and (Get-FileHash -LiteralPath $target).Hash -eq $fixtureHash) 'Recovery did not restore exact original bytes.'
        } else {
            Assert ($failed.file_restored -and -not (Test-Path -LiteralPath $target)) 'Failed new output was retained.'
        }
        if ($source -ne $target) { Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Failed Save As changed the original source file.' }
        Set-Fault | Out-Null
        Start-Sleep -Milliseconds 100
        Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'} | Out-Null
        Assert ((Invoke-McpTool $connection gp_score @{document=$id}).metadata.Title -ne $title) 'Recovery broke undo history.'
        Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
        $redone = Invoke-McpTool $connection gp_score @{document=$id}
        Assert ($redone.metadata.Title -eq $title -and $redone.dirty) 'Redo after failed save lost content or falsely reported saved state.'
        $retryPath = Join-Path $run ($case.name + '-retry.gp')
        $retry = Invoke-McpTool $connection gp_save_as @{document=$id;path=$retryPath}
        Assert (-not $retry.dirty -and (Title $retryPath) -eq $title) 'Save after recovery did not persist unsaved work.'
        $close = Invoke-McpTool $connection gp_close @{document=$id}
        Wait-Operation $close.request 'closed' | Out-Null
        $open = Invoke-McpTool $connection gp_open @{path=$retryPath}
        $reopened = (Wait-Operation $open.request 'opened').document
        Assert ((Invoke-McpTool $connection gp_score @{document=$reopened}).metadata.Title -eq $title) 'Recovered score did not reopen correctly.'
        $close = Invoke-McpTool $connection gp_close @{document=$reopened}
        Wait-Operation $close.request 'closed' | Out-Null
    }
    Assert ((Invoke-McpTool $connection gp_documents).documents.Count -eq 0) 'Recovery suite retained a document.'
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.hidden_mode -and $identity.foreground_pid -ne $identity.pid) 'Save failures took foreground focus.'
    $w = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    $main = @($w.objects | Where-Object class -EQ 'gp::gui::MainWindow')
    try { Invoke-McpTool $connection gp_close_window @{snapshot=$w.snapshot;id=$main[0].id} | Out-Null }
    catch { if (-not $process.WaitForExit(5000)) { throw } }
    Assert ($process.WaitForExit(15000) -and $process.ExitCode -eq 0) 'Recovery host did not exit cleanly.'
    Assert (-not (Test-Path -LiteralPath $sessionFile)) 'Recovery host retained its descriptor.'
    $passed = $true
} finally {
    Set-Fault | Out-Null
    if ($connection -and $process -and -not $process.HasExited) { Close-McpSession $connection }
    @{passed=$passed;checks=$checks;observations=$observations;host_pid=$(if($process){$process.Id});session_file=$sessionFile;exit_code=$(if($process -and $process.HasExited){$process.ExitCode});powershell=$PSVersionTable.PSVersion.ToString();native_partial_write_recovery_verified=$passed;post_save_validation_recovery_verified=$passed;retained_backup_verified=$passed;save_error_dialog_control_verified=$passed;native_save_progress_cancellation_verified=$false;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash;probe_sha256=(Get-FileHash $probe).Hash} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    if ($process) {
        if (-not $process.HasExited) { Write-Warning "Recovery host retained: PID $($process.Id), session $sessionFile" }
        $process.Dispose()
    }
}
Write-Output "PASS: $checks partial native write, invalid output, failed recovery, undo and reopen checks. Evidence: $run"
