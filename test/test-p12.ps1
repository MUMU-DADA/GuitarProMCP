param(
    [string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-p12-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$second = New-McpSession -SessionFile $SessionFile
$checks = 0; $complete = $false; $matrix = @(); $captures = @()
$descriptor = Read-McpInstance -SessionFile $SessionFile
$process = Get-Process -Id $connection.Pid
function Check($condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
function Record([string]$scenario, [string]$status, [string]$details) {
    $script:matrix += @{scenario=$scenario;status=$status;details=$details}
}
function Wait-Operation($operation, [string]$expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $state = (Invoke-McpTool $connection gp_operation @{request=$operation.request}).operation
        if ($state.status -in @($expected,'error','cancelled')) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq $expected) "Operation did not reach ${expected}: $($state | ConvertTo-Json -Depth 4 -Compress)"
    return $state
}
function Windows([bool]$includeHidden = $true) {
    $w = Invoke-McpTool $connection gp_windows @{include_hidden=$includeHidden}
    Check ($w.instance_id -eq $connection.InstanceId -and $w.pid -eq $connection.Pid -and $w.scope -eq 'qt_windows') 'Window scope or instance mismatch.'
    Check (-not $w.truncated -and $w.count_scope -eq 'complete_qt_set') 'Real host window enumeration was incomplete.'
    Check ($w.total_count -eq $w.visible_count + $w.hidden_count -and $w.returned_count -eq @($w.windows).Count) 'Window counts do not add up.'
    Check (@($w.windows.window_id | Sort-Object -Unique).Count -eq @($w.windows).Count) 'Duplicate window IDs.'
    if ($includeHidden) {
        Check ($w.returned_count -eq $w.total_count) 'Default list omitted hidden windows.'
        foreach ($item in $w.windows) {
            Check (-not $item.parent_window_id -or $item.parent_window_id -in $w.windows.window_id) 'Parent ID is not in the full window set.'
            Check ($item.modality -in @('non_modal','window_modal','application_modal')) 'Invalid modality.'
        }
    } else { Check (@($w.windows | Where-Object { -not $_.visible }).Count -eq 0) 'Hidden window passed the visible filter.' }
    return $w
}
function Raw-Screenshot([hashtable]$arguments, $session = $connection) {
    $body = @{jsonrpc='2.0';id=2;method='tools/call';params=@{name='gp_screenshot';arguments=$arguments}} | ConvertTo-Json -Depth 8 -Compress
    $rpc = Invoke-RestMethod -Uri $session.Url -Method Post -Headers $session.Headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15
    if ($rpc.error) { throw ($rpc.error | ConvertTo-Json -Compress) }
    return $rpc.result
}
function State {
    $cap = Invoke-McpTool $connection gp_capabilities
    $docs = Invoke-McpTool $connection gp_documents
    $scores = @($docs.documents | ForEach-Object {
        Invoke-McpTool $connection gp_score @{document=$_.id} | Select-Object document,dirty,undo_available,redo_available,metadata,cursor
    })
    $w = Invoke-McpTool $connection gp_windows
    return @{foreground=$cap.foreground_window.handle;pid=$cap.foreground_pid;documents=$docs.documents;active=$docs.active_document;scores=$scores;
        windows=@($w.windows | Sort-Object window_id | Select-Object window_id,parent_window_id,geometry,visible,minimized,maximized,fullscreen,active,modality,active_modal)}
}
function Capture([string]$label, [string]$windowId = '', [switch]$Default) {
    $before = State
    $args = if ($Default) { @{} } else { @{window_id=$windowId} }
    $raw = Raw-Screenshot $args
    $meta = $raw.structuredContent
    $images = @($raw.content | Where-Object type -EQ 'image')
    Check (-not $raw.isError -and $meta.status -eq 'experimental' -and $images.Count -eq 1) "$label did not capture: $($meta | ConvertTo-Json -Compress -Depth 4)"
    Check ($meta.instance_id -eq $connection.InstanceId -and $meta.pid -eq $connection.Pid) "$label captured a different instance."
    if (-not $Default) { Check ($meta.window_id -eq $windowId) "$label substituted a different target." }
    Check ($meta.capture_mode -eq 'qt_widget_render' -and $meta.capture_ms -le 2000) "$label used an unexpected capture path."
    Check (-not ($meta.PSObject.Properties.Name -contains '__mcp_image') -and $images[0].mimeType -eq 'image/png') "$label has invalid MCP content."
    $bytes = [Convert]::FromBase64String($images[0].data)
    $path = Join-Path $run "$label.png"
    [IO.File]::WriteAllBytes($path, $bytes)
    $bitmap = [Drawing.Bitmap]::new($path)
    try {
        Check ($bitmap.Width -eq $meta.width -and $bitmap.Height -eq $meta.height) "$label PNG dimensions differ from metadata."
        Check ($meta.width -eq [Math]::Floor($meta.geometry.width*$meta.device_pixel_ratio+0.5) -and $meta.height -eq [Math]::Floor($meta.geometry.height*$meta.device_pixel_ratio+0.5)) "$label logical and pixel sizes disagree."
        $colors = [Collections.Generic.HashSet[int]]::new()
        for ($y=0; $y -lt $bitmap.Height; $y += [Math]::Max(1,[int]($bitmap.Height/50))) {
            for ($x=0; $x -lt $bitmap.Width; $x += [Math]::Max(1,[int]($bitmap.Width/70))) { $null=$colors.Add($bitmap.GetPixel($x,$y).ToArgb()) }
        }
        Check ($colors.Count -gt 8) "$label image lacks distinguishable content."
    } finally { $bitmap.Dispose() }
    $after = State
    @{before=$before;after=$after} | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $run "$label-state.json") -Encoding utf8
    Check (($before | ConvertTo-Json -Depth 30 -Compress) -eq ($after | ConvertTo-Json -Depth 30 -Compress)) "$label changed focus, window state, document state or undo/redo."
    $meta | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $run "$label.json") -Encoding utf8
    $script:captures += @{label=$label;window_id=$meta.window_id;class=$meta.target_class;sha256=(Get-FileHash $path).Hash}
    return $meta
}
function Reject([string]$id, [string]$reason) {
    $raw = Raw-Screenshot @{window_id=$id} $second
    Check ($raw.isError -and $raw.structuredContent.reason -eq $reason -and @($raw.content | Where-Object type -EQ 'image').Count -eq 0) "Invalid ID did not fail without image: $reason"
}
function Trigger([string]$name) {
    $a = Invoke-McpTool $connection gp_actions @{query=$name;limit=100}
    $action = @($a.objects | Where-Object object_name -EQ $name)
    Check ($action.Count -eq 1 -and $action[0].enabled) "Native action is unavailable: $name"
    Invoke-McpTool $connection gp_trigger @{snapshot=$a.snapshot;id=$action[0].id} | Out-Null
}
try {
    $initial = Invoke-McpTool $connection gp_documents
    $artifactRoot = [IO.Path]::GetFullPath((Join-Path $root 'artifacts')) + [IO.Path]::DirectorySeparatorChar
    Check ([IO.Path]::GetFullPath($descriptor.host_exe).StartsWith([IO.Path]::GetFullPath((Join-Path $root '.tools')) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'P12 requires an isolated host under .tools.'
    foreach ($doc in $initial.documents) {
        Check (-not $doc.dirty -and $doc.opened_path -and [IO.Path]::GetFullPath($doc.opened_path).StartsWith($artifactRoot,[StringComparison]::OrdinalIgnoreCase)) 'Only clean artifact documents may be used by this test.'
    }
    $originalFiles = @($initial.documents | ForEach-Object { @{path=$_.opened_path;hash=(Get-FileHash -LiteralPath $_.opened_path).Hash} })
    $initialWindows = Windows
    $initialMain = @($initialWindows.windows | Where-Object kind -EQ 'main')[0]
    $mainId = $initialMain.window_id
    $initialWindows | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run 'initial-windows.json') -Encoding utf8
    $visible = Windows $false
    Check ($visible.total_count -eq $initialWindows.total_count -and $visible.visible_count -eq $visible.returned_count) 'Hidden filter altered the counts.'
    $clientList = Invoke-McpTool $second gp_windows
    Check (($initialWindows.windows.window_id -join ',') -eq ($clientList.windows.window_id -join ',')) 'Clients received different window identities.'
    Invoke-McpTool $second gp_objects @{query='MainWindow';limit=50} | Out-Null
    Invoke-McpTool $connection gp_actions @{query='actionShowVirtual';limit=50} | Out-Null
    Check ((Windows).windows.window_id -contains $mainId) 'Object/action snapshots invalidated window IDs.'
    foreach ($invalid in @('','bad-id',($connection.InstanceId+':window:0'))) { Reject $invalid 'invalid_window_id' }
    Reject ($mainId+"`n") 'invalid_window_id'
    Reject ($connection.InstanceId+':window:999999999') 'window_not_found'
    Reject (([guid]::NewGuid().ToString())+':window:1') 'foreign_instance'
    Record 'identity_and_clients' 'verified' 'Stable IDs, hidden counts, independent object snapshots, two interleaved clients, malformed/unknown/foreign IDs; errors have no image.'
    $menu = @($initialWindows.windows | Where-Object object_name -EQ 'menuFile')[0]
    if ($menu) {
        $beforeMenu = State
        $rawMenu = Raw-Screenshot @{window_id=$menu.window_id}
        if ($rawMenu.structuredContent.reason -eq 'unprepared_hidden_window') {
            Check ($rawMenu.isError -and @($rawMenu.content | Where-Object type -EQ 'image').Count -eq 0) 'Unprepared menu produced an image.'
            Check (($beforeMenu | ConvertTo-Json -Depth 30 -Compress) -eq ((State) | ConvertTo-Json -Depth 30 -Compress)) 'Rejected menu capture changed layout/state.'
            Record 'unprepared_popup' 'host_limited' 'Hidden menuFile has not been laid out by the host; rejected before Qt can resize it, with no image or state change.'
        } else { Record 'unprepared_popup' 'unverified' 'menuFile was already prepared by the host; fresh unprepared menu is covered by the Qt fixture.' }
    }

    $fixture = Join-Path $run 'p12.gp'
    Copy-Item "$PSScriptRoot/testdata/minimal.gp" $fixture
    $opened = Wait-Operation (Invoke-McpTool $connection gp_open @{path=$fixture}) 'opened'
    $document = $opened.document
    Invoke-McpTool $connection gp_window @{state='restore'} | Out-Null
    foreach ($pair in @(@('virtualKeyboard','actionShowVirtualKeyboard'),@('virtualFretboard','actionShowVirtualFretboard'))) {
        $existing = @((Windows).windows | Where-Object object_name -EQ $pair[0])
        if (-not $existing.Count -or -not $existing[0].visible) { Trigger $pair[1] }
    }
    $multi = Windows
    $keyboard = @($multi.windows | Where-Object object_name -EQ 'virtualKeyboard')[0]
    $fretboard = @($multi.windows | Where-Object object_name -EQ 'virtualFretboard')[0]
    Check ($keyboard.visible -and $fretboard.visible -and $keyboard.window_id -ne $fretboard.window_id) 'Two native floating windows did not coexist.'
    Check ($keyboard.parent_window_id -eq $mainId -and $fretboard.parent_window_id -eq $mainId -and $keyboard.kind -eq 'tool' -and $fretboard.kind -eq 'tool') 'Native floating parent/kind mismatch.'
    $multi | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run 'multiple-windows.json') -Encoding utf8
    Capture 'main' $mainId | Out-Null
    Capture 'keyboard' $keyboard.window_id | Out-Null
    Capture 'fretboard' $fretboard.window_id | Out-Null
    $default = Capture 'default-main' -Default
    Check ($default.window_id -eq $mainId -and $default.target_window -eq 'main') 'Default main selection changed.'
    Record 'native_multiple_windows' 'verified' 'MainWindow, VirtualKeyboardDockWidget and VirtualFretboardDockWidget coexist; each captured by ID with its dimensions and content.'
    $obj = Invoke-McpTool $connection gp_objects @{query='virtualKeyboard';limit=100}
    $kw = @($obj.objects | Where-Object class -EQ 'gp::gui::VirtualKeyboardDockWidget')[0]
    Invoke-McpTool $connection gp_close_window @{snapshot=$obj.snapshot;id=$kw.id} | Out-Null
    $hiddenKeyboard = @((Windows).windows | Where-Object window_id -EQ $keyboard.window_id)
    Check ($hiddenKeyboard.Count -eq 1 -and -not $hiddenKeyboard[0].visible) 'Closing the native floating window did not preserve its hidden object.'
    Capture 'keyboard-hidden' $keyboard.window_id | Out-Null
    Trigger 'actionShowVirtualKeyboard'
    Check (@((Windows).windows | Where-Object { $_.window_id -eq $keyboard.window_id -and $_.visible }).Count -eq 1) 'Showing the floating window changed its ID.'
    Record 'close_hide_show' 'verified' 'Native floating window close hides its object; ID survives hidden capture and re-show.'

    Trigger 'actionShowPreferences'
    $preferences = @((Windows).windows | Where-Object class -EQ 'gp::gui::PreferencesDialog')[0]
    Check ($preferences.visible -and $preferences.modality -eq 'non_modal') 'Native nonmodal preferences dialog missing.'
    Capture 'preferences' $preferences.window_id | Out-Null

    Invoke-McpTool $connection gp_edit_metadata @{document=$document;property='Title';value='P12 identity and undo'} | Out-Null
    $beforeEdit = Invoke-McpTool $connection gp_score @{document=$document}
    Check ($beforeEdit.dirty -and $beforeEdit.undo_available) 'Edit precondition missing.'
    Capture 'dirty-title' $mainId | Out-Null
    Invoke-McpTool $connection gp_undo_redo @{document=$document;operation='undo'} | Out-Null
    Capture 'redo-available' $mainId | Out-Null
    Invoke-McpTool $connection gp_undo_redo @{document=$document;operation='redo'} | Out-Null
    $prompt = Invoke-McpTool $connection gp_close @{document=$document;unsaved='prompt'}
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do { $dialog=Invoke-McpTool $connection gp_dialogs; if ($dialog.blocked) { break }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
    Check ($dialog.blocked) 'Native close confirmation is missing.'
    $modalWindows = Windows
    $modal = @($modalWindows.windows | Where-Object active_modal)[0]
    Check ($modal.class -eq $dialog.class -and $modal.parent_window_id -eq $mainId -and $modal.modality -ne 'non_modal') 'Modal enumeration differs from gp_dialogs.'
    $modalWindows | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $run 'modal-windows.json') -Encoding utf8
    $modalMain = Capture 'main-under-modal' $mainId
    Check (-not $modalMain.active_modal -and $modalMain.active_modal_window_id -eq $modal.window_id) 'Explicit main was substituted by the modal.'
    Capture 'keyboard-under-modal' $keyboard.window_id | Out-Null
    Capture 'fretboard-under-modal' $fretboard.window_id | Out-Null
    Capture 'preferences-under-modal' $preferences.window_id | Out-Null
    Capture 'modal' $modal.window_id | Out-Null
    $autoModal = Capture 'default-modal' -Default
    Check ($autoModal.window_id -eq $modal.window_id -and $autoModal.target_window -eq 'active_modal') 'Default modal preference changed.'
    Invoke-McpTool $connection gp_cancel @{request=$prompt.request} | Out-Null
    Wait-Operation $prompt 'cancelled' | Out-Null
    $afterModal = Windows
    Check ($afterModal.windows.window_id -notcontains $modal.window_id) 'Expected the native close-confirmation object to be destroyed.'
    Reject $modal.window_id 'window_not_found'
    $obj = Invoke-McpTool $connection gp_objects @{query='PreferencesDialog';limit=30}
    $pref = @($obj.objects | Where-Object class -EQ 'gp::gui::PreferencesDialog')[0]
    Invoke-McpTool $connection gp_close_window @{snapshot=$obj.snapshot;id=$pref.id} | Out-Null
    Record 'nonmodal_dialog' 'verified' 'PreferencesDialog captures alone and while blocked by close confirmation; no preference values were changed.'
    Record 'modal_and_destruction' 'verified' 'During a pending native close, explicit main and both floating windows remain selectable; default selects modal; cancelled modal is destroyed and its ID rejected.'
    Invoke-McpTool $connection gp_save_current @{document=$document} | Out-Null
    Wait-Operation (Invoke-McpTool $connection gp_close @{document=$document}) 'closed' | Out-Null
    $reopened = Wait-Operation (Invoke-McpTool $connection gp_open @{path=$fixture}) 'opened'
    $document = $reopened.document
    $reopenedScore = Invoke-McpTool $connection gp_score @{document=$document}
    Check ($reopenedScore.metadata.Title -eq 'P12 identity and undo' -and -not $reopenedScore.dirty) 'Host could not save and reopen after capture.'
    Record 'read_only_and_recovery' 'verified' 'Every capture compares foreground HWND/PID, all window display/active/modal states, active document, dirty, metadata, cursor and undo/redo; native edit, undo/redo and save/reopen still work.'

    foreach ($mode in @('hide','minimize')) {
        Invoke-McpTool $connection gp_window @{state='restore'} | Out-Null
        Invoke-McpTool $connection gp_window @{state=$mode} | Out-Null
        $meta = Capture "main-$mode" $mainId
        Check (($mode -eq 'hide' -and -not $meta.visible) -or ($mode -eq 'minimize' -and $meta.minimized)) "$mode state was misreported."
    }
    Invoke-McpTool $connection gp_window @{state='restore'} | Out-Null
    if (-not ('GpmcpP12Window' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class GpmcpP12Window {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr window, out Rect rect);
    public struct Rect { public int left, top, right, bottom; }
    private delegate bool WindowCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr data);
    public static IntPtr FindContentWindow(uint pid, int width, int height) {
        IntPtr match = IntPtr.Zero; int matches = 0;
        EnumWindows((window, data) => {
            uint owner; Rect rect;
            GetWindowThreadProcessId(window, out owner);
            if (owner == pid && GetClientRect(window, out rect) && rect.right == width && rect.bottom == height) { match=window; ++matches; }
            return true;
        }, IntPtr.Zero);
        return matches == 1 ? match : IntPtr.Zero;
    }
}
'@
    }
    $mainNow = @((Windows).windows | Where-Object window_id -EQ $mainId)[0]
    $hwnd = [GpmcpP12Window]::FindContentWindow($connection.Pid, [int]($mainNow.geometry.width*$mainNow.device_pixel_ratio), [int]($mainNow.geometry.height*$mainNow.device_pixel_ratio))
    $nativeTitle = [Text.StringBuilder]::new(1024); $nativePid = [uint32]0; $rect = [GpmcpP12Window+Rect]::new()
    [GpmcpP12Window]::GetWindowThreadProcessId($hwnd,[ref]$nativePid) | Out-Null
    [GpmcpP12Window]::GetWindowText($hwnd,$nativeTitle,1024) | Out-Null
    $hasRect = [GpmcpP12Window]::GetClientRect($hwnd,[ref]$rect)
    if ($hasRect -and $nativePid -eq $connection.Pid -and
        $rect.right -eq $mainNow.geometry.width*$mainNow.device_pixel_ratio -and $rect.bottom -eq $mainNow.geometry.height*$mainNow.device_pixel_ratio) {
        [GpmcpP12Window]::ShowWindow($hwnd,3) | Out-Null
        $maximized = Capture 'main-maximized' $mainId
        Check ($maximized.maximized) 'Maximized state missing.'
        [GpmcpP12Window]::ShowWindow($hwnd,9) | Out-Null
        Record 'maximized' 'verified' 'Test-only ShowWindow prepared maximized state; capture preserved it.'
    } else { Record 'maximized' 'unverified' 'No unique native window matches the Qt main client dimensions and PID.' }
    Record 'background_and_dpi' 'verified' 'Normal, hidden and minimized capture; available host DPI recorded with each PNG. Qt fixture separately covers scale 1 and 1.5.'

    $copy = Join-Path $run 'second.gp'; Copy-Item "$PSScriptRoot/testdata/minimal.gp" $copy
    $beforeCount = (Windows).total_count
    $other = Wait-Operation (Invoke-McpTool $connection gp_open @{path=$copy}) 'opened'
    Check ((Windows).windows.window_id -contains $mainId) 'Opening another document changed main window ID.'
    Capture 'multiple-documents' $mainId | Out-Null
    Record 'multiple_documents' 'verified' "Document tabs are embedded; main ID survives. Observed window totals before=$beforeCount after=$((Windows).total_count); extra windows are documented by their Qt objects, not inferred from tabs."
    $process.Refresh(); $resourcesBefore = @{private_bytes=$process.PrivateMemorySize64;handles=$process.HandleCount}
    for ($i=0; $i -lt 20; $i++) { $raw=Raw-Screenshot @{window_id=$keyboard.window_id}; Check (-not $raw.isError -and $raw.structuredContent.window_id -eq $keyboard.window_id) 'Repeated capture failed.'; $raw=$null }
    $process.Refresh(); $resourcesAfter = @{private_bytes=$process.PrivateMemorySize64;handles=$process.HandleCount}
    Check ($resourcesAfter.handles -le $resourcesBefore.handles+20 -and $resourcesAfter.private_bytes -le $resourcesBefore.private_bytes+64MB) 'Repeated capture retained excessive host resources.'
    Record 'repeated_capture' 'verified' '20 repeated floating captures stay within +20 handles and +64 MiB private bytes after warm-up; before/after values retained.'

    # Close only clean test-owned documents to verify the no-document window set.
    foreach ($doc in (Invoke-McpTool $connection gp_documents).documents) {
        Check (-not $doc.dirty) 'Unexpected dirty document before no-document check.'
        Wait-Operation (Invoke-McpTool $connection gp_close @{document=$doc.id}) 'closed' | Out-Null
    }
    Check (@((Invoke-McpTool $connection gp_documents).documents).Count -eq 0) 'No-document precondition failed.'
    Capture 'no-documents' $mainId | Out-Null
    foreach ($original in $originalFiles) {
        Check ((Get-FileHash -LiteralPath $original.path).Hash -eq $original.hash) 'Original document file bytes changed.'
        Wait-Operation (Invoke-McpTool $connection gp_open @{path=$original.path}) 'opened' | Out-Null
    }
    Record 'no_documents_and_file_bytes' 'verified' 'Main window remains selectable without documents; original fixture bytes verified and original files reopened.'
    foreach ($pair in @(@('virtualKeyboard','actionShowVirtualKeyboard'),@('virtualFretboard','actionShowVirtualFretboard'))) {
        $wasVisible = @($initialWindows.windows | Where-Object { $_.object_name -eq $pair[0] -and $_.visible }).Count -gt 0
        $nowVisible = @((Windows).windows | Where-Object { $_.object_name -eq $pair[0] -and $_.visible }).Count -gt 0
        if ($wasVisible -ne $nowVisible) { Trigger $pair[1] }
    }
    Invoke-McpTool $connection gp_window @{state=$(if ($initialMain.minimized) {'minimize'} elseif (-not $initialMain.visible) {'hide'} else {'restore'})} | Out-Null
    Record 'remaining_host_matrix' 'unverified' 'Native nested modals, native SubWindow, system/driver windows and unconstructed popup types are not claimed. Synthetic fixture covers SubWindow and QWindow-only boundaries; GPU, zero/oversize and enumeration-limit failures are fixture-only.'
    Record 'remaining_failure_paths' 'unverified' 'PNG allocator/encoder failure, response-size limit and stalled paint timeout not injected into the real host; 2000 ms is checked only after rendering returns.'
    $complete = $true
} finally {
    $sources = Get-FileHash -LiteralPath @("$root/native/window_capture.h","$root/native/guitarpro_mcp.cpp","$PSScriptRoot/test-p12.ps1") | Select-Object Path,Hash
    $loadedPlugin = @($process.Modules | Where-Object ModuleName -EQ 'guitarpro_mcp.dll')[0].FileName
    @{complete=$complete;checks=$checks;matrix=$matrix;captures=$captures;sources=$sources;instance_id=$connection.InstanceId;pid=$connection.Pid;
      host_sha256=(Get-FileHash -LiteralPath $descriptor.host_exe).Hash;plugin_sha256=(Get-FileHash -LiteralPath $loadedPlugin).Hash;
      resources_before=$resourcesBefore;resources_after=$resourcesAfter} | ConvertTo-Json -Depth 25 | Set-Content (Join-Path $run 'verification.json') -Encoding utf8
    Close-McpSession $second; Close-McpSession $connection
    if (-not $complete) { Write-Warning "P12 host retained for inspection. Evidence: $run" }
}
Write-Output "PASS: $checks P12 checks. Evidence: $run"
