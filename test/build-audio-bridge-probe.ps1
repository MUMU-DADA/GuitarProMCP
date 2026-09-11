param([string]$QtDir = "$PSScriptRoot/../.tools/qt/5.15.2/msvc2019_64")
$ErrorActionPreference = 'Stop'
$QtDir = (Resolve-Path -LiteralPath $QtDir).Path
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root '.tools/audio-bridge-probe'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsInstall) { throw 'Visual Studio x64 C++ build tools are required.' }
Import-Module (Join-Path $vsInstall 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
& cl /nologo /std:c++17 /EHsc /MD /O2 /utf-8 /I"$root/native" "$PSScriptRoot/audio-bridge-probe.cpp" "/Fo$output/" "/Fe$output/audio-bridge-probe.exe"
if ($LASTEXITCODE) { throw 'Audio bridge probe compilation failed.' }
& cl /nologo /std:c++17 /EHsc /MD /O2 /utf-8 /I"$root/native" /LD "$PSScriptRoot/audio-bridge-provider-fixture.cpp" "/Fo$output/" "/Fe$output/audio-bridge-provider-fixture.dll"
if ($LASTEXITCODE) { throw 'Audio bridge provider fixture compilation failed.' }
$plugins = Join-Path $output 'plugins/generic'
New-Item -ItemType Directory -Force -Path $plugins | Out-Null
$includes = @("$QtDir/include", "$QtDir/include/QtCore", "$QtDir/include/QtGui", $output)
& "$QtDir/bin/moc.exe" ($includes | ForEach-Object { "-I$_" }) "$PSScriptRoot/audio-bridge-consumer.cpp" -o "$output/audio-bridge-consumer.moc"
if ($LASTEXITCODE) { throw 'Audio consumer moc failed.' }
& cl /nologo /std:c++17 /EHsc /MD /O2 /utf-8 /LD /DQT_NO_DEBUG /DQT_PLUGIN ($includes | ForEach-Object { "/I$_" }) "$PSScriptRoot/audio-bridge-consumer.cpp" "/Fo$output/" "/Fe$plugins/guitarpro_audio_consumer.dll" /link "/LIBPATH:$QtDir/lib" Qt5Core.lib Qt5Gui.lib "/IMPLIB:$output/guitarpro_audio_consumer.lib"
if ($LASTEXITCODE) { throw 'Audio consumer compilation failed.' }
Write-Output "Audio bridge probe: $output/audio-bridge-probe.exe"
