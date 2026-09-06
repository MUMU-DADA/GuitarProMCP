param([string]$QtDir = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $QtDir) { $QtDir = Join-Path $projectRoot '.tools/qt/5.15.2/msvc2019_64' }
$QtDir = (Resolve-Path -LiteralPath $QtDir).Path
$buildDir = Join-Path $projectRoot '.tools/native/build'
$pluginDir = Join-Path $projectRoot '.tools/native/plugins/generic'
New-Item -ItemType Directory -Force -Path $buildDir,$pluginDir,(Join-Path $projectRoot '.cache/tmp') | Out-Null
$env:TEMP = Join-Path $projectRoot '.cache/tmp'
$env:TMP = $env:TEMP
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsInstall) { throw '需要安装 Visual Studio x64 C++ 构建工具。' }
Import-Module (Join-Path $vsInstall 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
& lib /nologo /machine:x64 "/def:$PSScriptRoot/gpcore.def" "/out:$buildDir/GPCore.lib"
if ($LASTEXITCODE -ne 0) { throw '生成 GPCore 导入库失败。' }
& lib /nologo /machine:x64 "/def:$PSScriptRoot/gprse.def" "/out:$buildDir/GPRSE.lib"
if ($LASTEXITCODE -ne 0) { throw '生成 GPRSE 导入库失败。' }
$includeDirs = @((Join-Path $QtDir 'include'), (Join-Path $QtDir 'include/QtCore'), (Join-Path $QtDir 'include/QtGui'), (Join-Path $QtDir 'include/QtWidgets'), (Join-Path $QtDir 'include/QtNetwork'), $buildDir)
$mocIncludes = $includeDirs | ForEach-Object { "-I$_" }
$source = Join-Path $PSScriptRoot 'guitarpro_mcp.cpp'
& (Join-Path $QtDir 'bin/moc.exe') @mocIncludes $source -o (Join-Path $buildDir 'guitarpro_mcp.moc')
if ($LASTEXITCODE -ne 0) { throw 'Qt moc 生成失败。' }
$clIncludes = $includeDirs | ForEach-Object { "/I$_" }
& cl /nologo /std:c++17 /EHsc /MD /O2 /utf-8 /LD /DQT_NO_DEBUG /DQT_PLUGIN @clIncludes $source (Join-Path $PSScriptRoot 'mcp_server.cpp') "/Fo$buildDir/" "/Fd$buildDir/guitarpro_mcp.pdb" "/Fe$pluginDir/guitarpro_mcp.dll" /link "/LIBPATH:$QtDir/lib" Qt5Core.lib Qt5Gui.lib Qt5Widgets.lib Qt5Network.lib User32.lib "$buildDir/GPCore.lib" "$buildDir/GPRSE.lib" "/IMPLIB:$buildDir/guitarpro_mcp.lib"
if ($LASTEXITCODE -ne 0) { throw '原生插件编译失败。' }
Write-Output "插件已生成：$pluginDir/guitarpro_mcp.dll"
$autoloadDir = Join-Path $projectRoot '.tools/native/plugins/imageformats'
New-Item -ItemType Directory -Force -Path $autoloadDir | Out-Null
& (Join-Path $QtDir 'bin/moc.exe') @mocIncludes (Join-Path $PSScriptRoot 'autoload.cpp') -o (Join-Path $buildDir 'autoload.moc')
if ($LASTEXITCODE -ne 0) { throw 'Autoload moc failed.' }
& cl /nologo /std:c++17 /EHsc /MD /O2 /LD /DQT_NO_DEBUG /DQT_PLUGIN @clIncludes (Join-Path $PSScriptRoot 'autoload.cpp') "/Fo$buildDir/" "/Fe$autoloadDir/guitarpro_mcp_autoload.dll" /link "/LIBPATH:$QtDir/lib" Qt5Core.lib Qt5Gui.lib Qt5Widgets.lib "/IMPLIB:$buildDir/guitarpro_mcp_autoload.lib"
if ($LASTEXITCODE -ne 0) { throw 'Autoload compilation failed.' }


