param([string]$HostDirectory = 'C:\Program Files\Arobas Music\Guitar Pro 8')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$probe = Join-Path $root '.tools/autoload-probe/guitarpro_mcp_probe.dll'
if (-not (Test-Path -LiteralPath $probe)) { throw 'Build the autoload probe first.' }
$run = Join-Path $root ('artifacts/autoload-probe-' + [guid]::NewGuid().ToString('N'))
$hostCopy = Join-Path $root ('.tools/autoload-host-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run,$hostCopy | Out-Null
Get-ChildItem -LiteralPath $HostDirectory -File | Where-Object { $_.Extension -in '.dll','.conf' -or $_.Name -eq 'GuitarPro.exe' } | Copy-Item -Destination $hostCopy
Copy-Item -LiteralPath (Join-Path $HostDirectory 'Plugins') -Destination $hostCopy -Recurse
Copy-Item -LiteralPath (Join-Path $HostDirectory 'translations') -Destination $hostCopy -Recurse
$installedProbe = Join-Path $hostCopy 'Plugins/imageformats/guitarpro_mcp_probe.dll'
Copy-Item -LiteralPath $probe -Destination $installedProbe
$exe = Join-Path $hostCopy 'GuitarPro.exe'
$shortcutPath = Join-Path $run 'Guitar Pro.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = $hostCopy
$shortcut.Save()
$resultPath = Join-Path $hostCopy 'autoload-probe-result.json'
$originalEnvironment = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_SESSION_FILE','QT_DEBUG_PLUGINS','TEMP','TMP')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$results = @()
try {
    Remove-Item Env:QT_PLUGIN_PATH,Env:QT_QPA_GENERIC_PLUGINS,Env:GPMCP_SESSION_FILE -ErrorAction SilentlyContinue
    $env:TEMP = $run
    $env:TMP = $run
    $env:QT_DEBUG_PLUGINS = '1'
    foreach ($variant in @('direct','shortcut','score','uninstalled')) {
        if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath }
        if ($variant -eq 'uninstalled') { Remove-Item -LiteralPath $installedProbe }
        $launch = @{FilePath=$exe; WorkingDirectory=$hostCopy; WindowStyle='Hidden'; PassThru=$true; RedirectStandardError=(Join-Path $run "$variant.stderr.log")}
        if ($variant -eq 'shortcut') { $launch.FilePath = $shortcutPath; $launch.Remove('RedirectStandardError') }
        if ($variant -eq 'score') { $launch.ArgumentList = @('--open', ('"' + (Join-Path $PSScriptRoot 'testdata/minimal.gp') + '"')) }
        $process = Start-Process @launch
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            do {
                Start-Sleep -Milliseconds 200
                $process.Refresh()
            } while (-not $process.HasExited -and -not (Test-Path -LiteralPath $resultPath) -and [DateTime]::UtcNow -lt $deadline)
            $loaded = Test-Path -LiteralPath $resultPath
            $observation = if ($loaded) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
            $results += [pscustomobject]@{variant=$variant;pid=$process.Id;loaded=$loaded;exited=$process.HasExited;observation=$observation}
            if ($loaded -and ($observation.pid -ne $process.Id -or $observation.generic_environment)) { throw 'Probe identity/environment mismatch.' }
            if ($variant -ne 'uninstalled' -and -not $loaded) { throw "Automatic loading failed for $variant. See $run" }
            if ($variant -eq 'uninstalled' -and ($loaded -or $process.HasExited)) { throw 'Uninstall did not restore normal startup.' }
        } finally {
            # This isolated process only ran the read-only probe, never edits.
            if (-not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit(5000) | Out-Null }
            $process.Dispose()
        }
    }
} finally {
    foreach ($name in $originalEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
    }
    @{host_directory=$hostCopy;host_sha256=(Get-FileHash -LiteralPath $exe).Hash;probe_sha256=(Get-FileHash -LiteralPath $probe).Hash;results=$results} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
}
Write-Output "PASS: direct EXE, Windows shortcut, score argument and uninstall startup. Evidence: $run"
