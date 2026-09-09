param([string]$SessionFile, [switch]$RenderPdf, [string]$PdfTextPython='', [switch]$SkipFaults)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../native/mcp-client.ps1"
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root ('artifacts/native-p8-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$connection = New-McpSession -SessionFile $SessionFile
$second = New-McpSession -SessionFile $SessionFile
$checks=0; $complete=$false; $owned=@(); $evidence=@(); $id=''
function Check($condition, [string]$message) { if (-not $condition) { throw $message }; $script:checks++; $script:lastCheck=$message }
function Json($value) { ConvertTo-Json -InputObject $value -Depth 64 -Compress }
function Clone($value) { Json $value | ConvertFrom-Json }
function WaitOp($request, [switch]$AllowError) {
    $deadline=[DateTime]::UtcNow.AddSeconds(40)
    do {
        $result=(Invoke-McpTool $connection gp_operation @{request=$request}).operation
        if ($result.status -notin @('scheduled','requested','cancelling')) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    Check ($result.status -notin @('scheduled','requested','cancelling')) "Request has no terminal state: $(Json $result)"
    $script:evidence += $result
    if (!$AllowError) { Check (!$result.error) "Request failed: $(Json $result)" }
    $result
}
function Call([string]$name, [hashtable]$values=@{}, [switch]$AllowError) {
    $values=$values.Clone()
    if ($script:id -and !$values.ContainsKey('document') -and $name -notin @('gp_new','gp_create_from_spec','gp_open')) { $values.document=$script:id }
    $r=Invoke-McpTool $connection $name $values -AllowError:$AllowError
    if ($r.status -eq 'scheduled') { $r=WaitOp $r.request -AllowError:$AllowError }
    if ($r.result) { $r.result } else { $r }
}
function Model { (Call gp_export_json).spec }
function Undo { Call gp_undo_redo @{operation='undo'} | Out-Null }
function Redo { Call gp_undo_redo @{operation='redo'} | Out-Null }
function Cycle([string]$label, [scriptblock]$write, [scriptblock]$verify) {
    $before=Model
    & $write | Out-Null
    $after=Model; & $verify $after
    Check ((Call gp_score).dirty) "$label did not set dirty"
    Undo; Check ((Json (Model)) -eq (Json $before)) "$label Undo differs"
    Redo; Check ((Json (Model)) -eq (Json $after)) "$label Redo differs"
}
function CloseScore($document) {
    $r=Invoke-McpTool $connection gp_close @{document=$document;unsaved='discard'}
    $done=WaitOp $r.request
    Check ($done.status -eq 'closed') 'Document close failed'
    $script:owned=@($script:owned | Where-Object {$_ -ne $document})
}
function Beat($m,$t=0,$s=0,$b=0,$v=0,$k=0) { $m.tracks[$t].staves[$s].bars[$b].voices[$v].beats[$k] }
try {
    $initial=Invoke-McpTool $connection gp_documents
    $others=@($initial.documents | Sort-Object id | Select-Object id,dirty,opened_path,save_path)
    $otherModels=@{}; foreach($d in $initial.documents) { $otherModels[$d.id]=Json ((Invoke-McpTool $connection gp_export_json @{document=$d.id}).spec) }
    $empty=@{voices=@()}
    $lead=@(0,2,2,0 | ForEach-Object { @{denominator=4;notes=@(@{string=0;fret=$_})} })
    $lead[0].effects=@{pick_stroke='Down'}; $lead[0].notes[0].effects=@{palm_mute=$true}
    $lead[0].notes[0].effects.bend=@{enabled=$true;origin_value=0;middle_value=2;destination_value=0;origin_offset=0;middle_offset1=0.25;middle_offset2=0.75;destination_offset=1}
    $lead[1].notes[0].effects=@{slide=@{flags=4}}
    $lead[2].notes[0].effects=@{harmonic=@{type='Artificial';fret=12}}
    $lead[1].legato=@{origin=$true}; $lead[2].legato=@{destination=$true}
    $lead[3].notes[0].tie=@{origin=$true}
    $chain=@(0..7 | ForEach-Object { @{denominator=8;notes=@(@{string=0;fret=0;tie=@{origin=($_ -lt 7);destination=$true}})} })
    $tuplets=@(0..2 | ForEach-Object { @{denominator=4;tuplets=@{primary=@{enabled=$true;actual=3;normal=2}};notes=@(@{string=2;fret=2})} })
    $tuplets+=@{denominator=4;dots=1;notes=@()}
    $piano=@(@{denominator=1;notes=@(@{midi=67},@{midi=60;effects=@{staccato=$true}},@{midi=64})})
    $drums=@(36,38,42,38 | ForEach-Object { @{denominator=4;notes=@(@{midi=$_})} })
    $spec=@{
        metadata=@{Title='P8 Ensemble';Music='原生作曲者';Artist='P8 Artist'}
        master_bars=@(
            @{time_signature=@{numerator=4;denominator=4};key_signature=@{accidentals=1;major=$true};repeat_start=$true;section=@{name='Intro';text='前奏'}}
            @{time_signature=@{numerator=4;denominator=4};repeat_end=$true;repeat_count=2;section=@{name='Verse';text='主歌'}}
            @{time_signature=@{numerator=7;denominator=8};section=@{name='Solo';text='独奏'}}
            @{time_signature=@{numerator=3;denominator=4};section=@{name='Outro';text='尾奏'}})
        tempo_points=@(@{bar=0;position=0;value=100;unit='Quarter';linear=$false;label='Intro'},@{bar=2;position=0;value=140;unit='Quarter';linear=$true;label='Grow'})
        tracks=@(
            @{name='Guitar';template='Steel Guitar';staves=@(@{tuning=@(38,45,50,55,59,64);capo=0;bars=@(@{voices=@(@{beats=$lead},@{beats=@(@{denominator=1;notes=@(@{string=1;fret=0})})})},@{voices=@(@{beats=$chain})},@{voices=@(@{beats=$tuplets})},$empty)})}
            @{name='Piano';template='Acoustic Piano';staves=@(@{bars=@(@{voices=@(@{beats=$piano})},$empty,$empty,$empty)},@{bars=@(@{voices=@(@{beats=@(@{denominator=1;notes=@(@{midi=48})})})},$empty,$empty,$empty)})}
            @{name='Drums';template='Drumkit';staves=@(@{bars=@(@{voices=@(@{beats=$drums})},$empty,$empty,$empty)})})
    }
    $spec | ConvertTo-Json -Depth 64 | Set-Content (Join-Path $run 'input.json') -Encoding UTF8
    $created=Call gp_create_from_spec @{template='Steel Guitar';spec=$spec}
    Check ($created.status -eq 'created') 'Create from spec did not finish'
    $id=$created.document; $owned+=$id
    $new=@((Invoke-McpTool $connection gp_documents).documents | Where-Object id -EQ $id)[0]
    Check ($new.dirty -and !$new.save_path -and !$new.opened_path) 'New score path/dirty differs'
    $model=Model
    Check ($model.tracks.Count -eq 3 -and $model.tracks[1].staves.Count -eq 2) 'Mixed instruments or piano staves missing'
    Check ((Beat $model 0 0 0 1).notes[0].midi -eq 45) 'Second voice differs'
    Check ((Beat $model 1 1).notes[0].midi -eq 48) 'Piano lower staff differs'
    Check ((Beat $model 2).notes[0].midi -eq 36) 'Percussion MIDI differs'
    Check ((@((Beat $model 1).notes | Where-Object midi -EQ 60)[0]).effects.staccato) 'Unsorted piano chord effect was applied to the wrong note'
    Check (!$model.tracks[1].staves[0].PSObject.Properties['tuning'] -and !(Beat $model 1).notes[0].PSObject.Properties['fret']) 'Non-string instruments expose physical frets'
    Check ((Beat $model 0 0 1 0 3).notes[0].tie.origin -and (Beat $model 0 0 1 0 3).notes[0].tie.destination) 'Tie chain differs'
    Check ((Beat $model 0 0 2).tuplets.primary.actual -eq 3) 'Tuplet ratio differs'
    Check ((Beat $model).notes[0].effects.bend.enabled -and (Beat $model 0 0 0 0 1).notes[0].effects.slide.flags -eq 4 -and (Beat $model 0 0 0 0 2).notes[0].effects.harmonic.type -eq 'Artificial') 'Bend/slide/harmonic construction differs'
    $timeline=Call gp_playback @{operation='timeline'}
    $evidence+=@{playback=$timeline}
    Check ($timeline.bars.Count -gt 4) 'Repeat did not expand the playback timeline'
    Undo; Check ((Model).tracks.Count -eq 1) 'Creation was not one native undo'
    Redo; Check ((Json (Model)) -eq (Json $model)) 'Creation redo differs'
    $round=Call gp_import_json @{spec=$model}
    Check ($round.status -eq 'unchanged' -and (Json (Model)) -eq (Json $model)) 'Full JSON round trip differs'
    # Same content into another document exercises a real import, not only a no-op.
    $target=Call gp_new @{template='Steel Guitar'}; $targetId=$target.document; $owned+=$targetId
    $targetBefore=(Invoke-McpTool $second gp_export_json @{document=$targetId}).spec
    $imported=Call gp_import_json @{document=$targetId;spec=(Json $model)}
    Check ($imported.status -eq 'applied') 'JSON import into a new score did not apply'
    Check ((Json ((Invoke-McpTool $second gp_export_json @{document=$targetId}).spec)) -eq (Json $model)) 'Second client sees a different imported model'
    Invoke-McpTool $second gp_undo_redo @{document=$targetId;operation='undo'} | Out-Null
    Check ((Json ((Invoke-McpTool $second gp_export_json @{document=$targetId}).spec)) -eq (Json $targetBefore)) 'Import Undo differs'
    Invoke-McpTool $second gp_undo_redo @{document=$targetId;operation='redo'} | Out-Null
    Check ((Json ((Invoke-McpTool $second gp_export_json @{document=$targetId}).spec)) -eq (Json $model)) 'Import Redo differs'
    CloseScore $targetId
    $cursor=(Call gp_score).cursor; $ascii=Call gp_export_tab @{track=0;staff=0;bar=0;count=4}
    Check (!$ascii.reversible -and $ascii.unrepresented.Count -ge 4 -and $ascii.text.Contains('bar 2 voice 0') -and $ascii.text.Contains('38|')) 'ASCII annotations/tuning/bar boundaries missing'
    Check ((Json (Call gp_score).cursor) -eq (Json $cursor)) 'ASCII export changed cursor'
    $ascii.text | Set-Content (Join-Path $run 'score.txt') -Encoding UTF8
    Check ((Call gp_structure).sections[1].start_bar -eq 1) 'Structure sections differ'
    Cycle 'Riff replace' { Call gp_insert_tab @{text='0-2-2-r';mode='replace';bar=3;track=0;staff=0;voice=0;string=0;denominator=8} } { param($m) Check ((Beat $m 0 0 3 0 3).rest) 'Riff rest missing' }
    Cycle 'Riff insert' { Call gp_insert_tab @{text='3-5';mode='insert';bar=1;track=0;staff=0;voice=1;string=1} } { param($m) Check ($m.master_bars.Count -eq 5 -and (Beat $m 0 0 1 1).notes[0].fret -eq 3) 'Riff insertion differs' }
    Undo
    Cycle 'Riff append' { Call gp_insert_tab @{text='3-5|7-r';mode='append';track=0;staff=0;voice=0;string=0} } { param($m) Check ($m.master_bars.Count -eq 6 -and (Beat $m 0 0 5 0 1).rest) 'Riff append differs' }
    Undo
    $append=@{master_bars=@(@{time_signature=@{numerator=4;denominator=4}});tracks=@(@{staves=@(@{bars=@($empty)})},@{staves=@(@{bars=@($empty)},@{bars=@($empty)})},@{staves=@(@{bars=@($empty)})})}
    Cycle 'Append spec' { Call gp_apply_spec @{mode='append';spec=$append} } { param($m) Check ($m.master_bars.Count -eq 5) 'Append count differs' }
    Cycle 'Insert spec' { Call gp_apply_spec @{mode='insert';bar=1;spec=$append} } { param($m) Check ($m.master_bars.Count -eq 6 -and $m.master_bars[2].section.name -eq 'Verse') 'Insert shifted section incorrectly' }
    $chord=@{root='A';bass='E';type=11;name='Am7/E';diagram=@{first_fret=5;frets=@(5,7,5,5,5,5);barres=@(@{from_string=0;to_string=5;fret=1});fingers=@(@{string=0;fret=1;finger=1},@{string=1;fret=3;finger=3})}}
    $position=@{track=0;staff=0;bar=0;voice=0;beat=0}
    Cycle 'Chord diagram' { Call gp_edit_chord ($position+@{chord=$chord}) } { param($m) $d=(Beat $m).chord.diagram; Check ($d.first_fret -eq 5 -and $d.barres[0].to_string -eq 5 -and $d.fingers.Count -eq 3 -and $d.fingers[1].string -eq 1) 'Chord diagram readback differs' }
    Cycle 'Piano chord symbol' { Call gp_edit_chord @{track=1;staff=1;bar=0;voice=0;beat=0;chord=@{root='C';type=0;name='C lower staff'}} } { param($m) Check ((Beat $m 1 1).chord.name -eq 'C lower staff' -and !(Beat $m 1).chord) 'Piano chord staff isolation differs' }
    Cycle 'Chord removal' { Call gp_edit_chord ($position+@{operation='remove'}) } { param($m) Check (!(Beat $m).chord) 'Chord removal differs' }
    Undo
    foreach($line in 0..4) { Cycle "Lyrics line $line" { Call gp_edit_lyrics ($position+@{line=$line;text="歌词 $line - la"}) } { param($m) Check ((Beat $m).lyrics.Count -eq ($line+1)) 'Lyrics line count differs' } }
    Cycle 'Piano lyrics' { Call gp_edit_lyrics @{track=1;staff=1;bar=0;voice=0;beat=0;line=0;text='低音声部'} } { param($m) Check ((Beat $m 1 1).lyrics[0].text -eq '低音声部' -and !(Beat $m 1).lyrics.Count) 'Piano lyric isolation differs' }
    Cycle 'Lyrics clear' { Call gp_edit_lyrics ($position+@{line=4;text=''}) } { param($m) Check ((Beat $m).lyrics.Count -eq 4) 'Lyrics removal differs' }
    Undo
    Cycle 'Section set' { Call gp_edit_section @{bar=1;name='Chorus';text='副歌'} } { param($m) Check ($m.master_bars[1].section.name -eq 'Chorus') 'Section did not persist' }
    Cycle 'Section remove' { Call gp_edit_section @{bar=1;operation='remove'} } { param($m) Check (!$m.master_bars[1].section) 'Section removal differs' }
    Undo
    $page=@{title='P8 Page';author='P8 Author';composer='P8 Composer';copyright='Copyright P8';first_footer=@{text='P8 FIRST FOOTER';visibility=0};even_header=@{text='P8 HEADER %PAGE%';visibility=0};odd_header=@{text='P8 HEADER %PAGE%';visibility=0};even_footer=@{text='P8 FOOTER';visibility=0};odd_footer=@{text='P8 FOOTER';visibility=0};first_page_number=@{text='P8 PAGE %PAGE%/%PAGES%';visibility=0}}
    Cycle 'Page metadata' { Call gp_presentation @{operation='set';page_metadata=$page} } { param($m) Check ($m.metadata.Title -eq 'P8 Page' -and $m.page_metadata.first_footer.text -eq 'P8 FIRST FOOTER') 'Page metadata readback differs' }
    # Reject malformed or unrepresentable fields before a live replacement.
    foreach($case in @(
        @{tool='gp_apply_spec';args=@{spec=@{master_bars=@(@{});tracks=@()}}}
        @{tool='gp_apply_spec';args=@{mode='append';spec=@{master_bars=@(@{});tracks=@(@{staves=@(@{tuning=@(40,45,50,55,59,64);bars=@($empty)})},@{staves=@(@{bars=@($empty)},@{bars=@($empty)})},@{staves=@(@{bars=@($empty)})})}}}
        @{tool='gp_presentation';args=@{operation='set';page_metadata=@{title='must not write';unknown='reject'}}}
        @{tool='gp_edit_lyrics';args=@{track=0;staff=0;bar=0;voice=0;beat=0;line=5;text='reject'}}
        @{tool='gp_edit_chord';args=$position+@{chord=@{root='H';type=0}}}
        @{tool='gp_insert_tab';args=@{text='0-999';mode='replace';bar=0}}
        @{tool='gp_apply_spec';args=@{document=[guid]::NewGuid().ToString();spec=$append}}
    )) {
        $before=Model; $r=Call $case.tool $case.args -AllowError
        Check ($r.error -and !$r.outcome_unknown) "Invalid request accepted or unknown: $(Json $case)"
        Check ((Json (Model)) -eq (Json $before)) 'Rejected input changed model'
    }
    if (!$SkipFaults) {
    # Scheduled edits bind the explicit document; a second client cannot overtake them.
    $pending=Invoke-McpTool $connection gp_apply_spec @{document=$id;spec=$append;mode='append';debug_delay_ms=2000}
    $blocked=Invoke-McpTool $second gp_edit_metadata @{document=$id;property='Title';value='overtake'} -AllowError
    Check ($blocked.error -match 'pending') 'Second client overtook a scheduled batch'
    $cancelled=Invoke-McpTool $second gp_cancel @{request=$pending.request}
    Check ($cancelled.status -eq 'cancelled' -and (WaitOp $pending.request).status -eq 'cancelled') 'Scheduled batch cancellation differs'
    foreach($fault in 'before_commit','after_commit') {
        $before=Model
        $pending=Invoke-McpTool $connection gp_apply_spec @{document=$id;spec=$append;mode='append';debug_fault=$fault}
        $failed=WaitOp $pending.request -AllowError
        Check ($failed.outcome_unknown -and $failed.recovery_available) 'Unknown native result is not recoverable'
        $blocked=Invoke-McpTool $second gp_undo_redo @{document=$id;operation='undo'} -AllowError
        Check ($blocked.error -match 'pending') 'Unknown result did not block edits'
        $recover=Invoke-McpTool $second gp_recover @{request=$pending.request}
        Check ($recover.status -eq 'recovered' -and $recover.resolution -eq $(if($fault -eq 'before_commit'){'not_applied'}else{'applied'})) 'Recovery guessed an incorrect outcome'
        if($fault -eq 'after_commit') { Check ((Model).master_bars.Count -eq ($before.master_bars.Count+1)) 'Replacement was replayed during recovery'; Undo }
        Check ((Json (Model)) -eq (Json $before)) 'Recovery changed the previous model'
    }
    }
    $final=Model
    $final | ConvertTo-Json -Depth 64 | Set-Content (Join-Path $run 'export.json') -Encoding UTF8
    $path=Join-Path $run 'score.gp'
    Call gp_save_as @{path=$path} | Out-Null
    $hash=(Get-FileHash $path).Hash
    $zip=[IO.Compression.ZipFile]::OpenRead($path)
    try { $reader=[IO.StreamReader]::new($zip.GetEntry('Content/score.gpif').Open()); [xml]$gpif=$reader.ReadToEnd(); $reader.Dispose() } finally { $zip.Dispose() }
    Check ($gpif.SelectSingleNode('/GPIF/Score/Title').InnerText -eq 'P8 Page') 'Saved GPIF title differs'
    Check ($gpif.OuterXml.Contains('歌词 4') -and $gpif.OuterXml.Contains('Am7/E') -and $gpif.OuterXml.Contains('Chorus')) 'Saved GPIF semantic objects missing'
    Check ($gpif.SelectSingleNode('//Fingering/Position[@finger="Ring" and @fret="3" and @string="1"]')) 'Saved chord fingering differs'
    CloseScore $id; $id=''
    $opened=Call gp_open @{path=$path}; $id=$opened.document; $owned+=$id
    Check ((Json (Model)) -eq (Json $final)) 'Saved/reopened full semantic model differs'
    Check ((Get-FileHash $path).Hash -eq $hash -and !(Call gp_score).dirty) 'Reopen changed bytes/dirty'
    $round=Call gp_import_json @{spec=(Model)}
    Check ($round.status -eq 'unchanged') 'Chord/lyrics/page JSON round trip differs'
    Call gp_presentation @{operation='set';height=150;top=12;bottom=12} | Out-Null
    $pdf=Call gp_export @{path=(Join-Path $run 'pages.pdf')}; $png=Call gp_export @{path=(Join-Path $run 'page.png')}
    Check ($pdf.pages -ge 2 -and $png.width -gt 0) 'Page output did not produce multiple pages'
    if($RenderPdf) {
        if ($PdfTextPython) {
            & $PdfTextPython -c 'from pypdf import PdfReader; import pathlib,sys; pathlib.Path(sys.argv[2]).write_text("\n".join(p.extract_text() for p in PdfReader(sys.argv[1]).pages),encoding="utf-8")' (Join-Path $run 'pages.pdf') (Join-Path $run 'pages.txt')
        } else { & pdftotext -layout (Join-Path $run 'pages.pdf') (Join-Path $run 'pages.txt') }
        Check ($LASTEXITCODE -eq 0) 'PDF text extraction failed'
        $text=Get-Content (Join-Path $run 'pages.txt') -Raw
        foreach($marker in 'P8 Page','P8 Author','P8 Composer','Copyright P8','P8 FIRST FOOTER','P8 HEADER 2','P8 PAGE 1/') { Check ($text.Contains($marker)) "PDF missing $marker" }
        & pdftoppm -f 1 -singlefile -scale-to 900 -png (Join-Path $run 'pages.pdf') (Join-Path $run 'render')
        Check ($LASTEXITCODE -eq 0) 'PDF rendering failed'
    }
    CloseScore $id; $id=''
    $remaining=Invoke-McpTool $connection gp_documents
    Check ((Json @($remaining.documents | Sort-Object id | Select-Object id,dirty,opened_path,save_path)) -eq (Json $others)) 'Other document identities or dirty states changed'
    foreach($d in $remaining.documents) { Check ((Json ((Invoke-McpTool $second gp_export_json @{document=$d.id}).spec)) -eq $otherModels[$d.id]) 'Other document model changed' }
    $complete=$true
} finally {
    if($complete) { foreach($document in @($owned)) { CloseScore $document } }
    $module=(Get-Process -Id $connection.Pid).Modules | Where-Object ModuleName -EQ 'guitarpro_mcp.dll'
    $sources=@(Get-ChildItem -LiteralPath @((Join-Path $root 'native'),$PSScriptRoot) -File | Where-Object Extension -In @('.h','.cpp','.ps1','.def') | Get-FileHash | Select-Object Path,Hash)
    $report=@{complete=$complete;checks=$checks;last_check=$lastCheck;pid=$connection.Pid;plugin_path=$module.FileName;plugin_sha256=(Get-FileHash $module.FileName).Hash;sources=$sources;render_pdf=[bool]$RenderPdf;faults=(-not [bool]$SkipFaults);operations=$evidence}
    $report | ConvertTo-Json -Depth 64 | Set-Content (Join-Path $run 'verification.json') -Encoding UTF8
    Close-McpSession $second; Close-McpSession $connection
    Write-Output "P8 checks=$checks complete=$complete evidence=$run"
}
if ($complete) { Write-Output "PASS: $checks P8 native semantic checks. Evidence: $run" }
