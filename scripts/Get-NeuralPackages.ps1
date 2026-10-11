[CmdletBinding()]
param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NeuralProvisioning.ps1')
$downloads = Join-Path $Root 'runtime\downloads'
$packages = Join-Path $Root 'runtime\packages'
Assert-NeuralProvisionPath $downloads
Assert-NeuralProvisionPath $packages
New-Item -ItemType Directory -Path $downloads,$packages -Force | Out-Null
$assets = @(
    @{ Name='mgpu_bridge-0.3.1.zip'; Url='https://github.com/maohgad-web/Neural-coprocessor/releases/download/0.3.1/mgpu_bridge-0.3.1.zip'; Hash='d87d145d6b7ae28fb7de568a5e58b58616c67c03ffcababaa9fef4b56edcc827'; Folder='bridge-0.3.1' },
    @{ Name='nvngx_dlssnr_310.8.SF-v2.zip'; Url='https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.SF-v2/nvngx_dlssnr_310.8.SF-v2.zip'; Hash='1da35941894994eb087e017577829e492454e9bae3a6a9397027069ceb74955c'; Folder='dlssnr-310.8.SF-v2' },
    @{ Name='ReShade_Setup_6.8.0_Addon.exe'; Url='https://reshade.me/downloads/ReShade_Setup_6.8.0_Addon.exe'; Hash='afe4c8f13048306307983b8b3d41d5bf00a86820440b0e57dea10950e1176445'; Folder='reshade-6.8.0' }
)
$records = @()
foreach ($asset in $assets) {
    $file = Join-Path $downloads $asset.Name
    Assert-NeuralProvisionPath $file
    if ((Test-Path -LiteralPath $file) -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.Hash) {
        throw ('Cached archive hash mismatch; no overwrite attempted: '+$file)
    }
    if (-not (Test-Path -LiteralPath $file)) {
        $partial = $file + '.partial.' + [Guid]::NewGuid().ToString('N')
        Assert-NeuralProvisionPath $partial
        try {
            Invoke-WebRequest -Uri $asset.Url -OutFile $partial
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.Hash) { throw "Hash mismatch for $($asset.Name). Refusing extraction." }
            [IO.File]::Move($partial,$file)
        } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial } }
    }
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $asset.Hash) { throw "Hash mismatch for $($asset.Name). Refusing extraction." }
    $destination = Join-Path $packages $asset.Folder
    Assert-NeuralProvisionPath $destination
    if(Test-Path -LiteralPath $destination){throw ('Existing package directory refused; preserve it before reprovisioning: '+$destination)}
    if ($asset.Name -like '*.zip') { Expand-NeuralPinnedArchive -ArchivePath $file -Hash $asset.Hash -Destination $destination }
    else {
        # ReShade's official installer contains a ZIP payload; never execute the installer.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        # The executable stub precedes the ZIP and Authenticode follows it. .NET
        # does not adjust ZIP-relative offsets in this self-extracting layout.
        $bytes = [IO.File]::ReadAllBytes($file)
        $end = -1
        for ($position=$bytes.Length-22; $position -ge [Math]::Max(0,$bytes.Length-65557); $position--) {
            if ($bytes[$position] -eq 80 -and $bytes[$position+1] -eq 75 -and $bytes[$position+2] -eq 5 -and $bytes[$position+3] -eq 6) { $end=$position; break }
        }
        if ($end -lt 0) { throw 'ZIP directory not found in ReShade installer.' }
        $start = $end - [BitConverter]::ToUInt32($bytes,$end+12) - [BitConverter]::ToUInt32($bytes,$end+16)
        if ($start -lt 0 -or $start -ge $end) { throw 'Invalid ZIP offset in ReShade installer.' }
        $stream = [IO.MemoryStream]::new($bytes,$start,$end+22-$start,$false)
        $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read)
        try {
            $entry = $archive.GetEntry('ReShade64.dll')
            if (-not $entry) { throw 'ReShade64.dll not found in installer payload.' }
            # Inspect the complete embedded directory, even though only the DLL is used.
            Get-NeuralProvisionArchivePlan $archive $destination | Out-Null
            Assert-NeuralProvisionPath $destination
            [IO.Directory]::CreateDirectory($destination)|Out-Null
            $target=Join-Path $destination 'ReShade64.dll'
            Assert-NeuralProvisionPath $target
            $output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
            try {$input=$entry.Open();try{$input.CopyTo($output)}finally{$input.Dispose()}}finally{$output.Dispose()}
        } finally { $archive.Dispose(); $stream.Dispose() }
    }
    $records += [pscustomobject]@{ name=$asset.Name; url=$asset.Url; sha256=$actual; package=$destination }
}
$recordPath=Join-Path $Root 'runtime\packages.json'
Assert-NeuralProvisionPath $recordPath
$records | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath -Encoding UTF8
$records
