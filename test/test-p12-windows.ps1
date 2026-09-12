param([string]$QtDir = "$PSScriptRoot/../.tools/qt/5.15.2/msvc2019_64", [switch]$NativeFrame)
$ErrorActionPreference = 'Stop'
$QtDir = (Resolve-Path -LiteralPath $QtDir).Path
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root '.tools/p12-windows'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsInstall) { throw 'Visual Studio x64 C++ build tools are required.' }
Import-Module (Join-Path $vsInstall 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
& cl /nologo /std:c++17 /EHsc /MD /O2 /utf-8 /DQT_NO_DEBUG "/I$QtDir/include" "/I$root/native" "$PSScriptRoot/p12-windows.cpp" "/Fo$output/" "/Fe$output/p12-windows.exe" /link "/LIBPATH:$QtDir/lib" Qt5Core.lib Qt5Gui.lib Qt5Widgets.lib User32.lib Gdi32.lib
if ($LASTEXITCODE) { throw 'P12 fixture build failed.' }
$previousPath = $env:PATH
$previousScale = $env:QT_SCALE_FACTOR
$previousPlugins = $env:QT_PLUGIN_PATH
try {
    $env:PATH = "$QtDir/bin;$env:PATH"
    $env:QT_PLUGIN_PATH = "$QtDir/plugins"
    foreach ($scale in @('1','1.5')) {
        $env:QT_SCALE_FACTOR = $scale
        if ($NativeFrame) { & "$output/p12-windows.exe" -platform windows --native-frame }
        else { & "$output/p12-windows.exe" -platform offscreen }
        if ($LASTEXITCODE) { throw "P12 Qt fixture failed at scale $scale." }
    }
} finally {
    $env:PATH = $previousPath; $env:QT_SCALE_FACTOR = $previousScale; $env:QT_PLUGIN_PATH = $previousPlugins
}
