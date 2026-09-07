param([string]$QtDir = "$PSScriptRoot/../.tools/qt/5.15.2/msvc2019_64")
$ErrorActionPreference = 'Stop'
$QtDir = (Resolve-Path -LiteralPath $QtDir).Path
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root '.tools/save-fault-probe'
$plugins = Join-Path $output 'plugins/generic'
New-Item -ItemType Directory -Force -Path $output,$plugins | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsInstall) { throw 'Visual Studio x64 C++ build tools are required.' }
Import-Module (Join-Path $vsInstall 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$version = & "$QtDir/bin/qmake.exe" -query QT_VERSION
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^5\.\d+\.\d+$') { throw 'Cannot determine Qt header version.' }
$includes = @("$QtDir/include", "$QtDir/include/QtCore", "$QtDir/include/QtGui", "$QtDir/include/QtWidgets", "$QtDir/include/QtCore/$version", "$QtDir/include/QtCore/$version/QtCore", "$QtDir/include/QtGui/$version", "$QtDir/include/QtGui/$version/QtGui", $output)
& "$QtDir/bin/moc.exe" ($includes | ForEach-Object { "-I$_" }) "$PSScriptRoot/save-fault-probe.cpp" -o "$output/save-fault-probe.moc"
if ($LASTEXITCODE) { throw 'Save fault probe moc failed.' }
& cl /nologo /std:c++17 /EHsc /MD /O2 /LD /DQT_NO_DEBUG /DQT_PLUGIN ($includes | ForEach-Object { "/I$_" }) "$PSScriptRoot/save-fault-probe.cpp" "/Fo$output/" "/Fe$plugins/guitarpro_save_fault_probe.dll" /link "/LIBPATH:$QtDir/lib" Qt5Core.lib Qt5Gui.lib Qt5Widgets.lib User32.lib "$root/.tools/native/build/GPCore.lib" "/IMPLIB:$output/guitarpro_save_fault_probe.lib"
if ($LASTEXITCODE) { throw 'Save fault probe compilation failed.' }
