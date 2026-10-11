param([string]$ModulePath = (Join-Path $PSScriptRoot '..\powershell\NeuralGameCatalog.psm1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }

Assert-True (Test-Path -LiteralPath $ModulePath -PathType Leaf) 'Game catalog module exists'
$testBase = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\runtime'))
$testRoot = Join-Path $testBase ('NeuralCatalog-test-' + [guid]::NewGuid().ToString('N'))
$previousRoot = $env:NEURAL_GAMING_ROOT
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:NEURAL_GAMING_ROOT = $testRoot
    function global:Start-Process { throw 'Catalog started a process' }
    function global:Get-Process { throw 'Catalog queried processes' }
    $module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'runtime'))) 'Import writes no runtime files'
    Assert-True (@($module.ExportedCommands.Keys).Count -eq 1 -and $module.ExportedCommands.ContainsKey('Get-NeuralDetectedGames')) 'Only discovery is exported'
    Write-Output 'PASS: catalog import is inert'

    function New-ExecutableFixture([string]$RelativePath) {
        $path = Join-Path $testRoot $RelativePath
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $path -Value 'fixture; never execute' -NoNewline
        return (Get-Item -LiteralPath $path).FullName
    }
    function New-Application([string]$Title, [string[]]$Images, [string]$DriverProfile, [bool]$Creative = $false) {
        # Matches NVIDIA App NvBackend/ApplicationStorage.json, including nested Application and arrays.
        return [pscustomobject]@{ LocalId = 123; Application = [pscustomobject]@{
            DisplayName = $Title; InstallDirectory = (Split-Path $Images[0] -Parent)
            ImageFiles = @($Images); DetectedFiles = @($Images); DriverProfile = $DriverProfile
            IsCreativeApplication = $Creative; LaunchCmd = 'start steam://rungameid/000000'
            Disable_SR_Override = $false; IsMultiGPUInferenceAllowed = $false
        } }
    }
    function Write-Catalog([string]$Root, [object[]]$Applications) {
        $backend = Join-Path $Root 'NvBackend'
        New-Item -ItemType Directory -Path $backend -Force | Out-Null
        $path = Join-Path $backend 'ApplicationStorage.json'
        [pscustomobject]@{ Applications = @($Applications) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }
    $primary = New-ExecutableFixture 'Games with spaces\Example\Game.exe'
    $launcher = New-ExecutableFixture 'Games with spaces\Example\Launcher.exe'
    $installer = New-ExecutableFixture 'Games with spaces\Example\__Installer\Cleanup.exe'
    $creative = New-ExecutableFixture 'Creative\Editor.exe'
    $client = New-ExecutableFixture 'Client\steam.exe'
    $overlay = New-ExecutableFixture 'Client\GameOverlayUI.exe'
    $stub = New-ExecutableFixture 'Games with spaces\Unreal\Expedition33_Steam.exe'
    $shipping = New-ExecutableFixture 'Games with spaces\Unreal\Sandfall\Binaries\Win64\SandFall-Win64-Shipping.exe'
    $stale = Join-Path $testRoot 'Missing\RemovedGame.exe'
    $cache = Join-Path $testRoot 'cache'
    $clientApplication = New-Application 'Steam' @($client) $client
    $clientApplication.Application.DetectedFiles = @($client, $overlay)
    $cacheFile = Write-Catalog $cache @(
        (New-Application "Jeu: L'été / Example" @($primary, $launcher, $installer) $primary),
        (New-Application 'Duplicate title' @($primary.ToUpperInvariant()) $primary.ToUpperInvariant()),
        (New-Application 'Clair Obscur Expedition 33' @($stub, $shipping) $shipping),
        (New-Application 'Stale entry' @($stale) $stale),
        (New-Application 'Adobe Editor' @($creative) $creative $true),
        $clientApplication,
        (New-Application 'Installer only' @($installer) $installer),
        [pscustomobject]@{ LocalId = 987; Application = $null },
        [pscustomobject]@{ Application = [pscustomobject]@{ DisplayName = 'Relative path'; ImageFiles = @('Game.exe') } },
        [pscustomobject]@{ Application = [pscustomobject]@{ DisplayName = 'Invalid path'; ImageFiles = @('C:\bad' + [char]0 + '.exe') } }
    )
    $cacheHash = (Get-FileHash -LiteralPath $cacheFile).Hash
    $primaryHash = (Get-FileHash -LiteralPath $primary).Hash
    $games = @(Get-NeuralDetectedGames -CacheRoot $cache -ManagedRoot $testRoot)
    Assert-True ($games.Count -eq 2) 'Real schema excludes missing executables, clients, creative apps, installers and malformed entries; duplicates collapse'
    $example = @($games | Where-Object Executable -eq $primary)[0]
    Assert-True ($example.Title -eq "Jeu: L'été / Example") 'NVIDIA title is preserved verbatim'
    Assert-True ($example.Source -eq 'NVIDIA App' -and $example.DiscoveryPath -eq $cacheFile) 'Source identifies the actual cache file'
    Assert-True ($example.Id -match '^game_[a-f0-9]{32}$') 'ID is a safe ASCII manager name based on executable path'
    Assert-True ($null -eq $example.ManagedName -and -not $example.IsManaged) 'Unmanaged game is identified without importing manager'
    Assert-True (@($games | Where-Object Executable -eq $shipping).Count -eq 1) 'Unreal shipping binary is selected instead of the root launch stub'
    Assert-True (@($example.PSObject.Properties.Name | Where-Object { $_ -match 'DLSS|Compatible|AntiCheat|Override' }).Count -eq 0) 'Detection conveys no compatibility or NVIDIA override claims'
    Assert-True ((Get-FileHash -LiteralPath $cacheFile).Hash -eq $cacheHash -and (Get-FileHash -LiteralPath $primary).Hash -eq $primaryHash) 'Discovery preserves cache and game files'
    Write-Output 'PASS: actual NVIDIA schema, safe executable selection and read-only discovery'

    $secondCache = Join-Path $testRoot 'second-cache'
    $secondFile = Write-Catalog $secondCache @((New-Application 'New display name' @($primary.ToUpperInvariant()) $primary))
    $duplicateGames = @(Get-NeuralDetectedGames -CacheRoot @($cacheFile, $secondFile) -ManagedRoot $testRoot)
    Assert-True ($duplicateGames.Count -eq 2) 'Canonical executable paths deduplicate across cache files'
    $changedTitle = @(Get-NeuralDetectedGames -CacheRoot $secondCache -ManagedRoot $testRoot)
    Assert-True ($changedTitle[0].Id -eq $example.Id) 'ID remains stable across title and path casing changes'
    $directBackend = @(Get-NeuralDetectedGames -CacheRoot (Join-Path $cache 'NvBackend') -ManagedRoot $testRoot)
    Assert-True ($directBackend.Count -eq 2) 'Cache override accepts NVIDIA App root, NvBackend root or direct file'
    Write-Output 'PASS: stable IDs and canonical deduplication'

    $previousLocal = $env:LOCALAPPDATA
    $previousProgramData = $env:ProgramData
    $previousProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = Join-Path $testRoot 'profile'
        $env:LOCALAPPDATA = Join-Path $testRoot 'redirected-sandbox'
        $env:ProgramData = Join-Path $testRoot 'program-data'
        $profileCache = Join-Path $env:USERPROFILE 'AppData\Local\NVIDIA Corporation\NVIDIA App'
        Write-Catalog $profileCache @((New-Application 'Profile game' @($primary) $primary)) | Out-Null
        $defaultGames = @(Get-NeuralDetectedGames -ManagedRoot $testRoot)
        Assert-True ($defaultGames.Count -eq 1 -and $defaultGames[0].Source -eq 'NVIDIA App') 'Default discovery finds profile cache when LOCALAPPDATA is sandbox redirected'
        $emptyOverride = @(Get-NeuralDetectedGames -CacheRoot (Join-Path $testRoot 'absent-cache') -ManagedRoot $testRoot -WarningVariable absentWarnings -WarningAction SilentlyContinue)
        Assert-True ($emptyOverride.Count -eq 0) 'An explicit cache override never reads the default profile cache'
        Assert-True (@($absentWarnings).Count -eq 1) 'Missing cache locations produce one warning, not one per candidate'
        Assert-True ([string]$absentWarnings[0] -match 'NVIDIA App.*scan.*Refresh.*Add game') 'Missing cache warning explains scanning, refreshing and manually adding a game'
    } finally {
        $env:LOCALAPPDATA = $previousLocal
        $env:ProgramData = $previousProgramData
        $env:USERPROFILE = $previousProfile
    }
    Write-Output 'PASS: sandbox profile discovery and explicit override isolation'

    $managedFolder = Join-Path $testRoot 'runtime\games'
    New-Item -ItemType Directory -Path $managedFolder -Force | Out-Null
    $managedFile = Join-Path $managedFolder 'ExistingGame.json'
    [pscustomobject]@{ Version = 1; Name = 'ExistingGame'; Executable = $primary; GameDirectory = (Split-Path $primary -Parent); Files = @(); CreatedDirectories = @() } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $managedFile -Encoding UTF8
    $managedHash = (Get-FileHash -LiteralPath $managedFile).Hash
    Set-Content -LiteralPath (Join-Path $managedFolder 'Malformed.json') -Value '{bad-json'
    [pscustomobject]@{ Name = '../Escape'; Executable = $primary; GameDirectory = (Split-Path $primary -Parent) } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $managedFolder 'Unsafe.json')
    $games = @(Get-NeuralDetectedGames -CacheRoot $cache -ManagedRoot $testRoot)
    $example = @($games | Where-Object Executable -eq $primary)[0]
    Assert-True ($example.IsManaged -and $example.ManagedName -eq 'ExistingGame') 'Exact executable matches the backend manifest name'
    Assert-True ($example.Source -eq 'NVIDIA App') 'Matched managed entry retains NVIDIA provenance'
    $fallback = @(Get-NeuralDetectedGames -CacheRoot (Join-Path $testRoot 'absent-cache') -ManagedRoot $testRoot -WarningVariable fallbackWarnings -WarningAction SilentlyContinue)
    Assert-True ($fallback.Count -eq 1 -and $fallback[0].Source -eq 'Managed setup' -and $fallback[0].IsManaged) 'Missing NVIDIA cache falls back to valid managed setup'
    Assert-True (@($fallbackWarnings).Count -eq 1) 'Missing cache warning is emitted even when managed fallback is available'
    Assert-True ($fallback[0].DiscoveryPath -eq $managedFile -and $fallback[0].ManagedName -eq 'ExistingGame') 'Managed fallback points to its manifest'
    Assert-True ($fallback[0].Id -eq $example.Id) 'A managed fallback retains the executable-based ID'
    Set-Content -LiteralPath $cacheFile -Value '{malformed'
    $malformedFallback = @(Get-NeuralDetectedGames -CacheRoot $cache -ManagedRoot $testRoot -WarningVariable malformedWarnings -WarningAction SilentlyContinue)
    Assert-True ($malformedFallback.Count -eq 1 -and $malformedFallback[0].ManagedName -eq 'ExistingGame') 'Malformed cache does not hide managed games'
    Assert-True (@($malformedWarnings).Count -eq 1) 'Malformed catalog produces one warning for its source file'
    Assert-True ([string]$malformedWarnings[0] -like ('*' + $cacheFile + '*')) 'Malformed cache warning identifies the source file'
    Assert-True ([string]$malformedWarnings[0] -match 'NVIDIA App.*scan.*Refresh.*Add game') 'Malformed cache warning includes actionable recovery options'
    Assert-True ((Get-FileHash -LiteralPath $managedFile).Hash -eq $managedHash) 'Manifest is never modified by discovery'
    Write-Output 'PASS: managed matching and absent or malformed cache fallback'
    Write-Output 'All game catalog tests passed.'
} finally {
    Remove-Item Function:\Start-Process,Function:\Get-Process -ErrorAction SilentlyContinue
    $env:NEURAL_GAMING_ROOT = $previousRoot
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        Assert-True ($resolved.StartsWith($testBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Test cleanup stays inside repository runtime'
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
