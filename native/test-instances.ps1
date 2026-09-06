param([Parameter(Mandatory=$true)][string]$HostDirectory, [switch]$CheckLaunchForwarding, [switch]$Visible)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$HostDirectory = [IO.Path]::GetFullPath($HostDirectory)
foreach ($directory in @($HostDirectory)) {
    if (-not $directory.StartsWith(([IO.Path]::GetFullPath((Join-Path $root '.tools')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Use isolated host copies under .tools.' }
}
. "$PSScriptRoot/mcp-client.ps1"
$run = Join-Path $root ('artifacts/instances-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $run 'data'
New-Item -ItemType Directory -Path $data -Force | Out-Null
$exe = Join-Path $HostDirectory 'GuitarPro.exe'
$checks = 0
$observations = @()
$processes = [Collections.Generic.List[object]]::new()
$connections = [Collections.Generic.List[object]]::new()
$saved = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_SESSION_FILE','GPMCP_DATA_DIR','GPMCP_BACKGROUND','GPMCP_PORT','TEMP','TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Reject([scriptblock]$operation, [string]$pattern) {
    $rejected = $false
    try { & $operation | Out-Null } catch { $rejected = $_.Exception.Message -like $pattern }
    Assert $rejected "Expected rejection: $pattern"
}
function Start-Host {
    param([string]$Directory = $HostDirectory)
    $process = Start-Process -FilePath (Join-Path $Directory 'GuitarPro.exe') -ArgumentList @('--open', ('"' + $fixture + '"')) -WorkingDirectory $Directory -WindowStyle Hidden -PassThru
    $null = $process.Handle
    $processes.Add($process)
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        $found = @(Get-McpInstances -DataDirectory $data | Where-Object pid -EQ $process.Id)
        if ($found.Count -eq 1 -or $process.HasExited) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $script:observations += [pscustomobject]@{launch_pid=$process.Id;exited=$process.HasExited;exit_code=$(if($process.HasExited){$process.ExitCode}else{$null})}
    Assert ($found.Count -eq 1 -and -not $process.HasExited) "No live descriptor for PID $($process.Id); exited=$($process.HasExited), code=$($process.ExitCode)"
    $connection = New-McpSession -InstanceId $found[0].instance_id -DataDirectory $data
    $connections.Add($connection)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $documents = Invoke-McpTool $connection gp_documents
        if ($documents.documents.Count -eq 1) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($documents.documents.Count -eq 1 -and -not $documents.documents[0].dirty) 'Expected one clean fixture per instance.'
    $script:observations += $found[0]
    [pscustomobject]@{process=$process;descriptor=$found[0];connection=$connection;document=$documents.documents[0].id}
}
function Stop-Host($hostInstance) {
    $documents = Invoke-McpTool $hostInstance.connection gp_documents
    Assert (-not @($documents.documents | Where-Object dirty).Count) 'Cannot close a dirty test instance.'
    $settle = 5000 - ([DateTime]::Now - $hostInstance.process.StartTime).TotalMilliseconds
    if ($settle -gt 0) { Start-Sleep -Milliseconds ([int]$settle) }
    $windows = Invoke-McpTool $hostInstance.connection gp_objects @{query='MainWindow';limit=100}
    $main = @($windows.objects | Where-Object class -EQ 'gp::gui::MainWindow')[0]
    try { Invoke-McpTool $hostInstance.connection gp_close_window @{snapshot=$windows.snapshot;id=$main.id} | Out-Null }
    catch { if (-not $hostInstance.process.WaitForExit(5000)) { throw } }
    Assert ($hostInstance.process.WaitForExit(15000) -and $hostInstance.process.ExitCode -eq 0) 'Test host did not exit cleanly.'
    Assert (-not (Test-Path -LiteralPath $hostInstance.descriptor.session_file)) 'Exited instance left its discovery file.'
}
function Http-Status($connection, [string]$instanceId, [string]$body) {
    $headers = $connection.Headers.Clone()
    $headers['GuitarProMCP-Instance-Id'] = $instanceId
    try {
        (Invoke-WebRequest -UseBasicParsing -Uri $connection.Url -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 15 -MaximumRedirection 0).StatusCode
    } catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { throw } }
}
function Concurrent-Edits($first, $second, [hashtable]$firstArgs, [hashtable]$secondArgs) {
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $requests = @(); $pending = @(); $responses = @()
    try {
        $pairs = @(@{session=$first;arguments=$firstArgs}, @{session=$second;arguments=$secondArgs})
        foreach ($pair in $pairs) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $pair.session.Url)
            foreach ($key in $pair.session.Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($key, [string]$pair.session.Headers[$key]) }
            $body = @{jsonrpc='2.0';id=($requests.Count + 40);method='tools/call';params=@{name='gp_edit_metadata';arguments=$pair.arguments}} | ConvertTo-Json -Compress
            $request.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
            $requests += $request
            $pending += $client.SendAsync($request)
        }
        for ($i = 0; $i -lt $pending.Count; $i++) {
            $response = $pending[$i].GetAwaiter().GetResult()
            $responses += $response
            $result = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            Assert ($response.IsSuccessStatusCode -and -not $result.error -and -not $result.result.isError -and $result.id -eq ($i + 40)) 'Concurrent native mutation failed or returned the wrong request ID.'
        }
    } finally {
        foreach ($response in $responses) { $response.Dispose() }
        foreach ($request in $requests) { $request.Dispose() }
        $client.Dispose()
    }
}
$fixture = Join-Path $run 'original.gp'
$forwardedPath = Join-Path $run 'forwarded.gp'
Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $fixture
Copy-Item -LiteralPath $fixture -Destination $forwardedPath
$fixtureHash = (Get-FileHash -LiteralPath $fixture).Hash
$passed = $false
$blocker = $null
& "$root/install-plugin.ps1" -InstallDirectory $HostDirectory | Out-Null
try {
    foreach ($name in $saved.Keys) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    $env:GPMCP_DATA_DIR = $data
    $env:GPMCP_BACKGROUND = if ($Visible) { '0' } else { '1' }
    $env:TEMP = $run; $env:TMP = $run
    $first = Start-Host
    Assert ($first.descriptor.port -eq 18432 -and -not $first.descriptor.port_fallback) 'Default port is not available for the first test instance.'
    $alias = Join-Path $data 'native-session.json'
    $aliasHash = (Get-FileHash -LiteralPath $alias).Hash
    $clientHash = (Get-FileHash -LiteralPath (Join-Path $data 'mcp-client.json')).Hash
    $tokenHash = (Get-FileHash -LiteralPath (Join-Path $data 'mcp-auth-token')).Hash
    Assert (@(Get-McpInstances -DataDirectory $data).Count -eq 1) 'Alias and unique descriptors were not deduplicated.'
    $settle = 5000 - ([DateTime]::Now - $first.process.StartTime).TotalMilliseconds
    if ($settle -gt 0) { Start-Sleep -Milliseconds ([int]$settle) }
    if ($CheckLaunchForwarding) {
        $forwarder = Start-Process -FilePath $exe -ArgumentList @('--open', ('"' + $forwardedPath + '"')) -WorkingDirectory $HostDirectory -WindowStyle Hidden -PassThru
        $null = $forwarder.Handle
        $processes.Add($forwarder)
        Assert ($forwarder.WaitForExit(15000) -and $forwarder.ExitCode -eq 0) 'Expected the supported host to forward a second launch and exit.'
    } else {
        Invoke-McpTool $first.connection gp_open @{path=$forwardedPath} | Out-Null
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $documents = Invoke-McpTool $first.connection gp_documents
        $forwarded = @($documents.documents | Where-Object { $_.opened_path -and [IO.Path]::GetFullPath($_.opened_path) -eq $forwardedPath })
        if ($forwarded.Count -eq 1) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $script:observations += @{launch_forwarding_test=[bool]$CheckLaunchForwarding;documents_after_open=$documents;dialogs_after_open=(Invoke-McpTool $first.connection gp_dialogs)}
    Assert ($documents.documents.Count -eq 2 -and $forwarded.Count -eq 1 -and -not $forwarded[0].dirty) 'Second score did not open in the existing host.'
    Assert (@($documents.documents | Where-Object id -EQ $first.document).Count -eq 1) 'Opening another document changed the original document identity.'
    Assert (@(Get-McpInstances -DataDirectory $data).Count -eq 1) 'Forwarding published a false independent instance.'
    Assert ((Get-FileHash -LiteralPath $alias).Hash -eq $aliasHash -and (Get-FileHash -LiteralPath (Join-Path $data 'mcp-client.json')).Hash -eq $clientHash) 'Forwarding overwrote the existing connection information.'
    $second = New-McpSession -DataDirectory $data
    $connections.Add($second)
    Assert ($second.InstanceId -eq $first.connection.InstanceId -and $second.Headers['Mcp-Session-Id'] -ne $first.connection.Headers['Mcp-Session-Id']) 'Clients did not receive distinct sessions for the same host.'
    $before = Invoke-McpTool $first.connection gp_score @{document=$first.document}
    Concurrent-Edits $first.connection $second @{document=$first.document;property='Title';value='First document only'} @{document=$forwarded[0].id;property='Title';value='Forwarded document only'}
    Assert ((Invoke-McpTool $second gp_score @{document=$first.document}).metadata.Title -eq 'First document only') 'First document mutation was redirected.'
    Assert ((Invoke-McpTool $first.connection gp_score @{document=$forwarded[0].id}).metadata.Title -eq 'Forwarded document only') 'Second document mutation was redirected.'
    Concurrent-Edits $first.connection $second @{document=$first.document;property='Artist';value='Concurrent artist'} @{document=$first.document;property='Album';value='Concurrent album'}
    $concurrent = Invoke-McpTool $second gp_score @{document=$first.document}
    Assert ($concurrent.metadata.Artist -eq 'Concurrent artist' -and $concurrent.metadata.Album -eq 'Concurrent album') 'Overlapping clients lost a metadata update.'
    Close-McpSession $second
    Assert ((Invoke-McpTool $first.connection gp_score @{document=$first.document}).metadata.Title -eq 'First document only') 'Closing one client stopped the other client.'
    $wrongId = [guid]::NewGuid().ToString()
    Reject { New-McpSession -SessionFile $alias -InstanceId $wrongId } 'The session file belongs to another instance*'
    $mutation = '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"gp_edit_metadata","arguments":{"property":"Title","value":"Wrong instance"}}}'
    Assert ((Http-Status $first.connection $wrongId $mutation) -eq 409) 'Wrong instance binding reached a native mutation.'
    Assert ((Invoke-McpTool $first.connection gp_score @{document=$first.document}).metadata.Title -eq 'First document only') 'Rejected binding changed the score.'
    $oldSessionId = $first.connection.Headers['Mcp-Session-Id']
    $first.connection = Reconnect-McpSession $first.connection
    $connections.Add($first.connection)
    Assert ($first.connection.Headers['Mcp-Session-Id'] -ne $oldSessionId -and $first.connection.InstanceId -eq $first.descriptor.instance_id) 'Reconnect did not replace only the protocol session.'
    Assert ((Invoke-McpTool $first.connection gp_score @{document=$first.document}).metadata.Title -eq 'First document only') 'Reconnect lost the existing score.'
    $fake = $first.descriptor | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $fake.instance_id = [guid]::NewGuid().ToString()
    $fake.session_file = Join-Path $data ('native-session-' + $fake.instance_id + '.json')
    $fake.process_start_time = '0'
    $fake | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fake.session_file
    Reject { New-McpSession -SessionFile $fake.session_file } 'The descriptor does not identify*'
    Assert (@(Get-McpInstances -DataDirectory $data).Count -eq 1) 'A reused PID was treated as a live instance.'
    $fake.process_start_time = $first.descriptor.process_start_time
    $fake.url = 'http://example.invalid/mcp'; $fake.port = 80
    $fake | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fake.session_file
    Reject { New-McpSession -SessionFile $fake.session_file } 'Invalid local MCP endpoint*'
    Remove-Item -LiteralPath $fake.session_file
    Invoke-McpTool $first.connection gp_save_as @{document=$first.document;path=(Join-Path $run 'first.gp')} | Out-Null
    Invoke-McpTool $first.connection gp_save_as @{document=$forwarded[0].id;path=(Join-Path $run 'second.gp')} | Out-Null
    $stale = $first.connection
    Stop-Host $first
    Assert (@(Get-McpInstances -DataDirectory $data).Count -eq 0) 'Closing the host left a live discovery record.'
    Reject { Reconnect-McpSession $stale } 'Target instance stopped*'
    $first.descriptor | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $alias
    $restarted = Start-Host
    Assert ((Get-Content -LiteralPath $alias -Raw | ConvertFrom-Json).instance_id -eq $restarted.descriptor.instance_id) 'Restart did not reclaim an exited process alias while its handle was retained.'
    Assert ($restarted.descriptor.port -eq 18432 -and $restarted.descriptor.instance_id -ne $first.descriptor.instance_id) 'Restart did not acquire a fresh identity on the default port.'
    Assert ((Http-Status $stale $stale.InstanceId $mutation) -eq 409) 'Stale connection reached the restarted host.'
    Assert ((Invoke-McpTool $restarted.connection gp_score).metadata.Title -eq $before.metadata.Title) 'Stale mutation changed the restarted score.'
    Assert ($restarted.document -ne $first.document) 'Host restart reused a document identity.'
    Assert ((Invoke-McpTool $restarted.connection gp_score @{document=$first.document} -AllowError).error) 'Restart accepted a stale document ID.'
    $selected = Reconnect-McpSession $stale -InstanceId $restarted.descriptor.instance_id
    $connections.Add($selected)
    Assert ((Invoke-McpTool $selected gp_capabilities).instance_id -eq $restarted.descriptor.instance_id) 'Explicit reconnection selected the wrong restarted process.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $data 'mcp-auth-token')).Hash -eq $tokenHash) 'Concurrent startup or restart changed the persistent token.'
    Stop-Host $restarted
    $blocker = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,18432)
    $blocker.Start()
    $fallback = Start-Host
    Assert ($fallback.descriptor.port_fallback -and $fallback.descriptor.port -ne 18432) 'Default port contention did not use an independent loopback port.'
    Assert ((Invoke-McpTool $fallback.connection gp_capabilities).pid -eq $fallback.process.Id) 'Fallback endpoint did not reach the intended host.'
    Stop-Host $fallback
    $blocker.Stop(); $blocker = $null
    Assert (@(Get-McpInstances -DataDirectory $data).Count -eq 0) 'Discovery retained an exited instance.'
    Assert (@(Get-ChildItem -LiteralPath $data -Filter 'mcp-client-*.json').Count -eq 0) 'Exit retained an instance-bound client configuration.'
    Assert ((Get-FileHash -LiteralPath $fixture).Hash -eq $fixtureHash -and (Get-FileHash -LiteralPath $forwardedPath).Hash -eq $fixtureHash) 'Connection verification modified an input fixture.'
    $passed = $true
} finally {
    if ($blocker) { $blocker.Stop() }
    foreach ($process in $processes) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }; $process.Dispose() }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    & "$root/install-plugin.ps1" -Action Uninstall -InstallDirectory $HostDirectory | Out-Null
    @{passed=$passed;checks=$checks;launch_forwarding_test=[bool]$CheckLaunchForwarding;visible=[bool]$Visible;startup_settling_ms=5000;independent_gui_instances_verified=$false;observations=$observations;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash;host_sha256=(Get-FileHash $exe).Hash;client_sha256=(Get-FileHash "$PSScriptRoot/mcp-client.ps1").Hash} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
}
Write-Output "PASS: $checks discovery, concurrent clients, binding, reconnection, restart and port checks. Launch forwarding tested: $CheckLaunchForwarding. Independent GUI instances remain unverified. Evidence: $run"
