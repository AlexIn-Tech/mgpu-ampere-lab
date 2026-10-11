param([switch]$SkipSmoke, [switch]$WpfOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
$root = Split-Path $PSScriptRoot -Parent
$xamlPath = Join-Path $root 'gui\NeuralGaming.xaml'
$scriptPath = Join-Path $root 'gui\Show-NeuralGaming.ps1'
Assert-True (Test-Path -LiteralPath $xamlPath) 'Native game library XAML exists'
Assert-True (Test-Path -LiteralPath $scriptPath) 'GUI launcher exists'
if ($WpfOnly) {
    function global:Start-Process { throw 'Smoke test attempted to start a real process' }
    try {
        $priorOverride=$env:NEURAL_GAMING_ROOT; $overrideRefused=$false
        try {
            $env:NEURAL_GAMING_ROOT=Join-Path $root 'runtime\alternate-gui-state'
            try { . $scriptPath -SmokeTest } catch { $overrideRefused=$_.Exception.Message -match 'installed repository state|alternate.*root' }
        } finally { $env:NEURAL_GAMING_ROOT=$priorOverride }
        Assert-True $overrideRefused 'GUI refuses an alternate state root before reading or displaying it'
        $env:NEURAL_GAMING_ROOT=$root
        . $scriptPath -SmokeTest
        $installedRoot=$script:root
        $securityFixture=Join-Path (Join-Path $installedRoot 'runtime') ('gui-security-' + [guid]::NewGuid().ToString('N'))
        $operationsLink=Join-Path $securityFixture 'runtime\gui\operations'
        $blockedAncestor=Split-Path $operationsLink -Parent
        try {
            New-Item -ItemType Directory -Path $operationsLink -Force | Out-Null
            # The execution sandbox disallows native junction creation. Substitute only the OS
            # metadata boundary; request creation and the full ancestor walk remain real.
            function global:Get-Item {
                [CmdletBinding()] param([string]$LiteralPath,[switch]$Force)
                if ($LiteralPath -eq $script:blockedAncestor) { return [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint} }
                Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
            }
            $script:root=$securityFixture; $script:demo=$false
            Start-NeuralGuiAction SaveSettings
            Assert-True (@(Get-ChildItem -LiteralPath $operationsLink -Force).Count -eq 0) 'Linked operations ancestor is refused before any request write'
            Assert-True ($script:activity[$script:activity.Count-1] -like '*Reparse-point*') 'Operations guard identifies the existing linked ancestor'
        } finally {
            $script:root=$installedRoot; $script:demo=$true
            Remove-Item Function:\Get-Item -ErrorAction SilentlyContinue
            $fixtureFull=[IO.Path]::GetFullPath($securityFixture)
            $allowedPrefix=[IO.Path]::GetFullPath((Join-Path $installedRoot 'runtime')).TrimEnd('\') + '\'
            if ($fixtureFull.StartsWith($allowedPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $fixtureFull -Leaf) -like 'gui-security-*') { Remove-Item -LiteralPath $fixtureFull -Recurse -Force }
        }
        Assert-True ($script:ui.GameList.Items.Count -eq 4) 'Representative library binds to the real ListBox'
        Assert-True (-not $script:ui.LaunchButton.IsEnabled) 'Managed disabled game with unknown physical binding cannot launch neural'
        Assert-True (-not $script:ui.BaselineButton.IsEnabled) 'Preview with unavailable scoped pinning blocks baseline launch'
        Assert-True (-not $script:ui.VerifyGpuButton.IsEnabled) 'GPU observation requires a running baseline game'
        Assert-True (-not $script:ui.PatchButton.IsEnabled) 'Managed game cannot be patched again'
        $sessionGame=$script:ui.GameList.SelectedItem
        Assert-True ($script:ui.PinningText.Text -match 'unavailable|unverified') 'Unavailable scoped GPU selector is visibly explained'
        $readyPinning=[pscustomobject]@{Available=$true;Supported=$true;Status='ExperimentalReady';Message='Per-process main-executable D3D12 import selector available';Method='MainExeD3D12Import';TargetLuid='00000000-00000001'}
        $sessionGame | Add-Member -NotePropertyName Pinning -NotePropertyValue $readyPinning -Force
        Update-GuiSelection
        Assert-True $script:ui.BaselineButton.IsEnabled 'Managed disabled game with available supported selector offers the explicit baseline attempt'
        Assert-True ($script:ui.PinningText.Text -match 'experimental' -and $script:ui.PinningText.Text -notmatch 'forced|verified') 'Selector readiness is experimental rather than proof of actual GPU binding'
        Assert-True ($script:ui.BaselineButton.ToolTip -match 'process|scoped' -and $script:ui.BaselineButton.ToolTip -match 'selector') 'Baseline tooltip discloses its scoped per-process selector'
        Assert-True ($script:ui.BindingText.Text -match 'unverified|unknown|baseline') 'Unknown GPU binding is visibly explained'
        $sessionGame.CanLaunchNeural=$true
        Update-GuiSelection
        Assert-True $script:ui.LaunchButton.IsEnabled 'Direct launch is available without a baseline lease when preflight and selector are ready'
        $sessionGame.Binding=[pscustomobject]@{Status='Mismatch';CanLaunch=$false;Message='Game observed on display GPU';RenderLuid='00000000-00000001';NeuralLuid='00000000-00000002';ObservedRenderUuid='GPU-preview-neural'}
        Update-GuiSelection
        Assert-True $script:ui.LaunchButton.IsEnabled 'Optional historical baseline mismatch does not block a new direct neural launch'
        $sessionGame.Binding=[pscustomobject]@{Status='Observed';CanLaunch=$true;Message='Baseline observed on headless GPU';RenderLuid='00000000-00000001';NeuralLuid='00000000-00000002';ObservedRenderUuid='GPU-preview-render'}
        Update-GuiSelection
        Assert-True $script:ui.LaunchButton.IsEnabled 'A managed stopped game with valid baseline evidence offers neural launch'
        foreach ($unusablePinning in @($null,[pscustomobject]@{Available=$false;Supported=$true;Status='Unavailable';Message='Selector binary unavailable';Method='MainExeD3D12Import'},[pscustomobject]@{Available=$true;Supported=$false;Status='Unsupported';Message='Executable does not expose the supported import';Method='MainExeD3D12Import'})) {
            $sessionGame.Pinning=$unusablePinning
            Update-GuiSelection
            Assert-True (-not $script:ui.LaunchButton.IsEnabled -and -not $script:ui.BaselineButton.IsEnabled) 'Missing, unavailable or unsupported selector blocks both launch modes despite positive baseline evidence'
        }
        try {
            $script:demo=$false
            Start-NeuralGuiAction 'Baseline'
            Assert-True ($script:activity[$script:activity.Count-1] -like '*Baseline launch blocked*') 'Unavailable selector refuses baseline before worker creation even if an action is directly invoked'
            Start-NeuralGuiAction 'Launch'
            Assert-True ($script:activity[$script:activity.Count-1] -like '*Neural launch blocked*') 'Unavailable selector refuses neural launch before worker creation'
        } finally { $script:demo=$true }
        $sessionGame.Pinning=$readyPinning
        Update-GuiSelection
        Assert-True ($script:ui.LaunchButton.IsEnabled -and $script:ui.BaselineButton.IsEnabled) 'Both launch modes return after selector readiness is explicitly reported'
        $sessionGame.State='Enabled'
        Update-GuiSelection
        Assert-True (-not $script:ui.LaunchButton.IsEnabled -and -not $script:ui.BaselineButton.IsEnabled) 'Enabled injector requires recovery before either launch mode'
        $sessionGame.State='Disabled'
        $sessionGame.IsRunning=$true
        Update-GuiSelection
        Assert-True (-not $script:ui.LaunchButton.IsEnabled -and -not $script:ui.BaselineButton.IsEnabled -and $script:ui.VerifyGpuButton.IsEnabled) 'Running disabled baseline offers GPU verification and blocks second launch'
        $sessionGame.State='Inconsistent'
        Update-GuiSelection
        Assert-True ($script:ui.StateText.Text -match 'unverified' -and -not $script:ui.VerifyGpuButton.IsEnabled) 'Uncertain injector state cannot be described as a baseline without neural'
        $sessionGame.State='Disabled'
        $sessionGame.IsRunning=$false
        try {
            $script:activeOperation=[pscustomobject]@{Action='Launch';GameId=$sessionGame.Id}
            Update-GuiSelection
            Assert-True ($script:ui.StateText.Text -match 'unverified' -and $script:ui.StateText.Text -notmatch 'active') 'A launch worker does not imply verified neural rendering'
            Assert-True ($sessionGame.StatusLabel -match 'unverified' -and $sessionGame.StatusLabel -notmatch 'Disabled') 'Library row replaces its stale disabled snapshot without claiming neural output'
            $sessionGame.Runtime=[pscustomobject]@{Status='Bound';Fresh=$false;BindingVerified=$true;Armed=$false;Streaming=$false;Message='Historical log';RenderLuid='00000000-00000001';NeuralLuid='00000000-00000002'}
            Update-GuiSelection
            Assert-True ($script:ui.RuntimeText.Text -match 'unverified|historical|stale' -and $script:ui.SessionHint.Text -notmatch 'Ctrl\+Alt\+F10') 'Historical binding cannot authorize arming the current session'
            $sessionGame.Runtime.Fresh=$true
            Update-GuiSelection
            Assert-True ($script:ui.RuntimeText.Text -match 'not armed|unarmed' -and $script:ui.SessionHint.Text -match 'Ctrl\+Alt\+F10' -and $script:ui.SessionHint.Text -match 'AutoArm=0') 'Bound but unarmed session offers manual activation with AutoArm disabled'
            $sessionGame.Runtime.Status='Streaming'; $sessionGame.Runtime.Armed=$true; $sessionGame.Runtime.Streaming=$true
            Update-GuiSelection
            Assert-True ($script:ui.RuntimeText.Text -match 'stream' -and $script:ui.StateText.Text -match 'stream') 'Neural streaming label requires fresh positive runtime evidence'
            $sessionGame.Runtime.BindingVerified=$false
            Update-GuiSelection
            Assert-True ($script:ui.StateText.Text -notmatch 'stream' -and $script:ui.SessionHint.Text -notmatch 'Ctrl\+Alt\+F10') 'Unverified adapter binding overrides a contradictory streaming flag'
            $sessionGame.Runtime=[pscustomobject]@{Status='Mismatch';Fresh=$true;BindingVerified=$false;Armed=$false;Streaming=$false;Message='Actual game/display binding inverted';RenderLuid='00000000-00000002';NeuralLuid='00000000-00000001'}
            Update-GuiSelection
            Assert-True ($script:ui.RuntimeText.Text -match 'mismatch' -and $script:ui.SessionHint.Text -match 'Close the game' -and $script:ui.SessionHint.Text -notmatch 'Ctrl\+Alt\+F10') 'Actual routing mismatch explicitly asks to close the game without suggesting arming'
        } finally { $script:activeOperation=$null; Update-GuiSelection }
        $sessionGame.Runtime=[pscustomobject]@{Status='Streaming';Fresh=$true;BindingVerified=$true;Armed=$true;Streaming=$true;Message='Previous session output';RenderLuid='00000000-00000001';NeuralLuid='00000000-00000002'}
        Update-GuiSelection
        Assert-True ($script:ui.RuntimeText.Text -notmatch 'streaming confirmed' -and $script:ui.SessionHint.Text -notmatch 'Ctrl\+Alt\+F10') 'A stopped game cannot appear to be producing neural output even with a stale positive DTO'
        $sessionGame.Runtime=$null
        Assert-True ($script:ui.StateText.Text -like '*Disabled*' -and $sessionGame.StatusLabel -like '*Disabled*') 'Session labels restore the normal snapshot when the worker finishes'
        $script:ui.SearchBox.Text = 'witcher'
        Assert-True ($script:ui.GameList.Items.Count -eq 1 -and $script:ui.GameTitle.Text -eq 'The Witcher 3') 'Search changes visible library and selected-game details'
        Assert-True ($script:ui.PatchButton.IsEnabled -and -not $script:ui.LaunchButton.IsEnabled) 'Detected unpatched game offers patch and does not offer neural launch'
        Assert-True (-not $script:ui.BaselineButton.IsEnabled -and -not $script:ui.VerifyGpuButton.IsEnabled) 'Unmanaged game cannot enter the managed GPU verification workflow'
        $script:ui.SearchBox.Text = ''
        $script:ui.FilterBox.SelectedIndex = 1
        Assert-True ($script:ui.GameList.Items.Count -eq 1) 'Patched filter shows only managed games'
        foreach ($mapping in @(@('LaunchButton','Launch'),@('BaselineButton','Baseline'),@('VerifyGpuButton','VerifyGpu'),@('UnpatchButton','Unpatch'),@('CheckButton','Check'),@('RecoverButton','Stop'),@('FreeGpuButton','StopLocalAI'))) {
            $script:ui[$mapping[0]].RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
            Assert-True ($script:activity[$script:activity.Count-1] -like ('*Preview: ' + $mapping[1] + ' is disabled*')) ('Actual click routes ' + $mapping[0] + ' to ' + $mapping[1])
        }
        $script:ui.FilterBox.SelectedIndex = 2
        Assert-True ($script:ui.GameList.Items.Count -eq 3) 'Unpatched filter shows discovered unpatched games'
        $script:ui.PatchButton.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
        Assert-True ($script:activity[$script:activity.Count-1] -like '*Preview: Patch is disabled*') 'Actual Patch click routes correctly and preview remains inert'
        $script:ui.SearchBox.Text='no-game-matches-this'
        Assert-True ($script:ui.GameList.Items.Count -eq 0 -and -not $script:ui.LaunchButton.IsEnabled) 'Empty search leaves launch disabled'
        Assert-True (-not $script:ui.BaselineButton.IsEnabled -and -not $script:ui.VerifyGpuButton.IsEnabled) 'Empty search leaves GPU workflow actions disabled'
        $settingsHost = New-Object Windows.Window
        $settingsHost.WindowStartupLocation='Manual'; $settingsHost.Left=-10000; $settingsHost.Top=-10000; $settingsHost.Show()
        $script:window=$settingsHost
        $script:settingsVerified=$false; $script:settingsError=$null
        $settingsTimer=New-Object Windows.Threading.DispatcherTimer
        $settingsTimer.Interval=[TimeSpan]::FromMilliseconds(100)
        $settingsTimer.Add_Tick({
            foreach ($surface in [Windows.PresentationSource]::CurrentSources) {
                $modal=$surface.RootVisual
                if ($modal -is [Windows.Window] -and $modal.Title -eq 'Neural Gaming — Settings') {
                    try {
                        Assert-True ($modal.FindName('RenderChoice').Items.Count -eq 2) 'Settings populates both actual GPU choices'
                        $modal.FindName('RenderChoice').SelectedIndex=0; $modal.FindName('NeuralChoice').SelectedIndex=1
                        Assert-True ($modal.FindName('WidthInput').Text -eq '3440' -and $modal.FindName('RefreshInput').Text -eq '100') 'Settings displays the requested screen profile'
                        $modal.FindName('SaveSettings').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
                        $script:settingsVerified=$script:activity[$script:activity.Count-1] -like '*Preview: SaveSettings is disabled*'
                    } catch { $script:settingsError=$_.Exception.Message; $modal.Close() }
                    return
                }
            }
        })
        try { $settingsTimer.Start(); Show-GuiSettings } finally { $settingsTimer.Stop(); $settingsHost.Close() }
        Assert-True ($script:settingsVerified -and -not $script:settingsError) ('Real settings dialog populates, routes SaveSettings and closes: ' + $script:settingsError)
        Write-Output 'PASS: real WPF search, filter, selection, button routing and inert preview'
    } finally { Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue }
    exit 0
}
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'GUI launcher parses without errors'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$names = @($xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') })
foreach ($name in @('GameList','SearchBox','FilterBox','RefreshButton','AddButton','LaunchButton','BaselineButton','VerifyGpuButton','WindowsGpuButton','BindingText','RuntimeText','PinningText','PatchButton','UnpatchButton','CheckButton','RecoverButton','FreeGpuButton','GuideButton','SettingsButton','OpenLogButton','OpenConfigButton','ReadmeButton','ActivityList','GameTitle','ExecutableText','StateText','DisplayText','GpuList')) {
    Assert-True ($names -contains $name) "Visible, addressable control: $name"
}
$source = $ast.Extent.Text
Assert-True ($source -match 'DispatcherTimer' -and $source -match 'ResultPath') 'Actions poll worker results on the WPF dispatcher'
Assert-True ($source -match 'AllowUnverified' -and $source -match 'MessageBoxResult\]::Yes') 'Unverified operations require affirmative consent'
Assert-True ($source -match 'WindowStyle Hidden') 'Worker processes are hidden'
Assert-True ($source -notmatch 'WaitForExit\(') 'The window does not block waiting for a launched game'
Assert-True ($source -match 'Register-NeuralLibraryGame' -and $source -match 'OpenFileDialog') 'Manual add chooses an executable and registers through the library'
Assert-True ($source -match 'Get-NeuralGamePinning') 'Command guide includes the scoped GPU pinning readiness query'
Write-Output 'PASS: XAML and GUI contract'
if (-not $SkipSmoke) {
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $outputBase = Join-Path ([IO.Path]::GetTempPath()) ('neural-gui-' + [guid]::NewGuid().ToString('N'))
    $stdout = $outputBase + '.out.txt'; $stderr = $outputBase + '.err.txt'
    $process = $null
    try {
        $arguments = '-NoProfile -Sta -ExecutionPolicy Bypass -File "{0}" -WpfOnly' -f $PSCommandPath
        $process = Start-Process $psExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        if (-not $process.WaitForExit(20000)) { $process.Kill(); throw 'FAIL: WPF smoke test exceeded 20 seconds.' }
        $process.WaitForExit()
        $process.Refresh()
        if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout }
        if (Test-Path -LiteralPath $stderr) { $errors = Get-Content -LiteralPath $stderr -Raw; if ($errors) { Write-Output $errors } }
        Assert-True ($process.ExitCode -eq 0) 'Real WPF load and harmless smoke test pass'
    } finally {
        if ($process) { $process.Dispose() }
        foreach ($path in @($stdout,$stderr)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
    }
}
Write-Output 'All NeuralGaming GUI tests passed.'
