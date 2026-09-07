param([string]$SessionFile = "$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
. "$PSScriptRoot/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-notation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$checks=0
$cases=@()
function Assert($ok, [string]$message) { if(-not $ok){throw $message}; $script:checks++ }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 40 -Compress }
function Call([string]$name, [hashtable]$arguments=@{}) { $arguments.document=$script:id; Invoke-McpTool $connection $name $arguments }
function Wait-Operation($request, [string]$expected) {
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $state=(Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if($state.status -in @($expected,'error','cancelled')) {break}
        Start-Sleep -Milliseconds 50
    } while([DateTime]::UtcNow -lt $deadline)
    Assert ($state.status -eq $expected) "Operation failed: $(Json $state)"
    $state
}
function Open([string]$path) {
    $request=Invoke-McpTool $connection gp_open @{path=$path}
    (Wait-Operation $request.request 'opened').document
}
function Close([string]$document) {
    $request=Invoke-McpTool $connection gp_close @{document=$document;unsaved='discard'}
    Wait-Operation $request.request 'closed' | Out-Null
}
function Bars { (Call gp_read_bars @{count=2}).bars }
function Undo { Call gp_undo_redo @{operation='undo'} | Out-Null }
function Check-Effect([string]$tool,[string]$property,$value,$clear) {
    $before=Bars
    $arguments=@{property=$property;value=$value}
    if($tool -eq 'gp_edit_note_effect') {$arguments.string=0}
    $result=Call $tool $arguments
    $after=Bars
    if($property -eq 'harmonic') {Assert ($after[0].voices[0].beats[0].notes[0].sounding_midi -eq 52) 'Twelfth-fret harmonic sounding pitch differs'}
    Assert ((Json $after) -ne (Json $before)) "$property did not change model: $(Json $value)"
    Undo
    Assert ((Json (Bars)) -eq (Json $before)) "$property undo changed content"
    Call gp_undo_redo @{operation='redo'} | Out-Null
    Assert ((Json (Bars)) -eq (Json $after)) "$property redo differs"
    $saved=Call gp_save_as @{path=(Join-Path $run ('case-' + $script:cases.Count + '.gp'))}
    $reopenPath=Join-Path $run ('case-' + $script:cases.Count + '-reopen.gp')
    Copy-Item -LiteralPath $saved.path -Destination $reopenPath
    $reopened=Open $reopenPath
    $actual=(Invoke-McpTool $connection gp_read_bars @{document=$reopened;count=2}).bars
    Assert ((Json $actual) -eq (Json $after)) "$property save/reopen differs"
    Close $reopened
    $arguments.value=$clear
    Call $tool $arguments | Out-Null
    $cleared=Bars
    $expectedClear=Json $before | ConvertFrom-Json
    if($property -eq 'grace') {
        $expectedClear[0].voices[0].beats[0].rhythm=$after[0].voices[0].beats[0].rhythm
        $expectedClear[0].voices[0].beats[0].native_note_value=$after[0].voices[0].beats[0].native_note_value
    }
    if($property -eq 'dead_slap') {
        $expectedClear[0].voices[0].beats[0].notes=@()
        $expectedClear[0].voices[0].beats[0].rest=$true
    }
    Assert ((Json $cleared) -eq (Json $expectedClear)) "$property clear differs"
    Undo
    Undo
    Assert ((Json (Bars)) -eq (Json $before)) "$property final undo differs"
    $script:cases+=@{tool=$tool;property=$property;value=$value;result=$result;saved=$saved.path}
}
try {
    $source=Join-Path $run 'source.gp'
    Copy-Item -LiteralPath "$PSScriptRoot/testdata/minimal.gp" -Destination $source
    $id=Open $source
    Call gp_cursor @{axis='bar';index=0} | Out-Null
    Call gp_cursor @{axis='beat';index=0} | Out-Null
    Call gp_edit_note @{operation='set';string=1;fret=3} | Out-Null
    foreach($property in @('dead','hopo','staccato','staccatissimo','accent','heavy_accent','tenuto')) {Check-Effect gp_edit_note_effect $property $true $false}
    Check-Effect gp_edit_note_effect 'trill' @{enabled=$true;midi=42} @{enabled=$false}
    foreach($kind in @('Shift','Legato','OutDownwards','OutUpwards','InFromBelow','InFromAbove','OutDownwardsPickScrape','OutUpwardsPickScrape')) {
        Check-Effect gp_edit_note_effect 'slide' @{kind=$kind;enabled=$true} @{kind='None'}
    }
    foreach($type in @('Natural','Artificial','Pinch','Tap','Semi','Feedback')) {
        Check-Effect gp_edit_note_effect 'harmonic' @{type=$type;fret=12} @{type='None'}
    }
    $ornaments=Invoke-McpTool $connection gp_edit_note_effect @{document=$id;string=0;property='ornament';value='invalid'} -AllowError
    foreach($type in $ornaments.choices | Where-Object {$_ -ne 'None'}) {
        Check-Effect gp_edit_note_effect 'ornament' $type 'None'
    }
    Check-Effect gp_edit_note_effect 'bend' @{enabled=$true;origin_value=0;middle_value=2;destination_value=0;origin_offset=0;middle_offset1=0.25;middle_offset2=0.75;destination_offset=1} @{enabled=$false}
    Check-Effect gp_edit_beat_effect 'whammy' @{enabled=$true;origin_value=0;middle_value=-2;destination_value=0;origin_offset=0;middle_offset1=0.25;middle_offset2=0.75;destination_offset=1} @{enabled=$false}
    foreach($property in @('grace','pick_stroke','fade','hairpin','golpe','ottavia','rasgueado','bar_vibrato','bass_attack','arpeggio','brush')) {
        $options=Invoke-McpTool $connection gp_edit_beat_effect @{document=$id;property=$property;value='invalid'} -AllowError
        Assert ($options.error -and $options.choices.Count -gt 1) "$property did not expose choices"
        $default=(Bars)[0].voices[0].beats[0].effects.$property
        foreach($value in $options.choices | Where-Object {$_ -ne $default}) {Check-Effect gp_edit_beat_effect $property $value $default}
    }
    foreach($value in @(8,16,32,64)){Check-Effect gp_edit_beat_effect 'tremolo' $value 0}
    Check-Effect gp_edit_beat_effect 'dead_slap' $true $false
    Call gp_save_as @{path=(Join-Path $run 'retained.gp')} | Out-Null
    Close $id
    $id=$null
    Write-Output "PASS: $checks native notation checks. Evidence: $run"
} finally {
    @{checks=$checks;cases=$cases;complete=($null -eq $id);plugin_sha256=(Get-FileHash -LiteralPath "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash} |
        ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $run 'verification.json') -Encoding UTF8
    Close-McpSession $connection
}
