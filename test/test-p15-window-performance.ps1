param(
    [string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json",
    [switch]$RequireDwm
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-p15-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$checks = 0; $complete = $false; $hostLimited = @(); $samples = @()
function Check($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Raw([string]$operation, [hashtable]$arguments) {
    $result = Invoke-McpTool $connection gp_window_performance $arguments -AllowError
    Check ($result.instance_id -eq $connection.InstanceId -or $result.reason -in @('invalid_sample_ms','invalid_operation','foreign_instance','monitor_not_found','session_limit','window_mismatch','dwm_timing_unavailable','source_unavailable','etw_not_available')) "Unexpected P15 instance result for $operation."
    return $result
}
try {
    $catalog = Invoke-McpTool $connection gp_capabilities
    $tools = Invoke-McpTool $connection gp_windows
    Check (@($tools.windows | Where-Object kind -EQ 'main').Count -ge 1) 'P15 requires an observed main window.'
    $main = @($tools.windows | Where-Object kind -EQ 'main')[0]
    $initialVisible = [bool]$main.visible
    $initialMinimized = [bool]$main.minimized
    $before = @{foreground=$catalog.foreground_window.handle; pid=$catalog.foreground_pid; windows=$tools.windows.window_id -join ','}
    $listBody = @{jsonrpc='2.0';id=3;method='tools/list';params=@{}} | ConvertTo-Json -Depth 10 -Compress
    $list = Invoke-WebRequest -UseBasicParsing -Uri $connection.Url -Method Post -Headers $connection.Headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($listBody)) -TimeoutSec 15
    Check (@(($list.Content | ConvertFrom-Json).result.tools | Where-Object name -EQ 'gp_window_performance').Count -eq 1) 'gp_window_performance is missing from tools/list.'

    $invalid = Raw 'invalid' @{operation='start';window_id=$main.window_id;sample_ms=249}
    Check ($invalid.reason -eq 'invalid_sample_ms') 'sample_ms lower bound was not enforced.'
    $start = Raw 'start' @{operation='start';window_id=$main.window_id;sample_ms=250;source='auto'}
    Check ($start.monitor_id -and $start.window_id -eq $main.window_id -and $start.requested_source -eq 'auto') 'P15 start did not bind the requested window.'
    Check ($start.measurement_source -in @('dwm_timing','qt_paint','screen_refresh')) 'P15 selected an unknown measurement source.'
    $samples += $start
    Start-Sleep -Milliseconds 400
    $snapshot = Raw 'snapshot' @{operation='snapshot';monitor_id=$start.monitor_id}
    Check ($snapshot.window_id -eq $main.window_id -and $snapshot.sample_duration_ms -ge 250) 'P15 snapshot duration or target is wrong.'
    Check ($snapshot.status -in @('running','completed','not_observed','host_limited')) 'P15 snapshot returned an invalid status.'
    Check ($snapshot.observation_status -in @('observed','qt_only','not_observed','host_limited')) 'P15 observation status is not explicit.'
    Check ($snapshot.refresh_rate_hz -eq $null -or $snapshot.refresh_rate_hz -gt 0) 'P15 refresh rate is invalid.'
    if ($snapshot.measurement_source -ne 'dwm_timing') { Check ($snapshot.presented_fps -eq $null -and $snapshot.displayed_fps -eq $null) 'Display FPS was reported without DWM source.' }
    $samples += $snapshot
    $stop = Raw 'stop' @{operation='stop';monitor_id=$start.monitor_id}
    Check ($stop.window_id -eq $main.window_id -and $stop.status -ne 'running') 'P15 stop did not return a terminal state.'
    $midCap = Invoke-McpTool $connection gp_capabilities
    Check ($before.foreground -eq $midCap.foreground_window.handle -and $before.pid -eq $midCap.foreground_pid) 'P15 sampling changed foreground focus.'
    $expired = Raw 'expired' @{operation='snapshot';monitor_id=$start.monitor_id}
    Check ($expired.reason -eq 'monitor_not_found') 'Stopped P15 monitor remained usable.'
    $missing = Raw 'missing' @{operation='snapshot';monitor_id=''}
    Check ($missing.reason -eq 'monitor_not_found') 'Missing P15 monitor ID was misclassified.'

    $short = Raw 'short-start' @{operation='start';window_id=$main.window_id;sample_ms=10000;source='qt_paint'}
    $shortStop = Raw 'short-stop' @{operation='stop';monitor_id=$short.monitor_id}
    Check ($shortStop.status -in @('completed','not_observed','host_limited') -and $shortStop.sample_duration_ms -lt 10000) 'P15 short stop did not finalize a bounded sample.'

    $limitSessions = @()
    foreach ($index in 1..4) {
        $limitSessions += Raw ('limit-start-' + $index) @{operation='start';window_id=$main.window_id;sample_ms=10000;source='qt_paint'}
    }
    Check ($limitSessions.Count -eq 4 -and @($limitSessions | Where-Object monitor_id).Count -eq 4) 'P15 did not accept four bounded sessions.'
    $fifth = Raw 'limit-fifth' @{operation='start';window_id=$main.window_id;sample_ms=10000;source='qt_paint'}
    Check ($fifth.reason -eq 'session_limit') 'P15 session limit was not enforced.'
    foreach ($session in $limitSessions) {
        $limitStop = Raw 'limit-stop' @{operation='stop';monitor_id=$session.monitor_id}
        Check ($limitStop.status -in @('completed','not_observed','host_limited')) 'P15 limit session did not stop cleanly.'
    }

    $etw = Raw 'etw' @{operation='start';window_id=$main.window_id;sample_ms=250;source='etw'}
    Check ($etw.status -eq 'host_limited' -and $etw.reason -eq 'etw_not_available') 'Unavailable ETW was not reported as host_limited.'

    $screen = Raw 'screen' @{operation='start';window_id=$main.window_id;sample_ms=250;source='screen'}
    Check ($screen.measurement_source -eq 'screen_refresh' -and $screen.status -in @('not_observed','running','completed')) 'Screen reference source was not explicitly separated.'
    $screenStop = Raw 'screen-stop' @{operation='stop';monitor_id=$screen.monitor_id}
    Check ($screenStop.measurement_source -eq 'screen_refresh' -and $screenStop.status -eq 'not_observed' -and $screenStop.presented_fps -eq $null -and $screenStop.displayed_fps -eq $null) 'Screen source was used as display FPS.'

    Invoke-McpTool $connection gp_window @{state='hide'} | Out-Null
    $hidden = Raw 'hidden' @{operation='start';window_id=$main.window_id;sample_ms=250;source='dwm'}
    if ($hidden.monitor_id) {
        Start-Sleep -Milliseconds 300
        $hiddenStop = Raw 'hidden-stop' @{operation='stop';monitor_id=$hidden.monitor_id}
        Check (-not $hiddenStop.visible -and $hiddenStop.status -in @('not_observed','host_limited','completed')) 'Hidden window visibility/status was not preserved.'
    } else { Check ($hidden.status -in @('host_limited','not_observed')) 'Hidden DWM source failed without an explicit limitation.' }
    Invoke-McpTool $connection gp_window @{state='restore'} | Out-Null
    if (-not $initialVisible) {
        Invoke-McpTool $connection gp_window @{state='hide'} -AllowError | Out-Null
    } elseif ($initialMinimized) {
        Invoke-McpTool $connection gp_window @{state='minimize'} -AllowError | Out-Null
    }

    $foreign = Raw 'foreign' @{operation='snapshot';monitor_id=(([guid]::NewGuid().ToString()) + ':monitor:test')}
    Check ($foreign.reason -eq 'foreign_instance') 'Foreign monitor ID was not rejected.'
    $afterWindows = Invoke-McpTool $connection gp_windows
    Check (($before.windows) -eq (($afterWindows.windows.window_id) -join ',')) 'P15 changed window identity set.'
    $dwmObserved = @($samples | Where-Object measurement_source -EQ 'dwm_timing').Count -gt 0
    if ($RequireDwm -and -not $dwmObserved) { throw 'DWM timing was required but unavailable on this host.' }
    $hostLimited = @($samples | Where-Object status -in @('host_limited','not_observed'))
    $complete = $true
    @{complete=$complete;checks=$checks;host_limited=$hostLimited;samples=$samples;source=(Get-FileHash (Join-Path $root 'native/window_performance.h')).Hash} |
        ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    Write-Output "PASS: $checks P15 checks. DWM observed: $dwmObserved; Evidence: $run"
} finally {
    try {
        if ($initialVisible -eq $false) { Invoke-McpTool $connection gp_window @{state='hide'} -AllowError | Out-Null }
        elseif ($initialMinimized) { Invoke-McpTool $connection gp_window @{state='minimize'} -AllowError | Out-Null }
        else { Invoke-McpTool $connection gp_window @{state='restore'} -AllowError | Out-Null }
    } catch {}
    Close-McpSession $connection
    if (-not (Test-Path -LiteralPath (Join-Path $run 'verification.json'))) {
        @{complete=$false;checks=$checks;host_limited=$hostLimited;samples=$samples} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    }
}
