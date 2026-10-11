[CmdletBinding()]
param([switch]$RedBaseline,[switch]$NoBuild)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\Initialize-NeuralPowerShell.ps1')
function Assert-True($Condition,[string]$Message) { if (-not $Condition) { throw ('FAIL: '+$Message) } }
$build=Join-Path $root 'runtime\pinning\build'
if (-not $NoBuild) {
    if ($RedBaseline) { & (Join-Path $root 'scripts\Build-NeuralPinning.ps1') -FixturesOnly }
    else { & (Join-Path $root 'scripts\Build-NeuralPinning.ps1') }
}
$fixture=Join-Path $root ('runtime\pinning\fixture space-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
# Measure the compiled initializer, including inlined helpers. DLL startup can
# run on a small Windows loader-worker stack, regardless of the EXE stack size.
$compiler=Join-Path $root 'runtime\toolchains\llvm-mingw-20261006-ucrt-x86_64\bin\x86_64-w64-mingw32-clang++.exe'
$detours=Join-Path $root 'runtime\toolchains\Detours-1dbd4ea281d73d478aa8d09a8b83fbd265f715f7\microsoft-Detours-1dbd4ea\src'
& $compiler -std=c++17 -O2 -fstack-usage -I $detours -c (Join-Path $root 'native\NeuralGpuPin.cpp') -o (Join-Path $fixture 'stack.o')
Assert-True ($LASTEXITCODE -eq 0) 'Compile selector stack-usage report'
$startupStack=@(Get-Content (Join-Path $fixture 'stack.su') | Where-Object { ($_ -split "`t")[0] -match ':DllMain$' })
Assert-True ($startupStack.Count -eq 1 -and [int](($startupStack[0] -split "`t")[1]) -le 8192) 'Compiled DLL initializer must fit an 8 KiB stack budget on loader workers'
Write-Output 'PASS: compiled selector initializer stays within loader-worker stack budget'
foreach ($name in @('PinFixtureMain.exe','PinFixtureNoImport.exe','sl.interposer.dll','PinFixtureBridge.dll')) {
    Copy-Item -LiteralPath (Join-Path $build $name) -Destination (Join-Path $fixture $name)
}
$exe=Join-Path $fixture 'PinFixtureMain.exe'
$table=@(& $exe --enumerate)
Assert-True ($LASTEXITCODE -eq 0 -and $table.Count -gt 0) 'Read-only DXGI enumeration must provide an adapter'
$target=($table[0] -split '\|')[0]
Assert-True ($target -cmatch '^[0-9A-F]{8}-[0-9A-F]{8}$' -and $target -cne '0000F17F-F17F0001' -and $target -cne '0000F17F-F17F0002') 'Target identity comes from the current DXGI adapter table'
$hardwareTargets=@($table | Where-Object { [UInt32](($_ -split '\|')[2]) -eq 0 } | ForEach-Object { ($_ -split '\|')[0] })
Assert-True ($hardwareTargets.Count -gt 0) 'Pinning fixture requires an enumeratable non-software adapter'
$target=$hardwareTargets[0]
$environmentNames=@('PIN_FIXTURE_OUTPUT','PIN_FIXTURE_MAIN_MARKER','NEURAL_PIN_EXECUTABLE','NEURAL_PIN_LUID')
$original=@{}
foreach ($name in $environmentNames) { $original[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
function Set-Case([string]$Name) {
    $script:output=Join-Path $fixture ($Name+'-calls.txt')
    $script:marker=Join-Path $fixture ($Name+'-main.marker')
    [Environment]::SetEnvironmentVariable('PIN_FIXTURE_OUTPUT',$output,'Process')
    [Environment]::SetEnvironmentVariable('PIN_FIXTURE_MAIN_MARKER',$marker,'Process')
}
function Read-Calls {
    Assert-True (Test-Path -LiteralPath $output -PathType Leaf) 'The preserved original interposer must receive the calls'
    return @(Get-Content -LiteralPath $output)
}
function Invoke-RejectedLauncher([string[]]$NativeArguments) {
    # Windows PowerShell turns native stderr into an ErrorRecord. These calls
    # intentionally fail; retain their real exit code without terminating the
    # surrounding suite on the expected diagnostic.
    $ErrorActionPreference='Continue'
    & $launcher @NativeArguments 2>$null
    return $LASTEXITCODE
}
try {
    Set-Case 'baseline'
    & $exe
    Assert-True ($LASTEXITCODE -eq 0) 'CPU-only baseline fixture must finish normally'
    $calls=Read-Calls
    Assert-True ($calls.Count -eq 2 -and $calls[0] -ceq 'Main|0000F17F-F17F0001|sl.interposer|device' -and $calls[1] -ceq 'Bridge|0000F17F-F17F0002|sl.interposer|device') 'Baseline proves independent main and bridge requests traverse the original import'
    if ($RedBaseline) {
        Assert-True ($calls[0] -ceq ('Main|'+$target+'|sl.interposer|device')) 'Before pinning, the main executable does not request the selected physical adapter'
        throw 'Red baseline unexpectedly passed'
    }
    $launcher=Join-Path $build 'NeuralPinnedLaunch.exe'
    $pin=Join-Path $build 'NeuralGpuPin.dll'
    $inject=Join-Path $build 'PinFixtureInject.exe'
    Set-Case 'missing-detours-payload'
    & $exe --load-pin $pin $target
    Assert-True ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $output)) 'A matching environment cannot authorize a direct LoadLibrary without the startup Detours payload'
    Set-Case 'pinned'
    $result=Join-Path $fixture 'pinned-result.json'
    [Environment]::SetEnvironmentVariable('NEURAL_PIN_EXECUTABLE','parent-sentinel.exe','Process')
    [Environment]::SetEnvironmentVariable('NEURAL_PIN_LUID','PARENT-SENTINEL','Process')
    & $launcher --exe $exe --dll $pin --luid $target --result $result
    Assert-True ($LASTEXITCODE -eq 0) 'The launcher must create and resume its own injected fixture child'
    Assert-True (Test-Path -LiteralPath $result -PathType Leaf) 'A successful spawn records the new child PID'
    $spawn=Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
    Assert-True ($spawn.ProcessId -gt 0 -and $spawn.Status -ceq 'Spawned') 'Spawn result describes process creation without claiming GPU success'
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while ((-not (Test-Path -LiteralPath $output) -or @(Get-Content -LiteralPath $output).Count -lt 2) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    $calls=Read-Calls
    Assert-True ($calls.Count -eq 2 -and $calls[0] -ceq ('Main|'+$target+'|sl.interposer|device')) 'The real main IAT hook must select the exact current physical LUID and retain the original interposer'
    Assert-True ($calls[1] -ceq 'Bridge|0000F17F-F17F0002|sl.interposer|device') 'The bridge DLL import must preserve its explicitly requested other adapter'
    Assert-True ([Environment]::GetEnvironmentVariable('NEURAL_PIN_EXECUTABLE','Process') -ceq 'parent-sentinel.exe' -and [Environment]::GetEnvironmentVariable('NEURAL_PIN_LUID','Process') -ceq 'PARENT-SENTINEL') 'Launcher child environment cannot change caller variables'
    foreach ($bad in @('00000000-xyz','00000000-00000000','00000000:00000001','00000000-00000001extra')) {
        Set-Case ('bad-luid-'+[Guid]::NewGuid().ToString('N'))
        $badResult=Join-Path $fixture ([Guid]::NewGuid().ToString('N')+'.json')
        $rejectedExit=Invoke-RejectedLauncher @('--exe',$exe,'--dll',$pin,'--luid',$bad,'--result',$badResult)
        Assert-True ($rejectedExit -ne 0 -and -not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $badResult)) 'Malformed or zero LUID must reject launch before fixture main'
    }
    Set-Case 'existing-result'
    $existing=Join-Path $fixture 'existing.json'
    [IO.File]::WriteAllText($existing,'preserve this existing file')
    $rejectedExit=Invoke-RejectedLauncher @('--exe',$exe,'--dll',$pin,'--luid',$target,'--result',$existing)
    Assert-True ($rejectedExit -ne 0 -and -not (Test-Path -LiteralPath $marker) -and [IO.File]::ReadAllText($existing) -ceq 'preserve this existing file') 'An existing result file is never overwritten and no child starts'
    foreach ($case in @(
        @{Name='wrong-exe';Exe=$exe;Expected=(Join-Path $fixture 'unrelated.exe');Luid=$target},
        @{Name='malformed-child-luid';Exe=$exe;Expected=$exe;Luid='invalid'},
        @{Name='missing-import';Exe=(Join-Path $fixture 'PinFixtureNoImport.exe');Expected=(Join-Path $fixture 'PinFixtureNoImport.exe');Luid=$target}
    )) {
        Set-Case $case.Name
        $childCode=@(& $inject $case.Exe $pin $case.Expected $case.Luid)
        Assert-True ($LASTEXITCODE -eq 0 -and $childCode.Count -eq 1 -and [UInt64]$childCode[0] -ne 0 -and -not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $output)) ($case.Name+' must fail in the newly injected child before its main entry point')
    }
    Set-Case 'unavailable-adapter'
    $absent='FFFFFFEE-00000001'
    Assert-True ($absent -notin @($table | ForEach-Object { ($_ -split '\|')[0] })) 'Absent-LUID negative case cannot identify a current adapter'
    $childCode=@(& $inject $exe $pin $exe $absent)
    Assert-True ($LASTEXITCODE -eq 0 -and $childCode.Count -eq 1 -and [UInt64]$childCode[0] -ne 0 -and (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $output)) 'Lazy lookup failure must return failure to main without calling the original interposer on an unpinned adapter'
    foreach ($otherTarget in @($hardwareTargets | Select-Object -Skip 1)) {
        Set-Case ('exact-adapter-'+$otherTarget)
        $childCode=@(& $inject $exe $pin $exe $otherTarget)
        Assert-True ($LASTEXITCODE -eq 0 -and $childCode.Count -eq 1 -and [UInt64]$childCode[0] -eq 0) 'Each explicitly selected physical adapter must complete the CPU-only fixture'
        $calls=Read-Calls
        Assert-True ($calls.Count -eq 2 -and $calls[0] -ceq ('Main|'+$otherTarget+'|sl.interposer|device') -and $calls[1] -ceq 'Bridge|0000F17F-F17F0002|sl.interposer|device') 'Exact second-card selection must preserve both the original interposer and independent bridge request'
    }
    foreach ($case in @(
        @{Name='non-pe';Exe=(Join-Path $fixture 'not-a-pe.exe');Dll=$pin},
        @{Name='dll-as-exe';Exe=$pin;Dll=$pin},
        @{Name='no-injection-ordinal';Exe=$exe;Dll=(Join-Path $fixture 'PinFixtureBridge.dll')},
        @{Name='relative-path';Exe='PinFixtureMain.exe';Dll=$pin}
    )) {
        if ($case.Name -ceq 'non-pe') { [IO.File]::WriteAllText($case.Exe,'This is not executable code') }
        Set-Case $case.Name
        $badResult=Join-Path $fixture ($case.Name+'.json')
        $rejectedExit=Invoke-RejectedLauncher @('--exe',$case.Exe,'--dll',$case.Dll,'--luid',$target,'--result',$badResult)
        Assert-True ($rejectedExit -ne 0 -and -not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $badResult)) ($case.Name+' must reject before child creation')
    }
    Write-Output ('PASS: CPU-only native pinning launch and main-import isolation; observed physical targets '+[string]::Join(', ',$hardwareTargets))
}
finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name,$original[$name],'Process') }
}
