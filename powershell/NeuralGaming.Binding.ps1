# Dot-sourced into the manager; import is inert. Observations never select an adapter.
function Get-NeuralBindingPath([string]$Name,[string]$Kind) {
    Get-NeuralManifestPath $Name | Out-Null
    if ($Kind -notin @('baseline','verified','observation','session','autoarm')) { throw 'Invalid binding record type.' }
    $path=Join-Path $script:NeuralRoot "runtime\binding\$Name.$Kind.json"
    Assert-NeuralRegularPath $path
    return $path
}
function Get-NeuralBindingRecord([string]$Name,[string]$Kind) {
    $path=Get-NeuralBindingPath $Name $Kind
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $path).Length -gt 65536) { throw 'GPU observation record is too large.' }
    Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
function Write-NeuralBindingRecord([string]$Name,[string]$Kind,$Record) {
    $path=Get-NeuralBindingPath $Name $Kind
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
    $temp=$path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'; $backup=$temp+'.bak'
    try {
        [IO.File]::WriteAllText($temp,($Record | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp,$path,$backup) } else { [IO.File]::Move($temp,$path) }
    } finally {
        foreach($file in @($temp,$backup)){ if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file} }
    }
}
function Remove-NeuralBindingRecord([string]$Name,[string]$Kind) {
    $path=Get-NeuralBindingPath $Name $Kind
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
}
function Get-NeuralTextHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','') }
    finally { $sha.Dispose() }
}
function Convert-NeuralRecordUtc($Value) {
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    [DateTime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Get-NeuralBootIdentity {
    $os=Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop
    if(-not $os.LastBootUpTime){throw 'Cannot establish the current Windows boot identity.'}
    $os.LastBootUpTime.ToUniversalTime().ToString('o')
}
function Get-NeuralWindowsGraphicsFingerprint([string]$Executable) {
    $key='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if(-not (Test-Path -LiteralPath $key)){return 'absent'}
    $item=Get-Item -LiteralPath $key -ErrorAction Stop
    try {
        $values=@()
        foreach($name in @($item.GetValueNames() | Sort-Object)) {
            # Include global options and the game's own preference, without writing them.
            if($name -eq $Executable -or $name -notmatch '^[A-Za-z]:[\\/]') {
                $values += [pscustomobject]@{Name=$name;Value=$item.GetValue($name);Kind=[string]$item.GetValueKind($name)}
            }
        }
        Get-NeuralTextHash ($values | ConvertTo-Json -Depth 6 -Compress)
    } finally { $item.Dispose() }
}
function Get-NeuralBindingContext($Manifest) {
    $configPath=Join-Path $script:NeuralRoot 'runtime\config.json'; Assert-NeuralRegularPath $configPath
    $config=Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $adapters=@(Get-NeuralGpuAdapters -Gpus @(Get-NeuralGpus))
    $render=@($adapters | Where-Object Uuid -eq $config.renderUuid)
    $neural=@($adapters | Where-Object Uuid -eq $config.neuralUuid)
    if($render.Count -ne 1 -or $neural.Count -ne 1 -or $config.renderUuid -eq $config.neuralUuid -or $render[0].DisplayActive -or -not $neural[0].DisplayActive -or $render[0].Luid -eq $neural[0].Luid) { throw 'Requested GPU roles do not match a distinct headless/render and display/neural topology.' }
    $identity=[ordered]@{
        WindowsBoot=Get-NeuralBootIdentity
        ExecutablePath=[IO.Path]::GetFullPath($Manifest.Executable).ToUpperInvariant()
        GameDirectory=[IO.Path]::GetFullPath($Manifest.GameDirectory).ToUpperInvariant()
        Executable=(Get-FileHash -LiteralPath $Manifest.Executable -Algorithm SHA256).Hash
        NeuralModel=(Get-FileHash -LiteralPath (Get-NeuralOwnedPath $Manifest.GameDirectory 'mgpu\nvngx_dlssnr.dll') -Algorithm SHA256).Hash
        Configuration=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
        BridgeSettings=(Get-FileHash -LiteralPath (Get-NeuralOwnedPath $Manifest.GameDirectory 'mgpu.ini') -Algorithm SHA256).Hash
        Adapters=@($adapters | Sort-Object Uuid | Select-Object Uuid,PciBusId,Luid,DisplayActive)
        WindowsGraphics=Get-NeuralWindowsGraphicsFingerprint $Manifest.Executable
    }
    $pinning=Get-NeuralPinBinaryState
    if(-not $pinning.Available){throw ('Scoped GPU selector unavailable: '+$pinning.Message)}
    $identity.NativeSelector=$pinning.Fingerprint
    [pscustomobject]@{Fingerprint=(Get-NeuralTextHash ($identity | ConvertTo-Json -Depth 8 -Compress));Render=$render[0];Neural=$neural[0];Adapters=$adapters}
}
function Get-NeuralGameBinding {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $result=[pscustomobject]@{Status='Unknown';CanLaunch=$false;Message='Optional baseline diagnostic. Launch with neural starts directly with manual activation; current runtime binding is checked separately.';RenderLuid=$null;NeuralLuid=$null;ObservedRenderUuid=$null}
    try {
        $manifest=Get-NeuralManifest $Name
        $lease=Get-NeuralBindingRecord $Name 'verified'
        if(-not $lease) {
            $observation=Get-NeuralBindingRecord $Name 'observation'
            if($observation){$result.Status=[string]$observation.Status;$result.Message=[string]$observation.Message}
            return $result
        }
        if($lease.Version -ne 1 -or $lease.Name -ne $Name -or $lease.Status -ne 'Observed'){throw 'Invalid baseline observation.'}
        $expires=Convert-NeuralRecordUtc $lease.ExpiresUtc
        $observed=Convert-NeuralRecordUtc $lease.ObservedUtc
        if($observed -gt [DateTime]::UtcNow.AddSeconds(5) -or $expires -le [DateTime]::UtcNow -or $expires -gt $observed.AddMinutes(10).AddSeconds(1)){throw 'Baseline observation expired. Verify a new baseline.'}
        $context=Get-NeuralBindingContext $manifest
        if($lease.Fingerprint -ne $context.Fingerprint -or $lease.ObservedRenderUuid -ne $context.Render.Uuid -or $lease.RenderLuid -ne $context.Render.Luid -or $lease.NeuralLuid -ne $context.Neural.Luid){throw 'GPU map, executable or settings changed. Verify a new baseline.'}
        $result.Status='Observed';$result.CanLaunch=$true
        $source=if($lease.PSObject.Properties['EvidenceSource']){[string]$lease.EvidenceSource}else{'Windows 3D counters'}
        $result.Message='Optional baseline: headless GPU observed via '+$source+'. Direct neural launch does not require this observation. The current neural runtime verifies actual binding and output separately.'
        if($lease.PSObject.Properties['DisplayAlsoActive'] -and $lease.DisplayAlsoActive){$result.Message+=' Headless activity observed; display GPU also active in this process. Render device ownership remains unverified until the neural runtime binding is checked.'}
        $result.RenderLuid=$context.Render.Luid;$result.NeuralLuid=$context.Neural.Luid;$result.ObservedRenderUuid=$context.Render.Uuid
    } catch { $result.Message=$_.Exception.Message }
    return $result
}
function Consume-NeuralGameBinding([string]$Name) {
    $binding=Get-NeuralGameBinding $Name
    if(-not $binding.CanLaunch){throw ('Neural launch blocked: '+$binding.Message)}
    Remove-NeuralBindingRecord $Name 'verified'
    Write-NeuralBindingRecord $Name 'observation' ([pscustomobject]@{Status='Unknown';Message='One-use baseline observation consumed. A new baseline is required for another neural launch.'})
}
function Start-NeuralGameBaseline {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $ErrorActionPreference='Stop';$manifest=Get-NeuralManifest $Name
    $operation=Enter-NeuralGameOperation $manifest.Executable
    try {
        if(@(Get-NeuralGameProcesses $manifest).Count){throw 'The game is already running. Close it before starting a baseline.'}
        if((Get-NeuralGameStatus $Name).State -ne 'Disabled'){throw 'Recover disabled injector files with Stop-NeuralGame before starting a baseline.'}
        Remove-NeuralBindingRecord $Name 'verified';Remove-NeuralBindingRecord $Name 'observation';Remove-NeuralBindingRecord $Name 'baseline'
        $context=Get-NeuralBindingContext $manifest
        $process=Start-NeuralPinnedProcess -Manifest $manifest
        $record=[pscustomobject]@{Version=2;Name=$Name;ProcessId=$process.Id;ProcessStartUtc=$process.StartTime.ToUniversalTime().ToString('o');Executable=$manifest.Executable;Fingerprint=$context.Fingerprint}
        Write-NeuralBindingRecord $Name 'baseline' $record
        [pscustomobject]@{Name=$Name;ProcessId=$record.ProcessId;Message='Baseline started with both managed injector DLLs disabled. Play, verify game GPU, then close the game.'}
    } finally {Exit-NeuralGameOperation $operation}
}
function Confirm-NeuralGameGpu {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $ErrorActionPreference='Stop';$manifest=Get-NeuralManifest $Name
    $operation=Enter-NeuralGameOperation $manifest.Executable
    try {
        Remove-NeuralBindingRecord $Name 'verified'
        if((Get-NeuralGameStatus $Name).State -ne 'Disabled'){throw 'GPU baseline verification requires both managed injector DLLs disabled.'}
        $baseline=Get-NeuralBindingRecord $Name 'baseline'
        $processes=@(Get-NeuralGameProcesses $manifest)
        if(-not $baseline -or $baseline.Version -ne 2 -or $baseline.Name -ne $Name -or $processes.Count -ne 1 -or $processes[0].Id -ne $baseline.ProcessId){throw 'Start a baseline using Start-NeuralGameBaseline, then verify while playing.'}
        $process=$processes[0]
        $baselineStart=(Convert-NeuralRecordUtc $baseline.ProcessStartUtc).ToString('o')
        if($process.StartTime.ToUniversalTime().ToString('o') -ne $baselineStart -or [IO.Path]::GetFullPath((Get-NeuralProcessPath $process.Id)) -ine [IO.Path]::GetFullPath($manifest.Executable)){throw 'Baseline process identity changed; start a new baseline.'}
        $context=Get-NeuralBindingContext $manifest
        if($baseline.Fingerprint -ne $context.Fingerprint){throw 'Baseline executable, selector, GPU map or settings changed since launch. Close it and start a new baseline.'}
        $samples=@();$counterError=$null;$nvidiaError=$null;$nvidia=@()
        try {$samples=@(Get-NeuralProcessGpuSamples -ProcessId $process.Id -SampleCount 6 -IntervalMilliseconds 1000)}
        catch {$counterError=$_.Exception.Message}
        $active=@($samples | Where-Object {$_.ProcessId -eq $process.Id -and $_.Engine -ieq '3d' -and $_.Utilization -gt 0})
        $luids=@($active | Select-Object -ExpandProperty Luid -Unique)
        $observations=@($active | Where-Object {$_.Luid -eq $context.Render.Luid -and $_.Utilization -ge 1} | Select-Object -ExpandProperty SampleIndex -Unique)
        $foreign=@($luids | Where-Object {$_ -ne $context.Render.Luid})
        $displayAlsoActive=($context.Neural.Luid -in $luids)
        # Process counters include every device/presentation path, not just the game's render device.
        # A configured display companion is not a mismatch when headless activity is repeated.
        # Unknown adapters, display-only activity and insufficient evidence still fail closed.
        if($observations.Count -ge 3){$foreign=@($foreign | Where-Object {$_ -ne $context.Neural.Luid})}
        $source='Windows 3D counters'
        if($foreign.Count -eq 0 -and $observations.Count -lt 3){
            try {$nvidia=@(Get-NeuralNvidiaProcessSamples -ProcessId $process.Id -Adapters $context.Adapters -SampleCount 6 -IntervalMilliseconds 1000)}
            catch {$nvidiaError=$_.Exception.Message}
            $nvidiaActive=@($nvidia | Where-Object {$_.ProcessId -eq $process.Id -and $_.Kind -in @('G','C+G')})
            $foreign=@($nvidiaActive | Where-Object {$_.Uuid -ne $context.Render.Uuid -or $_.Luid -ne $context.Render.Luid})
            $observations=@($nvidiaActive | Where-Object {$_.Uuid -eq $context.Render.Uuid -and $_.Luid -eq $context.Render.Luid} | Select-Object -ExpandProperty SampleIndex -Unique)
            $source='NVIDIA graphics process list'
        }
        $evidence=[pscustomobject]@{ProcessId=$process.Id;ExpectedRenderUuid=$context.Render.Uuid;ExpectedRenderLuid=$context.Render.Luid;ExpectedDisplayLuid=$context.Neural.Luid;DisplayAlsoActive=$displayAlsoActive;Source=$source;WindowsRowCount=$samples.Count;WindowsSamples=@($active | Select-Object -First 64);WindowsError=$counterError;NvidiaSamples=@($nvidia | Select-Object -First 64);NvidiaError=$nvidiaError}
        if($foreign.Count -gt 0 -or $observations.Count -lt 3){
            $status=if($foreign.Count){'Mismatch'}else{'Unknown'}
            $detail=if($foreign.Count){'Display, mixed or unknown GPU activity observed; requested headless GPU is '+$context.Render.Uuid+'.'}else{'Insufficient observations on the requested headless GPU ('+$observations.Count+'/3). Keep the baseline running in gameplay and retry.'}
            $message='Baseline GPU not verified: '+$detail
            if($counterError){$message+=' Windows counters: '+$counterError}
            if($nvidiaError){$message+=' NVIDIA query: '+$nvidiaError}
            Write-NeuralBindingRecord $Name 'observation' ([pscustomobject]@{Status=$status;Message=$message;Evidence=$evidence})
            throw $message
        }
        # Recheck identity/topology after the observation window, including PID reuse.
        $after=@(Get-NeuralGameProcesses $manifest)
        if($after.Count -ne 1 -or $after[0].Id -ne $process.Id -or $after[0].StartTime.ToUniversalTime().ToString('o') -ne $baselineStart -or (Get-NeuralBindingContext $manifest).Fingerprint -ne $context.Fingerprint){throw 'Baseline game or GPU settings changed during observation; retry.'}
        $now=[DateTime]::UtcNow
        Write-NeuralBindingRecord $Name 'observation' ([pscustomobject]@{Status='Observed';Message=('Headless GPU observed via '+$source+'.');Evidence=$evidence})
        $lease=[pscustomobject]@{Version=1;Name=$Name;Status='Observed';Fingerprint=$context.Fingerprint;ObservedUtc=$now.ToString('o');ExpiresUtc=$now.AddMinutes(10).ToString('o');ObservedRenderUuid=$context.Render.Uuid;RenderLuid=$context.Render.Luid;NeuralLuid=$context.Neural.Luid;ProcessId=$process.Id;Samples=$observations.Count;EvidenceSource=$source;DisplayAlsoActive=$displayAlsoActive}
        Write-NeuralBindingRecord $Name 'verified' $lease
        Get-NeuralGameBinding $Name
    } finally {Exit-NeuralGameOperation $operation}
}
function Save-NeuralSessionRecord([string]$Name,$Process,[DateTime]$StartedUtc,[string]$PreviousPrefixHash) {
    Write-NeuralBindingRecord $Name 'session' ([pscustomobject]@{Version=1;Name=$Name;ProcessId=$Process.Id;ProcessStartUtc=$Process.StartTime.ToUniversalTime().ToString('o');StartedUtc=$StartedUtc.ToString('o');PreviousPrefixHash=$PreviousPrefixHash;LaunchAutoArm=0})
}
function Get-NeuralGameRuntime {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $unknown=[pscustomobject]@{Status='Unknown';Fresh=$false;BindingVerified=$false;Armed=$false;Streaming=$false;Message='No verified current neural session. Startup probes are not live neural rendering.';RenderLuid=$null;NeuralLuid=$null}
    try {
        $manifest=Get-NeuralManifest $Name;$session=Get-NeuralBindingRecord $Name 'session'
        if(-not $session -or $session.Version -ne 1 -or $session.Name -ne $Name -or (Get-NeuralGameStatus $Name).State -ne 'Enabled'){return $unknown}
        $sessionStart=(Convert-NeuralRecordUtc $session.ProcessStartUtc).ToString('o')
        $process=@(Get-NeuralGameProcesses $manifest | Where-Object {$_.Id -eq $session.ProcessId -and $_.StartTime.ToUniversalTime().ToString('o') -eq $sessionStart})
        if($process.Count -ne 1){return $unknown}
        $config=Get-Content -LiteralPath (Join-Path $script:NeuralRoot 'runtime\config.json') -Raw | ConvertFrom-Json
        $adapters=@(Get-NeuralGpuAdapters -Gpus @(Get-NeuralGpus))
        $render=@($adapters | Where-Object Uuid -eq $config.renderUuid);$neural=@($adapters | Where-Object Uuid -eq $config.neuralUuid)
        if($render.Count -ne 1 -or $neural.Count -ne 1 -or $config.renderUuid -eq $config.neuralUuid -or $render[0].DisplayActive -or -not $neural[0].DisplayActive -or $render[0].Luid -eq $neural[0].Luid){throw 'Current GPU topology no longer has a distinct headless/render and display/neural pair. Close the game and verify a new baseline.'}
        Get-NeuralLogState -LogPath (Get-NeuralOwnedPath $manifest.GameDirectory 'ReShade.log') -ExpectedRenderLuid $render[0].Luid -ExpectedNeuralLuid $neural[0].Luid -NotBeforeUtc (Convert-NeuralRecordUtc $session.StartedUtc) -PreviousPrefixHash $session.PreviousPrefixHash
    } catch {$unknown.Message=$_.Exception.Message;return $unknown}
}
