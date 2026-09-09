param([Parameter(Mandatory=$true)][string]$Exe, [switch]$CloseCleanDocuments, [switch]$AddDocumentDuringRecovery)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Exe = (Resolve-Path -LiteralPath $Exe).Path
if (-not $Exe.StartsWith(([IO.Path]::GetFullPath((Join-Path $root '.tools')) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Use an isolated host under .tools.' }
. "$PSScriptRoot/../native/mcp-client.ps1"
$probe = Join-Path $root '.tools/tab-fault-probe/plugins/generic/guitarpro_tab_fault_probe.dll'
if (-not (Test-Path -LiteralPath $probe)) { throw 'Build test/build-tab-fault-probe.ps1 first.' }
$run = Join-Path $root ('artifacts/tab-recovery-' + [guid]::NewGuid().ToString('N'))
$sessionFile = Join-Path $run 'session/native-session.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $sessionFile) | Out-Null
'gpmcp-tab-fault-test' | Set-Content -LiteralPath (Join-Path $run 'isolated-tab-fault-test') -Encoding ASCII
$fixture = Join-Path $PSScriptRoot 'testdata/minimal.gp'
$fixtureHash = (Get-FileHash -LiteralPath $fixture).Hash
$control = Join-Path $run 'control.json'
$checks = 0; $passed = $false; $observations = @(); $connection = $null; $process = $null
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
function Set-Fault([string]$mode = '', [string]$document = '') {
    $request = [guid]::NewGuid().ToString()
    [IO.File]::WriteAllText($control, (@{request=$request;mode=$mode;document=$document} | ConvertTo-Json -Compress), [Text.Encoding]::ASCII)
    if ($connection) {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $events = @(Get-Content -LiteralPath (Join-Path $run 'probe.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object request -EQ $request)
            if ($events.Count) { break }
            Start-Sleep -Milliseconds 25
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert (@($events | Where-Object event -EQ $(if ($mode) {'armed'} else {'disarmed'})).Count -eq 1) 'Fault probe did not accept the configuration.'
    }
    return $request
}
function Wait-Operation($request, [string]$expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if ($state.status -eq $expected -or ($state.status -in @('error','cancelled') -and -not $state.outcome_unknown)) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($state.status -eq $expected) 'Unexpected document operation outcome.'
    return $state
}
function Check-Order([string[]]$ids, [string]$active) {
    $state = Invoke-McpTool $connection gp_documents
    Assert ($state.tab_order_available -and ($state.documents.id -join ',') -eq ($ids -join ',')) 'Full document order differs.'
    Assert ($state.active_document -eq $active -and @($state.documents | Where-Object active).Count -eq 1) 'Active document differs.'
    for ($i = 0; $i -lt $ids.Count; $i++) { Assert ($state.documents[$i].tab_index -eq $i) 'Document index differs.' }
    return $state
}
$saved = @{}
foreach ($name in @('QT_PLUGIN_PATH','QT_QPA_GENERIC_PLUGINS','GPMCP_DATA_DIR','GPMCP_SESSION_FILE','GPMCP_BACKGROUND','GPMCP_TAB_FAULT_DIRECTORY','TEMP','TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
try {
    Set-Fault | Out-Null
    try {
        $env:QT_PLUGIN_PATH = (Join-Path $root '.tools/native/plugins') + ';' + (Join-Path $root '.tools/tab-fault-probe/plugins')
        $env:QT_QPA_GENERIC_PLUGINS = 'guitarpro_mcp,guitarpro_tab_fault_probe'
        $env:GPMCP_DATA_DIR = Split-Path -Parent $sessionFile
        $env:GPMCP_SESSION_FILE = $sessionFile
        $env:GPMCP_TAB_FAULT_DIRECTORY = $run
        $env:GPMCP_BACKGROUND = '1'
        $env:TEMP = $run; $env:TMP = $run
        $process = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $run 'host.stderr.log')
        $null = $process.Handle
    } finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') } }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if (Test-Path -LiteralPath $sessionFile) { break }
        if ($process.HasExited) { throw 'Fault-test host exited before connecting.' }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $connection = New-McpSession -SessionFile $sessionFile
    Assert ([bool](Get-Content -LiteralPath (Join-Path $run 'probe.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -EQ 'ready')) 'Fault probe did not load.'
    foreach ($mode in @('delay_open','delay_create','throw_after_open','throw_after_create')) {
        $kind = if ($mode.EndsWith('_open')) { 'open' } else { 'create' }
        $delayedCase = $mode.StartsWith('delay_')
        $path = Join-Path $run 'delayed.gp'
        if ($kind -eq 'open') { Copy-Item -LiteralPath $fixture -Destination $path }
        $fault = Set-Fault $mode
        $delayed = if ($kind -eq 'open') { Invoke-McpTool $connection gp_open @{path=$path} } else {
            $templates = Invoke-McpTool $connection gp_templates
            Invoke-McpTool $connection gp_new @{template=$templates.templates[0]}
        }
        $pending = $null
        if ($delayedCase) {
            $deadline = [DateTime]::UtcNow.AddSeconds(11)
            do {
                $pending = (Invoke-McpTool $connection gp_operation @{request=$delayed.request}).operation
                if ($pending.outcome_unknown) { break }
                Start-Sleep -Milliseconds 50
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert ($pending.status -eq 'error' -and $pending.outcome_unknown) 'Delayed native loading did not retain an unknown outcome.'
            Assert ((Invoke-McpTool $connection gp_close @{document=[guid]::NewGuid().ToString();unsaved='cancel'} -AllowError).error -like '*pending*') 'Unknown load outcome did not block mutations.'
            Assert ((Invoke-McpTool $connection gp_cancel @{request=$delayed.request} -AllowError).error) 'An unobserved native load was falsely cancelled.'
            Assert ((Invoke-McpTool $connection gp_recover @{request=$delayed.request} -AllowError).error) 'Recovery cleared a load whose result was not observed.'
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            $completed = (Invoke-McpTool $connection gp_operation @{request=$delayed.request}).operation
            if ($completed.status -eq $(if($kind -eq 'open'){'opened'}else{'created'})) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert ($completed.document -and -not $completed.outcome_unknown -and $completed.status -eq $(if($kind -eq 'open'){'opened'}else{'created'})) 'Late native completion was not reconciled.'
        $documents = (Invoke-McpTool $connection gp_documents).documents
        Assert ($documents.Count -eq 1 -and $documents[0].id -eq $completed.document) 'Late completion created duplicate documents.'
        $events = @(Get-Content -LiteralPath (Join-Path $run 'probe.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object request -EQ $fault)
        if ($delayedCase) {
            Assert (@($events | Where-Object event -EQ 'deferred').Count -eq 1 -and @($events | Where-Object event -EQ 'delivered').Count -eq 1) 'Native file event was not delivered exactly once.'
        } else {
            Assert ($completed.native_error -and @($events | Where-Object event -EQ 'native_exception').Count -eq 1) 'Native exception was not retained with the real completed outcome.'
        }
        $observations += @{kind=$kind;mode=$mode;unknown=$pending;completed=$completed;events=$events}
        Set-Fault | Out-Null
        Invoke-McpTool $connection gp_edit_metadata @{document=$completed.document;property='Title';value='Edit after late native completion'} | Out-Null
        $copy = Join-Path $run ($mode + '-completion.gp')
        Invoke-McpTool $connection gp_save_as @{document=$completed.document;path=$copy} | Out-Null
        $close = Invoke-McpTool $connection gp_close @{document=$completed.document}
        Wait-Operation $close.request 'closed' | Out-Null
        $reopen = Invoke-McpTool $connection gp_open @{path=$copy}
        $reopened = (Wait-Operation $reopen.request 'opened').document
        Assert ((Invoke-McpTool $connection gp_score @{document=$reopened}).metadata.Title -eq 'Edit after late native completion') 'Late completion broke subsequent editing and saving.'
        if ($mode -eq 'throw_after_create') { $closeFault = Set-Fault 'throw_close' }
        $close = Invoke-McpTool $connection gp_close @{document=$reopened}
        $closed = Wait-Operation $close.request 'closed'
        if ($mode -eq 'throw_after_create') {
            Assert ($closed.native_error -and -not $closed.outcome_unknown -and (Invoke-McpTool $connection gp_documents).documents.Count -eq 0) 'Native close exception did not reconcile the closed document.'
            Assert ((Invoke-McpTool $connection gp_score @{document=$reopened} -AllowError).error) 'Closed document remains addressable after a native exception.'
            $observations += @{mode='throw_close';operation=$closed}
            Set-Fault | Out-Null
        }
    }
    foreach ($kind in @('open','create')) {
        $fault = Set-Fault ('error_' + $kind)
        $failedLoad = if ($kind -eq 'open') { Invoke-McpTool $connection gp_open @{path=(Join-Path $run 'delayed.gp')} } else {
            Invoke-McpTool $connection gp_new @{template=$templates.templates[0]}
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $dialog = Invoke-McpTool $connection gp_dialogs
            if ($dialog.blocked) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert ($dialog.blocked -and $dialog.title -eq 'Isolated load error' -and @($dialog.buttons | Where-Object standard_button -EQ 4194304).Count -eq 0) 'Expected the injected load error with no Cancel decision.'
        $dismissed = Invoke-McpTool $connection gp_cancel @{request=$failedLoad.request}
        Assert ($dismissed.status -eq 'cancelling' -and -not $dismissed.cancel_decision_available) 'Error dialog dismissal claimed a Cancel decision.'
        $failure = Wait-Operation $failedLoad.request 'error'
        Assert (-not $failure.outcome_unknown -and (Invoke-McpTool $connection gp_documents).documents.Count -eq 0) 'Load error was not reconciled as a confirmed failure.'
        Assert ((Invoke-McpTool $connection gp_cancel @{request=$failedLoad.request} -AllowError).error) 'Completed load failure was cancelled again.'
        $observations += @{mode=('error_' + $kind);dialog=$dialog;operation=$failure}
        Set-Fault | Out-Null
    }
    $ids = @(); $paths = @{}; $titles = @{}
    foreach ($i in 0..3) {
        $path = Join-Path $run ("source-$i.gp")
        Copy-Item -LiteralPath $fixture -Destination $path
        $open = Invoke-McpTool $connection gp_open @{path=$path}
        $id = (Wait-Operation $open.request 'opened').document
        $ids += $id; $paths[$id] = $path; $titles[$id] = "Tab recovery document $i"
        Invoke-McpTool $connection gp_edit_metadata @{document=$id;property='Title';value=$titles[$id]} | Out-Null
    }
    foreach ($mode in @('extra_reorder','switch_active','throw','throw_active','throw_recovery')) {
        Set-Fault | Out-Null
        $active = if ($mode -eq 'throw_active') { $ids[0] } else { $ids[1] }
        Invoke-McpTool $connection gp_activate @{document=$active} | Out-Null
        $before = Check-Order $ids $active
        if ($mode -eq 'throw_recovery') {
            foreach ($id in $ids) { Invoke-McpTool $connection gp_save_current @{document=$id} | Out-Null }
            $dirtyIds = if ($CloseCleanDocuments) { @($ids[0]) } else { $ids }
            foreach ($id in $dirtyIds) { Invoke-McpTool $connection gp_edit_metadata @{document=$id;property='Artist';value='Keep through recovery'} | Out-Null }
            Invoke-McpTool $connection gp_activate @{document=$active} | Out-Null
            $before = Check-Order $ids $active
        }
        $request = Set-Fault $(if ($mode -eq 'throw_active') {'throw'} else {$mode}) $ids[0]
        $result = Invoke-McpTool $connection gp_move_document @{document=$ids[0];index=2} -AllowError
        $events = @(Get-Content -LiteralPath (Join-Path $run 'probe.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object request -EQ $request)
        $observations += @{mode=$mode;before=$before;result=$result;events=$events;after=(Invoke-McpTool $connection gp_documents)}
        Assert ([bool]$result.error) 'Native tab fault unexpectedly reported a successful move.'
        Assert (@($events | Where-Object event -EQ 'fault').Count -eq $(if ($mode -eq 'throw_recovery') {2} else {1})) 'Fault did not fire the expected number of times.'
        Assert ([bool]$result.native_exception -eq $mode.StartsWith('throw')) 'Native exception classification differs.'
        $after = Check-Order $ids $active
        foreach ($doc in $before.documents) {
            $actual = $after.documents | Where-Object id -EQ $doc.id
            Assert ($actual.dirty -eq $doc.dirty -and $actual.opened_path -eq $doc.opened_path -and $actual.save_path -eq $doc.save_path) 'Rollback changed document state.'
            Assert ((Invoke-McpTool $connection gp_score @{document=$doc.id}).metadata.Title -eq $titles[$doc.id]) 'Rollback changed score content.'
        }
        $operation = (Invoke-McpTool $connection gp_operation @{request=$result.request}).operation
        Assert ($operation.kind -eq 'move' -and $operation.status -eq 'error' -and $operation.result.error -eq $result.error) 'Move failure is not tracked.'
        if ($mode -eq 'throw_recovery') {
            Assert (-not $result.rolled_back -and $result.outcome_unknown -and $operation.outcome_unknown -and $result.recovery_error) 'Recovery exception falsely reported a completed rollback.'
            Assert ((Invoke-McpTool $connection gp_edit_metadata @{document=$ids[0];property='Artist';value='Must not apply'} -AllowError).error) 'Unknown tab outcome permitted a mutation.'
            Assert ((Invoke-McpTool $connection gp_move_document @{document=$ids[0];index=1} -AllowError).error) 'Unknown tab outcome permitted another move.'
            $stacks = Invoke-McpTool $connection gp_objects @{query='QStackedWidget';limit=100}
            $stack = @($stacks.objects | Where-Object { $_.pages.Count -eq 4 -and $_.pages[0].class -eq 'gp::gui::IDocumentView' })
            Assert ($stack.Count -eq 1) 'Could not identify the native document stack.'
            $property = Invoke-McpTool $connection gp_set_property @{snapshot=$stacks.snapshot;id=$stack[0].id;property='currentIndex';value=$stack[0].properties.currentIndex} -AllowError
            Assert ($property.error -like '*operation is pending*') 'Native property writing bypassed the unknown-outcome guard.'
            $actions = Invoke-McpTool $connection gp_actions @{query='Undo';limit=100}
            Assert ($actions.objects.Count -gt 0) 'Could not identify a native undo action.'
            $trigger = Invoke-McpTool $connection gp_trigger @{snapshot=$actions.snapshot;id=$actions.objects[0].id} -AllowError
            Assert ($trigger.error -like '*operation is pending*') 'Native action triggering bypassed the unknown-outcome guard.'
            Assert ((Invoke-McpTool $connection gp_cancel @{request=$result.request} -AllowError).error) 'A completed native move was falsely cancelled.'
            Assert ((Invoke-McpTool $connection gp_operation @{request=$result.request}).operation.outcome_unknown) 'Cancellation cleared an unresolved native outcome.'
            Assert ($operation.recovery_available -and $result.recovery_available) 'The failed rollback has no retained recovery context.'
            Assert ((Invoke-McpTool $connection gp_recover @{request=[guid]::NewGuid().ToString()} -AllowError).error) 'An unrelated recovery request was accepted.'
            Set-Fault 'throw' $ids[0] | Out-Null
            $failedRecovery = Invoke-McpTool $connection gp_recover @{request=$result.request} -AllowError
            $stillPending = (Invoke-McpTool $connection gp_operation @{request=$result.request}).operation
            Assert ($failedRecovery.error -and $failedRecovery.outcome_unknown -and $stillPending.outcome_unknown -and $stillPending.recovery_available -and $stillPending.recovery_attempts -eq 1) 'A repeated recovery exception cleared the guard or lost its context.'
            Set-Fault | Out-Null
            $window = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
            $main = @($window.objects | Where-Object class -EQ 'gp::gui::MainWindow')
            Invoke-McpTool $connection gp_close_window @{snapshot=$window.snapshot;id=$main[0].id} | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            do {
                $dialog = Invoke-McpTool $connection gp_dialogs
                if ($dialog.blocked) { break }
                Start-Sleep -Milliseconds 50
            } while ([DateTime]::UtcNow -lt $deadline)
            $cancel = @($dialog.buttons | Where-Object standard_button -EQ 4194304)
            Assert ($dialog.blocked -and $cancel.Count -eq 1) 'Expected a native close confirmation during recovery.'
            Assert ((Invoke-McpTool $connection gp_recover @{request=$result.request} -AllowError).error) 'Recovery entered an active native dialog.'
            $buttons = Invoke-McpTool $connection gp_objects @{query=$cancel[0].text;limit=100}
            $button = @($buttons.objects | Where-Object { $_.button -and $_.enabled -and $_.visible -and $_.properties.text -eq $cancel[0].text })
            Assert ($button.Count -eq 1) 'Could not identify the native Cancel button.'
            Invoke-McpTool $connection gp_trigger @{snapshot=$buttons.snapshot;id=$button[0].id} | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                if (-not (Invoke-McpTool $connection gp_dialogs).blocked) { break }
                Start-Sleep -Milliseconds 50
            } while ([DateTime]::UtcNow -lt $deadline)
            $addedId = $null
            if ($AddDocumentDuringRecovery) {
                $extraPath = Join-Path $run 'manual-open-during-recovery.gp'
                Copy-Item -LiteralPath $fixture -Destination $extraPath
                Set-Fault 'open_external' $extraPath | Out-Null
                $deadline = [DateTime]::UtcNow.AddSeconds(8)
                do {
                    $added = @((Invoke-McpTool $connection gp_documents).documents | Where-Object { $_.id -notin $ids })
                    if ($added.Count -eq 1) { break }
                    Start-Sleep -Milliseconds 50
                } while ([DateTime]::UtcNow -lt $deadline)
                Assert ($added.Count -eq 1 -and -not $added[0].dirty) 'Native file open did not add a clean document during recovery.'
                $addedId = $added[0].id
                Set-Fault | Out-Null
            }
            $recovery = Invoke-McpTool $connection gp_recover @{request=$result.request}
            $recovered = (Invoke-McpTool $connection gp_operation @{request=$result.request}).operation
            $observations += @{mode='explicit-recovery';failed=$failedRecovery;recovery=$recovery;operation=$recovered}
            Assert ($recovery.status -eq 'recovered' -and $recovered.recovered -and -not $recovered.outcome_unknown -and -not $recovered.recovery_available -and $recovered.recovery_attempts -eq 2) 'Explicit recovery did not verify and release the original request.'
            Assert ($recovered.status -eq 'error' -and $recovered.result.error -eq $result.error -and $recovered.result.outcome_unknown -and $recovered.recovery.status -eq 'recovered') 'Recovery rewrote the original failed result.'
            if ($AddDocumentDuringRecovery) {
                Assert (-not $recovery.rolled_back -and $recovery.resolution -eq 'documents_changed' -and $recovery.added_documents.Count -eq 1 -and $recovery.added_documents[0] -eq $addedId) 'Added document was not reconciled accurately.'
                $remainingIds = @($(if ($CloseCleanDocuments) {$ids[0]} else {$ids})) + @($addedId)
                $remainingActive = $addedId
            } elseif ($CloseCleanDocuments) {
                Assert (-not $recovery.rolled_back -and $recovery.resolution -eq 'documents_closed' -and ($recovery.closed_documents -join ',') -eq ($ids[1..3] -join ',')) 'Closed documents were not reconciled accurately.'
                $remainingIds = @($ids[0]); $remainingActive = $ids[0]
            } else {
                Assert ($recovery.rolled_back -and $recovery.resolution -eq 'rolled_back') 'Recovery did not restore the original tab state.'
                $remainingIds = $ids; $remainingActive = $active
            }
            Check-Order $remainingIds $remainingActive | Out-Null
            $score = Invoke-McpTool $connection gp_score @{document=$ids[0]}
            Assert ($score.dirty -and $score.metadata.Artist -eq 'Keep through recovery') 'Recovery lost unsaved edits.'
            Assert ((Invoke-McpTool $connection gp_recover @{request=$result.request} -AllowError).error) 'Completed recovery was replayed.'
            Invoke-McpTool $connection gp_edit_metadata @{document=$ids[0];property='Artist';value='Recovered edit'} | Out-Null
            $copyPath = Join-Path $run 'explicit-recovery.gp'
            Invoke-McpTool $connection gp_save @{document=$ids[0];path=$copyPath} | Out-Null
            $open = Invoke-McpTool $connection gp_open @{path=$copyPath}
            $reopened = (Wait-Operation $open.request 'opened').document
            Assert ((Invoke-McpTool $connection gp_score @{document=$reopened}).metadata.Artist -eq 'Recovered edit') 'Editing and saving after recovery did not persist.'
            $close = Invoke-McpTool $connection gp_close @{document=$reopened}
            Wait-Operation $close.request 'closed' | Out-Null
            foreach ($id in $remainingIds) { Invoke-McpTool $connection gp_save_current @{document=$id} | Out-Null }
            Invoke-McpTool $connection gp_move_document @{document=$ids[0];index=($remainingIds.Count - 1)} | Out-Null
            $archived = (Invoke-McpTool $connection gp_operation @{request=$result.request}).operation
            Assert ($archived.recovered -and $archived.recovery.status -eq 'recovered') 'A later operation lost recovery history.'
            Assert ((Invoke-McpTool $connection gp_recover @{request=$result.request} -AllowError).error) 'Archived recovery was replayed.'
            Invoke-McpTool $connection gp_move_document @{document=$ids[0];index=0} | Out-Null
            break
        }
        Assert ($result.rolled_back -and -not $result.outcome_unknown -and -not $operation.outcome_unknown) 'Native fault did not finish with a verified rollback.'
        Assert ((Invoke-McpTool $connection gp_recover @{request=$result.request} -AllowError).error) 'A completed rollback was recovered again.'
        Set-Fault | Out-Null
        foreach ($id in $ids) {
            Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='undo'} | Out-Null
            Assert ((Invoke-McpTool $connection gp_score @{document=$id}).metadata.Title -ne $titles[$id]) 'Rollback broke native undo.'
            Invoke-McpTool $connection gp_undo_redo @{document=$id;operation='redo'} | Out-Null
            Assert ((Invoke-McpTool $connection gp_score @{document=$id}).metadata.Title -eq $titles[$id]) 'Rollback broke native redo.'
            Assert ((Get-FileHash -LiteralPath $paths[$id]).Hash -eq $fixtureHash) 'Tab operation wrote a source file.'
            $copyPath = Join-Path $run ("$mode-$id.gp")
            $copy = Invoke-McpTool $connection gp_save @{document=$id;path=$copyPath}
            Assert ($copy.copy_only -and $copy.dirty) 'Saving a recovered document copy changed unsaved state.'
            $open = Invoke-McpTool $connection gp_open @{path=$copyPath}
            $reopened = (Wait-Operation $open.request 'opened').document
            Assert ($reopened -notin $ids -and (Invoke-McpTool $connection gp_score @{document=$reopened}).metadata.Title -eq $titles[$id]) 'Recovered document did not save and reopen with its own content.'
            $close = Invoke-McpTool $connection gp_close @{document=$reopened}
            Wait-Operation $close.request 'closed' | Out-Null
        }
        $retry = Invoke-McpTool $connection gp_move_document @{document=$ids[0];index=2}
        Assert ($retry.status -eq 'moved') 'Move after recovered failure was rejected.'
        Check-Order @($ids[1],$ids[2],$ids[0],$ids[3]) $ids[3] | Out-Null
        Invoke-McpTool $connection gp_move_document @{document=$ids[0];index=0} | Out-Null
        Assert ((Invoke-McpTool $connection gp_operation @{request=$result.request}).operation.result.rolled_back) 'A later move lost the failure record.'
    }
    if (-not $CloseCleanDocuments -and -not $AddDocumentDuringRecovery) {
        Set-Fault 'throw_recovery' $ids[0] | Out-Null
        $unknownMove = Invoke-McpTool $connection gp_move_document @{document=$ids[0];index=2} -AllowError
        Assert ($unknownMove.outcome_unknown -and $unknownMove.recovery_available) 'Expected an unresolved move before native close-all.'
        Set-Fault 'close_external' | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $empty = Invoke-McpTool $connection gp_documents
            if ($empty.documents.Count -eq 0) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert ($empty.documents.Count -eq 0 -and $empty.tab_order_available) 'Native close-all retained a document.'
        Set-Fault | Out-Null
        $reconciled = Invoke-McpTool $connection gp_recover @{request=$unknownMove.request}
        Assert ($reconciled.status -eq 'recovered' -and $reconciled.resolution -eq 'documents_closed' -and -not $reconciled.rolled_back -and $reconciled.closed_documents.Count -eq 4) 'Recovery failed to reconcile all original documents being closed.'
        $observations += @{mode='all_documents_closed';recovery=$reconciled}
        $open = Invoke-McpTool $connection gp_open @{path=$paths[$ids[0]]}
        $reopened = (Wait-Operation $open.request 'opened').document
        Assert ($reopened -notin $ids -and (Invoke-McpTool $connection gp_score @{document=$reopened}).metadata.Artist -eq 'Recovered edit') 'Opening after close-all recovery lost identity or saved content.'
        $close = Invoke-McpTool $connection gp_close @{document=$reopened}
        Wait-Operation $close.request 'closed' | Out-Null
    }
    Assert (@((Invoke-McpTool $connection gp_documents).documents | Where-Object dirty).Count -eq 0) 'Recovery test left unsaved data before exit.'
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.hidden_mode -and $identity.foreground_pid -ne $identity.pid) 'Tab recovery took foreground focus.'
    $window = Invoke-McpTool $connection gp_objects @{query='MainWindow';limit=100}
    $main = @($window.objects | Where-Object class -EQ 'gp::gui::MainWindow')
    try { Invoke-McpTool $connection gp_close_window @{snapshot=$window.snapshot;id=$main[0].id} | Out-Null }
    catch { if (-not $process.WaitForExit(5000)) { throw } }
    Assert ($process.WaitForExit(15000) -and $process.ExitCode -eq 0) 'Recovery host did not exit cleanly.'
    Assert (-not (Test-Path -LiteralPath $sessionFile)) 'Recovery host retained its descriptor.'
    $passed = $true
} finally {
    $connectionForReset = $connection; $connection = $null
    Set-Fault | Out-Null
    $connection = $connectionForReset
    if ($connection -and $process -and -not $process.HasExited) { Close-McpSession $connection }
    @{passed=$passed;checks=$checks;observations=$observations;host_pid=$(if($process){$process.Id});session_file=$sessionFile;exit_code=$(if($process -and $process.HasExited){$process.ExitCode});powershell=$PSVersionTable.PSVersion.ToString();plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash;probe_sha256=(Get-FileHash $probe).Hash;late_native_load_reconciliation_verified=$passed;changed_document_set_verified=($passed -and $AddDocumentDuringRecovery.IsPresent);tab_rollback_verified=$passed;recovery_exception_guard_verified=$passed;explicit_recovery_verified=$passed;closed_document_reconciliation_verified=($passed -and $CloseCleanDocuments.IsPresent)} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    if ($process) {
        if (-not $process.HasExited) { Write-Warning "Tab recovery host retained: PID $($process.Id), session $sessionFile" }
        $process.Dispose()
    }
}
Write-Output "PASS: $checks tab rollback, identity, undo, retry and unknown-outcome checks. Evidence: $run"
