param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json", [switch]$VerifyDocumentMenu)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $PSScriptRoot 'testdata/minimal.gp'
$fixtureHash = (Get-FileHash -LiteralPath $fixture).Hash
$run = Join-Path $root ('artifacts/document-tabs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$checks = 0; $passed = $false; $observations = @()
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
$connection = New-McpSession -SessionFile $SessionFile
function Wait-Operation($request, [string]$expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if ($state.status -in @($expected,'error','cancelled','closed','opened','created')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($state.status -eq $expected) "Unexpected operation: $($state | ConvertTo-Json -Depth 5 -Compress)"
    return $state
}
function Close-Score([string]$id, [string]$decision = 'reject') {
    $request = Invoke-McpTool $connection gp_close @{document=$id;unsaved=$decision}
    Wait-Operation $request.request 'closed' | Out-Null
    Assert (@((Invoke-McpTool $connection gp_documents).documents | Where-Object id -EQ $id).Count -eq 0) 'Close removed the wrong document.'
}
function Check-Order([string[]]$expected, [string]$active) {
    $state = Invoke-McpTool $connection gp_documents
    Assert ($state.tab_order_available -and ($state.documents.id -join ',') -eq ($expected -join ',')) 'Document tab order differs.'
    Assert ($state.active_document -in $expected -and (-not $active -or $state.active_document -eq $active) -and @($state.documents | Where-Object active).Count -eq 1) 'Unexpected active document.'
    for ($i = 0; $i -lt $expected.Count; $i++) { Assert ($state.documents[$i].tab_index -eq $i) 'Tab index differs from list order.' }
    $script:observations += $state
}
function Move-Score([string]$id, [int]$index, [string[]]$expected) {
    $before = Invoke-McpTool $connection gp_documents
    $from = ($before.documents | Where-Object id -EQ $id).tab_index
    $moved = Invoke-McpTool $connection gp_move_document @{document=$id;index=$index}
    Assert ($moved.status -eq $(if ($from -eq $index) {'unchanged'} else {'moved'}) -and $moved.previous_index -eq $from -and $moved.tab_index -eq $index -and -not $moved.undoable) 'Unexpected move result.'
    Check-Order $expected $before.active_document
    $after = Invoke-McpTool $connection gp_documents
    foreach ($item in $before.documents) {
        $other = $after.documents | Where-Object id -EQ $item.id
        Assert ($other -and $other.dirty -eq $item.dirty -and $other.opened_path -eq $item.opened_path -and $other.save_path -eq $item.save_path) 'Moving changed document identity, paths or dirty state.'
    }
}
function Read-Title([string]$path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$xml = $reader.ReadToEnd(); $xml.GPIF.Score.Title.InnerText } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}
function Reject-Move([hashtable]$arguments) {
    $rejected = $false
    try { $rejected = [bool](Invoke-McpTool $connection gp_move_document $arguments -AllowError).error }
    catch {
        if ($_.Exception.Message -notmatch '"code":\s*-32602') { throw }
        $rejected = $true
    }
    Assert $rejected 'Invalid document move accepted.'
}
function Menu-Targets {
    $count = (Invoke-McpTool $connection gp_documents).documents.Count
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $actions = @((Invoke-McpTool $connection gp_actions @{query='OpenedDocumentAction_';include_hidden=$true;limit=100}).objects | Where-Object enabled)
        if ($actions.Count -eq $count) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($actions.Count -eq $count) 'Document menu actions did not become enabled.'
    $targets = @{}
    foreach ($action in $actions) {
        $snapshot = Invoke-McpTool $connection gp_actions @{query=$action.object_name;include_hidden=$true;limit=100}
        $exact = @($snapshot.objects | Where-Object object_name -EQ $action.object_name)
        Assert ($exact.Count -eq 1 -and $exact[0].enabled) 'Document menu action is unavailable.'
        Invoke-McpTool $connection gp_trigger @{snapshot=$snapshot.snapshot;id=$exact[0].id} | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $checked = @((Invoke-McpTool $connection gp_actions @{query=$action.object_name;include_hidden=$true;limit=100}).objects | Where-Object { $_.object_name -eq $action.object_name -and $_.checked })
            if ($checked.Count -eq 1) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert ($checked.Count -eq 1) 'Native document menu did not select its action.'
        $targets[$action.object_name] = (Invoke-McpTool $connection gp_documents).active_document
    }
    return $targets
}
try {
    $before = Invoke-McpTool $connection gp_documents
    Assert ($before.documents.Count -eq 1 -and -not $before.documents[0].dirty) 'Requires one clean fixture document.'
    $baseline = $before.documents[0]
    Assert ((Get-FileHash -LiteralPath $baseline.opened_path).Hash -eq $fixtureHash) 'Baseline differs from fixture.'
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.hidden_mode) 'Requires an isolated background host.'
    $ids = @($baseline.id); $paths = @{}
    foreach ($folder in @('a','b')) {
        $directory = New-Item -ItemType Directory -Path (Join-Path $run $folder)
        $path = Join-Path $directory.FullName 'same-name.gp'
        Copy-Item -LiteralPath $fixture -Destination $path
        $request = Invoke-McpTool $connection gp_open @{path=$path}
        $id = (Wait-Operation $request.request 'opened').document
        $ids += $id; $paths[$id] = $path
    }
    foreach ($i in 1..2) {
        $request = Invoke-McpTool $connection gp_new @{template='Nylon Guitar'}
        $ids += (Wait-Operation $request.request 'created').document
    }
    $a = $ids[1]; $b = $ids[2]; $c = $ids[3]; $d = $ids[4]
    Check-Order $ids $d
    $titles = @{}; $undoBefore = @{}
    foreach ($id in @($a,$b,$c,$d)) {
        $titles[$id] = 'Tab identity ' + $id
        Invoke-McpTool $connection gp_edit_metadata @{document=$id;property='Title';value=$titles[$id]} | Out-Null
        $undoBefore[$id] = Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'}
        Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
    }
    Assert (@((Invoke-McpTool $connection gp_documents).documents | Where-Object dirty).Count -eq 4) 'Expected four dirty documents.'
    Invoke-McpTool $connection gp_activate @{document=$b} | Out-Null
    Move-Score $d 0 @($d,$baseline.id,$a,$b,$c)
    Move-Score $b 0 @($b,$d,$baseline.id,$a,$c)
    Move-Score $b 4 @($d,$baseline.id,$a,$c,$b)
    Move-Score $b 4 @($d,$baseline.id,$a,$c,$b)
    foreach ($index in @(-1,5,1.5,'0',$null)) {
        Reject-Move @{document=$a;index=$index}
    }
    Reject-Move @{index=0}
    Reject-Move @{document='expired-document';index=0}
    Check-Order @($d,$baseline.id,$a,$c,$b) $b
    foreach ($id in @($a,$b,$c,$d)) {
        Assert ((Invoke-McpTool $connection gp_score @{document=$id}).metadata.Title -eq $titles[$id]) 'Moving changed score content.'
        $undo = Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'}
        Assert ($undo.metadata.Title -eq $undoBefore[$id].metadata.Title -and $undo.dirty -eq $undoBefore[$id].dirty -and $undo.undo_available -eq $undoBefore[$id].undo_available) 'Move replaced or damaged native undo history.'
        $redo = Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'}
        Assert ($redo.metadata.Title -eq $titles[$id] -and $redo.dirty) 'Redo restored the wrong document.'
    }
    Invoke-McpTool $connection gp_window @{state='restore'} | Out-Null
    if ($VerifyDocumentMenu) {
        $menuBefore = Menu-Targets
        Assert ($menuBefore.Count -eq 5 -and @($menuBefore.Values | Sort-Object -Unique).Count -eq 5) 'Document menu does not cover every document.'
    }
    Move-Score $c 0 @($c,$d,$baseline.id,$a,$b)
    if ($VerifyDocumentMenu) {
        $menuAfter = Menu-Targets
        foreach ($name in $menuBefore.Keys) { Assert ($menuAfter[$name] -eq $menuBefore[$name]) 'Moving retargeted a native document menu action.' }
        foreach ($cycle in 1..3) {
            Assert (-not (Invoke-McpTool $connection gp_window @{state='hide'}).visible) 'Window did not hide between menu checks.'
            $hidden = Invoke-McpTool $connection gp_capabilities
            Assert ($hidden.hidden_mode -and $hidden.foreground_pid -ne $hidden.pid) 'Menu checks lost background focus isolation.'
            Assert ((Invoke-McpTool $connection gp_window @{state='restore'}).visible) 'Window did not restore between menu checks.'
            $cycleTargets = Menu-Targets
            foreach ($name in $menuBefore.Keys) { Assert ($cycleTargets[$name] -eq $menuBefore[$name]) 'Restoring changed a document menu target.' }
        }
    }
    $tabs = @((Invoke-McpTool $connection gp_objects @{query='am::gui::Tab';limit=100}).objects | Where-Object class -EQ 'am::gui::Tab' | Sort-Object { $_.properties.x })
    Assert ($tabs.Count -eq 5 -and $tabs[2].properties.toolTip -eq $baseline.opened_path -and $tabs[3].properties.toolTip.EndsWith($paths[$a].Replace('\','/')) -and $tabs[4].properties.toolTip.EndsWith($paths[$b].Replace('\','/'))) 'Visible tab positions differ from document order.'
    Invoke-McpTool $connection gp_window @{state='hide'} | Out-Null
    $prompt = Invoke-McpTool $connection gp_close @{document=$c;unsaved='prompt'}
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $dialog = Invoke-McpTool $connection gp_dialogs
        if ($dialog.blocked) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($dialog.blocked) 'Expected native close dialog.'
    Assert ((Invoke-McpTool $connection gp_window @{state='restore'}).visible) 'Main window did not restore with a pending close dialog.'
    $restoredDialog = Invoke-McpTool $connection gp_dialogs
    Assert ($restoredDialog.blocked -and $restoredDialog.class -eq $dialog.class -and $restoredDialog.title -eq $dialog.title) 'Restoring lost the native close dialog.'
    Assert ((Invoke-McpTool $connection gp_move_document @{document=$a;index=0} -AllowError).error) 'Move entered an active document operation/dialog.'
    Invoke-McpTool $connection gp_cancel @{request=$prompt.request} | Out-Null
    Wait-Operation $prompt.request 'cancelled' | Out-Null
    Assert (-not (Invoke-McpTool $connection gp_window @{state='hide'}).visible) 'Window did not hide after cancelling the close dialog.'
    Check-Order @($c,$d,$baseline.id,$a,$b) $c
    Invoke-McpTool $connection gp_save_current @{document=$a} | Out-Null
    $paths[$b] = Join-Path $run 'adopted.gp'
    Invoke-McpTool $connection gp_save_as @{document=$b;path=$paths[$b]} | Out-Null
    $paths[$c] = Join-Path $run 'unnamed.gp'
    Invoke-McpTool $connection gp_save_as @{document=$c;path=$paths[$c]} | Out-Null
    foreach ($id in @($a,$b,$c)) { Assert ((Read-Title $paths[$id]) -eq $titles[$id]) 'Saved file belongs to another document.' }
    Assert ((Get-FileHash -LiteralPath (Join-Path $run 'b/same-name.gp')).Hash -eq $fixtureHash) 'Save As changed the old source.'
    Move-Score $c 4 @($d,$baseline.id,$a,$b,$c)
    Close-Score $b
    Assert ((Invoke-McpTool $connection gp_move_document @{document=$b;index=0} -AllowError).error) 'Closed document can still be moved.'
    Check-Order @($d,$baseline.id,$a,$c)
    Close-Score $d 'discard'
    Close-Score $a
    Close-Score $c
    foreach ($id in @($a,$b,$c)) {
        $request = Invoke-McpTool $connection gp_open @{path=$paths[$id]}
        $reopened = (Wait-Operation $request.request 'opened').document
        Assert ($reopened -notin $ids -and (Invoke-McpTool $connection gp_score @{document=$reopened}).metadata.Title -eq $titles[$id]) 'Reopen reused a stale ID or lost saved content.'
        Move-Score $reopened 0 @($reopened,$baseline.id)
        Close-Score $reopened
    }
    Check-Order @($baseline.id) $baseline.id
    Move-Score $baseline.id 0 @($baseline.id)
    Assert (-not (Invoke-McpTool $connection gp_score @{document=$baseline.id}).dirty) 'Baseline acquired unsaved changes.'
    Assert ((Get-FileHash -LiteralPath $baseline.opened_path).Hash -eq $fixtureHash -and (Get-FileHash -LiteralPath $fixture).Hash -eq $fixtureHash) 'Fixture bytes changed.'
    Assert ((Invoke-McpTool $connection gp_capabilities).hidden_mode) 'Test did not restore background mode.'
    $passed = $true
    Write-Output "PASS: $checks document tab checks. Evidence: $run"
} catch {
    Write-Warning "Failure: $($_.ScriptStackTrace)"
    throw
} finally {
    @{passed=$passed;checks=$checks;observations=$observations;menu_verified=($passed -and $VerifyDocumentMenu.IsPresent);menu_before=$menuBefore;menu_after=$menuAfter;visible_tabs=$tabs;host_pid=$connection.Pid;powershell=$PSVersionTable.PSVersion.ToString();plugin_sha256=(Get-FileHash -LiteralPath "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash} |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    Close-McpSession $connection
}
