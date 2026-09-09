param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
. "$PSScriptRoot/../native/mcp-client.ps1"
$root=Split-Path -Parent $PSScriptRoot
$run=Join-Path $root ('artifacts/native-score-form-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection=New-McpSession -SessionFile $SessionFile
$checks=0;$cases=@();$complete=$false
function Assert($ok,[string]$message){if(-not $ok){throw $message};$script:checks++}
function Json($value){ConvertTo-Json -InputObject $value -Depth 50 -Compress}
function Call([string]$tool,[hashtable]$arguments=@{}){$arguments.document=$script:id;Invoke-McpTool $connection $tool $arguments}
function Wait-Operation($request,[string]$expected){
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $state=(Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if($state.status -in @($expected,'error','cancelled')){break}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    Assert ($state.status -eq $expected) "Operation failed: $(Json $state)"
    $state.document
}
function Close([string]$document){$r=Invoke-McpTool $connection gp_close @{document=$document;unsaved='discard'};Wait-Operation $r.request 'closed' | Out-Null}
function Model([string]$document=$script:id){
    $count=(Invoke-McpTool $connection gp_score @{document=$document}).tracks[0].bars
    $bars=(Invoke-McpTool $connection gp_read_bars @{document=$document;count=$count}).bars
    foreach($bar in $bars){foreach($voice in $bar.voices){$voice.beats=@($voice.beats | Where-Object {-not $_.placeholder})}}
    $master=(Invoke-McpTool $connection gp_read_master_bars @{document=$document;count=$count}).bars
    foreach($bar in $master){if(-not $bar.repeat_end){$bar.repeat_count=0}}
    [pscustomobject]@{bars=$bars;master=$master}
}
function Cursor([int]$bar,[int]$beat=0){
    Call gp_selection @{operation='clear'} | Out-Null
    Call gp_cursor @{axis='bar';index=$bar} | Out-Null
    $content=Call gp_read_bars @{bar=$bar}
    if($content.bars[0].voices[0].beats.Count){Call gp_cursor @{axis='beat';index=$beat} | Out-Null}
}
function Undo {Call gp_undo_redo @{operation='undo'} | Out-Null}
function Reopen([string]$name,$expected){
    $saved=Call gp_save_as @{path=(Join-Path $run ($name+'.gp'))}
    $copy=Join-Path $run ($name+'-reopen.gp')
    Copy-Item -LiteralPath $saved.path -Destination $copy
    $request=Invoke-McpTool $connection gp_open @{path=$copy}
    $reopened=Wait-Operation $request.request 'opened'
    $actual=Model $reopened
    $script:cases+=@{name="$name-reopen";expected=$expected;actual=$actual}
    Assert ((Json $actual) -eq (Json $expected)) "$name save/reopen differs"
    Close $reopened
    Call gp_activate | Out-Null
}
function Cycle([string]$name,[scriptblock]$edit,[scriptblock]$verify){
    $before=Model
    & $edit | Out-Null
    $after=Model
    $case=@{name=$name;before=$before;after=$after};$script:cases+=$case
    & $verify $before $after
    Undo
    $case.undo=Model
    Assert ((Json $case.undo) -eq (Json $before)) "$name undo differs"
    Call gp_undo_redo @{operation='redo'} | Out-Null
    Assert ((Json (Model)) -eq (Json $after)) "$name redo differs"
    Reopen $name $after
}
function Edit-Measure([int]$bar,[string]$operation,[hashtable]$arguments){Cursor $bar;$arguments.operation=$operation;Call gp_edit_measure $arguments}
function Timeline([string]$name,[int]$bars){
    Call gp_activate | Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    do{$state=Call gp_playback; if($state.total_ticks -eq 1920*$bars){break};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
    Assert ($state.total_ticks -eq 1920*$bars) "$name expected $bars played bars, got $($state.total_ticks) ticks"
    $end=Call gp_playback @{operation='seek_tick';tick=(1920*$bars-1)}
    Assert ($end.tick -eq 1920*$bars-1 -and $end.frame -gt 0) "$name final tick unreachable"
    $script:cases+=@{name=$name;timeline=$state;end=$end}
}
function Check-Automation([string]$name,[int]$bar){
    $saved=Call gp_save_as @{path=(Join-Path $run ($name+'.gp'))}
    $zip=[IO.Compression.ZipFile]::OpenRead($saved.path)
    try {
        $reader=[IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try {[xml]$gpif=$reader.ReadToEnd()} finally {$reader.Dispose()}
        $points=@($gpif.SelectNodes('/GPIF/MasterTrack/Automations/Automation[Type="Tempo"]'))
        Assert ($points.Count -eq 2 -and @($points | Where-Object {$_.Bar -eq $bar -and $_.Value -eq '180 2'}).Count -eq 1) "$name lost or moved tempo automation"
        $script:cases+=@{name=$name;tempo=$points.OuterXml;saved=$saved.path}
    } finally {$zip.Dispose()}
}
try {
    $copy=Join-Path $run 'fixture.gp'
    Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $copy
    $zip=[IO.Compression.ZipFile]::Open($copy,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry=$zip.GetEntry('Content/score.gpif')
        $reader=[IO.StreamReader]::new($entry.Open())
        try {[xml]$gpif=$reader.ReadToEnd()} finally {$reader.Dispose()}
        $first=$gpif.SelectSingleNode('/GPIF/MasterTrack/Automations/Automation[Type="Tempo"]')
        $later=$first.CloneNode($true)
        $later.SelectSingleNode('Bar').InnerText='1'
        $later.SelectSingleNode('Value').InnerText='180 2'
        $first.ParentNode.AppendChild($later) | Out-Null
        $entry.Delete()
        $writer=[IO.StreamWriter]::new($zip.CreateEntry('Content/score.gpif').Open(),[Text.UTF8Encoding]::new($false))
        try {$writer.Write($gpif.OuterXml)} finally {$writer.Dispose()}
    } finally {$zip.Dispose()}
    $request=Invoke-McpTool $connection gp_open @{path=$copy}
    $id=Wait-Operation $request.request 'opened'
    Call gp_activate | Out-Null
    $from=@{track=0;staff=0;voice=0;bar=0;beat=0};$to=@{track=0;staff=0;voice=0;bar=1;beat=3}
    Call gp_selection @{operation='range';base=$to;extent=$from} | Out-Null
    Cycle 'long-legato' {Call gp_edit_connection @{kind='legato';enabled=$true;scope='selection'}} {param($before,$after)
        $beats=@($after.bars | ForEach-Object {$_.voices[0].beats})
        Assert (@($beats | Where-Object {$_.legato.origin}).Count -eq 7 -and @($beats | Where-Object {$_.legato.destination}).Count -eq 7) 'Eight-beat legato chain differs'
    }
    Undo
    foreach($bar in 0..1){foreach($beat in 0..3){
        Cursor $bar $beat
        $notes=(Call gp_read_bars @{bar=$bar}).bars[0].voices[0].beats[$beat].notes
        Call gp_edit_note @{operation='set';string=0;fret=12} | Out-Null
        foreach($note in $notes | Where-Object string -NE 0){Call gp_edit_note @{operation='remove';string=$note.string} | Out-Null}
    }}
    Call gp_selection @{operation='range';base=$from;extent=$to} | Out-Null
    Cycle 'long-tie' {Call gp_edit_connection @{kind='tie';enabled=$true;scope='selection'}} {param($before,$after)
        $notes=@($after.bars | ForEach-Object {$_.voices[0].beats.notes})
        Assert (@($notes | Where-Object {$_.tie.origin}).Count -eq 7 -and @($notes | Where-Object {$_.tie.destination}).Count -eq 7) 'Eight-note tie chain differs'
        Assert (@($notes.midi | Select-Object -Unique).Count -eq 1) 'Tie chain has different pitches'
    }
    Cursor 0
    Cycle 'tie-with-bend' {Call gp_edit_note_effect @{string=0;property='bend';value=@{enabled=$true;origin_value=0;middle_value=2;destination_value=0;origin_offset=0;middle_offset1=0.25;middle_offset2=0.75;destination_offset=1}}} {param($before,$after)
        Assert ($after.bars[0].voices[0].beats[0].notes[0].effects.bend.enabled) 'Bend missing on tied origin'
        Assert ($after.bars[1].voices[0].beats[3].notes[0].tie.destination) 'Bend broke tie endpoint'
    }
    Undo
    Call gp_selection @{operation='range';base=$from;extent=$to} | Out-Null
    Cycle 'transpose-long-tie' {Call gp_transpose @{scope='selection';semitones=2}} {param($before,$after)
        $notes=@($after.bars | ForEach-Object {$_.voices[0].beats.notes})
        Assert (@($notes | Where-Object {$_.midi -ne 54}).Count -eq 0) 'Tie chain transpose missed notes'
        Assert (@($notes | Where-Object {$_.tie.origin}).Count -eq 7 -and @($notes | Where-Object {$_.tie.destination}).Count -eq 7) 'Transpose broke the tie chain'
    }
    Undo
    Undo
    Call gp_edit_bars @{operation='insert';index=2;count=4} | Out-Null
    foreach($b in 2..5){Cursor $b;Call gp_edit_note @{operation='set';string=0;fret=$b} | Out-Null;Call gp_edit_beat @{operation='rhythm';denominator=1} | Out-Null}
    Cursor 0
    $marks=(Call gp_read_master_bars).direction_marks
    foreach($mark in $marks | Where-Object {$_.id -le 18}){
        Cycle "direction-$($mark.id)" {Edit-Measure 3 direction @{direction=$mark.id;enabled=$true}} {param($before,$after)
            Assert (@($after.master[3].directions | Where-Object id -EQ $mark.id).Count -eq 1) 'Direction missing'
        }
        Cycle "clear-direction-$($mark.id)" {Edit-Measure 3 direction @{direction=$mark.id;enabled=$false}} {param($before,$after)
            Assert ($after.master[3].directions.Count -eq 0) 'Direction was not cleared'
        }
        Undo
        Undo
    }
    Edit-Measure 2 direction @{direction=0;enabled=$true} | Out-Null
    Cycle 'move-direction' {Edit-Measure 4 direction @{direction=0;enabled=$true}} {param($before,$after)
        Assert ($after.master[2].directions.Count -eq 0 -and @($after.master[4].directions | Where-Object id -EQ 0).Count -eq 1) 'Direction did not move to the requested bar'
    }
    Cycle 'delete-before-direction' {Call gp_edit_bars @{operation='remove';index=3;count=1}} {param($before,$after)
        Assert ($after.master.Count -eq 5 -and @($after.master[3].directions | Where-Object id -EQ 0).Count -eq 1) 'Deletion lost direction reference'
    }
    Undo
    Edit-Measure 4 direction @{direction=2;enabled=$true} | Out-Null
    Cycle 'clear-one-of-two-directions' {Edit-Measure 4 direction @{direction=0;enabled=$false}} {param($before,$after)
        Assert ($after.master[4].directions.Count -eq 1 -and $after.master[4].directions[0].id -eq 2) 'Clearing one direction changed the other'
    }
    Edit-Measure 4 direction @{direction=2;enabled=$false} | Out-Null
    Check-Automation 'tempo-before-structure' 1
    Call gp_edit_bars @{operation='insert';index=1;count=1} | Out-Null
    Check-Automation 'tempo-after-insert' 2
    Call gp_edit_bars @{operation='remove';index=1;count=1} | Out-Null
    Check-Automation 'tempo-after-remove' 1
    Call gp_edit_tracks @{operation='duplicate';track=0} | Out-Null
    Call gp_edit_tracks @{operation='swap';track=0;other=1} | Out-Null
    Call gp_edit_tracks @{operation='remove';track=1} | Out-Null
    Check-Automation 'tempo-after-tracks' 1
    Edit-Measure 0 repeat_start @{enabled=$true} | Out-Null
    Edit-Measure 2 repeat_end @{enabled=$true;repeat_count=2} | Out-Null
    Edit-Measure 2 alternate_endings @{endings=@(1)} | Out-Null
    Cycle 'second-ending' {Edit-Measure 3 alternate_endings @{endings=@(2)}} {param($before,$after)
        Assert ((Json $after.master[3].alternate_endings) -eq '[2]') 'Second ending missing'
        Assert ((Json $before.master[2]) -eq (Json $after.master[2])) 'Second ending changed first ending'
    }
    Timeline 'alternate-endings' 8
    Cycle 'insert-with-endings' {Call gp_edit_bars @{operation='insert';index=1;count=1}} {param($before,$after)
        Assert ($after.master.Count -eq 7 -and (Json $after.master[3].alternate_endings) -eq '[1]' -and (Json $after.master[4].alternate_endings) -eq '[2]') 'Insertion lost ending references'
    }
    Timeline 'inserted-repeat-bar' 10
    Undo
    foreach($b in @(2,3)){Edit-Measure $b alternate_endings @{endings=@()} | Out-Null}
    Edit-Measure 2 repeat_end @{enabled=$false} | Out-Null
    Edit-Measure 1 repeat_start @{enabled=$true} | Out-Null
    Edit-Measure 2 repeat_end @{enabled=$true;repeat_count=2} | Out-Null
    Edit-Measure 4 repeat_end @{enabled=$true;repeat_count=2} | Out-Null
    Reopen 'nested-repeats' (Model)
    Timeline 'nested-repeats' 15
    Edit-Measure 0 repeat_start @{enabled=$false} | Out-Null
    Edit-Measure 1 repeat_start @{enabled=$false} | Out-Null
    Edit-Measure 2 repeat_end @{enabled=$false} | Out-Null
    Edit-Measure 4 repeat_end @{enabled=$false} | Out-Null
    Edit-Measure 2 direction @{direction=4;enabled=$true} | Out-Null
    Edit-Measure 4 direction @{direction=8;enabled=$true} | Out-Null
    Reopen 'da-capo-al-fine' (Model)
    Timeline 'da-capo-al-fine' 8
    Call gp_playback @{operation='set_loop';enabled=$false} | Out-Null
    Call gp_playback @{operation='seek_tick';tick=0} | Out-Null
    Call gp_playback @{operation='play'} | Out-Null
    Start-Sleep -Milliseconds 500
    $a=Call gp_playback
    Start-Sleep -Milliseconds 300
    $b=Call gp_playback
    Assert ($b.playing -and $b.tick -gt $a.tick -and $b.frame -gt $a.frame) 'Edited repeat score playback did not advance'
    Call gp_playback @{operation='stop'} | Out-Null
    $script:cases+=@{name='playback';before=$a;after=$b}
    Call gp_save_as @{path=(Join-Path $run 'retained.gp')} | Out-Null
    Close $id
    $complete=$true
    Write-Output "PASS: $checks native score form checks. Evidence: $run"
}finally {
    @{checks=$checks;complete=$complete;cases=$cases;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash} | ConvertTo-Json -Depth 65 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    Close-McpSession $connection
}
