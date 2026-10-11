[CmdletBinding()]
param([switch]$FixturesOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Initialize-NeuralPowerShell.ps1')
. (Join-Path $PSScriptRoot 'NeuralProvisioning.ps1')
$compiler=Join-Path $root 'runtime\toolchains\llvm-mingw-20261006-ucrt-x86_64\bin\x86_64-w64-mingw32-clang++.exe'
$archiver=Join-Path (Split-Path $compiler -Parent) 'llvm-ar.exe'
$detours=Join-Path $root 'runtime\toolchains\Detours-1dbd4ea281d73d478aa8d09a8b83fbd265f715f7\microsoft-Detours-1dbd4ea\src'
$build=Join-Path $root 'runtime\pinning\build'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The pinned LLVM MinGW compiler has not been provisioned. This script never downloads or installs dependencies.' }
# Verify complete archive provenance, including toolchain DLLs, headers, libraries
# and all Detours sources, before the compiler or archiver can execute.
foreach($asset in @(Get-NeuralToolchainAssets)){
    $base=Join-Path $root 'runtime\toolchains'
    $destination=if($asset.Container){Join-Path $base $asset.Container}else{$base}
    Assert-NeuralExtractedArchive -ArchivePath (Join-Path $base $asset.Name) -Hash $asset.Hash -Destination $destination -Prefix ($asset.Folder+'/')
}
Assert-NeuralProvisionPath $compiler
Assert-NeuralProvisionPath $archiver
Assert-NeuralProvisionTree $build
$buildOutputs=@('sl.interposer.dll','libPinFixtureInterposer.a','PinFixtureBridge.dll','libPinFixtureBridge.a','PinFixtureMain.exe','PinFixtureNoImport.exe','libdetours.a','NeuralGpuPin.dll','NeuralPinnedLaunch.exe','PinFixtureInject.exe','manifest.json')
$buildOutputs+=@('detours.cpp','modules.cpp','disasm.cpp','image.cpp','creatwth.cpp','disolx86.cpp','disolx64.cpp'|ForEach-Object {$_+'.o'})
foreach($name in $buildOutputs){Assert-NeuralProvisionPath (Join-Path $build $name)}
[IO.Directory]::CreateDirectory($build) | Out-Null
$common=@('-std=c++17','-O2','-static','-DUNICODE','-D_UNICODE','-D_WIN32_WINNT=0x0601')
function Invoke-Compile([string[]]$CompilerArguments) {
    Assert-NeuralProvisionTree $build
    & $compiler @CompilerArguments
    if ($LASTEXITCODE -ne 0) { throw ('Native compile failed with exit '+$LASTEXITCODE) }
}
$fixtureSource=Join-Path $root 'tests\native'
$sl=Join-Path $build 'sl.interposer.dll'
$slImport=Join-Path $build 'libPinFixtureInterposer.a'
Invoke-Compile ($common+@('-shared',(Join-Path $fixtureSource 'PinFixtureInterposer.cpp'),(Join-Path $fixtureSource 'PinFixtureInterposer.def'),'-ldxguid','-lole32',('-Wl,--out-implib,'+$slImport),'-o',$sl))
$bridge=Join-Path $build 'PinFixtureBridge.dll'
$bridgeImport=Join-Path $build 'libPinFixtureBridge.a'
Invoke-Compile ($common+@('-shared',(Join-Path $fixtureSource 'PinFixtureBridge.cpp'),(Join-Path $fixtureSource 'PinFixtureBridge.def'),$slImport,'-ldxguid','-lole32',('-Wl,--out-implib,'+$bridgeImport),'-o',$bridge))
Invoke-Compile ($common+@('-municode',(Join-Path $fixtureSource 'PinFixtureMain.cpp'),$slImport,$bridgeImport,'-ldxgi','-ldxguid','-lole32','-o',(Join-Path $build 'PinFixtureMain.exe')))
Invoke-Compile ($common+@('-municode','-DPIN_FIXTURE_NO_IMPORT',(Join-Path $fixtureSource 'PinFixtureMain.cpp'),'-ldxgi','-ldxguid','-lole32','-o',(Join-Path $build 'PinFixtureNoImport.exe')))
if ($FixturesOnly) { Write-Output ('CPU fixtures built: '+$build); return }
if (-not (Test-Path -LiteralPath (Join-Path $detours 'detours.h') -PathType Leaf)) { throw 'The pinned Microsoft Detours source has not been provisioned.' }
$objectFiles=@()
$detoursSources=@('detours.cpp','modules.cpp','disasm.cpp','image.cpp','creatwth.cpp','disolx86.cpp','disolx64.cpp')
foreach ($name in $detoursSources) {
    $source=Join-Path $detours $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Missing pinned Detours source: '+$name) }
    $object=Join-Path $build ($name+'.o')
    # Upstream's IA64-only alignment placement and identical numeric Windows
    # error macro produce Clang diagnostics; no Detours source is changed.
    Invoke-Compile ($common+@('-Wno-macro-redefined','-Wno-ignored-attributes','-I',$detours,'-c',$source,'-o',$object))
    $objectFiles+=$object
}
$library=Join-Path $build 'libdetours.a'
if (Test-Path -LiteralPath $library) { Remove-Item -LiteralPath $library }
Assert-NeuralProvisionTree $build
& $archiver rcs $library @objectFiles
if ($LASTEXITCODE -ne 0) { throw 'Detours static archive failed' }
$pinSource=Join-Path $root 'native\NeuralGpuPin.cpp'
$pinDef=Join-Path $root 'native\NeuralGpuPin.def'
$launchSource=Join-Path $root 'native\NeuralPinnedLaunch.cpp'
$pinDll=Join-Path $build 'NeuralGpuPin.dll'
$launcher=Join-Path $build 'NeuralPinnedLaunch.exe'
Invoke-Compile ($common+@('-Wall','-Wextra','-Werror','-I',$detours,'-shared',$pinSource,$pinDef,$library,'-ldxguid','-lole32','-o',$pinDll))
Invoke-Compile ($common+@('-Wall','-Wextra','-Werror','-I',$detours,'-municode',$launchSource,$library,'-o',$launcher))
Invoke-Compile ($common+@('-I',$detours,'-municode',(Join-Path $fixtureSource 'PinFixtureInject.cpp'),$library,'-o',(Join-Path $build 'PinFixtureInject.exe')))
$sourcePaths=@($pinSource,$pinDef,$launchSource,$PSCommandPath,(Join-Path $root 'scripts\NeuralProvisioning.ps1'),(Join-Path $root 'native\NeuralPinnedStartup.cs'),(Join-Path $root 'native\NeuralPinImports.cs'))+@(Get-ChildItem -LiteralPath $fixtureSource -File | Where-Object Name -Like 'PinFixture*' | Select-Object -ExpandProperty FullName)
foreach ($name in $detoursSources) { $sourcePaths+=Join-Path $detours $name }
$sourcePaths+=Join-Path $detours 'detours.h'
function Get-ManifestFiles([string[]]$Paths) {
    foreach ($path in $Paths) {
        [pscustomobject]@{RelativePath=$path.Substring($root.Length+1).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Length=(Get-Item -LiteralPath $path).Length}
    }
}
$manifest=[ordered]@{
    Version=1
    Experimental=$true
    BuiltUtc=[DateTime]::UtcNow.ToString('o')
    ToolchainVersion='llvm-mingw-20261006-ucrt-x86_64'
    Compiler=[ordered]@{RelativePath=$compiler.Substring($root.Length+1).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash}
    DetoursCommit='1dbd4ea281d73d478aa8d09a8b83fbd265f715f7'
    Files=@(Get-ManifestFiles ($sourcePaths+@($pinDll,$launcher,$library,(Join-Path $build 'PinFixtureMain.exe'),(Join-Path $build 'PinFixtureNoImport.exe'),(Join-Path $build 'PinFixtureInject.exe'),$sl,$bridge)))
}
$manifestPath=Join-Path $build 'manifest.json'
Assert-NeuralProvisionPath $manifestPath
[IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Output ('Experimental native pinning artifacts built: '+$build)
