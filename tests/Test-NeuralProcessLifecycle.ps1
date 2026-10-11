$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'powershell\NeuralGaming.psm1') -Force
$module = Get-Module NeuralGaming
& $module {
    # Control enumeration/path lookup to reproduce an exit between those two OS calls.
    $script:FixtureProcess = [pscustomobject]@{Id=2147483647;Path=$null}
    function script:Get-Process {
        [CmdletBinding()] param([string]$Name, [int]$Id)
        if ($Name) { return $script:FixtureProcess }
        Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction Stop
    }
    function script:Get-NeuralProcessPath { param($ProcessId) throw 'Process executable path unavailable.' }
    $manifest = [pscustomobject]@{Executable='C:\FixtureGame.exe'}
    try {
        $rows = @(Get-NeuralGameProcesses $manifest)
        if ($rows.Count) { throw 'Exited process must not count as running.' }
    } catch { throw ('FAIL: process exit during path lookup must be ignored: ' + $_.Exception.Message) }
    Write-Output 'PASS: process exit during path lookup is ignored'

    $script:FixtureProcess.Id = $PID
    $blocked = $false
    try { Get-NeuralGameProcesses $manifest | Out-Null } catch { $blocked = $true }
    if (-not $blocked) { throw 'FAIL: a live process with unreadable identity must block file changes.' }
    Write-Output 'PASS: unreadable live process identity still blocks file changes'

    $script:FixtureProcess.Path = 'C:\OtherGame.exe'
    if (@(Get-NeuralGameProcesses $manifest).Count) { throw 'FAIL: same name with a different executable must be excluded.' }
    $script:FixtureProcess.Path = 'C:\FixtureGame.exe'
    if (@(Get-NeuralGameProcesses $manifest).Count -ne 1) { throw 'FAIL: matching running executable must be included.' }
    Write-Output 'PASS: running processes require matching executable identity'
}
