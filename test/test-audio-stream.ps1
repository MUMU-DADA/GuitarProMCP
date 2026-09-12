param([string]$QtDir = "$PSScriptRoot/../.tools/qt/5.15.2/msvc2019_64", [string]$SessionFile, [switch]$Live)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$QtDir = (Resolve-Path -LiteralPath $QtDir).Path
$probe = Join-Path $root '.tools/audio-stream-probe/audio-stream-probe.exe'
$fixture = Join-Path $root '.tools/audio-stream-probe/audio-stream-provider-fixture.dll'
if (-not (Test-Path -LiteralPath $probe)) { & "$PSScriptRoot/build-audio-stream-probe.ps1" -QtDir $QtDir | Out-Host }
$run = Join-Path $root ('artifacts/native-audio-stream-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $run | Out-Null
$oldPath = $env:PATH
try {
    $env:PATH = "$QtDir/bin;$oldPath"
    $output = if ($Live) { @(& $probe --live 2>&1) } else { @(& $probe $fixture 2>&1) }
}
finally { $env:PATH = $oldPath }
if ($LASTEXITCODE -ne 0 -or (($output -join "`n") -notmatch '^PASS: P14 ABI v1' -and ($output -join "`n") -notmatch '^PASS: live WASAPI process loopback')) {
    @{complete=$false;output=$output} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    throw "P14 audio stream probe failed: $($output -join ' ')"
}
$checkCount = if ($Live) { 21 } else { 14 }
$captureScope = 'fixture_only'
if ($Live) {
    $scopeMatch = [regex]::Match(($output -join "`n"), 'scope=(?<scope>[A-Za-z0-9_]+)')
    if (-not $scopeMatch.Success) {
        @{complete=$false;output=$output;abi_version=1;live_capture=$true;reason='live_scope_missing'} |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
        throw "P14 live probe did not report capture scope: $($output -join ' ')"
    }
    $captureScope = $scopeMatch.Groups['scope'].Value
}
@{complete=$true;checks=$checkCount;output=$output;abi_version=1;live_capture=[bool]$Live;real_host_tap=$captureScope;capture_scope=$captureScope} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
Write-Output ("PASS: {0} P14 audio stream checks. Evidence: {1}" -f $checkCount, $run)
