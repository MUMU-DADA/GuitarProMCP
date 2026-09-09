param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = [IO.Path]::GetFullPath((Join-Path $projectRoot 'artifacts/native-test.gp'))
$fixtureHash = (Get-FileHash -LiteralPath "$PSScriptRoot/testdata/minimal.gp").Hash
if (-not (Test-Path -LiteralPath $sourcePath) -or (Get-FileHash -LiteralPath $sourcePath).Hash -ne $fixtureHash) {
    throw '请先复制 test/testdata/minimal.gp 到 artifacts/native-test.gp，再用 start-plugin.ps1 打开该测试副本。'
}
$checks = 0
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Read-Gpif([string]$path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $entry = $zip.GetEntry('Content/score.gpif')
        if (-not $entry) { throw 'Saved GP file has no GPIF score' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}
$connection = New-McpSession -SessionFile $SessionFile
try {
    $documents = Invoke-McpTool $connection gp_documents
    Assert ($documents.documents.Count -eq 1) 'Test requires exactly one document'
    $document = $documents.documents[0]
    Assert ($document.opened_path -eq $sourcePath.Replace('\','/') -and -not $document.dirty) 'Refusing to modify a different or dirty document'
    $startup = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    Assert (-not ($startup.objects | Where-Object class -EQ 'gp::gui::MainWindow').visible) 'Plugin did not maintain hidden startup mode'
    $hidden = Invoke-McpTool $connection gp_window @{state='hide'}
    Assert (-not $hidden.visible) 'Window did not hide'
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.pid -ne $identity.foreground_pid -and $identity.qt_thread) 'Host is foreground or tool is off the Qt thread'
    $before = Invoke-McpTool $connection gp_score
    $beforeBars = Invoke-McpTool $connection gp_read_bars @{count=2}
    Assert ($before.track_count -eq 1 -and $before.tracks[0].bars -eq 2) 'Fixture shape mismatch'
    Assert ($beforeBars.bars[0].voices[0].beats[0].notes[0].midi -eq 40) 'Native note read mismatch'
    $invalid = Invoke-McpTool $connection gp_edit_metadata @{property='Title';value='不能可靠保存 🎸'} -AllowError
    Assert ($null -ne $invalid.error) 'Host-incompatible Unicode was accepted'
    Assert ((Invoke-McpTool $connection gp_score).metadata.Title -eq $before.metadata.Title) 'Rejected edit changed metadata'
    Invoke-McpTool $connection gp_cursor @{axis='bar';index=1} | Out-Null
    Assert ((Invoke-McpTool $connection gp_score).cursor.bar -eq 1) 'Native cursor did not move'
    Invoke-McpTool $connection gp_cursor @{axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{axis='beat';index=0} | Out-Null
    $editedNote = Invoke-McpTool $connection gp_set_fret @{string=0;fret=5}
    Assert ($editedNote.note.fret -eq 5 -and $editedNote.note.midi -eq 45) 'Native fret/pitch edit failed'
    Invoke-McpTool $connection gp_undo_redo @{operation='undo'} | Out-Null
    $undone = Invoke-McpTool $connection gp_read_bars @{count=2}
    Assert (($undone.bars | ConvertTo-Json -Depth 20 -Compress) -eq ($beforeBars.bars | ConvertTo-Json -Depth 20 -Compress)) 'Undo did not restore all read notes'
    Invoke-McpTool $connection gp_undo_redo @{operation='redo'} | Out-Null
    Assert ((Invoke-McpTool $connection gp_read_bars).bars[0].voices[0].beats[0].notes[0].fret -eq 5) 'Native redo failed'
    $title = '原生后台曲谱验证'
    Invoke-McpTool $connection gp_edit_metadata @{property='Title';value=$title} | Out-Null
    $edited = Invoke-McpTool $connection gp_score
    Assert ($edited.metadata.Title -eq $title -and $edited.dirty) 'Native metadata/dirty state failed'
    $run = Join-Path $projectRoot ('artifacts/native-verification-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $copy = Invoke-McpTool $connection gp_save @{path=(Join-Path $run 'edited-copy.gp')}
    Assert ($copy.copy_only -and $copy.dirty) 'Save-copy unexpectedly changed saved state'
    $saved = Invoke-McpTool $connection gp_save_as @{path=(Join-Path $run 'edited.gp')}
    Assert (-not $saved.copy_only -and -not $saved.dirty) 'Native save-as did not complete saved-state bookkeeping'
    $gpif = Read-Gpif $saved.path
    Assert ($gpif.GPIF.Score.Title.InnerText -eq $title) 'Chinese metadata not preserved in GPIF'
    $fret = $gpif.SelectSingleNode('/GPIF/Notes/Note[@id="0"]/Properties/Property[@name="Fret"]/Fret')
    Assert ($fret.InnerText -eq '5') 'Native note change not preserved in GPIF'
    Assert (@($gpif.GPIF.Notes.Note).Count -eq 8) 'Unexpected note count in saved file'
    $rejectOverwrite = Invoke-McpTool $connection gp_save @{path=$saved.path} -AllowError
    Assert ($null -ne $rejectOverwrite.error) 'Existing output was accepted for overwrite'
    Invoke-McpTool $connection gp_undo_redo @{operation='undo'} | Out-Null
    Invoke-McpTool $connection gp_undo_redo @{operation='undo'} | Out-Null
    $restored = Invoke-McpTool $connection gp_score
    $restoredBars = Invoke-McpTool $connection gp_read_bars @{count=2}
    Assert ($restored.metadata.Title -eq $before.metadata.Title) 'Title restore failed'
    Assert (($restoredBars.bars | ConvertTo-Json -Depth 20 -Compress) -eq ($beforeBars.bars | ConvertTo-Json -Depth 20 -Compress)) 'Note restore failed'
    $restoredSave = Invoke-McpTool $connection gp_save_as @{path=(Join-Path $run 'restored.gp')}
    Assert (-not $restoredSave.dirty) 'Restored test document remains dirty'
    Assert ((Get-FileHash -LiteralPath $sourcePath).Hash -eq $fixtureHash) 'Original fixture copy changed'
    $afterIdentity = Invoke-McpTool $connection gp_capabilities
    Assert ($afterIdentity.pid -ne $afterIdentity.foreground_pid) 'Native operation brought host to foreground'
    $window = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    Assert (-not ($window.objects | Where-Object class -EQ 'gp::gui::MainWindow').visible) 'Host window became visible'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;before=$before;edited=$edited;note=$editedNote;saved=$saved;restored=$restoredSave;fixture_sha256=$fixtureHash} |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native background checks. Evidence: $run"
} finally { Close-McpSession $connection }
