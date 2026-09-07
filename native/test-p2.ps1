param([Parameter(Mandatory=$true)][string]$HostDirectory, [string]$NodeExe = 'node')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$HostDirectory = (Resolve-Path -LiteralPath $HostDirectory).Path
if (-not $HostDirectory.StartsWith(([IO.Path]::GetFullPath((Join-Path $root '.tools')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Use an isolated host under .tools.' }
$exe = Join-Path $HostDirectory 'GuitarPro.exe'
$NodeExe = (Get-Command $NodeExe -CommandType Application -ErrorAction Stop).Source
$run = Join-Path $root ('artifacts/p2-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$shells = @((Get-Command pwsh -ErrorAction Stop).Source, "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe")
$results = @(); $passed = $false
function Run-Step([string]$name, [string]$shell, [string]$script, [string[]]$arguments) {
    Write-Output "Running $name"
    $log = Join-Path $run ($name + '.log')
    $stderr = Join-Path $run ($name + '.stderr.log')
    $parameters = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot $script)) + $arguments
    $quoted = @($parameters | ForEach-Object { if ($_.Contains('"')) { throw 'Unexpected quote in test argument.' }; '"' + $_ + '"' })
    $modulePath = $env:PSModulePath
    try {
        # Let each PowerShell version construct its own built-in module path.
        Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue
        $process = Start-Process -FilePath $shell -ArgumentList $quoted -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
    } finally { $env:PSModulePath = $modulePath }
    try { $null = $process.Handle; while (-not $process.WaitForExit(1000)) {}; $code = $process.ExitCode } finally { $process.Dispose() }
    $output = @(Get-Content -LiteralPath $log)
    $script:results += @{name=$name;exit_code=$code;script=$script;shell=$shell}
    if ($code -ne 0) { throw "$name failed; evidence: $run" }
    if ($script -like 'test-*' -and -not @($output | Where-Object { "$_" -match '^PASS:|^Complete regression evidence:' }).Count) { throw "$name returned no passing evidence." }
}
try {
    Run-Step 'build' $shells[0] 'build.ps1' @()
    Run-Step 'build-save-probe' $shells[0] 'build-save-fault-probe.ps1' @()
    Run-Step 'build-tab-probe' $shells[0] 'build-tab-fault-probe.ps1' @()
    Run-Step 'build-dde-client' $shells[0] 'build-dde-client.ps1' @()
    for ($i = 0; $i -lt $shells.Count; $i++) {
        $label = if ($i -eq 0) { 'ps7' } else { 'ps51' }
        Run-Step "$label-regression" $shells[$i] 'test-all.ps1' @('-Exe',$exe)
        Run-Step "$label-save-recovery" $shells[$i] 'test-save-recovery.ps1' @('-Exe',$exe)
        Run-Step "$label-tab-recovery" $shells[$i] 'test-tab-recovery.ps1' @('-Exe',$exe)
        Run-Step "$label-changed-documents" $shells[$i] 'test-tab-recovery.ps1' @('-Exe',$exe,'-CloseCleanDocuments','-AddDocumentDuringRecovery')
        Run-Step "$label-instances" $shells[$i] 'test-instances.ps1' @('-HostDirectory',$HostDirectory,'-CheckLaunchForwarding','-CheckMcpClient','-NodeExe',$NodeExe)
    }
    $passed = $true
} finally {
    $sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object Extension -In @('.h','.cpp','.ps1','.def','.json') | Get-FileHash | Select-Object Path,Hash)
    @{passed=$passed;steps=$results;sources=$sources;host_sha256=(Get-FileHash -LiteralPath $exe).Hash;plugin_sha256=(Get-FileHash -LiteralPath "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash;autoload_sha256=(Get-FileHash -LiteralPath "$root/.tools/native/plugins/imageformats/guitarpro_mcp_autoload.dll").Hash} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
}
Write-Output "PASS: full P2 regression flow. Evidence: $run"
