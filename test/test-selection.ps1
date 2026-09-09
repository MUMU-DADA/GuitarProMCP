param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.Path]::GetFullPath((Join-Path $root 'artifacts/native-test.gp'))
$checks = 0
$regeneratedPlaceholders = @()
$batchStates = @()
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++; $script:lastCheck=$message }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 24 -Compress }
function Point([int]$bar, [int]$beat, [int]$track=0, [int]$voice=0, [int]$staff=0) { @{track=$track;staff=$staff;bar=$bar;voice=$voice;beat=$beat} }
$connection = New-McpSession -SessionFile $SessionFile
function Select-Score([hashtable]$arguments=@{}) { $arguments.document=$id; Invoke-McpTool $connection gp_selection $arguments }
function Score { Invoke-McpTool $connection gp_score @{document=$id} }
function Bars([int]$track=0, [int]$staff=0) { (Invoke-McpTool $connection gp_read_bars @{document=$id;track=$track;staff=$staff;count=2}).bars }
function Undo { Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'} | Out-Null }
function Open-Score([string]$path) {
    Invoke-McpTool $connection gp_open @{path=$path} | Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $found=@((Invoke-McpTool $connection gp_documents).documents | Where-Object opened_path -EQ $path.Replace('\','/'))
        if ($found.Count -eq 1) { return $found[0].id }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Native open did not complete'
}
function Close-Score([string]$document) {
    $request=Invoke-McpTool $connection gp_close @{document=$document}
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $state=Invoke-McpTool $connection gp_documents
        if ($state.closing.request -eq $request.request -and $state.closing.status -eq 'closed') { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Native close did not complete'
}
function Reject([hashtable]$arguments, [string]$tool='gp_selection') {
    $before=Json (Score)
    $active=(Invoke-McpTool $connection gp_documents).active_document
    $arguments.document=$id
    $rejected=$false
    try { $rejected=[bool](Invoke-McpTool $connection $tool $arguments -AllowError).error } catch { $rejected=$true }
    Assert $rejected "Invalid request was accepted: $(Json $arguments)"
    Assert ((Json (Score)) -eq $before) 'Rejected request changed cursor, dirty state or history'
    Assert ((Invoke-McpTool $connection gp_documents).active_document -eq $active) 'Rejected selection changed active document'
}
function All-Staves([string]$document=$id) {
    foreach($track in (Invoke-McpTool $connection gp_score @{document=$document}).tracks) {
        for($s=0; $s -lt $track.staves; $s++) {
            [pscustomobject]@{track=$track.index;staff=$s;bars=(Invoke-McpTool $connection gp_read_bars @{document=$document;track=$track.index;staff=$s;count=$track.bars}).bars}
        }
    }
}
function Test-Batch([hashtable]$selection, [string]$operation, [int]$count, [string]$name, [string[]]$expectedPoints=@()) {
    Select-Score $selection | Out-Null
    $before=@(All-Staves)
    $cursor=Json (Score).cursor
    $active=(Invoke-McpTool $connection gp_documents).active_document
    $selected=Select-Score @{operation='beats'}
    Assert ($selected.count -eq $count -and $selected.beats.Count -eq $count) "$name target count differs"
    if(-not $expectedPoints.Count) {
        $current=(Score).cursor
        $expectedPoints=@(foreach($staff in $before) {
            if(-not $selection.all_tracks -and ($staff.track -ne $current.track -or $staff.staff -ne $current.staff)) {continue}
            foreach($bar in $staff.bars) {
                if($selection.operation -eq 'range' -and ($bar.index -lt [Math]::Min($selection.base.bar,$selection.extent.bar) -or $bar.index -gt [Math]::Max($selection.base.bar,$selection.extent.bar))) {continue}
                foreach($voice in $bar.voices) {foreach($beat in $voice.beats) {
                    if(-not $beat.placeholder) {"$($staff.track)/$($staff.staff)/$($bar.index)/$($voice.index)/$($beat.index)"}
                }}
            }
        })
    }
    $actualPoints=@($selected.beats | ForEach-Object {"$($_.track)/$($_.staff)/$($_.bar)/$($_.voice)/$($_.beat)"})
    Assert ((Json @($actualPoints | Sort-Object)) -eq (Json @($expectedPoints | Sort-Object))) "$name selected different musical positions"
    Assert ((Json (Score).cursor) -eq $cursor -and (Invoke-McpTool $connection gp_documents).active_document -eq $active) 'Selection enumeration changed cursor or active document'
    $arguments=@{document=$id;scope='selection';operation=$operation}
    if($operation -eq 'rhythm') {$arguments.denominator=8} else {$arguments.dots=1}
    $edited=Invoke-McpTool $connection gp_edit_beat $arguments
    Assert ($edited.affected_beats -eq $count -and (Json $edited.beats) -eq (Json $selected.beats)) "$name edited a different target set"
    $after=@(All-Staves)
    $seen=0
    for($s=0; $s -lt $before.Count; $s++) {
        $oldStaff=$before[$s]; $newStaff=$after[$s]
        for($b=0; $b -lt $oldStaff.bars.Count; $b++) {
            foreach($voice in $oldStaff.bars[$b].voices) {
                $newVoice=$newStaff.bars[$b].voices | Where-Object index -EQ $voice.index
                Assert ($newVoice.beats.Count -eq $voice.beats.Count) "$name changed beat count"
                for($k=0; $k -lt $voice.beats.Count; $k++) {
                    $old=$voice.beats[$k]; $new=$newVoice.beats[$k]
                    $inside=@($selected.beats | Where-Object { $_.track -eq $oldStaff.track -and $_.staff -eq $oldStaff.staff -and $_.bar -eq $b -and $_.voice -eq $voice.index -and $_.beat -eq $k }).Count -eq 1
                    if($inside) {
                        $seen++
                        Assert ((Json $old.notes) -eq (Json $new.notes) -and $old.rest -eq $new.rest) "$name changed note content"
                        if($operation -eq 'rhythm') {Assert ($new.native_note_value -eq 5 -and $new.dots -eq $old.dots) "$name rhythm differs"}
                        else {Assert ($new.dots -eq 1 -and $new.native_note_value -eq $old.native_note_value) "$name dots differ"}
                    } else {Assert ((Json $new) -eq (Json $old)) "$name escaped selection"}
                }
            }
        }
    }
    Assert ($seen -eq $count) "$name did not read back all selected beats"
    if($selection.operation -eq 'all' -or $selection.all_tracks) {
        Invoke-McpTool $connection gp_edit_beat $arguments | Out-Null
    }
    Undo
    Assert ((Json @(All-Staves)) -eq (Json $before)) "$name single undo failed or identical write added history"
    Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
    Assert ((Json @(All-Staves)) -eq (Json $after)) "$name redo differs"
    $saved=Invoke-McpTool $connection gp_save @{document=$id;path=(Join-Path $run "$name.gp")}
    $reopened=Open-Score $saved.path
    $reloaded=@(All-Staves $reopened)
    for($s=0; $s -lt $after.Count; $s++) {
        for($b=0; $b -lt $after[$s].bars.Count; $b++) {
            foreach($voice in $after[$s].bars[$b].voices) {
                $loadedVoice=$reloaded[$s].bars[$b].voices | Where-Object index -EQ $voice.index
                if($voice.beats.Count -eq 0 -and $loadedVoice.beats.Count -ne 0) {
                    Assert ($loadedVoice.beats.Count -eq 1 -and $loadedVoice.beats[0].placeholder -and $loadedVoice.beats[0].rest -and $loadedVoice.beats[0].notes.Count -eq 0) "$name reload inserted real musical content into an empty voice"
                    $script:regeneratedPlaceholders+=@{case=$name;track=$after[$s].track;staff=$after[$s].staff;bar=$b;voice=$voice.index;beat=$loadedVoice.beats[0]}
                    $loadedVoice.beats=@()
                }
            }
        }
    }
    Assert ((Json $reloaded) -eq (Json $after)) "$name native save/open differs beyond an empty-voice placeholder"
    $script:batchStates+=@{case=$name;selected=$selected;edited=$edited;saved=$saved.path}
    Close-Score $reopened
    Undo
}
try {
    $fixtureHash=(Get-FileHash -LiteralPath "$PSScriptRoot/testdata/minimal.gp").Hash
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy changed'
    $identity=Invoke-McpTool $connection gp_capabilities
    Assert ($identity.pid -ne $identity.foreground_pid -and $identity.hidden_mode -and $identity.qt_thread) 'Host is not in native background mode'
    $run=Join-Path $root ('artifacts/native-selection-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $copy=Join-Path $run 'source.gp'
    Copy-Item -LiteralPath $source -Destination $copy
    $id=Open-Score $copy
    Select-Score @{operation='note';base=(Point 0 0);note_index=0} | Out-Null
    Invoke-McpTool $connection gp_edit_note @{document=$id;operation='set';string=1;fret=3} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='voice';index=1} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_edit_note @{document=$id;operation='set';string=0;fret=7} | Out-Null
    Invoke-McpTool $connection gp_edit_tracks @{document=$id;operation='duplicate';track=0} | Out-Null
    $transientBefore=@((Bars 0),(Bars 1))
    Select-Score @{operation='range';base=(Point 0 0);extent=(Point 0 0)} | Out-Null
    Select-Score @{operation='clear'} | Out-Null
    $transientAfter=@((Bars 0),(Bars 1))
    $withoutPlaceholders=(Json @{items=$transientBefore} | ConvertFrom-Json).items
    foreach($track in $withoutPlaceholders) { foreach($bar in $track) { foreach($voice in $bar.voices) {
        foreach($placeholder in $voice.beats | Where-Object placeholder) {
            Assert ($placeholder.rest -and $placeholder.notes.Count -eq 0) 'Unexpected musical content in a placeholder'
        }
        $voice.beats=@($voice.beats | Where-Object { -not $_.placeholder })
    }}}
    Assert ((Json $withoutPlaceholders) -eq (Json $transientAfter)) 'Native cursor normalization changed real musical content'
    $prepared=Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'prepared.gp')}
    Close-Score $id
    $id=Open-Score $prepared.path
    $original=@((Bars 0),(Bars 1))
    Assert (-not (Score).dirty -and -not (Score).undo_available) 'Prepared model has editing history'
    $states=@()
    foreach ($reverse in @($false,$true)) {
        $from=Point 0 1; $to=Point 1 2
        if ($reverse) { $from,$to=$to,$from }
        $result=Select-Score @{operation='range';base=$from;extent=$to}
        $range=$result.cursor.selection
        Assert ($range.multi_selection -and $range.native_modes -eq 1 -and $range.bars -eq 2 -and $range.beats -eq 6) 'Range count or mode differs'
        Assert ($range.base.bar -eq $from.bar -and $range.base.beat -eq $from.beat -and $range.extent.bar -eq $to.bar -and $range.extent.beat -eq $to.beat) 'Range direction was lost'
        Assert ($range.lower.bar -eq 0 -and $range.lower.beat -eq 1 -and $range.upper.bar -eq 1 -and $range.upper.beat -eq 2) 'Sorted endpoints differ'
        Assert ($result.cursor.bar -eq $to.bar -and $result.cursor.beat -eq $to.beat) 'Cursor is not at extent'
        Assert ((Json (Select-Score).cursor) -eq (Json $result.cursor)) 'Read-only selection state differs'
        $states+=$result
        $clear=Select-Score @{operation='clear'}
        Assert (-not $clear.cursor.selection.multi_selection -and $null -eq $clear.cursor.selection.extent -and $clear.cursor.selection.native_modes -eq 0) 'Clear retained selection modes'
        Assert ($clear.cursor.bar -eq $to.bar -and $clear.cursor.beat -eq $to.beat) 'Clear did not retain extent'
    }
    $single=Select-Score @{operation='range';base=(Point 0 0);extent=(Point 0 0)}
    Assert ($single.cursor.selection.multi_selection -and $single.cursor.selection.beats -eq 1) 'Explicit one-beat selection failed'
    $beforeOther=(Invoke-McpTool $connection gp_documents).documents | Where-Object id -NE $id
    if ($beforeOther) { Invoke-McpTool $connection gp_activate @{document=@($beforeOther)[0].id} | Out-Null }
    foreach ($arguments in @(
        @{operation='unknown'}, @{operation='state';base=(Point 0 0)}, @{operation='clear';all_tracks=$true}, @{operation='beats';all_tracks=$true},
        @{operation='range';base=(Point 0 0)}, @{operation='range';base='bad';extent=(Point 0 1)},
        @{operation='range';base=@{track=0;staff=0;bar=0;voice=0};extent=(Point 0 1)},
        @{operation='range';base=@{track=0;staff=0;bar=0;voice=0;beat=0;extra=1};extent=(Point 0 1)},
        @{operation='range';base=@{track=0;staff=0;bar=0;voice=0;beat=0.5};extent=(Point 0 1)},
        @{operation='range';base=@{track=0;staff=0;bar=0;voice=0;beat='0'};extent=(Point 0 1)},
        @{operation='range';base=(Point -1 0);extent=(Point 0 1)},
        @{operation='range';base=(Point 0 0);extent=(Point 2 0)},
        @{operation='range';base=(Point 0 0);extent=(Point 0 99)},
        @{operation='range';base=(Point 0 0);extent=(Point 0 0 2)},
        @{operation='range';base=(Point 0 0);extent=(Point 0 0 0 4)},
        @{operation='range';base=(Point 0 0);extent=(Point 0 0 0 0 1)},
        @{operation='range';base=(Point 0 0);extent=(Point 0 0 1)},
        @{operation='range';base=(Point 0 0);extent=(Point 0 0 0 1)},
        @{operation='note';base=(Point 0 0);note_index=99},
        @{operation='note';base=(Point 0 0 0 2);note_index=0},
        @{operation='all';all_tracks=$true;all_voices=$false}, @{operation='all';all_voices='true'}
    )) { Reject $arguments }
    for ($n=0; $n -lt 2; $n++) {
        $result=Select-Score @{operation='note';base=(Point 0 0);note_index=$n}
        $expected=$original[0][0].voices[0].beats[0].notes[$n]
        Assert ($result.cursor.note_midi -eq $expected.midi -and $result.cursor.note_string -eq $expected.string -and -not $result.cursor.selection.multi_selection) 'Chord note selection differs'
    }
    $voice=Select-Score @{operation='note';base=(Point 0 0 1 1);note_index=0}
    Assert ($voice.cursor.track -eq 1 -and $voice.cursor.voice -eq 1 -and $voice.cursor.note_midi -eq 47) 'Cross-track or second-voice note selection failed'
    foreach ($mode in @(@{all_tracks=$true},@{all_voices=$true},@{},@{all_tracks=$true},@{})) {
        $arguments=@{operation='range';base=(Point 0 1);extent=(Point 1 2)}
        foreach($key in $mode.Keys) { $arguments[$key]=$mode[$key] }
        $result=Select-Score $arguments
        $range=$result.cursor.selection
        $expectedMode=if ($mode.all_tracks) {7} elseif($mode.all_voices) {3} else {1}
        Assert ($range.native_modes -eq $expectedMode -and $range.multi_track -eq [bool]$mode.all_tracks) 'Selection inherited a previous mode'
        if ($mode.all_tracks) { Assert ($range.base.beat -eq -1 -and $range.extent.beat -eq -1 -and $range.bars -eq 2) 'All-track selection did not expand to whole bars' }
        $states+=$result
    }
    $all=Select-Score @{operation='all'}
    Assert ($all.cursor.selection.beats -eq 8 -and $all.cursor.selection.bars -eq 2 -and $all.cursor.selection.native_modes -eq 1) 'Select-all did not include whole current voice'
    $allTracks=Select-Score @{operation='all';all_tracks=$true}
    Assert ($allTracks.cursor.selection.native_modes -eq 7 -and $allTracks.cursor.selection.bars -eq 2) 'Select-all tracks failed'
    Select-Score @{operation='clear'} | Out-Null
    Assert ((Json (Bars 0)) -eq (Json $original[0]) -and (Json (Bars 1)) -eq (Json $original[1])) 'Selection changed score content'
    Assert (-not (Score).dirty -and -not (Score).undo_available) 'Selection added editing history or dirty state'
    foreach ($operation in @('rhythm','dots')) {
        $selection=Select-Score @{operation='range';base=(Point 1 2);extent=(Point 0 1)}
        $arguments=@{document=$id;scope='selection';operation=$operation}
        if ($operation -eq 'rhythm') { $arguments.denominator=8 } else { $arguments.dots=2 }
        $result=Invoke-McpTool $connection gp_edit_beat $arguments
        Assert ($result.affected_beats -eq 6 -and $result.dirty) 'Batch edit did not cover six selected beats'
        $edited=Bars 0
        for($b=0;$b -lt 2;$b++) {
            for($k=0;$k -lt 4;$k++) {
                $a=$edited[$b].voices[0].beats[$k]; $o=$original[0][$b].voices[0].beats[$k]
                $inside=($b -gt 0 -or $k -ge 1) -and ($b -lt 1 -or $k -le 2)
                if($inside) {
                    Assert ((Json $a.notes) -eq (Json $o.notes)) 'Batch rhythm edit changed notes'
                    if($operation -eq 'rhythm') { Assert ($a.native_note_value -eq 5 -and $a.dots -eq $o.dots) 'Selected rhythm readback differs' }
                    else { Assert ($a.dots -eq 2 -and $a.native_note_value -eq $o.native_note_value) 'Selected dots readback differs' }
                } else { Assert ((Json $a) -eq (Json $o)) 'Batch edit escaped the selected beat range' }
            }
            Assert ((Json $edited[$b].voices[1]) -eq (Json $original[0][$b].voices[1])) 'Batch edit changed another voice'
        }
        Assert ((Json (Bars 1)) -eq (Json $original[1])) 'Batch edit changed another track'
        Invoke-McpTool $connection gp_edit_beat $arguments | Out-Null
        Undo
        Assert ((Json (Bars 0)) -eq (Json $original[0])) 'Single undo did not restore full batch or identical write added history'
        Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
        Assert ((Json (Bars 0)) -eq (Json $edited)) 'Batch redo differs'
        $saved=Invoke-McpTool $connection gp_save @{document=$id;path=(Join-Path $run "$operation.gp")}
        $reopened=Open-Score $saved.path
        $reloaded=(Invoke-McpTool $connection gp_read_bars @{document=$reopened;count=2}).bars
        Assert ((Json $reloaded) -eq (Json $edited)) 'Native batch save/open differs'
        Close-Score $reopened
        Undo
    }
    foreach($operation in @('rhythm','dots')) {
        Select-Score @{operation='range';base=(Point 0 0);extent=(Point 0 0)} | Out-Null
        Test-Batch @{operation='all';all_voices=$true} $operation 9 "voices-$operation"
        Test-Batch @{operation='range';base=(Point 0 1);extent=(Point 0 0);all_voices=$true} $operation 3 "partial-voices-$operation" @('0/0/0/0/0','0/0/0/0/1','0/0/0/1/0')
        Test-Batch @{operation='all';all_tracks=$true} $operation 18 "tracks-$operation"
        Test-Batch @{operation='range';base=(Point 0 3 1);extent=(Point 0 1 1);all_tracks=$true} $operation 10 "partial-tracks-$operation"
    }
    Invoke-McpTool $connection gp_edit_bars @{document=$id;operation='insert';index=2;count=128} | Out-Null
    Select-Score @{operation='all';all_tracks=$true} | Out-Null
    Reject @{operation='beats'}
    Reject @{scope='selection';operation='rhythm';denominator=8} gp_edit_beat
    Undo
    Select-Score @{operation='note';base=(Point 0 0 0 1);note_index=0} | Out-Null
    Invoke-McpTool $connection gp_edit_beat @{document=$id;operation='rhythm';denominator=8} | Out-Null
    Invoke-McpTool $connection gp_edit_beat @{document=$id;operation='insert';denominator=8} | Out-Null
    foreach($v in 2,3) {
        Select-Score @{operation='range';base=(Point 0 0);extent=(Point 0 0)} | Out-Null
        Invoke-McpTool $connection gp_cursor @{document=$id;axis='voice';index=$v} | Out-Null
        Invoke-McpTool $connection gp_edit_note @{document=$id;operation='set';string=0;fret=(7+$v)} | Out-Null
        $denominator=if($v -eq 2){2}else{1}
        Invoke-McpTool $connection gp_edit_beat @{document=$id;operation='rhythm';denominator=$denominator} | Out-Null
    }
    Select-Score @{operation='range';base=(Point 0 0);extent=(Point 0 0)} | Out-Null
    Select-Score @{operation='clear'} | Out-Null
    $heterogeneous=Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'four-voices.gp')}
    Close-Score $id
    $id=Open-Score $heterogeneous.path
    foreach($operation in @('rhythm','dots')) {
        Test-Batch @{operation='range';base=(Point 0 0);extent=(Point 0 0);all_voices=$true} $operation 5 "four-voices-onset-$operation" @('0/0/0/0/0','0/0/0/1/0','0/0/0/1/1','0/0/0/2/0','0/0/0/3/0')
        Test-Batch @{operation='range';base=(Point 0 3);extent=(Point 0 1);all_voices=$true} $operation 3 "four-voices-late-$operation" @('0/0/0/0/1','0/0/0/0/2','0/0/0/0/3')
        Test-Batch @{operation='all';all_tracks=$true} $operation 21 "four-voices-tracks-$operation"
    }
    Select-Score @{operation='clear'} | Out-Null
    Reject @{scope='selection';operation='dots';dots=1} gp_edit_beat
    Reject @{scope='selection';operation='clear'} gp_edit_beat
    Reject @{scope='unknown';operation='rhythm';denominator=8} gp_edit_beat
    Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'restored.gp')} | Out-Null
    Close-Score $id
    $request=Invoke-McpTool $connection gp_new @{template='Acoustic Piano'}
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $state=Invoke-McpTool $connection gp_documents
        if ($state.creation.request -eq $request.request -and $state.creation.status -eq 'created') { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($state.creation.request -eq $request.request -and $state.creation.status -eq 'created') 'Piano creation failed'
    $id=$state.creation.document
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='staff';index=1} | Out-Null
    Invoke-McpTool $connection gp_edit_beat @{document=$id;operation='insert';denominator=4} | Out-Null
    Invoke-McpTool $connection gp_edit_beat @{document=$id;operation='insert';denominator=4} | Out-Null
    $piano=Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'piano.gp')}
    Close-Score $id
    $id=Open-Score $piano.path
    $upper=(Invoke-McpTool $connection gp_read_bars @{document=$id;staff=0}).bars
    $lower=(Invoke-McpTool $connection gp_read_bars @{document=$id;staff=1}).bars
    $range=Select-Score @{operation='range';base=(Point 0 0 0 0 1);extent=(Point 0 1 0 0 1)}
    Assert ($range.cursor.staff -eq 1 -and $range.cursor.selection.beats -eq 2 -and $range.cursor.selection.base.staff -eq 1) 'Piano lower-staff range failed'
    $upperBeforeSelection=(Json @{items=$upper} | ConvertFrom-Json).items
    $upper[0].voices[0].beats=@($upper[0].voices[0].beats | Where-Object { -not $_.placeholder })
    Assert ((Json (Invoke-McpTool $connection gp_read_bars @{document=$id;staff=0}).bars) -eq (Json $upper)) 'Piano selection changed upper-staff content beyond transient placeholders'
    Invoke-McpTool $connection gp_edit_beat @{document=$id;scope='selection';operation='dots';dots=1} | Out-Null
    $editedLower=(Invoke-McpTool $connection gp_read_bars @{document=$id;staff=1}).bars
    Assert ($editedLower[0].voices[0].beats[0].dots -eq 1 -and $editedLower[0].voices[0].beats[1].dots -eq 1) 'Piano lower-staff batch failed'
    Assert ((Json (Invoke-McpTool $connection gp_read_bars @{document=$id;staff=0}).bars) -eq (Json $upper)) 'Piano selection edit changed upper staff'
    Undo
    Assert ((Json (Invoke-McpTool $connection gp_read_bars @{document=$id;staff=1}).bars) -eq (Json $lower)) 'Piano batch undo differs'
    Reject @{operation='note';base=(Point 0 0 0 0 1);note_index=0}
    Invoke-McpTool $connection gp_edit_tracks @{document=$id;operation='duplicate';track=0} | Out-Null
    foreach($operation in @('rhythm','dots')) {
        Test-Batch @{operation='all';all_tracks=$true} $operation 4 "piano-tracks-$operation"
    }
    Undo
    Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'piano-restored.gp')} | Out-Null
    Close-Score $id
    $afterOther=(Invoke-McpTool $connection gp_documents).documents
    Assert ((Json ($beforeOther | Select-Object id,dirty,save_path)) -eq (Json ($afterOther | Select-Object id,dirty,save_path))) 'Other documents were modified'
    $after=Invoke-McpTool $connection gp_capabilities
    Assert ($after.pid -eq $identity.pid -and $after.foreground_pid -ne $after.pid -and $after.hidden_mode) 'Selection activated the host window'
    $window=Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    Assert (-not ($window.objects | Where-Object class -EQ 'gp::gui::MainWindow').visible) 'Selection made host visible'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy changed'
    @{checks=$checks;identity_before=$identity;identity_after=$after;states=$states;prepared=$prepared.path;transient_before=$transientBefore;transient_after=$transientAfter;regenerated_placeholders=$regeneratedPlaceholders;batches=$batchStates} |
        ConvertTo-Json -Depth 24 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native selection checks. Evidence: $run"
} catch {
    $failure=$_
    try {
        if ($run -and $id) {
            @{checks=$checks;error=$failure.ToString();before=$original;score=(Score)} | ConvertTo-Json -Depth 24 |
                Set-Content -LiteralPath (Join-Path $run 'failure.json')
        }
    } catch { Write-Output 'Failed to capture diagnostic score state' }
    Write-Output "Failed after $checks checks; last passed assertion: $lastCheck"
    throw $failure
} finally { Close-McpSession $connection }
