param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.Path]::GetFullPath((Join-Path $root 'artifacts/native-test.gp'))
$fixtureHash = (Get-FileHash -LiteralPath "$PSScriptRoot/testdata/minimal.gp").Hash
$checks = 0
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++; $script:lastCheck = $message }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 20 -Compress }
$connection = New-McpSession -SessionFile $SessionFile
function Score { Invoke-McpTool $connection gp_score @{document=$id} }
function Bars([int]$track=0, [int]$staff=0) { Invoke-McpTool $connection gp_read_bars @{document=$id;track=$track;staff=$staff;count=2} }
function Undo { Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'} | Out-Null }
try {
    $documents = Invoke-McpTool $connection gp_documents
    Assert ($documents.documents.Count -eq 1) 'Requires only artifacts/native-test.gp open'
    $fixture = $documents.documents[0]
    Assert ($fixture.opened_path -eq $source.Replace('\','/') -and -not $fixture.dirty) 'Refusing to edit another or dirty document'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy changed'
    $id = $fixture.id
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.pid -ne $identity.foreground_pid -and $identity.qt_thread -and $identity.hidden_mode) 'Host is not in native background mode'
    $run = Join-Path $root ('artifacts/native-tracks-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $before = Score
    $beforeBars = Bars
    Assert ($before.track_count -eq 1 -and $before.tracks[0].instrument_type -eq 'steelGuitar') 'Native track identity differs from fixture'
    Assert ($before.tracks[0].playback_state -eq 'Default' -and $before.tracks[0].pan -eq 0.5 -and $before.tracks[0].volume -gt 0) 'Native track playback state is missing'
    Assert ($before.tracks[0].color -eq '#c80000') 'Native color differs from fixture GPIF'
    foreach ($arguments in @(
        @{operation='duplicate';track=-1}, @{operation='remove';track=1},
        @{operation='swap';track=0;other=1}, @{operation='duplicate';track=0;other=0}
    )) {
        $arguments.document = $id
        Assert ((Invoke-McpTool $connection gp_edit_tracks $arguments -AllowError).error) 'Invalid structural track request accepted'
    }
    foreach ($value in @('无法保存 🎸',[string][char]0xffff,[string][char]0xfffe,[string][char]1)) {
        Assert ((Invoke-McpTool $connection gp_edit_track @{document=$id;track=0;property='name';value=$value} -AllowError).error) 'Invalid track text accepted'
    }
    Assert ((Invoke-McpTool $connection gp_edit_metadata @{document=$id;property='Title';value=([string][char]0xffff)} -AllowError).error) 'Invalid XML character accepted as metadata'
    foreach ($arguments in @(
        @{property='color';value='red'}, @{property='color';value='#abc'},
        @{property='color';value='#12345678'}, @{property='color';value='#GG0000'},
        @{property='color';value=123456}, @{property='name';value=1},
        @{property='pan';value=-0.01}, @{property='pan';value=1.01},
        @{property='volume';value=-0.01}, @{property='volume';value=1.01},
        @{property='volume';value='0.5'}, @{property='pan';value=$true},
        @{property='pan';value=$null}, @{property='volume';value=@(0.5)},
        @{property='playback_state';value=1}, @{property='invalid';value='x'}
    )) {
        $arguments.document = $id
        $arguments.track = 0
        Assert ((Invoke-McpTool $connection gp_edit_track $arguments -AllowError).error) 'Invalid track property request accepted'
    }
    Assert ((Json (Score).tracks) -eq (Json $before.tracks) -and -not (Score).dirty) 'Rejected requests changed track state'

    $duplicate = Invoke-McpTool $connection gp_edit_tracks @{document=$id;operation='duplicate';track=0}
    Assert ($duplicate.track_count -eq 2 -and $duplicate.dirty) 'Track duplication failed'
    Assert ((Json (Bars 1).bars) -eq (Json $beforeBars.bars)) 'Duplicated track lost score content'
    Invoke-McpTool $connection gp_edit_track @{document=$id;track=1;property='name';value='副旋律吉他'} | Out-Null
    Invoke-McpTool $connection gp_edit_track @{document=$id;track=1;property='short_name';value='副吉他'} | Out-Null
    Assert ((Score).tracks[0].name -eq $before.tracks[0].name -and (Score).tracks[1].name -eq '副旋律吉他') 'Renaming clone changed source track'
    Undo
    Assert ((Score).tracks[1].short_name -eq $before.tracks[0].short_name) 'Track short-name undo failed'
    Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
    Assert ((Score).tracks[1].short_name -eq '副吉他') 'Track short-name redo failed'
    foreach ($state in @('Solo','Mute','Default')) {
        $changed = Invoke-McpTool $connection gp_edit_track @{document=$id;track=1;property='playback_state';value=$state}
        Assert ($changed.tracks[1].playback_state -eq $state -and -not $changed.undoable) 'Track playback state readback differs'
    }
    Assert ((Invoke-McpTool $connection gp_edit_track @{document=$id;track=1;property='playback_state';value='invalid'} -AllowError).error) 'Invalid playback state accepted'
    foreach ($property in @('volume','pan')) {
        foreach ($value in @(0,1)) {
            $changed = Invoke-McpTool $connection gp_edit_track @{document=$id;track=1;property=$property;value=$value}
            Assert ($changed.tracks[1].$property -eq $value -and $changed.undoable -and $changed.dirty) "Track $property boundary readback differs"
            Undo
            Assert ((Score).tracks[1].$property -eq $before.tracks[0].$property) "Track $property boundary undo failed"
        }
    }
    foreach ($arguments in @(
        @{property='color';value='#1263D4'}, @{property='volume';value=0.625}, @{property='pan';value=0.25}
    )) {
        $arguments.document = $id
        $arguments.track = 1
        $property = $arguments.property
        $changed = Invoke-McpTool $connection gp_edit_track $arguments
        Assert ($changed.tracks[1].$property -eq $arguments.value -and $changed.undoable) "Track $property readback differs"
        Invoke-McpTool $connection gp_edit_track $arguments | Out-Null
        Undo
        Assert ((Score).tracks[1].$property -eq $before.tracks[0].$property) "Track $property undo failed or unchanged value created history"
        Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
        Assert ((Score).tracks[1].$property -eq $arguments.value) "Track $property redo failed"
    }
    $mixed = Score
    Assert ((Json $mixed.tracks[0]) -eq (Json $before.tracks[0])) 'Clone property changes affected the source track'
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='track';index=1} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='beat';index=0} | Out-Null
    Invoke-McpTool $connection gp_set_fret @{document=$id;string=0;fret=5} | Out-Null
    Assert ((Bars 1).bars[0].voices[0].beats[0].notes[0].midi -eq 45 -and (Json (Bars).bars) -eq (Json $beforeBars.bars)) 'Duplicated notes alias source notes'
    $saved = Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'edited.gp')}
    $zip = [IO.Compression.ZipFile]::OpenRead($saved.path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$gpif = $reader.ReadToEnd() } finally { $reader.Dispose() }
        Assert (@($gpif.GPIF.Tracks.Track).Count -eq 2) 'Saved GPIF lost duplicated track'
        Assert ($gpif.SelectSingleNode('/GPIF/Tracks/Track[2]/Name').InnerText -eq '副旋律吉他') 'Chinese track name was not saved'
        Assert ($gpif.SelectSingleNode('/GPIF/Tracks/Track[2]/ShortName').InnerText -eq '副吉他') 'Chinese short name was not saved'
        Assert ($gpif.SelectSingleNode('/GPIF/Tracks/Track[2]/Color').InnerText -eq '18 99 212') 'Saved color channel order differs'
        $parameters = $gpif.SelectSingleNode('/GPIF/Tracks/Track[2]/RSE/ChannelStrip/Parameters').InnerText.Trim() -split '\s+'
        Assert ([double]::Parse($parameters[11], [Globalization.CultureInfo]::InvariantCulture) -eq 0.25) 'Track pan was not saved'
        Assert ([double]::Parse($parameters[12], [Globalization.CultureInfo]::InvariantCulture) -eq 0.625) 'Track volume was not saved'
    } finally { $zip.Dispose() }
    $swapped = Invoke-McpTool $connection gp_edit_tracks @{document=$id;operation='swap';track=0;other=1}
    Assert ($swapped.tracks[0].name -eq '副旋律吉他' -and (Bars).bars[0].voices[0].beats[0].notes[0].midi -eq 45) 'Track swap lost identity or notes'
    Undo
    Assert ((Score).tracks[1].name -eq '副旋律吉他') 'Track swap undo failed'
    $removed = Invoke-McpTool $connection gp_edit_tracks @{document=$id;operation='remove';track=0}
    Assert ($removed.track_count -eq 1 -and $removed.tracks[0].name -eq '副旋律吉他') 'Track deletion removed the wrong track'
    Undo
    Assert ((Score).track_count -eq 2 -and (Json (Bars).bars) -eq (Json $beforeBars.bars)) 'Track deletion undo did not restore source'
    Invoke-McpTool $connection gp_edit_tracks @{document=$id;operation='remove';track=1} | Out-Null
    Assert ((Json (Score).tracks) -eq (Json $before.tracks) -and (Json (Bars).bars) -eq (Json $beforeBars.bars)) 'Removing clone did not leave original content'

    $emptyTrack = Invoke-McpTool $connection gp_insert_track @{document=$id;source_track=0;index=0}
    Assert ($emptyTrack.track_count -eq 2 -and $emptyTrack.tracks[0].bars -eq 2 -and -not $emptyTrack.copied_content) 'Empty track insertion failed'
    $emptyBars = Bars
    Assert (@($emptyBars.bars | ForEach-Object voices | ForEach-Object beats | ForEach-Object notes).Count -eq 0) 'Empty inserted track contains copied notes'
    Assert ((Json (Bars 1).bars) -eq (Json $beforeBars.bars)) 'Empty insertion changed source track content'
    Undo
    $copied = Invoke-McpTool $connection gp_insert_track @{document=$id;source_track=0;index=0;copy_content=$true}
    Assert ($copied.copied_content -and (Json (Bars).bars) -eq (Json $beforeBars.bars)) 'Track content insertion differs'
    Undo
    Assert ((Score).track_count -eq 1) 'Track insertion undo failed'

    $request = Invoke-McpTool $connection gp_new @{template='Acoustic Piano'}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $documents = Invoke-McpTool $connection gp_documents
        if ($documents.creation.request -eq $request.request -and $documents.creation.status -eq 'created') { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($documents.creation.request -eq $request.request -and $documents.creation.status -eq 'created') 'Piano template creation failed'
    $piano = $documents.creation.document
    Assert ((Invoke-McpTool $connection gp_insert_track @{document=$id;source_document=$piano;source_track=0;copy_content=$true} -AllowError).error) 'Mismatched bar counts accepted for content copying'
    $insertedPiano = Invoke-McpTool $connection gp_insert_track @{document=$id;source_document=$piano;source_track=0}
    Assert ($insertedPiano.track_count -eq 2 -and $insertedPiano.tracks[1].staves -eq 2 -and $insertedPiano.tracks[1].bars -eq 2) 'Piano configuration was not inserted at target length'
    Assert (@((Bars 1 1).bars).Count -eq 2) 'Inserted piano lower staff has a different length'
    $sourcePiano = Invoke-McpTool $connection gp_score @{document=$piano}
    Assert (-not $sourcePiano.dirty -and $sourcePiano.tracks[0].bars -eq 1) 'Track insertion changed its source document'
    Undo
    $zero = Invoke-McpTool $connection gp_edit_tracks @{document=$id;operation='remove';track=0}
    Assert ($zero.track_count -eq 0 -and $zero.cursor.track -eq -1) 'Removing final track did not leave an empty native score'
    $fromZero = Invoke-McpTool $connection gp_insert_track @{document=$id;source_document=$piano;source_track=0}
    Assert ($fromZero.track_count -eq 1 -and $fromZero.tracks[0].staves -eq 2) 'Inserting first track into empty score failed'
    Undo
    Assert ((Score).track_count -eq 0) 'First track undo failed'
    Undo
    Assert ((Json (Score).tracks) -eq (Json $before.tracks) -and (Json (Bars).bars) -eq (Json $beforeBars.bars)) 'Final-track deletion undo did not restore original score'
    Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'restored.gp')} | Out-Null
    $closed = Invoke-McpTool $connection gp_close @{document=$piano}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $documents = Invoke-McpTool $connection gp_documents
        if ($documents.closing.request -eq $closed.request -and $documents.closing.status -eq 'closed') { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($documents.documents.Count -eq 1 -and $documents.documents[0].id -eq $id -and -not $documents.documents[0].dirty) 'Test did not leave only a clean fixture'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy changed'
    $afterIdentity = Invoke-McpTool $connection gp_capabilities
    Assert ($afterIdentity.pid -eq $identity.pid -and $afterIdentity.foreground_pid -ne $identity.pid -and $afterIdentity.hidden_mode) 'Track operations brought host to foreground'
    $window = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    Assert (-not ($window.objects | Where-Object class -EQ 'gp::gui::MainWindow').visible) 'Track operations made host visible'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;before=$before;duplicate=$duplicate;mixed=$mixed;saved=$saved;empty_insert=$emptyTrack;copied=$copied;piano_insert=$insertedPiano;empty_score=$zero;first_track=$fromZero} |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native track checks. Evidence: $run"
} catch {
    Write-Output "Failed after $checks checks; last passed assertion: $lastCheck"
    throw
} finally { Close-McpSession $connection }
