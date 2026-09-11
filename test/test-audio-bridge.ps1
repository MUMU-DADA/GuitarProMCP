param([string]$Provider = "$PSScriptRoot/../.tools/native/plugins/generic/guitarpro_mcp.dll",
      [string]$Fixture = "$PSScriptRoot/../.tools/audio-bridge-probe/audio-bridge-provider-fixture.dll",
      [string]$HostDirectory = 'C:\Program Files\Arobas Music\Guitar Pro 8')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$probe = Join-Path $root '.tools/audio-bridge-probe/audio-bridge-probe.exe'
if (-not (Test-Path -LiteralPath $probe)) { throw 'Build the audio bridge probe first.' }
$run = Join-Path $root ('artifacts/native-audio-bridge-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$providerPath = [IO.Path]::GetFullPath($Provider)
$fixturePath = [IO.Path]::GetFullPath($Fixture)
$missing = Join-Path $run 'missing-provider.dll'
$checks = @()
$oldPath = $env:PATH
try {
    if (Test-Path -LiteralPath $HostDirectory) { $env:PATH = "$HostDirectory;$oldPath" }
    $fixture = @(& $probe $fixturePath 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($fixture -join "`n") -notmatch 'provider exports, ABI layout') { throw "Fixture provider probe failed: $($fixture -join ' ')" }
    $checks += 'loaded_provider_exports'
    $absent = @(& $probe $missing 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($absent -join "`n") -notmatch 'missing_provider=not_ready') { throw 'Missing-provider fallback failed.' }
    $checks += 'missing_provider_not_ready'
    $complete = $true
} finally {
    $env:PATH = $oldPath
    @{complete=$complete;checks=$checks;provider=$providerPath;provider_mode='requires_real_host_test';provider_sha256=(Get-FileHash -LiteralPath $providerPath -ErrorAction SilentlyContinue).Hash;fixture=$fixturePath;fixture_sha256=(Get-FileHash -LiteralPath $fixturePath -ErrorAction SilentlyContinue).Hash;missing_provider=$missing} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
}
Write-Output "PASS: $($checks.Count) audio bridge checks. Evidence: $run"
