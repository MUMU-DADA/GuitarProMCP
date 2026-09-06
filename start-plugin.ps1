param(
    [string]$ScorePath = '',
    [string]$Exe = 'C:\Program Files\Arobas Music\Guitar Pro 8\GuitarPro.exe',
    [string]$SessionFile = '',
    [switch]$Visible,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
$pluginRoot = Join-Path $PSScriptRoot '.tools/native/plugins'
$pluginDll = Join-Path $pluginRoot 'generic/guitarpro_mcp.dll'
if (-not (Test-Path -LiteralPath $pluginDll)) { throw '请先运行 ./native/build.ps1 编译插件。' }
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw '未找到 Guitar Pro 可执行文件。' }
if (-not $SessionFile) { $SessionFile = Join-Path $PSScriptRoot '.cache/native-session.json' }
$SessionFile = [IO.Path]::GetFullPath($SessionFile)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SessionFile),(Join-Path $PSScriptRoot '.cache/tmp') | Out-Null
if (Test-Path -LiteralPath $SessionFile) {
    $previous = Get-Content -LiteralPath $SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($previous.pid -and (Get-Process -Id $previous.pid -ErrorAction SilentlyContinue)) {
        throw "该会话已有运行中的进程（PID $($previous.pid)）。请使用现有插件，或为新实例指定不同的 -SessionFile。"
    }
}
$originalEnvironment = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_SESSION_FILE','GPMCP_BACKGROUND','GPMCP_DATA_DIR','TEMP','TMP')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $env:QT_PLUGIN_PATH = if ($env:QT_PLUGIN_PATH) { "$pluginRoot;$env:QT_PLUGIN_PATH" } else { $pluginRoot }
    $env:QT_QPA_GENERIC_PLUGINS = 'guitarpro_mcp'
    $env:GPMCP_SESSION_FILE = $SessionFile
    $env:GPMCP_DATA_DIR = Split-Path -Parent $SessionFile
    $env:GPMCP_BACKGROUND = if ($Visible) { '0' } else { '1' }
    $env:TEMP = Join-Path $PSScriptRoot '.cache/tmp'
    $env:TMP = $env:TEMP
    $launch = @{FilePath=$Exe; WorkingDirectory=(Split-Path -Parent $Exe); PassThru=$true; WindowStyle='Hidden'; RedirectStandardError=(Join-Path $PSScriptRoot '.cache/plugin-start.stderr.log')}
    if ($ScorePath) {
        $resolvedScore = (Resolve-Path -LiteralPath $ScorePath).Path
        $launch.ArgumentList = @('--open', "`"$resolvedScore`"")
    }
    $application = Start-Process @launch
    $null = $application.Handle
} finally {
    foreach ($name in $originalEnvironment.Keys) {
        if ($null -eq $originalEnvironment[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process') }
    }
}
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $SessionFile) {
        $session = Get-Content -LiteralPath $SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($session.pid -eq $application.Id -and $session.backend -eq 'in_process_qt_plugin') {
            if ($PassThru) { return $application }
            Write-Output "插件已加载到 Guitar Pro 进程：PID $($session.pid)，Qt $($session.qt_version)"
            Write-Output "会话文件：$SessionFile"
            return
        }
    }
    if ($application.HasExited) { throw 'Guitar Pro 在插件就绪前退出，请查看 .cache/plugin-start.stderr.log。' }
    Start-Sleep -Milliseconds 200
}
throw '未观察到插件就绪；进程仍保留，请检查 .cache/plugin-start.stderr.log 和软件窗口。'
