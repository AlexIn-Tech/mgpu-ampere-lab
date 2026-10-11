[CmdletBinding()] param([switch]$LiveSmoke)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert-True($Condition,[string]$Message) { if (-not $Condition) { throw ('FAIL: '+$Message) } }
function Assert-Throws([scriptblock]$Action,[string]$Pattern) {
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -match $Pattern) { return }; throw }
    throw ('FAIL: expected rejection matching '+$Pattern)
}
$root=Split-Path $PSScriptRoot -Parent
$modulePath=Join-Path $root 'powershell\NeuralGaming.Gpu.psm1'
Assert-True (Test-Path -LiteralPath $modulePath) 'GPU observation module must exist'
$beforePath=$env:PSModulePath
Import-Module $modulePath -Force
$module=Get-Module NeuralGaming.Gpu
Assert-True ($null -eq ('NeuralGaming.Native.GpuProbe' -as [type])) 'Import must not compile or initialize native APIs'
Assert-True ($env:PSModulePath -ceq $beforePath) 'Import must preserve module paths'
$gpus=@(
    [pscustomobject]@{Index=0;Uuid='GPU-display';PciBusId='00000000:21:00.0';DisplayActive=$true;Name='RTX 3090'},
    [pscustomobject]@{Index=1;Uuid='GPU-render';PciBusId='00000000:49:00.0';DisplayActive=$false;Name='RTX 3090'}
)
& $module {
    $script:adapterFixture=@(
        [pscustomobject]@{Bus=73;Slot=0;Luid='00000000-00014BE8';PhysicalGpuCount=1},
        [pscustomobject]@{Bus=33;Slot=0;Luid='00000000-00013511';PhysicalGpuCount=1}
    )
    function script:Read-NeuralGpuAdapters { $script:adapterFixture }
}
$mapped=@(Get-NeuralGpuAdapters -Gpus $gpus)
Assert-True ($mapped.Count -eq 2 -and $mapped[0].Uuid -eq 'GPU-display' -and $mapped[0].Luid -ceq '00000000-00013511' -and $mapped[1].Luid -ceq '00000000-00014BE8') 'Mapping must join physical PCI location, not NVIDIA enumeration order or model name'
Assert-True ($mapped[1].Index -eq 1 -and -not $mapped[1].DisplayActive -and $mapped[1].Name -eq 'RTX 3090') 'Mapping preserves GPU identity and display metadata'
Assert-Throws { Get-NeuralGpuAdapters -Gpus @($gpus[0],$gpus[0]) } 'duplicate'
Assert-Throws { Get-NeuralGpuAdapters -Gpus @([pscustomobject]@{Index=0;Uuid='GPU-unknown';PciBusId='00000000:22:00.0';DisplayActive=$false;Name='RTX 3090'}) } 'match'
Assert-Throws { Get-NeuralGpuAdapters -Gpus @([pscustomobject]@{Index=0;Uuid='GPU-domain';PciBusId='00000001:21:00.0';DisplayActive=$false;Name='RTX 3090'}) } 'domain'
& $module { $script:adapterFixture[0].PhysicalGpuCount=2 }
Assert-Throws { Get-NeuralGpuAdapters -Gpus $gpus } 'linked|physical'
& $module { $script:adapterFixture[0].PhysicalGpuCount=1; $script:adapterFixture[0].Luid='00000000-00013511' }
Assert-Throws { Get-NeuralGpuAdapters -Gpus $gpus } 'duplicate|ambiguous'
Write-Output 'PASS: PCI identity mapping rejects missing, duplicate and linked adapter evidence'

& $module {
    function script:Read-NeuralNvidiaProcessTable {
        @('|    0   N/A  N/A       999  C+G  C:\\other.exe N/A |',
          '|    1   N/A  N/A       456  C+G  D:\\Cyberpunk2077.exe N/A |',
          '|    0   N/A  N/A       456  C    D:\\compute.exe N/A |')
    }
}
$nvidia=@(Get-NeuralNvidiaProcessSamples -ProcessId 456 -Adapters $mapped -SampleCount 3 -IntervalMilliseconds 1)
Assert-True ($nvidia.Count -eq 3 -and $nvidia[0].Uuid -eq 'GPU-render' -and $nvidia[0].Luid -eq '00000000-00014BE8') 'NVIDIA graphics membership joins index to physical UUID/LUID and excludes compute-only and other PIDs'
Assert-True (@($nvidia.SampleIndex | Select-Object -Unique).Count -eq 3) 'NVIDIA graphics observations retain separate sample windows'
& $module { function script:Read-NeuralNvidiaProcessTable { '|    7   N/A  N/A       456  G    D:\\game.exe N/A |' } }
Assert-Throws { Get-NeuralNvidiaProcessSamples -ProcessId 456 -Adapters $mapped -SampleCount 1 -IntervalMilliseconds 1 } 'unknown|map'
& $module { function script:Read-NeuralNvidiaProcessTable { throw 'NVIDIA query failed' } }
Assert-Throws { Get-NeuralNvidiaProcessSamples -ProcessId 456 -Adapters $mapped -SampleCount 1 -IntervalMilliseconds 1 } 'NVIDIA query failed'

