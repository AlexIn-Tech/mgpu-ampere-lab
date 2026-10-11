[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Initialize-NeuralPowerShell.ps1"
$root=Split-Path $PSScriptRoot -Parent
# Operation files are data in one local directory, never arbitrary output targets.
function Assert-WorkerPath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $prefix=[IO.Path]::GetFullPath((Join-Path $root 'runtime\gui\operations')).TrimEnd('\')+'\'
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Worker files must stay within runtime\gui\operations.' }
    $current=$full
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Worker reparse-point path refused.' }
        $current=Split-Path $current -Parent
    }
    return $full
}
$RequestPath=Assert-WorkerPath $RequestPath
$ResultPath=Assert-WorkerPath $ResultPath
if ($RequestPath -ieq $ResultPath -or (Test-Path -LiteralPath $ResultPath)) { throw 'Use distinct request and new result files for each operation.' }
$result=$null; $exitCode=0
try {
    if ((Get-Item -LiteralPath $RequestPath).Length -gt 65536) { throw 'Worker request is too large.' }
    $request=Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    if (-not $request.Root -or [IO.Path]::GetFullPath($request.Root).TrimEnd('\') -ine [IO.Path]::GetFullPath($root).TrimEnd('\')) { throw 'Worker request must target this installation.' }
    $env:NEURAL_GAMING_ROOT=$root
    Import-Module (Join-Path $root 'powershell\NeuralGaming.Library.psm1') -Force
    $data=$null
    switch ([string]$request.Action) {
        'SaveSettings' {
            $data=Set-NeuralLibrarySettings -RenderGpuUuid $request.RenderGpuUuid -NeuralGpuUuid $request.NeuralGpuUuid -Width $request.Width -Height $request.Height -RefreshHz $request.RefreshHz
            $message='Saved GPU roles and display profile. Apply game resolution and Windows GPU selection separately.'
        }
        'StopLocalAI' {
            Import-Module 'C:\AI\LocalAI\LocalAI.psm1' -Force
            Stop-LocalAIAll | Out-Null
            $message='Local AI services stopped to free GPU memory.'
        }
        { $_ -in @('Patch','Unpatch','Check','Launch','Stop','Baseline','VerifyGpu') } {
            $accepted=$request.PSObject.Properties['AllowUnverified'] -and [bool]$request.AllowUnverified
            $data=Invoke-NeuralLibraryAction -Action $request.Action -GameId $request.GameId -AllowUnverified:$accepted
            $message=switch ($request.Action) {
                'Patch' {'Patch staged and disabled. Use Check before a managed launch.'}
                'Unpatch' {'Removed unchanged owned patch files.'}
                'Launch' {'Game session ended. Injector cleanup completed.'}
                'Baseline' {'Baseline started without the managed injectors. Play, verify its game GPU, then close the game.'}
                'VerifyGpu' {$data.Message}
                'Stop' {'Recovered inactive injector state.'}
                'Check' { if ($data.Ready) {'Dependencies and baseline observation passed. Fresh bridge binding and live neural output still need verification.'} else {'Launch blocked: '+($data.Issues -join '; ')} }
            }
        }
        default { throw 'Unsupported worker action.' }
    }
    $result=[pscustomobject]@{Success=$true;Message=$message;Data=$data}
} catch {
    $exitCode=1
    $result=[pscustomobject]@{Success=$false;Message=$_.Exception.Message;Data=$null}
} finally {
    $folder=Split-Path ([IO.Path]::GetFullPath($ResultPath)) -Parent
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $temp=$ResultPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($result | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp,$ResultPath)
}
exit $exitCode
