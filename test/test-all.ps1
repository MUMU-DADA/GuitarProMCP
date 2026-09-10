param([string]$Exe = 'C:\Program Files\Arobas Music\Guitar Pro 8\GuitarPro.exe', [string]$SessionFile, [string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
if ($PackageDirectory -and -not $SessionFile) { throw 'Package regression requires an autoloaded installed session.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/../native/mcp-client.ps1"
$fixture = Join-Path $root 'artifacts/native-test.gp'
$fixtureHash = (Get-FileHash -LiteralPath "$PSScriptRoot/testdata/minimal.gp").Hash
if (Test-Path -LiteralPath $fixture) {
    if ((Get-FileHash -LiteralPath $fixture).Hash -ne $fixtureHash) { throw 'Refusing to replace a modified native-test.gp.' }
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fixture) | Out-Null
    Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $fixture
}
$run = Join-Path $root ('artifacts/regression-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
if ($SessionFile) {
    $sessionFile = (Resolve-Path -LiteralPath $SessionFile).Path
    $existing = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json
    $process = Get-Process -Id $existing.pid
    if ($process.Path -ne $Exe) { throw 'The existing session does not belong to the requested executable.' }
    $null = $process.Handle
} else {
    $sessionFile = Join-Path $run 'session/native-session.json'
    $process = & "$root/start-plugin.ps1" -Exe $Exe -ScorePath $fixture -SessionFile $sessionFile -PassThru
}
$descriptor = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json
$loadedBinaries = @($process.Modules | Where-Object ModuleName -In @('guitarpro_mcp.dll','guitarpro_mcp_autoload.dll') | ForEach-Object {
    @{name=$_.ModuleName;path=$_.FileName;sha256=(Get-FileHash -LiteralPath $_.FileName).Hash}
})
if ($PackageDirectory) {
    $manifest = Get-Content -LiteralPath (Join-Path $PackageDirectory 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        $actual = @($loadedBinaries | Where-Object name -EQ ([IO.Path]::GetFileName($file.path)))
        if ($actual.Count -ne 1 -or $actual[0].sha256 -ne $file.sha256 -or
            $actual[0].path -ne (Join-Path (Split-Path -Parent $Exe) $file.path) -or
            (Get-FileHash -LiteralPath (Join-Path $PackageDirectory $file.path)).Hash -ne $file.sha256) {
            throw 'Loaded installation differs from the regression package.'
        }
    }
}
if (-not ('GpmcpRegressionProcess' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class GpmcpRegressionProcess {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
}
'@
}
$exitHandle = [GpmcpRegressionProcess]::OpenProcess(0x1000, $false, $process.Id)
if ($exitHandle -eq [IntPtr]::Zero) { throw 'Cannot retain a process handle for exit-code verification.' }
$exitCode = $null
Write-Output "Regression host PID $($process.Id). Session: $sessionFile"
$suites = @('mcp','native','editing','tracks','measures','effects','selection','saving','document-operations','document-tabs','lifecycle','session','structure','clipboard','tuplets','connections','notation','instruments','score-form','transfer','audio','p6','p8','p9','p10','p11','p12')
$results = @()
$fixtureRestorations = @()
$complete = $false
function Wait-FixtureOperation($connection, $request, [string]$expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if ($state.status -in @($expected,'error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($state.status -ne $expected) { throw "Fixture restore failed: $($state | ConvertTo-Json -Depth 5 -Compress)" }
    return $state
}
try {
    foreach ($suite in $suites) {
        $connection = New-McpSession -SessionFile $sessionFile
        try {
            $fixtureBefore = @((Invoke-McpTool $connection gp_documents).documents | Where-Object opened_path -EQ $fixture.Replace('\','/'))
            if ($fixtureBefore.Count -ne 1 -or $fixtureBefore[0].dirty) { throw 'Regression fixture is missing or dirty.' }
        } finally { Close-McpSession $connection }
        $parameters = @{SessionFile=$sessionFile}
        if ($suite -eq 'document-tabs') { $parameters.VerifyDocumentMenu = $true }
        if ($suite -eq 'audio' -and $env:GPMCP_DEVELOPMENT) { $parameters.Render = $true }
        if ($suite -eq 'p8') { $parameters.SkipFaults = -not [bool]$env:GPMCP_DEVELOPMENT }
        $output = @(& "$PSScriptRoot/test-$suite.ps1" @parameters | Tee-Object -FilePath (Join-Path $run "$suite.log"))
        $pass = @($output | Where-Object { $_ -match '^PASS:\s*(\d+)' })
        if ($pass.Count -ne 1 -or $pass[0] -notmatch '^PASS:\s*(\d+)') { throw "No unambiguous passing result from $suite." }
        $results += [pscustomobject]@{suite=$suite;checks=[int]$Matches[1];result=$pass[0]}
        Write-Output $pass[0]
        $connection = New-McpSession -SessionFile $sessionFile
        try {
            $documents = Invoke-McpTool $connection gp_documents
            if (@($documents.documents | Where-Object dirty).Count) { throw 'Suite left unsaved documents; host retained.' }
            if ((Get-FileHash -LiteralPath $fixture).Hash -ne $fixtureHash) { throw 'Suite changed fixture file bytes.' }
            if (-not @($documents.documents | Where-Object opened_path -EQ $fixture.Replace('\','/')).Count) {
                $adopted = @($documents.documents | Where-Object id -EQ $fixtureBefore[0].id)
                $artifactRoot = [IO.Path]::GetFullPath((Join-Path $root 'artifacts')) + '\'
                if ($adopted.Count -ne 1 -or -not $adopted[0].save_path -or -not [IO.Path]::GetFullPath($adopted[0].save_path).StartsWith($artifactRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Cannot identify the saved regression fixture.' }
                $others = @($documents.documents | Where-Object id -NE $adopted[0].id | Sort-Object id | Select-Object id,opened_path,save_path,dirty)
                $close = Invoke-McpTool $connection gp_close @{document=$adopted[0].id}
                Wait-FixtureOperation $connection $close.request 'closed' | Out-Null
                $open = Invoke-McpTool $connection gp_open @{path=$fixture}
                $opened = Wait-FixtureOperation $connection $open.request 'opened'
                $after = (Invoke-McpTool $connection gp_documents).documents
                $restored = @($after | Where-Object id -EQ $opened.document)
                if ($restored.Count -ne 1 -or $restored[0].dirty -or $restored[0].opened_path -ne $fixture.Replace('\','/')) { throw 'Fixture reopen did not restore the expected document.' }
                $othersAfter = @($after | Where-Object id -NE $opened.document | Sort-Object id | Select-Object id,opened_path,save_path,dirty)
                if ((ConvertTo-Json -InputObject $others -Compress) -ne (ConvertTo-Json -InputObject $othersAfter -Compress)) { throw 'Fixture restore changed another document.' }
                $fixtureRestorations += @{suite=$suite;closed=$adopted[0].id;saved_path=$adopted[0].save_path;reopened=$opened.document}
            }
        } finally { Close-McpSession $connection }
    }
    $connection = New-McpSession -SessionFile $sessionFile
    try {
        $documents = Invoke-McpTool $connection gp_documents
        if (@($documents.documents | Where-Object dirty).Count) { throw 'Regression left unsaved changes; host retained.' }
        $window = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
        $main = @($window.objects | Where-Object class -EQ 'gp::gui::MainWindow')
        try { Invoke-McpTool $connection gp_close_window @{snapshot=$window.snapshot;id=$main[0].id} | Out-Null }
        catch { if (-not $process.WaitForExit(5000)) { throw } }
        if (-not $process.WaitForExit(60000)) { throw 'Regression host did not exit.' }
        [uint32]$nativeExitCode = 0
        if (-not [GpmcpRegressionProcess]::GetExitCodeProcess($exitHandle, [ref]$nativeExitCode)) { throw 'Cannot read the regression host exit code.' }
        $exitCode = $nativeExitCode
        if ($exitCode -ne 0) { throw "Regression host failed clean shutdown: $exitCode" }
        if (Test-Path -LiteralPath $sessionFile) { throw 'Regression host left a stale session descriptor.' }
        $complete = $true
    } finally { if (-not $process.HasExited) { Close-McpSession $connection } }
} finally {
    $hashes = @(Get-ChildItem -LiteralPath @((Join-Path $root 'native'),$PSScriptRoot) -File | Where-Object Extension -In @('.h','.cpp','.ps1','.def','.json') | Get-FileHash | Select-Object Path,Hash)
    @{complete=$complete;host_pid=$descriptor.pid;exit_code=$exitCode;checks=($results | Measure-Object -Property checks -Sum).Sum;suites=$results;fixture_restorations=$fixtureRestorations;sources=$hashes;powershell=$PSVersionTable.PSVersion.ToString();package=$PackageDirectory;loaded_binaries=$loadedBinaries;plugin_sha256=($loadedBinaries | Where-Object name -EQ 'guitarpro_mcp.dll').sha256;autoload_sha256=($loadedBinaries | Where-Object name -EQ 'guitarpro_mcp_autoload.dll').sha256;host_exe=$Exe;host_sha256=(Get-FileHash -LiteralPath $Exe).Hash} |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $run 'regression.json') -Encoding UTF8
    if (-not $process.HasExited) { Write-Warning "Regression host retained for inspection: PID $($process.Id), session $sessionFile" }
    $process.Dispose()
    [GpmcpRegressionProcess]::CloseHandle($exitHandle) | Out-Null
}
Write-Output "Complete regression evidence: $run"
