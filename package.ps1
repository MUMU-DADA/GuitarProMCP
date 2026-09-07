param([string]$Version = '0.3.0', [switch]$ManualInstall)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][A-Za-z0-9.]+)?$') { throw 'Invalid package version.' }
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'artifacts') | Out-Null
$variant = if ($ManualInstall) { '-manual' } else { '' }
$output = Join-Path $PSScriptRoot ('artifacts/GuitarProMCP-' + $Version + $variant + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $output | Out-Null
if ($ManualInstall) {
    $files = @(foreach ($relative in @('Plugins/generic/guitarpro_mcp.dll', 'Plugins/imageformats/guitarpro_mcp_autoload.dll')) {
        $target = Join-Path $output $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('.tools/native/' + $relative)) -Destination $target
        [pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash}
    })
    # Keep manual extraction compatible with the installer's file ownership checks.
    @{product='GuitarProMCP';version=$Version;files=$files;packaged_at=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'Plugins/guitarpro-mcp-install.json') -Encoding UTF8
    Compress-Archive -LiteralPath (Join-Path $output 'Plugins') -DestinationPath "$output.zip"
    Write-Output "Manual installation package: $output.zip"
    return
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '.tools/native/plugins') -Destination $output -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-plugin.ps1'),(Join-Path $PSScriptRoot 'Install.cmd'),(Join-Path $PSScriptRoot 'start-installed.ps1'),(Join-Path $PSScriptRoot 'INSTALL.md'),(Join-Path $PSScriptRoot 'native/supported-host.json'),(Join-Path $PSScriptRoot 'native/mcp-client.ps1') -Destination $output
$files = @(Get-ChildItem -LiteralPath (Join-Path $output 'plugins') -File -Recurse | ForEach-Object {
    [pscustomobject]@{path=$_.FullName.Substring($output.Length + 1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
@{product='GuitarProMCP';version=$Version;files=$files} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'package.json') -Encoding UTF8
Compress-Archive -Path (Join-Path $output '*') -DestinationPath "$output.zip"
Write-Output "Package: $output.zip"
