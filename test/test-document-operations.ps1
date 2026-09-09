param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $PSScriptRoot 'testdata/minimal.gp'
$fixtureHash = (Get-FileHash -LiteralPath $fixture).Hash
$run = Join-Path $root ('artifacts/document-operations-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$checks = 0; $passed = $false; $observations = @()
function Assert($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++ }
$connection = New-McpSession -SessionFile $SessionFile
function Operation($request) { (Invoke-McpTool $connection gp_operation @{request=$request}).operation }
function Wait-Operation($request, [string]$expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = Operation $request
        if ($state.status -in @($expected,'error','cancelled','closed','opened','created')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    $script:observations += $state
    Assert ($state.status -eq $expected) "Operation did not reach ${expected}: $($state | ConvertTo-Json -Depth 5 -Compress)"
    return $state
}
function Wait-Dialog {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $modal = Invoke-McpTool $connection gp_dialogs
        if ($modal.blocked) { return $modal }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Expected a native operation dialog.'
}
function Title([string]$path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open())
        try { [xml]$xml = $reader.ReadToEnd(); $xml.GPIF.Score.Title.InnerText } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}
function New-Score { $r = Invoke-McpTool $connection gp_new @{template='Nylon Guitar'}; (Wait-Operation $r.request 'created').document }
try {
    $before = Invoke-McpTool $connection gp_documents
    Assert ($before.documents.Count -eq 1 -and -not $before.documents[0].dirty) 'Requires one clean baseline document.'
    $baseline = $before.documents[0]
    Assert ((Get-FileHash -LiteralPath $baseline.opened_path).Hash -eq $fixtureHash) 'Baseline differs from the fixture.'
    $workingPath = Join-Path $run 'working.gp'
    Copy-Item -LiteralPath $fixture -Destination $workingPath
    $open = Invoke-McpTool $connection gp_open @{path=$workingPath}
    Assert ($open.request -and $open.status -eq 'scheduled') 'Open did not return a tracked request.'
    $opened = Wait-Operation $open.request 'opened'
    $id = $opened.document
    Assert ((Invoke-McpTool $connection gp_documents).opening.request -eq $open.request) 'Document list omitted the opening request.'
    $duplicate = Invoke-McpTool $connection gp_open @{path=$workingPath}
    Assert ($duplicate.status -eq 'already_open' -and $duplicate.document -eq $id) 'Repeated open did not reuse the document.'
    Invoke-McpTool $connection gp_edit_metadata @{document=$id;property='Title';value='Keep until explicitly saved'} | Out-Null
    Assert ((Invoke-McpTool $connection gp_close @{document=$id} -AllowError).error) 'Default close discarded an unsaved document.'
    $cancel = Invoke-McpTool $connection gp_close @{document=$id;unsaved='cancel'}
    Assert ($cancel.status -eq 'cancelled' -and (Invoke-McpTool $connection gp_score @{document=$id}).dirty) 'Explicit cancel changed the document.'
    $prompt = Invoke-McpTool $connection gp_close @{document=$id;unsaved='prompt'}
    $modal = Wait-Dialog
    $observations += $modal
    Assert (@($modal.buttons | Where-Object standard_button -EQ 4194304).Count -eq 1) 'Native close dialog has no unambiguous Cancel button.'
    Assert ((Invoke-McpTool $connection gp_edit_metadata @{document=$baseline.id;property='Title';value='Must not change'} -AllowError).error) 'A second mutation entered a pending document operation.'
    Assert ((Invoke-McpTool $connection gp_cancel @{request=$cancel.request} -AllowError).error) 'A stale cancel request affected a later operation.'
    Assert ((Invoke-McpTool $connection gp_dialogs).blocked) 'Stale cancellation dismissed the current dialog.'
    $cancelling = Invoke-McpTool $connection gp_cancel @{request=$prompt.request}
    Assert ($cancelling.status -eq 'cancelling') 'Native cancellation did not report its pending outcome.'
    Wait-Operation $prompt.request 'cancelled' | Out-Null
    $retained = Invoke-McpTool $connection gp_score @{document=$id}
    Assert ($retained.dirty -and $retained.metadata.Title -eq 'Keep until explicitly saved') 'Cancel lost unsaved score content.'
    Assert ((Get-FileHash -LiteralPath $workingPath).Hash -eq $fixtureHash) 'Cancel unexpectedly wrote the source file.'
    $savedClose = Invoke-McpTool $connection gp_close @{document=$id;unsaved='save'}
    $closed = Wait-Operation $savedClose.request 'closed'
    Assert ($closed.save.path -and -not $closed.save.dirty) 'Save-and-close did not complete native saving.'
    Assert ((Title $workingPath) -eq 'Keep until explicitly saved') 'Save-and-close did not persist content.'
    Assert ((Operation $prompt.request).status -eq 'cancelled') 'A later close overwrote the previous operation result.'
    $openAgain = Invoke-McpTool $connection gp_open @{path=$workingPath}
    $id = (Wait-Operation $openAgain.request 'opened').document
    Invoke-McpTool $connection gp_edit_metadata @{document=$id;property='Title';value='Discard this change'} | Out-Null
    $hash = (Get-FileHash -LiteralPath $workingPath).Hash
    $discard = Invoke-McpTool $connection gp_close @{document=$id;unsaved='discard'}
    $discarded = Wait-Operation $discard.request 'closed'
    Assert ($discarded.decision -eq 'discard') 'Discard did not use the native discard decision.'
    Assert ((Get-FileHash -LiteralPath $workingPath).Hash -eq $hash) 'Discard changed file bytes.'
    Assert ((Invoke-McpTool $connection gp_score @{document=$id} -AllowError).error) 'Discarded document remains addressable.'
    $unnamed = New-Score
    Invoke-McpTool $connection gp_edit_metadata @{document=$unnamed;property='Title';value='Unnamed save-and-close'} | Out-Null
    $missing = Invoke-McpTool $connection gp_close @{document=$unnamed;unsaved='save'}
    Wait-Operation $missing.request 'error' | Out-Null
    Assert ((Invoke-McpTool $connection gp_score @{document=$unnamed}).dirty) 'Failed save-and-close cleared unsaved work.'
    $savedPath = Join-Path $run 'named.gp'
    $named = Invoke-McpTool $connection gp_close @{document=$unnamed;unsaved='save';path=$savedPath}
    Wait-Operation $named.request 'closed' | Out-Null
    Assert ((Title $savedPath) -eq 'Unnamed save-and-close') 'Save As during closing did not persist unnamed content.'
    $firstArchived = $null
    foreach ($i in 1..66) {
        $r = Invoke-McpTool $connection gp_close @{document=$baseline.id;unsaved='cancel'}
        if (-not $firstArchived) { $firstArchived = $r.request }
    }
    Assert ((Invoke-McpTool $connection gp_operation @{request=$firstArchived} -AllowError).error) 'Expired operation ID was not rejected.'
    Assert ((Operation $r.request).status -eq 'cancelled') 'Most recent operation result was not retained.'
    $invalidPath = Join-Path $run 'invalid.gp'
    'Not a Guitar Pro archive' | Set-Content -LiteralPath $invalidPath -Encoding ASCII
    $bad = Invoke-McpTool $connection gp_open @{path=$invalidPath}
    $invalid = Wait-Operation $bad.request 'error'
    Assert ($invalid.failure_stage -eq 'validation' -and -not $invalid.outcome_unknown) 'Malformed archive did not report a confirmed validation failure.'
    Assert ((Invoke-McpTool $connection gp_cancel @{request=$bad.request} -AllowError).error) 'Completed validation failure reported false cancellation.'
    Assert ((Invoke-McpTool $connection gp_close @{document=$baseline.id;unsaved='cancel'}).status -eq 'cancelled') 'Validation failure left the operation queue blocked.'
    Assert ((Invoke-McpTool $connection gp_documents).documents.Count -eq 1) 'Failed open created or removed a document.'
    $invalidArchives = @(
        @{name='missing-entry';entry='Content/other.xml';xml='<GPIF/>';error='Expected one Content/score.gpif*'},
        @{name='invalid-xml';entry='Content/score.gpif';xml='<GPIF><Score></GPIF>';error='Invalid GPIF XML*'},
        @{name='wrong-root';entry='Content/score.gpif';xml='<Other/>';error='Expected a GPIF XML root*'},
        @{name='doctype';entry='Content/score.gpif';xml='<!DOCTYPE GPIF [<!ENTITY value "test">]><GPIF>&value;</GPIF>';error='GPIF document type declarations*'},
        @{name='duplicate-entry';entry='Content/score.gpif';xml='<GPIF/>';duplicate=$true;error='Expected one Content/score.gpif*'},
        @{name='future-revision';entry='Content/score.gpif';xml='<GPIF><GPRevision required="999999">999999</GPRevision></GPIF>';error='Required GPIF revision exceeds*'},
        @{name='invalid-revision';entry='Content/score.gpif';xml='<GPIF><GPRevision required="invalid">13007</GPRevision></GPIF>';error='Invalid required GPIF revision*'}
    )
    foreach ($case in $invalidArchives) {
        $path = Join-Path $run ($case.name + '.gp')
        $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $count = if ($case.duplicate) { 2 } else { 1 }
            foreach ($i in 1..$count) {
                $writer = [IO.StreamWriter]::new($zip.CreateEntry($case.entry).Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write($case.xml) } finally { $writer.Dispose() }
            }
        } finally { $zip.Dispose() }
        $request = Invoke-McpTool $connection gp_open @{path=$path}
        $failure = Wait-Operation $request.request 'error'
        Assert ($failure.failure_stage -eq 'validation' -and $failure.error -like $case.error) "Unexpected ${path} validation result."
        Assert (-not $failure.outcome_unknown -and (Invoke-McpTool $connection gp_close @{document=$baseline.id;unsaved='cancel'}).status -eq 'cancelled') 'Rejected archive left subsequent document operations blocked.'
    }
    $revisionPath = Join-Path $run 'compatible-revision.gp'
    Copy-Item -LiteralPath $fixture -Destination $revisionPath
    $zip = [IO.Compression.ZipFile]::Open($revisionPath, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $zip.GetEntry('Content/score.gpif')
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $xml.GPIF.GPRevision.SetAttribute('required','13007')
        $xml.GPIF.GPRevision.SetAttribute('recommended','999999')
        $entry.Delete()
        $writer = [IO.StreamWriter]::new($zip.CreateEntry('Content/score.gpif').Open(), [Text.UTF8Encoding]::new($false))
        try { $xml.Save($writer) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    $compatible = Invoke-McpTool $connection gp_open @{path=$revisionPath}
    $compatibleId = (Wait-Operation $compatible.request 'opened').document
    Assert ((Invoke-McpTool $connection gp_score @{document=$compatibleId}).metadata.Title -eq 'MCP Test') 'Compatible required revision was rejected due to a newer recommendation.'
    $closeCompatible = Invoke-McpTool $connection gp_close @{document=$compatibleId}
    Wait-Operation $closeCompatible.request 'closed' | Out-Null
    $after = Invoke-McpTool $connection gp_documents
    Assert ($after.documents.Count -eq 1 -and $after.documents[0].id -eq $baseline.id -and -not $after.documents[0].dirty) 'Lifecycle checks changed baseline state.'
    Assert ((Get-FileHash -LiteralPath $baseline.opened_path).Hash -eq $fixtureHash) 'Lifecycle checks changed baseline bytes.'
    $identity = Invoke-McpTool $connection gp_capabilities
    Assert ($identity.hidden_mode -and $identity.foreground_pid -ne $identity.pid) 'Lifecycle operations took foreground focus.'
    $passed = $true
} finally {
    Close-McpSession $connection
    @{passed=$passed;checks=$checks;observations=$observations;host_pid=$connection.Pid;unknown_native_outcome_recovery_verified=$false;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
}
Write-Output "PASS: $checks tracked document open/close, save/discard/cancel, native dialog, history and isolation checks. Evidence: $run"
