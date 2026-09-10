param(
    [string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json",
    [switch]$RequireCapture
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-p11-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$checks = 0
$hostLimited = @()
$complete = $false
function Check($condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
function Invoke-RawScreenshot($session) {
    $body = @{jsonrpc='2.0';id=2;method='tools/call';params=@{name='gp_screenshot';arguments=@{}}} | ConvertTo-Json -Depth 20 -Compress
    $response = Invoke-WebRequest -UseBasicParsing -Uri $session.Url -Method Post -Headers $session.Headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 -MaximumRedirection 0
    $rpc = $response.Content | ConvertFrom-Json
    if ($rpc.error) { throw ($rpc.error | ConvertTo-Json -Depth 8) }
    return $rpc.result
}
function Wait-Operation($session, [string]$request, [string[]]$terminal) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $session gp_operation @{request=$request} -AllowError).operation
        if ($state.status -in $terminal) { return $state }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Operation $request did not reach a terminal state."
}
function Verify-Screenshot($result, [string]$label) {
    Check ($result.structuredContent -and $result.content) "$label did not return MCP content."
    $metadata = $result.structuredContent
    Check (-not ($metadata.PSObject.Properties.Name -contains '__mcp_image')) "$label leaked the internal image marker."
    Check ($metadata.status -in @('captured','experimental','host_limited')) "$label returned an unknown status: $($metadata.status)"
    Check (@($result.content | Where-Object type -EQ 'text').Count -eq 1) "$label did not preserve structured metadata text content."
    $images = @($result.content | Where-Object type -EQ 'image')
    if ($metadata.status -eq 'host_limited') {
        Check ($metadata.error) "$label host_limited result did not explain the limitation."
        $script:hostLimited += $label
        return $metadata
    }
    Check ($images.Count -eq 1) "$label did not return exactly one image content item."
    Check ([string]$images[0].mimeType -eq 'image/png' -and $images[0].data) "$label image content is not PNG."
    $bytes = [Convert]::FromBase64String([string]$images[0].data)
    Check ($bytes.Length -gt 24) "$label PNG is empty."
    Check (([BitConverter]::ToString($bytes[0..7])) -eq '89-50-4E-47-0D-0A-1A-0A') "$label image has an invalid PNG signature."
    Check ($metadata.width -gt 0 -and $metadata.height -gt 0 -and $metadata.dpi.x -gt 0 -and $metadata.dpi.y -gt 0) "$label omitted image dimensions or DPI."
    Check ($metadata.capture_mode -eq 'qt_widget_render') "$label did not identify Qt widget rendering."
    Check ($metadata.capture_ms -ge 0 -and $metadata.capture_ms -le 2000) "$label omitted or exceeded the capture time limit."
    [IO.File]::WriteAllBytes((Join-Path $run ($label + '.png')), $bytes)
    return $metadata
}
try {
    $rawListBody = @{jsonrpc='2.0';id=3;method='tools/list';params=@{}} | ConvertTo-Json -Depth 10 -Compress
    $rawList = Invoke-WebRequest -UseBasicParsing -Uri $connection.Url -Method Post -Headers $connection.Headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($rawListBody)) -TimeoutSec 15 -MaximumRedirection 0
    $catalog = ($rawList.Content | ConvertFrom-Json).result.tools
    Check (@($catalog | Where-Object name -EQ 'gp_screenshot').Count -eq 1) 'gp_screenshot is missing from tools/list.'

    Invoke-McpTool $connection gp_window @{state='restore'} | Out-Null
    Start-Sleep -Milliseconds 200
    $before = Invoke-McpTool $connection gp_capabilities
    $normal = Verify-Screenshot (Invoke-RawScreenshot $connection) 'normal'
    Check ($normal.instance_id -eq $connection.InstanceId -and $normal.pid -eq $connection.Pid) 'Normal screenshot was not bound to the current MCP instance.'
    $after = Invoke-McpTool $connection gp_capabilities
    Check ($before.foreground_window.handle -eq $after.foreground_window.handle -and $before.foreground_pid -eq $after.foreground_pid) 'Normal screenshot changed foreground focus.'
    Check ($normal.target_window -eq 'main' -and -not $normal.active_modal) 'Normal screenshot did not target the main window.'

    Invoke-McpTool $connection gp_window @{state='hide'} | Out-Null
    $before = Invoke-McpTool $connection gp_capabilities
    $hidden = Verify-Screenshot (Invoke-RawScreenshot $connection) 'hidden'
    $after = Invoke-McpTool $connection gp_capabilities
    Check ($before.foreground_window.handle -eq $after.foreground_window.handle -and $before.foreground_pid -eq $after.foreground_pid) 'Hidden screenshot changed foreground focus.'
    if ($hidden.status -eq 'captured') { Check (-not $hidden.visible) 'Hidden screenshot did not report the hidden window state.' }

    Invoke-McpTool $connection gp_window @{state='restore'} | Out-Null
    Start-Sleep -Milliseconds 200
    Invoke-McpTool $connection gp_window @{state='minimize'} | Out-Null
    $before = Invoke-McpTool $connection gp_capabilities
    $minimized = Verify-Screenshot (Invoke-RawScreenshot $connection) 'minimized'
    $after = Invoke-McpTool $connection gp_capabilities
    Check ($before.foreground_window.handle -eq $after.foreground_window.handle -and $before.foreground_pid -eq $after.foreground_pid) 'Minimized screenshot changed foreground focus.'
    if ($minimized.status -eq 'captured') { Check ($minimized.minimized) 'Minimized screenshot did not report the minimized state.' }

    Invoke-McpTool $connection gp_window @{state='restore'} | Out-Null
    $document = (Invoke-McpTool $connection gp_documents).documents | Select-Object -First 1
    Check ($document.id) 'Modal screenshot check requires an open document.'
    $beforeTitle = (Invoke-McpTool $connection gp_score @{document=$document.id}).metadata.Title
    Invoke-McpTool $connection gp_edit_metadata @{document=$document.id;property='Title';value=('P11-modal-' + [guid]::NewGuid().ToString('N').Substring(0, 8))} | Out-Null
    $close = Invoke-McpTool $connection gp_close @{document=$document.id;unsaved='prompt'} -NoWait
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $dialogs = Invoke-McpTool $connection gp_dialogs
        if ($dialogs.blocked) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($dialogs.blocked -and $dialogs.labels.Count -gt 0 -and $dialogs.buttons.Count -gt 0) 'Close confirmation dialog was not observed.'
    $before = Invoke-McpTool $connection gp_capabilities
    $modal = Verify-Screenshot (Invoke-RawScreenshot $connection) 'modal'
    $after = Invoke-McpTool $connection gp_capabilities
    Check ($modal.target_window -eq 'active_modal' -and $modal.active_modal) 'Modal screenshot did not target the active dialog.'
    Check ($before.foreground_window.handle -eq $after.foreground_window.handle -and $before.foreground_pid -eq $after.foreground_pid) 'Modal screenshot changed foreground focus.'
    Check ($modal.target_class -eq $dialogs.class) 'Modal screenshot class did not match gp_dialogs.'
    Invoke-McpTool $connection gp_cancel @{request=$close.request} -AllowError | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $closed = (Invoke-McpTool $connection gp_operation @{request=$close.request} -AllowError).operation
        if ($closed.status -in @('cancelled','closed','error')) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($closed.status -eq 'cancelled') 'Close confirmation cancellation did not complete.'
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $dialogsAfterCancel = Invoke-McpTool $connection gp_dialogs
        if (-not $dialogsAfterCancel.blocked) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Check (-not $dialogsAfterCancel.blocked) 'Close confirmation dialog remained after cancellation.'
    $cleanupClose = Invoke-McpTool $connection gp_close @{document=$document.id;unsaved='discard'} -NoWait
    $cleanupResult = Wait-Operation $connection $cleanupClose.request @('closed','error','cancelled')
    Check ($cleanupResult.status -eq 'closed') 'Modal screenshot cleanup could not discard the test document.'
    $reopen = Invoke-McpTool $connection gp_open @{path=$document.opened_path} -NoWait
    $reopened = Wait-Operation $connection $reopen.request @('opened','error','cancelled')
    Check ($reopened.status -eq 'opened') 'Modal screenshot cleanup could not reopen the test document.'
    $reopenedScore = Invoke-McpTool $connection gp_score @{document=$reopened.document}
    Check ($reopenedScore.metadata.Title -eq $beforeTitle -and -not $reopenedScore.dirty) 'Modal screenshot cleanup did not restore the document.'

    $complete = $RequireCapture.IsPresent -and $hostLimited.Count -eq 0
    if ($RequireCapture -and $hostLimited.Count) { throw "Required screenshot capture was host-limited: $($hostLimited -join ', ')" }
    if (-not $RequireCapture) { $complete = $true }
    @{complete=$complete;checks=$checks;host_limited=$hostLimited;source=(Get-FileHash (Join-Path $root 'native/guitarpro_mcp.cpp')).Hash;plugin_sha256=(Get-FileHash (Join-Path $root '.tools/native/plugins/generic/guitarpro_mcp.dll') -ErrorAction SilentlyContinue).Hash} |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    Write-Output "PASS: $checks P11 checks. Host-limited: $($hostLimited -join ', '); Evidence: $run"
} finally {
    try {
        $dialogs = Invoke-McpTool $connection gp_dialogs -AllowError
        if ($dialogs.blocked) {
            $observed = Invoke-McpTool $connection gp_objects @{query='取消';limit=20} -AllowError
            $cancelButton = @($observed.objects | Where-Object button -EQ $true | Select-Object -First 1)
            if ($cancelButton.Count) { Invoke-McpTool $connection gp_trigger @{snapshot=$observed.snapshot;id=$cancelButton[0].id} -AllowError | Out-Null }
        }
    } catch {}
    try { Invoke-McpTool $connection gp_window @{state='restore'} -AllowError | Out-Null } catch {}
    Close-McpSession $connection
    if (-not (Test-Path (Join-Path $run 'verification.json'))) {
        @{complete=$false;checks=$checks;host_limited=$hostLimited} |
            ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    }
}
