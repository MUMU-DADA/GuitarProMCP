param(
    [string]$InstallDirectory = 'C:\Program Files\Arobas Music\Guitar Pro 8',
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [ValidateSet('direct','shortcut','association','background')][string[]]$Variants = @('direct','shortcut','association','background'),
    [ValidateRange(0,60000)][int]$StartupSettleMs = 5000,
    [string]$RunDirectory = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$InstallDirectory = (Resolve-Path -LiteralPath $InstallDirectory).Path
$PackageDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
. "$PackageDirectory/mcp-client.ps1"
$exe = Join-Path $InstallDirectory 'GuitarPro.exe'
if (@(Get-Process -Name GuitarPro -ErrorAction SilentlyContinue).Count) { throw 'Close all Guitar Pro hosts before installed entrypoint tests.' }
$run = if ($RunDirectory) { [IO.Path]::GetFullPath($RunDirectory) } else { Join-Path $root ('artifacts/installed-entrypoints-' + [guid]::NewGuid().ToString('N')) }
if (-not $run.StartsWith(([IO.Path]::GetFullPath((Join-Path $root 'artifacts')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must be under project artifacts.' }
New-Item -ItemType Directory -Path $run | Out-Null
$score = Join-Path $run ('entrypoint ' + [char]0x66f2 + [char]0x8c31 + '.gp')
$secondScore = Join-Path $run 'second score.gp'
Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $score
Copy-Item -LiteralPath $score -Destination $secondScore
$manifest = Get-Content -LiteralPath "$PackageDirectory/package.json" -Raw | ConvertFrom-Json
$data = Join-Path $env:LOCALAPPDATA 'GuitarProMCP'
$descriptor = Join-Path $data 'native-session.json'
$checks = 0
$observations = @()
$passed = $false
$failure = $null
$original = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS') + @(Get-ChildItem Env: | Where-Object Name -Like 'GPMCP_*' | ForEach-Object Name)) { $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Assert($condition,[string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Read-Documents($connection,[string]$expectedPath = '') {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $documents = Invoke-McpTool $connection gp_documents
        if (-not $expectedPath -or @($documents.documents | Where-Object { $_.opened_path -eq $expectedPath.Replace('\','/') -and $_.native_score_available }).Count -eq 1) { return $documents }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The shell did not open the expected score: $expectedPath"
}
$process = $null
try {
    foreach ($name in $original.Keys) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    $receipt = Get-Content -LiteralPath "$InstallDirectory/Plugins/guitarpro-mcp-install.json" -Raw | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        Assert ((Get-FileHash -LiteralPath (Join-Path $InstallDirectory $file.path)).Hash -eq $file.sha256) 'Installed binary differs from the candidate package.'
        Assert (@($receipt.files | Where-Object { $_.path -eq $file.path -and $_.sha256 -eq $file.sha256 }).Count -eq 1) 'Installation receipt does not match the candidate.'
    }
    $shortcutPath = $null
    if ('shortcut' -in $Variants) {
        $locations = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs","$env:APPDATA\Microsoft\Windows\Start Menu\Programs",[Environment]::GetFolderPath('Desktop'),"$env:PUBLIC\Desktop")
        $shell = New-Object -ComObject WScript.Shell
        foreach ($file in @(Get-ChildItem -LiteralPath $locations -Filter '*Guitar*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
            if ($shell.CreateShortcut($file.FullName).TargetPath -eq $exe) { $shortcutPath = $file.FullName; break }
        }
        Assert ([bool]$shortcutPath) 'No existing Guitar Pro shortcut was found.'
    }
    $tokenHash = if (Test-Path -LiteralPath "$data/mcp-auth-token") { (Get-FileHash -LiteralPath "$data/mcp-auth-token").Hash } else { $null }
    foreach ($variant in $Variants) {
        Write-Output "Checking installed entrypoint: $variant"
        $background = $variant -eq 'background'
        $path = switch ($variant) { 'direct' { $exe }; 'shortcut' { $shortcutPath }; 'association' { $score }; 'background' { "$PackageDirectory/start-installed.ps1" } }
        if ($background) { $process = & $path -InstallDirectory $InstallDirectory -Background -ScorePath $score }
        else { $process = Start-Process -FilePath $path -WorkingDirectory $InstallDirectory -WindowStyle Normal -PassThru }
        # ShellExecute may return a launcher (or no process) for shortcuts and associations.
        # Bind the descriptor to the sole installed host; never trust the launcher PID.
        if ($process) { $process.Dispose(); $process = $null }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        $session = $null
        $ready = $false
        do {
            Start-Sleep -Milliseconds 100
            if (Test-Path -LiteralPath $descriptor) {
                try { $session = Get-Content -LiteralPath $descriptor -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $session = $null }
            }
            $hosts = @(Get-Process -Name GuitarPro -ErrorAction SilentlyContinue | Where-Object Path -EQ $exe)
            if ($hosts.Count -eq 1 -and $session.pid -eq $hosts[0].Id) { $process = $hosts[0]; $ready = $true; break }
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $process -and $hosts.Count -eq 1) { $process = $hosts[0] }
        Assert $ready "Installed $variant startup did not publish its MCP endpoint."
        $null = $process.Handle
        $connection = New-McpSession -SessionFile $descriptor
        try {
            $identity = Invoke-McpTool $connection gp_capabilities
            $observation = [ordered]@{variant=$variant;pid=$process.Id;path=$path;identity=$identity;documents=$null;exit_code=$null;descriptor_removed=$false}
            $observations += $observation
            Assert ($identity.pid -eq $process.Id -and $identity.native_score_abi_verified -and $identity.hidden_mode -eq $background) "Installed $variant startup has the wrong identity or visibility mode."
            $expectedPath = if ($variant -in @('association','background')) { $score } else { '' }
            $documents = Read-Documents $connection $expectedPath
            $observation.documents = $documents
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                $windows = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
                $main = @($windows.objects | Where-Object class -EQ 'gp::gui::MainWindow')
                if ($main.Count -eq 1 -and $main[0].visible -eq (-not $background)) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert ($main.Count -eq 1 -and $main[0].visible -eq (-not $background)) "Installed $variant window did not reach the requested visibility."
            if ($background) { Assert ($identity.foreground_pid -ne $process.Id) 'Background launch took foreground focus.' }
            $loadedModules = @($process.Modules | ForEach-Object FileName)
            foreach ($file in $manifest.files) { Assert ([IO.Path]::GetFullPath((Join-Path $InstallDirectory $file.path)) -in $loadedModules) 'Host loaded a plugin from the wrong directory.' }
            $status = Get-Content -LiteralPath "$data/status.json" -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert ($status.status -eq 'running') 'Installed service did not report running.'
            $client = Get-Content -LiteralPath "$data/mcp-client.json" -Raw -Encoding UTF8 | ConvertFrom-Json
            $server = @($client.mcpServers.PSObject.Properties)[0].Value
            Assert ($server.url -eq $connection.Url -and $server.headers.'GuitarProMCP-Instance-Id' -eq $connection.InstanceId) 'Client configuration is not bound to this instance.'
            if ($variant -eq 'association') {
                $first = @($documents.documents | Where-Object opened_path -EQ $score.Replace('\','/'))[0]
                # Exercise the Windows shell association, including registered DDE, without a helper.
                Start-Process -FilePath $secondScore -WorkingDirectory $InstallDirectory -WindowStyle Normal
                $documents = Read-Documents $connection $secondScore
                Assert (@($documents.documents | Where-Object id -EQ $first.id).Count -eq 1) 'Association forwarding replaced the original document.'
                Assert (@(Get-Process GuitarPro -ErrorAction SilentlyContinue | Where-Object Path -EQ $exe).Count -eq 1) 'Association forwarding created another installed host.'
                $second = @($documents.documents | Where-Object opened_path -EQ $secondScore.Replace('\','/'))[0]
                Start-Process -FilePath $secondScore -WorkingDirectory $InstallDirectory -WindowStyle Normal
                Start-Sleep -Seconds 1
                $documents = Read-Documents $connection $secondScore
                Assert (@($documents.documents | Where-Object id -EQ $second.id).Count -eq 1 -and $documents.documents.Count -eq 2) 'Repeated shell opening duplicated a document.'
                $observation.documents = $documents
            }
            if ($expectedPath) {
                # Shell activation is asynchronous; read each loaded document by stable ID.
                foreach ($document in $documents.documents) {
                    $bars = Invoke-McpTool $connection gp_read_bars @{document=$document.id;count=1}
                    Assert ($bars.bars[0].voices[0].beats[0].notes[0].midi -eq 40) 'Installed plugin could not read the fixture score.'
                }
            }
            Assert (-not @($documents.documents | Where-Object dirty).Count) 'A document has unsaved edits; host retained.'
            Assert (-not (Invoke-McpTool $connection gp_dialogs).blocked) 'Host has a modal dialog; retained for inspection.'
            $rejected = $false
            try { & "$PackageDirectory/install-plugin.ps1" -Action Update -InstallDirectory $InstallDirectory | Out-Null }
            catch { $rejected = $_.Exception.Message -like 'Close this Guitar Pro*' }
            Assert $rejected 'Updating the running installed host was not rejected.'
            if ($tokenHash) { Assert ((Get-FileHash -LiteralPath "$data/mcp-auth-token").Hash -eq $tokenHash) 'Restart changed the persistent token.' }
            else { $tokenHash = (Get-FileHash -LiteralPath "$data/mcp-auth-token").Hash }
            # Ordinary startup/exit, not the separately documented rapid-exit stress case.
            $settle = $StartupSettleMs - ([DateTime]::Now - $process.StartTime).TotalMilliseconds
            if ($settle -gt 0) { Start-Sleep -Milliseconds ([int]$settle) }
            $actions = Invoke-McpTool $connection gp_actions @{query='actionQuit';include_hidden=$true}
            Assert ($actions.objects.Count -eq 1 -and $actions.objects[0].enabled) 'The ordinary host Quit action is unavailable.'
            try { Invoke-McpTool $connection gp_trigger @{snapshot=$actions.snapshot;id=$actions.objects[0].id} | Out-Null }
            catch { if (-not $process.WaitForExit(5000)) { throw } }
            $exited = $process.WaitForExit(45000)
            if ($exited) { $observation.exit_code = $process.ExitCode }
            $observation.descriptor_removed = -not (Test-Path -LiteralPath $descriptor) -and -not (Test-Path -LiteralPath $session.session_file) -and -not (Test-Path -LiteralPath (Join-Path $data ('mcp-client-' + $connection.InstanceId + '.json')))
            Assert ($exited -and $process.ExitCode -eq 0) "Installed $variant host did not exit cleanly."
            Assert $observation.descriptor_removed 'Normal exit did not clean up instance discovery files.'
        } finally { if (-not $process.HasExited) { Close-McpSession $connection } }
        $process.Dispose(); $process = $null
    }
    $passed = $true
} catch { $failure = $_.Exception.Message; throw }
finally {
    foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
    @{passed=$passed;failure=$failure;checks=$checks;host=$exe;host_sha256=(Get-FileHash -LiteralPath $exe).Hash;package=$PackageDirectory;files=$manifest.files;test_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;powershell=$PSVersionTable.PSVersion.ToString();startup_settle_ms=$StartupSettleMs;observations=$observations} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    if ($process) { Write-Warning "Test host retained for inspection: PID $($process.Id)"; $process.Dispose() }
}
Write-Output "PASS: $checks installed entrypoint and clean-exit checks. Evidence: $run"
