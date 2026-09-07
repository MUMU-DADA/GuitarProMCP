param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $PSScriptRoot 'testdata/minimal.gp'
$fixtureHash = (Get-FileHash -LiteralPath $fixture).Hash
$run = Join-Path $root ('artifacts/native-saving-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$checks = 0
$observations = @()
$passed = $false
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Title([string]$path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$xml = $reader.ReadToEnd(); $xml.GPIF.Score.Title.InnerText } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}
$connection = New-McpSession -SessionFile $SessionFile
function Document($id) { (Invoke-McpTool $connection gp_documents).documents | Where-Object id -EQ $id }
function Assert-DocumentLabel([string]$id, [string]$path) {
    Invoke-McpTool $connection gp_activate @{document=$id} | Out-Null
    $state = Document $id
    $name = [IO.Path]::GetFileNameWithoutExtension($path)
    Assert ($state.opened_path -eq $path.Replace('\','/') -and $state.save_path -eq $state.opened_path) 'Save As did not adopt both native paths.'
    $tabs = @((Invoke-McpTool $connection gp_objects @{query='am::gui::Tab';limit=100}).objects | Where-Object { $_.class -eq 'am::gui::Tab' -and $_.properties.selected })
    Assert ($tabs.Count -eq 1 -and $tabs[0].properties.text -eq $name -and $tabs[0].properties.toolTip -eq $state.opened_path -and -not $tabs[0].properties.dirty) 'Saved document tab label or path is stale.'
    $windows = @((Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}).objects | Where-Object class -EQ 'gp::gui::MainWindow')
    Assert ($windows.Count -eq 1 -and $windows[0].properties.windowTitle.Contains($name)) 'Saved document window title is stale.'
    # Closed documents can leave checked QAction objects in the host registry.
    # This host names each live tab and its document action with the same suffix.
    if ($tabs[0].object_name -notmatch '^Tab_(\d+)$') { throw 'Cannot identify the saved document menu action.' }
    $actionName = 'OpenedDocumentAction_' + $Matches[1]
    $actions = @((Invoke-McpTool $connection gp_actions @{query=$actionName;include_hidden=$true;limit=100}).objects | Where-Object object_name -EQ $actionName)
    Assert ($actions.Count -eq 1 -and $actions[0].checked -and $actions[0].text -eq "&$($state.tab_index) $name") 'Saved document menu label is stale.'
}
function Open-Score([string]$path) {
    Invoke-McpTool $connection gp_open @{path=$path} | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $found = @((Invoke-McpTool $connection gp_documents).documents | Where-Object { $_.opened_path -and [IO.Path]::GetFullPath($_.opened_path) -eq $path })
        if ($found.Count -eq 1) { return $found[0] }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Test score did not open.'
}
function Close-Score([string]$id) {
    $operation = Invoke-McpTool $connection gp_close @{document=$id}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = Invoke-McpTool $connection gp_documents
        if ($state.closing.request -eq $operation.request -and $state.closing.status -eq 'closed') { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Test score did not close.'
}
try {
    $before = Invoke-McpTool $connection gp_documents
    Assert ($before.documents.Count -eq 1 -and -not $before.documents[0].dirty) 'Saving checks require one clean baseline document.'
    $baseline = $before.documents[0]
    Assert ((Get-FileHash -LiteralPath $baseline.opened_path).Hash -eq $fixtureHash) 'Baseline does not match the fixture.'
    $workingPath = Join-Path $run 'working.gp'
    $existingPath = Join-Path $run 'existing.gp'
    Copy-Item -LiteralPath $fixture -Destination $workingPath
    Copy-Item -LiteralPath $fixture -Destination $existingPath
    $working = Open-Score $workingPath
    Invoke-McpTool $connection gp_edit_metadata @{document=$working.id;property='Title';value='Save current roundtrip'} | Out-Null
    $saved = Invoke-McpTool $connection gp_save_current @{document=$working.id}
    $observations += $saved
    Assert ($saved.overwrote -and -not $saved.copy_only -and -not $saved.dirty) 'Save current did not commit native saved state.'
    Assert ((Title $workingPath) -eq 'Save current roundtrip') 'Save current did not persist the title.'
    Assert ([IO.Path]::GetFullPath((Document $working.id).save_path) -eq $workingPath) 'Save current changed the document path.'
    Invoke-McpTool $connection gp_undo_redo @{document=$working.id;operation='undo'} | Out-Null
    Assert ((Document $working.id).dirty) 'Undo after save did not mark the document dirty.'
    Invoke-McpTool $connection gp_undo_redo @{document=$working.id;operation='redo'} | Out-Null
    Assert ((Invoke-McpTool $connection gp_score @{document=$working.id}).metadata.Title -eq 'Save current roundtrip') 'Redo after saving did not restore score content.'
    $observations += @{dirty_after_redo_to_saved_content=(Document $working.id).dirty}
    Assert (-not (Invoke-McpTool $connection gp_save_current @{document=$working.id}).dirty) 'Saving again after redo did not restore native clean state.'
    Invoke-McpTool $connection gp_edit_metadata @{document=$working.id;property='Title';value='Explicit overwrite roundtrip'} | Out-Null
    Assert ((Invoke-McpTool $connection gp_save @{document=$working.id;path=$existingPath} -AllowError).error) 'Copy silently overwrote an existing file.'
    Assert ((Get-FileHash -LiteralPath $existingPath).Hash -eq $fixtureHash) 'Rejected overwrite changed destination bytes.'
    $copy = Invoke-McpTool $connection gp_save @{document=$working.id;path=$existingPath;overwrite=$true}
    Assert ($copy.copy_only -and $copy.overwrote -and $copy.dirty) 'Copy changed native dirty state.'
    Assert ((Title $existingPath) -eq 'Explicit overwrite roundtrip') 'Explicit copy overwrite did not persist content.'
    Assert ([IO.Path]::GetFullPath((Document $working.id).save_path) -eq $workingPath) 'Copy adopted the destination path.'
    Assert ((Document $working.id).opened_path -eq $workingPath.Replace('\','/')) 'Copy changed the native opened path.'
    Assert ((Invoke-McpTool $connection gp_save @{document=$working.id;path=$workingPath;overwrite=$true} -AllowError).error) 'Copy overwrote its own document without updating native saved state.'
    Assert ((Invoke-McpTool $connection gp_save_as @{document=$working.id;path=$baseline.opened_path;overwrite=$true} -AllowError).error) 'Save As overwrote another open document.'
    $existingHash = (Get-FileHash -LiteralPath $existingPath).Hash
    $locked = [IO.File]::Open($existingPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = Invoke-McpTool $connection gp_save_as @{document=$working.id;path=$existingPath;overwrite=$true} -AllowError
        $observations += $failed
        Assert ([bool]$failed.error) 'Save As accepted a locked destination.'
    } finally { $locked.Dispose() }
    Assert ((Get-FileHash -LiteralPath $existingPath).Hash -eq $existingHash) 'Failed Save As damaged the old destination.'
    Assert ((Document $working.id).dirty -and [IO.Path]::GetFullPath((Document $working.id).save_path) -eq $workingPath) 'Failed Save As changed the document path or dirty state.'
    $locked = [IO.File]::Open($workingPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Assert ((Invoke-McpTool $connection gp_save_current @{document=$working.id} -AllowError).error) 'Save current accepted a locked file.' } finally { $locked.Dispose() }
    Assert ((Title $workingPath) -eq 'Save current roundtrip' -and (Document $working.id).dirty) 'Failed current save lost prior bytes or unsaved changes.'
    Assert ((Invoke-McpTool $connection gp_save_as @{document=$working.id;path=(Join-Path $run 'missing/out.gp')} -AllowError).error) 'Save As accepted a missing directory.'
    Assert ((Invoke-McpTool $connection gp_save_as @{document=$working.id;path=$existingPath} -AllowError).error) 'Save As overwrote without explicit consent.'
    $adopted = Invoke-McpTool $connection gp_save_as @{document=$working.id;path=$existingPath;overwrite=$true}
    $observations += $adopted
    Assert (-not $adopted.dirty -and [IO.Path]::GetFullPath((Document $working.id).save_path) -eq $existingPath) 'Explicit Save As did not adopt and clean the document.'
    Assert ((Title $existingPath) -eq 'Explicit overwrite roundtrip') 'Save As content differs.'
    Assert-DocumentLabel $working.id $existingPath
    $original = Open-Score $workingPath
    Assert ($original.id -ne $working.id -and (Invoke-McpTool $connection gp_score @{document=$original.id}).metadata.Title -eq 'Save current roundtrip') 'Old source path still aliases the adopted document.'
    Close-Score $original.id
    $same = Invoke-McpTool $connection gp_open @{path=$existingPath}
    Assert ($same.status -eq 'already_open' -and $same.document -eq $working.id) 'Adopted path did not resolve to its existing document.'
    Close-Score $working.id
    $reopened = Open-Score $existingPath
    Assert ($reopened.id -ne $working.id -and (Invoke-McpTool $connection gp_score @{document=$reopened.id}).metadata.Title -eq 'Explicit overwrite roundtrip') 'Saved file did not reopen with a fresh identity and correct content.'
    Close-Score $reopened.id
    $new = Invoke-McpTool $connection gp_new @{template='Nylon Guitar'}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = Invoke-McpTool $connection gp_documents
        if ($state.creation.request -eq $new.request -and $state.creation.status -eq 'created') { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($state.creation.request -eq $new.request -and $state.creation.status -eq 'created') 'Unnamed test document was not created.'
    Assert ((Invoke-McpTool $connection gp_save_current @{document=$state.creation.document} -AllowError).error) 'Unnamed document saved without a destination.'
    $namedPath = Join-Path $run ('saved-' + [char]0x4e2d + ' score.gp')
    Invoke-McpTool $connection gp_edit_metadata @{document=$state.creation.document;property='Title';value='Named template'} | Out-Null
    Invoke-McpTool $connection gp_save_as @{document=$state.creation.document;path=$namedPath} | Out-Null
    Assert-DocumentLabel $state.creation.document $namedPath
    Invoke-McpTool $connection gp_undo_redo @{document=$state.creation.document;operation='undo'} | Out-Null
    Assert ((Document $state.creation.document).dirty -and (Document $state.creation.document).opened_path -eq $namedPath.Replace('\','/')) 'Undo changed the adopted path or lost dirty state.'
    Invoke-McpTool $connection gp_undo_redo @{document=$state.creation.document;operation='redo'} | Out-Null
    Invoke-McpTool $connection gp_save_current @{document=$state.creation.document} | Out-Null
    Assert-DocumentLabel $state.creation.document $namedPath
    Assert ((Title $namedPath) -eq 'Named template') 'Named template lost saved content.'
    Close-Score $state.creation.document
    Assert (-not @(Get-ChildItem -LiteralPath $run -Directory -Filter '.gpmcp-save-*').Count) 'Finished saves left recovery directories.'
    $after = Invoke-McpTool $connection gp_documents
    Assert ($after.documents.Count -eq 1 -and $after.documents[0].id -eq $baseline.id -and -not $after.documents[0].dirty) 'Saving checks changed the baseline document.'
    Assert ((Get-FileHash -LiteralPath $baseline.opened_path).Hash -eq $fixtureHash) 'Saving checks changed baseline bytes.'
    $passed = $true
} finally {
    Close-McpSession $connection
    @{passed=$passed;checks=$checks;observations=$observations;host_pid=$connection.Pid;recovery_after_native_failure_verified=$false;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
}
Write-Output "PASS: $checks save-current, explicit overwrite, rejected-write preservation and reopen checks. Evidence: $run"
