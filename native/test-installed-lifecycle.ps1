param(
    [string]$InstallDirectory = 'C:\Program Files\Arobas Music\Guitar Pro 8',
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [string]$RunDirectory = '',
    [ValidateRange(0,60000)][int]$StartupSettleMs = 5000,
    [string]$ExpectedUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
    [switch]$Elevate
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$InstallDirectory = (Resolve-Path -LiteralPath $InstallDirectory).Path
$PackageDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path
$run = if ($RunDirectory) { [IO.Path]::GetFullPath($RunDirectory) } else { Join-Path $root ('artifacts/installed-lifecycle-' + [guid]::NewGuid().ToString('N')) }
if (-not $run.StartsWith(([IO.Path]::GetFullPath((Join-Path $root 'artifacts')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must be under project artifacts.' }
New-Item -ItemType Directory -Path $run -Force | Out-Null
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $ExpectedUserSid) { throw 'Use the same Windows user when elevating; per-user acceptance cannot run as another account.' }
if ($Elevate -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Elevate the complete bounded lifecycle once; preserve the invoking user's data location.
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'),'-InstallDirectory',('"' + $InstallDirectory + '"'),'-PackageDirectory',('"' + $PackageDirectory + '"'),'-RunDirectory',('"' + $run + '"'),'-ExpectedUserSid',$ExpectedUserSid,'-StartupSettleMs',$StartupSettleMs)
    $child = Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
    Write-Output "Elevated acceptance started: PID $($child.Id). Evidence: $run"
    $child.WaitForExit()
    $code = $child.ExitCode
    $child.Dispose()
    if ($code -ne 0) { throw "Installed lifecycle failed (exit $code). Inspect $run/transcript.txt and verification.json." }
    Write-Output "PASS: installed lifecycle. Evidence: $run"
    return
}
if (@(Get-Process GuitarPro -ErrorAction SilentlyContinue).Count) { throw 'Close all Guitar Pro hosts before the installed lifecycle test.' }
$data = Join-Path $env:LOCALAPPDATA 'GuitarProMCP'
$settings = Join-Path $data 'settings.json'
$token = Join-Path $data 'mcp-auth-token'
$settingsBefore = if (Test-Path -LiteralPath $settings) { [IO.File]::ReadAllBytes($settings) } else { $null }
$tokenBefore = if (Test-Path -LiteralPath $token) { (Get-FileHash -LiteralPath $token).Hash } else { $null }
$installer = Join-Path $PackageDirectory 'install-plugin.ps1'
$exe = Join-Path $InstallDirectory 'GuitarPro.exe'
$manifest = Get-Content -LiteralPath "$PackageDirectory/package.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$receiptPath = Join-Path $InstallDirectory 'Plugins/guitarpro-mcp-install.json'
$originalReceipt = if (Test-Path -LiteralPath $receiptPath) { Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$vendorBefore = @((Get-Content -LiteralPath "$PackageDirectory/supported-host.json" -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
    @{path=$_.Name;sha256=(Get-FileHash -LiteralPath (Join-Path $InstallDirectory $_.Name)).Hash}
})
$shortcutBefore = @()
$shell = New-Object -ComObject WScript.Shell
$locations = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs","$env:APPDATA\Microsoft\Windows\Start Menu\Programs",[Environment]::GetFolderPath('Desktop'),"$env:PUBLIC\Desktop")
foreach ($file in @(Get-ChildItem -LiteralPath $locations -Filter '*Guitar*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
    if ($shell.CreateShortcut($file.FullName).TargetPath -eq $exe) { $shortcutBefore += @{path=$file.FullName;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash} }
}
$associationBefore = @()
foreach ($part in @('command','ddeexec','ddeexec\application','ddeexec\topic','ddeexec\ifexec')) {
    $key = 'Registry::HKEY_CLASSES_ROOT\Guitar Pro 8.AssocFile.gp\shell\open\' + $part
    $associationBefore += @{path=$key;value=(Get-Item -LiteralPath $key).GetValue('')}
}
$checks = 0
$steps = @()
$baseline = @()
$passed = $false
$failure = $null
$configurationRestored = $false
$process = $null
$original = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS') + @(Get-ChildItem Env: | Where-Object Name -Like 'GPMCP_*' | ForEach-Object Name)) { $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Assert($condition,[string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Install([string]$action) {
    Write-Output "Installed lifecycle: $action"
    & $installer -Action $action -InstallDirectory $InstallDirectory -DataDirectory $data -PackageDirectory $PackageDirectory | Out-Host
    $script:steps += @{action=$action;utc=[DateTime]::UtcNow.ToString('o')}
}
function Assert-Binaries {
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        Assert ((Get-FileHash -LiteralPath (Join-Path $InstallDirectory $file.path)).Hash -eq $file.sha256) 'Installed file differs from the tested package.'
        Assert (@($receipt.files | Where-Object { $_.path -eq $file.path -and $_.sha256 -eq $file.sha256 }).Count -eq 1) 'Receipt differs from the installed binary.'
    }
}
function Check-OrdinaryHost([string]$state) {
    $score = Join-Path $run "$state.gp"
    Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $score
    $script:process = Start-Process -FilePath $exe -WorkingDirectory $InstallDirectory -ArgumentList @('--open',('"' + $score + '"')) -WindowStyle Normal -PassThru
    $null = $process.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do { Start-Sleep -Milliseconds 200; $process.Refresh() } while (-not $process.HasExited -and $process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    Assert (-not $process.HasExited -and $process.MainWindowHandle -ne [IntPtr]::Zero) "Ordinary $state host did not show a window."
    $settle = $StartupSettleMs - ([DateTime]::Now - $process.StartTime).TotalMilliseconds
    if ($settle -gt 0) { Start-Sleep -Milliseconds ([int]$settle) }
    $modules = @($process.Modules | ForEach-Object ModuleName)
    Assert ('guitarpro_mcp.dll' -notin $modules) "The $state host loaded MCP core."
    if ($state -eq 'disabled') {
        Assert ('guitarpro_mcp_autoload.dll' -in $modules) 'Disabled installation did not load its status bootstrap.'
        $status = Get-Content -LiteralPath "$data/status.json" -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($status.status -eq 'disabled' -and $status.pid -eq $process.Id) 'Disabled status belongs to another host or reports the wrong state.'
    } else { Assert ('guitarpro_mcp_autoload.dll' -notin $modules) 'Uninstalled host loaded the bootstrap.' }
    Assert (-not (Test-Path -LiteralPath "$data/native-session.json")) 'Inactive service published a session descriptor.'
    $observation = [ordered]@{state=$state;pid=$process.Id;window_title=$process.MainWindowTitle;exit_code=$null}
    $script:baseline += $observation
    # WM_CLOSE retains normal save/discard/cancel handling. Never kill a retained real host.
    Assert ($process.CloseMainWindow()) 'Ordinary close was not accepted.'
    Assert ($process.WaitForExit(45000) -and $process.ExitCode -eq 0) "Ordinary $state host did not exit cleanly; retained."
    $observation.exit_code = $process.ExitCode
    $process.Dispose(); $script:process = $null
}
Start-Transcript -LiteralPath (Join-Path $run 'transcript.txt') | Out-Null
try {
    foreach ($name in $original.Keys) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    # First upgrade the user's old managed build. Then exercise a complete fresh lifecycle.
    Install Update
    Assert-Binaries
    Install Enable
    & "$PSScriptRoot/test-installed-entrypoints.ps1" -InstallDirectory $InstallDirectory -PackageDirectory $PackageDirectory -StartupSettleMs $StartupSettleMs -RunDirectory (Join-Path $run 'entrypoints')
    Install Uninstall
    Assert (-not (Test-Path -LiteralPath $receiptPath)) 'Uninstall left the installation receipt.'
    Install Install
    Assert-Binaries
    Install Update
    Assert-Binaries
    Install Disable
    Check-OrdinaryHost 'disabled'
    Install Enable
    & "$PSScriptRoot/test-installed-entrypoints.ps1" -InstallDirectory $InstallDirectory -PackageDirectory $PackageDirectory -Variants background -StartupSettleMs $StartupSettleMs -RunDirectory (Join-Path $run 'enabled')
    $settingsHash = (Get-FileHash -LiteralPath $settings).Hash
    $tokenHash = (Get-FileHash -LiteralPath $token).Hash
    Install Uninstall
    Assert (-not (Test-Path -LiteralPath $receiptPath)) 'Uninstall left the receipt.'
    foreach ($file in $manifest.files) { Assert (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory $file.path))) 'Uninstall left a managed DLL.' }
    Assert ((Get-FileHash -LiteralPath $settings).Hash -eq $settingsHash -and (Get-FileHash -LiteralPath $token).Hash -eq $tokenHash) 'Uninstall changed persistent settings or credentials.'
    Check-OrdinaryHost 'uninstalled'
    Install Install
    Assert-Binaries
    & "$PSScriptRoot/test-installed-entrypoints.ps1" -InstallDirectory $InstallDirectory -PackageDirectory $PackageDirectory -Variants background -StartupSettleMs $StartupSettleMs -RunDirectory (Join-Path $run 'reinstalled')
    foreach ($file in $vendorBefore) { Assert ((Get-FileHash -LiteralPath (Join-Path $InstallDirectory $file.path)).Hash -eq $file.sha256) 'The lifecycle changed a vendor binary.' }
    foreach ($file in $shortcutBefore) { Assert ((Get-FileHash -LiteralPath $file.path).Hash -eq $file.sha256) 'The lifecycle changed an existing shortcut.' }
    foreach ($key in $associationBefore) { Assert ((Get-Item -LiteralPath $key.path).GetValue('') -eq $key.value) 'The lifecycle changed the registered file-association protocol.' }
    if ($tokenBefore) { Assert ((Get-FileHash -LiteralPath $token).Hash -eq $tokenBefore) 'The lifecycle replaced existing user credentials.' }
    $passed = $true
} catch { $failure = $_.Exception.Message; throw }
finally {
    # Preserve the original user preference (including an originally absent settings file).
    if ($null -ne $settingsBefore) { [IO.File]::WriteAllBytes($settings, $settingsBefore) }
    elseif (Test-Path -LiteralPath $settings) { Remove-Item -LiteralPath $settings }
    $configurationRestored = $true
    foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
    if ($process) { Write-Warning "Test host retained: PID $($process.Id)"; $process.Dispose() }
    @{passed=$passed;failure=$failure;checks=$checks;package=$PackageDirectory;package_sha256=$(if(Test-Path -LiteralPath "$PackageDirectory.zip"){(Get-FileHash -LiteralPath "$PackageDirectory.zip").Hash});files=$manifest.files;host=$exe;original_receipt=$originalReceipt;steps=$steps;ordinary_hosts=$baseline;configuration_restored=$configurationRestored;powershell=$PSVersionTable.PSVersion.ToString();startup_settle_ms=$StartupSettleMs;test_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    Stop-Transcript | Out-Null
}
Write-Output "PASS: $checks installed lifecycle checks plus entrypoint suites. Evidence: $run"
