# Manual, per-game MGPU management. Importing this module has no external side effects.
Set-StrictMode -Version Latest
$script:NeuralRoot = if ($env:NEURAL_GAMING_ROOT) { [IO.Path]::GetFullPath($env:NEURAL_GAMING_ROOT) } else { Split-Path $PSScriptRoot -Parent }
$script:BridgeName = 'nvngx.dll_mgpu_bridge.addon64'
Import-Module (Join-Path $PSScriptRoot 'NeuralGaming.Gpu.psm1') -Scope Local -Force
Import-Module (Join-Path $PSScriptRoot 'NeuralGaming.Runtime.psm1') -Scope Local -Force
. (Join-Path $PSScriptRoot 'NeuralGaming.Binding.ps1')
. (Join-Path $PSScriptRoot 'NeuralGaming.Pinning.ps1')
. (Join-Path $PSScriptRoot 'NeuralGaming.AutoArm.ps1')

function Enter-NeuralGameOperation([string]$Executable) {
    # Named OS mutexes coordinate CLI/GUI processes without persistent lock files.
    # Windows mutex ownership is recursive on the same thread, including helper calls.
    $canonical = [IO.Path]::GetFullPath($Executable).ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\NeuralGaming-Game-' + $key))
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "An active operation or managed session already owns this game: $Executable. Wait for it to finish, then retry." }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
function Exit-NeuralGameOperation([Threading.Mutex]$Mutex) {
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Assert-NeuralRegularPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse-point path refused: $current" }
        }
        $current = Split-Path $current -Parent
    }
}
function Get-NeuralOwnedPath([string]$Directory, [string]$RelativePath) {
    if (-not $RelativePath -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "Owned path must be a contained relative path: $RelativePath" }
    $prefix = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $Directory $RelativePath))
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Owned path is outside game directory: $RelativePath" }
    Assert-NeuralRegularPath $path
    return $path
}
function Get-NeuralManifestPath([string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Game name must contain only letters, digits, underscores or hyphens.' }
    return Join-Path $script:NeuralRoot "runtime\games\$Name.json"
}
function Get-NeuralManifest([string]$Name) {
    $path = Get-NeuralManifestPath $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Game '$Name' is not installed. Use Install-NeuralGame first." }
    Assert-NeuralRegularPath $path
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($manifest.Name -ne $Name -or [IO.Path]::GetFullPath((Split-Path $manifest.Executable -Parent)) -ne [IO.Path]::GetFullPath($manifest.GameDirectory)) { throw 'Invalid game manifest directory or name.' }
    foreach ($file in $manifest.Files) {
        Get-NeuralOwnedPath $manifest.GameDirectory $file.RelativePath | Out-Null
        if ($file.DisabledRelativePath) { Get-NeuralOwnedPath $manifest.GameDirectory $file.DisabledRelativePath | Out-Null }
    }
    foreach ($dir in $manifest.CreatedDirectories) { Get-NeuralOwnedPath $manifest.GameDirectory $dir | Out-Null }
    return $manifest
}
function Get-NeuralGameProcesses($Manifest) {
    foreach ($process in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Manifest.Executable)) -ErrorAction SilentlyContinue)) {
        try {
            try { $path = $process.Path } catch { $path = $null }
            if (-not $path) { $path = Get-NeuralProcessPath -ProcessId $process.Id }
            if (-not $path) { throw "Cannot inspect game process $($process.Id); close it before changing files." }
        } catch {
            # Enumeration is a snapshot: the game can exit before path lookup.
            # Only ignore a confirmed exit; unreadable live identities still fail closed.
            $inspectionFailure = $_
            try { $null = Get-Process -Id $process.Id -ErrorAction Stop }
            catch {
                if ($_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId,*') { continue }
                throw $inspectionFailure
            }
            throw $inspectionFailure
        }
        if ([IO.Path]::GetFullPath($path) -eq [IO.Path]::GetFullPath($Manifest.Executable)) { $process }
    }
}
function Set-NeuralGameEnabled([string]$Name, [bool]$Enabled) {
    $manifest = Get-NeuralManifest $Name
    $operation = Enter-NeuralGameOperation $manifest.Executable
    try {
        $manifest = Get-NeuralManifest $Name
        $moves = @()
        foreach ($file in @($manifest.Files | Where-Object { $_.DisabledRelativePath })) {
            $active = Get-NeuralOwnedPath $manifest.GameDirectory $file.RelativePath
            $disabled = Get-NeuralOwnedPath $manifest.GameDirectory $file.DisabledRelativePath
            $hasActive = Test-Path -LiteralPath $active
            $hasDisabled = Test-Path -LiteralPath $disabled
            if ($hasActive -and $hasDisabled) { throw "File conflict: active and disabled copies both exist: $active" }
            if ($Enabled -and -not ($hasActive -or $hasDisabled)) { throw "Owned DLL is missing: $disabled" }
            if ($Enabled) {
                $existing = if ($hasActive) { $active } else { $disabled }
                if ((Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash -ne $file.Sha256) { throw "Owned DLL has changed: $existing" }
            }
            if ($Enabled -and $hasDisabled) { $moves += @{ From = $disabled; To = $active } }
            if (-not $Enabled -and $hasActive) { $moves += @{ From = $active; To = $disabled } }
        }
        $completed = @()
        try {
            foreach ($move in $moves) { [IO.File]::Move($move.From, $move.To); $completed += $move }
        } catch {
            for ($i = $completed.Count - 1; $i -ge 0; $i--) {
                $move = $completed[$i]
                if ((Test-Path -LiteralPath $move.To) -and -not (Test-Path -LiteralPath $move.From)) { [IO.File]::Move($move.To, $move.From) }
            }
            throw
        }
    } finally { Exit-NeuralGameOperation $operation }
}

function Install-NeuralGame {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Executable,
          [Parameter(Mandatory)][string]$PackagePath, [Parameter(Mandatory)][string]$ReShadeDll, [string]$NeuralDll)
    $ErrorActionPreference = 'Stop'
    $manifestPath = Get-NeuralManifestPath $Name
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Required input file is missing: $Executable" }
    $Executable = (Get-Item -LiteralPath $Executable).FullName
    Assert-NeuralRegularPath $Executable
    $operation = Enter-NeuralGameOperation $Executable
    try {
        if (Test-Path -LiteralPath $manifestPath) { throw "Game '$Name' already exists in the manager; uninstall it first." }
        foreach ($inputFile in @($ReShadeDll) + @($NeuralDll | Where-Object { $_ })) {
            if (-not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { throw "Required input file is missing: $inputFile" }
            Assert-NeuralRegularPath ((Get-Item -LiteralPath $inputFile).FullName)
        }
        $ReShadeDll = (Get-Item -LiteralPath $ReShadeDll).FullName
        if ($NeuralDll) { $NeuralDll = (Get-Item -LiteralPath $NeuralDll).FullName }
        $directory = Split-Path $Executable -Parent
        if (-not (Test-Path -LiteralPath $PackagePath -PathType Container)) { throw "Bridge package folder is missing: $PackagePath" }
        $PackagePath = (Get-Item -LiteralPath $PackagePath).FullName
        Assert-NeuralRegularPath $PackagePath
        foreach ($required in @($script:BridgeName, 'mgpu.ini', 'ReShade2.ini', 'gpu1.ini', 'reshade-shaders\Shaders\mgpu_depth_tap.fx')) {
            if (-not (Test-Path -LiteralPath (Join-Path $PackagePath $required) -PathType Leaf)) { throw "Bridge package is incomplete: $required" }
        }
        if (@(Get-NeuralGameProcesses ([pscustomobject]@{ Executable = $Executable })).Count) { throw 'Close the game before installing.' }
        if (@(Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name -match '\.addon64(\.neural-disabled)?$' }).Count) { throw 'Existing add-on conflict; preserve or remove the existing installation first.' }
        if (Test-Path -LiteralPath (Join-Path $directory 'nvngx_dlssnr.dll')) { throw 'Existing neural DLL beside the executable must be moved out of the game loader path first.' }
        $plan = @(@{ RelativePath = 'dxgi.dll'; DisabledRelativePath = 'dxgi.dll.neural-disabled'; Source = $ReShadeDll; Content = $null })
        foreach ($source in Get-ChildItem -LiteralPath $PackagePath -Recurse -File) {
            if ($source.Name -match '^(LICENSE|README)(\.|$)') { continue }
            Assert-NeuralRegularPath $source.FullName
            $relative = $source.FullName.Substring($PackagePath.Length).TrimStart('\', '/')
            $disabled = if ($relative -eq $script:BridgeName) { "$relative.neural-disabled" } else { $null }
            $content = $null
            if ($relative -eq 'mgpu.ini') {
                $content = Get-Content -LiteralPath $source.FullName -Raw
                foreach ($setting in @(@('AutoArm', '0'), @('Passes', '1'), @('DcompOverlay', '1'))) {
                    $pattern = '(?m)^\s*' + $setting[0] + '\s*=.*$'
                    if ($content -notmatch $pattern) { throw "Bridge configuration is missing $($setting[0])." }
                    $content = [regex]::Replace($content, $pattern, ($setting[0] + '=' + $setting[1]))
                }
            }
            $plan += @{ RelativePath = $relative; DisabledRelativePath = $disabled; Source = $source.FullName; Content = $content }
        }
        $plan += @{ RelativePath = 'ReShade.ini'; DisabledRelativePath = $null; Source = $null; Content = "[GENERAL]`r`nEffectSearchPaths=.\reshade-shaders\Shaders\**`r`nTextureSearchPaths=.\reshade-shaders\Textures\**`r`nPresetPath=.\NeuralGamingPreset.ini`r`n`r`n[OVERLAY]`r`nAutoSavePreset=0`r`n" }
        $plan += @{ RelativePath = 'NeuralGamingPreset.ini'; DisabledRelativePath = $null; Source = $null; Content = '' }
        if ($NeuralDll) { $plan += @{ RelativePath = 'mgpu\nvngx_dlssnr.dll'; DisabledRelativePath = $null; Source = $NeuralDll; Content = $null } }
        $destinations = @{}
        foreach ($file in $plan) {
            foreach ($relative in @($file.RelativePath, $file.DisabledRelativePath) | Where-Object { $_ }) {
                $path = Get-NeuralOwnedPath $directory $relative
                if ($destinations.ContainsKey($path) -or (Test-Path -LiteralPath $path)) { throw "Existing file conflict: $path" }
                $destinations[$path] = $true
            }
        }
        $createdFiles = @(); $createdDirectories = @(); $records = @(); $manifestCreated = $false
        try {
            foreach ($file in $plan) {
                $relative = if ($file.DisabledRelativePath) { $file.DisabledRelativePath } else { $file.RelativePath }
                $path = Get-NeuralOwnedPath $directory $relative
                $parent = Split-Path $path -Parent
                $missing = @()
                while ($parent -ne $directory -and -not (Test-Path -LiteralPath $parent)) { $missing += $parent; $parent = Split-Path $parent -Parent }
                foreach ($dir in @($missing | Sort-Object Length)) { [IO.Directory]::CreateDirectory($dir) | Out-Null; $createdDirectories += $dir.Substring($directory.Length).TrimStart('\', '/') }
                $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                $createdFiles += $path
                try {
                    if ($null -ne $file.Content) { $bytes = [Text.Encoding]::UTF8.GetBytes($file.Content); $stream.Write($bytes, 0, $bytes.Length) }
                    else { $inputStream = [IO.File]::OpenRead($file.Source); try { $inputStream.CopyTo($stream) } finally { $inputStream.Dispose() } }
                } finally { $stream.Dispose() }
                $records += [pscustomobject]@{ RelativePath = $file.RelativePath; DisabledRelativePath = $file.DisabledRelativePath; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
            }
            $manifest = [pscustomobject]@{ Version = 1; Name = $Name; Executable = $Executable; GameDirectory = $directory; InstalledAt = (Get-Date).ToUniversalTime().ToString('o'); Files = @($records); CreatedDirectories = @($createdDirectories | Select-Object -Unique) }
            foreach($kind in @('baseline','verified','observation','session','autoarm')){Remove-NeuralBindingRecord $Name $kind}
            Assert-NeuralRegularPath $manifestPath
            [IO.Directory]::CreateDirectory((Split-Path $manifestPath -Parent)) | Out-Null
            $jsonBytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 8))
            $manifestStream = [IO.File]::Open($manifestPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            $manifestCreated = $true
            try { $manifestStream.Write($jsonBytes, 0, $jsonBytes.Length) } finally { $manifestStream.Dispose() }
        } catch {
            if ($manifestCreated -and (Test-Path -LiteralPath $manifestPath)) { Remove-Item -LiteralPath $manifestPath }
            foreach ($path in $createdFiles) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
            foreach ($relative in @($createdDirectories | Sort-Object Length -Descending)) {
                $dir = Get-NeuralOwnedPath $directory $relative
                if ((Test-Path -LiteralPath $dir) -and -not @(Get-ChildItem -LiteralPath $dir -Force).Count) { Remove-Item -LiteralPath $dir }
            }
            throw
        }
        Get-NeuralGameStatus -Name $Name
    } finally { Exit-NeuralGameOperation $operation }
}

function Get-NeuralGpus {
    [CmdletBinding()]
    param()
    $command = Get-Command nvidia-smi -CommandType Application -ErrorAction Stop
    $lines = & $command.Source '--query-gpu=index,uuid,name,display_active,pci.bus_id' '--format=csv,noheader,nounits' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "nvidia-smi failed: $($lines -join ' ')" }
    foreach ($gpu in ($lines | ConvertFrom-Csv -Header Index, Uuid, Name, DisplayActive, PciBusId)) {
        [pscustomobject]@{ Index = [int]$gpu.Index.Trim(); Uuid = $gpu.Uuid.Trim(); Name = $gpu.Name.Trim(); DisplayActive = ($gpu.DisplayActive.Trim() -eq 'Enabled'); DisplayMode = $null; PciBusId = $gpu.PciBusId.Trim() }
    }
}
function Get-NeuralGameStatus {
    [CmdletBinding()]
    param([string]$Name)
    if (-not $Name) {
        $folder = Join-Path $script:NeuralRoot 'runtime\games'
        if (Test-Path -LiteralPath $folder) { foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.json' -File) { Get-NeuralGameStatus -Name $file.BaseName } }
        return
    }
    $manifest = Get-NeuralManifest $Name
    $active = 0; $disabled = 0; $count = 0
    foreach ($file in @($manifest.Files | Where-Object { $_.DisabledRelativePath })) {
        $count++
        if (Test-Path -LiteralPath (Get-NeuralOwnedPath $manifest.GameDirectory $file.RelativePath)) { $active++ }
        if (Test-Path -LiteralPath (Get-NeuralOwnedPath $manifest.GameDirectory $file.DisabledRelativePath)) { $disabled++ }
    }
    $state = if ($active -eq $count -and $disabled -eq 0) { 'Enabled' } elseif ($disabled -eq $count -and $active -eq 0) { 'Disabled' } else { 'Inconsistent' }
    [pscustomobject]@{ Name = $Name; State = $state; Executable = $manifest.Executable; NeuralDllPresent = (Test-Path -LiteralPath (Get-NeuralOwnedPath $manifest.GameDirectory 'mgpu\nvngx_dlssnr.dll') -PathType Leaf); Running = (@(Get-NeuralGameProcesses $manifest).Count -gt 0); Manifest = (Get-NeuralManifestPath $Name) }
}
function Test-NeuralGameSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $manifest = Get-NeuralManifest $Name
    $issues = @(); $gpus = @(); $config = $null
    if (-not (Test-Path -LiteralPath $manifest.Executable -PathType Leaf)) { $issues += 'Game executable is missing.' }
    if (-not (Test-Path -LiteralPath (Get-NeuralOwnedPath $manifest.GameDirectory 'mgpu\nvngx_dlssnr.dll') -PathType Leaf)) { $issues += 'Supply an Ampere-compatible neural DLL at mgpu\nvngx_dlssnr.dll; never beside the executable.' }
    if (Test-Path -LiteralPath (Join-Path $manifest.GameDirectory 'nvngx_dlssnr.dll')) { $issues += 'Move nvngx_dlssnr.dll out of the executable folder before launch.' }
    $iniPath = Get-NeuralOwnedPath $manifest.GameDirectory 'mgpu.ini'
    $ini = if (Test-Path -LiteralPath $iniPath) { Get-Content -LiteralPath $iniPath -Raw } else { '' }
    # MGPU consumes the first exact-case active key. Reject duplicates and case
    # variants so a later safe-looking line cannot hide an earlier unsafe value.
    foreach($setting in @(@('AutoArm','[01]'),@('Passes','1'),@('DcompOverlay','1'))){
        $entries=@([regex]::Matches([string]$ini,('(?im)^[ \t]*(?<key>'+[regex]::Escape($setting[0])+')(?<gap>[ \t]*)=[ \t]*(?<value>[^\r\n]*)\r?$')))
        if($entries.Count -ne 1 -or $entries[0].Groups['key'].Value -cne $setting[0] -or $entries[0].Groups['gap'].Value -ne '' -or $entries[0].Groups['value'].Value.Trim() -cnotmatch ('^'+$setting[1]+'$')){
            $issues += ('Require one exact-case mgpu.ini '+$setting[0]+'='+$setting[1]+' entry without duplicates for initial validation.')
        }
    }
    foreach ($file in $manifest.Files) {
        $path = Get-NeuralOwnedPath $manifest.GameDirectory $file.RelativePath
        if ($file.DisabledRelativePath -and -not (Test-Path -LiteralPath $path)) { $path = Get-NeuralOwnedPath $manifest.GameDirectory $file.DisabledRelativePath }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $issues += "Owned file is missing: $path" }
        elseif($file.RelativePath -eq 'mgpu\nvngx_dlssnr.dll' -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Sha256){$issues += 'Installed neural model has changed; review and reinstall it before launch.'}
    }
    if ((Get-NeuralGameStatus -Name $Name).State -eq 'Inconsistent') { $issues += 'Active/disabled DLL state is inconsistent; inspect the owned files.' }
    try { $gpus = @(Get-NeuralGpus) } catch { $issues += "Cannot inspect NVIDIA GPUs: $($_.Exception.Message)" }
    if ($gpus.Count -lt 2) { $issues += 'At least two NVIDIA GPUs are required.' }
    $configPath = Join-Path $script:NeuralRoot 'runtime\config.json'
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $render = @($gpus | Where-Object { $_.Uuid -eq $config.renderUuid })
        $neural = @($gpus | Where-Object { $_.Uuid -eq $config.neuralUuid })
        if ($config.renderUuid -eq $config.neuralUuid -or $render.Count -ne 1 -or $neural.Count -ne 1) { $issues += 'Configure distinct, present renderUuid and neuralUuid values in runtime/config.json.' }
        elseif ($render[0].DisplayActive -or -not $neural[0].DisplayActive) { $issues += 'Single-display topology requires the headless GPU to render and the display GPU to run the neural stage.' }
    } catch { $issues += "GPU role configuration is missing or invalid: $configPath" }
    $pinning=Get-NeuralGamePinning -Name $Name
    if(-not $pinning.Available -or -not $pinning.Supported){$issues += 'Scoped GPU selector not ready: '+$pinning.Message}
    $dependenciesReady=($issues.Count -eq 0)
    $binding=Get-NeuralGameBinding -Name $Name
    $warnings = @('Launch uses AutoArm=0. After fresh GPU binding is verified, Ctrl+Alt+F10 arms the bridge manually. A loaded model does not confirm neural output.', 'RTX 3090 neural rendering is experimental and has suffered a device-removal crash. Dependency checks do not establish runtime stability.')
    [pscustomobject]@{ Name = $Name; Ready = ($issues.Count -eq 0); DependenciesReady=$dependenciesReady; Issues = @($issues); Warnings = $warnings; Binding=$binding; Pinning=$pinning; GpuSelectionVerified = $false; RuntimeVerified = $false; Gpus = @($gpus); ConfigurationPath = $configPath }
}
function Start-NeuralGame {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $ErrorActionPreference = 'Stop'
    $manifest = Get-NeuralManifest $Name
    $operation = Enter-NeuralGameOperation $manifest.Executable
    try {
        $manifest = Get-NeuralManifest $Name
        if (-not (Test-Path -LiteralPath (Get-NeuralOwnedPath $manifest.GameDirectory 'mgpu\nvngx_dlssnr.dll') -PathType Leaf)) { throw 'Missing neural DLL: supply an Ampere-compatible mgpu\nvngx_dlssnr.dll before launching.' }
        if (@(Get-NeuralGameProcesses $manifest).Count) { throw 'The game is already running. Close it before starting a managed session.' }
        Restore-NeuralLaunchAutoArm -Name $Name
        $setup = Test-NeuralGameSetup -Name $Name
        if (-not $setup.Ready) { throw ($setup.Issues -join [Environment]::NewLine) }
        if ((Get-NeuralGameStatus -Name $Name).State -ne 'Disabled') { throw 'Recover the previous session with Stop-NeuralGame before starting.' }
        foreach ($warning in $setup.Warnings) { Write-Warning $warning }
        Remove-NeuralBindingRecord $Name 'verified'
        Write-NeuralBindingRecord $Name 'observation' ([pscustomobject]@{Status='Unknown';Message='Direct neural launch: the current runtime log verifies actual adapter binding and output. Baseline observation is optional.'})
        $startedUtc=[DateTime]::UtcNow
        $previousPrefix=Get-NeuralLogPrefixHash -LogPath (Get-NeuralOwnedPath $manifest.GameDirectory 'ReShade.log')
        try {
            Set-NeuralLaunchAutoArm -Name $Name -Value 0
            Write-Host 'Launch with neural: AutoArm=0 verified before process startup; Ctrl+Alt+F10 activates manually after GPU binding is verified.'
            Set-NeuralGameEnabled -Name $Name -Enabled $true
            $process = Start-NeuralPinnedProcess -Manifest $manifest
            Save-NeuralSessionRecord -Name $Name -Process $process -StartedUtc $startedUtc -PreviousPrefixHash $previousPrefix
            $process.WaitForExit()
            while (@(Get-NeuralGameProcesses $manifest).Count) { Get-NeuralGameProcesses $manifest | Wait-Process }
        } finally {
            if (@(Get-NeuralGameProcesses $manifest).Count -eq 0) {
                try { Set-NeuralGameEnabled -Name $Name -Enabled $false }
                finally { Restore-NeuralLaunchAutoArm -Name $Name }
            }
            else { Write-Warning 'The game is still running. Close it, then run Stop-NeuralGame to restore disabled files.' }
        }
    } finally { Exit-NeuralGameOperation $operation }
}
function Stop-NeuralGame {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $manifest = Get-NeuralManifest $Name
    $operation = Enter-NeuralGameOperation $manifest.Executable
    try {
        $manifest = Get-NeuralManifest $Name
        if (@(Get-NeuralGameProcesses $manifest).Count) { throw 'Close the game first; Stop-NeuralGame never terminates a game process.' }
        Set-NeuralGameEnabled -Name $Name -Enabled $false
        Restore-NeuralLaunchAutoArm -Name $Name
        Get-NeuralGameStatus -Name $Name
    } finally { Exit-NeuralGameOperation $operation }
}
function Uninstall-NeuralGame {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $ErrorActionPreference = 'Stop'
    $manifest = Get-NeuralManifest $Name
    $operation = Enter-NeuralGameOperation $manifest.Executable
    try {
        $manifest = Get-NeuralManifest $Name
        if (@(Get-NeuralGameProcesses $manifest).Count) { throw 'Close the game before uninstalling.' }
        $paths = @()
        foreach ($file in $manifest.Files) {
            $candidates = @($file.RelativePath, $file.DisabledRelativePath) | Where-Object { $_ }
            $existing = @($candidates | ForEach-Object { Get-NeuralOwnedPath $manifest.GameDirectory $_ } | Where-Object { Test-Path -LiteralPath $_ })
            if ($existing.Count -gt 1) { throw "Active/disabled file conflict: $($file.RelativePath)" }
            foreach ($path in $existing) {
                if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Sha256) { throw "Refusing uninstall: owned file was modified: $path" }
                $paths += $path
            }
        }
        foreach($kind in @('baseline','verified','observation','session','autoarm')){Remove-NeuralBindingRecord $Name $kind}
        foreach ($path in $paths) { Remove-Item -LiteralPath $path }
        foreach ($relative in @($manifest.CreatedDirectories | Sort-Object Length -Descending)) {
            $dir = Get-NeuralOwnedPath $manifest.GameDirectory $relative
            if ((Test-Path -LiteralPath $dir) -and -not @(Get-ChildItem -LiteralPath $dir -Force).Count) { Remove-Item -LiteralPath $dir }
        }
        Remove-Item -LiteralPath (Get-NeuralManifestPath $Name)
        "Removed unchanged owned files for $Name."
    } finally { Exit-NeuralGameOperation $operation }
}
function Show-NeuralGamingCommands {
    @'
Show-NeuralGaming                      Open the native game library GUI
Get-NeuralLibraryGames                 NVIDIA detected + manual + managed games
Invoke-NeuralLibraryAction -Action Check -GameId <id>
Get-NeuralGpus
Get-NeuralGameStatus
Test-NeuralGameSetup -Name Cyberpunk2077
Start-NeuralGameBaseline -Name Cyberpunk2077
Confirm-NeuralGameGpu -Name Cyberpunk2077
Get-NeuralGameBinding -Name Cyberpunk2077
Get-NeuralGameRuntime -Name Cyberpunk2077
Get-NeuralGamePinning -Name Cyberpunk2077
Start-NeuralGame -Name Cyberpunk2077
Stop-NeuralGame -Name Cyberpunk2077
Uninstall-NeuralGame -Name Cyberpunk2077
Install-NeuralGame -Name Cyberpunk2077 -Executable <exe> -PackagePath <bridge-folder> -ReShadeDll <64-bit-dll> [-NeuralDll <Ampere-compatible-dll>]
Start launches directly with AutoArm=0 verified before startup and restores the previous setting and disabled DLLs after exit.
Both tool launch modes use an experimental main-EXE DirectX 12 selector for the headless GPU. Baseline verification is optional.
After current GPU binding is verified, Ctrl+Alt+F10 activates neural manually. Ctrl+Alt+F7 compares views.
Ordinary Steam launches after cleanup retain normal GPU selection. Recover finishes cleanup after an interrupted tool session.
'@
}
Export-ModuleMember -Function Install-NeuralGame, Get-NeuralGpus, Get-NeuralGameStatus, Test-NeuralGameSetup, Start-NeuralGame, Stop-NeuralGame, Uninstall-NeuralGame, Show-NeuralGamingCommands, Start-NeuralGameBaseline, Confirm-NeuralGameGpu, Get-NeuralGameBinding, Get-NeuralGameRuntime, Get-NeuralGamePinning
