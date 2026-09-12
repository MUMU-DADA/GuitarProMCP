param([string]$QtDir = "$PSScriptRoot/../.tools/qt/5.15.2/msvc2019_64", [string]$SessionFile)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$QtDir = (Resolve-Path -LiteralPath $QtDir).Path
$probe = Join-Path $root '.tools/audio-stream-probe/audio-stream-probe.exe'
$fixture = Join-Path $root '.tools/audio-stream-probe/audio-stream-provider-fixture.dll'
if (-not (Test-Path -LiteralPath $probe)) { & "$PSScriptRoot/build-audio-stream-probe.ps1" -QtDir $QtDir | Out-Host }
$run = Join-Path $root ('artifacts/native-audio-stream-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $run | Out-Null
$oldPath = $env:PATH
try { $env:PATH = "$QtDir/bin;$oldPath"; $output = @(& $probe $fixture 2>&1) }
finally { $env:PATH = $oldPath }
if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch '^PASS: P14 ABI v1') {
    @{complete=$false;output=$output} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    throw "P14 audio stream probe failed: $($output -join ' ')"
}
@{complete=$true;checks=12;output=$output;abi_version=1;real_host_tap='host_limited';reason='no_verified_realtime_tap'} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
Write-Output "PASS: 12 P14 audio stream checks. Evidence: $run"
