# UI and command-line orchestration. Import never starts a game or changes settings.
Set-StrictMode -Version Latest
$script:LibraryRoot = if ($env:NEURAL_GAMING_ROOT) { [IO.Path]::GetFullPath($env:NEURAL_GAMING_ROOT) } else { Split-Path $PSScriptRoot -Parent }
$script:CodeRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'NeuralGaming.psm1') -Scope Local -Force
Import-Module (Join-Path $PSScriptRoot 'NeuralGameCatalog.psm1') -Scope Local -Force

function Get-LibraryProperty($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Get-LibraryId([string]$Executable) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Executable).ToLowerInvariant())) }
    finally { $sha.Dispose() }
    return 'game_' + [BitConverter]::ToString($hash).Replace('-','').ToLowerInvariant().Substring(0,32)
}
function Assert-LibraryRegularPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Reparse-point path refused: $current" }
        $current = Split-Path $current -Parent
    }
}
function Get-LibraryJson([string]$RelativePath, $Default) {
    $path = Join-Path $script:LibraryRoot $RelativePath
    Assert-LibraryRegularPath $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $Default }
    return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
function Set-LibraryJson([string]$RelativePath, $Value) {
    $path = Join-Path $script:LibraryRoot $RelativePath
    Assert-LibraryRegularPath $path
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    $temp = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $temp + '.bak'
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp,$path,$backup) } else { [IO.File]::Move($temp,$path) }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup }
    }
}
function Enter-LibraryMutation {
    $key = Get-LibraryId (Join-Path $script:LibraryRoot 'library.exe')
    $mutex = New-Object Threading.Mutex($false, ('Local\NeuralGaming-Library-' + $key))
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another library operation is running. Retry after it finishes.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
function Exit-LibraryMutation([Threading.Mutex]$Mutex) { try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } }
function Save-LibraryAcceptance([string]$GameId,[string]$ManagedName) {
    $prefs=Get-LibraryJson 'runtime\library\preferences.json' ([pscustomobject]@{Games=@()})
    $records=@(Get-LibraryProperty $prefs 'Games' @() | Where-Object Id -ne $GameId)
    $records += [pscustomobject]@{Id=$GameId;RiskAccepted=$true;ManagedName=$ManagedName;AcceptedUtc=[DateTime]::UtcNow.ToString('o')}
    Set-LibraryJson 'runtime\library\preferences.json' ([pscustomobject]@{Games=$records})
}
function Assert-LibraryExecutable([string]$Executable) {
    if (-not [IO.Path]::IsPathRooted($Executable) -or [IO.Path]::GetExtension($Executable) -ine '.exe') { throw 'Select an absolute path to a 64-bit game .exe.' }
    Assert-LibraryRegularPath $Executable
    $file = Get-Item -LiteralPath $Executable -ErrorAction Stop
    if ($file.PSIsContainer) { throw 'Select a game executable file.' }
    $systemDirectory=[IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')+'\'
    if ($file.FullName.StartsWith($systemDirectory,[StringComparison]::OrdinalIgnoreCase) -or $file.FullName -match '(?i)[\\/]NVIDIA Corporation[\\/](?:NVIDIA App|NvContainer|Installer2|Display.NvContainer)[\\/]') { throw 'System and NVIDIA utility executables cannot be registered as games.' }
    if ([IO.Path]::GetFileNameWithoutExtension($file.Name) -match '^(?i:steam|epicgameslauncher|uplay|ubisoftconnect|eadesktop|ealauncher|origin|battle\.net|goggalaxy|powershell|pwsh|cmd|regedit|explorer)$') { throw 'Select the actual game executable rather than a launcher or system utility.' }
    $stream = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw 'The selected file is not a Windows game executable.' }
        $stream.Position = 60; $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw 'Invalid executable header.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'This setup requires a 64-bit x64 Windows game executable.' }
    } finally { $reader.Dispose(); $stream.Dispose() }
    return $file.FullName
}
function Get-NeuralLibraryGames {
    [CmdletBinding()] param()
    $entries = @{}
    foreach ($entry in @(Get-NeuralDetectedGames -ManagedRoot $script:LibraryRoot)) { $entries[(Get-LibraryId $entry.Executable)] = $entry }
    $custom = Get-LibraryJson 'runtime\library\custom-games.json' ([pscustomobject]@{Games=@()})
    foreach ($entry in @(Get-LibraryProperty $custom 'Games' @())) {
        $exe = [string](Get-LibraryProperty $entry 'Executable')
        if (-not $exe -or -not [IO.Path]::IsPathRooted($exe)) { continue }
        $id = Get-LibraryId $exe
        if ($entries.ContainsKey($id)) { $entries[$id].Title = [string]$entry.Title }
        else { $entries[$id] = [pscustomobject]@{Id=$id;Title=[string]$entry.Title;Executable=$exe;Source='Manual';ManagedName=$null;DiscoveryPath=$null} }
    }
    # Manifests are authoritative even if a catalog entry vanished or was renamed.
    $managed = @{}
    $manifestFolder=Join-Path $script:LibraryRoot 'runtime\games'
    Assert-LibraryRegularPath $manifestFolder
    if (Test-Path -LiteralPath $manifestFolder -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $manifestFolder -Filter '*.json' -File)) {
            try {
                $status=Get-NeuralGameStatus -Name $file.BaseName
                $id=Get-LibraryId $status.Executable; $managed[$id]=$status
                if (-not $entries.ContainsKey($id)) { $entries[$id]=[pscustomobject]@{Id=$id;Title=$status.Name;Executable=$status.Executable;Source='Managed setup';DiscoveryPath=$file.FullName} }
            } catch { Write-Warning ('Cannot read managed game '+$file.BaseName+': '+$_.Exception.Message) }
        }
    }
    $preferences = Get-LibraryJson 'runtime\library\preferences.json' ([pscustomobject]@{Games=@()})
    foreach ($id in $entries.Keys) {
        $entry=$entries[$id]; $status=if ($managed.ContainsKey($id)) { $managed[$id] } else { $null }
        $pref=@(Get-LibraryProperty $preferences 'Games' @() | Where-Object { $_.Id -eq $id })
        $accepted=if ($pref.Count) { [bool]$pref[0].RiskAccepted } else { $null -ne $status }
        $binding=$null;$runtime=$null;$pinning=$null;$canLaunch=$false
        if($status){
            $binding=Get-NeuralGameBinding -Name $status.Name
            $runtime=Get-NeuralGameRuntime -Name $status.Name
            $pinning=Get-NeuralGamePinning -Name $status.Name
            # Direct launch checks dependencies and configured topology; optional
            # baseline observations remain separate from fresh runtime verification.
            $canLaunch=[bool](Test-NeuralGameSetup -Name $status.Name).Ready
        }
        [pscustomobject]@{
            Id=$id; Title=$entry.Title; Executable=$entry.Executable; Source=$entry.Source
            ManagedName=if ($status) { $status.Name } else { $null }; IsManaged=($null -ne $status)
            State=if ($status) { $status.State } else { 'Not patched' }; IsRunning=if ($status) { [bool]$status.Running } else { $false }
            Compatibility='Unverified'; RiskAccepted=$accepted; ArtPath=$null
            CanLaunchNeural=$canLaunch;Binding=$binding;Runtime=$runtime;Pinning=$pinning
            DiscoveryPath=Get-LibraryProperty $entry 'DiscoveryPath'
        }
    }
}
function Register-NeuralLibraryGame {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Title,[Parameter(Mandatory)][string]$Executable)
    if ([string]::IsNullOrWhiteSpace($Title) -or $Title.Length -gt 180) { throw 'Enter a game title of 1 to 180 characters.' }
    $exe = Assert-LibraryExecutable $Executable
    $id = Get-LibraryId $exe; $lock = Enter-LibraryMutation
    try {
        $custom=Get-LibraryJson 'runtime\library\custom-games.json' ([pscustomobject]@{Games=@()})
        $games=@(Get-LibraryProperty $custom 'Games' @() | Where-Object { (Get-LibraryId $_.Executable) -ne $id })
        $games += [pscustomobject]@{Id=$id;Title=$Title.Trim();Executable=$exe}
        Set-LibraryJson 'runtime\library\custom-games.json' ([pscustomobject]@{Games=$games})
    } finally { Exit-LibraryMutation $lock }
    Get-NeuralLibraryGames | Where-Object Id -eq $id
}
function Get-NeuralLibraryDisplay {
    [CmdletBinding()] param()
    $config=Get-LibraryJson 'runtime\config.json' $null
    $display=Get-LibraryProperty $config 'display'
    [pscustomobject]@{Width=[int](Get-LibraryProperty $display 'Width' 3440);Height=[int](Get-LibraryProperty $display 'Height' 1440);RefreshHz=[int](Get-LibraryProperty $display 'RefreshHz' 100);RenderGpuUuid=Get-LibraryProperty $config 'renderUuid';NeuralGpuUuid=Get-LibraryProperty $config 'neuralUuid'}
}
function Get-NeuralLibraryGpus { [CmdletBinding()] param(); Get-NeuralGpus }
function Set-NeuralLibrarySettings {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$RenderGpuUuid,[Parameter(Mandatory)][string]$NeuralGpuUuid,
        [ValidateRange(640,16384)][int]$Width=3440,[ValidateRange(480,16384)][int]$Height=1440,[ValidateRange(24,1000)][int]$RefreshHz=100)
    $gpus=@(Get-NeuralLibraryGpus)
    $render=@($gpus | Where-Object Uuid -eq $RenderGpuUuid); $neural=@($gpus | Where-Object Uuid -eq $NeuralGpuUuid)
    if ($RenderGpuUuid -eq $NeuralGpuUuid -or $render.Count -ne 1 -or $neural.Count -ne 1) { throw 'Select two distinct, present GPU UUIDs.' }
    if ($render[0].DisplayActive -or -not $neural[0].DisplayActive) { throw 'Select the headless GPU for rendering and the display-connected GPU for neural output.' }
    $lock=Enter-LibraryMutation
    try {
        $config=Get-LibraryJson 'runtime\config.json' ([pscustomobject]@{})
        $config | Add-Member NoteProperty renderUuid $RenderGpuUuid -Force
        $config | Add-Member NoteProperty neuralUuid $NeuralGpuUuid -Force
        $config | Add-Member NoteProperty display ([pscustomobject]@{Width=$Width;Height=$Height;RefreshHz=$RefreshHz}) -Force
        Set-LibraryJson 'runtime\config.json' $config
    } finally { Exit-LibraryMutation $lock }
    $config
}
function Invoke-NeuralLibraryAction {
    [CmdletBinding()] param([Parameter(Mandatory)][ValidateSet('Patch','Unpatch','Check','Launch','Stop','Baseline','VerifyGpu')][string]$Action,
        [Parameter(Mandatory)][string]$GameId,[switch]$AllowUnverified)
    $game=@(Get-NeuralLibraryGames | Where-Object Id -eq $GameId)
    if ($game.Count -ne 1) { throw 'Game was not found. Refresh the library and select it again.' }
    $game=$game[0]
    if ($Action -eq 'Patch') {
        if ($game.IsManaged) { throw 'This game is already patched.' }
        if (-not $game.RiskAccepted -and -not $AllowUnverified) { throw 'Acknowledge unverified compatibility before patching this game. Use -AllowUnverified after reviewing the game and its online/anti-cheat restrictions.' }
        $exe=Assert-LibraryExecutable $game.Executable
        $lock=Enter-LibraryMutation
        try {
            $prefs=Get-LibraryJson 'runtime\library\preferences.json' ([pscustomobject]@{Games=@()})
            $record=@(Get-LibraryProperty $prefs 'Games' @() | Where-Object Id -eq $GameId)
            $name=if ($record.Count) { [string](Get-LibraryProperty $record[0] 'ManagedName' $game.Id) } else { $game.Id }
            if ($name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid saved manager name. Review the library preferences.' }
            Install-NeuralGame -Name $name -Executable $exe -PackagePath (Join-Path $script:LibraryRoot 'runtime\packages\bridge-0.3.1') -ReShadeDll (Join-Path $script:LibraryRoot 'runtime\packages\reshade-6.8.0\ReShade64.dll') -NeuralDll (Join-Path $script:LibraryRoot 'runtime\packages\dlssnr-310.8.SF-v2\nvngx_dlssnr.dll') | Out-Null
            try {
                Save-LibraryAcceptance $GameId $name
            } catch { Uninstall-NeuralGame -Name $name | Out-Null; throw }
        } finally { Exit-LibraryMutation $lock }
        return Get-NeuralLibraryGames | Where-Object Id -eq $GameId
    }
    if (-not $game.IsManaged) { throw 'Patch this game before using managed session actions.' }
    switch ($Action) {
        'Unpatch' {
            $lock=Enter-LibraryMutation
            try {
                # Preserve a pre-existing CLI name (e.g. Cyberpunk2077) for repatching.
                Save-LibraryAcceptance $GameId $game.ManagedName
                Uninstall-NeuralGame -Name $game.ManagedName
            } finally { Exit-LibraryMutation $lock }
        }
        'Check' { Test-NeuralGameSetup -Name $game.ManagedName }
        'Launch' { Start-NeuralGame -Name $game.ManagedName }
        'Baseline' { Start-NeuralGameBaseline -Name $game.ManagedName }
        'VerifyGpu' { Confirm-NeuralGameGpu -Name $game.ManagedName }
        'Stop' { Stop-NeuralGame -Name $game.ManagedName }
    }
}
function Show-NeuralGamingGui {
    [CmdletBinding()] param()
    if ($script:LibraryRoot.TrimEnd('\') -ine $script:CodeRoot.TrimEnd('\')) { throw 'The GUI uses this installed repository. Clear NEURAL_GAMING_ROOT before opening it.' }
    $entry=Join-Path $script:CodeRoot 'gui\Show-NeuralGaming.ps1'
    $hostPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $hostPath -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$entry+'"')) -WindowStyle Hidden -PassThru
}
function Show-NeuralGaming { [CmdletBinding()] param(); Show-NeuralGamingGui }
Export-ModuleMember -Function Get-NeuralLibraryGames,Register-NeuralLibraryGame,Get-NeuralLibraryDisplay,Get-NeuralLibraryGpus,Set-NeuralLibrarySettings,Invoke-NeuralLibraryAction,Show-NeuralGamingGui,Show-NeuralGaming
