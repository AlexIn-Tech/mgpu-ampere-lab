[CmdletBinding()] param()
$ErrorActionPreference='Stop'
$hostPath=(Get-Process -Id $PID).Path
$names=@('Test-NeuralProvisioning.ps1','Test-NeuralImportBudget.ps1','Test-NeuralStartupOwnership.ps1','Test-NeuralGpu.ps1','Test-NeuralRuntime.ps1','Test-NeuralPinning.ps1','Test-NeuralPinningManager.ps1','Test-NeuralBinding.ps1','Test-NeuralProcessLifecycle.ps1','Test-NeuralGaming.ps1','Test-NeuralGameCatalog.ps1','Test-NeuralGamingLibrary.ps1','Test-NeuralGameWorker.ps1','Test-NeuralGamingGui.ps1','Test-NeuralWindowsPowerShell.ps1')
foreach ($name in $names) {
    $testArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot $name))
    if($name -eq 'Test-NeuralPinning.ps1'){$testArguments+='-NoBuild'}
    & $hostPath @testArguments
    if ($LASTEXITCODE -ne 0) { throw "Test suite failed: $name (exit $LASTEXITCODE)" }
}
Write-Output ('PASS: all '+$names.Count+' suites using '+$PSVersionTable.PSVersion)
