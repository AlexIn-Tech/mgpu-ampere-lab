# Read-only discovery. Import does not inspect caches, import the manager, write files or launch processes.
Set-StrictMode -Version Latest

function Get-CatalogProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-CatalogExecutable([object]$Value) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
    $path = $Value.Trim().Trim('"')
    # Cache paths must be absolute file paths, never commands, URIs or relative paths.
    try {
        if (-not [IO.Path]::IsPathRooted($path) -or [IO.Path]::GetExtension($path) -ine '.exe') { return $null }
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.PSIsContainer) { return $null }
        return $item.FullName
    } catch { return $null }
}

function Test-CatalogAuxiliaryExecutable([string]$Path) {
    $leaf = [IO.Path]::GetFileNameWithoutExtension($Path)
    if ($leaf -match '(?i)(launcher|crashhandler|crashreport|cleanup|updater|unins|^setup(?:\d|_|$)|^install(?:er|_|$))') { return $true }
    if ($leaf -match '^(?i:steam|uplay|ubisoftconnect|eadesktop|ealauncher|origin|battle\.net|goggalaxy)$') { return $true }
    return $Path -match '(?i)[\\/](?:__Installer|_CommonRedist|redist|installer)[\\/]'
}

function Test-CatalogClientApplication($Application) {
    foreach ($field in @('DriverProfile', 'ImageFiles')) {
        foreach ($value in @(Get-CatalogProperty $Application $field)) {
            if ($value -isnot [string]) { continue }
            try { $leaf = [IO.Path]::GetFileNameWithoutExtension($value.Trim('"')) }
            catch { continue }
            if ($leaf -match '^(?i:steam|epicgameslauncher|uplay|ubisoftconnect|eadesktop|ealauncher|origin|battle\.net|goggalaxy)$') { return $true }
        }
    }
    return $false
}

function Get-CatalogId([string]$Executable) {
    $canonical = [IO.Path]::GetFullPath($Executable).ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)) }
    finally { $sha.Dispose() }
    $hex = [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    return 'game_' + $hex.Substring(0, 32)
}

function New-CatalogEntry([string]$Title, [string]$Executable, [string]$Source, [string]$DiscoveryPath, $ManagedName) {
    if ([string]::IsNullOrWhiteSpace($Title)) { $Title = [IO.Path]::GetFileNameWithoutExtension($Executable) }
    return [pscustomobject]@{
        Id = Get-CatalogId $Executable
        Title = $Title
        Executable = $Executable
        Source = $Source
        DiscoveryPath = $DiscoveryPath
        ManagedName = $ManagedName
        IsManaged = ($null -ne $ManagedName)
    }
}

function Get-CatalogManagedEntries([string]$Root) {
    $folder = Join-Path $Root 'runtime\games'
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $name = Get-CatalogProperty $manifest 'Name'
            if ($name -isnot [string] -or $name -notmatch '^[A-Za-z0-9_-]+$' -or $name -cne $file.BaseName) { continue }
            $exe = Get-CatalogExecutable (Get-CatalogProperty $manifest 'Executable')
            if (-not $exe) { continue }
            $directory = Get-CatalogProperty $manifest 'GameDirectory'
            if ($directory -isnot [string] -or -not [IO.Path]::IsPathRooted($directory)) { continue }
            if ([IO.Path]::GetFullPath($directory).TrimEnd('\', '/') -ine (Split-Path $exe -Parent).TrimEnd('\', '/')) { continue }
            New-CatalogEntry $name $exe 'Managed setup' $file.FullName $name
        } catch { Write-Verbose "Skipped unreadable or malformed managed manifest: $($file.FullName)" }
    }
}

function Get-CatalogCacheFiles([string[]]$Roots) {
    $seen = @{}
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidates = if (Test-Path -LiteralPath $root -PathType Leaf) {
            @($root)
        } else {
            @((Join-Path $root 'NvBackend\ApplicationStorage.json'), (Join-Path $root 'ApplicationStorage.json'))
        }
        foreach ($candidate in $candidates) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            try { $path = (Get-Item -LiteralPath $candidate -ErrorAction Stop).FullName }
            catch { continue }
            if (-not $seen.ContainsKey($path)) { $seen[$path] = $true; $path }
        }
    }
}

