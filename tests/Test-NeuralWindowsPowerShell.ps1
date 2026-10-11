$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Get-FixtureSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $repo ('runtime\windows-powershell-test-' + [guid]::NewGuid().ToString('N'))
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pwsh = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
$coreModules = Join-Path (Split-Path $pwsh.Path -Parent) 'Modules'
Assert-True (Test-Path -LiteralPath (Join-Path $coreModules 'Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1')) 'PowerShell 7 built-in module fixture is available'
$previousModulePath = $env:PSModulePath
$previousRoot = $env:NEURAL_GAMING_ROOT

function Invoke-WindowsPowerShellFixture([string]$Arguments, [string]$Label) {
    $stdout = Join-Path $fixture ($Label + '.stdout.txt')
    $stderr = Join-Path $fixture ($Label + '.stderr.txt')
    $process = $null
    try {
        # Native invocation with & sanitizes PSModulePath. Start-Process matches the GUI launch.
        $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $Arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw "FAIL: $Label fixture exceeded 30 seconds." }
        $process.WaitForExit()
        $process.Refresh()
        return [pscustomobject]@{ExitCode=$process.ExitCode;Stdout=[IO.File]::ReadAllText($stdout);Stderr=[IO.File]::ReadAllText($stderr)}
    } finally { if ($process) { $process.Dispose() } }
}

try {
    foreach ($folder in @('powershell','scripts','fixture-game\mgpu','runtime\games','runtime\gui\operations','user-modules\NeuralFixtureUserPath')) {
        [IO.Directory]::CreateDirectory((Join-Path $fixture $folder)) | Out-Null
    }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repo 'powershell') -File)) {
        [IO.File]::Copy($file.FullName,(Join-Path $fixture ('powershell\' + $file.Name)))
    }
    # Include startup helpers without binding the fixture to their implementation.
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repo 'scripts') -Filter '*.ps1' -File)) {
        [IO.File]::Copy($file.FullName,(Join-Path $fixture ('scripts\' + $file.Name)))
    }
    $userModules = Join-Path $fixture 'user-modules'
    [IO.File]::WriteAllText((Join-Path $userModules 'NeuralFixtureUserPath\NeuralFixtureUserPath.psm1'),"function Get-NeuralFixtureUserPath { 'Preserved fixture user module path.' }; Export-ModuleMember -Function Get-NeuralFixtureUserPath")

    $gameDirectory = Join-Path $fixture 'fixture-game'
    $game = Join-Path $gameDirectory ('NeuralHashFixture_' + [guid]::NewGuid().ToString('N') + '.exe')
    [IO.File]::WriteAllText($game, 'Invalid executable fixture; never run.')
    $files = @()
    foreach ($entry in @(
        @('dxgi.dll', 'dxgi.dll.neural-disabled', 'fixture reshade'),
        @('nvngx.dll_mgpu_bridge.addon64', 'nvngx.dll_mgpu_bridge.addon64.neural-disabled', 'fixture bridge'),
        @('mgpu\nvngx_dlssnr.dll', $null, 'fixture neural'),
        @('mgpu.ini', $null, "[MGPU]`nAutoArm=0`nPasses=1`nDcompOverlay=1")
    )) {
        $relative = if ($entry[1]) { $entry[1] } else { $entry[0] }
        $path = Join-Path $gameDirectory $relative
        [IO.File]::WriteAllText($path, $entry[2])
        $files += [pscustomobject]@{RelativePath=$entry[0];DisabledRelativePath=$entry[1];Sha256=(Get-FixtureSha256 $path)}
    }
    $manifest = [pscustomobject]@{Version=1;Name='HashFixture';Executable=$game;GameDirectory=$gameDirectory;InstalledAt='2026-01-01T00:00:00Z';Files=$files;CreatedDirectories=@('mgpu')}
    [IO.File]::WriteAllText((Join-Path $fixture 'runtime\games\HashFixture.json'),($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture 'runtime\config.json'),'{"renderUuid":"GPU-fixture-render","neuralUuid":"GPU-fixture-neural"}')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $gameId = 'game_' + [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($game).ToLowerInvariant()))).Replace('-', '').ToLowerInvariant().Substring(0,32) }
    finally { $sha.Dispose() }
    $requestPath = Join-Path $fixture 'runtime\gui\operations\fixture.request.json'
    $resultPath = Join-Path $fixture 'runtime\gui\operations\fixture.result.json'
    [IO.File]::WriteAllText($requestPath,(@{Root=$fixture;Action='Launch';GameId=$gameId;AllowUnverified=$true} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))

    # Keep real discovery, preflight, integrity checks, activation and cleanup. Replace only
    # physical GPU enumeration and the native launch boundary, which must never run an exe.
    $boundaries = @'

