$ErrorActionPreference='Stop'
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"}}
$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'powershell\NeuralGaming.psm1') -Force -DisableNameChecking
Assert-True ($null -ne (Get-Command Get-NeuralGamePinning -ErrorAction SilentlyContinue)) 'Pinning readiness is exposed without launching a game'
$module=Get-Module NeuralGaming
& $module {Initialize-NeuralPinImports}
$folder=Join-Path $repo ('runtime\pin-manager-test-'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($folder)|Out-Null
try {
    # A real system PE is x64 but has no supported game-device import.
    Assert-True ([NeuralGaming.Native.PinImports]::Inspect((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')) -eq '') 'A system executable without the supported import cannot claim pinning support'
    $bad=Join-Path $folder 'bad.exe';[IO.File]::WriteAllText($bad,'invalid executable')
    $rejected=$false;try{[NeuralGaming.Native.PinImports]::Inspect($bad)|Out-Null}catch{$rejected=$true}
    Assert-True $rejected 'Malformed PE is rejected'
    $build=Join-Path $repo 'runtime\pinning\build'
    $fixture=Join-Path $build 'PinFixtureMain.exe'
    if(Test-Path $fixture){
        Assert-True ([NeuralGaming.Native.PinImports]::Inspect($fixture) -eq 'sl.interposer.dll') 'Actual fixture device import is recognized without executing it'
    } else {throw 'Build native pinning fixtures before running this suite.'}
    $integrity=& $module {Get-NeuralPinBinaryState}
    Assert-True $integrity.Available 'Compiled selector sources and binaries match the build hash record'
    $record=Join-Path $build 'manifest.json'
    $json=Get-Content $record -Raw | ConvertFrom-Json
    $json.Files[0].Sha256='00';$copy=Join-Path $folder 'bad-manifest.json';[IO.File]::WriteAllText($copy,($json | ConvertTo-Json -Depth 10))
    Assert-True (-not (& $module {param($Path) Get-NeuralPinBinaryState -ManifestPath $Path} $copy).Available) 'A mismatched build hash blocks native execution'
    # Exercise the actual hidden native helper from each PowerShell edition.
    # This child calls fake device exports; enumeration only reads adapter metadata.
    $table=@(& $fixture --enumerate)
    $hardware=@($table | Where-Object {[uint32](($_ -split '\|')[2]) -eq 0})
    Assert-True ($hardware.Count -ge 2) 'This dual-GPU manager regression needs two hardware adapters'
    $target=($hardware[1] -split '\|')[0];$display=($hardware[0] -split '\|')[0]
    [IO.Directory]::CreateDirectory((Join-Path $folder 'runtime\games'))|Out-Null
    $manifest=[pscustomobject]@{Name='fixture';Executable=$fixture;GameDirectory=$build;Files=@();CreatedDirectories=@()}
    $manifest|ConvertTo-Json -Depth 6|Set-Content (Join-Path $folder 'runtime\games\fixture.json')
    [IO.File]::WriteAllText((Join-Path $folder 'runtime\config.json'),'{"renderUuid":"fixture-headless","neuralUuid":"fixture-display"}')
    $previousRoot=& $module {$script:NeuralRoot}
    $previousWait=[Environment]::GetEnvironmentVariable('PIN_FIXTURE_WAIT_MS','Process')
    $previousOutput=[Environment]::GetEnvironmentVariable('PIN_FIXTURE_OUTPUT','Process')
    $previousMarker=[Environment]::GetEnvironmentVariable('PIN_FIXTURE_MAIN_MARKER','Process')
    try {
        & $module {param($Root,$Target,$Display)
            $script:NeuralRoot=$Root
            $script:PinFixtureAdapters=@([pscustomobject]@{Uuid='fixture-headless';Luid=$Target;DisplayActive=$false},[pscustomobject]@{Uuid='fixture-display';Luid=$Display;DisplayActive=$true})
            function script:Get-NeuralGpus {$script:PinFixtureAdapters}
            function script:Get-NeuralGpuAdapters {param($Gpus) $Gpus}
        } $folder $target $display
        [Environment]::SetEnvironmentVariable('PIN_FIXTURE_WAIT_MS','3000','Process')
        $callsPath=Join-Path $folder 'manager-calls.txt'
        [Environment]::SetEnvironmentVariable('PIN_FIXTURE_OUTPUT',$callsPath,'Process')
        [Environment]::SetEnvironmentVariable('PIN_FIXTURE_MAIN_MARKER',(Join-Path $folder 'manager.marker'),'Process')
        $child=& $module {param($Manifest) Start-NeuralPinnedProcess $Manifest} $manifest
        Assert-True ($child.Id -gt 0 -and -not $child.HasExited) 'The real wrapper retains the successful helper exit code and returns its own live CPU-only child'
        Assert-True ($child.WaitForExit(10000)) 'CPU-only child finishes without any process termination'
        $calls=@(Get-Content $callsPath)
        Assert-True ($calls.Count -eq 2 -and $calls[0] -eq ('Main|'+$target+'|sl.interposer|device') -and $calls[1] -eq 'Bridge|0000F17F-F17F0002|sl.interposer|device') 'The manager selects exact headless identity while the bridge request stays independent'
        $child.Dispose()
        [Environment]::SetEnvironmentVariable('PIN_FIXTURE_WAIT_MS','100','Process')
        [Environment]::SetEnvironmentVariable('PIN_FIXTURE_MAIN_MARKER',(Join-Path $folder 'early-exit.marker'),'Process')
        $startupRejected=$false
        try {
            $earlyChild=& $module {param($Manifest) Start-NeuralPinnedProcess $Manifest} $manifest
            $earlyChild.WaitForExit(10000)|Out-Null
            $earlyChild.Dispose()
        } catch { $startupRejected=$_.Exception.Message -match 'exited during startup.*0x00000000' }
        Assert-True $startupRejected 'An early child exit must report its exit code instead of successful startup'
    } finally {
        foreach($childRecord in @(Get-ChildItem -LiteralPath $folder -Filter child.json -Recurse -ErrorAction SilentlyContinue)){
            $spawn=Get-Content -LiteralPath $childRecord.FullName -Raw|ConvertFrom-Json
            $remaining=Get-Process -Id $spawn.ProcessId -ErrorAction SilentlyContinue
            if($remaining){
                $path=& $module {param($Id) Get-NeuralProcessPath $Id} $remaining.Id
                if($path -ieq $fixture){$null=$remaining.WaitForExit(10000)}
                $remaining.Dispose()
            }
        }
        & $module {param($Root) $script:NeuralRoot=$Root} $previousRoot
        [Environment]::SetEnvironmentVariable('PIN_FIXTURE_WAIT_MS',$previousWait,'Process')
        [Environment]::SetEnvironmentVariable('PIN_FIXTURE_OUTPUT',$previousOutput,'Process')
        [Environment]::SetEnvironmentVariable('PIN_FIXTURE_MAIN_MARKER',$previousMarker,'Process')
    }
    Write-Output 'PASS: malformed/unsupported PE and build mismatch fail closed; exact manager helper launches only a CPU fixture with preserved bridge import'
} finally {
    $full=[IO.Path]::GetFullPath($folder);$prefix=[IO.Path]::GetFullPath((Join-Path $repo 'runtime')).TrimEnd('\')+'\'
    if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $full -Recurse -Force}
}
