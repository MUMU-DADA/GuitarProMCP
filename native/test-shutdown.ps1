param([Parameter(Mandatory=$true)][string]$HostDirectory, [string]$StackProbe = '', [string]$PackageDirectory = '', [ValidateRange(0,30000)][int]$StartupSettleMs = 0)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$HostDirectory = [IO.Path]::GetFullPath($HostDirectory)
if (-not $HostDirectory.StartsWith(([IO.Path]::GetFullPath((Join-Path $root '.tools')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Use an isolated host copy under .tools.' }
if ($PackageDirectory) { . "$PackageDirectory/mcp-client.ps1" }
else { . "$PSScriptRoot/mcp-client.ps1" }
$run = Join-Path $root ('artifacts/shutdown-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$exe = Join-Path $HostDirectory 'GuitarPro.exe'
$saved = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_SESSION_FILE','GPMCP_DATA_DIR','GPMCP_BACKGROUND','GPMCP_PORT','TEMP','TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
$results = @()
$process = $null
$installer = if ($PackageDirectory) { "$PackageDirectory/install-plugin.ps1" } else { "$root/install-plugin.ps1" }
& $installer -InstallDirectory $HostDirectory -PackageDirectory $PackageDirectory | Out-Null
try {
    foreach ($startup in @('background','visible')) {
    foreach ($mode in @('generic','autoload')) {
        foreach ($quit in @('window','action')) {
            $data = Join-Path $run "$startup-$mode-$quit"
            New-Item -ItemType Directory -Path $data | Out-Null
            $sessionFile = Join-Path $data 'native-session.json'
            foreach ($name in $saved.Keys) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            $env:GPMCP_BACKGROUND = if ($startup -eq 'background') { '1' } else { '0' }
            $env:GPMCP_DATA_DIR = $data
            $env:TEMP = $data; $env:TMP = $data
            if ($mode -eq 'generic') {
                $process = & "$root/start-plugin.ps1" -Exe $exe -ScorePath "$PSScriptRoot/testdata/minimal.gp" -SessionFile $sessionFile -PassThru -Visible:($startup -eq 'visible')
            } else {
                $process = Start-Process -FilePath $exe -ArgumentList @('--open',('"' + "$PSScriptRoot/testdata/minimal.gp" + '"')) -WorkingDirectory $HostDirectory -WindowStyle Hidden -PassThru
                $null = $process.Handle
                $deadline = [DateTime]::UtcNow.AddSeconds(20)
                while (-not (Test-Path -LiteralPath $sessionFile) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            }
            $connection = New-McpSession -SessionFile $sessionFile
            try {
                $deadline = [DateTime]::UtcNow.AddSeconds(15)
                do {
                    $documents = Invoke-McpTool $connection gp_documents
                    if ($documents.documents.Count -eq 1) { break }
                    Start-Sleep -Milliseconds 100
                } while ([DateTime]::UtcNow -lt $deadline)
                if ($documents.documents.Count -ne 1 -or $documents.documents[0].dirty) { throw 'Expected one clean fixture.' }
                if ($StartupSettleMs) { Start-Sleep -Milliseconds $StartupSettleMs }
                Invoke-McpTool $connection gp_selection @{operation='range';base=@{track=0;staff=0;bar=0;voice=0;beat=0};extent=@{track=0;staff=0;bar=0;voice=0;beat=1}} | Out-Null
                $copy = Invoke-McpTool $connection gp_clipboard @{operation='copy'}
                if (-not $copy.available) { throw 'No native snapshot was retained for the shutdown test.' }
                if ($quit -eq 'window') {
                    $observed = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
                    $target = @($observed.objects | Where-Object class -EQ 'gp::gui::MainWindow')[0]
                    try { Invoke-McpTool $connection gp_close_window @{snapshot=$observed.snapshot;id=$target.id} | Out-Null }
                    catch { if (-not $process.WaitForExit(5000)) { throw } }
                } else {
                    $observed = Invoke-McpTool $connection gp_actions @{query='actionQuit';include_hidden=$true}
                    try { Invoke-McpTool $connection gp_trigger @{snapshot=$observed.snapshot;id=$observed.objects[0].id} | Out-Null }
                    catch { if (-not $process.WaitForExit(5000)) { throw } }
                }
                $exitTimer = [Diagnostics.Stopwatch]::StartNew()
                $exited = $process.WaitForExit(15000)
                if (-not $exited -and $StackProbe) {
                    $process.Refresh()
                    & $StackProbe $process.Id $process.Threads[0].Id | Tee-Object -FilePath (Join-Path $data 'blocked-thread.txt')
                }
                if (-not $exited) { $exited = $process.WaitForExit(45000) }
                $results += [pscustomobject]@{startup=$startup;mode=$mode;quit=$quit;pid=$process.Id;exited=$exited;exit_ms=$exitTimer.ElapsedMilliseconds;exit_code=$(if($exited){$process.ExitCode}else{$null});descriptor_removed=(-not(Test-Path -LiteralPath $sessionFile))}
                if (-not $exited -or $process.ExitCode -ne 0 -or (Test-Path -LiteralPath $sessionFile)) { throw "Unclean shutdown: $startup / $mode / $quit" }
            } finally { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }; $process.Dispose(); $process = $null }
        }
    }
    }
} finally {
    if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }; $process.Dispose() }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    & $installer -Action Uninstall -InstallDirectory $HostDirectory | Out-Null
    @{results=$results;startup_settle_ms=$StartupSettleMs;powershell_version=$PSVersionTable.PSVersion.ToString();package=$PackageDirectory;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash;autoload_sha256=(Get-FileHash "$root/.tools/native/plugins/imageformats/guitarpro_mcp_autoload.dll").Hash} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
}
Write-Output "PASS: eight native-snapshot shutdown paths, zero exit codes and descriptor cleanup. Evidence: $run"