function script:Get-NeuralGpus {
    [pscustomobject]@{Index=0;Uuid='GPU-fixture-render';Name='RTX fixture';DisplayActive=$false;PciBusId='49:00.0'}
    [pscustomobject]@{Index=1;Uuid='GPU-fixture-neural';Name='RTX fixture';DisplayActive=$true;PciBusId='21:00.0'}
}
function script:Get-NeuralGameBinding { param($Name) [pscustomobject]@{Status='Observed';CanLaunch=$true;Message='Fixture observation'} }
function script:Get-NeuralGamePinning {param($Name) [pscustomobject]@{Available=$true;Supported=$true;Message='Fixture selector'} }
function script:Start-NeuralPinnedProcess {param($Manifest) Start-Process -FilePath $Manifest.Executable -WorkingDirectory $Manifest.GameDirectory -WindowStyle Normal -PassThru}
function script:Consume-NeuralGameBinding { param($Name) }
function script:Save-NeuralSessionRecord { param($Name,$Process,$StartedUtc,$PreviousPrefixHash) }
function script:Start-Process {
    param([string]$FilePath,[string]$WorkingDirectory,[string]$WindowStyle,[switch]$PassThru)
    $expectedDirectory = [IO.Path]::Combine($script:NeuralRoot, 'fixture-game')
    if ($WorkingDirectory -ne $expectedDirectory -or [IO.Path]::GetDirectoryName($FilePath) -ne $expectedDirectory -or [IO.Path]::GetFileName($FilePath) -notlike 'NeuralHashFixture_*.exe') { throw 'Fixture launch target escaped the isolated game directory.' }
    foreach ($relative in @('dxgi.dll','nvngx.dll_mgpu_bridge.addon64')) {
        $active = [IO.Path]::Combine($expectedDirectory, $relative)
        if (-not [IO.File]::Exists($active) -or [IO.File]::Exists($active + '.neural-disabled')) { throw 'Fixture launch was reached before injector activation.' }
    }
    Import-Module NeuralFixtureUserPath -Scope Local -ErrorAction Stop
    if ((Get-NeuralFixtureUserPath) -ne 'Preserved fixture user module path.') { throw 'Inherited fixture user module path was lost.' }
    [IO.File]::WriteAllText([IO.Path]::Combine($script:NeuralRoot, 'runtime\launch-boundary.txt'), 'Injector enabled before native launch.')
    throw 'FIXTURE launch boundary: no executable was started.'
}
'@
    [IO.File]::AppendAllText((Join-Path $fixture 'powershell\NeuralGaming.psm1'),$boundaries,[Text.UTF8Encoding]::new($false))

    # Deliberately reproduce a Core-first environment even when this test itself uses PS 5.1.
    $env:PSModulePath = $coreModules + [IO.Path]::PathSeparator + $userModules + [IO.Path]::PathSeparator + $previousModulePath
    $env:NEURAL_GAMING_ROOT = $repo
    $guiPath = Join-Path $repo 'gui\Show-NeuralGaming.ps1'
    $gui = Invoke-WindowsPowerShellFixture ('-NoProfile -Sta -ExecutionPolicy Bypass -File "{0}" -SmokeTest' -f $guiPath) 'gui'
    Assert-True ($gui.ExitCode -eq 0 -and $gui.Stdout -match 'PASS: WPF library loaded, rendered and closed') ('GUI loads through Start-Process with inherited Core module paths: ' + $gui.Stderr)
    Write-Output 'PASS: Windows PowerShell GUI smoke test with inherited PowerShell 7 module paths'

    $workerPath = Join-Path $fixture 'scripts\Invoke-NeuralGameAction.ps1'
    $worker = Invoke-WindowsPowerShellFixture ('-NoProfile -Sta -ExecutionPolicy Bypass -File "{0}" -RequestPath "{1}" -ResultPath "{2}"' -f $workerPath,$requestPath,$resultPath) 'worker'
    Assert-True ([IO.File]::Exists($resultPath)) ('Worker persists a readable result: ' + $worker.Stderr)
    $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
    Assert-True ($worker.ExitCode -eq 1 -and -not $result.Success -and $result.Message -eq 'FIXTURE launch boundary: no executable was started.') ('Worker hashes owned DLLs before the safe launch boundary; observed: ' + $result.Message + '. Fixture: ' + $fixture)
    Assert-True ([IO.File]::Exists((Join-Path $fixture 'runtime\launch-boundary.txt'))) 'Worker enabled injector files before the trapped native launch'
    foreach ($file in $files) {
        $relative = if ($file.DisabledRelativePath) { $file.DisabledRelativePath } else { $file.RelativePath }
        $path = Join-Path $gameDirectory $relative
        Assert-True ([IO.File]::Exists($path) -and (Get-FixtureSha256 $path) -eq $file.Sha256) ('Worker cleanup preserves fixture bytes: ' + $relative)
        if ($file.DisabledRelativePath) { Assert-True (-not [IO.File]::Exists((Join-Path $gameDirectory $file.RelativePath))) ('Worker restores Disabled state: ' + $file.RelativePath) }
    }
    Write-Output 'PASS: Windows PowerShell worker preserves user module paths, hashes, activates and restores Disabled fixture files without starting an executable'
    Write-Output ('All Windows PowerShell module-path regression tests passed using caller ' + $PSVersionTable.PSVersion)
} finally {
    $env:PSModulePath = $previousModulePath
    $env:NEURAL_GAMING_ROOT = $previousRoot
}