& $module { Initialize-NeuralGpuNative }
$decoder='pid_456_luid_0x00000000_0x00014be8_phys_0_eng_2_engtype_3D'
$sample=[NeuralGaming.Native.GpuProbe]::DecodeSample($decoder,456,0,37.5,2)
Assert-True ($sample.ProcessId -eq 456 -and $sample.Luid -ceq '00000000-00014BE8' -and $sample.Engine -eq '3D' -and $sample.Utilization -eq 37.5) 'PDH decoder must preserve PID, engine and measured utilization with canonical LUID'
Assert-True ($sample.SampleIndex -eq 2) 'Temporal sample identity must survive decoding so multiple engine rows cannot masquerade as separate observations'
Assert-True ($null -eq [NeuralGaming.Native.GpuProbe]::DecodeSample($decoder,457,0,37.5)) 'Other PIDs must never contribute evidence'
Assert-True ($null -eq [NeuralGaming.Native.GpuProbe]::DecodeSample($decoder,456,0xC0000BC6,37.5)) 'Invalid PDH status must not become zero or valid utilization'
Assert-True ($null -eq [NeuralGaming.Native.GpuProbe]::DecodeSample($decoder,456,0,[double]::NaN)) 'NaN utilization must be discarded'
Assert-True ($null -eq [NeuralGaming.Native.GpuProbe]::DecodeSample(($decoder -replace 'phys_0','phys_1'),456,0,37.5)) 'Linked physical-node evidence must be discarded'
Assert-True ($null -eq [NeuralGaming.Native.GpuProbe]::DecodeSample('malformed',456,0,37.5)) 'Malformed instance names must not identify an adapter'
$zero=[NeuralGaming.Native.GpuProbe]::DecodeSample($decoder,456,1,0)
Assert-True ($null -ne $zero -and $zero.Utilization -eq 0) 'Valid idle samples remain observations, not active evidence'
& $module {
    function script:Read-NeuralProcessGpuSamples([int]$ProcessId,[int]$SampleCount,[int]$IntervalMilliseconds) {
        if ($ProcessId -ne 456 -or $SampleCount -ne 2 -or $IntervalMilliseconds -ne 25) { throw 'Observation arguments were not forwarded.' }
        [NeuralGaming.Native.GpuProbe]::DecodeSample('pid_456_luid_0x00000000_0x00014be8_phys_0_eng_0_engtype_3D',456,0,10,0)
        [NeuralGaming.Native.GpuProbe]::DecodeSample('pid_456_luid_0x00000000_0x00013511_phys_0_eng_0_engtype_Copy',456,0,20,0)
        [NeuralGaming.Native.GpuProbe]::DecodeSample('pid_456_luid_0x00000000_0x00014be8_phys_0_eng_0_engtype_3D',456,0,15,1)
    }
}
$observed=@(Get-NeuralProcessGpuSamples -ProcessId 456 -SampleCount 2 -IntervalMilliseconds 25)
Assert-True ($observed.Count -eq 3 -and @($observed | Where-Object Engine -eq '3D').Count -eq 2 -and @($observed.Luid | Select-Object -Unique).Count -eq 2) 'Observations retain per-engine adapter evidence without hiding secondary GPUs'
Assert-True (@($observed | Where-Object SampleIndex -eq 0).Count -eq 2 -and @($observed.SampleIndex | Select-Object -Unique).Count -eq 2) 'Public observations preserve distinct collection indices across repeated engine rows'
Assert-Throws { Get-NeuralProcessGpuSamples -ProcessId 0 } 'ProcessId|range'
Assert-Throws { Get-NeuralProcessGpuSamples -ProcessId 456 -SampleCount 0 } 'SampleCount|range'
$actualPath=Get-NeuralProcessPath -ProcessId $PID
$expectedPath=(Get-Process -Id $PID).Path
Assert-True ([IO.Path]::GetFullPath($actualPath) -ieq [IO.Path]::GetFullPath($expectedPath)) 'Limited-information process path resolves this host executable'
Write-Output 'PASS: PID-specific valid PDH decoding and limited-information process path'
if ($LiveSmoke) {
    Remove-Module NeuralGaming.Gpu
    Import-Module $modulePath -Force
    $lines=@(& nvidia-smi --query-gpu=index,uuid,pci.bus_id,name,display_active --format=csv,noheader)
    if ($LASTEXITCODE -ne 0) { throw 'Read-only live smoke requires nvidia-smi.' }
    $liveGpus=@($lines | ConvertFrom-Csv -Header Index,Uuid,PciBusId,Name,DisplayActive | ForEach-Object {
        [pscustomobject]@{Index=[int]$_.Index.Trim();Uuid=$_.Uuid.Trim();PciBusId=$_.PciBusId.Trim();Name=$_.Name.Trim();DisplayActive=($_.DisplayActive.Trim() -eq 'Enabled')}
    })
    $live=@(Get-NeuralGpuAdapters -Gpus $liveGpus)
    Assert-True ($live.Count -eq $liveGpus.Count) 'Read-only NVAPI maps every live GPU'
    $live | Format-Table Index,PciBusId,Luid,DisplayActive
    $samples=@(Get-NeuralProcessGpuSamples -ProcessId $PID -SampleCount 2 -IntervalMilliseconds 100)
    Assert-True (@($samples | Where-Object ProcessId -ne $PID).Count -eq 0) 'Live PDH query never includes another process'
    Write-Output ('PASS: live read-only NVAPI and PDH smoke; host GPU sample count='+$samples.Count)
}
Write-Output ('All GPU observation tests passed using '+$PSVersionTable.PSVersion)
