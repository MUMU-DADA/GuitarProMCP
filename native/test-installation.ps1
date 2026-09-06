param([Parameter(Mandatory=$true)][string]$HostDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$HostDirectory = [IO.Path]::GetFullPath($HostDirectory)
if (-not $HostDirectory.StartsWith(([IO.Path]::GetFullPath((Join-Path $root '.tools')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'This test requires an isolated host copy under the project .tools directory.' }
. "$PSScriptRoot/mcp-client.ps1"
$run = Join-Path $root ('artifacts/installation-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $run 'data'
New-Item -ItemType Directory -Path $run,$data | Out-Null
$descriptorPath = Join-Path $data 'native-session.json'
$statusPath = Join-Path $data 'status.json'
$settingsPath = Join-Path $data 'settings.json'
$exe = Join-Path $HostDirectory 'GuitarPro.exe'
$hashBefore = (Get-FileHash -LiteralPath $exe).Hash
$checks = 0
$observations = @()
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Install([string]$action) { & "$root/install-plugin.ps1" -Action $action -InstallDirectory $HostDirectory -DataDirectory $data }
function Launch([string]$variant, [bool]$background = $false, [bool]$openScore = $false) {
    if (Test-Path -LiteralPath $descriptorPath) { Remove-Item -LiteralPath $descriptorPath }
    if (Test-Path -LiteralPath $statusPath) { Remove-Item -LiteralPath $statusPath }
    $env:GPMCP_BACKGROUND = if ($background) { '1' } else { '0' }
    $launch = @{FilePath=$exe;WorkingDirectory=$HostDirectory;WindowStyle='Hidden';PassThru=$true;RedirectStandardError=(Join-Path $run "$variant.stderr.log")}
    if ($openScore) { $launch.ArgumentList = @('--open', ('"' + "$PSScriptRoot/testdata/minimal.gp" + '"')) }
    $process = Start-Process @launch
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    } while (-not $process.HasExited -and -not (Test-Path -LiteralPath $statusPath) -and [DateTime]::UtcNow -lt $deadline)
    $status = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json } else { $null }
    $script:observations += [pscustomobject]@{variant=$variant;pid=$process.Id;status=$status}
    return $process
}
function Stop-Owned($process) {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit(5000) | Out-Null }
    if ($process) { $process.Dispose() }
}
$original = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_SESSION_FILE','GPMCP_DATA_DIR','GPMCP_BACKGROUND','GPMCP_PORT','TEMP','TMP')) { $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$process = $null
try {
    Remove-Item Env:QT_PLUGIN_PATH,Env:QT_QPA_GENERIC_PLUGINS,Env:GPMCP_SESSION_FILE -ErrorAction SilentlyContinue
    $env:GPMCP_PORT = ''
    $env:GPMCP_DATA_DIR = $data
    $env:TEMP = $run
    $env:TMP = $run
    Install Install | Out-Null
    Assert ((Install Status).installed) 'Installation receipt is missing.'
    Install Update | Out-Null
    Assert ((Install Status).installed) 'Idempotent update failed.'
    $receiptPath = Join-Path $HostDirectory 'Plugins/guitarpro-mcp-install.json'
    $receiptHash = (Get-FileHash -LiteralPath $receiptPath).Hash
    $receiptLock = [IO.File]::Open($receiptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $rejected = $false
        try { Install Update | Out-Null } catch { $rejected = $true }
        Assert $rejected 'Locked receipt did not fail the update.'
    } finally { $receiptLock.Dispose() }
    Assert ((Get-FileHash -LiteralPath $receiptPath).Hash -eq $receiptHash) 'Failed update modified the receipt.'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    foreach ($file in $receipt.files) { Assert ((Get-FileHash -LiteralPath (Join-Path $HostDirectory $file.path)).Hash -eq $file.sha256) 'Failed update did not restore a plugin binary.' }
    $process = Launch 'visible' $false $true
    Assert (-not $process.HasExited -and (Test-Path -LiteralPath $descriptorPath)) 'Automatic MCP startup failed.'
    $connection = New-McpSession -SessionFile $descriptorPath
    try {
        $identity = Invoke-McpTool $connection gp_capabilities
        Assert ($identity.pid -eq $process.Id -and $identity.native_score_abi_verified) 'Wrong host identity or private ABI unavailable.'
        Assert (-not $identity.hidden_mode) 'Normal launch unexpectedly uses background mode.'
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $windows = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
            $main = @($windows.objects | Where-Object class -EQ 'gp::gui::MainWindow')
            if ($main.Count -eq 1 -and $main[0].visible) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert ($main.Count -eq 1 -and $main[0].visible) 'Normal startup did not preserve the visible main window.'
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $documents = Invoke-McpTool $connection gp_documents
            if ($documents.documents.Count -eq 1) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert ($documents.documents.Count -eq 1 -and -not $documents.documents[0].dirty) 'Score open did not produce one clean live document.'
        $bars = Invoke-McpTool $connection gp_read_bars @{count=2}
        Assert ($bars.bars[0].voices[0].beats[0].notes[0].midi -eq 40) 'The autoloaded plugin cannot read the native score.'
        $actions = Invoke-McpTool $connection gp_actions @{query='gpmcpStatusAction'}
        Assert ($actions.objects.Count -eq 1) 'MCP status action was not added to the application.'
        Invoke-McpTool $connection gp_trigger @{snapshot=$actions.snapshot;id=$actions.objects[0].id} | Out-Null
        Start-Sleep -Milliseconds 200
        $statusLabel = Invoke-McpTool $connection gp_objects @{query='gpmcpServiceStatus'}
        Assert ($statusLabel.objects.Count -eq 1 -and $statusLabel.objects[0].properties.text -eq 'running') 'Status dialog did not show the running service.'
        $modal = Invoke-McpTool $connection gp_dialogs
        Assert ($modal.blocked -and $modal.name -eq 'gpmcpStatusDialog') 'Active modal state was not exposed.'
        $scoreBefore = Invoke-McpTool $connection gp_score
        $blocked = Invoke-McpTool $connection gp_edit_metadata @{property='Title';value='must not be written'} -AllowError
        Assert ($blocked.error -and $blocked.dialog.blocked) 'Native edit was accepted while a modal dialog was open.'
        Assert ((Invoke-McpTool $connection gp_score).metadata.Title -eq $scoreBefore.metadata.Title) 'Rejected modal edit changed the score.'
        $mainWindow = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
        $mainTarget = @($mainWindow.objects | Where-Object class -EQ 'gp::gui::MainWindow')[0]
        $blockedClose = Invoke-McpTool $connection gp_close_window @{snapshot=$mainWindow.snapshot;id=$mainTarget.id} -AllowError
        Assert ($blockedClose.error -and $blockedClose.dialog.blocked) 'Main window closed while a modal dialog was active.'
        $checkbox = Invoke-McpTool $connection gp_objects @{query='gpmcpEnabled'}
        Invoke-McpTool $connection gp_set_property @{snapshot=$checkbox.snapshot;id=$checkbox.objects[0].id;property='checked';value=$false} | Out-Null
        Start-Sleep -Milliseconds 100
        Assert (-not (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).enabled) 'Status dialog did not persist the disabled setting.'
        $checkbox = Invoke-McpTool $connection gp_objects @{query='gpmcpEnabled'}
        Invoke-McpTool $connection gp_set_property @{snapshot=$checkbox.snapshot;id=$checkbox.objects[0].id;property='checked';value=$true} | Out-Null
        Start-Sleep -Milliseconds 100
        Assert ((Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).enabled) 'Status dialog did not persist the enabled setting.'
        $dialog = Invoke-McpTool $connection gp_objects @{query='gpmcpStatusDialog'}
        Invoke-McpTool $connection gp_close_window @{snapshot=$dialog.snapshot;id=$dialog.objects[0].id} | Out-Null
        $rejected = $false
        try { Install Update | Out-Null } catch { $rejected = $_.Exception.Message -like 'Close this Guitar Pro*' }
        Assert $rejected 'Updating a running host was accepted.'
        & "$PSScriptRoot/test-mcp.ps1" -SessionFile $descriptorPath
    } finally { Close-McpSession $connection }
    Stop-Owned $process; $process = $null
    $tokenHash = (Get-FileHash -LiteralPath (Join-Path $data 'mcp-auth-token')).Hash
    $process = Launch 'background' $true $true
    Assert (Test-Path -LiteralPath $descriptorPath) 'Background MCP startup failed.'
    $connection = New-McpSession -SessionFile $descriptorPath
    try {
        $identity = Invoke-McpTool $connection gp_capabilities
        Assert $identity.hidden_mode 'Explicit background mode was not selected.'
        Start-Sleep -Milliseconds 800
        $windows = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
        Assert (-not @($windows.objects | Where-Object { $_.class -eq 'gp::gui::MainWindow' -and $_.visible }).Count) 'Background startup showed the window.'
    } finally { Close-McpSession $connection }
    Assert ((Get-FileHash -LiteralPath (Join-Path $data 'mcp-auth-token')).Hash -eq $tokenHash) 'Restart changed the saved MCP token.'
    Stop-Owned $process; $process = $null
    Install Disable | Out-Null
    $process = Launch 'disabled'
    Assert (-not $process.HasExited -and -not (Test-Path -LiteralPath $descriptorPath)) 'Disabled plugin started MCP or stopped the host.'
    Assert ((Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).status -eq 'disabled') 'Disabled state was not reported.'
    Stop-Owned $process; $process = $null
    Install Enable | Out-Null
    $blocker = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 18432)
    $blocker.Start()
    try {
        $process = Launch 'port-conflict'
        Assert (-not $process.HasExited -and -not (Test-Path -LiteralPath $descriptorPath)) 'Port conflict stopped the host or published a wrong session.'
        Assert ((Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).status -eq 'service_error') 'Port conflict was not diagnosed.'
    } finally { Stop-Owned $process; $process = $null; $blocker.Stop() }
    $clientPath = Join-Path $data 'mcp-client.json'
    $clientBackup = Join-Path $run 'client-backup.json'
    Move-Item -LiteralPath $clientPath -Destination $clientBackup
    New-Item -ItemType Directory -Path $clientPath | Out-Null
    try {
        $process = Launch 'blocked-client-config'
        Assert (-not $process.HasExited -and -not (Test-Path -LiteralPath $descriptorPath)) 'Failed client configuration left a false session or stopped the host.'
        Assert ((Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).status -eq 'service_error') 'Client configuration failure was not diagnosed.'
    } finally {
        Stop-Owned $process; $process = $null
        Remove-Item -LiteralPath $clientPath
        Move-Item -LiteralPath $clientBackup -Destination $clientPath
    }
    $tokenPath = Join-Path $data 'mcp-auth-token'
    $tokenBackup = Join-Path $run 'token-backup'
    Move-Item -LiteralPath $tokenPath -Destination $tokenBackup
    'invalid' | Set-Content -LiteralPath $tokenPath -Encoding UTF8
    try {
        $process = Launch 'invalid-token'
        Assert (-not $process.HasExited -and -not (Test-Path -LiteralPath $descriptorPath)) 'Invalid token started MCP or stopped the host.'
        Assert ((Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).status -eq 'service_error') 'Invalid token was not diagnosed.'
    } finally {
        Stop-Owned $process; $process = $null
        Remove-Item -LiteralPath $tokenPath
        Move-Item -LiteralPath $tokenBackup -Destination $tokenPath
    }
    '{invalid' | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $process = Launch 'invalid-settings'
    Assert (-not $process.HasExited -and -not (Test-Path -LiteralPath $descriptorPath)) 'Invalid settings stopped the host or started MCP.'
    Assert ((Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).status -eq 'configuration_error') 'Invalid settings were not diagnosed.'
    Stop-Owned $process; $process = $null
    Remove-Item -LiteralPath $settingsPath
    $backupExe = Join-Path $run 'verified-GuitarPro.exe'
    Copy-Item -LiteralPath $exe -Destination $backupExe
    try {
        $append = [IO.File]::Open($exe, [IO.FileMode]::Append, [IO.FileAccess]::Write)
        try { $append.WriteByte(0) } finally { $append.Dispose() }
        $process = Launch 'unsupported-host'
        Assert (-not $process.HasExited -and -not (Test-Path -LiteralPath $descriptorPath)) 'Unsupported host started private MCP code or failed to launch.'
        Assert ((Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).status -eq 'unsupported_host') 'Unsupported host was not diagnosed.'
        $loadedCore = @($process.Modules | Where-Object ModuleName -EQ 'guitarpro_mcp.dll')
        Assert ($loadedCore.Count -eq 0) 'Unsupported host loaded the private-interface DLL.'
    } finally {
        Stop-Owned $process; $process = $null
        Copy-Item -LiteralPath $backupExe -Destination $exe -Force
    }
    Install Uninstall | Out-Null
    Assert (-not (Install Status).installed) 'Uninstall left the receipt.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $HostDirectory 'Plugins/imageformats/guitarpro_mcp_autoload.dll'))) 'Uninstall left the bootstrap.'
    $process = Launch 'uninstalled'
    Assert (-not $process.HasExited -and -not (Test-Path -LiteralPath $statusPath)) 'Uninstall did not restore ordinary startup.'
    Assert ((Get-FileHash -LiteralPath $exe).Hash -eq $hashBefore) 'The installer modified the host executable.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $data 'mcp-auth-token')).Hash -eq $tokenHash) 'Uninstall deleted or changed user credentials.'
} finally {
    Stop-Owned $process
    foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
    @{checks=$checks;host=$HostDirectory;host_sha256=$hashBefore;observations=$observations} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
}
Write-Output "PASS: $checks installation checks plus MCP protocol checks. Evidence: $run"
