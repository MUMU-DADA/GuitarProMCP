param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.Path]::GetFullPath((Join-Path $root 'artifacts/native-test.gp'))
$fixtureHash = (Get-FileHash -LiteralPath "$PSScriptRoot/testdata/minimal.gp").Hash
$checks = 0
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
$connection = New-McpSession -SessionFile $SessionFile
function Undo([string]$id) { Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'} | Out-Null }
function Bars([string]$id, [int]$count=2) { Invoke-McpTool $connection gp_read_bars @{document=$id;count=$count} }
function Same-Bars([string]$id, $expected) {
    Assert (((Bars $id).bars | ConvertTo-Json -Depth 20 -Compress) -eq ($expected.bars | ConvertTo-Json -Depth 20 -Compress)) 'Undo did not restore original bars'
}
function New-Score([string]$template) {
    $request = Invoke-McpTool $connection gp_new @{template=$template}
    Assert ($request.status -eq 'scheduled') 'New score was not scheduled'
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $documents = Invoke-McpTool $connection gp_documents
        if ($documents.creation.request -eq $request.request -and $documents.creation.status -ne 'scheduled') { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($documents.creation.request -eq $request.request -and $documents.creation.status -eq 'created') 'Template creation did not complete'
    $document = $documents.documents | Where-Object id -EQ $documents.creation.document
    Assert ($document -and $document.opened_path -eq '' -and $document.save_path -eq '') 'Template still has a file path instead of a new document'
    return $document.id
}
try {
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy changed'
    $documents = Invoke-McpTool $connection gp_documents
    $fixture = @($documents.documents | Where-Object opened_path -EQ $source.Replace('\','/'))
    Assert ($fixture.Count -eq 1 -and -not $fixture[0].dirty) 'Requires a clean artifacts/native-test.gp document'
    $id = $fixture[0].id
    Invoke-McpTool $connection gp_activate @{document=$id} | Out-Null
    Invoke-McpTool $connection gp_window @{state='hide'} | Out-Null
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.pid -ne $identity.foreground_pid -and $identity.qt_thread) 'Host is foreground or outside Qt thread'
    $run = Join-Path $root ('artifacts/native-structure-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    $clamped = Invoke-McpTool $connection gp_cursor @{document=$id;axis='beat';index=10000} -AllowError
    Assert ($clamped.error -and $clamped.cursor.beat -ne 10000) 'Clamped cursor position reported success'
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='beat';index=0} | Out-Null
    $before = Bars $id
    foreach ($arguments in @(
        @{operation='insert';index=-1}, @{operation='insert';index=0;count=0},
        @{operation='insert';index=0;count=129}, @{operation='remove';index=1;count=2}
    )) {
        $arguments.document = $id
        Assert ((Invoke-McpTool $connection gp_edit_bars $arguments -AllowError).error) 'Invalid bar range accepted'
    }
    Same-Bars $id $before

    $inserted = Invoke-McpTool $connection gp_edit_bars @{document=$id;operation='insert';index=1;count=2}
    Assert ($inserted.tracks[0].bars -eq 4) 'Middle insertion bar count differs'
    $middle = Bars $id 4
    Assert (($middle.bars[0].voices | ConvertTo-Json -Depth 15 -Compress) -eq ($before.bars[0].voices | ConvertTo-Json -Depth 15 -Compress)) 'Insertion changed preceding bar'
    Assert (($middle.bars[3].voices | ConvertTo-Json -Depth 15 -Compress) -eq ($before.bars[1].voices | ConvertTo-Json -Depth 15 -Compress)) 'Insertion did not shift following bar'
    Undo $id
    Same-Bars $id $before
    foreach ($position in @(0,2)) {
        $inserted = Invoke-McpTool $connection gp_edit_bars @{document=$id;operation='insert';index=$position}
        Assert ($inserted.tracks[0].bars -eq 3) 'Beginning/end insertion failed'
        Undo $id
        Same-Bars $id $before
    }
    $removed = Invoke-McpTool $connection gp_edit_bars @{document=$id;operation='remove';index=0}
    Assert ($removed.tracks[0].bars -eq 1 -and (Bars $id 1).bars[0].voices[0].beats[0].notes[0].midi -eq 47) 'Removal did not preserve remaining bar'
    Undo $id
    Same-Bars $id $before
    $empty = Invoke-McpTool $connection gp_edit_bars @{document=$id;operation='remove';index=0;count=2}
    Assert ($empty.tracks[0].bars -eq 1 -and (Bars $id 1).bars[0].voices[0].beats.Count -eq 0) 'Removing all bars did not leave the native empty bar'
    Undo $id
    Same-Bars $id $before
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='beat';index=1} | Out-Null
    $insertedBeat = Invoke-McpTool $connection gp_edit_beat @{document=$id;operation='insert';denominator=8;dots=1}
    $beats = $insertedBeat.bars[0].voices[0].beats
    Assert ($beats.Count -eq 5 -and $beats[1].rest -and $beats[1].rhythm.StartsWith('Eighth;Dots=1;')) 'Dotted rest insertion differs'
    Assert ($beats[2].notes[0].midi -eq 42) 'Inserted beat did not preserve following note'
    Undo $id
    Same-Bars $id $before
    Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'fixture-restored.gp')} | Out-Null

    $templates = Invoke-McpTool $connection gp_templates
    Assert ($templates.templates -contains 'Nylon Guitar' -and $templates.templates -contains 'Acoustic Piano' -and $templates.templates -contains 'Metal Band') 'Built-in templates missing'
    Assert ((Invoke-McpTool $connection gp_new @{template='../Empty'} -AllowError).error) 'Non-listed template accepted'
    $first = New-Score 'Nylon Guitar'
    $second = New-Score 'Nylon Guitar'
    Assert ($first -ne $second) 'Repeated template creation reused an existing document'
    $initial = Invoke-McpTool $connection gp_score @{document=$first}
    Assert ($initial.track_count -eq 1 -and $initial.cursor.selection.placeholder) 'New guitar score has unexpected initial state'
    $note = Invoke-McpTool $connection gp_edit_note @{document=$first;operation='set';string=0;fret=3}
    Assert ($note.notes[0].midi -eq 43 -and -not $note.cursor.selection.placeholder) 'Placeholder note input did not create a real beat'
    $dirtyStates = Invoke-McpTool $connection gp_documents
    Assert ($note.dirty -and ($dirtyStates.documents | Where-Object id -EQ $first).dirty -and -not ($dirtyStates.documents | Where-Object id -EQ $second).dirty) 'Inactive-document edit marked the wrong document dirty'
    Undo $first
    Assert (@((Bars $first 1).bars[0].voices[0].beats | ForEach-Object { $_.notes }).Count -eq 0) 'Undo of first note left note data'
    Invoke-McpTool $connection gp_undo_redo @{document=$first;operation='redo'} | Out-Null
    Assert ((Bars $first 1).bars[0].voices[0].beats[0].notes[0].midi -eq 43) 'First note redo failed'
    $saved = Invoke-McpTool $connection gp_save_as @{document=$first;path=(Join-Path $run 'new-guitar.gp')}
    $zip = [IO.Compression.ZipFile]::OpenRead($saved.path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$gpif = $reader.ReadToEnd() } finally { $reader.Dispose() }
        Assert ($gpif.SelectSingleNode('/GPIF/Notes/Note/Properties/Property[@name="Fret"]/Fret').InnerText -eq '3') 'First note missing from saved GPIF'
    } finally { $zip.Dispose() }
    $rest = Invoke-McpTool $connection gp_edit_beat @{document=$second;operation='insert';denominator=8;dots=1}
    $realBeats = @($rest.bars[0].voices[0].beats | Where-Object { -not $_.placeholder })
    Assert ($realBeats.Count -eq 1 -and $realBeats[0].rest -and $realBeats[0].dots -eq 1) 'Empty-score rest creation failed'
    Invoke-McpTool $connection gp_save_as @{document=$second;path=(Join-Path $run 'new-rest.gp')} | Out-Null

    $band = New-Score 'Metal Band'
    $bandBefore = Invoke-McpTool $connection gp_score @{document=$band}
    Assert ($bandBefore.track_count -gt 1) 'Band template has only one track'
    $bandInserted = Invoke-McpTool $connection gp_edit_bars @{document=$band;operation='insert';index=0;count=2}
    Assert (@($bandInserted.tracks | Where-Object bars -NE 3).Count -eq 0) 'Bar insertion did not affect all tracks'
    $bandRemoved = Invoke-McpTool $connection gp_edit_bars @{document=$band;operation='remove';index=1;count=2}
    Assert (@($bandRemoved.tracks | Where-Object bars -NE 1).Count -eq 0) 'Bar deletion did not affect all tracks'
    Undo $band
    Undo $band
    $bandRestored = Invoke-McpTool $connection gp_score @{document=$band}
    Assert (@($bandRestored.tracks | Where-Object bars -NE 1).Count -eq 0) 'Band bar undo failed'
    Invoke-McpTool $connection gp_save_as @{document=$band;path=(Join-Path $run 'new-band.gp')} | Out-Null
    $piano = New-Score 'Acoustic Piano'
    Assert ((Invoke-McpTool $connection gp_score @{document=$piano}).tracks[0].staves -eq 2) 'Piano template did not create two staves'
    $staffCursor = Invoke-McpTool $connection gp_cursor @{document=$piano;axis='staff';index=1}
    Assert ($staffCursor.cursor.staff -eq 1) 'Native lower-staff navigation failed'
    $upperBefore = Invoke-McpTool $connection gp_read_bars @{document=$piano;staff=0}
    Invoke-McpTool $connection gp_edit_beat @{document=$piano;operation='insert';denominator=4} | Out-Null
    $lower = Invoke-McpTool $connection gp_read_bars @{document=$piano;staff=1}
    Assert (@($lower.bars[0].voices[0].beats | Where-Object { -not $_.placeholder -and $_.rest }).Count -eq 1) 'Rest insertion did not reach lower staff'
    $upperAfter = Invoke-McpTool $connection gp_read_bars @{document=$piano;staff=0}
    Assert (($upperAfter.bars | ConvertTo-Json -Depth 15 -Compress) -eq ($upperBefore.bars | ConvertTo-Json -Depth 15 -Compress)) 'Lower-staff edit changed upper staff'
    Undo $piano
    Assert ((Invoke-McpTool $connection gp_cursor @{document=$piano;axis='staff';index=0}).cursor.staff -eq 0) 'Native upper-staff navigation failed'
    Assert ((Invoke-McpTool $connection gp_cursor @{document=$piano;axis='staff';index=2} -AllowError).error) 'Out-of-range staff accepted'
    Assert ((Invoke-McpTool $connection gp_score @{document=$piano}).cursor.staff -eq 0) 'Invalid staff request changed cursor'
    Invoke-McpTool $connection gp_save_as @{document=$piano;path=(Join-Path $run 'new-piano.gp')} | Out-Null
    Invoke-McpTool $connection gp_activate @{document=$id} | Out-Null
    $afterIdentity = Invoke-McpTool $connection gp_capabilities
    Assert ($afterIdentity.foreground_pid -ne $afterIdentity.pid) 'Host entered foreground'
    $window = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    Assert (-not ($window.objects | Where-Object class -EQ 'gp::gui::MainWindow').visible) 'Host became visible'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Original fixture changed'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;bar_insert=$middle;beat_insert=$insertedBeat;new_note=$note;saved=$saved;band_insert=$bandInserted;band_remove=$bandRemoved;templates=$templates;lower_staff=$lower} |
        ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native structure/template checks. Evidence: $run"
} finally { Close-McpSession $connection }
