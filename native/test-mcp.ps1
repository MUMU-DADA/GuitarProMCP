param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
$descriptor = Get-Content -LiteralPath $SessionFile -Raw | ConvertFrom-Json
$token = (Get-Content -LiteralPath (Join-Path (Split-Path $SessionFile) 'mcp-auth-token') -Raw).Trim()
$endpoint = [Uri]$descriptor.url
$checks = 0
function Assert($condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
function Send-Raw([string]$request) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect($endpoint.Host, $endpoint.Port)
        $stream = $client.GetStream(); $stream.ReadTimeout = 5000
        $bytes = [Text.Encoding]::UTF8.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $output = [IO.MemoryStream]::new()
        try {
            $buffer = [byte[]]::new(8192)
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $output.Write($buffer, 0, $read) }
            $text = [Text.Encoding]::UTF8.GetString($output.ToArray())
        } finally { $output.Dispose() }
        if ($text -notmatch '^HTTP/1.1 (\d+) ') { throw 'No HTTP response' }
        $status = [int]$Matches[1]
        $body = $text.Substring($text.IndexOf("`r`n`r`n") + 4)
        [pscustomobject]@{Status=$status;Body=$body;Json=$(if ($body) { $body | ConvertFrom-Json })}
    } finally { $client.Dispose() }
}
function Send-Http([string]$body, [hashtable]$overrides=@{}, [string]$method='POST', [string]$extra='') {
    $headers = @{Host="$($endpoint.Host):$($endpoint.Port)";Authorization="Bearer $token";Accept='application/json, text/event-stream';'Content-Type'='application/json';'Content-Length'=[Text.Encoding]::UTF8.GetByteCount($body)}
    foreach ($key in $overrides.Keys) { if ($null -eq $overrides[$key]) { $headers.Remove($key) } else { $headers[$key]=$overrides[$key] } }
    $lines = @("$method /mcp HTTP/1.1") + @($headers.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" })
    Send-Raw (($lines -join "`r`n") + "`r`n" + $extra + "`r`n" + $body)
}
$connection = New-McpSession -SessionFile $SessionFile
try {
    $sessionHeaders = @{'Mcp-Session-Id'=$connection.Headers['Mcp-Session-Id'];'MCP-Protocol-Version'=$connection.Version}
    Assert ($connection.Version -eq '2025-06-18') 'Negotiation failed'
    Assert ((Send-Http '{}' @{Authorization=$null}).Status -eq 401) 'Missing auth accepted'
    Assert ((Send-Http '{}' @{Authorization='Bearer wrong'}).Status -eq 401) 'Wrong token accepted'
    Assert ((Send-Http '{}' @{Origin='http://attacker.invalid'}).Status -eq 403) 'Foreign Origin accepted'
    Assert ((Send-Http '{}' @{Origin="http://user@localhost:$($endpoint.Port)"}).Status -eq 403) 'Invalid Origin accepted'
    Assert ((Send-Http '{}' @{Host="attacker.invalid:$($endpoint.Port)"}).Status -eq 403) 'Foreign Host accepted'
    Assert ((Send-Http '{}' @{} 'GET').Status -eq 405) 'GET must report unsupported SSE'
    Assert ((Send-Http '{}' @{'Content-Type'='text/plain'}).Status -eq 415) 'Wrong media type accepted'
    Assert ((Send-Http '{').Json.error.code -eq -32700) 'Malformed JSON accepted'
    Assert ((Send-Http '[]').Json.error.code -eq -32600) 'Batch accepted'
    Assert ((Send-Http '{}' @{} 'POST' "Content-Length: 2`r`n").Status -eq 400) 'Duplicate length accepted'
    Assert ((Send-Http '{}' @{'Transfer-Encoding'='chunked'}).Status -eq 400) 'Ambiguous framing accepted'
    $ping='{"jsonrpc":"2.0","id":7,"method":"ping"}'
    Assert ((Send-Http $ping).Status -eq 400) 'Missing session accepted'
    Assert ((Send-Http $ping @{'Mcp-Session-Id'='expired'}).Status -eq 404) 'Expired session accepted'
    Assert ((Send-Http $ping ($sessionHeaders + @{'Origin'="http://localhost:$($endpoint.Port)"})).Status -eq 200) 'Valid same-origin request rejected'
    $badVersion = $sessionHeaders.Clone(); $badVersion['MCP-Protocol-Version']='invalid'
    Assert ((Send-Http $ping $badVersion).Status -eq 400) 'Protocol mismatch accepted'
    Assert ((Send-Http '{"jsonrpc":"2.0","id":8,"method":"unknown"}' $sessionHeaders).Json.error.code -eq -32601) 'Unknown RPC accepted'
    foreach ($arguments in @(@{axis='bar';index=1.5}, @{axis='bar';index='1'}, @{axis='bar'}, @{axis='bar';index=0;unexpected=$true})) {
        $body=@{jsonrpc='2.0';id=9;method='tools/call';params=@{name='gp_cursor';arguments=$arguments}} | ConvertTo-Json -Compress
        Assert ((Send-Http $body $sessionHeaders).Json.error.code -eq -32602) 'Invalid arguments reached native code'
    }
    $list=Send-Http '{"jsonrpc":"2.0","id":10,"method":"tools/list"}' $sessionHeaders
    Assert ($list.Json.result.tools.name -contains 'gp_set_fret') 'Native tool missing'
    $chunkHeaders=$sessionHeaders.Clone(); $chunkHeaders['Content-Length']=$null; $chunkHeaders['Transfer-Encoding']='chunked'
    $chunks=('{0:x}' -f [Text.Encoding]::UTF8.GetByteCount($ping)) + "`r`n$ping`r`n0`r`n`r`n"
    Assert ((Send-Http $chunks $chunkHeaders).Status -eq 200) 'Chunked request failed'
    Assert ((Send-Http "+1`r`nx`r`n0`r`n`r`n" $chunkHeaders).Status -eq 400) 'Invalid chunk size accepted'
    $capabilities=Invoke-McpTool $connection gp_capabilities
    Assert ($capabilities.pid -eq $descriptor.pid -and $capabilities.qt_thread) 'Tool not running in host Qt thread'
} finally { Close-McpSession $connection }
Assert ((Send-Http $ping $sessionHeaders).Status -eq 404) 'Deleted session still usable'
Write-Output "PASS: $checks MCP transport, session, authentication, framing and validation checks."