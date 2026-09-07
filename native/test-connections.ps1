param([string]$SessionFile="$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference='Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root=Split-Path -Parent $PSScriptRoot
$checks=0
function Assert($condition,[string]$message){if(-not $condition){throw $message};$script:checks++;$script:lastCheck=$message}
function Json($value){ConvertTo-Json -InputObject $value -Depth 30 -Compress}
$connection=New-McpSession -SessionFile $SessionFile
function Tool([string]$name,[hashtable]$arguments=@{}){Invoke-McpTool $connection $name $arguments}
function Point([int]$bar,[int]$beat,[int]$track=0,[int]$voice=0,[int]$staff=0){@{track=$track;staff=$staff;bar=$bar;voice=$voice;beat=$beat}}
function Cursor($point){
    Tool gp_selection @{document=$script:id;operation='clear'} | Out-Null
    foreach($axis in 'track','staff','voice','bar','beat'){
        if($axis -eq 'beat' -and $point.beat -eq 0){
            $bar=Tool gp_read_bars @{document=$script:id;track=$point.track;staff=$point.staff;bar=$point.bar}
            if($bar.bars[0].voices[$point.voice].beats.Count -eq 0){continue}
        }
        Tool gp_cursor @{document=$script:id;axis=$axis;index=$point[$axis]} | Out-Null
    }
}
function Select-Range($from,$to,[bool]$voices=$false,[bool]$tracks=$false){Tool gp_selection @{document=$script:id;operation='range';base=$from;extent=$to;all_voices=$voices;all_tracks=$tracks} | Out-Null}
function Model([string]$document=$script:id){
    $model=[ordered]@{}
    foreach($track in (Tool gp_score @{document=$document}).tracks){foreach($staff in 0..($track.staves-1)){
        $model["$($track.index):$staff"]=(Tool gp_read_bars @{document=$document;track=$track.index;staff=$staff;count=$track.bars}).bars
    }}
    [pscustomobject]$model
}
function Beat($model,$point){$model.("$($point.track):$($point.staff)")[$point.bar].voices[$point.voice].beats[$point.beat]}
function Link([string]$kind,[bool]$enabled=$true,[string]$scope='cursor',[int]$string=-1){
    $args=@{document=$script:id;kind=$kind;enabled=$enabled;scope=$scope}
    if($string -ge 0){$args.string=$string}
    $cursor=(Tool gp_score @{document=$script:id}).cursor
    $result=Tool gp_edit_connection $args
    Assert ($result.cursor_preserved -and (Json $result.cursor) -eq (Json $cursor)) 'Connection changed cursor or selection'
    Assert ($result.status -eq 'executed' -and $result.requested_enabled -eq $enabled) 'Connection command result differs'
    $result
}
function Undo {Tool gp_undo_redo @{document=$script:id;operation='undo'} | Out-Null}
function Redo {Tool gp_undo_redo @{document=$script:id;operation='redo'} | Out-Null}
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
function Save-Read([string]$name){
    $saved=Tool gp_save @{document=$script:id;path=(Join-Path $run "$name.gp")}
    $zip=[IO.Compression.ZipFile]::OpenRead($saved.path)
    try {
        $reader=[IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try{[xml]$xml=$reader.ReadToEnd()}finally{$reader.Dispose()}
    }finally{$zip.Dispose()}
    $reopened=Open-Score $saved.path
    Assert ((Json (Model $reopened)) -eq (Json (Model))) "$name changed after native save/open"
    Close-Score $reopened
    [pscustomobject]@{path=$saved.path;xml=$xml}
}
function Gpif-Beat($xml,$p){
    $barId=($xml.GPIF.MasterBars.MasterBar[$p.bar].Bars -split '\s+')[$p.track]
    $bar=$xml.SelectSingleNode("/GPIF/Bars/Bar[@id='$barId']")
    $voiceId=($bar.Voices -split '\s+')[$p.voice]
    $voice=$xml.SelectSingleNode("/GPIF/Voices/Voice[@id='$voiceId']")
    $beatId=($voice.Beats -split '\s+')[$p.beat]
    $xml.SelectSingleNode("/GPIF/Beats/Beat[@id='$beatId']")
}
function Expect-Legato($baseline,$points){
    $expected=Json $baseline | ConvertFrom-Json
    for($i=0;$i -lt $points.Count-1;$i++){
        (Beat $expected $points[$i]).legato.origin=$true
        (Beat $expected $points[$i+1]).legato.destination=$true
    }
    $expected
}
try {
    $others=(Tool gp_documents).documents
    $identity=Tool gp_capabilities
    Assert ($identity.hidden_mode -and $identity.qt_thread -and $identity.pid -ne $identity.foreground_pid) 'Host is not hidden and in background'
    $fixture=Join-Path $PSScriptRoot 'testdata/minimal.gp'
    $fixtureHash=(Get-FileHash $fixture).Hash
    $run=Join-Path $root ('artifacts/native-connections-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $copy=Join-Path $run 'fixture.gp'
    Copy-Item $fixture $copy
    $script:id=Open-Score $copy
    Cursor (Point 0 0)
    $original=Model
    $invalid=@(
        @{kind='unknown';enabled=$true},@{kind='tie';enabled='true'},@{kind='legato';enabled=$true;scope='other'},
        @{kind='legato';enabled=$true;string=0},@{kind='tie';enabled=$true;scope='selection';string=0},
        @{kind='tie';enabled=$true;string=-1},@{kind='tie';enabled=$true;string=0.5},@{kind='tie';enabled=$true;string=16},
        @{kind='tie';enabled=$true;string=1},@{kind='legato';enabled=$true;scope='selection'}
    )
    foreach($args in $invalid){
        $args.document=$script:id
        try {$rejected=(Invoke-McpTool $connection gp_edit_connection $args -AllowError).error}
        catch {if(($_.Exception.Message | ConvertFrom-Json).code -ne -32602){throw};$rejected=$true}
        Assert $rejected 'Invalid connection accepted'
    }
    Assert ((Json (Model)) -eq (Json $original) -and -not (Tool gp_score @{document=$script:id}).dirty) 'Invalid connection changed score'
    $evidence=@()
    $cases=@(
        @{name='cursor-legato';scope='cursor';points=@((Point 0 0),(Point 0 1))},
        @{name='range-legato';scope='selection';points=@((Point 0 1),(Point 0 2),(Point 0 3))},
        @{name='cross-bar-reversed-legato';scope='selection';reverse=$true;points=@((Point 0 2),(Point 0 3),(Point 1 0),(Point 1 1))}
    )
    foreach($case in $cases){
        if($case.scope -eq 'cursor'){Cursor $case.points[0]}
        elseif($case.reverse){Select-Range $case.points[-1] $case.points[0]}
        else{Select-Range $case.points[0] $case.points[-1]}
        $before=Model
        $expected=Expect-Legato $before $case.points
        $result=Link legato $true $case.scope
        Assert ((Json (Model)) -eq (Json $expected)) "$($case.name) changed notes or wrong connection endpoints"
        Assert ($result.changed_selected_beats -eq $(if($case.scope -eq 'cursor'){1}else{$case.points.Count})) 'Selected-beat readback differs'
        $saved=Save-Read $case.name
        foreach($p in $case.points){
            $node=(Gpif-Beat $saved.xml $p).Legato
            $state=(Beat $expected $p).legato
            Assert ($node.origin -eq $state.origin.ToString().ToLowerInvariant() -and $node.destination -eq $state.destination.ToString().ToLowerInvariant()) 'GPIF legato endpoints differ'
        }
        Undo
        Assert ((Json (Model)) -eq (Json $before)) 'Legato undo did not restore exact model'
        Redo
        Assert ((Json (Model)) -eq (Json $expected)) 'Legato redo differs'
        Link legato $false $case.scope | Out-Null
        Assert ((Json (Model)) -eq (Json $before)) 'Legato clear differs'
        Undo
        Assert ((Json (Model)) -eq (Json $expected)) 'Legato clear undo differs'
        Undo
        $evidence+=@{name=$case.name;path=$saved.path;result=$result}
    }
    Select-Range (Point 0 0) (Point 0 3)
    $before=Model
    Link legato | Out-Null
    Assert ((Json (Model)) -eq (Json (Expect-Legato $before @((Point 0 3),(Point 1 0))))) 'Cursor legato applied to larger UI selection'
    Undo
    foreach($variant in @('beat','single','single-different-pitch')){
        $single=$variant -ne 'beat'
        Cursor (Point 0 1)
        if($single){
            if($variant -eq 'single'){Tool gp_set_fret @{document=$script:id;string=0;fret=0} | Out-Null}
            Tool gp_edit_note @{document=$script:id;operation='set';string=1;fret=7} | Out-Null
        }
        $before=Model
        $expected=Json $before | ConvertFrom-Json
        $previous=(Beat $expected (Point 0 0)).notes[0]
        $destination=(Beat $expected (Point 0 1)).notes[0]
        $previous.tie.origin=$true
        $destination.tie.destination=$true
        $destination.fret=0;$destination.midi=40;$destination.sounding_midi=40;$destination.accidental=0
        $result=Link tie $true cursor $(if($single){0}else{-1})
        Assert ((Json (Model)) -eq (Json $expected)) 'Tie changed unexpected notes, strings or rhythm'
        Assert ($result.changed_selected_beats -eq 1 -and $result.observed_beats[0].notes[0].tie.destination) 'Tie result did not report destination'
        $saved=Save-Read "tie-$variant"
        foreach($point in @((Point 0 0),(Point 0 1))){
            $beat=Gpif-Beat $saved.xml $point
            $noteId=($beat.Notes -split '\s+')[0]
            $tie=$saved.xml.SelectSingleNode("/GPIF/Notes/Note[@id='$noteId']/Tie")
            $state=(Beat $expected $point).notes[0].tie
            Assert ($tie.origin -eq $state.origin.ToString().ToLowerInvariant() -and $tie.destination -eq $state.destination.ToString().ToLowerInvariant()) 'GPIF tie endpoints differ'
        }
        Undo
        Assert ((Json (Model)) -eq (Json $before)) 'Tie undo lost original pitch or chord'
        Redo
        Assert ((Json (Model)) -eq (Json $expected)) 'Tie redo differs'
        Link tie $false cursor $(if($single){0}else{-1}) | Out-Null
        $cleared=Json $expected | ConvertFrom-Json
        (Beat $cleared (Point 0 0)).notes[0].tie.origin=$false
        (Beat $cleared (Point 0 1)).notes[0].tie.destination=$false
        Assert ((Json (Model)) -eq (Json $cleared)) 'Tie clear should preserve its current pitch'
        Undo
        Assert ((Json (Model)) -eq (Json $expected)) 'Tie clear undo differs'
        Undo
        if($single){Undo;if($variant -eq 'single'){Undo}}
        $evidence+=@{name="tie-$variant";path=$saved.path;result=$result}
    }
    Cursor (Point 0 0)
    $before=Model
    Link legato | Out-Null
    $linked=Model
    $repeat=Link legato
    Assert ($repeat.changed_selected_beats -eq 0 -and (Json (Model)) -eq (Json $linked)) 'Repeated connection changed model'
    Undo
    Assert ((Json (Model)) -eq (Json $linked)) 'Native repeated connection undo behavior changed'
    Undo
    Assert ((Json (Model)) -eq (Json $before)) 'Native connection history did not restore baseline'
    foreach($p in @((Point 0 0))){
        Cursor $p
        $before=Model
        $result=Link tie
        Assert ($result.changed_selected_beats -eq 0 -and (Json (Model)) -eq (Json $before)) 'Nonapplicable tie changed notes or falsely reported changes'
        Undo
    }
    Cursor (Point 0 3)
    $before=Model
    $expected=Json $before | ConvertFrom-Json
    $added=Json (Beat $expected (Point 0 2)).notes[0] | ConvertFrom-Json
    (Beat $expected (Point 0 2)).notes[0].tie.origin=$true
    $added.tie.destination=$true
    (Beat $expected (Point 0 3)).notes+=@($added)
    Link tie | Out-Null
    Assert ((Json (Model)) -eq (Json $expected)) 'Whole-beat tie did not retain existing notes while adding missing string'
    Undo
    Assert ((Json (Model)) -eq (Json $before)) 'Automatic tie note insertion did not undo exactly'
    Select-Range (Point 1 1) (Point 0 3)
    $before=Model
    $expected=Json $before | ConvertFrom-Json
    (Beat $expected (Point 0 3)).notes[0].tie.origin=$true
    foreach($p in @((Point 1 0),(Point 1 1))){
        $note=(Beat $expected $p).notes[0]
        $note.tie.destination=$true;$note.fret=0;$note.midi=45;$note.sounding_midi=45;$note.accidental=0
    }
    (Beat $expected (Point 1 0)).notes[0].tie.origin=$true
    Link tie $true selection | Out-Null
    Assert ((Json (Model)) -eq (Json $expected)) 'Reversed cross-bar tie changed wrong endpoints or pitches'
    $saved=Save-Read 'cross-bar-tie'
    $evidence+=@{name='cross-bar-tie';path=$saved.path}
    Undo
    Assert ((Json (Model)) -eq (Json $before)) 'Cross-bar tie undo differs'
    Cursor (Point 0 0 0 1)
    Tool gp_edit_note @{document=$script:id;operation='set';string=0;fret=5} | Out-Null
    Tool gp_edit_beat @{document=$script:id;operation='insert';denominator=4} | Out-Null
    Tool gp_edit_note @{document=$script:id;operation='set';string=0;fret=5} | Out-Null
    Cursor (Point 0 0)
    Tool gp_edit_tracks @{document=$script:id;operation='duplicate';track=0} | Out-Null
    foreach($allTracks in @($false,$true)){
        Select-Range (Point 0 0) (Point 0 1) $true $allTracks
        $before=Model
        foreach($kind in @('legato','tie')){
            $expected=Json $before | ConvertFrom-Json
            foreach($track in $(if($allTracks){@(0,1)}else{@(0)})){
                foreach($voice in @(0,1)){
                    $last=if($allTracks -and $voice -eq 0){3}else{1}
                    if($kind -eq 'legato'){
                        $points=@(0..$last | ForEach-Object {Point 0 $_ $track $voice})
                        $expected=Expect-Legato $expected $points
                    }else{
                        $last=if($allTracks -and $voice -eq 0){2}else{1}
                        (Beat $expected (Point 0 0 $track $voice)).notes[0].tie.origin=$true
                        foreach($index in 1..$last){
                            $note=(Beat $expected (Point 0 $index $track $voice)).notes[0]
                            $note.tie.destination=$true;$note.tie.origin=$index -lt $last
                            $note.fret=if($voice -eq 0){0}else{5};$note.midi=if($voice -eq 0){40}else{45};$note.sounding_midi=$note.midi;$note.accidental=0
                        }
                    }
                }
            }
            Link $kind $true selection | Out-Null
            Assert ((Json (Model)) -eq (Json $expected)) "$kind all_tracks=$allTracks changed the wrong voices or tracks"
            $saved=Save-Read "$kind-all-tracks-$allTracks"
            $evidence+=@{name="$kind-all-tracks-$allTracks";path=$saved.path}
            Undo
            Assert ((Json (Model)) -eq (Json $before)) "$kind multi-range undo was not atomic"
            Redo
            Assert ((Json (Model)) -eq (Json $expected)) "$kind multi-range redo differs"
            Undo
        }
    }
    $main=$script:id
    $creation=Tool gp_new @{template='Acoustic Piano'}
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do{$state=(Tool gp_documents).creation;if($state.request -eq $creation.request -and $state.status -eq 'created'){break};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
    Assert ($state.request -eq $creation.request -and $state.status -eq 'created') 'Piano creation did not complete'
    $script:id=$state.document
    foreach($staff in @(0,1)){
        Cursor (Point 0 0 0 0 $staff)
        Tool gp_edit_note @{document=$script:id;operation='set';string=0;fret=0} | Out-Null
        Tool gp_edit_beat @{document=$script:id;operation='insert';denominator=4} | Out-Null
        Tool gp_edit_note @{document=$script:id;operation='set';string=0;fret=0} | Out-Null
    }
    Select-Range (Point 0 0 0 0 1) (Point 0 1 0 0 1)
    $before=Model
    foreach($kind in @('legato','tie')){
        $expected=Json $before | ConvertFrom-Json
        if($kind -eq 'legato'){$expected=Expect-Legato $before @((Point 0 0 0 0 1),(Point 0 1 0 0 1))}
        else{(Beat $expected (Point 0 0 0 0 1)).notes[0].tie.origin=$true;(Beat $expected (Point 0 1 0 0 1)).notes[0].tie.destination=$true}
        Link $kind $true selection | Out-Null
        Assert ((Json (Model)) -eq (Json $expected)) "$kind changed another piano staff"
        $saved=Save-Read "piano-$kind"
        $evidence+=@{name="piano-$kind";path=$saved.path}
        Undo
        Assert ((Json (Model)) -eq (Json $before)) "Piano $kind undo differs"
    }
    Tool gp_save_as @{document=$script:id;path=(Join-Path $run 'piano-retained.gp')} | Out-Null
    Close-Score $script:id
    $script:id=$main
    Tool gp_save_as @{document=$script:id;path=(Join-Path $run 'restored.gp')} | Out-Null
    Close-Score $script:id
    $after=Tool gp_capabilities
    Assert ($after.pid -eq $identity.pid -and $after.hidden_mode -and $after.foreground_pid -ne $after.pid) 'Connection commands activated or restarted host'
    Assert ((Get-FileHash $fixture).Hash -eq $fixtureHash -and (Get-FileHash $copy).Hash -eq $fixtureHash) 'Fixture changed'
    Assert ((Json ((Tool gp_documents).documents | Sort-Object id | Select-Object id,save_path,dirty)) -eq (Json ($others | Sort-Object id | Select-Object id,save_path,dirty))) 'Connection test changed another document'
    @{checks=$checks;identity_before=$identity;identity_after=$after;cases=$evidence} | ConvertTo-Json -Depth 24 | Set-Content (Join-Path $run 'verification.json')
    "PASS: $checks native connection checks. Evidence: $run"
}catch{
    if($run){@{checks=$checks;error=$_.ToString();last_passed=$lastCheck;expected=$expected;observed=$(try{Model}catch{$null})} | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $run 'failure.json')}
    "Failed after $checks checks; last passed assertion: $lastCheck"
    throw
}finally{Close-McpSession $connection}
