[CmdletBinding()] param()
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Initialize-NeuralPowerShell.ps1"
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'powershell\NeuralGaming.Library.psm1') -Force
Show-NeuralGamingGui
