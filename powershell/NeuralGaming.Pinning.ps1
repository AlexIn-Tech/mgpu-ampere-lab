# Game-only device selection. Imports/inspection do not start a process.
$script:NeuralCodeRoot=Split-Path $PSScriptRoot -Parent
function Initialize-NeuralPinImports {
    if(-not ('NeuralGaming.Native.PinImports' -as [type])){Add-Type -Path (Join-Path $script:NeuralCodeRoot 'native\NeuralPinImports.cs') -ErrorAction Stop}
}
function Start-NeuralPinnedHelper($Launcher,[string[]]$Arguments,$Directory,$Stdout,$Stderr) {
    if(-not ('NeuralGaming.Native.PinnedStartup' -as [type])){Add-Type -Path (Join-Path $script:NeuralCodeRoot 'native\NeuralPinnedStartup.cs') -ErrorAction Stop}
    [NeuralGaming.Native.PinnedStartup]::Start($Launcher,$Arguments,$Directory,$Stdout,$Stderr)
}
function Get-NeuralPinBinaryState([string]$ManifestPath=(Join-Path $script:NeuralCodeRoot 'runtime\pinning\build\manifest.json')) {
    $result=[pscustomobject]@{Available=$false;Message='Build the experimental scoped GPU selector before a baseline launch.';Launcher=(Join-Path $script:NeuralCodeRoot 'runtime\pinning\build\NeuralPinnedLaunch.exe');Dll=(Join-Path $script:NeuralCodeRoot 'runtime\pinning\build\NeuralGpuPin.dll');Fingerprint=$null}
    try {
        Assert-NeuralRegularPath $ManifestPath
        if(-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)){return $result}
        if((Get-Item -LiteralPath $ManifestPath).Length -gt 65536){throw 'Native build hash record exceeds its limit.'}
        $record=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        if($record.Version -ne 1 -or @($record.Files).Count -lt 4 -or @($record.Files).Count -gt 64){throw 'Invalid native build hash record.'}
        $seen=@{}
        foreach($file in $record.Files){
            $path=Get-NeuralOwnedPath $script:NeuralCodeRoot $file.RelativePath
            if($seen.ContainsKey($path)){throw 'Duplicate native build hash entry.'};$seen[$path]=$true
            if($file.Sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Sha256){throw ('Native selector source/binary changed or missing: '+$file.RelativePath+'. Rebuild before launch.')}
        }
        foreach($required in @('runtime\pinning\build\NeuralGpuPin.dll','runtime\pinning\build\NeuralPinnedLaunch.exe','native\NeuralGpuPin.cpp','native\NeuralPinnedLaunch.cpp','native\NeuralPinImports.cs','native\NeuralPinnedStartup.cs')){
            if(-not $seen.ContainsKey((Get-NeuralOwnedPath $script:NeuralCodeRoot $required))){throw ('Native build record is missing '+$required)}
        }
        $result.Available=$true;$result.Fingerprint=(Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
        $result.Message='Experimental main-EXE device selector built and integrity checked. Game compatibility still requires a baseline.'
    } catch {$result.Message=$_.Exception.Message}
    return $result
}
function Get-NeuralGamePinning {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $binary=Get-NeuralPinBinaryState
    $result=[pscustomobject]@{Available=$binary.Available;Supported=$false;Status='Unavailable';Message=$binary.Message;Method='MainExeD3D12Import';TargetLuid=$null;ImportModule=$null;Fingerprint=$binary.Fingerprint}
    try {
        $manifest=Get-NeuralManifest $Name;Initialize-NeuralPinImports
        $import=[NeuralGaming.Native.PinImports]::Inspect($manifest.Executable)
        if(-not $import){$result.Status='Unsupported';$result.Message='This executable has no single supported main-EXE DirectX 12 device import. No pinning fallback is used.';return $result}
        $result.Supported=$true;$result.ImportModule=$import
        if($binary.Available){$result.Status='ExperimentalReady';$result.Message='Experimental selector changes only the main executable device call via '+$import+'. MGPU keeps its independent adapter. Verify the baseline and fresh runtime.'}
    } catch {$result.Status='Unsupported';$result.Message=$_.Exception.Message}
    return $result
}
function Start-NeuralPinnedProcess($Manifest,[ValidateRange(1,30000)][int]$TimeoutMilliseconds=30000) {
    $pinning=Get-NeuralGamePinning -Name $Manifest.Name
    if(-not $pinning.Available -or -not $pinning.Supported){throw ('Scoped GPU launch blocked: '+$pinning.Message)}
    $config=Get-Content -LiteralPath (Join-Path $script:NeuralRoot 'runtime\config.json') -Raw | ConvertFrom-Json
    $gpus=@(Get-NeuralGpuAdapters -Gpus @(Get-NeuralGpus))
    $target=@($gpus | Where-Object Uuid -eq $config.renderUuid)
    $output=@($gpus | Where-Object Uuid -eq $config.neuralUuid)
    if($target.Count -ne 1 -or $output.Count -ne 1 -or $target[0].DisplayActive -or -not $output[0].DisplayActive -or $target[0].Luid -eq $output[0].Luid){throw 'Cannot pin a distinct headless game GPU with the neural GPU driving the display.'}
    $binary=Get-NeuralPinBinaryState
    if(-not $binary.Available -or $binary.Fingerprint -ne $pinning.Fingerprint){throw 'Native selector changed during launch checks.'}
    $folder=Join-Path $script:NeuralRoot ('runtime\pinning\launches\'+[Guid]::NewGuid().ToString('N'));Assert-NeuralRegularPath $folder
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    $resultPath=Join-Path $folder 'child.json';$stdout=Join-Path $folder 'launcher.stdout.txt';$stderr=Join-Path $folder 'launcher.stderr.txt'
    $launchArguments=@('--exe',$Manifest.Executable,'--dll',$binary.Dll,'--luid',$target[0].Luid,'--result',$resultPath)
    $launcher=Start-NeuralPinnedHelper $binary.Launcher $launchArguments $Manifest.GameDirectory $stdout $stderr
    $process=$null;$handedOff=$false
    try {
        if(-not $launcher.WaitForExit($TimeoutMilliseconds)){throw 'Native launch helper timed out; its owned startup job was cancelled.'}
        if($launcher.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)){
            $detail=if(Test-Path -LiteralPath $stderr){([string](Get-Content -LiteralPath $stderr -Raw)).Trim()}else{'No launch result.'}
            throw ('Native launch helper failed: '+$detail)
        }
        $record=Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if($record.Status -ne 'Spawned' -or $record.ProcessId -lt 1){throw 'Invalid native child-process result.'}
        $process=Get-Process -Id ([int]$record.ProcessId) -ErrorAction Stop
        $null=$process.Handle
        if(-not $launcher.ContainsProcess($process.Handle)){throw 'Native child process is outside the owned startup job.'}
        if([IO.Path]::GetFullPath((Get-NeuralProcessPath $process.Id)) -ine [IO.Path]::GetFullPath($Manifest.Executable)){throw 'Native child executable identity does not match the managed game.'}
        if($process.WaitForExit(1000)){
            $process.Refresh()
            $code=$process.ExitCode
            throw ('Game exited during startup (0x'+$code.ToString('X8')+'). Inspect game/mod logs before retrying; no successful baseline was recorded.')
        }
        $launcher.Handoff();$handedOff=$true
        return $process
    } finally {
        # Closing the private job cancels helper and descendants on every failure,
        # including timeout, invalid result and child identity mismatch. Never
        # terminate a process reconstructed from the result PID.
        try {$launcher.Dispose()} finally {if($process -and -not $handedOff){$process.Dispose()}}
    }
}
