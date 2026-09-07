param([Parameter(Mandatory=$true)][string]$HostDirectory, [string]$PackageDirectory = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$HostDirectory = [IO.Path]::GetFullPath($HostDirectory)
if (-not $HostDirectory.StartsWith(([IO.Path]::GetFullPath((Join-Path $root '.tools')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Use an isolated host copy under .tools.' }
$run = Join-Path $root ('artifacts/installer-files-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$core = Join-Path $HostDirectory 'Plugins/generic/guitarpro_mcp.dll'
$autoload = Join-Path $HostDirectory 'Plugins/imageformats/guitarpro_mcp_autoload.dll'
if (Test-Path -LiteralPath $core) { throw 'Uninstall the test copy before file-level checks.' }
$checks = 0
function Assert($condition,[string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
$installer = if ($PackageDirectory) { Join-Path $PackageDirectory 'install-plugin.ps1' } else { "$root/install-plugin.ps1" }
function Install([string]$action) { & $installer -Action $action -InstallDirectory $HostDirectory -DataDirectory $run -PackageDirectory $PackageDirectory }
function Reject([scriptblock]$operation,[string]$pattern) {
    $rejected = $false
    try { & $operation | Out-Null } catch { $rejected = $_.Exception.Message -like $pattern }
    Assert $rejected "Expected rejection: $pattern"
}
'unowned-test-file' | Set-Content -LiteralPath $core
try {
    Reject { Install Install } 'Refusing to replace or remove an unowned/modified file*'
    Assert ((Get-Content -LiteralPath $core -Raw).Trim() -eq 'unowned-test-file') 'Installer overwrote an unowned file.'
} finally { Remove-Item -LiteralPath $core }
Install Install | Out-Null
try {
    # A rollback to byte-identical DLLs can pass even if restoration is broken.
    # Use distinct PE overlays in an isolated candidate, then fail its receipt commit.
    $receiptPath = Join-Path $HostDirectory 'Plugins/guitarpro-mcp-install.json'
    $receiptBefore = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $receiptHash = (Get-FileHash -LiteralPath $receiptPath).Hash
    $rollbackPackage = Join-Path $run 'rollback-package'
    New-Item -ItemType Directory -Path $rollbackPackage | Out-Null
    $compatibility = if ($PackageDirectory) { Join-Path $PackageDirectory 'supported-host.json' } else { "$PSScriptRoot/supported-host.json" }
    Copy-Item -LiteralPath $compatibility -Destination $rollbackPackage
    $changedFiles = @()
    foreach ($file in $receiptBefore.files) {
        $candidate = Join-Path $rollbackPackage $file.path
        New-Item -ItemType Directory -Path (Split-Path -Parent $candidate) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $HostDirectory $file.path) -Destination $candidate
        $stream = [IO.File]::Open($candidate,[IO.FileMode]::Append,[IO.FileAccess]::Write)
        try { $stream.WriteByte(0) } finally { $stream.Dispose() }
        $hash = (Get-FileHash -LiteralPath $candidate).Hash
        Assert ($hash -ne $file.sha256) 'Rollback fixture did not change the candidate bytes.'
        $changedFiles += @{path=$file.path;sha256=$hash}
    }
    @{product='GuitarProMCP';version='0.3.0-rollback.test';files=$changedFiles} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$rollbackPackage/package.json" -Encoding UTF8
    $receiptLock = [IO.File]::Open($receiptPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $failedAtReceipt = $false
        try { & $installer -Action Update -InstallDirectory $HostDirectory -DataDirectory $run -PackageDirectory $rollbackPackage | Out-Null }
        catch {
            $failureDetail = @{message=$_.Exception.Message;line=$_.InvocationInfo.Line;stack=$_.ScriptStackTrace;inner_hresult=$_.Exception.InnerException.HResult}
            $failureDetail | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'rollback-failure.json') -Encoding UTF8
            $failedAtReceipt = $_.InvocationInfo.Line -like '*Replace($newReceipt*'
        }
        Assert $failedAtReceipt 'The distinct-binary update did not fail at the locked receipt commit.'
    } finally { $receiptLock.Dispose() }
    Assert ((Get-FileHash -LiteralPath $receiptPath).Hash -eq $receiptHash) 'Rollback changed the previous receipt.'
    foreach ($file in $receiptBefore.files) { Assert ((Get-FileHash -LiteralPath (Join-Path $HostDirectory $file.path)).Hash -eq $file.sha256) 'Rollback failed to restore the previous DLL bytes.' }
    $backup = Join-Path $run 'bootstrap-backup.dll'
    Copy-Item -LiteralPath $autoload -Destination $backup
    $append = [IO.File]::Open($autoload,[IO.FileMode]::Append,[IO.FileAccess]::Write)
    try { $append.WriteByte(0) } finally { $append.Dispose() }
    try {
        Reject { Install Update } 'Refusing to replace or remove an unowned/modified file*'
        Reject { Install Uninstall } 'Refusing to replace or remove an unowned/modified file*'
    } finally { Copy-Item -LiteralPath $backup -Destination $autoload -Force }
    $settings = Join-Path $run 'settings.json'
    foreach ($invalid in @('false','[]','null','{"enabled":"yes"}','{invalid')) {
        $invalid | Set-Content -LiteralPath $settings -Encoding UTF8
        $status = Install Status
        Assert ($status.configuration_error -and $null -eq $status.enabled) 'Invalid settings were presented as enabled.'
        Reject { Install Enable } '*'
        Assert ((Get-Content -LiteralPath $settings -Raw).Trim() -eq $invalid) 'Invalid settings were overwritten.'
    }
    Remove-Item -LiteralPath $settings
    Install Disable | Out-Null
    Assert (-not (Install Status).enabled) 'Disable state mismatch.'
    Install Enable | Out-Null
    Assert ((Install Status).enabled) 'Enable state mismatch.'
    $label = [string][char]0x66f2 + [char]0x8c31 + [char]0x914d + [char]0x7f6e
    [IO.File]::WriteAllText($settings, (@{enabled=$true;label=$label} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    foreach ($action in @('Disable','Enable')) {
        Install $action | Out-Null
        $savedSettings = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($savedSettings.label -eq $label) 'Startup setting update corrupted BOM-less UTF-8 user configuration.'
        Assert ($savedSettings.enabled -eq ($action -eq 'Enable')) 'UTF-8 settings did not retain the requested startup preference.'
    }
    Assert ((Install Status).running_pids.Count -eq 0) 'Inactive host reported a null process as running.'
} finally { Install Uninstall | Out-Null }
Assert (-not (Test-Path -LiteralPath $core) -and -not (Test-Path -LiteralPath $autoload)) 'Uninstall left an owned DLL.'
@{passed=$true;checks=$checks;host=$HostDirectory;package=$PackageDirectory;installed_files=$receiptBefore.files;test_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;powershell=$PSVersionTable.PSVersion.ToString()} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
Write-Output "PASS: $checks installer file-ownership and configuration checks. Evidence: $run"
