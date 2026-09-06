param([string]$Exe = 'C:\Program Files\Arobas Music\Guitar Pro 8\GuitarPro.exe')
$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/mcp-client.ps1"
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
$sessionFile = Join-Path $run 'session/native-session.json'
$process = & "$root/start-plugin.ps1" -Exe $Exe -ScorePath $fixture -SessionFile $sessionFile -PassThru
$descriptor = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json
Write-Output "Regression host PID $($process.Id). Session: $sessionFile"
$suites = @('mcp','native','editing','tracks','measures','effects','selection','saving','document-operations','lifecycle','session','structure','clipboard','tuplets','connections')
$results = @()
$complete = $false
try {
    foreach ($suite in $suites) {
        $output = @(& "$PSScriptRoot/test-$suite.ps1" -SessionFile $sessionFile | Tee-Object -FilePath (Join-Path $run "$suite.log"))
        $pass = @($output | Where-Object { $_ -match '^PASS:\s*(\d+)' })
        if ($pass.Count -ne 1 -or $pass[0] -notmatch '^PASS:\s*(\d+)') { throw "No unambiguous passing result from $suite." }
        $results += [pscustomobject]@{suite=$suite;checks=[int]$Matches[1];result=$pass[0]}
        Write-Output $pass[0]
    }
    $connection = New-McpSession -SessionFile $sessionFile
    try {
        $documents = Invoke-McpTool $connection gp_documents
        if (@($documents.documents | Where-Object dirty).Count) { throw 'Regression left unsaved changes; host retained.' }
        $window = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
        $main = @($window.objects | Where-Object class -EQ 'gp::gui::MainWindow')
        try { Invoke-McpTool $connection gp_close_window @{snapshot=$window.snapshot;id=$main[0].id} | Out-Null }
        catch { if (-not $process.WaitForExit(5000)) { throw } }
        if (-not $process.WaitForExit(60000) -or $process.ExitCode -ne 0) { throw 'Regression host failed clean shutdown.' }
        if (Test-Path -LiteralPath $sessionFile) { throw 'Regression host left a stale session descriptor.' }
        $complete = $true
    } finally { if (-not $process.HasExited) { Close-McpSession $connection } }
} finally {
    $sourceFiles = @('guitarpro_mcp.cpp','guitarpro_api.h','guitarpro_abi.h','guitarpro_clipboard.h','mcp_server.cpp','object_registry.h','host_build.h','plugin_config.h','autoload.cpp','plugin_status.h')
    $hashes = @($sourceFiles | ForEach-Object { Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_) | Select-Object Path,Hash })
    @{complete=$complete;host_pid=$descriptor.pid;exit_code=$(if($process.HasExited){$process.ExitCode}else{$null});checks=($results | Measure-Object -Property checks -Sum).Sum;suites=$results;sources=$hashes;plugin_sha256=(Get-FileHash -LiteralPath "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash;autoload_sha256=(Get-FileHash -LiteralPath "$root/.tools/native/plugins/imageformats/guitarpro_mcp_autoload.dll").Hash;host_exe=$Exe;host_sha256=(Get-FileHash -LiteralPath $Exe).Hash} |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $run 'regression.json')
    if (-not $process.HasExited) { Write-Warning "Regression host retained for inspection: PID $($process.Id), session $sessionFile" }
    $process.Dispose()
}
Write-Output "Complete regression evidence: $run"
