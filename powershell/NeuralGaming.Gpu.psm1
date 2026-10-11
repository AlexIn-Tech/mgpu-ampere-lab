# Read-only GPU observations. Import does not load native APIs or start workloads.
Set-StrictMode -Version Latest
function Initialize-NeuralGpuNative {
    if (-not ('NeuralGaming.Native.GpuProbe' -as [type])) {
        Add-Type -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'native\NeuralGpuProbe.cs') -ErrorAction Stop
    }
}
function Read-NeuralGpuAdapters { Initialize-NeuralGpuNative; [NeuralGaming.Native.GpuProbe]::ReadAdapters() }
function Read-NeuralProcessGpuSamples([int]$ProcessId,[int]$SampleCount,[int]$IntervalMilliseconds) {
    Initialize-NeuralGpuNative
    [NeuralGaming.Native.GpuProbe]::ReadProcessSamples($ProcessId,$SampleCount,$IntervalMilliseconds)
}
function Get-NeuralGpuAdapters {
    [CmdletBinding()] param([Parameter(Mandatory)][object[]]$Gpus)
    if ($Gpus.Count -eq 0) { throw 'No NVIDIA GPUs were supplied for adapter mapping.' }
    $identities=@{}; $locations=@{}; $rows=@()
    foreach ($gpu in $Gpus) {
        foreach ($field in @('Index','Uuid','PciBusId','DisplayActive','Name')) {
            if (-not $gpu.PSObject.Properties[$field]) { throw ('GPU identity is missing '+$field+'.') }
        }
        $uuid=[string]$gpu.Uuid
        if (-not $uuid -or $identities.ContainsKey($uuid)) { throw 'Missing or duplicate NVIDIA GPU UUID.' }
        $identities[$uuid]=$true
        if ([string]$gpu.PciBusId -notmatch '^([0-9a-fA-F]{4,8}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$') { throw ('Invalid GPU PCI location: '+$gpu.PciBusId) }
        # NVAPI exposes bus/slot but not a PCI domain; never collapse another domain.
        if ([Convert]::ToUInt32($Matches[1],16) -ne 0 -or [int]$Matches[4] -ne 0) { throw 'Unsupported PCI domain/function: cannot establish an unambiguous NVAPI mapping.' }
        $bus=[Convert]::ToUInt32($Matches[2],16); $slot=[Convert]::ToUInt32($Matches[3],16)
        $location=('{0}:{1}' -f $bus,$slot)
        if ($locations.ContainsKey($location)) { throw 'Duplicate physical GPU PCI location.' }
        $locations[$location]=$true
        $rows += [pscustomobject]@{Gpu=$gpu;Bus=$bus;Slot=$slot}
    }
    try { $native=@(Read-NeuralGpuAdapters) } catch { throw ('Cannot read NVIDIA adapter identities: '+$_.Exception.Message) }
    if ($native.Count -eq 0) { throw 'NVAPI reported no physical NVIDIA GPU adapters; software adapters are not accepted.' }
    $luids=@{}; $nativeLocations=@{}
    foreach ($adapter in $native) {
        if ($adapter.PhysicalGpuCount -ne 1) { throw 'Linked logical GPU contains multiple physical GPUs; adapter identity is ambiguous.' }
        $luid=[string]$adapter.Luid
        if ($luid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{8}$' -or $luid -eq '00000000-00000000') { throw 'NVAPI returned an invalid adapter LUID.' }
        $location=('{0}:{1}' -f $adapter.Bus,$adapter.Slot)
        if ($luids.ContainsKey($luid) -or $nativeLocations.ContainsKey($location)) { throw 'Duplicate or ambiguous physical adapter identity returned by NVAPI.' }
        $luids[$luid]=$true; $nativeLocations[$location]=$adapter
    }
    foreach ($row in $rows) {
        $location=('{0}:{1}' -f $row.Bus,$row.Slot)
        if (-not $nativeLocations.ContainsKey($location)) { throw ('Cannot match NVIDIA GPU '+$row.Gpu.Uuid+' at '+$row.Gpu.PciBusId+' to a physical DXGI adapter.') }
        $gpu=$row.Gpu; $adapter=$nativeLocations[$location]
        [pscustomobject]@{Index=$gpu.Index;Uuid=$gpu.Uuid;PciBusId=$gpu.PciBusId;DisplayActive=[bool]$gpu.DisplayActive;Name=$gpu.Name;Luid=([string]$adapter.Luid).ToUpperInvariant()}
    }
}
function Get-NeuralProcessGpuSamples {
    <# Observes process GPU activity; this is not proof of swapchain/device ownership. #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,
        [ValidateRange(1,120)][int]$SampleCount=6,
        [ValidateRange(1,10000)][int]$IntervalMilliseconds=1000
    )
    try { Read-NeuralProcessGpuSamples $ProcessId $SampleCount $IntervalMilliseconds }
    catch { throw ('Cannot observe GPU activity for process '+$ProcessId+': '+$_.Exception.Message) }
}
function Get-NeuralProcessPath {
    [CmdletBinding()] param([Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId)
    Initialize-NeuralGpuNative
    try { return [NeuralGaming.Native.GpuProbe]::ReadProcessPath($ProcessId) }
    catch {
        $nativeFailure=$_.Exception.Message
        $process=$null
        try {
            $process=Get-Process -Id $ProcessId -ErrorAction Stop
            $path=$process.Path
            if ([string]::IsNullOrWhiteSpace($path)) { throw 'Process executable path is unavailable.' }
            return $path
        } catch { throw ('Cannot read executable path for process '+$ProcessId+': '+$nativeFailure+'; fallback: '+$_.Exception.Message) }
        finally { if ($process) { $process.Dispose() } }
    }
}
function Read-NeuralNvidiaProcessTable {
    $smi=Get-Command nvidia-smi -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $lines=@(& $smi.Source 2>&1)
    if($LASTEXITCODE -ne 0){throw ('NVIDIA process query failed (exit '+$LASTEXITCODE+').')}
    $lines
}
function Get-NeuralNvidiaProcessSamples {
    <# Graphics process membership, not utilization or proof of swapchain ownership. #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,
        [Parameter(Mandatory)][object[]]$Adapters,
        [ValidateRange(1,120)][int]$SampleCount=6,
        [ValidateRange(1,10000)][int]$IntervalMilliseconds=1000
    )
    for($sample=0;$sample -lt $SampleCount;$sample++) {
        if($sample -gt 0){Start-Sleep -Milliseconds $IntervalMilliseconds}
        foreach($line in @(Read-NeuralNvidiaProcessTable)) {
            # Same process table as Get-LocalAIGpuStatus; don't use compute-only queries for games.
            if([string]$line -notmatch '^\|\s+(\d+)\s+\S+\s+\S+\s+(\d+)\s+(C\+G|C|G)\s+'){continue}
            $index=[int]$Matches[1];$observedPid=[int]$Matches[2];$kind=$Matches[3]
            if($observedPid -ne $ProcessId -or $kind -eq 'C'){continue}
            $adapter=@($Adapters | Where-Object Index -eq $index)
            if($adapter.Count -ne 1){throw ('NVIDIA process refers to an unknown or ambiguous GPU index: '+$index)}
            [pscustomobject]@{ProcessId=$ProcessId;SampleIndex=$sample;Uuid=$adapter[0].Uuid;Luid=$adapter[0].Luid;Kind=$kind}
        }
    }
}
Export-ModuleMember -Function Get-NeuralGpuAdapters,Get-NeuralProcessGpuSamples,Get-NeuralProcessPath,Get-NeuralNvidiaProcessSamples
