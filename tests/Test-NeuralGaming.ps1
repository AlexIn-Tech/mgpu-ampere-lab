param([string]$ModulePath = (Join-Path $PSScriptRoot '..\powershell\NeuralGaming.psm1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "Expected '$Pattern', got '$($_.Exception.Message)'"
        return
    }
    throw "FAIL: Expected refusal matching '$Pattern'"
}
function Start-FixturePowerShell([string]$Script) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    return [Diagnostics.Process]::Start($info)
}
function Wait-FixturePowerShell($Process) {
    if (-not $Process.WaitForExit(30000)) { $Process.Kill(); throw 'Fixture PowerShell timed out.' }
    $output = $Process.StandardOutput.ReadToEnd() + $Process.StandardError.ReadToEnd()
    Assert-True ($Process.ExitCode -eq 0) "Fixture PowerShell failed: $output"
}
Assert-True (Test-Path -LiteralPath $ModulePath) 'Manager module is implemented'
$testBase = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\runtime'))
$testRoot = Join-Path $testBase ('NeuralGaming-test-' + [guid]::NewGuid().ToString('N'))
$previousRoot = $env:NEURAL_GAMING_ROOT
$previousPath = $env:PATH
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $env:NEURAL_GAMING_ROOT = $testRoot
    # Process entry points are replaced only for import; calling any one is an observable failure.
    function global:Start-Process { throw 'Import started a process' }
    function global:nvidia-smi { throw 'Import queried a GPU process' }
    try { $module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking }
    finally { Remove-Item Function:\Start-Process,Function:\nvidia-smi }
    Assert-True (-not (Test-Path (Join-Path $testRoot 'runtime'))) 'Import writes no runtime files'
    $childPrelude = "`$ErrorActionPreference = 'Stop'`n`$env:NEURAL_GAMING_ROOT = '$($testRoot.Replace("'", "''"))'`nImport-Module '$((Get-Item -LiteralPath $ModulePath).FullName.Replace("'", "''"))' -Force -DisableNameChecking`n"
    Write-Output 'PASS: import is inert'

    # Exercise the external-command query boundary; a deprecated/extra field makes this fixture fail.
    $gpuCommandFolder = Join-Path $testRoot 'gpu-command'
    New-Item -ItemType Directory -Path $gpuCommandFolder | Out-Null
    Set-Content (Join-Path $gpuCommandFolder 'nvidia-smi.cmd') @'
