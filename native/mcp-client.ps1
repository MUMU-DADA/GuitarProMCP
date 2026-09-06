function New-McpSession {
    param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
    $descriptor = Get-Content -LiteralPath $SessionFile -Raw | ConvertFrom-Json
    $token = (Get-Content -LiteralPath (Join-Path (Split-Path $SessionFile) 'mcp-auth-token') -Raw).Trim()
    $headers = @{Authorization="Bearer $token";Accept='application/json, text/event-stream'}
    $body = @{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='native-verifier';version='0.2'}}} | ConvertTo-Json -Depth 10 -Compress
    $response = Invoke-WebRequest -Uri $descriptor.url -Method Post -Headers $headers -ContentType 'application/json' -Body $body
    $result = $response.Content | ConvertFrom-Json
    if ($result.error) { throw ($result.error | ConvertTo-Json) }
    $headers['Mcp-Session-Id'] = [string]($response.Headers['Mcp-Session-Id'] | Select-Object -First 1)
    $headers['MCP-Protocol-Version'] = $result.result.protocolVersion
    Invoke-WebRequest -Uri $descriptor.url -Method Post -Headers $headers -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' | Out-Null
    [pscustomobject]@{Url=$descriptor.url;Headers=$headers;Pid=$descriptor.pid;Version=$result.result.protocolVersion}
}
function Invoke-McpTool {
    param($Session,[string]$Name,[hashtable]$Arguments=@{},[switch]$AllowError)
    $body = @{jsonrpc='2.0';id=2;method='tools/call';params=@{name=$Name;arguments=$Arguments}} | ConvertTo-Json -Depth 12 -Compress
    try { $response = Invoke-RestMethod -Uri $Session.Url -Method Post -Headers $Session.Headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) }
    catch { throw "MCP tool $Name failed: $($_.Exception.Message)" }
    if ($response.error) { throw ($response.error | ConvertTo-Json) }
    if ($response.result.isError -and -not $AllowError) { throw ($response.result.structuredContent | ConvertTo-Json -Depth 8) }
    $response.result.structuredContent
}
function Close-McpSession {
    param($Session)
    if (Get-Process -Id $Session.Pid -ErrorAction SilentlyContinue) {
        Invoke-WebRequest -Uri $Session.Url -Method Delete -Headers $Session.Headers | Out-Null
    }
}
