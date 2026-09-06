param([string]$InstallDirectory = 'C:\Program Files\Arobas Music\Guitar Pro 8')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $InstallDirectory 'GuitarPro.exe'
if (@(Get-Process -Name GuitarPro -ErrorAction SilentlyContinue | Where-Object Path -EQ $exe).Count) { throw 'Close the installed host before entrypoint tests.' }
$run = Join-Path $root ('artifacts/installed-entrypoints-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$score = Join-Path $run 'entrypoint.gp'
Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $score
$locations = @('C:\ProgramData\Microsoft\Windows\Start Menu\Programs',"$env:APPDATA\Microsoft\Windows\Start Menu\Programs",[Environment]::GetFolderPath('Desktop'),'C:\Users\Public\Desktop')
$shell = New-Object -ComObject WScript.Shell
$shortcutPath = $null
foreach ($file in @(Get-ChildItem -LiteralPath $locations -Filter '*Guitar*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
    if ($shell.CreateShortcut($file.FullName).TargetPath -eq $exe) { $shortcutPath = $file.FullName; break }
}
if (-not $shortcutPath) { throw 'No existing Guitar Pro shortcut was found.' }
$descriptor = Join-Path $env:LOCALAPPDATA 'GuitarProMCP/native-session.json'
$checks = 0
$observations = @()
$original = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_SESSION_FILE','GPMCP_DATA_DIR','GPMCP_BACKGROUND','GPMCP_PORT')) { $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Assert($condition,[string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
$process = $null
try {
    foreach ($name in $original.Keys) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    foreach ($variant in @('direct','shortcut','association')) {
        $path = switch ($variant) { 'direct' { $exe }; 'shortcut' { $shortcutPath }; 'association' { $score } }
        $process = Start-Process -FilePath $path -WorkingDirectory $InstallDirectory -WindowStyle Hidden -PassThru
        $null = $process.Handle
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        do {
            Start-Sleep -Milliseconds 100
            $session = if (Test-Path -LiteralPath $descriptor) { Get-Content -LiteralPath $descriptor -Raw | ConvertFrom-Json } else { $null }
            $process.Refresh()
        } while (-not $process.HasExited -and $session.pid -ne $process.Id -and [DateTime]::UtcNow -lt $deadline)
        Assert (-not $process.HasExited -and $session.pid -eq $process.Id) "Installed $variant startup did not publish its MCP endpoint."
        $connection = New-McpSession -SessionFile $descriptor
        try {
            $identity = Invoke-McpTool $connection gp_capabilities
            Assert ($identity.native_score_abi_verified -and -not $identity.hidden_mode) "Installed $variant startup is not a visible verified host."
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                $windows = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
                $main = @($windows.objects | Where-Object class -EQ 'gp::gui::MainWindow')
                $documents = Invoke-McpTool $connection gp_documents
                $loaded = $variant -ne 'association' -or @($documents.documents | Where-Object opened_path -EQ $score.Replace('\','/')).Count -eq 1
                if ($main.Count -eq 1 -and $main[0].visible -and $loaded) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert ($main.Count -eq 1 -and $main[0].visible -and $loaded) "Installed $variant window or score did not become ready."
            Assert (-not @($documents.documents | Where-Object dirty).Count) 'A document has unsaved edits; leave this host open.'
            $modal = Invoke-McpTool $connection gp_dialogs
            if ($modal.blocked) { throw ('Resolve the host dialog before entrypoint verification: ' + ($modal | ConvertTo-Json -Depth 6 -Compress)) }
            $observations += [pscustomobject]@{variant=$variant;pid=$process.Id;path=$path;identity=$identity;documents=$documents}
            $actions = Invoke-McpTool $connection gp_actions @{query='actionQuit';include_hidden=$true}
            if ($actions.objects.Count -ne 1 -or -not $actions.objects[0].enabled) { throw 'The ordinary host Quit action is unavailable.' }
            try { Invoke-McpTool $connection gp_trigger @{snapshot=$actions.snapshot;id=$actions.objects[0].id} | Out-Null }
            catch { if (-not $process.WaitForExit(5000)) { throw } }
            Assert ($process.WaitForExit(60000) -and $process.ExitCode -eq 0) "Installed $variant host did not exit cleanly."
            Assert (-not (Test-Path -LiteralPath $descriptor)) 'Normal exit did not remove the session descriptor.'
        } finally { if (-not $process.HasExited) { Close-McpSession $connection } }
        $process.Dispose(); $process = $null
    }
} finally {
    foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
    @{checks=$checks;host=$exe;observations=$observations} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    if ($process) { Write-Warning "Test host retained for inspection: PID $($process.Id)"; $process.Dispose() }
}
Write-Output "PASS: $checks installed entrypoint and clean-exit checks. Evidence: $run"
