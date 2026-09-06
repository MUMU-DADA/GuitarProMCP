param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.Path]::GetFullPath((Join-Path $root 'artifacts/native-test.gp'))
$fixture = Join-Path $PSScriptRoot 'testdata/minimal.gp'
$fixtureHash = (Get-FileHash -LiteralPath $fixture).Hash
$checks = 0
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
$connection = New-McpSession -SessionFile $SessionFile
function Wait-Playback([string]$document, [scriptblock]$condition) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $state = Invoke-McpTool $connection gp_playback @{document=$document} -AllowError
        if (-not $state.error -and (& $condition $state)) { return $state }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Playback state did not settle: $($state | ConvertTo-Json -Compress)"
}
try {
    $documents = Invoke-McpTool $connection gp_documents
    Assert ($documents.documents.Count -eq 1) 'Start this test with only artifacts/native-test.gp open'
    $first = $documents.documents[0]
    Assert ($first.opened_path -eq $source.Replace('\','/') -and -not $first.dirty) 'Refusing to use a different or dirty document'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy was modified'
    Invoke-McpTool $connection gp_window @{state='hide'} | Out-Null
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.qobject_registry -and -not $identity.qobject_registry_truncated) 'QObject registry unavailable or truncated'
    Assert ($identity.foreground_pid -ne $identity.pid) 'Host is in foreground'
    $run = Join-Path $root ('artifacts/native-session-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $secondPath = Join-Path $run 'second.gp'
    Copy-Item -LiteralPath $fixture -Destination $secondPath
    $zip = [IO.Compression.ZipFile]::Open($secondPath, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $zip.GetEntry('Content/score.gpif')
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$gpif = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $titleNode = $gpif.SelectSingleNode('/GPIF/Score/Title')
        $titleNode.RemoveAll()
        $titleNode.AppendChild($gpif.CreateCDataSection('后台播放测试二')) | Out-Null
        $tempo = $gpif.SelectSingleNode('//Automation[Type="Tempo"]/Value')
        Assert ($tempo.InnerText -eq '90 2') 'Unexpected fixture tempo'
        $tempo.InnerText = '120 2'
        $laterTempo = $tempo.ParentNode.CloneNode($true)
        $laterTempo.SelectSingleNode('Bar').InnerText = '1'
        $laterTempo.SelectSingleNode('Value').InnerText = '180 2'
        $tempo.ParentNode.ParentNode.AppendChild($laterTempo) | Out-Null
        $voice = $gpif.SelectSingleNode('/GPIF/Voices/Voice[@id="0"]').CloneNode($true)
        $voice.SetAttribute('id', '2')
        $gpif.GPIF.Voices.AppendChild($voice) | Out-Null
        $gpif.SelectSingleNode('/GPIF/Bars/Bar[@id="0"]/Voices').InnerText = '0 2'
        $entry.Delete()
        $writer = [IO.StreamWriter]::new($zip.CreateEntry('Content/score.gpif').Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write($gpif.OuterXml) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    $opened = Invoke-McpTool $connection gp_open @{path=$secondPath}
    Assert ($opened.status -eq 'scheduled') 'Open was not scheduled'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $documents = Invoke-McpTool $connection gp_documents
        $second = $documents.documents | Where-Object opened_path -EQ $secondPath.Replace('\','/')
        if ($second) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($null -ne $second -and $documents.documents.Count -eq 2) 'Native file open did not produce the expected document'
    Assert ((Invoke-McpTool $connection gp_score @{document=$second.id}).metadata.Title -eq '后台播放测试二') 'Opened document content mismatch'
    $duplicate = Invoke-McpTool $connection gp_open @{path=$secondPath}
    Assert ($duplicate.status -eq 'already_open' -and $duplicate.document -eq $second.id) 'Duplicate open did not reuse document'
    Invoke-McpTool $connection gp_activate @{document=$second.id} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$second.id;axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$second.id;axis='beat';index=0} | Out-Null
    $voicesBefore = Invoke-McpTool $connection gp_read_bars @{document=$second.id;count=2}
    $otherVoice = $voicesBefore.bars[0].voices[1] | ConvertTo-Json -Depth 15 -Compress
    Assert ($voicesBefore.bars[0].voices[1].beats.Count -eq 4) 'Second voice fixture was not imported'
    Invoke-McpTool $connection gp_edit_note @{document=$second.id;operation='set';string=1;fret=3} | Out-Null
    $added = Invoke-McpTool $connection gp_read_bars @{document=$second.id}
    Assert ($added.bars[0].voices[0].beats[0].notes.Count -eq 2 -and ($added.bars[0].voices[1] | ConvertTo-Json -Depth 15 -Compress) -eq $otherVoice) 'Note creation changed another voice'
    Invoke-McpTool $connection gp_edit_beat @{document=$second.id;operation='rhythm';denominator=8} | Out-Null
    $rhythm = Invoke-McpTool $connection gp_read_bars @{document=$second.id}
    Assert ($rhythm.bars[0].voices[0].beats[0].native_note_value -eq 5 -and ($rhythm.bars[0].voices[1] | ConvertTo-Json -Depth 15 -Compress) -eq $otherVoice) 'Rhythm edit changed another voice'
    Invoke-McpTool $connection gp_undo_redo @{document=$second.id;operation='undo'} | Out-Null
    Invoke-McpTool $connection gp_undo_redo @{document=$second.id;operation='undo'} | Out-Null
    $voicesRestored = Invoke-McpTool $connection gp_read_bars @{document=$second.id;count=2}
    Assert (($voicesRestored.bars | ConvertTo-Json -Depth 20 -Compress) -eq ($voicesBefore.bars | ConvertTo-Json -Depth 20 -Compress)) 'Multiple voices did not restore after undo'
    $voiceCursor = Invoke-McpTool $connection gp_cursor @{document=$second.id;axis='voice';index=1}
    Assert ($voiceCursor.cursor.voice -eq 1) 'Native second-voice navigation failed'
    Invoke-McpTool $connection gp_cursor @{document=$second.id;axis='beat';index=0} | Out-Null
    Invoke-McpTool $connection gp_edit_note @{document=$second.id;operation='set';string=1;fret=4} | Out-Null
    $voiceEdited = Invoke-McpTool $connection gp_read_bars @{document=$second.id}
    Assert (($voiceEdited.bars[0].voices[1].beats[0].notes | Where-Object string -EQ 1).fret -eq 4) 'Edit did not reach the second voice'
    Assert (($voiceEdited.bars[0].voices[0] | ConvertTo-Json -Depth 15 -Compress) -eq ($voicesBefore.bars[0].voices[0] | ConvertTo-Json -Depth 15 -Compress)) 'Second-voice edit changed the first voice'
    Invoke-McpTool $connection gp_undo_redo @{document=$second.id;operation='undo'} | Out-Null
    $voicesUndone = Invoke-McpTool $connection gp_read_bars @{document=$second.id;count=2}
    Assert (($voicesUndone.bars | ConvertTo-Json -Depth 20 -Compress) -eq ($voicesBefore.bars | ConvertTo-Json -Depth 20 -Compress)) 'Second-voice undo changed score content'
    foreach ($voice in @(2,3,0)) {
        Assert ((Invoke-McpTool $connection gp_cursor @{document=$second.id;axis='voice';index=$voice}).cursor.voice -eq $voice) 'Native voice navigation readback differs'
    }
    Assert ((Invoke-McpTool $connection gp_cursor @{document=$second.id;axis='voice';index=4} -AllowError).error) 'Out-of-range voice accepted'
    Assert ((Invoke-McpTool $connection gp_score @{document=$second.id}).cursor.voice -eq 0) 'Invalid voice request changed cursor'
    $restored = Invoke-McpTool $connection gp_save_as @{document=$second.id;path=(Join-Path $run 'second-restored.gp')}
    Assert (-not $restored.dirty) 'Restored second document is dirty'
    $activations = @()
    # Repeated switching guards against the stale QObject snapshot crash.
    foreach ($round in 1..3) { foreach ($document in @($first, $second)) {
        $activation = Invoke-McpTool $connection gp_activate @{document=$document.id}
        $observed = Invoke-McpTool $connection gp_documents
        Assert ($activation.status -eq 'active' -and $observed.active_document -eq $document.id) 'Native activation mismatch'
        $playback = Wait-Playback $document.id { param($state) $state.total_ticks -gt 0 }
        $activations += @{document=$document.id;playback=$playback}
    } }
    $playbackEvidence = @()
    foreach ($document in @($first, $second)) {
        Invoke-McpTool $connection gp_activate @{document=$document.id} | Out-Null
        $before = Wait-Playback $document.id { param($state) $state.total_ticks -gt 0 }
        Assert (-not $before.playing) 'Refusing to interrupt existing playback'
        try {
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='set_loop';enabled=$false} | Out-Null
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='set_metronome';enabled=$false} | Out-Null
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='set_countdown';enabled=$false} | Out-Null
            $settings = Invoke-McpTool $connection gp_playback @{document=$document.id}
            Assert (-not $settings.loop -and -not $settings.metronome -and -not $settings.countdown) 'Native settings readback failed'
            $seek = Invoke-McpTool $connection gp_playback @{document=$document.id;operation='seek';bar=1;tick=0}
            Assert ($seek.tick -eq 1920 -and $seek.frame -gt 0) 'Native playback seek failed'
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='seek';bar=0;tick=0} | Out-Null
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='play'} | Out-Null
            $playing = Wait-Playback $document.id { param($state) $state.playing -and $state.frame -gt 0 }
            Start-Sleep -Milliseconds 150
            $advanced = Invoke-McpTool $connection gp_playback @{document=$document.id}
            Assert ($advanced.playing -and $advanced.frame -gt $playing.frame -and $advanced.tick -ge $playing.tick) 'Playback did not progress'
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='stop'} | Out-Null
            $stopped = Wait-Playback $document.id { param($state) -not $state.playing }
            Start-Sleep -Milliseconds 100
            $settled = Invoke-McpTool $connection gp_playback @{document=$document.id}
            Assert (-not $settled.playing -and $settled.frame -eq $stopped.frame) 'Stopped timeline is still advancing'
            $playbackEvidence += @{document=$document.id;seek=$seek;playing=$playing;advanced=$advanced;stopped=$settled}
        } finally {
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='stop'} | Out-Null
            Wait-Playback $document.id {param($state) -not $state.playing} | Out-Null
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='seek';bar=0;tick=0} | Out-Null
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='set_loop';enabled=[bool]$before.loop} | Out-Null
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='set_metronome';enabled=[bool]$before.metronome} | Out-Null
            Invoke-McpTool $connection gp_playback @{document=$document.id;operation='set_countdown';enabled=[bool]$before.countdown} | Out-Null
        }
    }
    $ratio = $playbackEvidence[1].seek.frame / $playbackEvidence[0].seek.frame
    Assert ([Math]::Abs($ratio - 0.75) -lt 0.01) 'Playback controllers did not follow the documents distinct tempos'
    $initialTempo = (Invoke-McpTool $connection gp_score @{document=$first.id}).tempo
    Assert ($initialTempo.value -eq 90 -and $initialTempo.unit -eq 'Quarter' -and $initialTempo.quarter_bpm -eq 90) 'Initial score tempo differs from fixture'
    foreach ($arguments in @(
        @{value=0}, @{value=400.1}, @{value=137.5}, @{value=-1}, @{value='120'}, @{value=$null}, @{value=$true},
        @{value=120;unit='None'}, @{value=120;unit='invalid'},
        @{value=120;label=([string][char]0xffff)}, @{value=120;label=([string][char]1)},
        @{value=120;label='无法保存 🎸'}
    )) {
        $arguments.document = $first.id
        Assert ((Invoke-McpTool $connection gp_edit_tempo $arguments -AllowError).error) 'Invalid tempo request accepted'
    }
    $unchanged = Invoke-McpTool $connection gp_score @{document=$first.id}
    Assert (-not $unchanged.dirty -and $unchanged.tempo.value -eq 90 -and $unchanged.tempo.label -eq $initialTempo.label) 'Rejected tempo request changed score'
    foreach ($value in @(1,400)) {
        $tempo = Invoke-McpTool $connection gp_edit_tempo @{document=$first.id;value=$value}
        Assert ($tempo.tempo.value -eq $value -and $tempo.dirty -and $tempo.undo_available) 'Tempo boundary readback differs'
        $undone = Invoke-McpTool $connection gp_undo_redo @{document=$first.id;operation='undo'}
        Assert ($undone.tempo.value -eq 90) 'Tempo boundary undo failed'
    }
    $tempoEvidence = @()
    foreach ($case in @(
        @{unit='Eighth';factor=0.5;gpif=1}, @{unit='Quarter';factor=1;gpif=2},
        @{unit='QuarterDotted';factor=1.5;gpif=3}, @{unit='Half';factor=2;gpif=4},
        @{unit='HalfDotted';factor=3;gpif=5}
    )) {
        Invoke-McpTool $connection gp_activate @{document=$second.id} | Out-Null
        $changed = Invoke-McpTool $connection gp_edit_tempo @{document=$first.id;value=60;unit=$case.unit;label='速度验证'}
        Assert ($changed.tempo.value -eq 60 -and $changed.tempo.unit -eq $case.unit -and $changed.tempo.quarter_bpm -eq 60*$case.factor) 'Native tempo unit conversion differs'
        $other = Invoke-McpTool $connection gp_score @{document=$second.id}
        Assert ($other.tempo.value -eq 120 -and -not $other.dirty) 'Tempo edit changed the inactive document'
        $expectedFrame = $playbackEvidence[0].seek.frame * 90 / (60*$case.factor)
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $seek = Invoke-McpTool $connection gp_playback @{document=$first.id;operation='seek';bar=1;tick=0}
            if ([Math]::Abs($seek.frame - $expectedFrame) -le 2) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert ($seek.tick -eq 1920 -and [Math]::Abs($seek.frame - $expectedFrame) -le 2) 'Tempo edit did not update native playback timing'
        $savedTempo = Invoke-McpTool $connection gp_save @{document=$first.id;path=(Join-Path $run ("tempo-" + $case.unit + '.gp'))}
        $zip = [IO.Compression.ZipFile]::OpenRead($savedTempo.path)
        try {
            $reader = [IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
            try { [xml]$gpifTempo = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $automation = $gpifTempo.SelectSingleNode('/GPIF/MasterTrack/Automations/Automation[Type="Tempo"]')
            Assert ($automation.Value -eq "60 $($case.gpif)") 'Saved GPIF tempo unit differs'
            Assert ($automation.Text.InnerText -eq '速度验证') 'Chinese tempo label was not saved'
        } finally { $zip.Dispose() }
        Invoke-McpTool $connection gp_edit_tempo @{document=$first.id;value=60} | Out-Null
        $undone = Invoke-McpTool $connection gp_undo_redo @{document=$first.id;operation='undo'}
        Assert ($undone.tempo.value -eq 90 -and $undone.tempo.unit -eq 'Quarter' -and $undone.tempo.label -eq $initialTempo.label) 'Tempo undo failed or unchanged tempo created history'
        $redone = Invoke-McpTool $connection gp_undo_redo @{document=$first.id;operation='redo'}
        Assert ($redone.tempo.unit -eq $case.unit -and $redone.tempo.value -eq 60) 'Tempo redo failed'
        Invoke-McpTool $connection gp_undo_redo @{document=$first.id;operation='undo'} | Out-Null
        $tempoEvidence += @{changed=$changed;seek=$seek;saved=$savedTempo}
    }
    $tempoRestored = Invoke-McpTool $connection gp_save_as @{document=$first.id;path=(Join-Path $run 'tempo-restored.gp')}
    Assert (-not $tempoRestored.dirty) 'Tempo test left fixture dirty'
    Invoke-McpTool $connection gp_playback @{document=$first.id;operation='seek';bar=0;tick=0} | Out-Null
    $laterChanged = Invoke-McpTool $connection gp_edit_tempo @{document=$second.id;value=150}
    Assert ($laterChanged.tempo.value -eq 150) 'Initial tempo edit failed with later tempo automation'
    $laterStart = Invoke-McpTool $connection gp_playback @{document=$second.id;operation='seek';bar=1;tick=0}
    $laterBeat = Invoke-McpTool $connection gp_playback @{document=$second.id;operation='seek';bar=1;tick=480}
    Assert ([Math]::Abs($laterStart.frame / $playbackEvidence[0].seek.frame - 0.6) -lt 0.01) 'Initial tempo did not reach playback with later automation'
    Assert ([Math]::Abs(($laterBeat.frame - $laterStart.frame) - $playbackEvidence[0].seek.frame/8) -le 2) 'Initial tempo edit changed later tempo playback'
    $laterSaved = Invoke-McpTool $connection gp_save @{document=$second.id;path=(Join-Path $run 'tempo-with-later-automation.gp')}
    $zip = [IO.Compression.ZipFile]::OpenRead($laterSaved.path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$gpifTempo = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $tempos = @($gpifTempo.SelectNodes('/GPIF/MasterTrack/Automations/Automation[Type="Tempo"]'))
        Assert ($tempos.Count -eq 2 -and ($tempos | Where-Object Bar -EQ 0).Value -eq '150 2' -and ($tempos | Where-Object Bar -EQ 1).Value -eq '180 2') 'Initial tempo edit changed later saved automation'
    } finally { $zip.Dispose() }
    $laterUndone = Invoke-McpTool $connection gp_undo_redo @{document=$second.id;operation='undo'}
    Assert ($laterUndone.tempo.value -eq 120) 'Initial tempo undo failed with later automation'
    Invoke-McpTool $connection gp_save_as @{document=$second.id;path=(Join-Path $run 'second-tempo-restored.gp')} | Out-Null
    Invoke-McpTool $connection gp_playback @{document=$second.id;operation='seek';bar=0;tick=0} | Out-Null
    Invoke-McpTool $connection gp_activate @{document=$first.id} | Out-Null
    $afterIdentity = Invoke-McpTool $connection gp_capabilities
    Assert ($afterIdentity.foreground_pid -ne $afterIdentity.pid) 'Host entered foreground'
    $window = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    Assert (-not ($window.objects | Where-Object class -EQ 'gp::gui::MainWindow').visible) 'Host window became visible'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Original fixture changed'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;opened=$opened;activations=$activations;playback=$playbackEvidence;tempo_frame_ratio=$ratio;tempo_edits=$tempoEvidence;later_tempo=@{changed=$laterChanged;start=$laterStart;beat=$laterBeat;saved=$laterSaved};voice_edit=$added;voice_rhythm=$rhythm;second_voice_edit=$voiceEdited;voice_restored=$restored} |
        ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native document/playback checks. Evidence: $run"
} finally { Close-McpSession $connection }
