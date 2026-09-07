$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root '.tools/dde-client'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsInstall) { throw 'Visual Studio x64 C++ build tools are required.' }
Import-Module (Join-Path $vsInstall 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
& cl /nologo /std:c++17 /EHsc /O2 "$PSScriptRoot/dde-open.cpp" "/Fo$output/dde-open.obj" "/Fe$output/dde-open.exe" /link User32.lib
if ($LASTEXITCODE) { throw 'DDE test client compilation failed.' }
