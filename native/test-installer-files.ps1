param([Parameter(Mandatory=$true)][string]$HostDirectory)
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
function Install([string]$action) { & "$root/install-plugin.ps1" -Action $action -InstallDirectory $HostDirectory -DataDirectory $run }
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
    Assert ((Install Status).running_pids.Count -eq 0) 'Inactive host reported a null process as running.'
} finally { Install Uninstall | Out-Null }
Assert (-not (Test-Path -LiteralPath $core) -and -not (Test-Path -LiteralPath $autoload)) 'Uninstall left an owned DLL.'
@{checks=$checks;host=$HostDirectory} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'verification.json')
Write-Output "PASS: $checks installer file-ownership and configuration checks. Evidence: $run"
