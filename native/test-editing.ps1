param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.Path]::GetFullPath((Join-Path $root 'artifacts/native-test.gp'))
$fixtureHash = (Get-FileHash -LiteralPath "$PSScriptRoot/testdata/minimal.gp").Hash
$checks = 0
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
$connection = New-McpSession -SessionFile $SessionFile
function Bars { Invoke-McpTool $connection gp_read_bars @{count=2} }
function Undo { Invoke-McpTool $connection gp_undo_redo @{operation='undo'} | Out-Null }
function Same-Bars($expected) {
    Assert (((Bars).bars | ConvertTo-Json -Depth 20 -Compress) -eq ($expected.bars | ConvertTo-Json -Depth 20 -Compress)) 'Score content differs after undo'
}
function Read-Gpif([string]$path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}
try {
    $documents = Invoke-McpTool $connection gp_documents
    Assert ($documents.documents.Count -eq 1) 'Test requires exactly one fixture document'
    $document = $documents.documents[0]
    Assert ($document.opened_path -eq $source.Replace('\','/') -and -not $document.dirty) 'Refusing to edit a different or dirty document'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy was changed'
    Invoke-McpTool $connection gp_window @{state='hide'} | Out-Null
    Invoke-McpTool $connection gp_cursor @{axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{axis='beat';index=0} | Out-Null
    $before = Bars
    Assert ($before.bars[0].voices[0].beats.Count -eq 4 -and $before.bars[0].voices[0].beats[0].notes[0].midi -eq 40) 'Fixture shape mismatch'
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.pid -ne $identity.foreground_pid -and $identity.qt_thread) 'Host is foreground or outside Qt thread'
    $run = Join-Path $root ('artifacts/native-editing-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null

    foreach ($case in @(
        @{tool='gp_edit_note';arguments=@{operation='set';string=6;fret=3}},
        @{tool='gp_edit_note';arguments=@{operation='set';string=1;fret=37}},
        @{tool='gp_edit_note';arguments=@{operation='remove';string=0;fret=0}},
        @{tool='gp_edit_beat';arguments=@{operation='rhythm';denominator=3}},
        @{tool='gp_edit_beat';arguments=@{operation='rhythm';denominator=8;dots=1}},
        @{tool='gp_edit_beat';arguments=@{operation='dots';dots=3}},
        @{tool='gp_edit_beat';arguments=@{operation='clear';denominator=8}}
    )) {
        $rejected = Invoke-McpTool $connection $case.tool $case.arguments -AllowError
        Assert ($null -ne $rejected.error) 'Invalid edit was accepted'
    }
    Same-Bars $before

    $added = Invoke-McpTool $connection gp_edit_note @{operation='set';string=1;fret=3}
    $chord = Bars
    $notes = $chord.bars[0].voices[0].beats[0].notes
    Assert ($notes.Count -eq 2 -and ($notes | Where-Object string -EQ 1).midi -eq 48) 'Chord note was not added'
    Assert ($added.cursor.beat -eq 0) 'Note edit moved to another beat'
    Undo
    Same-Bars $before
    Invoke-McpTool $connection gp_undo_redo @{operation='redo'} | Out-Null
    Same-Bars $chord
    Invoke-McpTool $connection gp_edit_note @{operation='set';string=1;fret=5} | Out-Null
    $updated = (Bars).bars[0].voices[0].beats[0].notes
    Assert ($updated.Count -eq 2 -and ($updated | Where-Object string -EQ 1).midi -eq 50) 'Set duplicated or failed to update the note'
    Undo
    Same-Bars $chord
    Invoke-McpTool $connection gp_edit_note @{operation='remove';string=1} | Out-Null
    Same-Bars $before
    Undo
    Same-Bars $chord
    Undo
    Same-Bars $before

    Invoke-McpTool $connection gp_edit_note @{operation='remove';string=0} | Out-Null
    $rest = (Bars).bars[0].voices[0].beats[0]
    Assert ($rest.rest -and $rest.notes.Count -eq 0 -and $rest.native_note_value -eq 4) 'Removing the last note did not preserve a rest'
    Invoke-McpTool $connection gp_edit_note @{operation='set';string=0;fret=2} | Out-Null
    $fromRest = (Bars).bars[0].voices[0].beats[0]
    Assert (-not $fromRest.rest -and $fromRest.notes[0].midi -eq 42) 'Cannot create a note on a rest'
    Undo
    Undo
    Same-Bars $before

    foreach ($denominator in @(1,2,8,16,32,64,128)) {
        Invoke-McpTool $connection gp_edit_beat @{operation='rhythm';denominator=$denominator} | Out-Null
        $changed = (Bars).bars[0].voices[0].beats[0]
        Assert ($changed.native_note_value -eq (2 + [int][Math]::Log($denominator, 2)) -and $changed.notes[0].midi -eq 40) 'Note value mapping or pitch changed'
        Undo
        Same-Bars $before
    }
    foreach ($dots in @(1,2,0)) {
        Invoke-McpTool $connection gp_edit_beat @{operation='dots';dots=$dots} | Out-Null
        Assert ((Bars).bars[0].voices[0].beats[0].dots -eq $dots) 'Dots did not match'
    }
    Undo
    Assert ((Bars).bars[0].voices[0].beats[0].dots -eq 2) 'Undo did not restore double dots'
    Undo
    Undo
    Same-Bars $before

    Invoke-McpTool $connection gp_edit_beat @{operation='clear'} | Out-Null
    $cleared = (Bars).bars[0].voices[0]
    Assert ($cleared.beats.Count -eq 4 -and $cleared.beats[0].rest) 'Clear did not preserve beat duration/count'
    Undo
    Same-Bars $before
    Invoke-McpTool $connection gp_edit_beat @{operation='remove'} | Out-Null
    $removed = (Bars).bars[0].voices[0]
    Assert ($removed.beats.Count -eq 3 -and $removed.beats[0].notes[0].midi -eq 42) 'Remove did not shift the remaining beats'
    Undo
    Same-Bars $before

    Invoke-McpTool $connection gp_edit_note @{operation='set';string=1;fret=3} | Out-Null
    Invoke-McpTool $connection gp_edit_beat @{operation='dots';dots=1} | Out-Null
    Invoke-McpTool $connection gp_edit_beat @{operation='rhythm';denominator=8} | Out-Null
    $edited = Bars
    Assert ($edited.bars[0].voices[0].beats[0].dots -eq 1) 'Changing note value removed existing dots'
    $saved = Invoke-McpTool $connection gp_save @{path=(Join-Path $run 'edited.gp')}
    $gpif = Read-Gpif $saved.path
    # GPIF deduplicates equal note definitions; count beat references, not definitions.
    $noteReferences = @($gpif.SelectNodes('/GPIF/Beats/Beat/Notes') | ForEach-Object { $_.InnerText.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) })
    Assert ($noteReferences.Count -eq 9) 'Added note missing from GPIF beat references'
    $firstBeat = $gpif.SelectSingleNode('/GPIF/Beats/Beat[@id="0"]')
    $noteIds = $firstBeat.Notes.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    Assert ($noteIds.Count -eq 2) 'GPIF first beat is not a chord'
    $savedNotes = @($noteIds | ForEach-Object { $gpif.SelectSingleNode("/GPIF/Notes/Note[@id='$_']") })
    $newNote = $savedNotes | Where-Object { $_.SelectSingleNode('Properties/Property[@name="String"]/String').InnerText -eq '1' }
    Assert ($newNote.SelectSingleNode('Properties/Property[@name="Fret"]/Fret').InnerText -eq '3') 'GPIF chord fret differs'
    $rhythmId = $firstBeat.Rhythm.ref
    $rhythm = $gpif.SelectSingleNode("/GPIF/Rhythms/Rhythm[@id='$rhythmId']")
    Assert ($rhythm.NoteValue -eq 'Eighth' -and $rhythm.AugmentationDot.count -eq '1') 'GPIF dotted eighth differs'
    Undo
    Undo
    Undo
    Same-Bars $before
    $restored = Invoke-McpTool $connection gp_save_as @{path=(Join-Path $run 'restored.gp')}
    Assert (-not $restored.dirty) 'Restored document is dirty'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Original fixture was modified'
    $afterIdentity = Invoke-McpTool $connection gp_capabilities
    Assert ($afterIdentity.foreground_pid -ne $afterIdentity.pid) 'Host entered foreground'
    $window = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    Assert (-not ($window.objects | Where-Object class -EQ 'gp::gui::MainWindow').visible) 'Host became visible'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;added=$added;edited=$edited;saved=$saved;restored=$restored;fixture_sha256=$fixtureHash} |
        ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native editing checks. Evidence: $run"
} finally { Close-McpSession $connection }