function Get-NeuralDetectedGames {
    <#
    .SYNOPSIS
    Lists installed NVIDIA App games and existing NeuralGaming managed setups without changing them.
    .PARAMETER CacheRoot
    Optional NVIDIA App roots, NvBackend roots or ApplicationStorage.json files. Overrides default cache locations.
    .PARAMETER ManagedRoot
    Repository/configuration root containing runtime\games. Defaults to NEURAL_GAMING_ROOT or this repository.
    #>
    [CmdletBinding()]
    param([string[]]$CacheRoot, [string]$ManagedRoot)

    if ([string]::IsNullOrWhiteSpace($ManagedRoot)) {
        $ManagedRoot = if ($env:NEURAL_GAMING_ROOT) { $env:NEURAL_GAMING_ROOT } else { Split-Path $PSScriptRoot -Parent }
    }
    if (-not $PSBoundParameters.ContainsKey('CacheRoot')) {
        $CacheRoot = @()
        if ($env:LOCALAPPDATA) { $CacheRoot += Join-Path $env:LOCALAPPDATA 'NVIDIA Corporation\NVIDIA App' }
        # Windows application sandboxes can redirect LOCALAPPDATA while the NVIDIA App uses the profile's cache.
        if ($env:USERPROFILE) { $CacheRoot += Join-Path $env:USERPROFILE 'AppData\Local\NVIDIA Corporation\NVIDIA App' }
        if ($env:ProgramData) { $CacheRoot += Join-Path $env:ProgramData 'NVIDIA Corporation\NVIDIA App' }
    }
    $managed = @(Get-CatalogManagedEntries $ManagedRoot)
    $managedByPath = @{}
    foreach ($entry in $managed) { if (-not $managedByPath.ContainsKey($entry.Executable)) { $managedByPath[$entry.Executable] = $entry } }
    $byPath = @{}
    $cacheFiles = @(Get-CatalogCacheFiles $CacheRoot)
    if ($cacheFiles.Count -eq 0) {
        Write-Warning 'NVIDIA App game catalog was not found. Open NVIDIA App and scan for games, then Refresh, or choose Add game.'
    }
    foreach ($cache in $cacheFiles) {
        try { $document = Get-Content -LiteralPath $cache -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch {
            Write-Warning "Cannot read the NVIDIA App game catalog '$cache': it is unreadable or malformed. Open NVIDIA App and scan for games, then Refresh, or choose Add game."
            continue
        }
        foreach ($record in @(Get-CatalogProperty $document 'Applications')) {
            $app = Get-CatalogProperty $record 'Application'
            if ($null -eq $app -or (Get-CatalogProperty $app 'IsCreativeApplication') -eq $true -or (Test-CatalogClientApplication $app)) { continue }
            $paths = @{}
            $order = 0
            foreach ($field in @('ImageFiles', 'DriverProfile', 'DetectedFiles')) {
                foreach ($value in @(Get-CatalogProperty $app $field)) {
                    $exe = Get-CatalogExecutable $value
                    if (-not $exe -or (Test-CatalogAuxiliaryExecutable $exe)) { continue }
                    $score = if ($managedByPath.ContainsKey($exe)) { -1 }
                        elseif ($exe -match '(?i)-Shipping\.exe$') { 0 }
                        elseif ($exe -match '(?i)[\\/]Binaries[\\/](?:Win64|x64)[\\/]') { 1 }
                        elseif ($field -eq 'DriverProfile') { 2 }
                        elseif ($field -eq 'ImageFiles') { 3 }
                        else { 4 }
                    if (-not $paths.ContainsKey($exe) -or $score -lt $paths[$exe].Score) {
                        $paths[$exe] = [pscustomobject]@{ Executable = $exe; Score = $score; Order = $order }
                    }
                    $order++
                }
            }
            if ($paths.Count -eq 0) { continue }
            $selected = @($paths.Values | Sort-Object Score, Order)[0].Executable
            if ($byPath.ContainsKey($selected)) { continue }
            $title = Get-CatalogProperty $app 'DisplayName'
            if ($title -isnot [string]) { $title = $null }
            $managedName = if ($managedByPath.ContainsKey($selected)) { $managedByPath[$selected].ManagedName } else { $null }
            $byPath[$selected] = New-CatalogEntry $title $selected 'NVIDIA App' $cache $managedName
        }
    }
    # Keep existing managed setups visible even after an NVIDIA App rescan drops an entry.
    foreach ($entry in $managed) { if (-not $byPath.ContainsKey($entry.Executable)) { $byPath[$entry.Executable] = $entry } }
    $byPath.Values | Sort-Object Title, Executable
}

Export-ModuleMember -Function Get-NeuralDetectedGames
