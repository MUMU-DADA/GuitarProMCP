param([string]$SessionFile="$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=Split-Path -Parent $PSScriptRoot
$run=Join-Path $root ('artifacts/native-transfer-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection=New-McpSession -SessionFile $SessionFile
$checks=0
$cases=@()
$complete=$false
function Assert($ok,[string]$message){if(-not $ok){throw $message};$script:checks++}
function Json($value){ConvertTo-Json -InputObject $value -Depth 50 -Compress}
function Call([string]$name,[hashtable]$arguments=@{}){$arguments.document=$script:id;Invoke-McpTool $connection $name $arguments}
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
function Close([string]$document){
    $request=Invoke-McpTool $connection gp_close @{document=$document;unsaved='discard'}
    Wait-Operation $request.request 'closed' | Out-Null
}
function Open-Fixture([string]$name){
    $path=Join-Path $run ($name+'.gp')
    Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $path
    if($name -eq 'source'){
        $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Update)
        try {
            $entry=$zip.GetEntry('Content/score.gpif')
            $reader=[IO.StreamReader]::new($entry.Open())
            try {[xml]$gpif=$reader.ReadToEnd()} finally {$reader.Dispose()}
            $text=$gpif.CreateElement('FreeText')
            $text.AppendChild($gpif.CreateCDataSection('P4 phrase')) | Out-Null
            $beat=$gpif.SelectSingleNode('/GPIF/Beats/Beat')
            $beat.InsertBefore($text,$beat.SelectSingleNode('Rhythm')) | Out-Null
            $entry.Delete()
            $writer=[IO.StreamWriter]::new($zip.CreateEntry('Content/score.gpif').Open(),[Text.UTF8Encoding]::new($false))
            try {$writer.Write($gpif.OuterXml)} finally {$writer.Dispose()}
        } finally {$zip.Dispose()}
    }
    $request=Invoke-McpTool $connection gp_open @{path=$path}
    Wait-Operation $request.request 'opened'
}
function Model([string]$document=$script:id){
    $state=Invoke-McpTool $connection gp_score @{document=$document}
    $bars=[ordered]@{}
    foreach($track in $state.tracks){foreach($staff in 0..($track.staves-1)){
        $content=@()
        for($bar=0;$bar -lt $track.bars;$bar+=16){
            $content+=@(Invoke-McpTool $connection gp_read_bars @{document=$document;track=$track.index;staff=$staff;bar=$bar;count=[Math]::Min(16,$track.bars-$bar)}).bars
        }
        foreach($bar in $content){foreach($voice in $bar.voices){$voice.beats=@($voice.beats | Where-Object {-not $_.placeholder})}}
        $bars["$($track.index):$staff"]=$content
    }}
    [pscustomobject]@{tracks=$state.tracks;bars=[pscustomobject]$bars;master=(Invoke-McpTool $connection gp_read_master_bars @{document=$document;count=[Math]::Min(128,$state.tracks[0].bars)}).bars}
}
function Point([int]$bar,[int]$beat,[int]$track=0,[int]$voice=0,[int]$staff=0){@{track=$track;staff=$staff;bar=$bar;voice=$voice;beat=$beat}}
function Select-Range($from,$to,[bool]$allVoices=$false,[bool]$allTracks=$false){
    Call gp_selection @{operation='range';base=$from;extent=$to;all_voices=$allVoices;all_tracks=$allTracks} | Out-Null
}
function Cursor($point){
    Call gp_selection @{operation='clear'} | Out-Null
    foreach($axis in 'track','staff','voice','bar','beat'){
        if($axis -eq 'beat' -and $point.beat -eq 0){
            $bar=Call gp_read_bars @{track=$point.track;staff=$point.staff;bar=$point.bar}
            if(-not $bar.bars[0].voices[$point.voice].beats.Count){continue}
        }
        Call gp_cursor @{axis=$axis;index=$point[$axis]} | Out-Null
    }
}
function Undo {Call gp_undo_redo @{operation='undo'} | Out-Null}
function Reopen([string]$name,$expected){
    $saved=Call gp_save @{path=(Join-Path $run ($name+'-saved.gp'))}
    $request=Invoke-McpTool $connection gp_open @{path=$saved.path}
    $reopened=Wait-Operation $request.request 'opened'
    Assert ((Json (Model $reopened)) -eq (Json $expected)) "$name save/reopen differs"
    Close $reopened
}
function Cycle([string]$name,[scriptblock]$edit,[scriptblock]$verify){
    $before=Model
    $result=& $edit
    $after=Model
    $case=@{name=$name;before=$before;after=$after;result=$result}
    $script:cases+=$case
    & $verify $before $after $result
    Assert ((Json $before) -ne (Json $after)) "$name did not change state"
    Undo
    $case.undo=Model
    Assert ((Json $case.undo) -eq (Json $before)) "$name undo differs"
    Call gp_undo_redo @{operation='redo'} | Out-Null
    Assert ((Json (Model)) -eq (Json $after)) "$name redo differs"
    Reopen $name $after
    Undo
}
function Reject([string]$tool,[hashtable]$arguments){
    $before=Json (Model)
    $state=Json (Call gp_score)
    $buffer=Json (Invoke-McpTool $connection gp_clipboard)
    $arguments.document=$script:id
    $rejected=$false
    try {$rejected=[bool](Invoke-McpTool $connection $tool $arguments -AllowError).error} catch {$rejected=$true}
    Assert $rejected "$tool accepted invalid input: $(Json $arguments)"
    Assert ((Json (Model)) -eq $before -and (Json (Call gp_score)) -eq $state) "$tool rejection changed target or history"
    Assert ((Json (Invoke-McpTool $connection gp_clipboard)) -eq $buffer) "$tool rejection changed clipboard"
}
try {
    $others=(Invoke-McpTool $connection gp_documents).documents
    $id=Open-Fixture 'source'
    $source=$id
    Select-Range (Point 0 0) (Point 0 1)
    $copy=Call gp_clipboard @{operation='copy'}
    $snapshot=Json (Invoke-McpTool $connection gp_clipboard @{operation='read';id=$copy.id})
    Assert ((Call gp_read_bars).bars[0].voices[0].beats[0].text -eq 'P4 phrase') 'Source text fixture is missing'
    $id=Open-Fixture 'target'
    $target=$id
    Cursor (Point 0 2)
    Cycle 'repeat-beats' {Call gp_clipboard @{operation='paste';id=$copy.id;repeat=3}} {
        param($before,$after,$result)
        $a=$after.bars.'0:0'[0].voices[0].beats
        $b=$before.bars.'0:0'[0].voices[0].beats
        Assert ($result.repeat -eq 3 -and $a.Count -eq 10 -and $result.global_bar_delta -eq 0) 'Repeated beat count differs'
        Assert ((Json @($a[2..7].notes)) -eq (Json @($b[0..1].notes+$b[0..1].notes+$b[0..1].notes))) 'Repeated content differs'
        Assert ((Json @($a[0..1]+$a[8..9] | Select-Object -ExcludeProperty index)) -eq (Json @($b | Select-Object -ExcludeProperty index))) 'Repeat changed surrounding beats'
        Assert ((Json $after.bars.'0:0'[1]) -eq (Json $before.bars.'0:0'[1])) 'Repeat changed next bar'
    }
    Assert ((Json (Invoke-McpTool $connection gp_clipboard @{operation='read';id=$copy.id})) -eq $snapshot) 'Paste mutated retained snapshot'
    foreach($includeText in @($false,$true)){
        Cursor (Point 0 1)
        Cycle ('special-text-'+$includeText) {Call gp_clipboard @{operation='paste';id=$copy.id;include_text=$includeText}} {
            param($before,$after,$result)
            $expectedText=if($includeText){'P4 phrase'}else{''}
            Assert ($after.bars.'0:0'[0].voices[0].beats[1].text -eq $expectedText) 'Special-paste text filtering differs'
        }
    }
    Cursor (Point 0 0)
    Cycle 'repeat-100' {Call gp_clipboard @{operation='paste';id=$copy.id;repeat=100}} {
        param($before,$after,$result)
        Assert ($after.bars.'0:0'[0].voices[0].beats.Count -eq 204) 'Repeat limit did not insert 200 beats'
        Assert ((Json @($after.bars.'0:0'[0].voices[0].beats[0..199].notes.midi)) -eq (Json @((40,42)*100))) 'Repeat limit content differs'
    }
    foreach($repeat in @(0,101,1.5,'2')){Reject gp_clipboard @{operation='paste';id=$copy.id;repeat=$repeat}}
    Reject gp_clipboard @{operation='paste';id=$copy.id;include_text='true'}
    Select-Range (Point 0 1) (Point 1 2)
    Cycle 'cross-bar-cut' {Call gp_clipboard @{operation='cut'}} {
        param($before,$after,$result)
        Assert ($result.bar_count -eq 2 -and $result.beat_count -eq 6) 'Cross-bar cut snapshot differs'
        Assert ($after.bars.'0:0'[0].voices[0].beats.Count -eq 1 -and $after.bars.'0:0'[1].voices[0].beats.Count -eq 1) 'Cross-bar cut did not retain boundary beats'
        Assert ($after.bars.'0:0'[0].voices[0].beats[0].notes.fret -eq $before.bars.'0:0'[0].voices[0].beats[0].notes.fret) 'Cross-bar cut changed first boundary'
    }
    $cut=Invoke-McpTool $connection gp_clipboard
    Select-Range (Point 0 1) (Point 1 2)
    Reject gp_clipboard @{operation='paste';id=$cut.id;scope='selection';repeat=2}
    Select-Range (Point 0 0) (Point 1 3) $true $true
    Cycle 'cross-bar-replace' {Call gp_clipboard @{operation='paste';id=$cut.id;scope='selection';repeat=2}} {
        param($before,$after,$result)
        Assert ($result.native_method -eq 'Score::pasteBarRange') 'Cross-bar replacement used wrong method'
        Assert ($after.tracks[0].bars -eq 4) 'Repeated cross-bar replacement bar count differs'
        $notes=@($after.bars.'0:0' | ForEach-Object {$_.voices[0].beats.notes.midi})
        Assert ((Json $notes) -eq '[42,43,45,47,48,50,42,43,45,47,48,50]') 'Cross-bar replacement content differs'
    }
    Reject gp_clipboard @{operation='paste';id=$cut.id;repeat=65}
    Select-Range (Point 0 0) (Point 1 3) $true $true
    Cycle 'repeat-128-bars' {Call gp_clipboard @{operation='paste';id=$cut.id;scope='selection';repeat=64}} {
        param($before,$after,$result)
        Assert ($after.tracks[0].bars -eq 128 -and $result.global_bar_delta -eq 126) '128-bar repeated replacement differs'
        Assert ((Json @($after.bars.'0:0' | ForEach-Object {$_.voices[0].beats.notes.midi})) -eq (Json @((42,43,45,47,48,50)*64))) '128-bar repeated content differs'
    }
    Select-Range (Point 0 1) (Point 1 2)
    foreach($operation in 'clear','remove'){
        Select-Range (Point 0 1) (Point 1 2)
        Cycle ('batch-'+$operation) {Call gp_edit_beat @{operation=$operation;scope='selection'}} {
            param($before,$after,$result)
            Assert ($result.affected_beats -eq 6) 'Batch target count differs'
            Assert ($after.bars.'0:0'[0].voices[0].beats[0].notes.fret -eq $before.bars.'0:0'[0].voices[0].beats[0].notes.fret) 'Batch changed outside first boundary'
            if($operation -eq 'clear'){
                Assert (@($after.bars.'0:0'[0].voices[0].beats[1..3] | Where-Object {-not $_.rest}).Count -eq 0) 'Batch clear retained notes'
            }else{Assert ($after.bars.'0:0'[0].voices[0].beats.Count -eq 1) 'Batch remove retained selected beats'}
        }
    }
    $id=$source
    Cursor (Point 0 0)
    Call gp_set_fret @{string=0;fret=5} | Out-Null
    Select-Range (Point 0 0) (Point 0 1)
    $copy=Call gp_clipboard @{operation='copy'}
    $sourceNotes=(Invoke-McpTool $connection gp_clipboard @{operation='read';id=$copy.id}).bars[0].voices[0].beats.notes
    $id=$target
    Cursor (Point 0 0)
    Call gp_edit_tuning @{track=0;capo=2;preserve_pitch=$false} | Out-Null
    Cursor (Point 0 1)
    Cycle 'capo-paste' {Call gp_clipboard @{operation='paste';id=$copy.id}} {
        param($before,$after,$result)
        Assert ($after.bars.'0:0'[0].voices[0].beats.Count -eq 6) 'Capo paste omitted beats'
        Assert ((Json @($after.bars.'0:0'[0].voices[0].beats[1..2].notes.sounding_midi)) -eq (Json @($sourceNotes.sounding_midi))) 'Capo paste changed sounding pitches'
        Assert ((Json $after.bars.'0:0'[1]) -eq (Json $before.bars.'0:0'[1])) 'Capo paste changed next bar'
    }
    Undo
    $tuning=@((Call gp_score).tracks[0].staff_details[0].tuning | ForEach-Object {$_-2})
    Call gp_edit_tuning @{track=0;tuning=$tuning;preserve_pitch=$false} | Out-Null
    Cursor (Point 0 1)
    Cycle 'different-tuning' {Call gp_clipboard @{operation='paste';id=$copy.id}} {
        param($before,$after,$result)
        Assert ((Json @($after.bars.'0:0'[0].voices[0].beats[1..2].notes.sounding_midi)) -eq (Json @($sourceNotes.sounding_midi))) 'Different tuning changed copied sounding pitches'
    }
    Undo
    Call gp_edit_tuning @{track=0;capo=24;preserve_pitch=$false} | Out-Null
    Cursor (Point 0 1)
    Reject gp_clipboard @{operation='paste';id=$copy.id}
    Undo
    Call gp_edit_track @{track=0;property='transposition';value=2} | Out-Null
    Cursor (Point 0 1)
    Cycle 'transposing-instrument' {Call gp_clipboard @{operation='paste';id=$copy.id}} {
        param($before,$after,$result)
        Assert ((Json @($after.bars.'0:0'[0].voices[0].beats[1..2].notes.sounding_midi)) -eq (Json @($sourceNotes.sounding_midi))) 'Written transposition changed pasted sounding pitches'
    }
    Undo
    Call gp_edit_tracks @{operation='duplicate';track=0} | Out-Null
    foreach($track in 0,1){
        Cursor (Point 0 0 $track 1)
        Call gp_edit_note @{operation='set';string=0;fret=7} | Out-Null
        Call gp_edit_beat @{operation='rhythm';denominator=1} | Out-Null
    }
    foreach($operation in 'clear','remove'){
        Select-Range (Point 0 0) (Point 1 3) $true $true
        Cycle ('multi-track-'+$operation) {Call gp_edit_beat @{operation=$operation;scope='selection'}} {
            param($before,$after,$result)
            Assert ($result.affected_beats -eq 18) 'Multi-track batch count differs'
            foreach($key in '0:0','1:0'){
                Assert (@($after.bars.$key.voices.beats | Where-Object {$_.notes.Count -gt 0}).Count -eq 0) 'Multi-track batch retained notes'
                Assert ($after.tracks[0].bars -eq $before.tracks[0].bars) 'Beat batch deleted master bars'
            }
        }
    }
    Select-Range (Point 0 0) (Point 1 3) $true $true
    $subset=Call gp_selection @{operation='beats';tracks=@(1);voices=@(1)}
    Assert ($subset.count -eq 1 -and $subset.beats[0].track -eq 1 -and $subset.beats[0].voice -eq 1) 'Filtered batch positions differ'
    Cycle 'filtered-clear' {Call gp_edit_beat @{operation='clear';scope='selection';tracks=@(1);voices=@(1)}} {
        param($before,$after,$result)
        Assert ($result.affected_beats -eq 1) 'Filtered batch expanded targets'
        Assert ((Json $after.bars.'0:0') -eq (Json $before.bars.'0:0')) 'Filtered batch changed excluded track'
        Assert ((Json $after.bars.'1:0'[0].voices[0]) -eq (Json $before.bars.'1:0'[0].voices[0])) 'Filtered batch changed excluded voice'
        Assert ($after.bars.'1:0'[0].voices[1].beats[0].rest) 'Filtered clear retained note'
    }
    foreach($filter in @(@{tracks=@()},@{tracks=@(0,0)},@{tracks=@(2)},@{voices=@(4)},@{staves=@(1)})){
        $arguments=@{operation='clear';scope='selection'}
        foreach($key in $filter.Keys){$arguments[$key]=$filter[$key]}
        Reject gp_edit_beat $arguments
    }
    foreach($template in @('Acoustic Piano','Drumkit')){
        $request=Invoke-McpTool $connection gp_new @{template=$template}
        $instrument=Wait-Operation $request.request 'created'
        $id=$instrument
        foreach($midi in $(if($template -eq 'Drumkit'){@(36,38)}else{@(60,64)})){
            Call gp_edit_note @{operation='set';midi=$midi} | Out-Null
        }
        $expected=(Call gp_read_bars).bars[0].voices[0].beats[0].notes[1]
        $selected=Call gp_selection @{operation='note';base=(Point 0 0);note_index=1}
        Assert ($selected.cursor.selection.base.note_midi -eq $expected.midi) 'Keyboard/drum single-note selection differs'
        Select-Range (Point 0 0) (Point 0 0)
        $instrumentCopy=Call gp_clipboard @{operation='copy'}
        Cursor (Point 0 0)
        Cycle ($template+'-repeat') {Call gp_clipboard @{operation='paste';id=$instrumentCopy.id;repeat=2}} {
            param($before,$after,$result)
            Assert ($after.bars.'0:0'[0].voices[0].beats.Count -eq 3) 'Instrument repeated paste beat count differs'
            Assert ((Json @($after.bars.'0:0'[0].voices[0].beats[0].notes)) -eq (Json @($before.bars.'0:0'[0].voices[0].beats[0].notes))) 'Instrument copied notes differ'
        }
        if($template -eq 'Acoustic Piano'){
            Cursor (Point 0 0 0 0 1)
            Call gp_edit_note @{operation='set';midi=48} | Out-Null
            Select-Range (Point 0 0) (Point 0 0) $true $true
            $selected=Call gp_selection @{operation='beats';staves=@(1);voices=@(0)}
            Assert ($selected.count -eq 1 -and $selected.beats[0].staff -eq 1) 'Piano staff filter differs'
            Cycle 'piano-lower-staff-filter' {Call gp_edit_beat @{operation='clear';scope='selection';staves=@(1);voices=@(0)}} {
                param($before,$after,$result)
                Assert ((Json $after.bars.'0:0') -eq (Json $before.bars.'0:0')) 'Piano filter changed upper staff'
                Assert ($after.bars.'0:1'[0].voices[0].beats[0].rest) 'Piano filter left lower-staff note'
            }
        } else {
            $id=$source
            Select-Range (Point 0 0) (Point 0 0)
            $pitched=Call gp_clipboard @{operation='copy'}
            $id=$instrument
            Cursor (Point 0 0)
            Reject gp_clipboard @{operation='paste';id=$pitched.id}
            Select-Range (Point 0 0) (Point 0 0)
            $instrumentCopy=Call gp_clipboard @{operation='copy'}
        }
        $id=$target
        Cursor (Point 0 0)
        Reject gp_clipboard @{operation='paste';id=$instrumentCopy.id}
        Close $instrument
    }
    Close $target
    Close $source
    $id=Open-Fixture 'limit'
    for($track=1;$track -lt 51;$track++){Call gp_edit_tracks @{operation='duplicate';track=0} | Out-Null}
    Select-Range (Point 0 0) (Point 0 3) $true $true
    $large=Call gp_clipboard @{operation='copy'}
    Reject gp_clipboard @{operation='paste';id=$large.id;repeat=100}
    $pasteError=(Invoke-McpTool $connection gp_clipboard @{document=$id;operation='paste';id=$large.id;repeat=100} -AllowError).error
    Assert ($pasteError -like '*20000 beats*') 'Large paste was not rejected by the beat bound'
    Close $id
    Invoke-McpTool $connection gp_clipboard @{operation='clear'} | Out-Null
    Assert ((Json @((Invoke-McpTool $connection gp_documents).documents | Select-Object id,save_path,dirty)) -eq (Json @($others | Select-Object id,save_path,dirty))) 'Transfer checks changed other documents'
    $complete=$true
} finally {
    @{complete=$complete;checks=$checks;cases=$cases;error=if($complete){$null}else{[string]$Error[0]};plugin_sha256=(Get-FileHash -LiteralPath "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash} | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    Close-McpSession $connection
}
Write-Output "PASS: $checks native transfer checks. Evidence: $run"
