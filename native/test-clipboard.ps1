param([string]$SessionFile="$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference='Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root=Split-Path -Parent $PSScriptRoot
$checks=0
function Assert($condition,[string]$message){if(-not $condition){throw $message};$script:checks++;$script:lastCheck=$message}
function Json($value){ConvertTo-Json -InputObject $value -Depth 24 -Compress}
function Point([int]$bar,[int]$beat,[int]$track=0,[int]$voice=0,[int]$staff=0){@{track=$track;staff=$staff;bar=$bar;voice=$voice;beat=$beat}}
$connection=New-McpSession -SessionFile $SessionFile
function Tool([string]$name,[hashtable]$arguments=@{}){Invoke-McpTool $connection $name $arguments}
function Clip([hashtable]$arguments=@{}){Tool gp_clipboard $arguments}
function Select-Range([string]$document,$from,$to,[bool]$allVoices=$false,[bool]$allTracks=$false){Tool gp_selection @{document=$document;operation='range';base=$from;extent=$to;all_voices=$allVoices;all_tracks=$allTracks} | Out-Null}
function Bars([string]$document,[int]$track=0,[int]$staff=0,[int]$count=2){,(Tool gp_read_bars @{document=$document;track=$track;staff=$staff;count=$count}).bars}
function Undo([string]$document){Tool gp_undo_redo @{document=$document;operation='undo'} | Out-Null}
function Redo([string]$document){Tool gp_undo_redo @{document=$document;operation='redo'} | Out-Null}
function Musical($beats){@($beats | Select-Object notes,rhythm,native_note_value,dots,rest,placeholder)}
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
function New-Score([string]$template){
    $request=Tool gp_new @{template=$template}
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $creation=(Tool gp_documents).creation
        if($creation.request -eq $request.request -and $creation.status -eq 'created'){return $creation.document}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'Native template creation did not complete'
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
function Reject([hashtable]$arguments){
    $document=if($arguments.document){$arguments.document}else{$target}
    $before=Json (Tool gp_score @{document=$document})
    $bufferBefore=Json (Clip)
    $active=(Tool gp_documents).active_document
    $rejected=$false
    try{$rejected=[bool](Invoke-McpTool $connection gp_clipboard $arguments -AllowError).error}catch{$rejected=$true}
    Assert $rejected "Invalid clipboard request was accepted: $(Json $arguments)"
    Assert ((Json (Tool gp_score @{document=$document})) -eq $before) 'Rejected clipboard request changed target state'
    Assert ((Json (Clip)) -eq $bufferBefore -and (Tool gp_documents).active_document -eq $active) 'Rejected clipboard request changed buffer or active document'
}
try {
    $identity=Tool gp_capabilities
    Assert ($identity.hidden_mode -and $identity.pid -ne $identity.foreground_pid -and $identity.qt_thread) 'Host is not running in native background mode'
    $others=(Tool gp_documents).documents
    $run=Join-Path $root ('artifacts/native-clipboard-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $fixture=Join-Path $PSScriptRoot 'testdata/minimal.gp'
    $fixtureHash=(Get-FileHash -LiteralPath $fixture).Hash
    $sourcePath=Join-Path $run 'source.gp';$targetPath=Join-Path $run 'target.gp'
    Copy-Item -LiteralPath $fixture -Destination $sourcePath
    Copy-Item -LiteralPath $fixture -Destination $targetPath
    $source=Open-Score $sourcePath;$target=Open-Score $targetPath
    Clip @{operation='clear'} | Out-Null
    Assert (-not (Clip).available) 'Clipboard clear failed'
    Reject @{operation='paste';document=$target;id='missing'}
    Select-Range $source (Point 0 1) (Point 0 0)
    Tool gp_edit_note_effect @{document=$source;property='palm_mute';string=0;value=$true} | Out-Null
    $sourceBars=Bars $source
    Tool gp_activate @{document=$target} | Out-Null
    $sourceState=Json (Tool gp_score @{document=$source})
    $copy=Clip @{operation='copy';document=$source}
    Assert ($copy.available -and $copy.beat_count -eq 2 -and $copy.bar_count -eq 1 -and -not $copy.multi_track) 'Native clipboard range metadata differs'
    Assert ((Json (Tool gp_score @{document=$source})) -eq $sourceState -and (Tool gp_documents).active_document -eq $target) 'Copy changed source state or active document'
    $copied=(Clip @{operation='read';id=$copy.id}).bars
    Assert ((Json (Musical $copied[0].voices[0].beats)) -eq (Json (Musical $sourceBars[0].voices[0].beats[0..1]))) 'Copied snapshot lost notes, rhythm or techniques'
    foreach($arguments in @(
        @{operation='paste';document=$target},@{operation='paste';document=$target;id='stale'},
        @{operation='read';id='stale'},@{operation='paste';document=$target;id=$copy.id;scope='invalid'},
        @{operation='copy';document=$target},@{operation='state';document=$target},@{operation='read';id=$copy.id;count=17}
    )){Reject $arguments}
    Tool gp_set_fret @{document=$source;string=0;fret=9} | Out-Null
    Assert ((Json (Clip @{operation='read';id=$copy.id}).bars) -eq (Json $copied)) 'Native snapshot aliases source edits'
    Tool gp_save_as @{document=$source;path=(Join-Path $run 'source-modified.gp')} | Out-Null
    Close-Score $source
    Assert ((Json (Clip @{operation='read';id=$copy.id}).bars) -eq (Json $copied)) 'Snapshot became unavailable after source closed'
    Select-Range $target (Point 0 2) (Point 0 2)
    Tool gp_selection @{document=$target;operation='clear'} | Out-Null
    $before=Bars $target
    $paste=Clip @{operation='paste';document=$target;id=$copy.id}
    $after=Bars $target
    Assert ($paste.native_method -eq 'Score::pasteBeatRange' -and $paste.global_bar_delta -eq 0 -and $paste.dirty -and $paste.undo_available) 'Paste did not use native beat command'
    Assert ($after[0].voices[0].beats.Count -eq 6) 'Cursor paste did not insert two beats'
    Assert ((Json (Musical $after[0].voices[0].beats[2..3])) -eq (Json (Musical $copied[0].voices[0].beats))) 'Pasted fragment differs from independent snapshot'
    Assert ((Json (Musical $after[0].voices[0].beats[0..1])) -eq (Json (Musical $before[0].voices[0].beats[0..1])) -and (Json (Musical $after[0].voices[0].beats[4..5])) -eq (Json (Musical $before[0].voices[0].beats[2..3])) -and (Json $after[1]) -eq (Json $before[1])) 'Cursor paste changed surrounding content'
    Undo $target
    Assert ((Json (Bars $target)) -eq (Json $before)) 'Paste undo differs'
    Redo $target
    Assert ((Json (Bars $target)) -eq (Json $after)) 'Paste redo differs'
    $saved=Tool gp_save @{document=$target;path=(Join-Path $run 'pasted.gp')}
    $reloaded=Open-Score $saved.path
    Assert ((Json (Bars $reloaded)) -eq (Json $after)) 'Pasted score did not survive native save/open'
    Close-Score $reloaded
    Undo $target
    Select-Range $target (Point 0 1) (Point 0 2)
    Clip @{operation='paste';document=$target;id=$copy.id;scope='selection'} | Out-Null
    $replaced=Bars $target
    Assert ($replaced[0].voices[0].beats.Count -eq 4 -and (Json (Musical $replaced[0].voices[0].beats[1..2])) -eq (Json (Musical $copied[0].voices[0].beats))) 'Selection replacement differs'
    Assert ((Json $replaced[0].voices[0].beats[0]) -eq (Json $before[0].voices[0].beats[0]) -and (Json $replaced[0].voices[0].beats[3]) -eq (Json $before[0].voices[0].beats[3])) 'Selection replacement escaped target range'
    Undo $target
    Assert ((Json (Bars $target)) -eq (Json $before)) 'Replacement undo differs'
    Select-Range $target (Point 0 2) (Point 0 1)
    $cut=Clip @{operation='cut';document=$target}
    $cutBars=Bars $target
    Assert ($cut.id -ne $copy.id -and $cut.beat_count -eq 2 -and $cutBars[0].voices[0].beats.Count -eq 2) 'Native cut did not remove selected beats'
    Assert ((Json (Musical $cutBars[0].voices[0].beats)) -eq (Json (Musical @($before[0].voices[0].beats[0],$before[0].voices[0].beats[3])))) 'Cut changed retained beats'
    Reject @{operation='paste';document=$target;id=$copy.id}
    Undo $target
    Assert ((Json (Bars $target)) -eq (Json $before)) 'Cut undo differs'
    Redo $target
    Assert ((Json (Bars $target)) -eq (Json $cutBars)) 'Cut redo differs'
    Undo $target
    Tool gp_edit_tracks @{document=$target;operation='duplicate';track=0} | Out-Null
    Select-Range $target (Point 0 0) (Point 0 0)
    Tool gp_cursor @{document=$target;axis='voice';index=1} | Out-Null
    Tool gp_edit_note @{document=$target;operation='set';string=0;fret=7} | Out-Null
    Select-Range $target (Point 0 0) (Point 0 1) $true
    $multiSource=@((Bars $target),(Bars $target 1))
    $voices=Clip @{operation='copy';document=$target}
    Assert ($voices.multi_voice -and -not $voices.multi_track -and $voices.beat_count -eq 3) 'Multi-voice copy metadata differs'
    $voiceData=(Clip @{operation='read';id=$voices.id}).bars[0]
    Assert ((Json (Musical $voiceData.voices[0].beats)) -eq (Json (Musical $multiSource[0][0].voices[0].beats[0..1])) -and
        $voiceData.voices[1].beats.Count -eq 2 -and (Json $voiceData.voices[1].beats[0]) -eq (Json $multiSource[0][0].voices[1].beats[0])) 'Multi-voice snapshot changed selected notes'
    # Native serialization pads the shorter voice to the selected musical duration.
    $padding=$voiceData.voices[1].beats[1]
    Assert ($padding.rest -and -not $padding.placeholder -and $padding.notes.Count -eq 0 -and $padding.rhythm -eq 'Quarter;Dots=0;PriTuplet=0/0;SecTuplet=0/0') 'Multi-voice snapshot padding differs'
    $secondPath=Join-Path $run 'second-target.gp'
    Copy-Item -LiteralPath $fixture -Destination $secondPath
    $second=Open-Score $secondPath
    Tool gp_edit_tracks @{document=$second;operation='duplicate';track=0} | Out-Null
    Select-Range $second (Point 0 0) (Point 0 0)
    Tool gp_selection @{document=$second;operation='clear'} | Out-Null
    $secondBefore=@((Bars $second),(Bars $second 1))
    Reject @{operation='paste';document=$second;id=$voices.id}
    Select-Range $second (Point 0 0) (Point 0 0) $true
    Clip @{operation='paste';document=$second;id=$voices.id} | Out-Null
    $secondAfter=Bars $second
    Assert ($secondAfter[0].voices[0].beats.Count -eq 6) 'Multi-voice paste did not insert the first voice'
    Assert ((Json (Musical $secondAfter[0].voices[0].beats[0..1])) -eq (Json (Musical $voiceData.voices[0].beats))) 'Multi-voice paste changed first-voice content'
    Assert ((Json (Musical @($secondAfter[0].voices[1].beats | Where-Object {-not $_.placeholder}))) -eq (Json (Musical @($voiceData.voices[1].beats | Where-Object {-not $_.placeholder})))) 'Multi-voice paste lost second-voice content'
    Assert ((Json (Bars $second 1)) -eq (Json $secondBefore[1]) -and (Json $secondAfter[1]) -eq (Json $secondBefore[0][1])) 'Multi-voice paste changed another track or bar'
    Undo $second
    Assert ((Json (Bars $second)) -eq (Json $secondBefore[0])) 'Multi-voice paste undo differs'
    Redo $second
    Assert ((Json (Bars $second)) -eq (Json $secondAfter)) 'Multi-voice paste redo differs'
    Undo $second
    Select-Range $target (Point 0 0) (Point 0 1) $true
    $cutBefore=Bars $target
    Assert ((Json $cutBefore) -eq (Json $multiSource[0])) 'Copy and document switching changed source content'
    Clip @{operation='cut';document=$target} | Out-Null
    $voiceCut=Bars $target
    Assert ($voiceCut[0].voices[0].beats.Count -eq 2 -and @($voiceCut[0].voices[1].beats | Where-Object {-not $_.placeholder}).Count -eq 0) 'Multi-voice cut left selected beats'
    Assert ((Json (Bars $target 1)) -eq (Json $multiSource[1])) 'Multi-voice cut changed another track'
    Undo $target
    Assert ((Json (Bars $target)) -eq (Json $multiSource[0])) 'Multi-voice cut undo differs'
    Redo $target
    Assert ((Json (Bars $target)) -eq (Json $voiceCut)) 'Multi-voice cut redo differs'
    Undo $target
    Select-Range $target (Point 0 3) (Point 0 1) $true $true
    $tracks=Clip @{operation='copy';document=$target}
    Assert ($tracks.multi_track -and $tracks.track_count -eq 2 -and $tracks.bar_count -eq 1 -and $tracks.beat_count -eq 9) 'Multi-track copy metadata differs'
    $incompatiblePath=Join-Path $run 'incompatible.gp'
    Copy-Item -LiteralPath $fixture -Destination $incompatiblePath
    $incompatible=Open-Score $incompatiblePath
    Reject @{operation='paste';document=$incompatible;id=$tracks.id}
    Close-Score $incompatible
    $trackData=@((Clip @{operation='read';id=$tracks.id;track=0}).bars[0],(Clip @{operation='read';id=$tracks.id;track=1}).bars[0])
    Select-Range $second (Point 1 0) (Point 1 0)
    Tool gp_selection @{document=$second;operation='clear'} | Out-Null
    $trackPaste=Clip @{operation='paste';document=$second;id=$tracks.id}
    Assert ($trackPaste.native_method -eq 'Score::pasteBarRange' -and $trackPaste.global_bar_delta -eq 1 -and $trackPaste.previous_bar_count -eq 2 -and $trackPaste.tracks[0].bars -eq 3 -and $trackPaste.tracks[1].bars -eq 3) 'Multi-track paste did not insert a global bar'
    for($t=0;$t -lt 2;$t++) {
        $actual=Bars $second $t 0 3
        Assert ((Json $actual[1].voices) -eq (Json $trackData[$t].voices)) 'Multi-track paste differs from copied bar'
        Assert ((Json $actual[0]) -eq (Json $secondBefore[$t][0])) 'Multi-track paste changed a preceding bar'
        Assert ((Json $actual[2].voices) -eq (Json $secondBefore[$t][1].voices)) 'Multi-track paste changed shifted trailing content'
    }
    $trackAfter=@((Bars $second 0 0 3),(Bars $second 1 0 3))
    Undo $second
    Assert ((Json @((Bars $second),(Bars $second 1))) -eq (Json $secondBefore)) 'Multi-track paste single undo differs'
    Redo $second
    Assert ((Json @((Bars $second 0 0 3),(Bars $second 1 0 3))) -eq (Json $trackAfter)) 'Multi-track paste redo differs'
    $savedTracks=Tool gp_save @{document=$second;path=(Join-Path $run 'pasted-tracks.gp')}
    $reloaded=Open-Score $savedTracks.path
    Assert ((Json @((Bars $reloaded 0 0 3),(Bars $reloaded 1 0 3))) -eq (Json $trackAfter)) 'Multi-track paste did not survive native save/open'
    Close-Score $reloaded
    Undo $second
    Select-Range $target (Point 0 0) (Point 0 0) $true $true
    Clip @{operation='cut';document=$target} | Out-Null
    foreach($t in 0,1) {
        $remaining=(Tool gp_read_bars @{document=$target;track=$t}).bars
        Assert ((Tool gp_score @{document=$target}).tracks[$t].bars -eq 1 -and (Json $remaining[0].voices) -eq (Json $multiSource[$t][1].voices)) 'Multi-track cut did not remove the selected global bar'
    }
    Undo $target
    Assert ((Json @((Bars $target),(Bars $target 1))) -eq (Json $multiSource)) 'Multi-track cut undo differs'
    Select-Range $target (Point 1 1 1) (Point 0 2 1)
    $multiBar=Clip @{operation='copy';document=$target}
    Assert (-not $multiBar.multi_track -and $multiBar.bar_count -eq 2 -and $multiBar.beat_count -eq 4) 'Partial multi-bar snapshot metadata differs'
    $barData=(Clip @{operation='read';id=$multiBar.id;count=2}).bars
    Select-Range $second (Point 0 0) (Point 0 0)
    Tool gp_selection @{document=$second;operation='clear'} | Out-Null
    $barPaste=Clip @{operation='paste';document=$second;id=$multiBar.id}
    Assert ($barPaste.native_method -eq 'Score::pasteBarRange' -and $barPaste.global_bar_delta -eq 2) 'Multi-bar paste used a different native dispatch'
    $barAfter=Bars $second
    $expectedBars=(Json @{items=$barData} | ConvertFrom-Json).items
    $emptyEffects=[ordered]@{arpeggio='None';bar_vibrato='None';bass_attack='None';brush='None';dead_slap=$false;fade='None';golpe='None';grace='None';hairpin='NoHairpin';ottavia='None';pick_stroke='None';rasgueado='None';tremolo=0;whammy=[ordered]@{enabled=$false}}
    $expectedBars[1].voices[0].beats += [pscustomobject][ordered]@{dots=0;effects=$emptyEffects;index=2;legato=[ordered]@{destination=$false;origin=$false};native_note_value=4;notes=@();placeholder=$true;rest=$true;rhythm='Quarter;Dots=0;PriTuplet=0/0;SecTuplet=0/0';tuplets=[ordered]@{primary=[ordered]@{actual=0;enabled=$false;normal=0};secondary=[ordered]@{actual=0;enabled=$false;normal=0}}}
    Assert ((Json $barAfter) -eq (Json $expectedBars)) 'Partial multi-bar paste differs beyond its trailing cursor placeholder'
    foreach($t in 0,1){
        Assert ($barPaste.tracks[$t].bars -eq 4) 'Multi-bar paste did not insert two global bars'
        $actual=Bars $second $t 0 4
        foreach($b in 0,1){Assert ((Json $actual[$b+2].voices) -eq (Json $secondBefore[$t][$b].voices)) 'Multi-bar paste changed shifted original content'}
        if($t -eq 1){foreach($b in 0,1){Assert (@($actual[$b].voices | ForEach-Object {$_.beats}).Count -eq 0) 'Single-track paste inserted content into another track'}}
    }
    Undo $second
    Assert ((Json (Bars $second)) -eq (Json $secondBefore[0])) 'Multi-bar paste undo differs'
    Select-Range $target (Point 0 0) (Point 0 1)
    $fragment=Clip @{operation='copy';document=$target}
    $fragmentData=(Clip @{operation='read';id=$fragment.id}).bars[0].voices[0].beats
    $empty=New-Score 'Nylon Guitar'
    $emptyBefore=Bars $empty 0 0 1
    Clip @{operation='paste';document=$empty;id=$fragment.id} | Out-Null
    $emptyAfter=Bars $empty 0 0 1
    Assert ((Json (Musical $emptyAfter[0].voices[0].beats[0..1])) -eq (Json (Musical $fragmentData))) 'Paste into a placeholder lost notes'
    Assert ($emptyAfter[0].voices[0].beats.Count -eq 3 -and $emptyAfter[0].voices[0].beats[2].placeholder -and $emptyAfter[0].voices[0].beats[2].notes.Count -eq 0) 'Empty-target paste produced unexpected trailing content'
    Undo $empty
    Assert ((Json (Bars $empty 0 0 1)) -eq (Json $emptyBefore)) 'Empty-target paste undo differs'
    Tool gp_save_as @{document=$empty;path=(Join-Path $run 'empty-restored.gp')} | Out-Null
    Close-Score $empty
    $piano=New-Score 'Acoustic Piano'
    Tool gp_edit_beat @{document=$piano;operation='insert';denominator=8} | Out-Null
    Tool gp_cursor @{document=$piano;axis='staff';index=1} | Out-Null
    Tool gp_edit_beat @{document=$piano;operation='insert';denominator=4} | Out-Null
    Tool gp_edit_beat @{document=$piano;operation='insert';denominator=2} | Out-Null
    Select-Range $piano (Point 0 0 0 0 1) (Point 0 1 0 0 1)
    $pianoBefore=@((Bars $piano 0 0 1),(Bars $piano 0 1 1))
    $pianoClip=Clip @{operation='copy';document=$piano}
    $pianoSnapshot=(Clip @{operation='read';id=$pianoClip.id;staff=1}).bars
    Assert ((Json $pianoSnapshot) -eq (Json $pianoBefore[1]) -and $pianoClip.beat_count -eq 2 -and $pianoClip.tracks[0].staves -eq 2) 'Piano snapshot lost lower-staff rhythm'
    Assert ((Json @((Bars $piano 0 0 1),(Bars $piano 0 1 1))) -eq (Json $pianoBefore)) 'Piano copy changed source staves'
    Clip @{operation='paste';document=$piano;id=$pianoClip.id} | Out-Null
    $pianoAfter=@((Bars $piano 0 0 1),(Bars $piano 0 1 1))
    Assert ((Json $pianoAfter[0]) -eq (Json $pianoBefore[0])) 'Piano lower-staff paste changed upper staff'
    Assert ($pianoAfter[1][0].voices[0].beats.Count -eq 4 -and (Json (Musical $pianoAfter[1][0].voices[0].beats[1..2])) -eq (Json (Musical $pianoSnapshot[0].voices[0].beats))) 'Piano lower-staff paste changed copied content'
    Assert ((Json (Musical @($pianoAfter[1][0].voices[0].beats[0],$pianoAfter[1][0].voices[0].beats[3]))) -eq (Json (Musical $pianoBefore[1][0].voices[0].beats))) 'Piano paste changed retained beats'
    Undo $piano
    Assert ((Json @((Bars $piano 0 0 1),(Bars $piano 0 1 1))) -eq (Json $pianoBefore)) 'Piano paste undo differs'
    Redo $piano
    Assert ((Json @((Bars $piano 0 0 1),(Bars $piano 0 1 1))) -eq (Json $pianoAfter)) 'Piano paste redo differs'
    $pianoSaved=Tool gp_save @{document=$piano;path=(Join-Path $run 'pasted-piano.gp')}
    $reloaded=Open-Score $pianoSaved.path
    Assert ((Json @((Bars $reloaded 0 0 1),(Bars $reloaded 0 1 1))) -eq (Json $pianoAfter)) 'Piano paste did not survive native save/open'
    Close-Score $reloaded
    Undo $piano
    Select-Range $piano (Point 0 0 0 0 1) (Point 0 1 0 0 1)
    Clip @{operation='cut';document=$piano} | Out-Null
    Assert ((Json (Bars $piano 0 0 1)) -eq (Json $pianoBefore[0])) 'Piano lower-staff cut changed upper staff'
    Assert (@((Bars $piano 0 1 1)[0].voices[0].beats | Where-Object {-not $_.placeholder}).Count -eq 0) 'Piano cut retained selected beats'
    Undo $piano
    Assert ((Json @((Bars $piano 0 0 1),(Bars $piano 0 1 1))) -eq (Json $pianoBefore)) 'Piano cut undo differs'
    Tool gp_save_as @{document=$piano;path=(Join-Path $run 'piano-restored.gp')} | Out-Null
    Close-Score $piano
    Tool gp_save_as @{document=$second;path=(Join-Path $run 'second-restored.gp')} | Out-Null
    Close-Score $second
    Clip @{operation='clear'} | Out-Null
    Assert (-not (Clip).available) 'Native snapshot did not release'
    Tool gp_save_as @{document=$target;path=(Join-Path $run 'restored.gp')} | Out-Null
    Close-Score $target
    Assert ((Json ((Tool gp_documents).documents | Select-Object id,save_path,dirty)) -eq (Json ($others | Select-Object id,save_path,dirty))) 'Clipboard checks changed other documents'
    $afterIdentity=Tool gp_capabilities
    Assert ($afterIdentity.pid -eq $identity.pid -and $afterIdentity.hidden_mode -and $afterIdentity.foreground_pid -ne $afterIdentity.pid) 'Clipboard commands activated or restarted the host'
    Assert ((Get-FileHash -LiteralPath $fixture).Hash -eq $fixtureHash) 'Fixture changed'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;copy=$copy;cut=$cut;paste=$paste;saved=$saved.path;voices=$voices;tracks=$tracks;multi_bar=$multiBar;saved_tracks=$savedTracks.path;multi_bar_after=$barAfter;voice_snapshot=$voiceData;piano_snapshot=$pianoSnapshot;saved_piano=$pianoSaved.path} | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native clipboard checks. Evidence: $run"
}catch{
    $failure=$_
    try {if($run){$state=Clip;@{checks=$checks;error=$failure.ToString();documents=(Tool gp_documents);clipboard=$state;snapshot=$(if($state.available){Clip @{operation='read';id=$state.id}})} | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath (Join-Path $run 'failure.json')}}catch{}
    Write-Output "Failed after $checks checks; last passed assertion: $lastCheck"
    throw $failure
}finally{Close-McpSession $connection}
