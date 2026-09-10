param(
    [ValidateSet('Install','Update','Uninstall','Enable','Disable','Status')][string]$Action = 'Install',
    [string]$InstallDirectory = 'C:\Program Files\Arobas Music\Guitar Pro 8',
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'GuitarProMCP'),
    [string]$PackageDirectory = '',
    [switch]$Elevate
)
$ErrorActionPreference = 'Stop'
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
if ($Elevate -and $Action -in 'Install','Update','Uninstall') {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'),'-Action',$Action,'-InstallDirectory',('"' + $InstallDirectory + '"'),'-DataDirectory',('"' + $DataDirectory + '"'))
        if ($PackageDirectory) { $arguments += @('-PackageDirectory',('"' + [IO.Path]::GetFullPath($PackageDirectory) + '"')) }
        $child = Start-Process -FilePath powershell.exe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if ($child.ExitCode) { throw "Elevated installer failed (exit $($child.ExitCode)). Run install-plugin.ps1 from an administrator terminal for details." }
        Write-Output "$Action completed."
        return
    }
}
$receiptPath = Join-Path $InstallDirectory 'Plugins/guitarpro-mcp-install.json'
$settingsPath = Join-Path $DataDirectory 'settings.json'
$paths = @('Plugins/generic/guitarpro_mcp.dll','Plugins/imageformats/guitarpro_mcp_autoload.dll')
$receipt = if (Test-Path -LiteralPath $receiptPath) { Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
if ($receipt -and $receipt.product -ne 'GuitarProMCP') { throw 'Unrecognized installation receipt.' }
function Read-Settings {
    if (-not (Test-Path -LiteralPath $settingsPath)) { return [pscustomobject]@{} }
    $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $settings -or $settings.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') { throw 'settings.json must contain an object.' }
    if ($settings.PSObject.Properties['enabled'] -and $settings.enabled -isnot [bool]) { throw 'enabled must be boolean.' }
    return $settings
}
if ($Action -in 'Enable','Disable') {
    New-Item -ItemType Directory -Force -Path $DataDirectory | Out-Null
    $settings = Read-Settings
    $settings | Add-Member -NotePropertyName enabled -NotePropertyValue ($Action -eq 'Enable') -Force
    $temporary = Join-Path $DataDirectory ('settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $settingsPath) { [IO.File]::Replace($temporary, $settingsPath, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $settingsPath) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    Write-Output "$Action saved for the next Guitar Pro start."
    return
}
$exe = Join-Path $InstallDirectory 'GuitarPro.exe'
$running = @(Get-Process -Name GuitarPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
if ($Action -eq 'Status') {
    $enabled = $null
    $configurationError = $null
    try {
        $settings = Read-Settings
        $enabled = -not $settings.PSObject.Properties['enabled'] -or $settings.enabled
    } catch { $configurationError = $_.Exception.Message }
    [pscustomobject]@{installed=($null -ne $receipt);version=$receipt.version;enabled=$enabled;configuration_error=$configurationError;running_pids=@($running | ForEach-Object Id);data_directory=$DataDirectory;client_config=(Join-Path $DataDirectory 'mcp-client.json')}
    return
}
if ($running.Count) { throw "Close this Guitar Pro instance before $Action (PID $($running.Id -join ', '))." }
foreach ($relative in $paths) {
    $target = Join-Path $InstallDirectory $relative
    $recorded = @($receipt.files | Where-Object path -EQ $relative)
    if (Test-Path -LiteralPath $target) {
        if ($recorded.Count -ne 1 -or (Get-FileHash -LiteralPath $target).Hash -ne $recorded[0].sha256) {
            throw "Refusing to replace or remove an unowned/modified file: $target"
        }
    }
}
if ($Action -eq 'Uninstall') {
    if (-not $receipt) { Write-Output 'GuitarProMCP is not installed.'; return }
    foreach ($relative in $paths) {
        $target = Join-Path $InstallDirectory $relative
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
    }
    Remove-Item -LiteralPath $receiptPath
    Write-Output "GuitarProMCP uninstalled. User configuration retained at $DataDirectory."
    return
}
if (-not $PackageDirectory) {
    $PackageDirectory = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'plugins')) { $PSScriptRoot } else { Join-Path $PSScriptRoot '.tools/native' }
}
$PackageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
$allowlistPath = Join-Path $PackageDirectory 'supported-host.json'
if (-not (Test-Path -LiteralPath $allowlistPath)) { $allowlistPath = Join-Path $PSScriptRoot 'native/supported-host.json' }
$allowlist = Get-Content -LiteralPath $allowlistPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($file in $allowlist.PSObject.Properties) {
    $target = Join-Path $InstallDirectory $file.Name
    if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target).Hash -ne $file.Value) {
        throw "Unsupported Guitar Pro build: $($file.Name) does not match the verified release."
    }
}
$configuration = Get-Content -LiteralPath (Join-Path $InstallDirectory 'qt.conf') -Raw
if ($configuration.Trim() -notmatch '^\[Paths\]\s+Plugins\s*=\s*Plugins\s*$') { throw 'Unsupported Qt plugin directory configuration.' }
$files = @()
foreach ($relative in $paths) {
    $source = Join-Path $PackageDirectory $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing prebuilt plugin: $source" }
    $files += [pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $source).Hash}
}
$packageManifest = Join-Path $PackageDirectory 'package.json'
$version = '0.7.0'
if (Test-Path -LiteralPath $packageManifest) {
    $manifest = Get-Content -LiteralPath $packageManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.product -ne 'GuitarProMCP' -or $manifest.version -notmatch '^\d+\.\d+\.\d+([-.][A-Za-z0-9.]+)?$') { throw 'Invalid package manifest.' }
    $version = $manifest.version
    foreach ($file in $files) {
        $expected = @($manifest.files | Where-Object path -EQ $file.path)
        if ($expected.Count -ne 1 -or $expected[0].sha256 -ne $file.sha256) { throw "Package integrity check failed: $($file.path)" }
    }
}
$staging = Join-Path $InstallDirectory ('Plugins/gpmcp-staging-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
$changed = @()
$removeStaging = $true
try {
    foreach ($file in $files) {
        Copy-Item -LiteralPath (Join-Path $PackageDirectory $file.path) -Destination (Join-Path $staging ([IO.Path]::GetFileName($file.path)))
    }
    foreach ($file in $files) {
        $target = Join-Path $InstallDirectory $file.path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        $staged = Join-Path $staging ([IO.Path]::GetFileName($file.path))
        $backup = "$staged.backup"
        if (Test-Path -LiteralPath $target) { [IO.File]::Replace($staged, $target, $backup) }
        else { [IO.File]::Move($staged, $target) }
        $changed += [pscustomobject]@{target=$target;backup=$backup}
    }
    $newReceipt = Join-Path $staging 'receipt.json'
    @{product='GuitarProMCP';version=$version;files=$files;installed_at=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $newReceipt -Encoding UTF8
    if (Test-Path -LiteralPath $receiptPath) { [IO.File]::Replace($newReceipt, $receiptPath, [NullString]::Value) }
    else { [IO.File]::Move($newReceipt, $receiptPath) }
} catch {
    try {
        [array]::Reverse($changed)
        foreach ($file in $changed) {
            if (Test-Path -LiteralPath $file.backup) { [IO.File]::Replace($file.backup, $file.target, [NullString]::Value) }
            elseif (Test-Path -LiteralPath $file.target) { Remove-Item -LiteralPath $file.target }
        }
    } catch {
        $removeStaging = $false
        throw "Rollback could not finish. Backups retained at $staging. $($_.Exception.Message)"
    }
    throw
} finally {
    # Only remove the flat staging directory created by this invocation.
    if ($removeStaging) {
        Get-ChildItem -LiteralPath $staging -File | Remove-Item
        Remove-Item -LiteralPath $staging
    }
}
Write-Output "GuitarProMCP installed in $InstallDirectory. Start Guitar Pro normally."
