param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.Path]::GetFullPath((Join-Path $root 'artifacts/native-test.gp'))
$fixtureHash = (Get-FileHash -LiteralPath "$PSScriptRoot/testdata/minimal.gp").Hash
$checks = 0
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++; $script:lastCheck=$message }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 24 -Compress }
$connection = New-McpSession -SessionFile $SessionFile
function Score { Invoke-McpTool $connection gp_score @{document=$id} }
function Notes([int]$track=0) { Invoke-McpTool $connection gp_read_bars @{document=$id;track=$track;count=2} }
function Undo { Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'} | Out-Null }
function Effect([string]$property, $value, [int]$string=0) { Invoke-McpTool $connection gp_edit_note_effect @{document=$id;string=$string;property=$property;value=$value} }
function Read-Gpif([string]$path) {
    $zip=[IO.Compression.ZipFile]::OpenRead($path)
    try {
        $reader=[IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}
function First-GpifNote($gpif) {
    $barId=($gpif.GPIF.MasterBars.MasterBar[0].Bars -split '\s+')[0]
    $bar=$gpif.SelectSingleNode("/GPIF/Bars/Bar[@id='$barId']")
    $voiceId=($bar.Voices -split '\s+')[0]
    $voice=$gpif.SelectSingleNode("/GPIF/Voices/Voice[@id='$voiceId']")
    $beatId=($voice.Beats -split '\s+')[0]
    $beat=$gpif.SelectSingleNode("/GPIF/Beats/Beat[@id='$beatId']")
    $noteId=($beat.Notes -split '\s+')[0]
    $gpif.SelectSingleNode("/GPIF/Notes/Note[@id='$noteId']")
}
function Close-Document([string]$document) {
    $request=Invoke-McpTool $connection gp_close @{document=$document}
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do {
        $state=Invoke-McpTool $connection gp_documents
        if ($state.closing.request -eq $request.request -and $state.closing.status -eq 'closed') { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Native document close did not finish'
}
function Open-Document([string]$path) {
    Invoke-McpTool $connection gp_open @{path=$path} | Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do {
        $found=@((Invoke-McpTool $connection gp_documents).documents | Where-Object opened_path -EQ $path.Replace('\','/'))
        if ($found.Count -eq 1) { return $found[0].id }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Native document open did not finish'
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
    $run=Join-Path $root ('artifacts/native-effects-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='voice';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='beat';index=0} | Out-Null
    $original=Notes
    foreach ($arguments in @(
        @{string=-1;property='palm_mute';value=$true}, @{string=6;property='palm_mute';value=$true},
        @{string=1;property='palm_mute';value=$true}, @{string=0;property='unknown';value=$true},
        @{string=0;property='palm_mute';value='true'}, @{string=0;property='vibrato';value=$true},
        @{string=0;property='vibrato';value='Heavy'}, @{string=0;property='anti_accent';value='Ghost'},
        @{string=0;property='left_fingering';value='1'}, @{string=0;property='right_fingering';value='Z'}
    )) {
        $arguments.document=$id
        Assert ((Invoke-McpTool $connection gp_edit_note_effect $arguments -AllowError).error) 'Invalid note effect accepted'
    }
    Assert ((Json (Notes).bars) -eq (Json $original.bars) -and -not (Score).dirty) 'Rejected effects changed score'
    Invoke-McpTool $connection gp_edit_note @{document=$id;operation='set';string=1;fret=3} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='voice';index=1} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_edit_note @{document=$id;operation='set';string=0;fret=7} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='voice';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='beat';index=0} | Out-Null
    Invoke-McpTool $connection gp_edit_tracks @{document=$id;operation='duplicate';track=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='track';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='bar';index=0} | Out-Null
    Invoke-McpTool $connection gp_cursor @{document=$id;axis='beat';index=0} | Out-Null
    $before=Notes
    $otherTrack=Notes 1
    $beforeCursor=(Score).cursor
    $baselineCopy=Invoke-McpTool $connection gp_save @{document=$id;path=(Join-Path $run 'baseline.gp')}
    $baselineGpifNote=First-GpifNote (Read-Gpif $baselineCopy.path)
    $selectors=@{
        palm_mute="Properties/Property[@name='PalmMuted']"; let_ring='LetRing'
        left_hand_tapping="Properties/Property[@name='LeftHandTapped']"; right_hand_tapping="Properties/Property[@name='Tapped']"
        vibrato='Vibrato'; anti_accent='AntiAccent'; left_fingering='LeftFingering'; right_fingering='RightFingering'
    }
    $cases=@(
        @{property='palm_mute';values=@($true)}, @{property='let_ring';values=@($true)},
        @{property='left_hand_tapping';values=@($true)}, @{property='right_hand_tapping';values=@($true)},
        @{property='vibrato';values=@('Slight','Wide')}, @{property='anti_accent';values=@('Soft','Normal','Strong')},
        @{property='left_fingering';values=@('P','I','M','A','C','Open')},
        @{property='right_fingering';values=@('P','I','M','A','C','Open')}
    )
    $savedCases=@()
    foreach ($case in $cases) {
        foreach ($value in $case.values) {
            $changed=Effect $case.property $value
            Assert ($changed.note.effects.($case.property) -ceq $value -and $changed.dirty) "Native $($case.property) $value was not applied"
            $expected=(Json @{items=$before.bars} | ConvertFrom-Json).items
            $expected[0].voices[0].beats[0].notes[0].effects.($case.property)=$value
            Assert ((Json (Notes).bars) -eq (Json $expected)) "Effect $($case.property) changed another note, voice, rhythm or pitch"
            Assert ((Json (Notes 1).bars) -eq (Json $otherTrack.bars)) "Effect $($case.property) changed another track"
            Assert ((Json (Score).cursor) -eq (Json $beforeCursor)) "Effect $($case.property) changed cursor or UI selection"
            $saved=Invoke-McpTool $connection gp_save @{document=$id;path=(Join-Path $run "$($case.property)-$value.gp")}
            $gpif=Read-Gpif $saved.path
            $gpifNote=First-GpifNote $gpif
            $effectNode=$gpifNote.SelectSingleNode($selectors[$case.property])
            $persisted=if ($value -is [bool]) { $null -ne $effectNode -and ($case.property -eq 'let_ring' -or $null -ne $effectNode.SelectSingleNode('Enable')) } else { $effectNode.InnerText -ceq $value }
            Assert $persisted "Saved $($case.property) $value differs from GPIF"
            $noteWithoutEffect=$gpifNote.CloneNode($true)
            $node=$noteWithoutEffect.SelectSingleNode($selectors[$case.property])
            $node.ParentNode.RemoveChild($node) | Out-Null
            Assert ($noteWithoutEffect.OuterXml -eq $baselineGpifNote.OuterXml) "Saved $($case.property) changed other note data"
            $savedCases+=@{property=$case.property;value=$value;path=$saved.path;note=$changed.note;gpif_note=$gpifNote.OuterXml}
            Effect $case.property $value | Out-Null
            Undo
            Assert ((Json (Notes).bars) -eq (Json $before.bars)) "Effect $($case.property) undo failed or identical write added history"
            Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
            Assert ((Json (Notes).bars) -eq (Json $expected)) "Effect $($case.property) redo failed"
            $clear=if ($value -is [bool]) { $false } else { 'None' }
            Effect $case.property $clear | Out-Null
            Assert ((Json (Notes).bars) -eq (Json $before.bars)) "Effect $($case.property) clear failed"
            Undo
            Assert ((Json (Notes).bars) -eq (Json $expected)) "Effect $($case.property) clear undo failed"
            Undo
            Assert ((Json (Notes).bars) -eq (Json $before.bars)) "Effect $($case.property) final undo failed"
        }
    }
    foreach ($case in $cases) { Effect $case.property $case.values[0] | Out-Null }
    $combined=Notes
    $combinedCopy=Invoke-McpTool $connection gp_save @{document=$id;path=(Join-Path $run 'combined.gp')}
    $reopened=Open-Document $combinedCopy.path
    $reopenedBars=Invoke-McpTool $connection gp_read_bars @{document=$reopened;count=2}
    Assert ((Json $reopenedBars.bars) -eq (Json $combined.bars)) 'Combined effects changed after native save/open'
    Close-Document $reopened
    foreach ($case in $cases) { Undo }
    Assert ((Json (Notes).bars) -eq (Json $before.bars)) 'Combined effect undo did not restore notes'
    Undo
    Undo
    Undo
    $restored=Notes
    $placeholder=$restored.bars[0].voices[1].beats
    Assert ($placeholder.Count -eq 0 -or ($placeholder.Count -eq 1 -and $placeholder[0].placeholder -and $placeholder[0].rest -and $placeholder[0].notes.Count -eq 0)) 'Empty-voice undo left unexpected musical content'
    $restored.bars[0].voices[1].beats=@()
    Assert ((Json $restored.bars) -eq (Json $original.bars) -and (Score).track_count -eq 1) 'Test setup undo did not restore fixture content'
    Invoke-McpTool $connection gp_save_as @{document=$id;path=(Join-Path $run 'restored.gp')} | Out-Null
    Close-Document $id
    $id=Open-Document $source
    Assert ((Json (Notes).bars) -eq (Json $original.bars) -and -not (Score).dirty) 'Reopening fixture did not restore exact initial model'
    $after=Invoke-McpTool $connection gp_capabilities
    Assert ($after.pid -eq $identity.pid -and $after.foreground_pid -ne $after.pid -and $after.hidden_mode) 'Note effects brought host to foreground'
    $window=Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    Assert (-not ($window.objects | Where-Object class -EQ 'gp::gui::MainWindow').visible) 'Note effects made host visible'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $fixtureHash) 'Fixture copy changed'
    @{checks=$checks;identity_before=$identity;identity_after=$after;before=$before;saved_cases=$savedCases;combined=$combined;combined_copy=$combinedCopy} |
        ConvertTo-Json -Depth 24 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks native note-effect checks. Evidence: $run"
} catch {
    Write-Output "Failed after $checks checks; last passed assertion: $lastCheck"
    throw
} finally { Close-McpSession $connection }
