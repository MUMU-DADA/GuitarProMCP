param([string]$QtDir = '')
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'native/build.ps1') -QtDir $QtDir
