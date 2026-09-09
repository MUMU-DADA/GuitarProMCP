param([string]$SessionFile="$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root=Split-Path -Parent $PSScriptRoot
$checks=0
function Assert($condition,[string]$message){if(-not $condition){throw $message};$script:checks++;$script:lastCheck=$message}
function Json($value){ConvertTo-Json -InputObject $value -Depth 30 -Compress}
$connection=New-McpSession -SessionFile $SessionFile
function Tool([string]$name,[hashtable]$arguments=@{}){Invoke-McpTool $connection $name $arguments}
function Point([int]$bar,[int]$beat,[int]$track=0,[int]$voice=0,[int]$staff=0){@{track=$track;staff=$staff;bar=$bar;voice=$voice;beat=$beat}}
function Select-Range([string]$document,$from,$to,[bool]$allVoices=$false,[bool]$allTracks=$false){Tool gp_selection @{document=$document;operation='range';base=$from;extent=$to;all_voices=$allVoices;all_tracks=$allTracks} | Out-Null}
function Edit([string]$document,[string]$level='primary',[int]$actual=3,[int]$normal=2,[string]$scope='selection',[bool]$enabled=$true){
    $arguments=@{document=$document;operation='tuplet';level=$level;scope=$scope;enabled=$enabled}
    if($enabled){$arguments.actual=$actual;$arguments.normal=$normal}
    Tool gp_edit_beat $arguments
}
function Undo([string]$document){Tool gp_undo_redo @{document=$document;operation='undo'} | Out-Null}
function Model([string]$document){
    $score=Tool gp_score @{document=$document}
    $model=[ordered]@{}
    foreach($track in $score.tracks){
        foreach($staff in 0..($track.staves-1)){
            $model["$($track.index):$staff"]=(Tool gp_read_bars @{document=$document;track=$track.index;staff=$staff;count=$track.bars}).bars
        }
    }
    [pscustomobject]$model
}
function Structured($model){
    $copy=Json $model | ConvertFrom-Json
    foreach($entry in $copy.PSObject.Properties){foreach($bar in $entry.Value){foreach($voice in $bar.voices){foreach($beat in $voice.beats){$beat.PSObject.Properties.Remove('rhythm')}}}}
    Json $copy
}
function All-BarPositions($model,[int]$bar=0){
    foreach($entry in $model.PSObject.Properties){
        $indices=$entry.Name.Split(':')
        foreach($voice in $entry.Value[$bar].voices){foreach($beat in $voice.beats){
            if(-not $beat.placeholder){Point $bar $beat.index ([int]$indices[0]) $voice.index ([int]$indices[1])}
        }}
    }
}
function Assert-Change($before,$after,$positions,[string]$level,[int]$actual,[int]$normal,[bool]$enabled=$true){
    $expected=Json $before | ConvertFrom-Json
    foreach($p in $positions){
        $ratio=$expected.("$($p.track):$($p.staff)")[$p.bar].voices[$p.voice].beats[$p.beat].tuplets.$level
        $ratio.actual=if($enabled){$actual}else{0};$ratio.normal=if($enabled){$normal}else{0};$ratio.enabled=$enabled
    }
    Assert ((Structured $after) -eq (Structured $expected)) 'Tuplet changed notes, another level, dots, note value or content outside the expected positions'
}
function Open-Score([string]$path){
    Tool gp_open @{path=$path} | Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $found=@((Tool gp_documents).documents | Where-Object opened_path -EQ $path.Replace('\','/'))
        if($found.Count -eq 1){return $found[0].id}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'Native open did not complete'
}
function Close-Score([string]$document){
    $request=Tool gp_close @{document=$document}
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $state=Tool gp_documents
        if($state.closing.request -eq $request.request -and $state.closing.status -eq 'closed'){return}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'Native close did not complete'
}
function Save-Read([string]$document,[string]$name){
    $saved=Tool gp_save @{document=$document;path=(Join-Path $run "$name.gp")}
    $zip=[IO.Compression.ZipFile]::OpenRead($saved.path)
    try {
        $reader=[IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try{[xml]$xml=$reader.ReadToEnd()}finally{$reader.Dispose()}
    }finally{$zip.Dispose()}
    [pscustomobject]@{path=$saved.path;xml=$xml}
}
function Gpif-Rhythm($xml,$position){
    # The fixture and duplicate tracks have one staff each; piano is checked by native reopen.
    $barId=($xml.GPIF.MasterBars.MasterBar[$position.bar].Bars -split '\s+')[$position.track]
    $bar=$xml.SelectSingleNode("/GPIF/Bars/Bar[@id='$barId']")
    $voiceId=($bar.Voices -split '\s+')[$position.voice]
    $voice=$xml.SelectSingleNode("/GPIF/Voices/Voice[@id='$voiceId']")
    $beatId=($voice.Beats -split '\s+')[$position.beat]
    $beat=$xml.SelectSingleNode("/GPIF/Beats/Beat[@id='$beatId']")
    $xml.SelectSingleNode("/GPIF/Rhythms/Rhythm[@id='$($beat.Rhythm.ref)']")
}
function Reject([hashtable]$arguments){
    $arguments.document=$source
    $before=Json (Tool gp_score @{document=$source});$notes=Json (Model $source)
    $rejected=$false
    try{$rejected=[bool](Invoke-McpTool $connection gp_edit_beat $arguments -AllowError).error}catch{$rejected=$true}
    Assert $rejected "Invalid tuplet request accepted: $(Json $arguments)"
    Assert ((Json (Tool gp_score @{document=$source})) -eq $before -and (Json (Model $source)) -eq $notes) 'Invalid tuplet request changed the score'
}
try {
    $identity=Tool gp_capabilities
    Assert ($identity.hidden_mode -and $identity.pid -ne $identity.foreground_pid -and $identity.qt_thread) 'Host is not in native background mode'
    $others=(Tool gp_documents).documents
    $run=Join-Path $root ('artifacts/native-tuplets-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $fixture=Join-Path $PSScriptRoot 'testdata/minimal.gp';$fixtureHash=(Get-FileHash $fixture).Hash
    $sourcePath=Join-Path $run 'source.gp';$targetPath=Join-Path $run 'target.gp'
    Copy-Item $fixture $sourcePath;Copy-Item $fixture $targetPath
    $source=Open-Score $sourcePath;$target=Open-Score $targetPath
    Select-Range $source (Point 0 0) (Point 0 2)
    foreach($invalid in @(
        @{operation='tuplet'},@{operation='tuplet';actual=0;normal=2},@{operation='tuplet';actual=3;normal=0},
        @{operation='tuplet';actual=256;normal=2},@{operation='tuplet';actual=3;normal=256},@{operation='tuplet';actual=-1;normal=2},
        @{operation='tuplet';actual=3.5;normal=2},@{operation='tuplet';actual='3';normal=2},@{operation='tuplet';actual=1;normal=1},
        @{operation='tuplet';actual=3;normal=2;level='third'},@{operation='tuplet';actual=3;normal=2;enabled='true'},
        @{operation='tuplet';enabled=$false;actual=3},@{operation='tuplet';actual=3;normal=2;dots=1},
        @{operation='tuplet';actual=3;normal=2;denominator=8},@{operation='rhythm';denominator=8;level='primary'}
    )){Reject $invalid}
    $positions=@((Point 0 0),(Point 0 1),(Point 0 2))
    $evidence=@()
    foreach($ratio in @(@(3,2),@(2,3),@(5,4),@(7,4),@(9,8),@(11,8),@(13,8),@(255,254),@(255,1),@(1,255))){
        $before=Model $source;$cursor=(Tool gp_score @{document=$source}).cursor
        $changed=Edit $source 'primary' $ratio[0] $ratio[1]
        Assert ($changed.affected_beats -eq 3 -and $changed.dirty) 'Selection tuplet edit count or dirty state differs'
        $after=Model $source
        Assert-Change $before $after $positions 'primary' $ratio[0] $ratio[1]
        Assert ((Json (Tool gp_score @{document=$source}).cursor) -eq (Json $cursor)) 'Tuplet edit changed cursor or selection'
        $saved=Save-Read $source "primary-$($ratio[0])-$($ratio[1])"
        foreach($p in $positions){
            $rhythm=Gpif-Rhythm $saved.xml $p
            Assert ([int]$rhythm.PrimaryTuplet.num -eq $ratio[0] -and [int]$rhythm.PrimaryTuplet.den -eq $ratio[1]) 'GPIF primary tuplet differs'
        }
        Assert ($null -eq (Gpif-Rhythm $saved.xml (Point 0 3)).PrimaryTuplet) 'Saved tuplet changed an unselected beat'
        Edit $source 'primary' $ratio[0] $ratio[1] | Out-Null
        Undo $source
        Assert ((Json (Model $source)) -eq (Json $before)) 'Repeated tuplet edit added history or undo failed'
        Tool gp_undo_redo @{document=$source;operation='redo'} | Out-Null
        Assert ((Json (Model $source)) -eq (Json $after)) 'Tuplet redo differs'
        Edit $source 'primary' 0 0 'selection' $false | Out-Null
        Assert ((Json (Model $source)) -eq (Json $before)) 'Clearing primary tuplet differs'
        Undo $source;Undo $source
        Assert ((Json (Model $source)) -eq (Json $before)) 'Tuplet clear undo did not restore the original model'
        $evidence+=@{actual=$ratio[0];normal=$ratio[1];saved=$saved.path}
    }
    Select-Range $source (Point 1 1) (Point 0 2)
    $before=Model $source
    $changed=Edit $source 'primary' 7 4
    Assert ($changed.affected_beats -eq 4) 'Reverse cross-bar tuplet selection differs'
    Assert-Change $before (Model $source) @((Point 0 2),(Point 0 3),(Point 1 0),(Point 1 1)) 'primary' 7 4
    Undo $source
    Assert ((Json (Model $source)) -eq (Json $before)) 'Cross-bar tuplet undo differs'
    Select-Range $source (Point 0 0) (Point 0 2)
    # Cursor scope must remain one beat even when a larger UI selection is active.
    $before=Model $source
    Edit $source 'secondary' 5 4 'cursor' | Out-Null
    Assert-Change $before (Model $source) @((Point 0 2)) 'secondary' 5 4
    Undo $source
    Edit $source 'primary' 3 2 | Out-Null
    $primary=Model $source
    Edit $source 'secondary' 5 4 | Out-Null
    $nested=Model $source
    Assert-Change $primary $nested $positions 'secondary' 5 4
    $savedNested=Save-Read $source 'nested'
    foreach($p in $positions){
        $rhythm=Gpif-Rhythm $savedNested.xml $p
        Assert ([int]$rhythm.PrimaryTuplet.num -eq 3 -and [int]$rhythm.PrimaryTuplet.den -eq 2 -and [int]$rhythm.SecondaryTuplet.num -eq 5 -and [int]$rhythm.SecondaryTuplet.den -eq 4) 'Nested tuplets did not persist independently'
    }
    $reopened=Open-Score $savedNested.path
    Assert ((Json (Model $reopened)) -eq (Json $nested)) 'Nested tuplets changed after native save/open'
    Close-Score $reopened
    Edit $source 'secondary' 0 0 'selection' $false | Out-Null
    Assert ((Json (Model $source)) -eq (Json $primary)) 'Clearing secondary tuplet changed the primary level'
    Undo $source
    Assert ((Json (Model $source)) -eq (Json $nested)) 'Secondary tuplet clear undo differs'
    Tool gp_edit_beat @{document=$source;operation='rhythm';denominator=8;scope='selection'} | Out-Null
    Tool gp_edit_beat @{document=$source;operation='dots';dots=1;scope='selection'} | Out-Null
    $rhythms=Model $source
    foreach($p in $positions){$b=$rhythms.'0:0'[0].voices[0].beats[$p.beat];Assert ($b.native_note_value -eq 5 -and $b.dots -eq 1 -and (Json $b.tuplets) -eq (Json $nested.'0:0'[0].voices[0].beats[$p.beat].tuplets)) 'Note value or dot editing overwrote tuplets'}
    Undo $source;Undo $source
    Edit $source 'primary' 0 0 'selection' $false | Out-Null
    $secondaryOnly=Model $source
    Assert-Change $nested $secondaryOnly $positions 'primary' 0 0 $false
    $savedSecondary=Save-Read $source 'secondary-only'
    $reopened=Open-Score $savedSecondary.path
    Assert ((Json (Model $reopened)) -eq (Json $secondaryOnly)) 'Secondary-only tuplets changed after native save/open'
    Close-Score $reopened
    Undo $source
    $clip=Tool gp_clipboard @{document=$source;operation='copy'}
    $clipBeats=(Tool gp_clipboard @{operation='read';id=$clip.id}).bars[0].voices[0].beats
    foreach($b in $clipBeats){Assert ($b.tuplets.primary.actual -eq 3 -and $b.tuplets.secondary.actual -eq 5) 'Plugin clipboard lost nested tuplets'}
    Tool gp_clipboard @{document=$target;operation='paste';id=$clip.id} | Out-Null
    $pasted=Model $target
    foreach($i in 0..2){Assert ((Json $pasted.'0:0'[0].voices[0].beats[$i].tuplets) -eq (Json $clipBeats[$i].tuplets)) 'Pasted nested tuplets differ'}
    Undo $target
    Undo $source;Undo $source
    Tool gp_cursor @{document=$source;axis='voice';index=1} | Out-Null
    Tool gp_cursor @{document=$source;axis='bar';index=0} | Out-Null
    Tool gp_edit_note @{document=$source;operation='set';string=0;fret=7} | Out-Null
    Tool gp_edit_beat @{document=$source;operation='rhythm';denominator=2} | Out-Null
    Tool gp_edit_tracks @{document=$source;operation='duplicate';track=0} | Out-Null
    Select-Range $source (Point 0 0) (Point 0 2) $true
    $before=Model $source
    $changed=Edit $source
    Assert ($changed.affected_beats -eq 4) 'Multi-voice tuplet selection differs'
    Assert-Change $before (Model $source) @($positions+(Point 0 0 0 1)) 'primary' 3 2
    Undo $source
    Assert ((Json (Model $source)) -eq (Json $before)) 'Multi-voice tuplet undo was not atomic'
    Select-Range $source (Point 0 0) (Point 0 0) $true $true
    $before=Model $source;$allPositions=@(All-BarPositions $before)
    $changed=Edit $source
    Assert ($changed.affected_beats -eq $allPositions.Count -and $allPositions.Count -eq 10) 'Multi-track tuplet edit missed a voice'
    Assert-Change $before (Model $source) $allPositions 'primary' 3 2
    Undo $source
    Assert ((Json (Model $source)) -eq (Json $before)) 'Multi-track tuplet undo was not atomic'
    $creation=Tool gp_new @{template='Acoustic Piano'}
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {$state=(Tool gp_documents).creation;if($state.request -eq $creation.request -and $state.status -eq 'created'){break};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
    if($state.status -ne 'created'){throw 'Piano template creation failed'}
    $piano=$state.document
    Tool gp_edit_beat @{document=$piano;operation='insert';denominator=8} | Out-Null
    Tool gp_cursor @{document=$piano;axis='staff';index=1} | Out-Null
    Tool gp_edit_beat @{document=$piano;operation='insert';denominator=4} | Out-Null
    Tool gp_edit_beat @{document=$piano;operation='insert';denominator=2} | Out-Null
    Select-Range $piano (Point 0 0 0 0 1) (Point 0 1 0 0 1)
    $before=Model $piano
    Edit $piano | Out-Null
    Assert-Change $before (Model $piano) @((Point 0 0 0 0 1),(Point 0 1 0 0 1)) 'primary' 3 2
    $savedPiano=Save-Read $piano 'piano'
    $reopened=Open-Score $savedPiano.path
    Assert ((Json (Model $reopened)) -eq (Json (Model $piano))) 'Piano tuplet changed after native save/open'
    Close-Score $reopened
    Undo $piano
    Assert ((Json (Model $piano)) -eq (Json $before)) 'Piano tuplet undo differs'
    foreach($document in $source,$target,$piano){Tool gp_save_as @{document=$document;path=(Join-Path $run "$document-retained.gp")} | Out-Null;Close-Score $document}
    Tool gp_clipboard @{operation='clear'} | Out-Null
    Assert ((Json ((Tool gp_documents).documents | Sort-Object id | Select-Object id,save_path,dirty)) -eq (Json ($others | Sort-Object id | Select-Object id,save_path,dirty))) 'Tuplet checks changed other documents'
    $afterIdentity=Tool gp_capabilities
    Assert ($afterIdentity.pid -eq $identity.pid -and $afterIdentity.hidden_mode -and $afterIdentity.foreground_pid -ne $identity.pid) 'Tuplet operations activated or restarted the host'
    Assert ((Get-FileHash $fixture).Hash -eq $fixtureHash) 'Fixture changed'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;ratios=$evidence;nested=$savedNested.path;piano=$savedPiano.path;multi_track_positions=$allPositions} | ConvertTo-Json -Depth 24 | Set-Content (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native tuplet checks. Evidence: $run"
}catch{
    $failure=$_
    if($run){@{checks=$checks;error=$failure.ToString();last_passed=$lastCheck} | ConvertTo-Json | Set-Content (Join-Path $run 'failure.json')}
    Write-Output "Failed after $checks checks; last passed assertion: $lastCheck"
    throw $failure
}finally{Close-McpSession $connection}
