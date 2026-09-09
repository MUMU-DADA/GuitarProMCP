param([string]$SessionFile, [switch]$RenderPdf)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-p6-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$s = New-McpSession -SessionFile $SessionFile
$checks=0; $complete=$false; $owned=@(); $preferences=@{}; $evidence=@(); $midiRequest=$null; $midiBefore=$null
function Check($condition, $message) { if (-not $condition) { throw $message }; $script:checks++ }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 30 -Compress }
function WaitOp($request, $expected) {
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    do {
        $state=(Invoke-McpTool $s gp_operation @{request=$request}).operation
        if ($state.status -in @('exported','opened','closed','saved','created','error','cancelled')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($state.status -eq $expected) "Operation differs: $(Json $state)"
    $script:evidence += $state
    $state
}
function OpenScore($path) {
    $opened=WaitOp (Invoke-McpTool $s gp_open @{path=$path}).request 'opened'
    $script:owned += $opened.document
    $opened.document
}
function CloseScore($id) {
    WaitOp (Invoke-McpTool $s gp_close @{document=$id;unsaved='discard'}).request 'closed' | Out-Null
    $script:owned=@($script:owned | Where-Object { $_ -ne $id })
}
function ExportScore($id, $name, $extra=@{}) {
    $arguments=@{document=$id;path=(Join-Path $run $name)}
    foreach ($key in $extra.Keys) { $arguments[$key]=$extra[$key] }
    $done=WaitOp (Invoke-McpTool $s gp_export $arguments).request 'exported'
    Check ((Get-FileHash $arguments.path).Hash -eq $done.result.sha256) "$name committed hash differs"
    $done.result
}
function WaitMidi($path) {
    $script:midiRequest=(Invoke-McpTool $s gp_open @{path=$path}).request
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do {
        $options=Invoke-McpTool $s gp_midi_import @{request=$script:midiRequest} -AllowError
        if (-not $options.error) { return $options }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'MIDI options did not appear'
}
function ReadXml($path) {
    $settings=[Xml.XmlReaderSettings]::new(); $settings.DtdProcessing=[Xml.DtdProcessing]::Ignore; $settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create($path,$settings)
    try { $xml=[Xml.XmlDocument]::new(); $xml.XmlResolver=$null; $xml.Load($reader); return ,$xml } finally { $reader.Dispose() }
}
function InspectImage($path) {
    $bitmap=[Drawing.Bitmap]::new($path)
    try {
        $dark=0
        for ($y=0; $y -lt $bitmap.Height; $y+=2) { for ($x=0; $x -lt $bitmap.Width; $x+=2) {
            $pixel=$bitmap.GetPixel($x,$y); if ($pixel.R -lt 180 -and $pixel.G -lt 180 -and $pixel.B -lt 180) { $dark++ }
        } }
        Check ($dark -gt 500 -and $dark -lt $bitmap.Width*$bitmap.Height/8) 'Page is empty or obscured'
        @{width=$bitmap.Width;height=$bitmap.Height;dark_samples=$dark}
    } finally { $bitmap.Dispose() }
}
try {
    $initial=Invoke-McpTool $s gp_documents
    $others=@($initial.documents | Sort-Object id | Select-Object id,dirty,opened_path,save_path)
    $path=Join-Path $run 'score.gp'; Copy-Item "$PSScriptRoot/testdata/minimal.gp" $path
    $id=OpenScore $path
    $formats=Invoke-McpTool $s gp_formats
    Check (@($formats.importers | Where-Object extensions -contains 'musicxml').Count -eq 1) 'MusicXML importer missing'
    Check ($formats.export_extensions -contains 'pdf' -and $formats.export_extensions -contains 'png') 'Print output missing'
    foreach ($ext in @('gp5','gpx','musicxml','mid')) {
        ExportScore $id "score.$ext" | Out-Null
        if ($ext -eq 'mid') { continue }
        $converted=OpenScore (Join-Path $run "score.$ext")
        $score=Invoke-McpTool $s gp_score @{document=$converted}
        $bars=Invoke-McpTool $s gp_read_bars @{document=$converted;track=0;bar=0;count=2}
        $evidence += @{format=$ext;score=$score;bars=$bars}
        Check ($score.tracks.Count -eq 1) "$ext track count differs"
        Check (($bars.bars.voices.beats.notes.sounding_midi -join ',') -eq '40,42,43,45,47,48,50,52') "$ext pitches differ"
        CloseScore $converted
    }
    $xml=ReadXml (Join-Path $run 'score.musicxml')
    Check ($xml.DocumentElement.LocalName -eq 'score-partwise') 'Invalid MusicXML root'
    Check ($xml.SelectNodes('/score-partwise/part').Count -eq 1 -and $xml.SelectNodes('//measure').Count -eq 2) 'MusicXML structure differs'
    Check ($xml.SelectNodes('//note[pitch and staff=1]').Count -eq 8 -and $xml.SelectNodes('//note[pitch and staff=2]').Count -eq 8 -and $xml.SelectNodes('//note[pitch and duration=1]').Count -eq 16) 'MusicXML note content differs'
    $parsed=& "$PSScriptRoot/test-exchange.ps1" -Directory $run
    $evidence += @{independent_exchange=$parsed}
    Check ($parsed.gp5_notes.Count -eq 8 -and $parsed.gpx_notes.Count -eq 8 -and $parsed.midi_notes.Count -eq 8) 'Independent exchange parsing differs'
    $options=WaitMidi (Join-Path $run 'score.mid'); $midiBefore=$options.values
    foreach ($property in $midiBefore.PSObject.Properties) {
        $value=if ($property.Name -eq 'quantization') {5} else {-not $property.Value}
        $changed=Invoke-McpTool $s gp_midi_import @{request=$midiRequest;operation='set';property=$property.Name;value=$value}
        Check ($changed.values.($property.Name) -eq $value) 'MIDI option readback differs'
        Invoke-McpTool $s gp_midi_import @{request=$midiRequest;operation='set';property=$property.Name;value=$property.Value} | Out-Null
    }
    Check ((Invoke-McpTool $s gp_midi_import @{request=$midiRequest;operation='set';property='quantization';value=99} -AllowError).error) 'Invalid MIDI quantization accepted'
    Invoke-McpTool $s gp_midi_import @{request=$midiRequest;operation='accept'} | Out-Null
    $imported=(WaitOp $midiRequest 'opened').document; $owned += $imported; $midiRequest=$null
    $evidence += @{format='mid';bars=(Invoke-McpTool $s gp_read_bars @{document=$imported;track=0;bar=0;count=2})}
    CloseScore $imported
    WaitMidi (Join-Path $run 'score.mid') | Out-Null
    Invoke-McpTool $s gp_cancel @{request=$midiRequest} | Out-Null
    WaitOp $midiRequest 'cancelled' | Out-Null; $midiRequest=$null
    $pres=(Invoke-McpTool $s gp_presentation @{document=$id}).state
    Invoke-McpTool $s gp_presentation @{document=$id;operation='set';width=$pres.width} | Out-Null
    Check (-not @((Invoke-McpTool $s gp_documents).documents | Where-Object id -eq $id)[0].dirty) 'No-op page change dirtied score'
    foreach ($field in @('zoom','design_mode','multivoice_edition')) {
        $value=if ($field -eq 'zoom') {1.25} else {-not $pres.$field}
        $arguments=@{document=$id;operation='set'}; $arguments[$field]=$value
        Invoke-McpTool $s gp_presentation $arguments | Out-Null
        Start-Sleep -Milliseconds 100
        Check ((Invoke-McpTool $s gp_presentation @{document=$id}).state.$field -eq $value) "$field did not settle"
        $arguments[$field]=$pres.$field; Invoke-McpTool $s gp_presentation $arguments | Out-Null
    }
    $changed=Invoke-McpTool $s gp_presentation @{document=$id;operation='set';width=200;height=290;left=11;top=12;right=13;bottom=14;orientation='landscape'}
    Check ($changed.state.width -eq 200 -and $changed.state.left -eq 11 -and -not $changed.undoable) 'Page readback differs'
    Check (@((Invoke-McpTool $s gp_documents).documents | Where-Object id -eq $id)[0].dirty) 'Page change did not dirty score'
    $before=Json $changed.state
    Check ((Invoke-McpTool $s gp_presentation @{document=$id;operation='set';left=500} -AllowError).error) 'Invalid margins accepted'
    Check ((Json (Invoke-McpTool $s gp_presentation @{document=$id}).state) -eq $before) 'Invalid margins changed state'
    $notation=Invoke-McpTool $s gp_presentation @{document=$id;operation='set';track=0;tablature=$false}
    Check (-not $notation.state.tracks[0].tablature -and -not $notation.undoable) 'Notation readback differs'
    Invoke-McpTool $s gp_save_current @{document=$id} | Out-Null
    CloseScore $id; $id=OpenScore $path
    $reopened=(Invoke-McpTool $s gp_presentation @{document=$id}).state
    Check ($reopened.width -eq 200 -and $reopened.height -eq 290 -and $reopened.orientation -eq 'landscape' -and $reopened.left -eq 11 -and -not $reopened.tracks[0].tablature) 'Page or notation did not persist'
    $pdf=ExportScore $id 'print.pdf'; $png=ExportScore $id 'page.png'
    $evidence += @{png=(InspectImage (Join-Path $run 'page.png'))}
    Check ($png.width -gt $png.height -and $pdf.pages -eq 1) 'Landscape page dimensions differ'
    if ($RenderPdf) {
        $info=@(& pdfinfo (Join-Path $run 'print.pdf')); Check ($LASTEXITCODE -eq 0) 'PDF parse failed'
        & pdftoppm -singlefile -scale-to 900 -png (Join-Path $run 'print.pdf') (Join-Path $run 'print-render')
        Check ($LASTEXITCODE -eq 0) 'PDF render failed'
        $evidence += @{pdfinfo=$info;pdf_render=(InspectImage (Join-Path $run 'print-render.png'))}
    }
    $pagePath=Join-Path $run 'pages.gp'; Copy-Item "$PSScriptRoot/testdata/minimal.gp" $pagePath
    $archive=[IO.Compression.ZipFile]::Open($pagePath,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry=$archive.GetEntry('Content/score.gpif'); $reader=[IO.StreamReader]::new($entry.Open())
        try { [xml]$fixture=$reader.ReadToEnd() } finally {$reader.Dispose()}
        for ($i=2; $i -lt 50; $i++) {
            $master=$fixture.GPIF.MasterBars.MasterBar[0].CloneNode($true); $master.Bars=[string]$i; $fixture.GPIF.MasterBars.AppendChild($master) | Out-Null
            $bar=$fixture.GPIF.Bars.Bar[0].CloneNode($true); $bar.id=[string]$i; $bar.Voices=[string]$i; $fixture.GPIF.Bars.AppendChild($bar) | Out-Null
            $voice=$fixture.GPIF.Voices.Voice[0].CloneNode($true); $voice.id=[string]$i; $voice.Beats=((0..3 | ForEach-Object {4*$i+$_}) -join ' '); $fixture.GPIF.Voices.AppendChild($voice) | Out-Null
            for ($j=0; $j -lt 4; $j++) { $beat=$fixture.GPIF.Beats.Beat[$j].CloneNode($true); $beat.id=[string](4*$i+$j); $fixture.GPIF.Beats.AppendChild($beat) | Out-Null }
        }
        $entry.Delete(); $writer=[IO.StreamWriter]::new($archive.CreateEntry('Content/score.gpif').Open(),[Text.UTF8Encoding]::new($false))
        try {$writer.Write($fixture.OuterXml)} finally {$writer.Dispose()}
    } finally {$archive.Dispose()}
    $pageId=OpenScore $pagePath
    $many=ExportScore $pageId 'pages.pdf'; $second=ExportScore $pageId 'page-2.png' @{page=2}
    Check ($many.pages -ge 2 -and $many.pages -eq $second.pages -and $second.page -eq 2) 'Multi-page output differs'
    $evidence += @{second_page=(InspectImage (Join-Path $run 'page-2.png'))}
    CloseScore $pageId
    $existing=Join-Path $run 'existing.gp5'; [IO.File]::WriteAllText($existing,'keep')
    $refused=WaitOp (Invoke-McpTool $s gp_export @{document=$id;path=$existing}).request 'error'
    Check ($refused.error -match 'overwrite|exists' -and [IO.File]::ReadAllText($existing) -eq 'keep') 'Overwrite refusal damaged target'
    ExportScore $id 'existing.gp5' @{overwrite=$true} | Out-Null
    $locked=[IO.File]::Open($existing,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $hash=(Get-FileHash $existing).Hash
    try { WaitOp (Invoke-McpTool $s gp_export @{document=$id;path=$existing;overwrite=$true}).request 'error' | Out-Null } finally { $locked.Dispose() }
    Check ((Get-FileHash $existing).Hash -eq $hash) 'Failed commit damaged target'
    WaitOp (Invoke-McpTool $s gp_export @{document=$id;path=(Join-Path $run 'missing/fail.pdf')}).request 'error' | Out-Null
    WaitOp (Invoke-McpTool $s gp_export @{document=$id;path=(Join-Path $run 'bad.png');page=100}).request 'error' | Out-Null
    Check (-not (Test-Path (Join-Path $run 'bad.png'))) 'Failed PNG left output'
    $audioPath=Join-Path $run 'audio.gp'; Copy-Item "$PSScriptRoot/testdata/minimal.gp" $audioPath
    $archive=[IO.Compression.ZipFile]::Open($audioPath,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry=$archive.GetEntry('Content/score.gpif'); $reader=[IO.StreamReader]::new($entry.Open())
        try { [xml]$fixture=$reader.ReadToEnd() } finally {$reader.Dispose()}
        $fixture.GPIF.Tracks.Track.AudioEngineState='RSE'; $entry.Delete()
        $writer=[IO.StreamWriter]::new($archive.CreateEntry('Content/score.gpif').Open(),[Text.UTF8Encoding]::new($false))
        try {$writer.Write($fixture.OuterXml)} finally {$writer.Dispose()}
    } finally {$archive.Dispose()}
    $audioId=OpenScore $audioPath
    $guitar=(WaitOp (Invoke-McpTool $s gp_new @{template='Steel Guitar'}).request 'created').document; $owned += $guitar
    Invoke-McpTool $s gp_audio_track @{document=$audioId;track=0;operation='copy';source_document=$guitar;source_track=0} | Out-Null
    $wav=ExportScore $audioId 'audio.wav'
    $stream=[IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $run 'audio.wav')))
    try {
        $header=$stream.ReadBytes(44)
        Check ([Text.Encoding]::ASCII.GetString($header,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($header,8,4) -eq 'WAVE') 'Invalid WAV header'
        Check ([BitConverter]::ToInt16($header,22) -eq 2 -and [BitConverter]::ToInt32($header,24) -eq 44100 -and [BitConverter]::ToInt16($header,34) -eq 16) 'WAV encoding differs'
        $sum=0.0; $count=0; $peak=0
        while ($stream.BaseStream.Position -lt $stream.BaseStream.Length) { $sample=[int]$stream.ReadInt16(); $sum+=[double]$sample*$sample; $count++; $peak=[Math]::Max($peak,[Math]::Abs($sample)) }
        $rms=[Math]::Sqrt($sum/$count)
        Check ($count/2 -eq 235200 -and $wav.frames -eq 235200 -and $rms -gt 100 -and $peak -gt 1000) 'Rendered sound is silent or has incorrect duration'
        $evidence += @{audio=@{frames=$count/2;rms=$rms;peak=$peak;seconds=$wav.seconds}}
    } finally {$stream.Dispose()}
    $cancel=Invoke-McpTool $s gp_export @{document=$audioId;path=(Join-Path $run 'cancel.wav')}
    Invoke-McpTool $s gp_cancel @{request=$cancel.request} | Out-Null
    WaitOp $cancel.request 'cancelled' | Out-Null
    Check (-not (Test-Path (Join-Path $run 'cancel.wav'))) 'Cancelled export committed target'
    ExportScore $audioId 'recovered.gp5' | Out-Null
    Invoke-McpTool $s gp_save_current @{document=$audioId} | Out-Null
    foreach ($doc in @($owned)) { CloseScore $doc }
    $p6PreferenceFields=@{
        general=@('embedAudioFiles','restoreOpenFile','zoom')
        gui=@('autoOpenFxPopup','highlightBar','includeChordsInCopyPaste','playSoundWhileEditing','useMediaKeys')
        score=@('barLengthError','hoPoError','outOfRangeError','tupletError','unreachableBarError')
    }
    foreach ($model in @('general','gui','score')) {
        $preferences[$model]=(Invoke-McpTool $s gp_preferences @{model=$model}).values
        foreach ($name in $p6PreferenceFields[$model]) {
            $property=$preferences[$model].PSObject.Properties | Where-Object Name -EQ $name
            if (-not $property) { continue }
            $value=if ($property.Name -eq 'zoom') { if ($property.Value -eq 1.25) {1.5} else {1.25} } else {-not $property.Value}
            $changed=Invoke-McpTool $s gp_preferences @{model=$model;operation='set';property=$property.Name;value=$value}
            Check ($changed.scope -eq 'application' -and $changed.values.($property.Name) -eq $value) 'Preference did not read back'
            Invoke-McpTool $s gp_preferences @{model=$model;operation='set';property=$property.Name;value=$property.Value} | Out-Null
        }
    }
    Check ((Invoke-McpTool $s gp_preferences @{model='general';operation='set';property='zoom';value=100} -AllowError).error) 'Invalid preference accepted'
    foreach ($doc in @($owned)) { CloseScore $doc }
    $after=@((Invoke-McpTool $s gp_documents).documents | Sort-Object id | Select-Object id,dirty,opened_path,save_path)
    Check ((Json $after) -eq (Json $others)) 'P6 changed another document'
    Check (@(Get-ChildItem $run -Directory -Filter '.gpmcp-export-*').Count -eq 0) 'Export staging leaked'
    $complete=$true
} finally {
    $cleanupError=$null
    try {
    if ($midiRequest) {
        if ($midiBefore) { foreach ($property in $midiBefore.PSObject.Properties) { Invoke-McpTool $s gp_midi_import @{request=$midiRequest;operation='set';property=$property.Name;value=$property.Value} -AllowError | Out-Null } }
        Invoke-McpTool $s gp_cancel @{request=$midiRequest} -AllowError | Out-Null
        Start-Sleep -Milliseconds 100
    }
    foreach ($model in $preferences.Keys) { foreach ($name in $p6PreferenceFields[$model]) {
        $property=$preferences[$model].PSObject.Properties | Where-Object Name -EQ $name
        if (-not $property) { continue }
        $restored=Invoke-McpTool $s gp_preferences @{model=$model;operation='set';property=$property.Name;value=$property.Value}
        Check ($restored.values.($property.Name) -eq $property.Value) 'Preference restore failed'
    } }
    foreach ($doc in @($owned)) { CloseScore $doc }
    if ($initial.active_document) { Invoke-McpTool $s gp_activate @{document=$initial.active_document} | Out-Null }
    } catch {
        $complete=$false
        $cleanupError=$_.Exception.Message
        throw
    } finally {
    $sources=@('native/guitarpro_io.h','native/guitarpro_mcp.cpp','native/guitarpro_abi.h','native/host_build.h','test/test-p6.ps1','test/test-exchange.ps1','native/supported-host.json') | ForEach-Object {Get-FileHash (Join-Path $root $_) | Select-Object Path,Hash}
    @{complete=$complete;cleanup_error=$cleanupError;checks=$checks;operations=$evidence;sources=$sources;plugin_sha256=(Get-FileHash "$root/.tools/native/plugins/generic/guitarpro_mcp.dll").Hash;host_pid=$s.Pid} | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    Close-McpSession $s
    }
}
Write-Output "PASS: $checks P6 checks; evidence: $run"
