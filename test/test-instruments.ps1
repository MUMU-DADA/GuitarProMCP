param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-instruments-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$checks=0
$cases=@()
$complete=$false
function Assert($ok,[string]$message) {if(-not $ok){throw $message};$script:checks++}
function Json($value) {ConvertTo-Json -InputObject $value -Depth 50 -Compress}
function Call([string]$name,[hashtable]$arguments=@{}) {$arguments.document=$script:id;Invoke-McpTool $connection $name $arguments}
function Wait-Operation($request,[string]$expected) {
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $state=(Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if($state.status -in @($expected,'error','cancelled')){break}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    Assert ($state.status -eq $expected) "Operation failed: $(Json $state)"
    $state.document
}
function Save([string]$name) {Call gp_save_as @{path=(Join-Path $run ($name+'.gp'))}}
function Close([string]$document) {
    $request=Invoke-McpTool $connection gp_close @{document=$document;unsaved='discard'}
    Wait-Operation $request.request 'closed' | Out-Null
}
function Model([string]$document=$script:id) {
    $state=Invoke-McpTool $connection gp_score @{document=$document}
    $bars=[ordered]@{}
    foreach($track in $state.tracks){foreach($staff in 0..($track.staves-1)){
        $content=(Invoke-McpTool $connection gp_read_bars @{document=$document;track=$track.index;staff=$staff;count=$track.bars}).bars
        # Cursor-only input placeholders are not persisted score content.
        foreach($bar in $content){foreach($voice in $bar.voices){$voice.beats=@($voice.beats | Where-Object {-not $_.placeholder})}}
        $bars["$($track.index):$staff"]=$content
    }}
    [pscustomobject]@{tracks=$state.tracks;bars=[pscustomobject]$bars;master=(Invoke-McpTool $connection gp_read_master_bars @{document=$document;count=$state.tracks[0].bars}).bars}
}
function Point([int]$track=0,[int]$staff=0,[int]$voice=0,[int]$bar=0,[int]$beat=0) {
    Call gp_selection @{operation='clear'} | Out-Null
    foreach($axis in 'track','staff','voice','bar','beat'){
        if($axis -eq 'beat' -and $beat -eq 0){
            $state=Call gp_read_bars @{track=$track;staff=$staff;bar=$bar}
            if($state.bars[0].voices[$voice].beats.Count -eq 0){continue}
        }
        Call gp_cursor @{axis=$axis;index=(Get-Variable -Name $axis -ValueOnly)} | Out-Null
    }
}
function Undo {Call gp_undo_redo @{operation='undo'} | Out-Null}
function Reopen([string]$name,$expected) {
    $saved=Save $name
    $copy=Join-Path $run ($name+'-reopen.gp')
    Copy-Item -LiteralPath $saved.path -Destination $copy
    $request=Invoke-McpTool $connection gp_open @{path=$copy}
    $reopened=Wait-Operation $request.request 'opened'
    Assert ((Json (Model $reopened)) -eq (Json $expected)) "$name save/reopen differs"
    Close $reopened
}
function Cycle([string]$name,[scriptblock]$edit,[scriptblock]$verify) {
    $before=Model
    & $edit | Out-Null
    $after=Model
    $case=@{name=$name;before=$before;after=$after}
    $script:cases+=$case
    & $verify $before $after
    Assert ((Json $before) -ne (Json $after)) "$name did not change state"
    Undo
    $case.undo=Model
    Assert ((Json $case.undo) -eq (Json $before)) "$name undo differs"
    Call gp_undo_redo @{operation='redo'} | Out-Null
    Assert ((Json (Model)) -eq (Json $after)) "$name redo differs"
    Reopen $name $after
}
function Reject([string]$tool,[hashtable]$arguments) {
    $before=Model
    $arguments.document=$script:id
    $error=(Invoke-McpTool $connection $tool $arguments -AllowError).error
    Assert ([bool]$error) "$tool did not reject invalid input"
    Assert ((Json (Model)) -eq (Json $before)) "$tool rejection changed score"
}
try {
    $fixture=Join-Path $run 'fixture.gp'
    Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $fixture
    $request=Invoke-McpTool $connection gp_open @{path=$fixture}
    $id=Wait-Operation $request.request 'opened'
    $guitar=$id
    foreach($template in @('Acoustic Piano','Drumkit')) {
        Save ('before-'+$template.Replace(' ','-')) | Out-Null
        $request=Invoke-McpTool $connection gp_new @{template=$template}
        $source=Wait-Operation $request.request 'created'
        Call gp_insert_track @{source_document=$source;source_track=0} | Out-Null
        Save ('after-'+$template.Replace(' ','-')) | Out-Null
        Close $source
    }
    $initial=Model
    Assert ($initial.tracks.Count -eq 3 -and $initial.tracks[1].staves -eq 2) 'Mixed score lacks piano staves'
    Assert ($initial.tracks[0].stringed -and -not $initial.tracks[1].stringed -and $initial.tracks[2].unpitched) 'Instrument classes differ'
    foreach($position in @(@{staff=0;voice=0;midi=60},@{staff=0;voice=1;midi=67},@{staff=1;voice=0;midi=48},@{staff=1;voice=1;midi=43})) {
        Point 1 $position.staff $position.voice
        $key="1:$($position.staff)";$voice=$position.voice;$midi=$position.midi
        Cycle "piano-$($position.staff)-$voice" {Call gp_edit_note @{operation='set';midi=$midi}} {
            param($before,$after)
            $notes=$after.bars.$key[0].voices[$voice].beats[0].notes
            Assert ($notes.Count -eq 1 -and $notes[0].midi -eq $midi -and $notes[0].sounding_midi -eq $midi) 'Piano input pitch differs'
            Assert ((Json $before.bars.'0:0') -eq (Json $after.bars.'0:0') -and (Json $before.bars.'2:0') -eq (Json $after.bars.'2:0')) 'Piano input changed another track'
        }
    }
    Point 1
    Cycle 'piano-chord' {Call gp_edit_note @{operation='set';midi=64}} {param($before,$after)
        Assert ((Json @($after.bars.'1:0'[0].voices[0].beats[0].notes.midi | Sort-Object)) -eq '[60,64]') 'Piano chord differs'
        Assert ((Json $before.bars.'1:0'[0].voices[1]) -eq (Json $after.bars.'1:0'[0].voices[1])) 'Piano chord changed other voice'
    }
    $before=Model
    Call gp_edit_note @{operation='set';midi=64} | Out-Null
    Assert ((Json (Model)) -eq (Json $before)) 'Duplicate MIDI set toggled a note'
    Cycle 'piano-single-ornament' {Call gp_edit_note_effect @{note_index=1;property='ornament';value='Turn'}} {param($before,$after)
        Assert ((Json $before.bars.'1:0'[0].voices[0].beats[0].notes[0]) -eq (Json $after.bars.'1:0'[0].voices[0].beats[0].notes[0])) 'Ordinal effect changed other chord note'
        Assert ($after.bars.'1:0'[0].voices[0].beats[0].notes[1].effects.ornament -eq 'Turn') 'Piano ornament missing'
    }
    Cycle 'piano-remove' {Call gp_edit_note @{operation='remove';midi=64}} {param($before,$after)
        Assert ((Json @($after.bars.'1:0'[0].voices[0].beats[0].notes.midi)) -eq '[60]') 'Piano removal changed remaining note'
    }
    Reject gp_edit_tuning @{track=1;capo=2}
    Reject gp_edit_note_effect @{note_index=0;property='bend';value=@{enabled=$false}}
    Point 2
    foreach($midi in @(36,38,42)) {
        Point 2
        Cycle "drum-$midi" {Call gp_edit_note @{operation='set';midi=$midi}} {param($before,$after)
            Assert (@($after.bars.'2:0'[0].voices[0].beats[0].notes | Where-Object {$_.midi -eq $midi -and $_.sounding_midi -eq $midi}).Count -eq 1) 'Drum articulation MIDI differs'
            Assert ((Json $before.bars.'1:0') -eq (Json $after.bars.'1:0')) 'Drum input changed piano'
        }
    }
    Point 2
    Cycle 'drum-remove' {Call gp_edit_note @{operation='remove';midi=38}} {param($before,$after)
        Assert ((Json @($after.bars.'2:0'[0].voices[0].beats[0].notes.midi | Sort-Object)) -eq '[36,42]') 'Drum removal differs'
    }
    Reject gp_edit_note @{operation='set';midi=0}
    Reject gp_transpose @{semitones=2}
    Reject gp_edit_track @{track=2;property='transposition';value=2}
    Call gp_selection @{operation='range';base=@{track=0;staff=0;voice=0;bar=0;beat=0};extent=@{track=0;staff=0;voice=0;bar=1;beat=3};all_tracks=$true} | Out-Null
    Reject gp_transpose @{semitones=2;scope='selection'}
    Point
    Reject gp_transpose @{semitones=-24}
    Reject gp_edit_tuning @{track=0;tuning=@(80,81,82,83,84,85)}
    Reject gp_edit_tuning @{track=0;tuning=@(40);preserve_pitch=$false}
    Cycle 'drop-d-preserve' {Call gp_edit_tuning @{track=0;tuning=@(38,45,50,55,59,64)}} {param($before,$after)
        $note=$after.bars.'0:0'[0].voices[0].beats[0].notes[0]
        Assert ($note.midi -eq 40 -and $note.fret -eq 2) 'Drop D did not preserve pitch'
        Assert ((Json $before.bars.'1:0') -eq (Json $after.bars.'1:0')) 'Tuning changed piano'
    }
    Undo
    Cycle 'drop-d-fingering' {Call gp_edit_tuning @{track=0;tuning=@(38,45,50,55,59,64);preserve_pitch=$false}} {param($before,$after)
        $note=$after.bars.'0:0'[0].voices[0].beats[0].notes[0]
        Assert ($note.midi -eq 38 -and $note.fret -eq 0) 'Drop D did not preserve fingering'
    }
    Undo
    Cycle 'capo' {Call gp_edit_tuning @{track=0;capo=2;preserve_pitch=$false}} {param($before,$after)
        $note=$after.bars.'0:0'[0].voices[0].beats[0].notes[0]
        Assert ($after.tracks[0].staff_details[0].capo -eq 2 -and $note.sounding_midi -eq 42) 'Capo sounding pitch differs'
    }
    Undo
    Cycle 'partial-capo' {Call gp_edit_tuning @{track=0;partial_capo=2;partial_capo_strings=@($true,$false,$false,$false,$false,$false);preserve_pitch=$false}} {param($before,$after)
        Assert ($after.bars.'0:0'[0].voices[0].beats[0].notes[0].sounding_midi -eq 42) 'Partial capo pitch differs'
    }
    Undo
    Cycle 'written-transposition' {Call gp_edit_track @{track=0;property='transposition';value=2}} {param($before,$after)
        $expected=Json $before.bars | ConvertFrom-Json
        for($b=0;$b -lt $expected.'0:0'.Count;$b++){for($v=0;$v -lt 4;$v++){
            for($k=0;$k -lt $expected.'0:0'[$b].voices[$v].beats.Count;$k++){
                $notes=$expected.'0:0'[$b].voices[$v].beats[$k].notes
                for($n=0;$n -lt $notes.Count;$n++){$notes[$n].accidental=$after.bars.'0:0'[$b].voices[$v].beats[$k].notes[$n].accidental}
            }
        }}
        Assert ($after.tracks[0].transposition -eq 2 -and (Json $expected) -eq (Json $after.bars)) 'Written transposition changed sounding notes'
    }
    Undo
    # Native transpose snapshots complete partially written voices with rests.
    # Use complete bars here so exact undo and unrelated-track isolation are testable.
    foreach($p in @(@(1,0,0),@(1,0,1),@(1,1,0),@(1,1,1),@(2,0,0))){
        Point $p[0] $p[1] $p[2]
        Call gp_edit_beat @{operation='rhythm';denominator=1} | Out-Null
    }
    Point
    Cycle 'sounding-transposition' {Call gp_transpose @{semitones=2}} {param($before,$after)
        Assert ($after.bars.'0:0'[0].voices[0].beats[0].notes[0].sounding_midi -eq 42 -and $after.tracks[0].transposition -eq $before.tracks[0].transposition) 'Sounding transpose differs'
        Assert ((Json $before.bars.'0:0'[0].voices[0].beats[1]) -eq (Json $after.bars.'0:0'[0].voices[0].beats[1])) 'Cursor transpose changed next beat'
    }
    Undo
    Point 1
    Cycle 'piano-transposition' {Call gp_transpose @{semitones=-12}} {param($before,$after)
        Assert ($after.bars.'1:0'[0].voices[0].beats[0].notes[0].sounding_midi -eq 48) 'Piano octave transpose differs'
        Assert ((Json $before.bars.'1:1') -eq (Json $after.bars.'1:1')) 'Piano transpose changed lower staff'
    }
    Call gp_edit_tracks @{operation='remove';track=2} | Out-Null
    Call gp_selection @{operation='range';base=@{track=0;staff=0;voice=0;bar=0;beat=0};extent=@{track=0;staff=0;voice=0;bar=1;beat=3};all_tracks=$true} | Out-Null
    Cycle 'cross-track-transposition' {Call gp_transpose @{semitones=2;scope='selection'}} {param($before,$after)
        foreach($property in $before.bars.psobject.Properties){
            $key=$property.Name
            for($b=0;$b -lt $before.bars.$key.Count;$b++){for($v=0;$v -lt 4;$v++){
                $old=$before.bars.$key[$b].voices[$v].beats
                $new=$after.bars.$key[$b].voices[$v].beats
                Assert ($old.Count -eq $new.Count) 'Batch transpose changed beat count'
                for($k=0;$k -lt $old.Count;$k++){
                    Assert ((Json @($old[$k].notes.midi | ForEach-Object {$_+2} | Sort-Object)) -eq (Json @($new[$k].notes.midi | Sort-Object))) 'Batch transpose missed a staff or voice'
                }
            }}
        }
    }
    Reopen 'mixed-final' (Model)
    Save 'retained' | Out-Null
    Close $id
    $complete=$true
    Write-Output "PASS: $checks native instrument checks. Evidence: $run"
} finally {
    @{complete=$complete;checks=$checks;cases=$cases;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash} | ConvertTo-Json -Depth 70 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    Close-McpSession $connection
}
