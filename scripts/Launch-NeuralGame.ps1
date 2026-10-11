[CmdletBinding(DefaultParameterSetName='Name')]
param(
    [Parameter(ParameterSetName='Name')][string]$Name='Cyberpunk2077',
    [Parameter(Mandatory,ParameterSetName='Library')][string]$GameId
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Initialize-NeuralPowerShell.ps1"
$root=Split-Path $PSScriptRoot -Parent
if ($PSCmdlet.ParameterSetName -eq 'Library') {
    Import-Module (Join-Path $root 'powershell\NeuralGaming.Library.psm1') -Force
    Invoke-NeuralLibraryAction -Action Launch -GameId $GameId
} else {
    Import-Module (Join-Path $root 'powershell\NeuralGaming.psm1') -Force
    Start-NeuralGame -Name $Name
}
