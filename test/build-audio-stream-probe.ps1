param([string]$QtDir = "$PSScriptRoot/../.tools/qt/5.15.2/msvc2019_64")
$ErrorActionPreference = 'Stop'
$QtDir = (Resolve-Path -LiteralPath $QtDir).Path
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root '.tools/audio-stream-probe'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsInstall) { throw 'Visual Studio x64 C++ build tools are required.' }
Import-Module (Join-Path $vsInstall 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$version = & "$QtDir/bin/qmake.exe" -query QT_VERSION
if ($LASTEXITCODE -or $version -notmatch '^5\.\d+\.\d+$') { throw 'Cannot determine Qt header version.' }
$includes = @("$QtDir/include", "$QtDir/include/QtCore", "$QtDir/include/QtGui", "$QtDir/include/QtWidgets", "$QtDir/include/QtNetwork", "$QtDir/include/QtPrintSupport", "$QtDir/include/QtCore/$version", "$QtDir/include/QtCore/$version/QtCore", "$QtDir/include/QtGui/$version", "$QtDir/include/QtGui/$version/QtGui", "$root/native")
& cl /nologo /std:c++17 /EHsc /MD /O2 /utf-8 /DQT_NO_DEBUG ($includes | ForEach-Object { "/I$_" }) "$PSScriptRoot/audio-stream-probe.cpp" "/Fo$output/" "/Fe$output/audio-stream-probe.exe" /link "/LIBPATH:$QtDir/lib" Qt5Core.lib Qt5Gui.lib Qt5Widgets.lib Qt5Network.lib Qt5PrintSupport.lib
if ($LASTEXITCODE) { throw 'Audio stream probe compilation failed.' }
& cl /nologo /std:c++17 /EHsc /MD /O2 /utf-8 /LD "/I$root/native" "$PSScriptRoot/audio-stream-provider-fixture.cpp" "/Fo$output/" "/Fe$output/audio-stream-provider-fixture.dll"
if ($LASTEXITCODE) { throw 'Audio stream provider fixture compilation failed.' }
Write-Output "Audio stream probe: $output/audio-stream-probe.exe"
