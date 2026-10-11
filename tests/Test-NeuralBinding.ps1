$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert-True($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Assert-Throws([scriptblock]$Action,[string]$Pattern) {
    try { & $Action | Out-Null } catch { Assert-True ($_.Exception.Message -match $Pattern) "Expected $Pattern, got $($_.Exception.Message)"; return }
    throw "FAIL: expected refusal $Pattern"
}
$root=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\runtime'))) ('binding-test-'+[Guid]::NewGuid().ToString('N'))
$oldRoot=$env:NEURAL_GAMING_ROOT
$module=$null
try {
    [IO.Directory]::CreateDirectory((Join-Path $root 'runtime\games')) | Out-Null
    $env:NEURAL_GAMING_ROOT=$root
    $module=Import-Module (Join-Path $PSScriptRoot '..\powershell\NeuralGaming.psm1') -Force -PassThru -DisableNameChecking
    Assert-True ($null -ne (Get-Command Start-NeuralGameBaseline -ErrorAction SilentlyContinue)) 'Explicit baseline launch command exists'
    $game=Join-Path $root 'game'; [IO.Directory]::CreateDirectory((Join-Path $game 'mgpu')) | Out-Null
    $exe=Join-Path $game 'fixture.exe'; [IO.File]::WriteAllText($exe,'Never execute this fixture')
    $files=@()
    foreach ($name in @('dxgi.dll','nvngx.dll_mgpu_bridge.addon64')) {
        $path=Join-Path $game ($name+'.neural-disabled'); [IO.File]::WriteAllText($path,'fixture DLL')
        $files += [pscustomobject]@{RelativePath=$name;DisabledRelativePath=$name+'.neural-disabled';Sha256=(Get-FileHash $path).Hash}
    }
    [IO.File]::WriteAllText((Join-Path $game 'mgpu\nvngx_dlssnr.dll'),'fixture model')
    [IO.File]::WriteAllText((Join-Path $game 'mgpu.ini'),"AutoArm=0`nPasses=1`nDcompOverlay=1")
    $manifest=[pscustomobject]@{Version=1;Name='fixture';Executable=$exe;GameDirectory=$game;Files=$files;CreatedDirectories=@()}
    $manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'runtime\games\fixture.json')
    [IO.File]::WriteAllText((Join-Path $root 'runtime\config.json'),'{"renderUuid":"GPU-headless","neuralUuid":"GPU-display"}')
    & $module {
        function script:Get-NeuralGamePinning {param($Name) [pscustomobject]@{Available=$true;Supported=$true;Message='Fixture selector'} }
        function script:Get-NeuralPinBinaryState {[pscustomobject]@{Available=$true;Fingerprint='fixture-selector';Message='Fixture selector'}}
        function script:Start-NeuralPinnedProcess {param($Manifest) Start-Process -FilePath $Manifest.Executable -WorkingDirectory $Manifest.GameDirectory -WindowStyle Normal -PassThru}
        $script:FixtureInvalidTopology=$false
        function script:Get-NeuralGpus { @([pscustomobject]@{Index=0;Uuid='GPU-display';Name='3090';DisplayActive=(-not $script:FixtureInvalidTopology);PciBusId='21'},[pscustomobject]@{Index=1;Uuid='GPU-headless';Name='3090';DisplayActive=$false;PciBusId='49'}) }
        function script:Get-NeuralGpuAdapters { param($Gpus) foreach($g in $Gpus) { $g | Add-Member NoteProperty Luid $(if($g.Uuid -eq 'GPU-display'){'00000000-00000021'}else{'00000000-00000049'}) -PassThru } }
        function script:Get-NeuralWindowsGraphicsFingerprint { param($Executable) 'fixture-preferences' }
        $script:FixtureBoot='boot-one'
        function script:Get-NeuralBootIdentity {$script:FixtureBoot}
        function script:Get-NeuralGameProcesses { param($Manifest) if($script:FixtureRunning) { $script:FixtureProcess } }
        $script:FixtureRunning=$false; $script:FixtureStarted=0
        $script:FixtureProcess=[pscustomobject]@{Id=12345;Path=$null;StartTime=[DateTime]::Now}
        function script:Get-NeuralProcessPath { param($ProcessId) (Get-NeuralManifest 'fixture').Executable }
        function script:Start-Process { param($FilePath,$WorkingDirectory,$WindowStyle,[switch]$PassThru) $script:FixtureStarted++; $script:FixtureRunning=$true; $script:FixtureProcess }
        function script:Get-NeuralProcessGpuSamples { param($ProcessId,$SampleCount,$IntervalMilliseconds) for($i=1;$i -le 4;$i++){ [pscustomobject]@{ProcessId=$ProcessId;SampleIndex=$i;Luid=$script:FixtureSampleLuid;Engine='3d';Utilization=70} } }
        $script:FixtureSampleLuid='00000000-00000021'
        function script:Get-NeuralNvidiaProcessSamples { param($ProcessId,$Adapters,$SampleCount,$IntervalMilliseconds) @() }
    }
    $setup=Test-NeuralGameSetup fixture
    Assert-True ($setup.DependenciesReady -and $setup.Ready) 'Direct neural launch requires dependencies and topology without a baseline lease'
    $iniPath=Join-Path $game 'mgpu.ini'
    foreach($unsafeIni in @("AutoArm=1`nAutoArm=0`nPasses=1`nDcompOverlay=1","AutoArm=0`nPasses=2`nPasses=1`nDcompOverlay=1","AutoArm=0`nPasses=1`nDcompOverlay=0`nDcompOverlay=1","autoarm=0`nPasses=1`nDcompOverlay=1","AutoArm = 0`nPasses=1`nDcompOverlay=1")){
        [IO.File]::WriteAllText($iniPath,$unsafeIni)
        Assert-True (-not (Test-NeuralGameSetup fixture).DependenciesReady) 'Unsafe/duplicate/case-mismatched effective bridge keys cannot pass dependency checks'
    }
    [IO.File]::WriteAllText($iniPath,"  AutoArm=0`n`tPasses=1`n DcompOverlay=1")
    Assert-True (Test-NeuralGameSetup fixture).DependenciesReady 'Canonical safe keys accept upstream leading spaces/tabs'
    [IO.File]::WriteAllText($iniPath,"AutoArm=0`nPasses=1`nDcompOverlay=1")
    & $module {
        $script:FixtureLaunchBoundary=(Get-Command Start-NeuralPinnedProcess).ScriptBlock
        function script:Start-NeuralPinnedProcess {param($Manifest)
            if([IO.File]::ReadAllText((Join-Path $Manifest.GameDirectory 'mgpu.ini')) -notmatch '(?m)^AutoArm=0$'){throw 'AutoArm was not disabled before process startup'}
            throw 'Direct launch reached with AutoArm verified'
        }
    }
    $originalIni=[IO.File]::ReadAllBytes($iniPath)
    Assert-Throws { Start-NeuralGame fixture } 'Direct launch reached'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($iniPath)) -ceq [Convert]::ToBase64String($originalIni)) 'Failed direct launch restores exact original AutoArm bytes'
    Assert-True ((Get-NeuralGameStatus fixture).State -eq 'Disabled') 'Failed direct launch restores injector files'
    [IO.File]::WriteAllText($iniPath,"AutoArm=1`nPasses=1`nDcompOverlay=1")
    Assert-Throws { Start-NeuralGame fixture } 'Direct launch reached'
    Assert-True ([IO.File]::ReadAllText($iniPath) -match '(?m)^AutoArm=1$') 'Launch overrides an existing AutoArm=1 to manual mode and restores it after failure'
    & $module {Set-NeuralLaunchAutoArm fixture 0}
    [IO.File]::AppendAllText($iniPath,"`nCalibration=manual-preserved")
    Stop-NeuralGame fixture | Out-Null
    Assert-True ([IO.File]::ReadAllText($iniPath) -match '(?m)^AutoArm=1$' -and [IO.File]::ReadAllText($iniPath) -match 'Calibration=manual-preserved') 'Manual session recovery restores a previous AutoArm=1 while preserving unrelated edits'
    [IO.File]::WriteAllBytes($iniPath,$originalIni)
    & $module {
        Set-NeuralLaunchAutoArm fixture 1
        $ini=Join-Path (Get-NeuralManifest fixture).GameDirectory 'mgpu.ini'
        [IO.File]::AppendAllText($ini,"`nCalibration=preserved")
    }
    Stop-NeuralGame fixture | Out-Null
    Assert-True ([IO.File]::ReadAllText($iniPath) -match '(?m)^AutoArm=0$' -and [IO.File]::ReadAllText($iniPath) -match 'Calibration=preserved') 'Recover restores AutoArm while preserving runtime or user edits to unrelated settings'
    [IO.File]::WriteAllBytes($iniPath,$originalIni)
    & $module {Set-NeuralLaunchAutoArm fixture 1;Restore-NeuralLaunchAutoArm fixture}
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($iniPath)) -ceq [Convert]::ToBase64String($originalIni)) 'Recovery without other edits restores exact original INI bytes'
    & $module {
        function script:Start-NeuralPinnedProcess {param($Manifest)
            if([IO.File]::ReadAllText((Join-Path $Manifest.GameDirectory 'mgpu.ini')) -notmatch '(?m)^AutoArm=0$'){throw 'Successful launch without manual arm'}
            $fake=[pscustomobject]@{Id=4242;StartTime=[DateTime]::Now}
            $fake | Add-Member ScriptMethod WaitForExit {} -PassThru
        }
    }
    Start-NeuralGame fixture
    Assert-True ((Get-NeuralGameStatus fixture).State -eq 'Disabled' -and [IO.File]::ReadAllText($iniPath) -match '(?m)^AutoArm=0$') 'Successful session exit restores normal Steam launch state: disabled injector and original AutoArm'
    $completed=Get-Content (Join-Path $root 'runtime\binding\fixture.session.json') -Raw | ConvertFrom-Json
    Assert-True ($completed.LaunchAutoArm -eq 0) 'Session record reports manual arm verified at the native launch boundary'
    Assert-True (-not (Test-Path (Join-Path $root 'runtime\binding\fixture.autoarm.json'))) 'Successful cleanup removes pending AutoArm recovery'
    & $module {Set-Item Function:Start-NeuralPinnedProcess $script:FixtureLaunchBoundary}
    Start-NeuralGameBaseline fixture | Out-Null
    Assert-True ((Get-NeuralGameStatus fixture).State -eq 'Disabled') 'Baseline keeps both injector DLLs disabled'
    Assert-Throws { Confirm-NeuralGameGpu fixture } 'display|headless|requested'
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'Wrong adapter cannot authorize neural launch'
    & $module { $script:FixtureSampleLuid='00000000-00000049' }
    $started=& $module {$script:FixtureProcess.StartTime}
    & $module {$script:FixtureProcess.StartTime=$script:FixtureProcess.StartTime.AddSeconds(1)}
    Assert-Throws { Confirm-NeuralGameGpu fixture } 'identity changed'
    & $module {param($Time) $script:FixtureProcess.StartTime=$Time} $started
    & $module {function script:Get-NeuralPinBinaryState {[pscustomobject]@{Available=$true;Fingerprint='changed-selector';Message='Fixture selector'}}}
    Assert-Throws {Confirm-NeuralGameGpu fixture} 'baseline.*changed|changed.*baseline'
    & $module {function script:Get-NeuralPinBinaryState {[pscustomobject]@{Available=$true;Fingerprint='fixture-selector';Message='Fixture selector'}}}
    $originalExecutable=[IO.File]::ReadAllBytes($exe)
    [IO.File]::AppendAllText($exe,'updated while baseline runs')
    Assert-Throws {Confirm-NeuralGameGpu fixture} 'baseline.*changed|changed.*baseline'
    [IO.File]::WriteAllBytes($exe,$originalExecutable)
    & $module {
        Set-NeuralGameEnabled fixture $true
        Save-NeuralSessionRecord fixture $script:FixtureProcess ([DateTime]::UtcNow) 'ABSENT'
        function script:Get-NeuralLogState {param($LogPath,$ExpectedRenderLuid,$ExpectedNeuralLuid,$NotBeforeUtc,$PreviousPrefixHash)
            [pscustomobject]@{Status='Bound';Fresh=$true;BindingVerified=$true;Armed=$false;Streaming=$false;Message='Fixture fresh binding'}
        }
    }
    Assert-True (Get-NeuralGameRuntime fixture).BindingVerified 'Current valid topology permits fresh binding evidence'
    & $module {$script:FixtureInvalidTopology=$true}
    Assert-True (-not (Get-NeuralGameRuntime fixture).BindingVerified) 'Display detachment invalidates runtime binding despite identical UUIDs and LUIDs'
    & $module {$script:FixtureInvalidTopology=$false;Set-NeuralGameEnabled fixture $false}
    & $module {
        $script:FixtureSamples=(Get-Command Get-NeuralProcessGpuSamples).ScriptBlock
        function script:Get-NeuralProcessGpuSamples {param($ProcessId,$SampleCount,$IntervalMilliseconds)
            & $script:FixtureSamples $ProcessId $SampleCount $IntervalMilliseconds
            [pscustomobject]@{ProcessId=$ProcessId;SampleIndex=2;Luid='00000000-00000999';Engine='3d';Utilization=0.5}
        }
    }
    Assert-Throws { Confirm-NeuralGameGpu fixture } 'mixed|headless|requested'
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'Unknown active 3D adapter cannot authorize neural launch'
    & $module {Set-Item Function:Get-NeuralProcessGpuSamples $script:FixtureSamples}
    & $module {
        function script:Get-NeuralProcessGpuSamples {param($ProcessId,$SampleCount,$IntervalMilliseconds)
            & $script:FixtureSamples $ProcessId $SampleCount $IntervalMilliseconds
            for($i=1;$i -le 4;$i++){[pscustomobject]@{ProcessId=$ProcessId;SampleIndex=$i;Luid='00000000-00000021';Engine='3d';Utilization=5}}
        }
    }
    $shared=Confirm-NeuralGameGpu fixture
    Assert-True ($shared.CanLaunch -and $shared.Message -match 'display GPU also active') 'Repeated headless activity with the configured display companion is observed without claiming exclusive device ownership'
    & $module {Set-Item Function:Get-NeuralProcessGpuSamples $script:FixtureSamples}
    & $module {
        function script:Get-NeuralProcessGpuSamples {param($ProcessId,$SampleCount,$IntervalMilliseconds) @()}
        function script:Get-NeuralNvidiaProcessSamples {param($ProcessId,$Adapters,$SampleCount,$IntervalMilliseconds)
            for($i=0;$i -lt 4;$i++){[pscustomobject]@{ProcessId=$ProcessId;SampleIndex=$i;Uuid='GPU-headless';Luid='00000000-00000049';Kind='C+G'}}
        }
    }
    $nvidiaBinding=Confirm-NeuralGameGpu fixture
    Assert-True ($nvidiaBinding.CanLaunch -and $nvidiaBinding.Message -match 'NVIDIA') 'Repeated exclusive NVIDIA graphics membership permits observation when Windows counters are missing'
    $nvidiaLease=Get-Content (Join-Path $root 'runtime\binding\fixture.verified.json') -Raw | ConvertFrom-Json
    Assert-True ($nvidiaLease.EvidenceSource -eq 'NVIDIA graphics process list') 'Lease records membership source without claiming measured 3D utilization'
    & $module {
        $script:FixtureNvidia=(Get-Command Get-NeuralNvidiaProcessSamples).ScriptBlock
        function script:Get-NeuralNvidiaProcessSamples {param($ProcessId,$Adapters,$SampleCount,$IntervalMilliseconds)
            & $script:FixtureNvidia $ProcessId $Adapters $SampleCount $IntervalMilliseconds
            [pscustomobject]@{ProcessId=$ProcessId;SampleIndex=1;Uuid='GPU-display';Luid='00000000-00000021';Kind='C+G'}
        }
    }
    Assert-Throws { Confirm-NeuralGameGpu fixture } 'mixed|headless'
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'NVIDIA membership alone on both GPUs does not identify a render device'
    & $module {function script:Get-NeuralNvidiaProcessSamples {param($ProcessId,$Adapters,$SampleCount,$IntervalMilliseconds) throw 'NVIDIA fixture unavailable'}}
    Assert-Throws { Confirm-NeuralGameGpu fixture } 'Insufficient|unavailable'
    Assert-True ((Get-NeuralGameBinding fixture).Status -eq 'Unknown') 'Missing Windows counters and failed NVIDIA query remain unknown, not a wrong GPU'
    & $module {
        Set-Item Function:Get-NeuralNvidiaProcessSamples $script:FixtureNvidia
        function script:Get-NeuralProcessGpuSamples {param($ProcessId,$SampleCount,$IntervalMilliseconds) throw 'Windows fixture unavailable'}
    }
    Assert-True (Confirm-NeuralGameGpu fixture).CanLaunch 'Failed Windows counter query can fall back to repeated exclusive NVIDIA graphics membership'
    & $module {
        function script:Get-NeuralProcessGpuSamples {param($ProcessId,$SampleCount,$IntervalMilliseconds)
            for($i=0;$i -lt 4;$i++){[pscustomobject]@{ProcessId=$ProcessId;SampleIndex=$i;Luid='00000000-00000049';Engine='3d';Utilization=0.5}}
        }
    }
    Assert-True ((Confirm-NeuralGameGpu fixture).Message -match 'NVIDIA') 'Weak headless Windows utilization uses repeated NVIDIA graphics membership instead of falsely declaring a GPU mismatch'
    & $module {
        function script:Get-NeuralProcessGpuSamples {param($ProcessId,$SampleCount,$IntervalMilliseconds)
            for($i=0;$i -lt 4;$i++){[pscustomobject]@{ProcessId=$ProcessId;SampleIndex=$i;Luid='00000000-00000021';Engine='3d';Utilization=10}}
        }
    }
    Assert-Throws { Confirm-NeuralGameGpu fixture } 'Display|headless'
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'Favorable NVIDIA membership cannot override display-only Windows activity'
    & $module {
        function script:Get-NeuralProcessGpuSamples {param($ProcessId,$SampleCount,$IntervalMilliseconds)
            & $script:FixtureSamples $ProcessId $SampleCount $IntervalMilliseconds
            [pscustomobject]@{ProcessId=$ProcessId;SampleIndex=1;Luid='00000000-00000999';Engine='3d';Utilization=0.5}
        }
    }
    Assert-Throws { Confirm-NeuralGameGpu fixture } 'unknown|headless'
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'Favorable NVIDIA membership cannot override an unknown active Windows adapter'
    & $module {Set-Item Function:Get-NeuralProcessGpuSamples $script:FixtureSamples}
    $observed=Confirm-NeuralGameGpu fixture
    Assert-True ($observed.Status -eq 'Observed' -and $observed.CanLaunch) 'Repeated headless process activity records observation'
    Assert-Throws { Start-NeuralGame fixture } 'already running'
    & $module { $script:FixtureRunning=$false }
    Assert-True ((Test-NeuralGameSetup fixture).Ready) 'Direct launch remains ready after baseline closes'
    & $module {function script:Get-NeuralPinBinaryState {[pscustomobject]@{Available=$true;Fingerprint='changed-selector';Message='Fixture selector'}}}
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'Selector build update invalidates observation'
    & $module {function script:Get-NeuralPinBinaryState {[pscustomobject]@{Available=$true;Fingerprint='fixture-selector';Message='Fixture selector'}}}
    $other=Join-Path $root 'other-game';[IO.Directory]::CreateDirectory((Join-Path $other 'mgpu')) | Out-Null
    Copy-Item $exe (Join-Path $other 'fixture.exe')
    Copy-Item (Join-Path $game 'mgpu.ini') (Join-Path $other 'mgpu.ini')
    Copy-Item (Join-Path $game 'mgpu\nvngx_dlssnr.dll') (Join-Path $other 'mgpu\nvngx_dlssnr.dll')
    $different= & $module {param($Directory) $m=Get-NeuralManifest fixture;$original=Get-NeuralBindingContext $m;$m.Executable=Join-Path $Directory 'fixture.exe';$m.GameDirectory=$Directory;$copy=Get-NeuralBindingContext $m;$original.Fingerprint -ne $copy.Fingerprint} $other
    Assert-True $different 'Byte-identical games at different paths have distinct observation contexts'
    & $module {$script:FixtureBoot='boot-two'}
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'Reboot invalidates observation even if adapter LUIDs repeat'
    & $module {$script:FixtureBoot='boot-one'}
    $leasePath=Join-Path $root 'runtime\binding\fixture.verified.json'
    $lease=Get-Content $leasePath -Raw | ConvertFrom-Json
    $lease.ExpiresUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o'); $lease | ConvertTo-Json -Depth 12 | Set-Content $leasePath
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'Expired observation is rejected'
    & $module { $script:FixtureRunning=$true }
    Confirm-NeuralGameGpu fixture | Out-Null
    & $module { $script:FixtureRunning=$false }
    [IO.File]::AppendAllText($exe,'changed executable')
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'Executable update invalidates observation'
    # An optional baseline becoming stale does not disable direct launch.
    Assert-True ((Get-NeuralGameStatus fixture).State -eq 'Disabled') 'Baseline observation never changes injector state'
    & $module {$script:FixtureRunning=$true}
    Assert-Throws {Confirm-NeuralGameGpu fixture} 'baseline.*changed|changed.*baseline'
    & $module {$script:FixtureRunning=$false}
    Start-NeuralGameBaseline fixture | Out-Null
    Confirm-NeuralGameGpu fixture | Out-Null
    & $module {
        $script:FixtureRunning=$false
        function script:Start-Process {param($FilePath,$WorkingDirectory,$WindowStyle,[switch]$PassThru)
            if(-not (Test-Path (Join-Path $WorkingDirectory 'dxgi.dll'))){throw 'Fixture launch before activation'}
            if([IO.File]::ReadAllText((Join-Path $WorkingDirectory 'mgpu.ini')) -notmatch '(?m)^AutoArm=0$'){throw 'Fixture launch without manual arm'}
            throw 'Fixture native launch failure'
        }
    }
    Assert-Throws {Start-NeuralGame fixture} 'Fixture native launch failure'
    Assert-True (-not (Get-NeuralGameBinding fixture).CanLaunch) 'Direct launch clears the optional baseline lease even on native failure'
    Assert-True (-not (Test-Path $leasePath)) 'One-use observation file removed before launching'
    Assert-True ((Get-NeuralGameStatus fixture).State -eq 'Disabled') 'Failed attempt recovers disabled injector files'
    Assert-Throws {Start-NeuralGame fixture} 'Fixture native launch failure'
    Assert-True ([IO.File]::ReadAllText($iniPath) -match '(?m)^AutoArm=0$') 'Repeated direct attempts restore AutoArm after failure'
    & $module {
        # Simulate interruption between recording recovery and changing the INI.
        $m=Get-NeuralManifest fixture
        $path=Join-Path $m.GameDirectory 'mgpu.ini'
        $text=[IO.File]::ReadAllText($path)
        Write-NeuralBindingRecord fixture autoarm ([pscustomobject]@{Version=1;Executable=$m.Executable;Original=[Convert]::ToBase64String([IO.File]::ReadAllBytes($path));PreviousAutoArm=0;EnabledTextHash=(Get-NeuralTextHash ($text.Replace('AutoArm=0','AutoArm=1')))})
    }
    Uninstall-NeuralGame fixture | Out-Null
    Assert-True (-not (Test-Path (Join-Path $root 'runtime\binding\fixture.autoarm.json'))) 'Uninstall removes interrupted AutoArm recovery so a future reinstall is not blocked'
    Write-Output 'PASS: missing, wrong, mixed, PID-reused, expired and changed observations block activation; one-use attempt cleans up'
} finally {
    $env:NEURAL_GAMING_ROOT=$oldRoot
    if($module){Remove-Module $module.Name -ErrorAction SilentlyContinue}
    $full=[IO.Path]::GetFullPath($root); $parent=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\runtime')).TrimEnd('\')+'\'
    if($full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
