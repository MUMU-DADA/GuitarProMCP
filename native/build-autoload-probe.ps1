param([string]$QtDir = "$PSScriptRoot/../.tools/qt/5.15.2/msvc2019_64")
$ErrorActionPreference = 'Stop'
$QtDir = (Resolve-Path -LiteralPath $QtDir).Path
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root '.tools/autoload-probe'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsInstall) { throw 'Visual Studio x64 C++ build tools are required.' }
Import-Module (Join-Path $vsInstall 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$includes = @("$QtDir/include", "$QtDir/include/QtCore", "$QtDir/include/QtGui", $output)
& "$QtDir/bin/moc.exe" ($includes | ForEach-Object { "-I$_" }) "$PSScriptRoot/autoload-probe.cpp" -o "$output/autoload-probe.moc"
if ($LASTEXITCODE) { throw 'Probe moc failed.' }
& cl /nologo /std:c++17 /EHsc /MD /O2 /LD /DQT_NO_DEBUG /DQT_PLUGIN ($includes | ForEach-Object { "/I$_" }) "$PSScriptRoot/autoload-probe.cpp" "/Fo$output/" "/Fe$output/guitarpro_mcp_probe.dll" /link "/LIBPATH:$QtDir/lib" Qt5Core.lib Qt5Gui.lib "/IMPLIB:$output/guitarpro_mcp_probe.lib"
if ($LASTEXITCODE) { throw 'Probe compilation failed.' }
