param([string]$Version = '0.3.0')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][A-Za-z0-9.]+)?$') { throw 'Invalid package version.' }
$output = Join-Path $PSScriptRoot ('artifacts/GuitarProMCP-' + $Version + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $output | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '.tools/native/plugins') -Destination $output -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-plugin.ps1'),(Join-Path $PSScriptRoot 'Install.cmd'),(Join-Path $PSScriptRoot 'start-installed.ps1'),(Join-Path $PSScriptRoot 'INSTALL.md'),(Join-Path $PSScriptRoot 'native/supported-host.json'),(Join-Path $PSScriptRoot 'native/mcp-client.ps1') -Destination $output
$files = @(Get-ChildItem -LiteralPath (Join-Path $output 'plugins') -File -Recurse | ForEach-Object {
    [pscustomobject]@{path=$_.FullName.Substring($output.Length + 1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
@{product='GuitarProMCP';version=$Version;files=$files} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'package.json') -Encoding UTF8
Compress-Archive -Path (Join-Path $output '*') -DestinationPath "$output.zip"
Write-Output "Package: $output.zip"
