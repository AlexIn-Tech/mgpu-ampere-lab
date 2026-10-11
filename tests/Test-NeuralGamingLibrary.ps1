$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$modulePath=Join-Path $repo 'powershell\NeuralGaming.Library.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw 'FAIL: game library and actions are not implemented.' }
$fixture=Join-Path $repo ('runtime\library-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$oldRoot=$env:NEURAL_GAMING_ROOT
$env:NEURAL_GAMING_ROOT=$fixture
try {
    Import-Module $modulePath -Force
    $game=Join-Path $fixture 'FixtureGame.exe'
    $bytes=New-Object byte[] 256
    $bytes[0]=77; $bytes[1]=90; $bytes[60]=128
    $bytes[128]=80; $bytes[129]=69; $bytes[132]=100; $bytes[133]=134
    [IO.File]::WriteAllBytes($game,$bytes)
    $registered=Register-NeuralLibraryGame -Title 'Fixture ultrawide game' -Executable $game
    $row=@(Get-NeuralLibraryGames | Where-Object Id -eq $registered.Id)
    if ($row.Count -ne 1 -or $row[0].Title -ne 'Fixture ultrawide game' -or $row[0].IsManaged) { throw 'Manual game registration/projection failed.' }
    Register-NeuralLibraryGame -Title 'Renamed fixture' -Executable $game | Out-Null
    if (@(Get-NeuralLibraryGames | Where-Object Executable -eq $game).Count -ne 1) { throw 'Executable aliases must deduplicate.' }
    Write-Output 'PASS: manual registration and canonical executable projection'
    $display=Get-NeuralLibraryDisplay
    if ($display.Width -ne 3440 -or $display.Height -ne 1440 -or $display.RefreshHz -ne 100) { throw 'Ultrawide defaults are wrong.' }
    Write-Output 'PASS: 3440x1440 100Hz display profile defaults'
    $rejected=$false
    try { Invoke-NeuralLibraryAction -Action Patch -GameId $registered.Id } catch { $rejected=$_.Exception.Message -match 'acknowledge|unverified|consent|confirm' }
    if (-not $rejected) { throw 'New unverified games require explicit acknowledgment before patching.' }
    Write-Output 'PASS: unverified patch stops before writing files'
    $bad=Join-Path $fixture 'BadGame.exe'; [IO.File]::WriteAllText($bad,'not PE')
    $rejected=$false
    try { Register-NeuralLibraryGame -Title 'Bad' -Executable $bad } catch { $rejected=$true }
    if (-not $rejected) { throw 'Registration must reject non-PE game files.' }
    Write-Output 'PASS: invalid executable rejection'
    $rejected=$false
    try { Register-NeuralLibraryGame -Title 'System binary' -Executable (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') } catch { $rejected=$true }
    if (-not $rejected) { throw 'Manual registration must reject Windows system binaries.' }
    Write-Output 'PASS: Windows system executable rejection'
    $module=Get-Module NeuralGaming.Library
    & $module {
        function script:Get-NeuralLibraryGpus {
            [pscustomobject]@{Uuid='GPU-fixture-render';Name='RTX fixture';DisplayActive=$false;Index=1;PciBusId='49:00.0'}
            [pscustomobject]@{Uuid='GPU-fixture-neural';Name='RTX fixture';DisplayActive=$true;Index=0;PciBusId='21:00.0'}
        }
    }
    Set-NeuralLibrarySettings -RenderGpuUuid GPU-fixture-render -NeuralGpuUuid GPU-fixture-neural -Width 3440 -Height 1440 -RefreshHz 100 | Out-Null
    $config=Get-Content -LiteralPath (Join-Path $fixture 'runtime\config.json') -Raw | ConvertFrom-Json
    if ($config.renderUuid -ne 'GPU-fixture-render' -or $config.display.Width -ne 3440) { throw 'Settings must save exact roles and display metadata.' }
    $rejected=$false
    try { Set-NeuralLibrarySettings -RenderGpuUuid GPU-fixture-neural -NeuralGpuUuid GPU-fixture-neural -Width 3440 -Height 1440 -RefreshHz 100 } catch { $rejected=$true }
    if (-not $rejected) { throw 'Identical saved GPU roles must be rejected.' }
    Write-Output 'PASS: validated settings persist locally'
    $package=Join-Path $fixture 'runtime\packages\bridge-0.3.1'
    New-Item -ItemType Directory -Path (Join-Path $package 'reshade-shaders\Shaders'),(Join-Path $fixture 'runtime\packages\reshade-6.8.0'),(Join-Path $fixture 'runtime\packages\dlssnr-310.8.SF-v2') -Force | Out-Null
    foreach ($name in @('nvngx.dll_mgpu_bridge.addon64','gpu1.ini','ReShade2.ini','reshade-shaders\Shaders\mgpu_depth_tap.fx')) { Set-Content -LiteralPath (Join-Path $package $name) -Value 'fixture' }
    Set-Content -LiteralPath (Join-Path $package 'mgpu.ini') -Value "[MGPU]`nAutoArm=1`nPasses=2`nDcompOverlay=0"
    Set-Content -LiteralPath (Join-Path $fixture 'runtime\packages\reshade-6.8.0\ReShade64.dll') -Value 'fixture'
    Set-Content -LiteralPath (Join-Path $fixture 'runtime\packages\dlssnr-310.8.SF-v2\nvngx_dlssnr.dll') -Value 'fixture'
    Invoke-NeuralLibraryAction -Action Patch -GameId $registered.Id -AllowUnverified | Out-Null
    $row=Get-NeuralLibraryGames | Where-Object Id -eq $registered.Id
    if (-not $row.IsManaged -or -not $row.RiskAccepted -or $row.State -ne 'Disabled') { throw 'Patch must remain inactive and persist the acknowledgment.' }
    Invoke-NeuralLibraryAction -Action Unpatch -GameId $registered.Id | Out-Null
    if ((Get-NeuralLibraryGames | Where-Object Id -eq $registered.Id).IsManaged) { throw 'Unpatch must restore an unpatched library entry.' }
    Write-Output 'PASS: patch/unpatch use real file manager and retain manual game'
    Invoke-NeuralLibraryAction -Action Patch -GameId $registered.Id | Out-Null
    # A game removed by its launcher must still be removable from this manager.
    Move-Item -LiteralPath $game -Destination ($game+'.fixture-backup')
    $row=Get-NeuralLibraryGames | Where-Object Id -eq $registered.Id
    if (-not $row.IsManaged) { throw 'Missing executable must not hide a managed installation.' }
    Invoke-NeuralLibraryAction -Action Unpatch -GameId $registered.Id | Out-Null
    Move-Item -LiteralPath ($game+'.fixture-backup') -Destination $game
    Write-Output 'PASS: removed game remains visible for unpatching'
    & $module { param($Game,$Package,$Fixture) Install-NeuralGame -Name LegacyFixture -Executable $Game -PackagePath $Package -ReShadeDll (Join-Path $Fixture 'runtime\packages\reshade-6.8.0\ReShade64.dll') -NeuralDll (Join-Path $Fixture 'runtime\packages\dlssnr-310.8.SF-v2\nvngx_dlssnr.dll') } $game $package $fixture | Out-Null
    Invoke-NeuralLibraryAction -Action Unpatch -GameId $registered.Id | Out-Null
    Invoke-NeuralLibraryAction -Action Patch -GameId $registered.Id | Out-Null
    if ((Get-NeuralLibraryGames | Where-Object Id -eq $registered.Id).ManagedName -ne 'LegacyFixture') { throw 'GUI repatching must preserve the established CLI game name.' }
    Invoke-NeuralLibraryAction -Action Unpatch -GameId $registered.Id | Out-Null
    Write-Output 'PASS: repatching preserves established CLI names'
    Set-Content -LiteralPath (Join-Path $fixture 'runtime\games\Corrupt.json') -Value '{broken'
    $rows=@(Get-NeuralLibraryGames -WarningVariable manifestWarnings -WarningAction SilentlyContinue)
    if (-not @($rows | Where-Object Id -eq $registered.Id).Count -or -not $manifestWarnings) { throw 'One malformed manifest must warn without hiding healthy games.' }
    Write-Output 'PASS: malformed manifest is isolated with a diagnostic'
    Write-Output 'All game library fixture tests passed.'
} finally {
    Remove-Module NeuralGaming.Library,NeuralGameCatalog,NeuralGaming -ErrorAction SilentlyContinue
    $env:NEURAL_GAMING_ROOT=$oldRoot
}
