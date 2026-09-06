function Read-McpInstance {
    param([Parameter(Mandatory=$true)][string]$SessionFile)
    $SessionFile = [IO.Path]::GetFullPath($SessionFile)
    $descriptor = Get-Content -LiteralPath $SessionFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $instance = [guid]::Empty
    if (-not [guid]::TryParse([string]$descriptor.instance_id, [ref]$instance) -or $instance -eq [guid]::Empty -or
        $descriptor.backend -ne 'in_process_qt_plugin' -or -not $descriptor.process_start_time) {
        throw "Missing supported instance identity in $SessionFile; update or restart the host."
    }
    $endpoint = [uri]$descriptor.url
    if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -ne 'http' -or $endpoint.Host -ne '127.0.0.1' -or
        $endpoint.AbsolutePath -ne '/mcp' -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.UserInfo -or
        $endpoint.Port -ne $descriptor.port -or $endpoint.Port -lt 1) { throw 'Invalid local MCP endpoint.' }
    $process = Get-Process -Id $descriptor.pid -ErrorAction Stop
    try {
        if ($process.ProcessName -ne 'GuitarPro' -or $process.Path -ne [IO.Path]::GetFullPath($descriptor.host_exe) -or
            [string]$process.StartTime.ToFileTimeUtc() -ne [string]$descriptor.process_start_time) {
            throw 'The descriptor does not identify the current Guitar Pro process.'
        }
    } finally { $process.Dispose() }
    $expected = Join-Path (Split-Path -Parent $SessionFile) ('native-session-' + $descriptor.instance_id + '.json')
    if (-not $descriptor.session_file -or [IO.Path]::GetFullPath($descriptor.session_file) -ne $expected) { throw 'Invalid instance descriptor path.' }
    $descriptor.session_file = $expected
    return $descriptor
}
function Get-McpInstances {
    param([string[]]$DataDirectory = @())
    if (-not $DataDirectory.Count) {
        if ($env:GPMCP_DATA_DIR) { $DataDirectory += $env:GPMCP_DATA_DIR }
        $DataDirectory += @("$PSScriptRoot/../.cache", (Join-Path $env:LOCALAPPDATA 'GuitarProMCP'))
    }
    $found = @{}
    foreach ($directory in $DataDirectory) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $directory -Filter 'native-session*.json' -File) {
            try { $descriptor = Read-McpInstance -SessionFile $file.FullName }
            catch { continue }
            $found[$descriptor.instance_id] = $descriptor
        }
    }
    $found.Values | Sort-Object pid
}
function New-McpSession {
    param([string]$SessionFile = '', [string]$InstanceId = '', [string[]]$DataDirectory = @())
    if ($SessionFile) {
        $descriptor = Read-McpInstance -SessionFile $SessionFile
        if ($InstanceId -and $descriptor.instance_id -ne $InstanceId) { throw 'The session file belongs to another instance.' }
    } else {
        $instances = @(Get-McpInstances -DataDirectory $DataDirectory | Where-Object { -not $InstanceId -or $_.instance_id -eq $InstanceId })
        if ($instances.Count -eq 0) { throw 'No matching live GuitarProMCP instance found. Start the host or supply -SessionFile.' }
        if ($instances.Count -ne 1) { throw 'Multiple GuitarProMCP instances found. Select -InstanceId or -SessionFile explicitly.' }
        $descriptor = $instances[0]
    }
    $SessionFile = $descriptor.session_file
    $directory = Split-Path -Parent $SessionFile
    $token = (Get-Content -LiteralPath (Join-Path $directory 'mcp-auth-token') -Raw -ErrorAction Stop).Trim()
    $headers = @{Authorization="Bearer $token";Accept='application/json, text/event-stream';'GuitarProMCP-Instance-Id'=$descriptor.instance_id}
    $body = @{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='native-verifier';version='0.2'}}} | ConvertTo-Json -Depth 10 -Compress
    $response = Invoke-WebRequest -UseBasicParsing -Uri $descriptor.url -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 15 -MaximumRedirection 0
    $result = $response.Content | ConvertFrom-Json
    if ($result.error) { throw ($result.error | ConvertTo-Json) }
    if ($result.result._meta.instance_id -ne $descriptor.instance_id -or $result.result._meta.pid -ne $descriptor.pid -or
        $result.result.protocolVersion -ne '2025-06-18') { throw 'MCP initialization returned an unexpected instance or protocol.' }
    $headers['Mcp-Session-Id'] = [string]($response.Headers['Mcp-Session-Id'] | Select-Object -First 1)
    $headers['MCP-Protocol-Version'] = $result.result.protocolVersion
    Invoke-WebRequest -UseBasicParsing -Uri $descriptor.url -Method Post -Headers $headers -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -TimeoutSec 15 -MaximumRedirection 0 | Out-Null
    [pscustomobject]@{Url=$descriptor.url;Headers=$headers;Pid=$descriptor.pid;Version=$result.result.protocolVersion;InstanceId=$descriptor.instance_id;SessionFile=$SessionFile;DataDirectory=$directory}
}
function Invoke-McpTool {
    param($Session,[string]$Name,[hashtable]$Arguments=@{},[switch]$AllowError,[switch]$NoWait)
    $body = @{jsonrpc='2.0';id=2;method='tools/call';params=@{name=$Name;arguments=$Arguments}} | ConvertTo-Json -Depth 12 -Compress
    try { $response = Invoke-RestMethod -Uri $Session.Url -Method Post -Headers $Session.Headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 -MaximumRedirection 0 }
    catch { throw "MCP tool $Name failed: $($_.Exception.Message). Its outcome may be unknown; inspect the target before retrying a mutation." }
    if ($response.error) { throw ($response.error | ConvertTo-Json) }
    if ($response.result.isError -and -not $AllowError) { throw ($response.result.structuredContent | ConvertTo-Json -Depth 8) }
    $result = $response.result.structuredContent
    if (-not $NoWait -and $Name -in @('gp_save','gp_save_as','gp_save_current') -and $result.status -eq 'scheduled') {
        $request = $result.request
        $deadline = [DateTime]::UtcNow.AddSeconds(12)
        do {
            $operation = (Invoke-McpTool $Session gp_operation @{request=$request}).operation
            if ($operation.status -in @('saved','error','cancelled')) {
                $result = if ($operation.result) { $operation.result } else { [pscustomobject]@{error="Save operation $($operation.status)"} }
                $result | Add-Member -NotePropertyName request -NotePropertyValue $request -Force
                $result | Add-Member -NotePropertyName status -NotePropertyValue $operation.status -Force
                if ($result.error -and -not $AllowError) { throw ($result | ConvertTo-Json -Depth 8) }
                return $result
            }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "Save request $request is still pending. Inspect gp_operation and gp_dialogs; do not repeat the save. Use -NoWait to manage it explicitly."
    }
    $result
}
function Close-McpSession {
    param($Session)
    try { $descriptor = Read-McpInstance -SessionFile $Session.SessionFile } catch { return }
    if ($descriptor.instance_id -ne $Session.InstanceId) { return }
    Invoke-WebRequest -UseBasicParsing -Uri $Session.Url -Method Delete -Headers $Session.Headers -TimeoutSec 15 -MaximumRedirection 0 | Out-Null
}
function Reconnect-McpSession {
    param($Session, [string]$InstanceId = '')
    if (-not $InstanceId) { $InstanceId = $Session.InstanceId }
    $available = @(Get-McpInstances -DataDirectory $Session.DataDirectory | Where-Object instance_id -EQ $InstanceId)
    if ($available.Count -ne 1) { throw 'Target instance stopped or is unavailable. Discover and explicitly select a new instance after restart.' }
    try { Close-McpSession $Session }
    catch { if ([int]$_.Exception.Response.StatusCode -ne 404) { throw } }
    New-McpSession -InstanceId $InstanceId -DataDirectory $Session.DataDirectory
}
