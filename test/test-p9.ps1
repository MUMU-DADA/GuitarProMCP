param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-p9-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$checks = 0
$complete = $false
$id = ''
function Check($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 50 -Compress }
function Call([string]$name, [hashtable]$arguments = @{}, [switch]$AllowError) {
    $values = $arguments.Clone()
    if ($script:id -and -not $values.ContainsKey('document')) { $values.document = $script:id }
    $result = Invoke-McpTool $connection $name $values -AllowError:$AllowError
    if ($result.result) { return $result.result }
    return $result
}
function Close-Document {
    if (-not $script:id) { return }
    $result = Call gp_close @{unsaved='discard'}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$result.request}).operation
        if ($state.status -in @('closed','error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq 'closed') "P9 document close failed: $(Json $state)"
    $script:id = ''
}
try {
    $status = Call gp_p9_status
    Check ($status.phase -eq 'P9' -and $status.capabilities.Count -ge 10) 'P9 capability matrix is incomplete.'
    $textCapability = @($status.capabilities | Where-Object id -eq 'beat_text')
    Check ($textCapability.Count -eq 1 -and $textCapability[0].tool -eq 'gp_edit_beat') 'Beat text capability is not advertised.'
    $dynamicCapability = @($status.capabilities | Where-Object id -eq 'beat_dynamic')
    Check ($dynamicCapability.Count -eq 1 -and $dynamicCapability[0].operation -eq 'dynamic') 'Beat dynamic capability is not advertised.'
    $clefCapability = @($status.capabilities | Where-Object id -eq 'measure_clef')
    Check ($clefCapability.Count -eq 1 -and $clefCapability[0].operation -eq 'clef') 'Measure clef capability is not advertised.'
    $capabilities = Call gp_capabilities
    Check ($capabilities.p9.phase -eq 'P9' -and $capabilities.p9.capabilities.Count -eq $status.capabilities.Count) 'gp_capabilities does not expose the P9 matrix.'

    $source = Join-Path $run 'fixture.gp'
    Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $source
    $opened = Invoke-McpTool $connection gp_open @{path=$source}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$opened.request}).operation
        if ($state.status -in @('opened','error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq 'opened') "P9 fixture open failed: $(Json $state)"
    $script:id = $state.document
    Call gp_cursor @{axis='bar';index=0} | Out-Null
    Call gp_cursor @{axis='beat';index=0} | Out-Null
    $automationBefore = Call gp_automation @{operation='state';track=0}
    $soundBefore = @($automationBefore.tracks[0].automations | Where-Object type -eq 1024)
    Check ($soundBefore.Count -eq 1 -and @($soundBefore[0].points).Count -ge 1) 'Fixture Sound automation was not readable.'
    $invalidAutomation = Call gp_automation @{operation='state';track=-2} -AllowError
    Check ($invalidAutomation.error -match 'track must be -1') 'Automation state accepted an invalid negative track index.'
    $invalidAutomation = Call gp_automation @{operation='set';track=0;bar=0;position=0.25;value=0.8} -AllowError
    Check ($invalidAutomation.error -match 'parameter must be an integer') 'Automation set accepted a missing parameter.'
    $invalidAutomation = Call gp_automation @{operation='set';track=0;parameter=0;bar=0;position=0.25} -AllowError
    Check ($invalidAutomation.error -match 'value must be a finite number') 'Automation set accepted a missing value.'
    $invalidAutomation = Call gp_automation @{operation='bogus'} -AllowError
    Check ($invalidAutomation.error -match 'operation must be types') 'Automation accepted an unknown operation.'
    $invalidAutomation = Call gp_automation @{operation='set';track=0;parameter=0;bar=0;position=0.25;value=0.8;text=([string][char]1)} -AllowError
    Check ($invalidAutomation.error -match 'valid host text') 'Automation set accepted an invalid host text value.'
    $automationSet = Call gp_automation @{operation='set';track=0;parameter=0;bar=0;position=0.25;value=0.8;linear=$true;text='P9 automation'}
    $automationTypes = @($automationSet.state.tracks[0].automations | ForEach-Object name)
    Check ($automationSet.changed -and $automationSet.dirty -and $automationTypes -contains 'DSPParam_00' -and $automationTypes -contains 'Sound') 'Experimental automation write did not preserve existing Sound automation.'
    $automationSame = Call gp_automation @{operation='set';track=0;parameter=0;bar=0;position=0.25;value=0.8;linear=$true;text='P9 automation'}
    Check (-not $automationSame.changed) 'Identical automation write was not reported unchanged.'
    Call gp_undo_redo @{operation='undo'} | Out-Null
    $automationUndo = Call gp_automation @{operation='state';track=0}
    Check (@($automationUndo.tracks[0].automations | Where-Object name -eq 'DSPParam_00').Count -eq 0 -and @($automationUndo.tracks[0].automations | Where-Object name -eq 'Sound').Count -eq 1) 'Automation undo did not restore the original Sound-only state.'
    Call gp_undo_redo @{operation='redo'} | Out-Null
    $automationRedo = Call gp_automation @{operation='state';track=0}
    Check (@($automationRedo.tracks[0].automations | Where-Object name -eq 'DSPParam_00').Count -eq 1 -and @($automationRedo.tracks[0].automations | Where-Object name -eq 'Sound').Count -eq 1) 'Automation redo did not restore the experimental point.'
    $automationPath = Join-Path $run 'automation.gp'
    $automationSave = Call gp_save_as @{path=$automationPath}
    Check ($automationSave.path -and (Test-Path -LiteralPath $automationSave.path)) 'Automation save failed.'
    $automationCopy = Join-Path $run 'automation-reopen.gp'
    Copy-Item -LiteralPath $automationSave.path -Destination $automationCopy
    $automationOpen = Invoke-McpTool $connection gp_open @{path=$automationCopy}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$automationOpen.request}).operation
        if ($state.status -in @('opened','error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq 'opened') "Automation reopen failed: $(Json $state)"
    $automationReopened = Invoke-McpTool $connection gp_automation @{document=$state.document;track=0;operation='state'}
    $automationPoint = @($automationReopened.tracks[0].automations | Where-Object name -eq 'DSPParam_00')[0]
    Check ($automationPoint -and @($automationPoint.points).Count -eq 1 -and $automationPoint.points[0].bar -eq 0 -and
        [Math]::Abs([double]$automationPoint.points[0].position - 0.25) -lt 0.0001 -and
        [Math]::Abs([double]$automationPoint.points[0].value - 0.8) -lt 0.0001 -and
        $automationPoint.points[0].linear -eq $true -and $automationPoint.points[0].text -eq 'P9 automation' -and
        $automationPoint.points[0].parameter_id -eq 256) 'Automation save/reopen changed the experimental point.'
    $automationClose = Invoke-McpTool $connection gp_close @{document=$state.document;unsaved='discard'}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$automationClose.request}).operation
        if ($state.status -in @('closed','error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq 'closed') 'Automation reopened document close failed.'
    $automationRemove = Call gp_automation @{operation='remove';track=0;parameter=0;bar=0;position=0.25}
    Check ($automationRemove.changed -and @($automationRemove.state.tracks[0].automations | Where-Object name -eq 'DSPParam_00').Count -eq 0 -and @($automationRemove.state.tracks[0].automations | Where-Object name -eq 'Sound').Count -eq 1) 'Automation remove did not preserve Sound automation.'
    $automationRemoveSame = Call gp_automation @{operation='remove';track=0;parameter=0;bar=0;position=0.25}
    Check (-not $automationRemoveSame.changed) 'Removing a missing automation point was not reported unchanged.'
    $stemInitial = (Call gp_read_bars @{bar=0;include_stem=$true}).bars[0].voices[0].beats
    Check ($stemInitial[0].stem.drawing -eq 'Undefined' -and -not $stemInitial[0].stem.has_user_concert -and -not $stemInitial[0].stem.has_user_transposed) 'Fixture unexpectedly contains a user stem orientation.'
    $stemUp = Call gp_edit_beat @{operation='stem';orientation='Upward'}
    Check ($stemUp.orientation -eq 'Upward' -and $stemUp.bars[0].voices[0].beats[0].stem.drawing -eq 'Upward') 'Native stem orientation write/readback failed.'
    Call gp_undo_redo @{operation='undo'} | Out-Null
    Check ((Call gp_read_bars @{bar=0;include_stem=$true}).bars[0].voices[0].beats[0].stem.drawing -eq 'Undefined') 'Stem orientation undo failed.'
    Call gp_undo_redo @{operation='redo'} | Out-Null
    Check ((Call gp_read_bars @{bar=0;include_stem=$true}).bars[0].voices[0].beats[0].stem.drawing -eq 'Upward') 'Stem orientation redo failed.'
    Call gp_selection @{
        operation='range'
        base=@{track=0;staff=0;bar=0;voice=0;beat=1}
        extent=@{track=0;staff=0;bar=0;voice=0;beat=2}
    } | Out-Null
    $stemDown = Call gp_edit_beat @{operation='stem';scope='selection';orientation='Downward'}
    Check ($stemDown.orientation -eq 'Downward' -and @($stemDown.stems).Count -eq 2 -and
        @($stemDown.stems | Where-Object { $_.drawing -eq 'Downward' }).Count -eq 2) 'Stem orientation selection write failed.'
    $stemAuto = Call gp_edit_beat @{operation='stem';scope='selection';orientation='auto'}
    Check ($stemAuto.orientation -eq 'Auto' -and @($stemAuto.stems | Where-Object { $_.has_user_concert -or $_.has_user_transposed }).Count -eq 0) 'Automatic stem orientation did not clear user settings.'
    Call gp_selection @{operation='clear'} | Out-Null
    Call gp_cursor @{axis='beat';index=0} | Out-Null
    Call gp_edit_beat @{operation='stem';orientation='Upward'} | Out-Null
    $before = (Call gp_read_bars @{bar=0}).bars[0].voices[0].beats[0].text
    Check ($before -eq '') 'Fixture unexpectedly contains beat text.'
    Call gp_edit_beat @{operation='text';text='P9 文本 - cue'} | Out-Null
    $after = (Call gp_read_bars @{bar=0}).bars[0].voices[0].beats[0].text
    Check ($after -eq 'P9 文本 - cue') 'Native beat text was not written.'
    Check ((Call gp_score).dirty) 'Beat text did not mark the document dirty.'
    Call gp_undo_redo @{operation='undo'} | Out-Null
    Check ((Call gp_read_bars @{bar=0}).bars[0].voices[0].beats[0].text -eq '') 'Beat text undo failed.'
    Call gp_undo_redo @{operation='redo'} | Out-Null
    Check ((Call gp_read_bars @{bar=0}).bars[0].voices[0].beats[0].text -eq 'P9 文本 - cue') 'Beat text redo failed.'

    Call gp_selection @{
        operation='range'
        base=@{track=0;staff=0;bar=0;voice=0;beat=0}
        extent=@{track=0;staff=0;bar=0;voice=0;beat=1}
    } | Out-Null
    Call gp_edit_beat @{operation='text';scope='selection';text='P9 选区 - cue'} | Out-Null
    $selected = (Call gp_read_bars @{bar=0}).bars[0].voices[0].beats
    Check ($selected[0].text -eq 'P9 选区 - cue' -and $selected[1].text -eq 'P9 选区 - cue') 'Beat text selection write failed.'
    Call gp_undo_redo @{operation='undo'} | Out-Null
    $undone = (Call gp_read_bars @{bar=0}).bars[0].voices[0].beats
    Check ($undone[0].text -eq 'P9 文本 - cue' -and $undone[1].text -eq '') 'Beat text selection undo failed.'
    Call gp_undo_redo @{operation='redo'} | Out-Null
    $redone = (Call gp_read_bars @{bar=0}).bars[0].voices[0].beats
    Check ($redone[0].text -eq 'P9 选区 - cue' -and $redone[1].text -eq 'P9 选区 - cue') 'Beat text selection redo failed.'
    Call gp_edit_beat @{operation='text';scope='selection';text=''} | Out-Null
    $cleared = (Call gp_read_bars @{bar=0}).bars[0].voices[0].beats
    Check ($cleared[0].text -eq '' -and $cleared[1].text -eq '') 'Beat text selection clear failed.'
    Call gp_undo_redo @{operation='undo'} | Out-Null
    $restored = (Call gp_read_bars @{bar=0}).bars[0].voices[0].beats
    Check ($restored[0].text -eq 'P9 选区 - cue' -and $restored[1].text -eq 'P9 选区 - cue') 'Beat text selection clear undo failed.'

    Call gp_edit_beat @{operation='dynamic';scope='selection';dynamic='MF'} | Out-Null
    $dynamicBeats = (Call gp_read_bars @{bar=0;include_dynamic=$true}).bars[0].voices[0].beats
    Check ($dynamicBeats[0].dynamic -eq 'MF' -and $dynamicBeats[1].dynamic -eq 'MF') 'Beat dynamic write/readback failed.'
    Call gp_edit_beat @{operation='dynamic';scope='selection';dynamic='FF'} | Out-Null
    $dynamicBeats = (Call gp_read_bars @{bar=0;include_dynamic=$true}).bars[0].voices[0].beats
    Check ($dynamicBeats[0].dynamic -eq 'FF' -and $dynamicBeats[1].dynamic -eq 'FF') 'Beat dynamic second write failed.'
    Call gp_undo_redo @{operation='undo'} | Out-Null
    $dynamicBeats = (Call gp_read_bars @{bar=0;include_dynamic=$true}).bars[0].voices[0].beats
    Check ($dynamicBeats[0].dynamic -eq 'MF' -and $dynamicBeats[1].dynamic -eq 'MF') 'Beat dynamic undo failed.'
    Call gp_undo_redo @{operation='redo'} | Out-Null
    $dynamicBeats = (Call gp_read_bars @{bar=0;include_dynamic=$true}).bars[0].voices[0].beats
    Check ($dynamicBeats[0].dynamic -eq 'FF' -and $dynamicBeats[1].dynamic -eq 'FF') 'Beat dynamic redo failed.'
    Call gp_selection @{operation='clear'} | Out-Null
    Call gp_cursor @{axis='beat';index=0} | Out-Null
    foreach ($level in @('PPP','PP','P','MP','MF','F','FF','FFF')) {
        Call gp_edit_beat @{operation='dynamic';dynamic=$level} | Out-Null
        $dynamicBeats = (Call gp_read_bars @{bar=0;include_dynamic=$true}).bars[0].voices[0].beats
        Check ($dynamicBeats[0].dynamic -eq $level) "Beat dynamic $level write/readback failed (observed $($dynamicBeats[0].dynamic))."
    }
    Call gp_selection @{operation='clear'} | Out-Null
    Call gp_cursor @{axis='beat';index=0} | Out-Null
    Call gp_edit_beat @{operation='dynamic';dynamic='MF'} | Out-Null
    $dynamicBeats = (Call gp_read_bars @{bar=0;include_dynamic=$true}).bars[0].voices[0].beats
    Check ($dynamicBeats[0].dynamic -eq 'MF' -and $dynamicBeats[1].dynamic -eq 'FF') 'Beat dynamic cursor isolation failed.'
    Call gp_undo_redo @{operation='undo'} | Out-Null
    $dynamicBeats = (Call gp_read_bars @{bar=0;include_dynamic=$true}).bars[0].voices[0].beats
    Check ($dynamicBeats[0].dynamic -eq 'FFF' -and $dynamicBeats[1].dynamic -eq 'FF') 'Beat dynamic cursor undo failed.'
    Call gp_undo_redo @{operation='redo'} | Out-Null

    $clefResult = Call gp_edit_measure @{operation='clef';clef='F4'}
    Check ($clefResult.bar.clef -eq 'F4') 'Measure clef write/readback failed.'
    Call gp_edit_measure @{operation='clef';clef='G2'} | Out-Null
    Check (((Call gp_read_bars @{bar=0;include_clef=$true}).bars[0].clef) -eq 'G2') 'Measure clef second write failed.'
    Call gp_undo_redo @{operation='undo'} | Out-Null
    Check (((Call gp_read_bars @{bar=0;include_clef=$true}).bars[0].clef) -eq 'F4') 'Measure clef undo failed.'
    Call gp_undo_redo @{operation='redo'} | Out-Null
    Check (((Call gp_read_bars @{bar=0;include_clef=$true}).bars[0].clef) -eq 'G2') 'Measure clef redo failed.'
    Call gp_edit_measure @{operation='clef';clef='C3'} | Out-Null
    Check (((Call gp_read_bars @{bar=0;include_clef=$true}).bars[0].clef) -eq 'C3') 'Measure C3 clef write/readback failed.'
    Call gp_edit_measure @{operation='clef';clef='G2'} | Out-Null

    $saved = Call gp_save_as @{path=(Join-Path $run 'text.gp')}
    Check ($saved.path -and (Test-Path -LiteralPath $saved.path)) 'Beat text save failed.'
    $copy = Join-Path $run 'text-reopen.gp'
    Copy-Item -LiteralPath $saved.path -Destination $copy
    $reopen = Invoke-McpTool $connection gp_open @{path=$copy}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$reopen.request}).operation
        if ($state.status -in @('opened','error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq 'opened') "P9 text reopen failed: $(Json $state)"
    $reopenedId = $state.document
    $reopenedState = Invoke-McpTool $connection gp_read_bars @{document=$reopenedId;bar=0;include_dynamic=$true;include_clef=$true;include_stem=$true}
    $reopenedBeats = $reopenedState.bars[0].voices[0].beats
    Check ($reopenedBeats[0].text -eq 'P9 选区 - cue' -and $reopenedBeats[1].text -eq 'P9 选区 - cue') 'Beat text save/reopen differs.'
    Check ($reopenedBeats[0].dynamic -eq 'MF' -and $reopenedBeats[1].dynamic -eq 'FF' -and $reopenedState.bars[0].clef -eq 'G2') 'Beat dynamic or measure clef save/reopen differs.'
    Check ($reopenedBeats[0].stem.drawing -eq 'Upward' -and $reopenedBeats[0].stem.has_user_transposed) 'Stem orientation save/reopen differs.'
    $reopenedAutomation = Invoke-McpTool $connection gp_automation @{document=$reopenedId;track=0;operation='state'}
    Check (@($reopenedAutomation.tracks[0].automations | Where-Object name -eq 'Sound').Count -eq 1 -and @($reopenedAutomation.tracks[0].automations | Where-Object name -eq 'DSPParam_00').Count -eq 0) 'Automation save/reopen changed the Sound automation or removed-point state.'
    $close = Invoke-McpTool $connection gp_close @{document=$reopenedId;unsaved='discard'}
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$close.request}).operation
        if ($state.status -in @('closed','error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq 'closed') 'Reopened P9 document close failed.'
    Close-Document
    $complete = $true
    Write-Output "PASS: $checks P9 checks. Evidence: $run"
} finally {
    @{checks=$checks;complete=$complete;source=$source;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll" -ErrorAction SilentlyContinue).Hash} |
        ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    Close-McpSession $connection
}