@echo off
if not "%*"=="--query-gpu=index,uuid,name,display_active,pci.bus_id --format=csv,noheader,nounits" exit /b 7
echo 0, GPU-display, NVIDIA GeForce RTX 3090, Enabled, 00000000:01:00.0
echo 1, GPU-headless, NVIDIA GeForce RTX 3090, Disabled, 00000000:02:00.0
'@
    $env:PATH = $gpuCommandFolder
    $queriedGpus = @(Get-NeuralGpus)
    Assert-True ($queriedGpus.Count -eq 2 -and $queriedGpus[0].DisplayActive -and -not $queriedGpus[1].DisplayActive) 'Supported NVIDIA query parses display activity'
    Assert-True ($queriedGpus[1].PciBusId -eq '00000000:02:00.0') 'GPU query headers preserve PCI bus identity'
    $env:PATH = $previousPath
    Write-Output 'PASS: GPU discovery uses supported NVIDIA fields and matching headers'

    $package = Join-Path $testRoot 'package'
    New-Item -ItemType Directory -Path (Join-Path $package 'reshade-shaders\Shaders') -Force | Out-Null
    Set-Content (Join-Path $package 'nvngx.dll_mgpu_bridge.addon64') 'bridge fixture'
    Set-Content (Join-Path $package 'mgpu.ini') "[MGPU]`nAutoArm=1`nPasses=2`nDcompOverlay=0"
    Set-Content (Join-Path $package 'ReShade2.ini') "[GENERAL]`nPresetPath=.\gpu1.ini"
    Set-Content (Join-Path $package 'gpu1.ini') '' -NoNewline
    Set-Content (Join-Path $package 'reshade-shaders\Shaders\mgpu_depth_tap.fx') 'shader fixture'
    Set-Content (Join-Path $package 'LICENSE') 'excluded'
    Set-Content (Join-Path $package 'README.txt') 'excluded'
    $reshade = Join-Path $testRoot 'ReShade64.dll'
    Set-Content $reshade 'reshade fixture'
    function New-GameFixture([string]$Name) {
        $dir = Join-Path $testRoot $Name
        New-Item -ItemType Directory -Path $dir | Out-Null
        $exe = Join-Path $dir ($Name + '.exe')
        Set-Content $exe 'not executable; launch must remain blocked'
        return $exe
    }
    $relativeExe = New-GameFixture 'Relative'
    $modelSource = Join-Path $testRoot 'model.dll'
    Set-Content $modelSource 'neural source fixture'
    $originalLocation = Get-Location
    try {
        Set-Location -LiteralPath $testRoot
        Assert-True ([Environment]::CurrentDirectory -ne (Get-Location).Path) 'Fixture separates PowerShell location from process working directory'
        Install-NeuralGame -Name Relative -Executable '.\Relative\Relative.exe' -PackagePath '.\package' -ReShadeDll '.\ReShade64.dll' -NeuralDll '.\model.dll' | Out-Null
    } finally { Set-Location -LiteralPath $originalLocation.Path }
    $relativeDir = Split-Path $relativeExe
    Assert-True ((Get-FileHash (Join-Path $relativeDir 'dxgi.dll.neural-disabled')).Hash -eq (Get-FileHash $reshade).Hash) 'Relative ReShade source resolves from PowerShell location'
    Assert-True ((Get-FileHash (Join-Path $relativeDir 'mgpu\nvngx_dlssnr.dll')).Hash -eq (Get-FileHash $modelSource).Hash) 'Relative neural source resolves from PowerShell location'
    $relativeManifest = Join-Path $testRoot 'runtime\games\Relative.json'
    $manifestHash = (Get-FileHash $relativeManifest).Hash
    Assert-Throws { Install-NeuralGame -Name Relative -Executable $relativeExe -PackagePath $package -ReShadeDll $reshade } 'already exists'
    Assert-True ((Get-FileHash $relativeManifest).Hash -eq $manifestHash) 'A previously existing manifest is preserved'
    Uninstall-NeuralGame -Name Relative | Out-Null
    Write-Output 'PASS: relative DLL inputs resolve correctly and existing manifest is preserved'

    # Inject failure only at the native stream-write boundary; actual file creation and rollback remain real.
    $partialExe = New-GameFixture 'PartialManifest'
    $installDefinition = & $module { (Get-Command Install-NeuralGame).ScriptBlock }
    $writeCall = '$manifestStream.Write($jsonBytes, 0, $jsonBytes.Length)'
    $faultingInstall = [scriptblock]::Create($installDefinition.ToString().Replace($writeCall, ('$manifestStream.Dispose(); ' + $writeCall)))
    try {
        & $module { param($definition) Set-Item Function:Install-NeuralGame $definition } $faultingInstall
        Assert-Throws { & $module { param($exe, $pkg, $dll) Install-NeuralGame -Name PartialManifest -Executable $exe -PackagePath $pkg -ReShadeDll $dll } $partialExe $package $reshade } 'closed|disposed'
        Assert-True (-not (Test-Path (Join-Path $testRoot 'runtime\games\PartialManifest.json'))) 'Failed write removes only its newly created partial manifest'
        Assert-True (-not (Test-Path (Join-Path (Split-Path $partialExe) 'dxgi.dll.neural-disabled'))) 'Manifest write failure rolls back copied DLLs'
    } finally { & $module { param($definition) Set-Item Function:Install-NeuralGame $definition } $installDefinition }
    $retryInstall = Start-FixturePowerShell ($childPrelude + "Install-NeuralGame -Name PartialManifest -Executable '$($partialExe.Replace("'", "''"))' -PackagePath '$($package.Replace("'", "''"))' -ReShadeDll '$($reshade.Replace("'", "''"))' | Out-Null`nUninstall-NeuralGame -Name PartialManifest | Out-Null")
    try { Wait-FixturePowerShell $retryInstall } finally { $retryInstall.Dispose() }
    Write-Output 'PASS: failed manifest write rolls back its own partial installation'

    $exe = New-GameFixture 'Fixture'
    $gameDir = Split-Path $exe
    Install-NeuralGame -Name Fixture -Executable $exe -PackagePath $package -ReShadeDll $reshade | Out-Null
    Assert-True (Test-Path (Join-Path $gameDir 'dxgi.dll.neural-disabled')) 'ReShade stages disabled'
    Assert-True (Test-Path (Join-Path $gameDir 'nvngx.dll_mgpu_bridge.addon64.neural-disabled')) 'Bridge stages disabled'
    Assert-True (-not (Test-Path (Join-Path $gameDir 'dxgi.dll'))) 'No active dxgi.dll at installation'
    Assert-True (-not (Test-Path (Join-Path $gameDir 'README.txt'))) 'Documentation is not copied to game'
    $ini = Get-Content (Join-Path $gameDir 'mgpu.ini') -Raw
    Assert-True ($ini -match '(?m)^AutoArm=0\s*$' -and $ini -match '(?m)^Passes=1\s*$') 'Conservative bridge settings'
    Assert-True ((Get-Content (Join-Path $gameDir 'ReShade.ini') -Raw) -match 'EffectSearchPaths=.\\reshade-shaders\\Shaders\\\*\*') 'GAME runtime shader search path'
    Assert-True ((Get-Item (Join-Path $gameDir 'NeuralGamingPreset.ini')).Length -eq 0) 'Game preset is empty'
    Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Disabled') 'Status reports disabled'
    Write-Output 'PASS: installation stages disabled files and conservative configuration'

    $collisionExe = New-GameFixture 'Collision'
    $collision = Join-Path (Split-Path $collisionExe) 'dxgi.dll'
    Set-Content $collision 'existing mod'
    $before = (Get-FileHash $collision).Hash
    Assert-Throws { Install-NeuralGame -Name Collision -Executable $collisionExe -PackagePath $package -ReShadeDll $reshade } 'conflict|exists'
    Assert-True ((Get-FileHash $collision).Hash -eq $before) 'Existing mod remains byte-identical'
    Assert-True (-not (Test-Path (Join-Path (Split-Path $collisionExe) 'mgpu.ini'))) 'Conflict leaves no partial files'
    Write-Output 'PASS: existing mod collision is preserved'

    & $module { param($n) Set-NeuralGameEnabled -Name $n -Enabled $true } Fixture
    Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Enabled') 'Activation enables both DLLs'
    Stop-NeuralGame -Name Fixture | Out-Null
    Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Disabled') 'Stop deactivates after game is closed'
    Write-Output 'PASS: activation/deactivation round-trip'

    Assert-Throws { Start-NeuralGame -Name Fixture } 'nvngx_dlssnr.dll|neural DLL'
    Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Disabled') 'Missing model refuses before activation'
    Write-Output 'PASS: missing neural DLL prevents launch'

    # Keep file management real; substitute only GPU discovery and the OS process launch boundary.
    $neural = Join-Path $gameDir 'mgpu\nvngx_dlssnr.dll'
    New-Item -ItemType Directory -Path (Split-Path $neural) | Out-Null
    Set-Content $neural 'model fixture'
    $gpuDefinition = & $module { (Get-Command Get-NeuralGpus).ScriptBlock }
    & $module {
        # Lease policy is exercised in Test-NeuralBinding. This fixture isolates
        # existing file integrity, rollback and cross-process mutex behavior.
        function script:Get-NeuralGameBinding { param($Name) [pscustomobject]@{CanLaunch=$true;Message='Fixture observation'} }
        function script:Get-NeuralGamePinning {param($Name) [pscustomobject]@{Available=$true;Supported=$true;Message='Fixture selector'} }
        function script:Start-NeuralPinnedProcess {param($Manifest) Start-Process -FilePath $Manifest.Executable -WorkingDirectory $Manifest.GameDirectory -WindowStyle Normal -PassThru}
        function script:Consume-NeuralGameBinding { param($Name) }
        function script:Save-NeuralSessionRecord { param($Name,$Process,$StartedUtc,$PreviousPrefixHash) }
        function script:Get-NeuralGpus {
            [pscustomobject]@{ Index = 0; Uuid = 'GPU-display'; Name = 'NVIDIA GeForce RTX 3090'; DisplayActive = $true; DisplayMode = 'Enabled'; PciBusId = '00000000:01:00.0' }
            [pscustomobject]@{ Index = 1; Uuid = 'GPU-headless'; Name = 'NVIDIA GeForce RTX 3090'; DisplayActive = $false; DisplayMode = 'Disabled'; PciBusId = '00000000:02:00.0' }
        }
    }
    $configPath = Join-Path $testRoot 'runtime\config.json'
    Set-Content $configPath '{"renderUuid":"GPU-display","neuralUuid":"GPU-headless"}'
    Assert-True (-not (Test-NeuralGameSetup -Name Fixture).Ready) 'Wrong GPU roles refuse setup'
    Assert-Throws { Start-NeuralGame -Name Fixture } 'headless GPU'
    Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Disabled') 'Topology refusal leaves DLLs disabled'
    Set-Content $configPath '{"renderUuid":"GPU-headless","neuralUuid":"GPU-display"}'
    $preflight = Test-NeuralGameSetup -Name Fixture
    Assert-True $preflight.Ready 'Correct fixture topology and dependencies pass setup'
    Assert-True (-not $preflight.GpuSelectionVerified -and -not $preflight.RuntimeVerified) 'Preflight does not claim Windows adapter or runtime validation'
    & $module {
        function script:Start-Process {
            param($FilePath, $WorkingDirectory, $WindowStyle, [switch]$PassThru)
            if (-not (Test-Path -LiteralPath (Join-Path $WorkingDirectory 'dxgi.dll'))) { throw 'Launch attempted before activation' }
            throw 'Fixture OS launch failure'
        }
    }
    Assert-Throws { Start-NeuralGame -Name Fixture } 'Fixture OS launch failure'
    Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Disabled') 'Failed OS launch restores disabled DLLs'

    # A separate process must be able to mutate after failure; same-thread reentrancy could hide a leaked lease.
    $afterFailure = Start-FixturePowerShell ($childPrelude + 'Stop-NeuralGame -Name Fixture | Out-Null')
    try { Wait-FixturePowerShell $afterFailure } finally { $afterFailure.Dispose() }
    Write-Output 'PASS: failed session releases its operation lease to another PowerShell process'

    $eventId = [guid]::NewGuid().ToString('N')
    $readyName = 'Local\NeuralGamingTestReady-' + $eventId
    $continueName = 'Local\NeuralGamingTestContinue-' + $eventId
    $cleanupName = 'Local\NeuralGamingTestCleanup-' + $eventId
    $finishName = 'Local\NeuralGamingTestFinish-' + $eventId
    $ready = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $readyName)
    $continue = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $continueName)
    $cleanup = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $cleanupName)
    $finish = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $finishName)
    $sessionScript = $childPrelude + @'
$module = Get-Module NeuralGaming
& $module {
    param($readyName, $continueName, $cleanupName, $finishName)
    $script:FixtureReady = [Threading.EventWaitHandle]::OpenExisting($readyName)
    $script:FixtureContinue = [Threading.EventWaitHandle]::OpenExisting($continueName)
    $script:FixtureCleanup = [Threading.EventWaitHandle]::OpenExisting($cleanupName)
    $script:FixtureFinish = [Threading.EventWaitHandle]::OpenExisting($finishName)
    $script:FixtureSetEnabled = (Get-Command Set-NeuralGameEnabled).ScriptBlock
    function script:Get-NeuralGameBinding { param($Name) [pscustomobject]@{CanLaunch=$true;Message='Fixture observation'} }
    function script:Get-NeuralGamePinning {param($Name) [pscustomobject]@{Available=$true;Supported=$true;Message='Fixture selector'} }
    function script:Start-NeuralPinnedProcess {param($Manifest) Start-Process -FilePath $Manifest.Executable -WorkingDirectory $Manifest.GameDirectory -WindowStyle Normal -PassThru}
    function script:Consume-NeuralGameBinding { param($Name) }
    function script:Save-NeuralSessionRecord { param($Name,$Process,$StartedUtc,$PreviousPrefixHash) }
    function script:Set-NeuralGameEnabled {
        param([string]$Name, [bool]$Enabled)
        if (-not $Enabled) {
            $script:FixtureCleanup.Set() | Out-Null
            if (-not $script:FixtureFinish.WaitOne(30000)) { throw 'Fixture cleanup timeout' }
        }
        & $script:FixtureSetEnabled -Name $Name -Enabled $Enabled
    }
    function script:Get-NeuralGpus {
        [pscustomobject]@{ Index = 0; Uuid = 'GPU-display'; Name = 'NVIDIA GeForce RTX 3090'; DisplayActive = $true; DisplayMode = $null; PciBusId = '00000000:01:00.0' }
        [pscustomobject]@{ Index = 1; Uuid = 'GPU-headless'; Name = 'NVIDIA GeForce RTX 3090'; DisplayActive = $false; DisplayMode = $null; PciBusId = '00000000:02:00.0' }
    }
    function script:Start-Process {
        param($FilePath, $WorkingDirectory, $WindowStyle, [switch]$PassThru)
        $process = New-Object PSObject
        $process | Add-Member ScriptMethod WaitForExit {
            $script:FixtureReady.Set() | Out-Null
            if (-not $script:FixtureContinue.WaitOne(30000)) { throw 'Fixture wait timeout' }
        }
        return $process
    }
} '__READY__' '__CONTINUE__' '__CLEANUP__' '__FINISH__'
Start-NeuralGame -Name Fixture
'@
    $sessionScript = $sessionScript.Replace('__READY__', $readyName).Replace('__CONTINUE__', $continueName).Replace('__CLEANUP__', $cleanupName).Replace('__FINISH__', $finishName)
    $session = Start-FixturePowerShell $sessionScript
    try {
        Assert-True ($ready.WaitOne(30000)) 'Separate PowerShell session reaches its waiting boundary'
        Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Enabled') 'Status stays readable while session owns the operation lease'
        Assert-True (Test-NeuralGameSetup -Name Fixture).Ready 'Preflight stays readable while session owns the operation lease'
        Assert-Throws { Start-NeuralGame -Name Fixture } 'active operation|active.*session'
        Assert-Throws { Stop-NeuralGame -Name Fixture } 'active operation|active.*session'
        Assert-Throws { Uninstall-NeuralGame -Name Fixture } 'active operation|active.*session'
        Assert-Throws { Install-NeuralGame -Name Fixture -Executable $exe -PackagePath $package -ReShadeDll $reshade } 'active operation|active.*session'
        $canonicalAlias = Join-Path $gameDir '..\Fixture\Fixture.exe'
        Assert-Throws { Install-NeuralGame -Name Alias -Executable $canonicalAlias.ToUpperInvariant() -PackagePath $package -ReShadeDll $reshade } 'active operation|active.*session'
        Assert-True (-not (Test-Path (Join-Path $testRoot 'runtime\games\Alias.json'))) 'Alternate names cannot patch a leased executable'
        $independentExe = New-GameFixture 'Independent'
        Install-NeuralGame -Name Independent -Executable $independentExe -PackagePath $package -ReShadeDll $reshade | Out-Null
        Uninstall-NeuralGame -Name Independent | Out-Null
        $continue.Set() | Out-Null
        Assert-True ($cleanup.WaitOne(30000)) 'Managed session reaches its cleanup boundary'
        Assert-Throws { Stop-NeuralGame -Name Fixture } 'active operation|active.*session'
        Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Enabled') 'Cleanup owns the lease before disabling files'
        $finish.Set() | Out-Null
        Wait-FixturePowerShell $session
        Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Disabled') 'Successful session restores disabled files before releasing its lease'
        Stop-NeuralGame -Name Fixture | Out-Null

        # An abruptly exited owner cannot leave a persistent/stale lease behind.
        $ready.Reset() | Out-Null
        $abandonScript = $childPrelude + @'
$module = Get-Module NeuralGaming
& $module {
    param($readyName)
    $manifest = Get-NeuralManifest Fixture
    $lease = Enter-NeuralGameOperation $manifest.Executable
    $ready = [Threading.EventWaitHandle]::OpenExisting($readyName)
    $ready.Set() | Out-Null
    [Threading.Thread]::Sleep(30000)
} '__READY__'
'@
        $abandonOwner = Start-FixturePowerShell ($abandonScript.Replace('__READY__', $readyName))
        try {
            Assert-True ($ready.WaitOne(30000)) 'Abandonment fixture owns the real named mutex'
            Assert-Throws { Stop-NeuralGame -Name Fixture } 'active operation|active.*session'
            $abandonOwner.Kill(); $abandonOwner.WaitForExit()
            Stop-NeuralGame -Name Fixture | Out-Null
            Assert-True ((Get-NeuralGameStatus -Name Fixture).State -eq 'Disabled') 'A terminated owner does not leave a stale operation lease'
        } finally {
            if (-not $abandonOwner.HasExited) { $abandonOwner.Kill(); $abandonOwner.WaitForExit() }
            $abandonOwner.Dispose()
        }
    } finally {
        $continue.Set() | Out-Null
        $finish.Set() | Out-Null
        if (-not $session.WaitForExit(5000)) { $session.Kill(); $session.WaitForExit() }
        $session.Dispose()
        $ready.Dispose(); $continue.Dispose(); $cleanup.Dispose(); $finish.Dispose()
    }
    Write-Output 'PASS: canonical per-game leases reject concurrent mutations through wait and cleanup, with readable status/preflight'
    & $module { param($definition) Remove-Item Function:Start-Process; Set-Item Function:Get-NeuralGpus $definition } $gpuDefinition
    Write-Output 'PASS: GPU roles guard launch and launch failure restores disabled files'

    $manifestPath = Join-Path $testRoot 'runtime\games\Fixture.json'
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $original = Get-Content $manifestPath -Raw
    $manifest.Files[0].RelativePath = '..\outside.dll'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
    Assert-Throws { Uninstall-NeuralGame -Name Fixture } 'outside|contain|relative'
    Set-Content $manifestPath $original
    Assert-True (Test-Path (Join-Path $gameDir 'dxgi.dll.neural-disabled')) 'Manifest traversal deletes no game files'
    Write-Output 'PASS: manifest paths cannot escape game directory'

    $ownedIni = Join-Path $gameDir 'mgpu.ini'
    $originalIni = [IO.File]::ReadAllBytes($ownedIni)
    Add-Content $ownedIni '; user edit'
    Assert-Throws { Uninstall-NeuralGame -Name Fixture } 'modified|changed'
    Assert-True (Test-Path (Join-Path $gameDir 'dxgi.dll.neural-disabled')) 'Modified-file refusal preserves all owned files'
    [IO.File]::WriteAllBytes($ownedIni, $originalIni)
    $userFile = Join-Path $gameDir 'reshade-shaders\Shaders\user.fx'
    Set-Content $userFile 'user shader'
    Uninstall-NeuralGame -Name Fixture | Out-Null
    Assert-True (Test-Path $userFile) 'Uninstall preserves unowned user files'
    Assert-True (Test-Path $neural) 'Uninstall preserves a manually supplied unowned model'
    Assert-True (-not (Test-Path (Join-Path $gameDir 'dxgi.dll.neural-disabled'))) 'Uninstall removes unchanged owned DLL'
    Assert-True (-not (Test-Path $manifestPath)) 'Uninstall removes game manifest'
    Write-Output 'PASS: uninstall guards modified files and preserves unowned files'
    Write-Output 'All NeuralGaming fixture tests passed.'
} finally {
    Remove-Module NeuralGaming -ErrorAction SilentlyContinue
    $env:NEURAL_GAMING_ROOT = $previousRoot
    $env:PATH = $previousPath
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $fixturePrefix = $testBase.TrimEnd('\') + '\'
    if ($resolved.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'NeuralGaming-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
