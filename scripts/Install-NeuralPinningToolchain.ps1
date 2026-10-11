[CmdletBinding()] param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Initialize-NeuralPowerShell.ps1')
. (Join-Path $PSScriptRoot 'NeuralProvisioning.ps1')
$base=Join-Path $root 'runtime\toolchains'
Assert-NeuralProvisionPath $base
[IO.Directory]::CreateDirectory($base)|Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$assets=@(Get-NeuralToolchainAssets)
foreach($asset in $assets){
    $archivePath=Join-Path $base $asset.Name
    Assert-NeuralProvisionPath $archivePath
    if(-not (Test-Path -LiteralPath $archivePath)){
        $partial=$archivePath+'.partial.'+[Guid]::NewGuid().ToString('N')
        Assert-NeuralProvisionPath $partial
        try {
            Invoke-WebRequest -Uri $asset.Url -OutFile $partial -UseBasicParsing
            if((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $asset.Hash){throw ('Download hash mismatch: '+$asset.Name)}
            [IO.File]::Move($partial,$archivePath)
        } finally {if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial}}
    }
    if((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $asset.Hash){throw ('Cached archive changed; preserve it and inspect before retrying: '+$archivePath)}
    $destination=if($asset.Container){Join-Path $base $asset.Container}else{$base}
    $folder=Join-Path $destination $asset.Folder
    Assert-NeuralProvisionPath $folder
    if(Test-Path -LiteralPath $folder){
        if(-not (Test-Path -LiteralPath (Join-Path $folder $asset.Marker) -PathType Leaf)){throw ('Incomplete toolchain folder; no overwrite attempted: '+$folder)}
        Assert-NeuralExtractedArchive -ArchivePath $archivePath -Hash $asset.Hash -Destination $destination -Prefix ($asset.Folder+'/')
        Write-Output ('Pinned archive and extracted files verified; portable toolchain retained: '+$folder)
        continue
    }
    # Inspect every entry before extraction; reject absolute, escaping, alternate
    # stream and out-of-package entries. Existing files are never overwritten.
    Expand-NeuralPinnedArchive -ArchivePath $archivePath -Hash $asset.Hash -Destination $destination -Prefix ($asset.Folder+'/')
    if(-not (Test-Path -LiteralPath (Join-Path $folder $asset.Marker) -PathType Leaf)){throw 'Extracted toolchain marker missing.'}
    Write-Output ('Portable toolchain extracted: '+$folder)
}
Write-Output 'No PATH, registry, service, driver or system compiler installation was changed. Run Build-NeuralPinning.ps1 explicitly to compile.'
