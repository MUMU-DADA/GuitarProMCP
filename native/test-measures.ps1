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
function Measures { Invoke-McpTool $connection gp_read_master_bars @{document=$id;count=2} }
function Notes { Invoke-McpTool $connection gp_read_bars @{document=$id;count=2} }
function SoundingContent($state) {
    $bars=(Json @{items=$state.bars} | ConvertFrom-Json).items
    foreach ($note in @($bars | ForEach-Object voices | ForEach-Object beats | ForEach-Object notes)) { $note.PSObject.Properties.Remove('accidental') }
    Json $bars
}
function Edit([hashtable]$arguments) { $arguments.document=$id; Invoke-McpTool $connection gp_edit_measure $arguments }
function Undo { Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'} | Out-Null }
function Read-Gpif([string]$path) {
    $zip=[IO.Compression.ZipFile]::OpenRead($path)
    try {
        $reader=[IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}
try {
    $docs=Invoke-McpTool $connection gp_documents
    Assert ($docs.documents.Count -eq 1) 'Requires only artifacts/native-test.gp open'
    $fixture=$docs.documents[0]
    Assert ($fixture.opened_path -eq $source.Replace('\','/') -and -not $fixture.dirty) 'Refusing to edit another or dirty document'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy changed'
    $id=$fixture.id
    $identity=Invoke-McpTool $connection gp_capabilities
    Assert ($identity.pid -ne $identity.foreground_pid -and $identity.qt_thread -and $identity.hidden_mode) 'Host is not in native background mode'
    $run=Join-Path $root ('artifacts/native-measures-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='beat';index=0} | Out-Null
    $before=Measures
    $expectedBars=(Json @{items=$before.bars} | ConvertFrom-Json).items
    $beforeNotes=Notes
    Assert ($before.bar_count -eq 2 -and $before.bars[0].time_signature.numerator -eq 4 -and $before.bars[0].time_signature.denominator -eq 4) 'Fixture master time signature differs'
    Assert ($before.bars[0].key_signature.accidentals -eq 0 -and $before.bars[0].key_signature.major -and -not $before.bars[0].repeat_end) 'Fixture key or repeat state differs'
    foreach ($arguments in @(@{bar=-1},@{bar=2},@{count=0},@{count=129},@{bar=1;count=2})) {
        $arguments.document=$id
        Assert ((Invoke-McpTool $connection gp_read_master_bars $arguments -AllowError).error) 'Invalid master bar range accepted'
    }
    foreach ($arguments in @(
        @{operation='time_signature';numerator=0;denominator=4}, @{operation='time_signature';numerator=65;denominator=4},
        @{operation='time_signature';numerator=3;denominator=3}, @{operation='time_signature';numerator=4;denominator=0},
        @{operation='time_signature';numerator=4;denominator=256}, @{operation='time_signature';numerator=4},
        @{operation='key_signature';accidentals=-8;major=$true}, @{operation='key_signature';accidentals=8;major=$true},
        @{operation='key_signature';accidentals=0}, @{operation='key_signature';major=$true},
        @{operation='repeat_start'}, @{operation='repeat_end';enabled=$true;repeat_count=1},
        @{operation='repeat_end';enabled=$true;repeat_count=101}, @{operation='repeat_end';enabled=$false;repeat_count=2},
        @{operation='double_bar';enabled=$true;repeat_count=2}, @{operation='invalid'}
    )) {
        $arguments.document=$id
        Assert ((Invoke-McpTool $connection gp_edit_measure $arguments -AllowError).error) 'Invalid measure edit accepted'
    }
    Assert ((Json (Measures).bars) -eq (Json $expectedBars) -and -not (Invoke-McpTool $connection gp_score @{document=$id}).dirty) 'Rejected measure edit changed score'
    $edits=@()
    foreach ($time in @(@{numerator=3;denominator=4},@{numerator=7;denominator=8},@{numerator=1;denominator=128},@{numerator=64;denominator=1})) {
        $changed=Edit @{operation='time_signature';numerator=$time.numerator;denominator=$time.denominator}
        Assert ($changed.bar.time_signature.numerator -eq $time.numerator -and $changed.bar.time_signature.denominator -eq $time.denominator -and $changed.dirty) 'Time signature readback differs'
        Assert ((Json (Measures).bars[1]) -eq (Json $before.bars[1])) 'Time signature propagated beyond selected bar'
        Assert ((Json (Notes).bars) -eq (Json $beforeNotes.bars)) 'Time signature edit changed notes'
        Edit @{operation='time_signature';numerator=$time.numerator;denominator=$time.denominator} | Out-Null
        Undo
        Assert ((Json (Measures).bars) -eq (Json $expectedBars)) 'Time signature undo failed or unchanged edit added history'
        $edits+=$changed
    }
    foreach ($key in @(@{accidentals=-7;major=$false},@{accidentals=-1;major=$true},@{accidentals=0;major=$false},@{accidentals=2;major=$true},@{accidentals=7;major=$true})) {
        $changed=Edit @{operation='key_signature';accidentals=$key.accidentals;major=$key.major}
        Assert ($changed.bar.key_signature.accidentals -eq $key.accidentals -and $changed.bar.key_signature.major -eq $key.major) 'Concert key readback differs'
        Assert ((Json (Measures).bars[1]) -eq (Json $before.bars[1])) 'Key signature propagated beyond selected bar'
        Assert ((SoundingContent (Notes)) -eq (SoundingContent $beforeNotes)) 'Concert key edit changed sounding notes or rhythm'
        Undo
        Assert ((Json (Measures).bars) -eq (Json $expectedBars)) 'Key signature undo failed'
        Assert ((Json (Notes).bars) -eq (Json $beforeNotes.bars)) 'Key undo did not restore accidental spelling'
        $edits+=$changed
    }
    foreach ($operation in @('repeat_start','repeat_end','double_bar','free_time')) {
        $changed=Edit @{operation=$operation;enabled=$true}
        Assert ($changed.bar.$operation) "Native $operation was not enabled"
        Assert ((Json (Measures).bars[1]) -eq (Json $before.bars[1])) "Native $operation changed another bar"
        $cleared=Edit @{operation=$operation;enabled=$false}
        Assert (-not $cleared.bar.$operation) "Native $operation was not disabled"
        Undo
        Assert ((Measures).bars[0].$operation) "Native $operation disable undo failed"
        Undo
        if ($operation -eq 'repeat_end') { $expectedBars[0].repeat_count=2 }
        Assert ((Json (Measures).bars) -eq (Json $expectedBars)) "Native $operation enable undo failed"
        $edits+=$changed
    }
    $playbackBefore=Invoke-McpTool $connection gp_playback @{document=$id}
    Assert (-not $playbackBefore.playing -and $playbackBefore.total_ticks -eq 3840) 'Unexpected fixture playback timeline'
    Edit @{operation='repeat_start';enabled=$true} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=1} | Out-Null
    Edit @{operation='repeat_end';enabled=$true;repeat_count=3} | Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do {
        $repeated=Invoke-McpTool $connection gp_playback @{document=$id}
        if ($repeated.total_ticks -eq 3*$playbackBefore.total_ticks) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($repeated.total_ticks -eq 3*$playbackBefore.total_ticks) 'Repeat markers did not rebuild native playback timeline'
    $scoreSeek=Invoke-McpTool $connection gp_playback @{document=$id;operation='seek';bar=1;tick=0}
    Assert ($scoreSeek.tick -eq 1920 -and $scoreSeek.score_bar_count -eq 2) 'Score-bar seek did not address the original bar'
    foreach ($arguments in @(
        @{operation='seek';bar=1;tick=1920}, @{operation='seek';bar=1;tick=5000},
        @{operation='seek_tick';tick=-1}, @{operation='seek_tick';tick=11520},
        @{operation='seek_tick'}, @{operation='seek_tick';tick=0;bar=0}
    )) {
        $arguments.document=$id
        Assert ((Invoke-McpTool $connection gp_playback $arguments -AllowError).error) 'Out-of-range or ambiguous playback seek accepted'
    }
    Assert ((Invoke-McpTool $connection gp_playback @{document=$id}).tick -eq $scoreSeek.tick) 'Rejected seek changed playback position'
    $repeatSeek=Invoke-McpTool $connection gp_playback @{document=$id;operation='seek_tick';tick=9600}
    Assert ($repeatSeek.tick -eq 9600 -and [Math]::Abs($repeatSeek.frame / $scoreSeek.frame - 5) -lt 0.001) 'Native playback could not seek to the final repeated bar'
    $finalTick=Invoke-McpTool $connection gp_playback @{document=$id;operation='seek_tick';tick=11519}
    Assert ($finalTick.tick -eq 11519) 'Last valid timeline tick was not reachable'
    $maximumRepeat=Edit @{operation='repeat_end';enabled=$true;repeat_count=100}
    Assert ($maximumRepeat.bar.repeat_end -and $maximumRepeat.bar.repeat_count -eq 100) 'Maximum repeat count was not applied'
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do {
        $maximumPlayback=Invoke-McpTool $connection gp_playback @{document=$id}
        if ($maximumPlayback.total_ticks -eq 100*$playbackBefore.total_ticks) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($maximumPlayback.total_ticks -eq 100*$playbackBefore.total_ticks) 'Maximum repeat count did not rebuild playback timeline'
    $maximumSeek=Invoke-McpTool $connection gp_playback @{document=$id;operation='seek_tick';tick=($maximumPlayback.total_ticks-1)}
    Assert ($maximumSeek.tick -eq 383999) 'Maximum repeat timeline end was not reachable'
    Undo
    Assert ((Measures).bars[1].repeat_count -eq 3) 'Repeat count undo did not restore previous count'
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do {
        $countUndone=Invoke-McpTool $connection gp_playback @{document=$id}
        if ($countUndone.total_ticks -eq $repeated.total_ticks) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($countUndone.total_ticks -eq $repeated.total_ticks) 'Repeat count undo did not restore playback timeline'
    Undo
    Undo
    $expectedBars[1].repeat_count=3
    Assert ((Json (Measures).bars) -eq (Json $expectedBars)) 'Repeat playback undo did not restore markers'
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do {
        $repeatUndone=Invoke-McpTool $connection gp_playback @{document=$id}
        if ($repeatUndone.total_ticks -eq $playbackBefore.total_ticks) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($repeatUndone.total_ticks -eq $playbackBefore.total_ticks) 'Repeat undo did not restore native playback timeline'
    Invoke-McpTool $connection gp_playback @{document=$id;operation='seek';bar=0;tick=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    Edit @{operation='time_signature';numerator=3;denominator=4} | Out-Null
    Edit @{operation='key_signature';accidentals=-2;major=$false} | Out-Null
    Edit @{operation='repeat_start';enabled=$true} | Out-Null
    Edit @{operation='double_bar';enabled=$true} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=1} | Out-Null
    Edit @{operation='repeat_end';enabled=$true;repeat_count=3} | Out-Null
    Edit @{operation='free_time';enabled=$true} | Out-Null
    $saved=Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'edited.gp')}
    $gpif=Read-Gpif $saved.path
    $bars=@($gpif.GPIF.MasterBars.MasterBar)
    Assert ($bars[0].Time -eq '3/4' -and $bars[1].Time -eq '4/4') 'Saved time signatures differ'
    Assert ($bars[0].Key.AccidentalCount -eq '-2' -and $bars[0].Key.Mode -eq 'Minor' -and $bars[1].Key.AccidentalCount -eq '0') 'Saved concert keys differ'
    Assert ($bars[0].Repeat.start -eq 'true' -and $bars[1].Repeat.end -eq 'true' -and $bars[1].Repeat.count -eq '3') 'Saved repeat markers differ'
    Assert ($null -ne $bars[0].SelectSingleNode('DoubleBar') -and $null -ne $bars[1].SelectSingleNode('FreeTime')) 'Saved barline or free-time marker differs'
    foreach ($step in 1..6) { Undo }
    $expectedBars[1].repeat_count=3
    Assert ((Json (Measures).bars) -eq (Json $expectedBars)) 'Combined measure undo did not restore score'
    Assert ((Json (Notes).bars) -eq (Json $beforeNotes.bars)) 'Combined measure edits changed notes'
    Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
    Assert ((Measures).bars[0].time_signature.numerator -eq 3) 'Measure redo failed'
    Undo
    Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'restored.gp')} | Out-Null
    $afterIdentity=Invoke-McpTool $connection gp_capabilities
    Assert ($afterIdentity.pid -eq $identity.pid -and $afterIdentity.foreground_pid -ne $identity.pid -and $afterIdentity.hidden_mode) 'Measure edits brought host to foreground'
    $window=Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    Assert (-not ($window.objects | Where-Object class -EQ 'gp::gui::MainWindow').visible) 'Measure edits made host visible'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy changed'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;before=$before;edits=$edits;repeat_playback=$repeated;repeat_seek=$repeatSeek;maximum_repeat=$maximumRepeat;maximum_playback=$maximumPlayback;maximum_seek=$maximumSeek;repeat_undone=$repeatUndone;saved=$saved} |
        ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native measure checks. Evidence: $run"
} catch {
    Write-Output "Failed after $checks checks; last passed assertion: $lastCheck"
    throw
} finally { Close-McpSession $connection }
