param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json", [switch]$VerifyRestart, [string]$Exe = 'C:\Program Files\Arobas Music\Guitar Pro 8\GuitarPro.exe')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-p10-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$checks = 0
$complete = $false
$hostLimited = @()
$restartPersistence = 'not_run'
$newDocumentDefaults = 'not_run'
$models = @{
    general = @('defaultTemplate','defaultStylesheet','pageMode','zoom','forceStylesheet','forcePageMode','forceZoom','forceNotation','forcePlayback','restoreOpenFile','embedAudioFiles')
    gui = @('autoOpenFxPopup','highlightBar','includeChordsInCopyPaste','playSoundWhileEditing','useMediaKeys','showFretlightButton','uiLanguage','cursorStyle','plusMinusKeyBehavior','showMSB','showExamples')
    score = @('barLengthError','hoPoError','outOfRangeError','tupletError','unreachableBarError')
    user_info = @('artist','lyrics','music','copyright','instructions','tab')
    midi = @('midiInput','selectedMidiOutputs','midiCaptureSensitivity')
}
function Check($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 40 -Compress }
function Has-Property($object, [string]$name) { return $null -ne ($object.PSObject.Properties | Where-Object Name -EQ $name) }
try {
    foreach ($model in $models.Keys) {
        $state = Invoke-McpTool $connection gp_preferences @{model=$model} -AllowError
        if ($state.status -eq 'host_limited') {
            $hostLimited += $model
            Check ($state.error -and $state.model -eq $model) "Host-limited P10 model did not explain its state: $model"
            continue
        }
        Check ($state.scope -eq 'application' -and $state.model -eq $model -and $state.property_info) "P10 state is missing scope or property_info: $model"
        foreach ($name in $models[$model]) {
            $info = $state.property_info.$name
            Check ($null -ne $info) "P10 state omitted allowlisted property_info: $model/$name"
            if (-not $info.available) { continue }
            if (-not $info.readable -or -not (Has-Property $state.values $name)) { continue }
            if ($info.writable) {
                $value = $state.values.$name
                $changed = Invoke-McpTool $connection gp_preferences @{model=$model;operation='set';property=$name;value=$value} -AllowError
                Check (-not $changed.error -and (Has-Property $changed.values $name) -and (Json $changed.values.$name) -eq (Json $value)) "P10 readback failed: $model/$name"
            }
        }
        $invalid = Invoke-McpTool $connection gp_preferences @{model=$model;operation='set';property='p10_unknown';value=$false} -AllowError
        Check ($invalid.error -match 'allowlist') "P10 accepted an unknown property: $model"
    }

    $audio = Invoke-McpTool $connection gp_audio_device @{operation='state'} -AllowError
    if ($audio.error) {
        $hostLimited += 'audio'
        Check ($audio.error -match 'unavailable|disabled|configuration') 'Audio state failure did not identify a host limitation.'
    } else {
        Check ($audio.scope -eq 'application' -and $audio.choices -and $audio.property_types) 'Audio state omitted choices or property types.'
        if (Has-Property $audio.configuration 'audioOutputChannels' -and $audio.choices.audioOutputChannels) {
            $channels = $audio.configuration.audioOutputChannels
            if ($channels -is [Array]) {
                foreach ($channel in $channels) { Check (@($audio.choices.audioOutputChannels | Where-Object { (Json $_) -eq (Json $channel) }).Count -gt 0) 'Audio output channel readback is outside host choices.' }
            } else {
                Check (@($audio.choices.audioOutputChannels | Where-Object { (Json $_) -eq (Json $channels) }).Count -gt 0) 'Audio output channel readback is outside host choices.'
            }
        }
        foreach ($property in @('audioDevice','audioInput','audioOutput','audioOutputChannels','audioBuffersSize')) {
            if (-not (Has-Property $audio.configuration $property) -or -not (Has-Property $audio.choices $property)) { continue }
            $audioSet = Invoke-McpTool $connection gp_audio_device @{operation='set';property=$property;value=$audio.configuration.$property} -AllowError
            Check (-not $audioSet.error -and (Json $audioSet.configuration.$property) -eq (Json $audio.configuration.$property)) "Audio same-value readback failed: $property"
        }
        $invalidAudio = Invoke-McpTool $connection gp_audio_device @{operation='set';property='p10_unknown';value='p10_unknown'} -AllowError
        Check ($invalidAudio.error -match 'property|exact value|choices') 'Audio accepted an unknown property.'
    }

    $score = Invoke-McpTool $connection gp_preferences @{model='score'} -AllowError
    if (-not $score.error -and $score.property_info) {
        foreach ($name in @('barLengthError','hoPoError','outOfRangeError','tupletError','unreachableBarError')) {
            Check ($null -ne $score.property_info.$name) "Score error preference missing from P10 state: $name"
        }
    }
    if ($VerifyRestart -and $hostLimited.Count -eq 0) {
        $restartState = Invoke-McpTool $connection gp_preferences @{model='general'}
        if (-not $restartState.property_info.forceNotation.available -or -not $restartState.property_info.forceNotation.writable) { throw 'No writable general preference is available for restart persistence.' }
        $restartBefore = [bool]$restartState.values.forceNotation
        $restartScore = @((Invoke-McpTool $connection gp_documents).documents | Where-Object opened_path | Select-Object -First 1).opened_path
        if (-not $restartScore) { throw 'Restart persistence requires an opened score path.' }
        $restartSet = Invoke-McpTool $connection gp_preferences @{model='general';operation='set';property='forceNotation';value=(-not $restartBefore)}
        Check ([bool]$restartSet.values.forceNotation -eq (-not $restartBefore)) 'Restart preference did not change before restart.'
        $restartPid = $connection.Pid
        try {
            $objects = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
            $main = @($objects.objects | Where-Object class -EQ 'gp::gui::MainWindow')[0]
            try { Invoke-McpTool $connection gp_close_window @{snapshot=$objects.snapshot;id=$main.id} -AllowError | Out-Null } catch {}
        } finally { try { Close-McpSession $connection } catch {} }
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ((Get-Process -Id $restartPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if (Get-Process -Id $restartPid -ErrorAction SilentlyContinue) {
            $hostLimited += 'restart_exit'
            $restartPersistence = 'host_limited'
        } else {
            & (Join-Path $root 'start-plugin.ps1') -Exe $Exe -ScorePath $restartScore -SessionFile $SessionFile -PassThru | Out-Null
            $connection = New-McpSession -SessionFile $SessionFile
            $restartAfter = Invoke-McpTool $connection gp_preferences @{model='general'}
            Check ([bool]$restartAfter.values.forceNotation -eq (-not $restartBefore)) 'General preference did not persist after restart.'
            $restored = Invoke-McpTool $connection gp_preferences @{model='general';operation='set';property='forceNotation';value=$restartBefore}
            Check ([bool]$restored.values.forceNotation -eq $restartBefore) 'Restart preference restore failed.'
            $restartPersistence = 'passed'

        $userState = Invoke-McpTool $connection gp_preferences @{model='user_info'}
        if ($userState.property_info.tab.available -and $userState.property_info.tab.writable) {
            $tabBefore = [string]$userState.values.tab
            $tabSentinel = 'P10-default-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            Invoke-McpTool $connection gp_preferences @{model='user_info';operation='set';property='tab';value=$tabSentinel} | Out-Null
            $creation = Invoke-McpTool $connection gp_new @{template='Empty'}
            $deadline = [DateTime]::UtcNow.AddSeconds(12)
            do {
                $created = (Invoke-McpTool $connection gp_operation @{request=$creation.request}).operation
                if ($created.status -in @('created','error','cancelled')) { break }
                Start-Sleep -Milliseconds 50
            } while ([DateTime]::UtcNow -lt $deadline)
            Check ($created.status -eq 'created') 'New document creation failed during P10 default inheritance check.'
            $newScore = Invoke-McpTool $connection gp_score @{document=$created.document}
            Check ($newScore.metadata.Tabber -eq $tabSentinel) 'New document did not inherit the user_info.tab default.'
            $closeNew = Invoke-McpTool $connection gp_close @{document=$created.document;unsaved='discard'}
            $deadline = [DateTime]::UtcNow.AddSeconds(12)
            do {
                $closed = (Invoke-McpTool $connection gp_operation @{request=$closeNew.request}).operation
                if ($closed.status -in @('closed','error','cancelled')) { break }
                Start-Sleep -Milliseconds 50
            } while ([DateTime]::UtcNow -lt $deadline)
            Check ($closed.status -eq 'closed') 'P10 default inheritance document cleanup failed.'
            Invoke-McpTool $connection gp_preferences @{model='user_info';operation='set';property='tab';value=$tabBefore} | Out-Null
            $newDocumentDefaults = 'passed'
        }
        }
    }
    $complete = $hostLimited.Count -eq 0 -and $restartPersistence -eq 'passed' -and $newDocumentDefaults -eq 'passed'
    @{complete=$complete;checks=$checks;host_limited=$hostLimited;restart_persistence=$restartPersistence;new_document_defaults=$newDocumentDefaults;sources=@('native/guitarpro_mcp.cpp','native/guitarpro_audio.h','test/test-p10.ps1','native/supported-host.json') | ForEach-Object { Get-FileHash (Join-Path $root $_) | Select-Object Path,Hash };plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll" -ErrorAction SilentlyContinue).Hash} |
        ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    Write-Output "PASS: $checks P10 checks. Host-limited: $($hostLimited -join ','); restart persistence: $restartPersistence; new-document defaults: $newDocumentDefaults. Evidence: $run"
} finally {
    Close-McpSession $connection
    if (-not (Test-Path (Join-Path $run 'verification.json'))) {
        @{complete=$false;checks=$checks;host_limited=$hostLimited;restart_persistence=$restartPersistence;new_document_defaults=$newDocumentDefaults} | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    }
}
