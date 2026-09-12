param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json", [switch]$Render)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-audio-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$checks = 0; $complete = $false; $evidence = @(); $owned = @(); $id = ''; $deviceBefore = $null; $playbackBefore = $null
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 30 -Compress }
function Call([string]$tool, [hashtable]$arguments = @{}, [switch]$AllowError) {
    $arguments = $arguments.Clone()
    if ($script:id) { $arguments.document = $script:id }
    try { Invoke-McpTool $connection $tool $arguments -AllowError:$AllowError }
    catch { if ($AllowError -and $_.Exception.Message -match '-32602') { return @{error=$_.Exception.Message} }; throw }
}
function Wait-Operation($request, $expected) {
    $until = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if ($state.status -in @($expected,'error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $until)
    Assert ($state.status -eq $expected) "Operation failed: $(Json $state)"
    $state
}
function Wait-Playback([scriptblock]$condition) {
    $until = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $state = Call gp_playback @{} -AllowError
        if (-not $state.error -and (& $condition $state)) { return $state }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $until)
    throw "Playback did not settle: $(Json $state)"
}
function Cycle([string]$name, [scriptblock]$change, [scriptblock]$read, [scriptblock]$verify) {
    $before = & $read
    & $change | Out-Null
    $after = & $read
    & $verify $after
    Call gp_undo_redo @{operation='undo'} | Out-Null
    Assert ((Json (& $read)) -eq (Json $before)) "$name undo differs"
    Call gp_undo_redo @{operation='redo'} | Out-Null
    Assert ((Json (& $read)) -eq (Json $after)) "$name redo differs"
    Call gp_undo_redo @{operation='undo'} | Out-Null
}
function Measure-Audio([string]$name) {
    $sample = Call gp_audio_probe
    Assert ($sample.frames -eq $sample.expected_frames -and $sample.frames -gt 0) "$name PCM length differs"
    $script:evidence += @{name=$name;pcm=$sample}
    $sample
}
function Edit-Measure([int]$bar, [string]$property, [hashtable]$values) {
    Call gp_cursor @{axis='bar';index=$bar} | Out-Null
    $values = $values.Clone(); $values.operation = $property
    Call gp_edit_measure $values | Out-Null
}
try {
    $others = (Invoke-McpTool $connection gp_documents).documents | Select-Object id,dirty,opened_path
    foreach ($name in @('audio','other')) {
        $path = Join-Path $run "$name.gp"
        Copy-Item "$PSScriptRoot/testdata/minimal.gp" $path
        if ($name -eq 'audio') {
            $archive=[IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Update)
            try {
                $entry=$archive.GetEntry('Content/score.gpif'); $reader=[IO.StreamReader]::new($entry.Open())
                try { [xml]$fixture=$reader.ReadToEnd() } finally {$reader.Dispose()}
                $fixture.GPIF.Tracks.Track.AudioEngineState='RSE'
                $entry.Delete(); $writer=[IO.StreamWriter]::new($archive.CreateEntry('Content/score.gpif').Open(), [Text.UTF8Encoding]::new($false))
                try {$writer.Write($fixture.OuterXml)} finally {$writer.Dispose()}
            } finally {$archive.Dispose()}
        }
        $opened = Invoke-McpTool $connection gp_open @{path=$path}
        $owned += (Wait-Operation $opened.request 'opened').document
    }
    $id = $owned[0]
    $template = Invoke-McpTool $connection gp_new @{template='Steel Guitar'}
    $guitar = (Wait-Operation $template.request 'created').document; $owned += $guitar
    Invoke-McpTool $connection gp_activate @{document=$id} | Out-Null
    Call gp_audio_track @{track=0;operation='copy';source_document=$guitar;source_track=0} | Out-Null
    $playbackBefore=Call gp_playback
    foreach ($operation in @('set_loop','set_metronome','set_countdown')) { Call gp_playback @{operation=$operation;enabled=$false} | Out-Null }
    $deviceBefore = Invoke-McpTool $connection gp_audio_device
    Assert ($deviceBefore.scope -eq 'application' -and $deviceBefore.choices.audioOutput.Count -gt 0) 'Native output devices unavailable'
    Assert ((Invoke-McpTool $connection gp_audio_device @{operation='set';property='audioOutput';value='gpmcp-nonexistent-output'} -AllowError).error) 'Unknown audio device accepted'
    Assert ((Json (Invoke-McpTool $connection gp_audio_device).configuration) -eq (Json $deviceBefore.configuration)) 'Invalid device changed settings'
    foreach ($property in @('audioBuffersSize','audioOutput')) {
        # ASIO drivers commonly expose the host buffer choices but reject a
        # live buffer-size change; exercise the writable path on Standard and
        # leave the driver-owned ASIO setting untouched.
        if ($property -eq 'audioBuffersSize' -and $deviceBefore.configuration.audioDevice -eq 'ASIO') { continue }
        $alternative = @($deviceBefore.choices.$property | Where-Object { $_ -ne $deviceBefore.configuration.$property } | Select-Object -First 1)
        if ($alternative.Count) {
            $changed = Invoke-McpTool $connection gp_audio_device @{operation='set';property=$property;value=$alternative[0]}
            Assert ($changed.configuration.$property -eq $alternative[0] -and $changed.running) 'Native device change failed'
            $restored = Invoke-McpTool $connection gp_audio_device @{operation='set';property=$property;value=$deviceBefore.configuration.$property}
            Assert ($restored.configuration.$property -eq $deviceBefore.configuration.$property) 'Native device restore failed'
        }
    }
    $tempoRead = { (Call gp_tempo).points }
    Cycle 'tempo-point' { Call gp_tempo @{operation='set';bar=1;position=0.5;value=180;label='P5'} } $tempoRead {
        param($points) Assert ($points.Count -eq 2 -and $points[1].bar -eq 1 -and $points[1].position -eq 0.5 -and $points[1].value -eq 180) 'Tempo point differs'
    }
    foreach ($bad in @(@{bar=2;value=90},@{bar=1;position=1;value=90},@{bar=1;value=90.5},@{bar=1;value=401},@{bar=1;value=90;unit='bad'})) {
        $before = Json (& $tempoRead); $bad.operation='set'
        Assert ((Call gp_tempo $bad -AllowError).error) 'Invalid tempo accepted'
        Assert ((Json (& $tempoRead)) -eq $before) 'Invalid tempo changed score'
    }
    Assert ((Call gp_tempo @{operation='remove';bar=0} -AllowError).error) 'Initial tempo removed'
    Call gp_tempo @{operation='set';bar=1;value=180;linear=$false} | Out-Null
    $timed = Wait-Playback {param($s) [Math]::Abs($s.total_frames - 176400) -le 2}
    $timeline = Call gp_playback @{operation='timeline'}
    Assert ($timeline.count -eq 2 -and [Math]::Abs($timeline.bars[1].frames - 58800) -le 2) 'Stopped tempo frame update failed'
    $seek = Call gp_playback @{operation='seek_tick';tick=2880}
    Assert ([Math]::Abs($seek.frame - 147000) -le 2) 'Tempo-aware seek differs'
    if ($Render) {
        $step = Measure-Audio 'step-tempo'
        Assert ([Math]::Abs($step.frames - 176400) -le 2) 'Rendered tempo duration differs'
    }
    Cycle 'remove-tempo' { Call gp_tempo @{operation='remove';bar=1} } $tempoRead {param($p) Assert ($p.Count -eq 1) 'Tempo removal failed'}
    Call gp_tempo @{operation='set';bar=0;value=90;linear=$true} | Out-Null
    $ramp = Wait-Playback {param($s) $s.total_frames -lt 176390 -and $s.total_frames -gt 117600}
    $evidence += @{name='linear-tempo';playback=$ramp;points=(& $tempoRead)}
    if ($Render) { $rampPcm=Measure-Audio 'linear-tempo'; Assert ([Math]::Abs($rampPcm.frames-$ramp.total_frames) -le 2) 'Rendered ramp duration differs' }
    Call gp_tempo @{operation='set';bar=0;value=90;linear=$false} | Out-Null
    Call gp_tempo @{operation='remove';bar=1} | Out-Null
    Wait-Playback {param($s) $s.total_frames -eq 235200} | Out-Null
    $soundRead = { (Call gp_audio_track @{track=0}).sounds }
    $originalSounds = & $soundRead
    $forced=Call gp_audio_track @{track=0;operation='select';sound=0}
    Assert ($forced.forced_sound -eq 0 -and -not $forced.undoable) 'Sound selection differs'
    Assert ((Call gp_audio_track @{track=0;operation='select';sound=-1}).forced_sound -eq -1) 'Automatic sound selection did not restore'
    Cycle 'effect-bypass' {Call gp_audio_track @{track=0;operation='effect_bypass';effect=0;enabled=$true}} $soundRead {param($s) Assert ($s[0].effects[0].bypass) 'Effect bypass differs'}
    Cycle 'effect-parameter' {Call gp_audio_track @{track=0;operation='effect_parameter';effect=0;parameter=0;value=0.7}} $soundRead {param($s) Assert ([Math]::Abs($s[0].effects[0].parameters[0]-0.7)-lt 0.0001) 'Effect parameter differs'}
    Cycle 'effect-order' {Call gp_audio_track @{track=0;operation='effect_swap';effect=0;other=2}} $soundRead {param($s) Assert ($s[0].effects[0].id -eq $originalSounds[0].effects[2].id) 'Effect order differs'}
    Cycle 'effect-remove' {Call gp_audio_track @{track=0;operation='effect_remove';effect=0}} $soundRead {param($s) Assert ($s[0].effects.Count -eq 2) 'Effect removal differs'}
    Cycle 'midi-program' {Call gp_audio_track @{track=0;operation='midi_program';value=10}} $soundRead {param($s) Assert ($s[0].midi_program -eq 10) 'MIDI program differs'}
    foreach ($bad in @(@{operation='effect_parameter';effect=0;parameter=100;value=0.5},@{operation='effect_parameter';effect=0;parameter=0;value=2},@{operation='effect_swap';effect=0;other=99},@{operation='select';sound=99})) {
        $bad.track=0
        Assert ((Call gp_audio_track $bad -AllowError).error) 'Invalid audio request accepted'
        Assert ((Json (& $soundRead)) -eq (Json $originalSounds)) 'Invalid audio request changed sound'
    }
    if ($Render) {
        $baseline = Measure-Audio 'baseline'
        Assert ($baseline.peak -gt 0.001 -and $baseline.left_rms -gt 0.0001) 'Rendered fixture is silent'
        Call gp_edit_track @{track=0;property='volume';value=0} | Out-Null
        $silent = Measure-Audio 'zero-volume'
        Assert ($silent.left_rms -lt $baseline.left_rms * 0.01) 'Zero volume did not silence audio'
        Call gp_undo_redo @{operation='undo'} | Out-Null
        Call gp_edit_track @{track=0;property='pan';value=0} | Out-Null
        $panned = Measure-Audio 'left-pan'
        Assert ($panned.left_rms -gt $panned.right_rms * 2) 'Pan did not affect stereo output'
        Call gp_undo_redo @{operation='undo'} | Out-Null
        Call gp_audio_track @{track=0;operation='effect_parameter';effect=2;parameter=4;value=1} | Out-Null
        $effect = Measure-Audio 'reverb'
        Assert ($effect.pcm_sha256 -ne $baseline.pcm_sha256 -and [Math]::Abs($effect.left_rms-$baseline.left_rms) -gt 0.00001) 'Effect did not change rendered sound'
        Call gp_undo_redo @{operation='undo'} | Out-Null
        $created=Invoke-McpTool $connection gp_new @{template='Acoustic Piano'}
        $piano=(Wait-Operation $created.request 'created').document; $owned += $piano
        Call gp_audio_track @{track=0;operation='copy';source_document=$piano;source_track=0} | Out-Null
        $pianoSound=Measure-Audio 'piano-sound'
        Assert ($pianoSound.peak -gt 0.001 -and [Math]::Abs($pianoSound.left_rms-$baseline.left_rms) -gt 0.001) 'Sound replacement did not change PCM'
        Call gp_undo_redo @{operation='undo'} | Out-Null
        Assert ((Json (& $soundRead)) -eq (Json $originalSounds)) 'Sound replacement undo differs'
    }
    Edit-Measure 0 repeat_start @{enabled=$true}
    Edit-Measure 1 repeat_end @{enabled=$true;repeat_count=3}
    Wait-Playback {param($s) $s.total_ticks -eq 11520} | Out-Null
    $timeline=Call gp_playback @{operation='timeline'}
    Assert (($timeline.bars.bar -join ',') -eq '0,1,0,1,0,1') 'Repeat unfolding differs'
    $page=Call gp_playback @{operation='timeline';offset=2;limit=2}
    Assert ($page.bars.Count -eq 2 -and $page.bars[0].start_tick -eq 3840 -and $page.next_offset -eq 4) 'Timeline pagination differs'
    foreach ($entry in $timeline.bars) {
        $seek=Call gp_playback @{operation='seek_tick';tick=$entry.start_tick}
        Assert ($seek.tick -eq $entry.start_tick) 'Repeated occurrence seek differs'
    }
    if ($Render) { $repeat=Measure-Audio 'repeat'; Assert ($repeat.frames -eq 705600) 'Rendered repeats differ' }
    Edit-Measure 0 repeat_start @{enabled=$false}
    Edit-Measure 1 repeat_end @{enabled=$false}
    Call gp_edit_bars @{operation='insert';index=2;count=2} | Out-Null
    Edit-Measure 0 repeat_start @{enabled=$true}
    Edit-Measure 1 repeat_end @{enabled=$true;repeat_count=2}
    Edit-Measure 1 alternate_endings @{endings=@(1)}
    Edit-Measure 2 alternate_endings @{endings=@(2)}
    Wait-Playback {param($s) $s.total_ticks -eq 9600} | Out-Null
    $endings=Call gp_playback @{operation='timeline'}
    Assert (($endings.bars.bar -join ',') -eq '0,1,0,2,3') 'Alternate ending unfolding differs'
    $evidence += @{name='alternate-endings';timeline=$endings}
    foreach ($bar in @(1,2)) { Edit-Measure $bar alternate_endings @{endings=@()} }
    Edit-Measure 0 repeat_start @{enabled=$false}
    Edit-Measure 1 repeat_end @{enabled=$false}
    Edit-Measure 1 direction @{direction=4;enabled=$true}
    Edit-Measure 3 direction @{direction=8;enabled=$true}
    Wait-Playback {param($s) $s.total_ticks -eq 11520} | Out-Null
    $jump=Call gp_playback @{operation='timeline'}
    Assert (($jump.bars.bar -join ',') -eq '0,1,2,3,0,1') 'D.C. al Fine unfolding differs'
    $evidence += @{name='directions';master=(Call gp_read_master_bars).bars}
    $base=@{track=0;staff=0;voice=0;bar=0;beat=1}; $extent=@{track=0;staff=0;voice=0;bar=0;beat=2}
    $loop=Call gp_playback @{operation='set_loop_range';base=$base;extent=$extent}
    Assert ($loop.range.loop_start_tick -eq 480 -and $loop.range.loop_end_tick -eq 1440) 'Loop endpoints differ'
    Call gp_playback @{operation='play'} | Out-Null
    Wait-Playback {param($s) $s.playing} | Out-Null
    Assert ((Call gp_playback @{operation='set_loop_range';base=$base;extent=$extent} -AllowError).error) 'Playing loop range was changed'
    Assert ((Invoke-McpTool $connection gp_audio_device @{operation='set';property='audioBuffersSize';value=$deviceBefore.configuration.audioBuffersSize} -AllowError).error) 'Device change accepted during playback'
    $wrapped=$false; $previous=480; $samples=@(); $until=[DateTime]::UtcNow.AddSeconds(4)
    do {
        Start-Sleep -Milliseconds 75
        $state=Call gp_playback; $samples += $state.tick
        if ($state.tick -lt $previous) { $wrapped=$true }; $previous=$state.tick
    } while (-not $wrapped -and [DateTime]::UtcNow -lt $until)
    Assert ($wrapped) 'Loop did not wrap'
    $evidence += @{name='loop';ticks=$samples}
    Call gp_playback @{operation='stop'} | Out-Null
    Wait-Playback {param($s) -not $s.playing} | Out-Null
    Call gp_playback @{operation='clear_loop_range'} | Out-Null
    foreach ($round in 1..3) {
        Call gp_playback @{operation='play'} | Out-Null
        Call gp_playback @{operation='stop'} | Out-Null
        Wait-Playback {param($s) -not $s.playing} | Out-Null
        Start-Sleep -Milliseconds 150
        Assert (-not (Call gp_playback).playing) 'Stopped pending playback started later'
    }
    Call gp_playback @{operation='play'} | Out-Null
    Invoke-McpTool $connection gp_activate @{document=$owned[1]} | Out-Null
    Start-Sleep -Milliseconds 200
    $otherPlayback=Invoke-McpTool $connection gp_playback @{document=$owned[1]}
    Assert (-not $otherPlayback.playing) 'Pending play started in the other document'
    Invoke-McpTool $connection gp_activate @{document=$id} | Out-Null
    Call gp_playback @{operation='stop'} | Out-Null
    Wait-Playback {param($s) -not $s.playing} | Out-Null
    Call gp_tempo @{operation='set';bar=1;position=0.5;value=150;linear=$true;label='P5'} | Out-Null
    Call gp_audio_track @{track=0;operation='effect_bypass';effect=0;enabled=$true} | Out-Null
    $expectedTempo=Json (& $tempoRead); $expectedSound=Json (& $soundRead)
    $saved=Join-Path $run 'persisted.gp'
    Call gp_save_as @{path=$saved} | Out-Null
    $zip=[IO.Compression.ZipFile]::OpenRead($saved)
    try { $reader=[IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open()); try { [xml]$xml=$reader.ReadToEnd() } finally {$reader.Dispose()} } finally {$zip.Dispose()}
    $point=$xml.SelectSingleNode('//MasterTrack/Automations/Automation[Type="Tempo" and Bar="1"]')
    Assert ($point.Value -eq '150 2' -and $point.Position -eq '0.5' -and $point.Linear -eq 'true') 'Saved GPIF tempo differs'
    # Audio graph refreshes can mark the live document dirty after Save As has
    # completed. The persisted bytes were validated above, so explicitly
    # discard only that post-save in-memory state before reopening the copy.
    Wait-Operation (Call gp_close @{unsaved='discard'}).request 'closed' | Out-Null
    $opened=Invoke-McpTool $connection gp_open @{path=$saved}; $id=(Wait-Operation $opened.request 'opened').document; $owned += $id
    Assert ((Json (& $tempoRead)) -eq $expectedTempo) 'Reopened tempo differs'
    Assert ((Json (& $soundRead)) -eq $expectedSound) 'Reopened sound differs'
    $after=(Invoke-McpTool $connection gp_documents).documents | Where-Object id -NotIn $owned | Select-Object id,dirty,opened_path
    Assert ((Json $after) -eq (Json $others)) 'Audio tests changed another document'
    $complete=$true
} finally {
    if ($id) { Call gp_playback @{operation='stop'} -AllowError | Out-Null }
    if ($playbackBefore -and $id) {
        Invoke-McpTool $connection gp_activate @{document=$id} | Out-Null
        foreach ($pair in @(@('set_loop','loop'),@('set_metronome','metronome'),@('set_countdown','countdown'))) {
            Call gp_playback @{operation=$pair[0];enabled=[bool]$playbackBefore.($pair[1])} | Out-Null
        }
    }
    if ($deviceBefore) {
        foreach ($property in @('audioDevice','audioOutput','audioInput','audioBuffersSize')) {
            $current=Invoke-McpTool $connection gp_audio_device
            if ($current.configuration.$property -ne $deviceBefore.configuration.$property) {
                Invoke-McpTool $connection gp_audio_device @{operation='set';property=$property;value=$deviceBefore.configuration.$property} | Out-Null
            }
        }
    }
    if ($complete) { foreach ($document in (Invoke-McpTool $connection gp_documents).documents | Where-Object id -In $owned) {
        Wait-Operation (Invoke-McpTool $connection gp_close @{document=$document.id;unsaved='discard'}).request 'closed' | Out-Null
    } }
    @{complete=$complete;checks=$checks;render=[bool]$Render;devices=$deviceBefore;evidence=$evidence;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash} |
        ConvertTo-Json -Depth 30 | Set-Content (Join-Path $run 'verification.json') -Encoding utf8
    Close-McpSession $connection
}
Write-Output "PASS: $checks audio checks. Evidence: $run"
