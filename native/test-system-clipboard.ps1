param([string]$SessionFile="$PSScriptRoot/../.cache/native-session.json")
$ErrorActionPreference='Stop'
. "$PSScriptRoot/mcp-client.ps1"
$root=Split-Path -Parent $PSScriptRoot
$env:TEMP=Join-Path $root '.cache/tmp'
$env:TMP=$env:TEMP
if(-not ('IsolatedClipboardTest' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public sealed class IsolatedClipboardTest : IDisposable {
 [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr handle,int index,StringBuilder name,uint size,out uint needed);
 [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
 [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr window);
 [DllImport("user32.dll")] static extern bool CloseClipboard();
 [DllImport("user32.dll")] static extern bool EmptyClipboard();
 [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format,IntPtr data);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint ex,string cls,string name,uint style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
 [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
 [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags,UIntPtr length);
 [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr data);
 [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr data);
 [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr data);
 IntPtr window;
 public static string VerifyStation() {
  uint needed;var name=new StringBuilder(256);
  if(!GetUserObjectInformation(GetProcessWindowStation(),2,name,512,out needed) || !name.ToString().StartsWith("GuitarProMCP-Test-",StringComparison.Ordinal))
   throw new Exception("Run this test in an isolated GuitarProMCP-Test-* window station; the user clipboard must not be used");
  return name.ToString();
 }
 public IsolatedClipboardTest() {
  VerifyStation();
  window=CreateWindowEx(0,"STATIC","Isolated clipboard test",0,0,0,0,0,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
  if(window==IntPtr.Zero)throw new Exception("Cannot create isolated clipboard owner");
 }
 public void Replace(bool scoreMarker) {
  VerifyStation();
  var bytes=scoreMarker ? new byte[]{32} : Encoding.Unicode.GetBytes("GuitarProMCP isolated test\0");
  uint format=scoreMarker ? RegisterClipboardFormat("app/gp") : 13;
  var data=GlobalAlloc(2,(UIntPtr)bytes.Length);
  if(format==0 || data==IntPtr.Zero)throw new Exception("Cannot allocate test clipboard");
  bool opened=false;
  try {
   var pointer=GlobalLock(data);if(pointer==IntPtr.Zero)throw new Exception("Cannot lock clipboard allocation");
   Marshal.Copy(bytes,0,pointer,bytes.Length);GlobalUnlock(data);
   opened=OpenClipboard(window);if(!opened || !EmptyClipboard())throw new Exception("Isolated clipboard is busy");
   if(SetClipboardData(format,data)==IntPtr.Zero)throw new Exception("Cannot publish isolated clipboard");
   data=IntPtr.Zero;
  } finally {if(opened)CloseClipboard();if(data!=IntPtr.Zero)GlobalFree(data);}
 }
 public void Dispose(){if(window!=IntPtr.Zero){DestroyWindow(window);window=IntPtr.Zero;}}
}
'@
}
$station=[IsolatedClipboardTest]::VerifyStation()
$checks=0
function Assert($condition,[string]$message){if(-not $condition){throw $message};$script:checks++;$script:lastCheck=$message}
function Json($value){ConvertTo-Json -InputObject $value -Depth 24 -Compress}
function Point([int]$bar,[int]$beat,[int]$track=0,[int]$voice=0,[int]$staff=0){@{track=$track;staff=$staff;bar=$bar;voice=$voice;beat=$beat}}
$connection=New-McpSession -SessionFile $SessionFile
function Tool([string]$name,[hashtable]$arguments=@{}){Invoke-McpTool $connection $name $arguments}
function Clip([hashtable]$arguments=@{}){Tool gp_clipboard $arguments}
function Select-Range([string]$document,$from,$to,[bool]$allVoices=$false,[bool]$allTracks=$false){Tool gp_selection @{document=$document;operation='range';base=$from;extent=$to;all_voices=$allVoices;all_tracks=$allTracks} | Out-Null}
function Bars([string]$document,[int]$track=0,[int]$staff=0,[int]$count=2){,(Tool gp_read_bars @{document=$document;track=$track;staff=$staff;count=$count}).bars}
function Musical($beats){@($beats | Select-Object notes,rhythm,native_note_value,dots,rest,placeholder)}
function Undo([string]$document){Tool gp_undo_redo @{document=$document;operation='undo'} | Out-Null}
function Open-Score([string]$path){
    Tool gp_open @{path=$path} | Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $found=@((Tool gp_documents).documents | Where-Object opened_path -EQ $path.Replace('\','/'))
        if($found.Count -eq 1){return $found[0].id}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'Native open did not complete'
}
function Close-Score([string]$document){
    $request=Tool gp_close @{document=$document}
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $state=Tool gp_documents
        if($state.closing.request -eq $request.request -and $state.closing.status -eq 'closed'){return}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'Native close did not complete'
}
function NativeCopy([string]$document){
    $state=Clip @{operation='native_state'}
    $copy=Clip @{operation='native_copy';document=$document;sequence=$state.sequence}
    $state=Clip @{operation='native_state'}
    Assert ($state.available -and $state.owned_by_host -and $state.score_marker -and $state.sequence -eq $copy.native_sequence) 'Native copy did not publish a host-owned score'
    return $copy
}
function Import {
    $state=Clip @{operation='native_state'}
    Clip @{operation='native_import';sequence=$state.sequence}
}
function Reject([hashtable]$arguments){
    $before=Json (Clip)
    $sequence=[IsolatedClipboardTest]::GetClipboardSequenceNumber()
    $rejected=$false
    try{$rejected=[bool](Invoke-McpTool $connection gp_clipboard $arguments -AllowError).error}catch{$rejected=$true}
    Assert $rejected "Invalid system clipboard request was accepted: $(Json $arguments)"
    Assert ((Json (Clip)) -eq $before -and [IsolatedClipboardTest]::GetClipboardSequenceNumber() -eq $sequence) 'Rejected request changed a clipboard'
}
$external=$null
try {
    $identity=Tool gp_capabilities
    Assert ($identity.window_station -eq $station) 'Host and test must share the isolated window station'
    Assert ($identity.hidden_mode -and $identity.pid -ne $identity.foreground_pid -and $identity.qt_thread) 'Host is not running in native background mode'
    $external=[IsolatedClipboardTest]::new()
    $others=(Tool gp_documents).documents
    $run=Join-Path $root ('artifacts/native-system-clipboard-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $fixture=Join-Path $PSScriptRoot 'testdata/minimal.gp'
    $fixtureHash=(Get-FileHash -LiteralPath $fixture).Hash
    $sourcePath=Join-Path $run 'source.gp';$targetPath=Join-Path $run 'target.gp'
    Copy-Item -LiteralPath $fixture -Destination $sourcePath
    Copy-Item -LiteralPath $fixture -Destination $targetPath
    $source=Open-Score $sourcePath;$target=Open-Score $targetPath
    Select-Range $source (Point 0 0) (Point 0 1)
    Tool gp_activate @{document=$target} | Out-Null
    $sourceBefore=Json (Tool gp_score @{document=$source})
    $bufferBefore=Json (Clip)
    $copy=NativeCopy $source
    Assert ((Json (Tool gp_score @{document=$source})) -eq $sourceBefore -and (Tool gp_documents).active_document -eq $target) 'Native copy changed source or active document'
    Assert ((Json (Clip)) -eq $bufferBefore) 'Native copy changed the independent plugin clipboard'
    $firstImport=Import
    $copied=(Clip @{operation='read';id=$firstImport.id}).bars
    $sourceBars=Bars $source
    Assert ((Json (Musical $copied[0].voices[0].beats)) -eq (Json (Musical $sourceBars[0].voices[0].beats[0..1]))) 'Native copy lost the selected notes'
    foreach($invalid in @(@{operation='native_import'},@{operation='native_copy';document=$source},@{operation='native_import';sequence=0},@{operation='native_copy';document=$source;sequence=0},@{operation='native_state';id='unused'})){Reject $invalid}
    Select-Range $target (Point 0 2) (Point 0 2)
    Tool gp_selection @{document=$target;operation='clear'} | Out-Null
    $before=Bars $target
    Clip @{operation='paste';document=$target;id=$firstImport.id} | Out-Null
    $after=Bars $target
    Assert ($after[0].voices[0].beats.Count -eq 6 -and (Json (Musical $after[0].voices[0].beats[2..3])) -eq (Json (Musical $copied[0].voices[0].beats))) 'Native paste did not consume the imported host snapshot'
    Undo $target
    Assert ((Json (Bars $target)) -eq (Json $before)) 'Native paste undo differs'
    Select-Range $source (Point 0 2) (Point 0 3)
    NativeCopy $source | Out-Null
    Clip @{operation='clear'} | Out-Null
    Assert (-not (Clip).available -and (Clip @{operation='native_state'}).available) 'Clearing plugin buffer also cleared host clipboard'
    $imported=Import
    $importData=(Clip @{operation='read';id=$imported.id}).bars
    Assert ((Json (Musical $importData[0].voices[0].beats)) -eq (Json (Musical $sourceBars[0].voices[0].beats[2..3]))) 'MCP import did not read the latest host copy'
    foreach($beat in 0,1,2,3){
        Select-Range $source (Point 0 $beat) (Point 0 $beat)
        NativeCopy $source | Out-Null
        Assert ((Json (Clip @{operation='read';id=$imported.id}).bars) -eq (Json $importData)) 'Imported snapshot was invalidated by later native copies'
    }
    Close-Score $source
    Assert ((Json (Clip @{operation='read';id=$imported.id}).bars) -eq (Json $importData) -and (Clip @{operation='native_state'}).available) 'Closing source invalidated retained clipboard snapshots'
    Select-Range $target (Point 0 0) (Point 0 0)
    Tool gp_selection @{document=$target;operation='clear'} | Out-Null
    Clip @{operation='paste';document=$target;id=$imported.id} | Out-Null
    $pasted=Bars $target
    Assert ((Json (Musical $pasted[0].voices[0].beats[0..1])) -eq (Json (Musical $importData[0].voices[0].beats))) 'Imported fragment paste differs after source close'
    $saved=Tool gp_save @{document=$target;path=(Join-Path $run 'imported-paste.gp')}
    $reloaded=Open-Score $saved.path
    Assert ((Json (Bars $reloaded)) -eq (Json $pasted)) 'Native clipboard paste did not survive save/open'
    Close-Score $reloaded
    Undo $target
    Assert ((Json (Bars $target)) -eq (Json $before)) 'Imported paste undo differs'
    foreach($marker in $false,$true){
        $external.Replace($marker)
        $state=Clip @{operation='native_state'}
        Assert (-not $state.available -and -not $state.owned_by_host -and $state.stable) 'External clipboard content was mistaken for the cached host score'
        Reject @{operation='native_import';sequence=$state.sequence}
        Assert ((Json (Clip @{operation='read';id=$imported.id}).bars) -eq (Json $importData)) 'External clipboard change invalidated the independent imported snapshot'
    }
    Tool gp_save_as @{document=$target;path=(Join-Path $run 'target-restored.gp')} | Out-Null
    Close-Score $target
    Clip @{operation='clear'} | Out-Null
    Assert ((Json ((Tool gp_documents).documents | Select-Object id,save_path,dirty)) -eq (Json ($others | Select-Object id,save_path,dirty))) 'Clipboard checks changed other documents'
    $afterIdentity=Tool gp_capabilities
    Assert ($afterIdentity.pid -eq $identity.pid -and $afterIdentity.hidden_mode -and $afterIdentity.foreground_pid -ne $afterIdentity.pid) 'Native clipboard operations activated or restarted the host'
    Assert ((Get-FileHash -LiteralPath $fixture).Hash -eq $fixtureHash) 'Fixture changed'
    @{checks=$checks;identity_before=$identity;identity_after=$afterIdentity;copy=$copy;imported=$imported;pasted=$pasted;saved=$saved.path} | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath (Join-Path $run 'verification.json')
    Write-Output "PASS: $checks isolated native system clipboard checks. Evidence: $run"
}catch{
    $failure=$_
    try {if($run){@{checks=$checks;error=$failure.ToString();documents=(Tool gp_documents);native_clipboard=(Clip @{operation='native_state'})} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $run 'failure.json')}}catch{}
    Write-Output "Failed after $checks checks; last passed assertion: $lastCheck"
    throw $failure
}finally{
    if($external){$external.Dispose()}
    Close-McpSession $connection
}
