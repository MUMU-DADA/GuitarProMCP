param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.Path]::GetFullPath((Join-Path $root 'artifacts/native-test.gp'))
$fixtureHash = (Get-FileHash -LiteralPath "$PSScriptRoot/testdata/minimal.gp").Hash
$checks = 0
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++; $script:lastCheck = $message }
$connection = New-McpSession -SessionFile $SessionFile
function Wait-DocumentOperation([string]$field, [string]$request, [string]$status) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $documents = Invoke-McpTool $connection gp_documents
        $operation = $documents.$field
        if ($operation.request -eq $request -and $operation.status -in @($status,'error')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($operation.request -eq $request -and $operation.status -eq $status) "Document operation failed: $($operation | ConvertTo-Json -Compress)"
    return $documents
}
function New-Score {
    $request = Invoke-McpTool $connection gp_new @{template='Nylon Guitar'}
    (Wait-DocumentOperation 'creation' $request.request 'created').creation.document
}
function Close-Score([string]$id) {
    $request = Invoke-McpTool $connection gp_close @{document=$id}
    Assert ($request.status -eq 'scheduled') 'Document close was not scheduled'
    $documents = Wait-DocumentOperation 'closing' $request.request 'closed'
    Assert (@($documents.documents | Where-Object id -EQ $id).Count -eq 0) 'Closed document is still listed'
    return $documents
}
try {
    $documents = Invoke-McpTool $connection gp_documents
    Assert ($documents.documents.Count -eq 1) 'Requires only artifacts/native-test.gp open'
    $fixture = $documents.documents[0]
    Assert ($fixture.opened_path -eq $source.Replace('\','/') -and -not $fixture.dirty) 'Refusing to close a different or dirty document'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy changed'
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.pid -ne $identity.foreground_pid -and $identity.qt_thread -and $identity.hidden_mode) 'Host is not in native background mode'
    $run = Join-Path $root ('artifacts/native-lifecycle-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $first = New-Score
    $second = New-Score
    $third = New-Score
    Invoke-McpTool $connection gp_activate @{document=$fixture.id} | Out-Null
    $afterMiddle = Close-Score $second
    Assert ($afterMiddle.documents.Count -eq 3 -and $afterMiddle.documents.id -contains $first -and $afterMiddle.documents.id -contains $third -and $afterMiddle.documents.id -contains $fixture.id) 'Closing inactive middle document removed another document'
    Assert ((Invoke-McpTool $connection gp_score @{document=$second} -AllowError).error) 'Closed document ID still reads a score'
    Assert ((Invoke-McpTool $connection gp_close @{document=$second} -AllowError).error) 'Stale document ID accepted for closing'
    Invoke-McpTool $connection gp_edit_metadata @{document=$first;property='Title';value='文档关闭与重开验证'} | Out-Null
    Assert ((Invoke-McpTool $connection gp_close @{document=$first} -AllowError).error) 'Dirty document close was accepted'
    $dirty = Invoke-McpTool $connection gp_documents
    Assert ($dirty.documents.Count -eq 3 -and ($dirty.documents | Where-Object id -EQ $first).dirty) 'Rejected close changed the document list or dirty state'
    $savedPath = Join-Path $run 'saved.gp'
    Invoke-McpTool $connection gp_save_as @{document=$first;path=$savedPath} | Out-Null
    Close-Score $first | Out-Null
    $afterLastCreated = Close-Score $third
    Assert ($afterLastCreated.documents.Count -eq 1 -and $afterLastCreated.documents[0].id -eq $fixture.id) 'Closing shifted tab indices removed the fixture'
    $empty = Close-Score $fixture.id
    Assert ($empty.documents.Count -eq 0) 'Last document did not close'
    Assert ((Invoke-McpTool $connection gp_capabilities).pid -eq $identity.pid) 'Closing the last document exited the host'
    $opened = Invoke-McpTool $connection gp_open @{path=$savedPath}
    Assert ($opened.status -eq 'scheduled') 'Reopening saved document was not scheduled'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $reopened = (Invoke-McpTool $connection gp_documents).documents | Where-Object opened_path -EQ $savedPath.Replace('\','/')
        if ($reopened) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($reopened -and $reopened.id -notin @($fixture.id,$first,$second,$third)) 'Reopening reused a stale document ID'
    Assert ((Invoke-McpTool $connection gp_score @{document=$reopened.id}).metadata.Title -eq '文档关闭与重开验证') 'Reopened document lost saved content'
    Close-Score $reopened.id | Out-Null
    Invoke-McpTool $connection gp_open @{path=$source} | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $restored = (Invoke-McpTool $connection gp_documents).documents
        if ($restored.Count -eq 1 -and $restored[0].opened_path -eq $source.Replace('\','/')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($restored.Count -eq 1 -and -not $restored[0].dirty -and $restored[0].opened_path -eq $source.Replace('\','/')) 'Fixture was not reopened cleanly'
    Assert ((Invoke-McpTool $connection gp_window @{state='restore'}).visible) 'Explicit window restore failed'
    $shownWindow = (Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}).objects | Where-Object class -EQ 'gp::gui::MainWindow'
    Assert (-not ($shownWindow.native_window_flags -band 0x00200000)) 'Restored native window cannot receive focus'
    Assert (-not (Invoke-McpTool $connection gp_window @{state='hide'}).visible) 'Window did not return to hidden mode'
    $hiddenWindow = (Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}).objects | Where-Object class -EQ 'gp::gui::MainWindow'
    Assert (($hiddenWindow.native_window_flags -band 0x00200000) -and ($hiddenWindow.window_flags -band 0x00200000)) 'Hidden QWidget and native window have different focus policies'
    $afterIdentity = Invoke-McpTool $connection gp_capabilities
    Assert ($afterIdentity.pid -eq $identity.pid -and $afterIdentity.foreground_pid -ne $identity.pid -and $afterIdentity.hidden_mode) 'Document lifecycle left the host in foreground'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture content changed'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;after_middle=$afterMiddle;empty=$empty;reopened=$reopened;restored=$restored} |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native document lifecycle checks. Evidence: $run"
} catch {
    Write-Warning "Last passed check: $lastCheck. Failure: $($_.ScriptStackTrace)"
    throw
} finally {
    if (Get-Process -Id $connection.Pid -ErrorAction SilentlyContinue) {
        try { Close-McpSession $connection } catch { Write-Warning "Session cleanup failed: $_" }
    }
}
