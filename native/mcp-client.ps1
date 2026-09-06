function New-McpSession {
    param([string]$SessionFile = '')
    if (-not $SessionFile) {
        $candidates = @()
        if ($env:GPMCP_DATA_DIR) { $candidates += Join-Path $env:GPMCP_DATA_DIR 'native-session.json' }
        $candidates += "$PSScriptRoot/../.cache/native-session.json"
        $candidates += Join-Path $env:LOCALAPPDATA 'GuitarProMCP/native-session.json'
        foreach ($candidate in $candidates) {
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            $saved = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
            if ($saved.pid -and (Get-Process -Id $saved.pid -ErrorAction SilentlyContinue)) { $SessionFile = $candidate; break }
        }
        if (-not $SessionFile) { throw 'No running GuitarProMCP session found. Start the installed Guitar Pro or supply -SessionFile.' }
    }
    $descriptor = Get-Content -LiteralPath $SessionFile -Raw | ConvertFrom-Json
    $token = (Get-Content -LiteralPath (Join-Path (Split-Path $SessionFile) 'mcp-auth-token') -Raw).Trim()
    $headers = @{Authorization="Bearer $token";Accept='application/json, text/event-stream'}
    $body = @{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='native-verifier';version='0.2'}}} | ConvertTo-Json -Depth 10 -Compress
    $response = Invoke-WebRequest -UseBasicParsing -Uri $descriptor.url -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 15
    $result = $response.Content | ConvertFrom-Json
    if ($result.error) { throw ($result.error | ConvertTo-Json) }
    $headers['Mcp-Session-Id'] = [string]($response.Headers['Mcp-Session-Id'] | Select-Object -First 1)
    $headers['MCP-Protocol-Version'] = $result.result.protocolVersion
    Invoke-WebRequest -UseBasicParsing -Uri $descriptor.url -Method Post -Headers $headers -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -TimeoutSec 15 | Out-Null
    [pscustomobject]@{Url=$descriptor.url;Headers=$headers;Pid=$descriptor.pid;Version=$result.result.protocolVersion}
}
function Invoke-McpTool {
    param($Session,[string]$Name,[hashtable]$Arguments=@{},[switch]$AllowError)
    $body = @{jsonrpc='2.0';id=2;method='tools/call';params=@{name=$Name;arguments=$Arguments}} | ConvertTo-Json -Depth 12 -Compress
    try { $response = Invoke-RestMethod -Uri $Session.Url -Method Post -Headers $Session.Headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 }
    catch { throw "MCP tool $Name failed: $($_.Exception.Message)" }
    if ($response.error) { throw ($response.error | ConvertTo-Json) }
    if ($response.result.isError -and -not $AllowError) { throw ($response.result.structuredContent | ConvertTo-Json -Depth 8) }
    $response.result.structuredContent
}
function Close-McpSession {
    param($Session)
    if (Get-Process -Id $Session.Pid -ErrorAction SilentlyContinue) {
        Invoke-WebRequest -UseBasicParsing -Uri $Session.Url -Method Delete -Headers $Session.Headers -TimeoutSec 15 | Out-Null
    }
}
