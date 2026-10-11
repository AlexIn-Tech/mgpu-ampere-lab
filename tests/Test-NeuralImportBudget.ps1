$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)}}
$repo=Split-Path $PSScriptRoot -Parent
if(-not ('NeuralGaming.Native.PinImports' -as [type])){
    Add-Type -Path (Join-Path $repo 'native\NeuralPinImports.cs') -ErrorAction Stop
}
# Build data only: these files are inspected, never loaded or executed.
if(-not ('NeuralImportBudgetFixture' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Text;
public static class NeuralImportBudgetFixture {
    static void U16(byte[] b,int at,ushort value){Array.Copy(BitConverter.GetBytes(value),0,b,at,2);}
    static void U32(byte[] b,int at,uint value){Array.Copy(BitConverter.GetBytes(value),0,b,at,4);}
    static void U64(byte[] b,int at,ulong value){Array.Copy(BitConverter.GetBytes(value),0,b,at,8);}
    static uint Rva(int offset){return (uint)(offset-512+4096);}
    public static byte[] Create(int descriptors,int ordinals,bool deviceImport) {
        const int pe=128,optional=152,section=392,imports=512,thunks=4608;
        int dllName=thunks+(ordinals+2)*8;
        int function=dllName+32;
        byte[] b=new byte[function+64];
        U16(b,0,0x5A4D);U32(b,60,pe);U32(b,pe,0x4550);
        U16(b,pe+4,0x8664);U16(b,pe+6,1);U16(b,pe+20,240);
        U16(b,optional,0x20B);U32(b,optional+60,512);U32(b,optional+108,16);
        U32(b,optional+120,Rva(imports));U32(b,optional+124,(uint)((descriptors+1)*20));
        U32(b,section+12,4096);U32(b,section+16,(uint)(b.Length-512));U32(b,section+20,512);
        for(int i=0;i<descriptors;i++){
            int at=imports+i*20;
            U32(b,at,Rva(thunks));U32(b,at+12,Rva(dllName));U32(b,at+16,Rva(thunks));
        }
        for(int i=0;i<ordinals;i++)U64(b,thunks+i*8,0x8000000000000001UL);
        if(deviceImport)U64(b,thunks+ordinals*8,Rva(function));
        Array.Copy(Encoding.ASCII.GetBytes("d3d12.dll"),0,b,dllName,9);
        Array.Copy(Encoding.ASCII.GetBytes("D3D12CreateDevice"),0,b,function+2,17);
        return b;
    }
}
'@ -ErrorAction Stop
}
$fixture=Join-Path $repo ('runtime\import-budget-test-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
try {
    $supported=Join-Path $fixture 'supported.exe'
    [IO.File]::WriteAllBytes($supported,[NeuralImportBudgetFixture]::Create(1,128,$true))
    Assert-True ([NeuralGaming.Native.PinImports]::Inspect($supported) -ceq 'd3d12.dll') 'A supported device import after ordinal imports remains recognized'
    $unsupported=Join-Path $fixture 'unsupported.exe'
    [IO.File]::WriteAllBytes($unsupported,[NeuralImportBudgetFixture]::Create(1,128,$false))
    Assert-True ([NeuralGaming.Native.PinImports]::Inspect($unsupported) -ceq '') 'An ordinary image without a device import remains unsupported'
    $repeated=Join-Path $fixture 'repeated-thunks.exe'
    # A small table repeats one 32,768-entry ordinal table sixteen times.
    # Removing the global budget makes this return unsupported instead of rejecting it.
    [IO.File]::WriteAllBytes($repeated,[NeuralImportBudgetFixture]::Create(16,32768,$false))
    $timer=[Diagnostics.Stopwatch]::StartNew();$rejected=$false
    try {[NeuralGaming.Native.PinImports]::Inspect($repeated)|Out-Null}
    catch {
        $errorValue=$_.Exception
        while($errorValue.InnerException){$errorValue=$errorValue.InnerException}
        if($errorValue -isnot [IO.InvalidDataException] -or $errorValue.Message -notmatch 'work budget'){throw}
        $rejected=$true
    }
    $timer.Stop()
    Assert-True $rejected 'Repeated import tables must exhaust a total inspection work budget'
    Assert-True ($timer.Elapsed.TotalSeconds -lt 10) 'Budget exhaustion must complete within ten seconds'
    # Each inspection owns its own budget; a rejected image cannot poison later calls.
    Assert-True ([NeuralGaming.Native.PinImports]::Inspect($supported) -ceq 'd3d12.dll') 'Valid inspection succeeds after an over-budget image'
    Write-Output ('PASS: static PE work budget rejects repeated tables in '+$timer.ElapsedMilliseconds+' ms; ordinary imports preserved. No executable was started.')
} finally {
    $full=[IO.Path]::GetFullPath($fixture)
    $prefix=[IO.Path]::GetFullPath((Join-Path $repo 'runtime')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $full -Leaf) -notlike 'import-budget-test-*'){throw 'Refusing unexpected fixture cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
