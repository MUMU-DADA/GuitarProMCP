param([Parameter(Mandatory=$true)][string]$Directory)
$ErrorActionPreference='Stop'
# A deliberately restricted reader for the plain two-bar fixture, independent
# of GPCore. Unsupported GP5 features fail instead of being silently skipped.
$expected='40,42,43,45,47,48,50,52'
function Require($condition,$message) { if (-not $condition) { throw $message } }
function Skip($count) { Require ($reader.ReadBytes($count).Length -eq $count) 'Truncated GP5' }
function GpString {
    $length=$reader.ReadInt32(); Require ($length -ge 1 -and $length -lt 4096) 'Invalid GP5 string'
    $count=$reader.ReadByte(); Require ($length -eq $count+1) 'GP5 string length differs'
    [Text.Encoding]::UTF8.GetString($reader.ReadBytes($count))
}
$reader=[IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $Directory 'score.gp5')))
try {
    $version=$reader.ReadBytes(31)
    Require ([Text.Encoding]::ASCII.GetString($version,1,$version[0]) -eq 'FICHIER GUITAR PRO v5.10') 'Expected GP5.10'
    $title=GpString; 1..8 | ForEach-Object { GpString | Out-Null }
    Require ($title -eq 'MCP Test' -and $reader.ReadInt32() -eq 0) 'GP5 metadata differs'
    Skip 4
    1..5 | ForEach-Object { Skip 4; $length=$reader.ReadInt32(); Require ($length -ge 0 -and $length -lt 4096) 'Invalid lyric length'; Skip $length }
    Skip 19 # Master RSE volume, reserved field and equalizer.
    Skip 30 # Page dimensions, scale and header/footer flags.
    1..10 | ForEach-Object { GpString | Out-Null }
    GpString | Out-Null; $tempo=$reader.ReadInt32(); Skip 6
    Skip (64*12+19*2+4) # MIDI channels, navigation and master reverb.
    $measures=$reader.ReadInt32(); $tracks=$reader.ReadInt32()
    Require ($measures -eq 2 -and $tracks -eq 1 -and $tempo -eq 90) 'GP5 score dimensions differ'
    for ($bar=0; $bar -lt $measures; $bar++) {
        if ($bar) { Skip 1 }
        $flags=$reader.ReadByte(); Require (($flags -band 0xbc) -eq 0) 'Unsupported GP5 measure flags'
        if ($flags -band 1) { Require ($reader.ReadByte() -eq 4) 'GP5 numerator differs' }
        if ($flags -band 2) { Require ($reader.ReadByte() -eq 4) 'GP5 denominator differs' }
        if ($flags -band 64) { Skip 2 }
        if ($flags -band 3) { Skip 4 }
        Skip 2
    }
    Skip 1; $trackFlags=$reader.ReadByte(); Require (($trackFlags -band 1) -eq 0) 'Unexpected percussion'
    Skip 41; $strings=$reader.ReadInt32(); $tuning=@(1..7 | ForEach-Object {$reader.ReadInt32()})
    Require ($strings -eq 6) 'GP5 string count differs'
    Skip 24 # Port, channels, fret count, capo and color.
    Skip 49 # GP5.10 display, RSE instrument and equalizer settings.
    GpString | Out-Null; GpString | Out-Null; Skip 1
    $notes=@()
    for ($bar=0; $bar -lt $measures; $bar++) {
        for ($voice=0; $voice -lt 2; $voice++) {
            $beats=$reader.ReadInt32(); Require ($beats -ge 0 -and $beats -le 4) 'GP5 beat count differs'
            for ($beat=0; $beat -lt $beats; $beat++) {
                $flags=$reader.ReadByte(); Require ($flags -in @(0,64)) 'Unsupported GP5 beat flags'
                if ($flags -band 64) { Require ($reader.ReadByte() -eq 0) 'Unexpected GP5 rest' }
                Require ($reader.ReadSByte() -eq 0) 'Expected GP5 quarter duration'
                $mask=$reader.ReadByte()
                for ($str=1; $str -le 7; $str++) { if ($mask -band (1 -shl (7-$str))) {
                    Require ($reader.ReadByte() -eq 32 -and $reader.ReadByte() -eq 1) 'Unsupported GP5 note flags'
                    $fret=$reader.ReadByte(); $notes += $tuning[$str-1]+$fret
                    Require ($reader.ReadByte() -eq 0) 'Unsupported GP5 note extension'
                } }
                Require ($reader.ReadUInt16() -eq 0) 'Unsupported GP5 beat extension'
            }
        }
        if ($bar+1 -lt $measures) { Skip 1 }
    }
    Require (($notes -join ',') -eq $expected -and $reader.BaseStream.Position -eq $reader.BaseStream.Length) 'GP5 notes or trailing content differs'
} finally { $reader.Dispose() }
if (-not ('P6GpxReader' -as [type])) { Add-Type @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
public static class P6GpxReader {
    sealed class Bits {
        byte[] data; int bit=64;
        public Bits(byte[] bytes) { data=bytes; }
        public int Read(int count, bool reverse=false) {
            int value=0;
            for(int i=0;i<count;i++) {
                if(bit>=data.Length*8) throw new InvalidDataException("Truncated GPX");
                int b=(data[bit/8]>>(7-bit%8))&1; bit++;
                if(reverse) value |= b<<i; else value=(value<<1)|b;
            }
            return value;
        }
    }
    public static byte[] Score(byte[] input) {
        if(Encoding.ASCII.GetString(input,0,4)!="BCFZ") throw new InvalidDataException("Expected compressed GPX");
        int length=BitConverter.ToInt32(input,4);
        if(length<4096 || length>16000000) throw new InvalidDataException("GPX size bound");
        var bits=new Bits(input); var output=new List<byte>(length);
        while(output.Count<length) {
            if(bits.Read(1)==1) {
                int width=bits.Read(4), offset=bits.Read(width,true), count=bits.Read(width,true);
                if(offset<1 || offset>output.Count || count<1) throw new InvalidDataException("Invalid GPX reference");
                int start=output.Count-offset;
                for(int i=0;i<Math.Min(offset,count);i++) output.Add(output[start+i]);
            } else {
                int count=bits.Read(2,true);
                for(int i=0;i<count;i++) output.Add((byte)bits.Read(8));
            }
        }
        byte[] fs=output.ToArray();
        if(fs.Length!=length || Encoding.ASCII.GetString(fs,0,4)!="BCFS") throw new InvalidDataException("Invalid GPX filesystem");
        for(int block=4;block+4096<=fs.Length;block+=4096) {
            if(BitConverter.ToInt32(fs,block)!=2) continue;
            string name=Encoding.ASCII.GetString(fs,block+4,127).TrimEnd('\0');
            if(name!="score.gpif") continue;
            int size=BitConverter.ToInt32(fs,block+0x8c);
            using(var stream=new MemoryStream()) {
                for(int index=0;stream.Length<size;index++) {
                    if(index>=997) throw new InvalidDataException("GPX block table bound");
                    int sector=BitConverter.ToInt32(fs,block+0x94+index*4), at=4+sector*4096;
                    if(sector<=0 || at+4096>fs.Length) throw new InvalidDataException("Invalid GPX sector");
                    stream.Write(fs,at,Math.Min(4096,size-(int)stream.Length));
                }
                return stream.ToArray();
            }
        }
        throw new InvalidDataException("GPX score missing");
    }
}
'@ }
$bytes=[P6GpxReader]::Score([IO.File]::ReadAllBytes((Join-Path $Directory 'score.gpx')))
$gpif=[Xml.XmlDocument]::new(); $gpif.XmlResolver=$null; $gpif.LoadXml([Text.Encoding]::UTF8.GetString($bytes))
Require ($gpif.SelectNodes('/GPIF/Tracks/Track').Count -eq 1 -and $gpif.SelectNodes('/GPIF/MasterBars/MasterBar').Count -eq 2) 'GPX score structure differs'
$gpNotes=@($gpif.SelectNodes('/GPIF/Notes/Note') | ForEach-Object { [int]$_.Properties.SelectSingleNode('Property[@name="Midi"]/Number').InnerText })
# GPIF's string/fret notes have no Midi property; resolve their physical pitch.
if (($gpNotes -join ',') -ne $expected) {
    $tuning=@(40,45,50,55,59,64)
    $gpNotes=@($gpif.SelectNodes('/GPIF/Notes/Note') | ForEach-Object { $tuning[[int]$_.Properties.SelectSingleNode('Property[@name="String"]/String').InnerText]+[int]$_.Properties.SelectSingleNode('Property[@name="Fret"]/Fret').InnerText })
}
Require (($gpNotes -join ',') -eq $expected) 'GPX pitches differ'
function BE($count) { $value=0; 1..$count | ForEach-Object {$value=($value -shl 8) -bor $reader.ReadByte()}; $value }
function VLQ { $value=0; for($i=0;$i -lt 4;$i++) {$b=$reader.ReadByte();$value=($value -shl 7) -bor ($b -band 127);if($b -lt 128){return $value}}; throw 'Invalid MIDI delta' }
$reader=[IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $Directory 'score.mid')))
try {
    Require ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -eq 'MThd' -and (BE 4) -eq 6 -and (BE 2) -eq 1) 'Invalid MIDI header'
    $tracks=BE 2; $division=BE 2; $midiNotes=@(); $durations=@(); $tempo=0
    for($track=0;$track -lt $tracks;$track++) {
        Require ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -eq 'MTrk') 'Missing MIDI track'
        $length=BE 4; $end=$reader.BaseStream.Position+$length; $tick=0; $active=@{}; $running=0
        while($reader.BaseStream.Position -lt $end) {
            $tick+=VLQ; $status=$reader.ReadByte()
            if($status -lt 128) {$reader.BaseStream.Position--; $status=$running} elseif($status -lt 240) {$running=$status}
            if($status -eq 255) {
                $type=$reader.ReadByte();$length=VLQ;$data=$reader.ReadBytes($length)
                if($type -eq 81) {$tempo=([int]$data[0] -shl 16) -bor ([int]$data[1] -shl 8) -bor [int]$data[2]}
            } elseif(($status -band 240) -in @(128,144,176,192,224)) {
                $a=$reader.ReadByte();$b=if(($status -band 240) -ne 192){$reader.ReadByte()}else{0}
                if(($status -band 240) -eq 144 -and $b -gt 0) {$midiNotes+=$a;$active[$a]=$tick}
                elseif(($status -band 240) -eq 128 -or (($status -band 240) -eq 144 -and $b -eq 0)) {Require ($active.ContainsKey($a)) 'Unpaired MIDI note';$durations+=$tick-$active[$a];$active.Remove($a)}
            } else {throw 'Unsupported fixture MIDI event'}
        }
        Require ($reader.BaseStream.Position -eq $end -and $active.Count -eq 0) 'MIDI track length differs'
    }
    Require (($midiNotes -join ',') -eq $expected -and $durations.Count -eq 8 -and @($durations | Where-Object {$_ -ne $division}).Count -eq 0) 'MIDI pitch or rhythm differs'
    Require ($tempo -eq 666666 -and $reader.BaseStream.Position -eq $reader.BaseStream.Length) 'MIDI tempo or length differs'
} finally {$reader.Dispose()}
@{gp5_notes=$notes;gpx_notes=$gpNotes;midi_notes=$midiNotes;midi_note_ticks=$durations;midi_division=$division;midi_microseconds_per_quarter=$tempo}
