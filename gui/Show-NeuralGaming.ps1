[CmdletBinding()]
param([switch]$Preview, [string]$ScreenshotPath, [switch]$SmokeTest)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Initialize-NeuralPowerShell.ps1"
Set-StrictMode -Version Latest
$script:root = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if ($env:NEURAL_GAMING_ROOT -and [IO.Path]::GetFullPath($env:NEURAL_GAMING_ROOT).TrimEnd('\','/') -ine $script:root.TrimEnd('\','/')) {
    throw "The GUI uses installed repository state at $script:root. An alternate NEURAL_GAMING_ROOT is set. Clear it before opening the GUI; alternate roots are supported only by fixture/CLI commands."
}
$env:NEURAL_GAMING_ROOT = $script:root
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start this window with Windows PowerShell -Sta, or Show-NeuralGaming.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$script:demo = $Preview -or $SmokeTest
$script:activeOperation = $null
$script:lastLibraryRefresh = [DateTime]::MinValue
$script:games = @(); $script:gpus = @(); $script:display = $null
$script:activity = New-Object 'System.Collections.ObjectModel.ObservableCollection[string]'
[xml]$markup = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'NeuralGaming.xaml') -Raw -Encoding UTF8
$reader = New-Object Xml.XmlNodeReader $markup
try { $script:window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
$script:ui = @{}
foreach ($node in $markup.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $script:ui[$name] = $script:window.FindName($name)
}
$script:ui.ActivityList.ItemsSource = $script:activity
function Get-GuiValue($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Assert-GuiRegularPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse-point path refused before operation write: $current"
        }
        $current = Split-Path $current -Parent
    }
}
function Add-GuiActivity([string]$Message) {
    $script:activity.Add(('{0:HH:mm:ss}  {1}' -f [DateTime]::Now, $Message))
    while ($script:activity.Count -gt 150) { $script:activity.RemoveAt(0) }
    $script:ui.ActivityList.ScrollIntoView($script:activity[$script:activity.Count - 1])
}
function ConvertTo-GuiGame($Game) {
    $title = [string](Get-GuiValue $Game 'Title' 'Untitled game')
    $initials = -join @($title -split '\s+' | Where-Object { $_ } | Select-Object -First 2 | ForEach-Object { $_.Substring(0,1).ToUpperInvariant() })
    $managed = [bool](Get-GuiValue $Game 'IsManaged' $false)
    $state = [string](Get-GuiValue $Game 'State' 'Not patched')
    [pscustomobject]@{
        Id = [string](Get-GuiValue $Game 'Id'); Title = $title; Initials = $initials
        Executable = [string](Get-GuiValue $Game 'Executable'); Source = [string](Get-GuiValue $Game 'Source' 'Manual')
        IsManaged = $managed; ManagedName = Get-GuiValue $Game 'ManagedName'; State = $state
        IsRunning = [bool](Get-GuiValue $Game 'IsRunning' $false)
        Compatibility = [string](Get-GuiValue $Game 'Compatibility' 'Unverified')
        RiskAccepted = [bool](Get-GuiValue $Game 'RiskAccepted' $false)
        CanLaunchNeural = [bool](Get-GuiValue $Game 'CanLaunchNeural' $false)
        Binding = Get-GuiValue $Game 'Binding'
        Runtime = Get-GuiValue $Game 'Runtime'
        Pinning = Get-GuiValue $Game 'Pinning'
        ArtPath = Get-GuiValue $Game 'ArtPath'
        StatusLabel = if ($managed) { 'Patched · ' + $state } else { 'Not patched · unverified' }
    }
}
function Update-GuiSelection {
    $busy = $null -ne $script:activeOperation
    $sessionId = if ($busy -and $script:activeOperation.Action -eq 'Launch') { $script:activeOperation.GameId } else { $null }
    $rowsChanged = $false
    foreach ($entry in $script:games) {
        $runtime = Get-GuiValue $entry 'Runtime'
        $freshBinding = [bool](Get-GuiValue $runtime 'Fresh' $false) -and [bool](Get-GuiValue $runtime 'BindingVerified' $false)
        $label = if ($sessionId -and $entry.Id -eq $sessionId) {
            if ($freshBinding -and (Get-GuiValue $runtime 'Streaming' $false)) { 'Patched · Neural streaming' } else { 'Patched · Neural output unverified' }
        } elseif ($entry.IsManaged) { 'Patched · ' + $entry.State } else { 'Not patched · unverified' }
        if ($entry.StatusLabel -ne $label) { $entry.StatusLabel=$label; $rowsChanged=$true }
    }
    if ($rowsChanged) { $script:ui.GameList.Items.Refresh() }
    $game = $script:ui.GameList.SelectedItem
    foreach ($name in @('PatchButton','UnpatchButton','LaunchButton','BaselineButton','VerifyGpuButton','CheckButton','RecoverButton','OpenLogButton')) { $script:ui[$name].IsEnabled = $false }
    foreach ($name in @('AddButton','RefreshButton','FreeGpuButton','SettingsButton')) { $script:ui[$name].IsEnabled = -not $busy }
    $script:ui.GameArtwork.Source = $null
    if ($null -eq $game) {
        $script:ui.GameTitle.Text = 'Your next session'; $script:ui.StateText.Text = 'Select a game'
        $script:ui.SourceText.Text = 'Choose a game from your library'; $script:ui.ExecutableText.Text = '—'
        $script:ui.CompatibilityText.Text = 'Detected games are not automatically supported'
        $script:ui.BindingText.Text = 'Game GPU: unverified'; $script:ui.RuntimeText.Text = 'Neural output: unverified'
        $script:ui.PinningText.Text = 'Scoped GPU selector: unverified · select a managed game'
        $script:ui.PinningText.ToolTip = $script:ui.PinningText.Text
        $script:ui.SessionHint.Text = 'Add or select a game. Check its executable and compatibility before patching.'
        return
    }
    $script:ui.GameTitle.Text = $game.Title
    $script:ui.GameTitle.ToolTip = $game.Title
    $script:ui.SourceText.Text = 'Discovered via ' + $game.Source
    $script:ui.ExecutableText.Text = $game.Executable
    $binding = Get-GuiValue $game 'Binding'
    $runtime = Get-GuiValue $game 'Runtime'
    $pinning = Get-GuiValue $game 'Pinning'
    $pinningReady = [bool](Get-GuiValue $pinning 'Available' $false) -and [bool](Get-GuiValue $pinning 'Supported' $false)
    $pinningStatus = [string](Get-GuiValue $pinning 'Status' 'Unavailable')
    $pinningMessage = [string](Get-GuiValue $pinning 'Message' 'No supported scoped GPU selector has been reported for this executable.')
    $pinningLabel = if ($pinningReady) { 'experimental device creation' } elseif ($pinningStatus -eq 'Unsupported') { 'unsupported executable' } else { 'unavailable' }
    $script:ui.PinningText.Text = 'Scoped GPU selector: ' + $pinningLabel + ' · ' + $pinningMessage
    $script:ui.PinningText.ToolTip = $script:ui.PinningText.Text
    $neuralSession = ($sessionId -and $game.Id -eq $sessionId) -or ($game.IsRunning -and $game.State -eq 'Enabled')
    $freshRuntime = $neuralSession -and [bool](Get-GuiValue $runtime 'Fresh' $false)
    $runtimeBound = $freshRuntime -and [bool](Get-GuiValue $runtime 'BindingVerified' $false)
    $runtimeMismatch = $freshRuntime -and (Get-GuiValue $runtime 'Status' '') -eq 'Mismatch'
    $streaming = $runtimeBound -and [bool](Get-GuiValue $runtime 'Streaming' $false)
    $armed = $runtimeBound -and [bool](Get-GuiValue $runtime 'Armed' $false)
    $script:ui.StateText.Text = if ($neuralSession) {
        if ($runtimeMismatch) { 'GPU binding mismatch' } elseif ($streaming) { 'Neural streaming' } elseif ($armed) { 'Armed · output unverified' } elseif ($runtimeBound) { 'GPU binding verified · not armed' } else { 'Neural output unverified' }
    } elseif ($game.IsRunning -and $game.State -eq 'Disabled') { 'Baseline running · observe GPU' } elseif ($game.IsRunning) { 'Game running · neural output unverified' } elseif ($game.IsManaged) { 'Patched · ' + $game.State } else { 'Not patched' }
    $script:ui.CompatibilityText.Text = 'Runtime compatibility: ' + $game.Compatibility.ToLowerInvariant()
    $bindingStatus = [string](Get-GuiValue $binding 'Status' 'Unknown')
    $bindingMessage = [string](Get-GuiValue $binding 'Message' 'Start a baseline without neural, then observe its game GPU.')
    $script:ui.BindingText.Text = 'Baseline game GPU: ' + $(if ($bindingStatus -eq 'Observed') { 'observed · ' } elseif ($bindingStatus -eq 'Mismatch') { 'mismatch · ' } else { 'unverified · ' }) + $bindingMessage
    $script:ui.BindingText.Foreground = if ($bindingStatus -eq 'Observed') { '#8EEBDD' } else { '#E6D6AE' }
    $runtimeDetail = if ($runtimeMismatch) { 'GPU binding mismatch · ' + (Get-GuiValue $runtime 'Message' '') } elseif ($streaming) { 'streaming confirmed by the current log' } elseif ($armed) { 'armed · gameplay output still unverified' } elseif ($runtimeBound) { 'GPU binding verified · bridge not armed · no neural gameplay confirmed' } elseif ($runtime -and -not $freshRuntime) { 'unverified · ' + (Get-GuiValue $runtime 'Message' 'No current session or fresh log.') } else { 'unverified · no current binding or gameplay evidence' }
    $script:ui.RuntimeText.Text = 'Neural runtime: ' + $runtimeDetail
    $script:ui.RuntimeText.Foreground = if ($runtimeMismatch) { '#FFACA6' } elseif ($streaming -or $runtimeBound) { '#8EEBDD' } else { '#B8CADC' }
    $script:ui.SessionHint.Text = if ($neuralSession -and $runtimeMismatch) { 'Close the game: current GPU binding differs from the configured roles. Actual neural output is not verified.' } elseif ($neuralSession -and $runtimeBound) { 'Current GPU binding matches. Launch uses AutoArm=0. Press Ctrl+Alt+F10 to activate neural when ready. Ctrl+Alt+F7 compares output. AutoArm and injector files are restored after exit.' } elseif ($neuralSession) { 'AutoArm=0 is verified before launch. Wait for fresh GPU binding before manual activation; a loaded model alone does not confirm output.' } elseif ($game.IsRunning -and $game.State -eq 'Disabled') { 'Optional baseline diagnostic: play and Verify game GPU. Close the game before launching with neural.' } elseif ($game.IsRunning) { 'Close the game and recover the managed injector state before launching again.' } elseif ($game.IsManaged -and -not $pinningReady) { 'A supported scoped GPU selector is required before either launch mode. Check its status below.' } else { 'Launch with neural starts the game directly with AutoArm=0. Manual activation instructions appear after current GPU binding is verified. No baseline is required. The runtime status confirms actual output.' }
    if ($game.ArtPath -and (Test-Path -LiteralPath $game.ArtPath -PathType Leaf)) {
        try { $script:ui.GameArtwork.Source = New-Object Windows.Media.Imaging.BitmapImage ([uri]$game.ArtPath) } catch { }
    }
    $script:ui.PatchButton.IsEnabled = -not $busy -and -not $game.IsManaged -and -not $game.IsRunning
    $script:ui.UnpatchButton.IsEnabled = -not $busy -and $game.IsManaged -and -not $game.IsRunning
    $script:ui.LaunchButton.IsEnabled = -not $busy -and $game.IsManaged -and $game.State -eq 'Disabled' -and -not $game.IsRunning -and $pinningReady -and $game.CanLaunchNeural
    $script:ui.BaselineButton.IsEnabled = -not $busy -and $game.IsManaged -and $game.State -eq 'Disabled' -and -not $game.IsRunning -and $pinningReady
    $script:ui.VerifyGpuButton.IsEnabled = -not $busy -and $game.IsManaged -and $game.State -eq 'Disabled' -and $game.IsRunning
    $script:ui.CheckButton.IsEnabled = -not $busy -and $game.IsManaged
    $script:ui.RecoverButton.IsEnabled = -not $busy -and $game.IsManaged -and -not $game.IsRunning
    $script:ui.OpenLogButton.IsEnabled = $game.IsManaged
}
function Update-GuiFilter {
    $selectedId = if ($script:ui.GameList.SelectedItem) { $script:ui.GameList.SelectedItem.Id } else { $null }
    $search = $script:ui.SearchBox.Text.Trim()
    $script:ui.SearchHint.Visibility = if ($search) { 'Collapsed' } else { 'Visible' }
    $filter = $script:ui.FilterBox.SelectedIndex
    $filtered = @($script:games | Where-Object {
        (!$search -or $_.Title.IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
        ($filter -eq 0 -or ($filter -eq 1 -and $_.IsManaged) -or ($filter -eq 2 -and -not $_.IsManaged))
    })
    $script:ui.GameList.ItemsSource = $filtered
    $script:ui.GameCount.Text = '{0} games' -f $filtered.Count
    $script:ui.EmptyLibrary.Visibility = if ($filtered.Count) { 'Collapsed' } else { 'Visible' }
    $selected = @($filtered | Where-Object Id -eq $selectedId | Select-Object -First 1)
    if ($selected.Count) { $script:ui.GameList.SelectedItem = $selected[0] } elseif ($filtered.Count) { $script:ui.GameList.SelectedIndex = 0 }
    Update-GuiSelection
}
function Update-GuiSetup {
    $d = $script:display
    $script:ui.DisplayText.Text = if ($d) { '{0} × {1}  ·  {2} Hz profile' -f $d.Width,$d.Height,$d.RefreshHz } else { 'Display profile unavailable' }
    $rows = @($script:gpus | ForEach-Object {
        $displayActive = [bool](Get-GuiValue $_ 'DisplayActive' $false)
        $uuid = [string](Get-GuiValue $_ 'Uuid')
        $role = if ($uuid -eq (Get-GuiValue $d 'RenderGpuUuid' '_')) { 'Desired game / headless' } elseif ($uuid -eq (Get-GuiValue $d 'NeuralGpuUuid' '_')) { 'Desired neural / display' } elseif ($displayActive) { 'Display attached · role unset' } else { 'Headless · role unset' }
        [pscustomobject]@{ Summary = ('{0} · {1} · PCI {2}' -f (Get-GuiValue $_ 'Name' 'GPU'),$role,(Get-GuiValue $_ 'PciBusId' '?')) }
    })
    $script:ui.GpuList.ItemsSource = $rows
}
function Refresh-GuiLibrary {
    $script:lastLibraryRefresh = [DateTime]::Now
    if ($script:demo) {
        $script:games = @(
            [pscustomobject]@{ Id='preview-cyberpunk'; Title='Cyberpunk 2077'; Executable='D:\SteamLibrary\steamapps\common\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe'; Source='NVIDIA App'; IsManaged=$true; State='Disabled'; Compatibility='Unverified'; RiskAccepted=$true; Pinning=[pscustomobject]@{Available=$false;Supported=$false;Status='Unavailable';Message='Selector readiness has not been established.';Method='MainExeD3D12Import'} },
            [pscustomobject]@{ Id='preview-skyrim'; Title='Skyrim Special Edition'; Executable='D:\SteamLibrary\steamapps\common\Skyrim Special Edition\SkyrimSE.exe'; Source='NVIDIA App'; IsManaged=$false; Compatibility='Unverified' },
            [pscustomobject]@{ Id='preview-witcher'; Title='The Witcher 3'; Executable='D:\Games\The Witcher 3\bin\x64_dx12\witcher3.exe'; Source='NVIDIA App'; IsManaged=$false; Compatibility='Unverified' },
            [pscustomobject]@{ Id='preview-wow'; Title='World of Warcraft'; Executable='D:\Games\World of Warcraft\_retail_\Wow.exe'; Source='NVIDIA App'; IsManaged=$false; Compatibility='Unverified' }
        ) | ForEach-Object { ConvertTo-GuiGame $_ }
        $script:display = [pscustomobject]@{Width=3440;Height=1440;RefreshHz=100;RenderGpuUuid='GPU-preview-render';NeuralGpuUuid='GPU-preview-neural'}
        $script:gpus = @(
            [pscustomobject]@{Name='RTX 3090';Uuid='GPU-preview-render';PciBusId='49:00.0';DisplayActive=$false},
            [pscustomobject]@{Name='RTX 3090';Uuid='GPU-preview-neural';PciBusId='21:00.0';DisplayActive=$true}
        )
    } else {
        try {
            $catalogWarnings = @()
            $script:games = @(Get-NeuralLibraryGames -WarningVariable catalogWarnings -WarningAction SilentlyContinue | Sort-Object @{Expression='IsManaged';Descending=$true},Title | ForEach-Object { ConvertTo-GuiGame $_ })
            foreach ($warning in $catalogWarnings) { Add-GuiActivity ('Library warning: ' + [string]$warning) }
            $script:display = Get-NeuralLibraryDisplay
            $script:gpus = @(Get-NeuralLibraryGpus)
        } catch {
            foreach ($entry in $script:games) { $entry.CanLaunchNeural=$false; $entry.Binding=$null; $entry.Runtime=$null; $entry.Pinning=$null }
            Add-GuiActivity ('Library refresh failed; launch blocked: ' + $_.Exception.Message)
        }
    }
    Update-GuiFilter; Update-GuiSetup
}
function Confirm-GuiRisk($Game, [string]$Action) {
    if ($Game.RiskAccepted -or $Game.Compatibility -ne 'Unverified') { return $true }
    $message = "Game: $($Game.Title)`nExecutable: $($Game.Executable)`n`nDetection does not establish injector compatibility or game-policy permission. This community MGPU experiment injects ReShade and a neural add-on. Begin with an offline, 64-bit DX11/DX12 game; do not use it in online, competitive or anti-cheat-protected games.`n`nI have checked this executable and the game's policy. Continue with $Action?"
    $answer = [Windows.MessageBox]::Show($script:window,$message,'Confirm this game before patching',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning,[Windows.MessageBoxResult]::No)
    return $answer -eq [Windows.MessageBoxResult]::Yes
}
function Start-NeuralGuiAction([string]$Action, [hashtable]$Extra = @{}) {
    if ($script:demo) { Add-GuiActivity ('Preview: ' + $Action + ' is disabled; no system changes.'); return }
    if ($script:activeOperation) { return }
    $game = $script:ui.GameList.SelectedItem
    $globalAction = $Action -in @('StopLocalAI','SaveSettings')
    if (-not $globalAction -and -not $game) { return }
    if ($Action -eq 'Launch' -and -not $script:ui.LaunchButton.IsEnabled) { Add-GuiActivity 'Neural launch blocked. A supported scoped selector, stopped game and valid dependencies/GPU topology are required.'; return }
    if ($Action -eq 'Baseline' -and -not $script:ui.BaselineButton.IsEnabled) { Add-GuiActivity 'Baseline launch blocked. A supported scoped selector and stopped game with the managed neural injector disabled are required.'; return }
    $allow = $false
    if ($Action -in @('Patch','Launch')) {
        if (-not (Confirm-GuiRisk $game $Action)) { Add-GuiActivity "$Action cancelled."; return }
        $allow = $true
    }
    if ($Action -eq 'Unpatch') {
        $answer = [Windows.MessageBox]::Show($script:window,"Remove the managed patch from $($game.Title)?`n`nOnly tracked, unchanged files are removed. Your edited files are preserved by the manager.",'Remove patch',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question,[Windows.MessageBoxResult]::No)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    }
    if ($Action -eq 'StopLocalAI') {
        $answer = [Windows.MessageBox]::Show($script:window,'Stop all local AI workloads to free GPU memory? Any current AI requests will be interrupted.','Free GPU memory',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question,[Windows.MessageBoxResult]::No)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    }
    try {
        $opDir = Join-Path $script:root 'runtime\gui\operations'
        Assert-GuiRegularPath $opDir
        New-Item -ItemType Directory -Path $opDir -Force | Out-Null
        $id = [guid]::NewGuid().ToString('N')
        $requestPath = Join-Path $opDir ($id + '.request.json'); $resultPath = Join-Path $opDir ($id + '.result.json')
        Assert-GuiRegularPath $requestPath
        Assert-GuiRegularPath $resultPath
        $request = @{Action=$Action; GameId=if ($globalAction) { $null } else { $game.Id }; Root=$script:root; AllowUnverified=$allow}
        foreach ($key in $Extra.Keys) { $request[$key] = $Extra[$key] }
        $request | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -Encoding UTF8
        $workerPath = Join-Path $script:root 'scripts\Invoke-NeuralGameAction.ps1'
        if (-not (Test-Path -LiteralPath $workerPath)) { throw 'The action worker is missing. Check the repository installation.' }
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -Sta -ExecutionPolicy Bypass -File "{0}" -RequestPath "{1}" -ResultPath "{2}"' -f $workerPath,$requestPath,$resultPath
        $process = Start-Process -FilePath $psExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        # Keep the native handle so Windows PowerShell can read ExitCode after an early worker exit.
        $null = $process.Handle
        $script:activeOperation = [pscustomobject]@{ Action=$Action; GameId=$request.GameId; ResultPath=$resultPath; Process=$process; Started=[DateTime]::Now; Label=if ($globalAction) { $Action } else { "$Action · $($game.Title)" } }
        $script:ui.OperationText.Text = $script:activeOperation.Label + ' · working…'
        Add-GuiActivity ($script:activeOperation.Label + ' started.')
        Update-GuiSelection
    } catch { Add-GuiActivity ('Action could not start: ' + $_.Exception.Message) }
}
function Open-GuiFile([string]$Path) {
    if ($script:demo) { Add-GuiActivity ('Preview: open ' + $Path); return }
    try { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File is not available: $Path" }; Start-Process -FilePath $Path | Out-Null } catch { Add-GuiActivity $_.Exception.Message }
}
function Show-GuiGuide {
    $guide = @'
Get-NeuralGpus                         Inspect the physical GPUs
Get-NeuralGameStatus -Name <game>      Read state and actual runtime evidence
Get-NeuralGamePinning -Name <game>     Inspect experimental scoped selector readiness
Test-NeuralGameSetup -Name <game>      Check dependencies and the launch gate
Install-NeuralGame -Name <game> ...    Patch (stages files disabled)
Start-NeuralGameBaseline -Name <game>  Start with selector; neural DLLs disabled
Confirm-NeuralGameGpu -Name <game>     Observe the running baseline GPU
Start-NeuralGame -Name <game>          Launch with session cleanup
Stop-NeuralGame -Name <game>           Recover after closing the game
Uninstall-NeuralGame -Name <game>      Remove unchanged managed files
Stop-LocalAIAll                       Explicitly free both GPUs
Show-NeuralGaming                     Open this library

AutoArm=0    Verified before Launch with neural; activation is manual
Ctrl+Alt+F10  Toggle neural activation after current GPU binding matches
Ctrl+Alt+F7   Compare neural, input and split output
Home         Open ReShade

The scoped selector attempts GPU device selection only in this process.
Launch with neural starts directly; baseline verification is optional.
AutoArm and injector files are restored after exit. Steam launches after
cleanup retain normal GPU selection. Recover handles an interrupted session.
Game activity, model loading and initial probes do not prove neural output.
Read the README for installation parameters, pinned packages and recovery.
'@
    [Windows.MessageBox]::Show($script:window,$guide,'PowerShell command guide',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Information) | Out-Null
}
function Show-GuiSettings {
    [xml]$settingsMarkup = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Neural Gaming — Settings" Width="600" Height="490" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#101827" Foreground="#F0F3FC" FontFamily="Segoe UI">
 <StackPanel Margin="24"><TextBlock Text="Desired GPU roles and display profile" FontSize="22" FontWeight="SemiBold" /><TextBlock Text="Explicit launches use an experimental selector for the requested headless card. Verify the baseline and the new session log." TextWrapping="Wrap" Foreground="#AFBDD3" Margin="0,10,0,18" />
  <TextBlock Text="Desired game GPU (headless)" Margin="0,0,0,5" /><ComboBox x:Name="RenderChoice" DisplayMemberPath="Label" SelectedValuePath="Uuid" Height="32" />
  <TextBlock Text="Desired neural GPU (display attached)" Margin="0,12,0,5" /><ComboBox x:Name="NeuralChoice" DisplayMemberPath="Label" SelectedValuePath="Uuid" Height="32" />
  <TextBlock Text="Display target: width / height / refresh Hz" Margin="0,16,0,7" /><UniformGrid Columns="3"><TextBox x:Name="WidthInput" Margin="0,0,8,0" Padding="8" /><TextBox x:Name="HeightInput" Margin="0,0,8,0" Padding="8" /><TextBox x:Name="RefreshInput" Padding="8" /></UniformGrid>
  <TextBlock Text="This does not alter Windows graphics preferences, game video settings, drivers or security settings." TextWrapping="Wrap" Foreground="#AFBDD3" Margin="0,14,0,15" />
  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="WindowsSettings" Content="Windows graphics" Padding="12,8" Margin="0,0,8,0" /><Button x:Name="SaveSettings" Content="Save profile" Padding="16,8" IsDefault="True" Margin="0,0,8,0" /><Button Content="Close" IsCancel="True" Padding="12,8" /></StackPanel>
 </StackPanel>
</Window>
'@
    $settingsReader = New-Object Xml.XmlNodeReader $settingsMarkup
    try { $dialog = [Windows.Markup.XamlReader]::Load($settingsReader) } finally { $settingsReader.Close() }
    $dialog.Owner = $script:window
    $render = $dialog.FindName('RenderChoice'); $neural = $dialog.FindName('NeuralChoice')
    $choices = @($script:gpus | ForEach-Object { [pscustomobject]@{Uuid=Get-GuiValue $_ 'Uuid';Label=('{0} · PCI {1} · {2}' -f $_.Name,(Get-GuiValue $_ 'PciBusId' '?'),(Get-GuiValue $_ 'Uuid' '?'))} })
    $render.ItemsSource = $choices; $neural.ItemsSource = $choices
    $render.SelectedValue = Get-GuiValue $script:display 'RenderGpuUuid'; $neural.SelectedValue = Get-GuiValue $script:display 'NeuralGpuUuid'
    $width = $dialog.FindName('WidthInput'); $height = $dialog.FindName('HeightInput'); $refresh = $dialog.FindName('RefreshInput')
    $width.Text = [string](Get-GuiValue $script:display 'Width' 3440); $height.Text = [string](Get-GuiValue $script:display 'Height' 1440); $refresh.Text = [string](Get-GuiValue $script:display 'RefreshHz' 100)
    $dialog.FindName('WindowsSettings').Add_Click({ if ($script:demo) { Add-GuiActivity 'Preview: Windows graphics settings.' } else { Start-Process 'ms-settings:display-advancedgraphics' } })
    $save = {
        $w=0; $h=0; $hz=0
        if (-not [int]::TryParse($width.Text,[ref]$w) -or -not [int]::TryParse($height.Text,[ref]$h) -or -not [int]::TryParse($refresh.Text,[ref]$hz) -or $w -lt 640 -or $w -gt 16384 -or $h -lt 480 -or $h -gt 16384 -or $hz -lt 24 -or $hz -gt 1000) {
            [Windows.MessageBox]::Show($dialog,'Enter a width (640–16384), height (480–16384) and refresh rate (24–1000 Hz).','Review display profile') | Out-Null; return
        }
        if (-not $render.SelectedValue -or -not $neural.SelectedValue -or $render.SelectedValue -eq $neural.SelectedValue) { [Windows.MessageBox]::Show($dialog,'Select two distinct GPUs.','Review GPU roles') | Out-Null; return }
        Start-NeuralGuiAction -Action SaveSettings -Extra @{RenderGpuUuid=[string]$render.SelectedValue;NeuralGpuUuid=[string]$neural.SelectedValue;Width=$w;Height=$h;RefreshHz=$hz}
        $dialog.Close()
    }.GetNewClosure()
    $dialog.FindName('SaveSettings').Add_Click($save)
    $dialog.ShowDialog() | Out-Null
}
$script:ui.SearchBox.Add_TextChanged({ Update-GuiFilter })
$script:ui.FilterBox.Add_SelectionChanged({ Update-GuiFilter })
$script:ui.GameList.Add_SelectionChanged({ Update-GuiSelection })
$script:ui.RefreshButton.Add_Click({ Refresh-GuiLibrary; Add-GuiActivity 'Library refreshed.' })
$script:ui.PatchButton.Add_Click({ Start-NeuralGuiAction 'Patch' })
$script:ui.UnpatchButton.Add_Click({ Start-NeuralGuiAction 'Unpatch' })
$script:ui.CheckButton.Add_Click({ Start-NeuralGuiAction 'Check' })
$script:ui.BaselineButton.Add_Click({ Start-NeuralGuiAction 'Baseline' })
$script:ui.VerifyGpuButton.Add_Click({ Start-NeuralGuiAction 'VerifyGpu' })
$script:ui.WindowsGpuButton.Add_Click({ if ($script:demo) { Add-GuiActivity 'Preview: Windows graphics settings.' } else { try { Start-Process 'ms-settings:display-advancedgraphics' | Out-Null } catch { Add-GuiActivity $_.Exception.Message } } })
$script:ui.LaunchButton.Add_Click({ Start-NeuralGuiAction 'Launch' })
$script:ui.RecoverButton.Add_Click({ Start-NeuralGuiAction 'Stop' })
$script:ui.FreeGpuButton.Add_Click({ Start-NeuralGuiAction 'StopLocalAI' })
$script:ui.GuideButton.Add_Click({ Show-GuiGuide })
$script:ui.SettingsButton.Add_Click({ Show-GuiSettings })
$script:ui.OpenConfigButton.Add_Click({ Open-GuiFile (Join-Path $script:root 'runtime\config.json') })
$script:ui.ReadmeButton.Add_Click({ Open-GuiFile (Join-Path $script:root 'README.md') })
$script:ui.OpenLogButton.Add_Click({ $game=$script:ui.GameList.SelectedItem; if ($game) { Open-GuiFile (Join-Path (Split-Path $game.Executable -Parent) 'ReShade.log') } })
$script:ui.AddButton.Add_Click({
    if ($script:demo) { Add-GuiActivity 'Preview: add game is disabled.'; return }
    $picker = New-Object Microsoft.Win32.OpenFileDialog
    $picker.Title = 'Select the game executable'; $picker.Filter = 'Game executable (*.exe)|*.exe'; $picker.CheckFileExists=$true; $picker.Multiselect=$false
    if ($picker.ShowDialog($script:window)) {
        try { $title=[IO.Path]::GetFileNameWithoutExtension($picker.FileName); Register-NeuralLibraryGame -Title $title -Executable $picker.FileName | Out-Null; Refresh-GuiLibrary; Add-GuiActivity ('Added ' + $title + '. Compatibility remains unverified.') } catch { Add-GuiActivity $_.Exception.Message }
    }
})
$script:timer = New-Object Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:timer.Add_Tick({
    $op = $script:activeOperation
    $refreshInterval = if ($op -and $op.Action -eq 'Launch') { 3 } else { 5 }
    if (-not $script:demo -and ((-not $op) -or $op.Action -eq 'Launch') -and ([DateTime]::Now - $script:lastLibraryRefresh).TotalSeconds -ge $refreshInterval) { Refresh-GuiLibrary }
    if (-not $op) { return }
    if (Test-Path -LiteralPath $op.ResultPath -PathType Leaf) {
        try {
            $result = Get-Content -LiteralPath $op.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $message = [string](Get-GuiValue $result 'Message' 'Action completed.')
            Add-GuiActivity ($(if ($result.Success) { 'OK: ' } else { 'FAILED: ' }) + $message)
            $data = Get-GuiValue $result 'Data'
            if ($data) {
                foreach ($issue in @(Get-GuiValue $data 'Issues' @())) { Add-GuiActivity ('Issue: ' + $issue) }
                foreach ($warning in @(Get-GuiValue $data 'Warnings' @())) { Add-GuiActivity ('Note: ' + $warning) }
            }
            $script:activeOperation = $null; $script:ui.OperationText.Text = if ($result.Success) { 'Completed · ' + $op.Action } else { 'Action needs attention · ' + $op.Action }
            Refresh-GuiLibrary
        } catch { if ($op.Process.HasExited) { Add-GuiActivity ('Unreadable result: ' + $_.Exception.Message); $script:activeOperation=$null; Update-GuiSelection } }
    } elseif ($op.Process.HasExited) {
        Add-GuiActivity ('Worker exited without a result (exit ' + $op.Process.ExitCode + '). Check runtime logs before retrying.')
        $script:activeOperation = $null; $script:ui.OperationText.Text='Action needs attention'; Refresh-GuiLibrary
    } else {
        $elapsed = [int]([DateTime]::Now - $op.Started).TotalSeconds
        $script:ui.OperationText.Text = $op.Label + $(if ($op.Action -eq 'Launch') { ' · monitoring game / runtime evidence · ' } else { ' · working · ' }) + $elapsed + 's'
    }
})
$script:window.Add_Closing({
    if ($script:activeOperation) {
        $message = if ($script:activeOperation.Action -eq 'Launch') { 'The game session will continue. Its worker remains running and will disable the injector after the game exits. Close this library?' } else { 'An action is still running. It will continue in its worker. Close this library?' }
        if ([Windows.MessageBox]::Show($script:window,$message,'Action in progress',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Information,[Windows.MessageBoxResult]::No) -ne [Windows.MessageBoxResult]::Yes) { $_.Cancel=$true }
    }
})
$script:window.Add_Closed({ $script:timer.Stop() })
if (-not $script:demo) {
    try { Import-Module (Join-Path $script:root 'powershell\NeuralGaming.Library.psm1') -Force -DisableNameChecking } catch { Add-GuiActivity ('Library module unavailable: ' + $_.Exception.Message) }
}
Refresh-GuiLibrary
Add-GuiActivity $(if ($script:demo) { 'Preview data · no patch, launch or system changes are performed.' } else { 'Ready. Select a game; patching and launch are explicit actions.' })
$script:timer.Start()
if ($SmokeTest -or $ScreenshotPath) {
    $script:window.WindowStartupLocation='Manual'; $script:window.Left=-10000; $script:window.Top=-10000
    $script:window.Show(); $script:window.UpdateLayout()
    $script:window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
    if ($ScreenshotPath) {
        $target = [IO.Path]::GetFullPath($ScreenshotPath)
        $surface = $script:window.Content
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$surface.ActualWidth),([int]$surface.ActualHeight),96,96,([Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($surface)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Create($target)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        Write-Output ('Preview saved: ' + $target)
    }
    $script:window.Close()
    Write-Output 'PASS: WPF library loaded, rendered and closed without invoking real actions.'
} else {
    $script:window.Add_ContentRendered({ $script:ui.SearchBox.Focus() | Out-Null })
    $script:window.ShowDialog() | Out-Null
}
