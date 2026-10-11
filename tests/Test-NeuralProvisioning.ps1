$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $repo ('runtime\provisioning-test-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
function New-FixtureZip([string]$Path,[hashtable]$Files) {
    $archive=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try {foreach($name in $Files.Keys){$entry=$archive.CreateEntry($name);$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write([string]$Files[$name])}finally{$writer.Dispose()}}}finally{$archive.Dispose()}
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Assert-Rejected([scriptblock]$Action,[string]$Reason) {
    $caught=$null
    try {& $Action|Out-Null}catch{$caught=$_}
    if(-not $caught){throw ('Expected refusal: '+$Reason)}
    if($caught.Exception.Message -notmatch 'reparse|conflict|existing|changed|hash|archive|entry|contained|missing|provenance'){throw ('Unexpected failure for '+$Reason+': '+$caught.Exception.Message)}
    Write-Output ('PASS: '+$Reason)
}
# These cached miniature archives exercise the real package entry point offline.
# Only pinned asset hashes change in the isolated copy; no network calls are made.
$packageRoot=Join-Path $fixture 'packages-case'
$downloads=Join-Path $packageRoot 'runtime\downloads'
[IO.Directory]::CreateDirectory($downloads)|Out-Null
$bridgeHash=New-FixtureZip (Join-Path $downloads 'mgpu_bridge-0.3.1.zip') @{'owned.dat'='verified bridge'}
$modelHash=New-FixtureZip (Join-Path $downloads 'nvngx_dlssnr_310.8.SF-v2.zip') @{'nvngx_dlssnr.dll'='verified model'}
$reshadeHash=New-FixtureZip (Join-Path $downloads 'ReShade_Setup_6.8.0_Addon.exe') @{'ReShade64.dll'='verified reshade'}
$code=Join-Path $fixture 'code'
Copy-Item -LiteralPath (Join-Path $repo 'scripts') -Destination $code -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'powershell') -Destination (Join-Path $fixture 'powershell') -Recurse
# Keep the copied script in scripts/ so its normal module lookup stays real.
Move-Item -LiteralPath $code -Destination (Join-Path $fixture 'scripts')
$packageScript=Join-Path $fixture 'scripts\Get-NeuralPackages.ps1'
$text=[IO.File]::ReadAllText($packageScript)
$text=$text.Replace('d87d145d6b7ae28fb7de568a5e58b58616c67c03ffcababaa9fef4b56edcc827',$bridgeHash).Replace('1da35941894994eb087e017577829e492454e9bae3a6a9397027069ceb74955c',$modelHash).Replace('afe4c8f13048306307983b8b3d41d5bf00a86820440b0e57dea10950e1176445',$reshadeHash)
[IO.File]::WriteAllText($packageScript,$text)
function Invoke-WebRequest {throw 'Unexpected network attempt in offline provisioning fixture.'}
$existing=Join-Path $packageRoot 'runtime\packages\bridge-0.3.1\owned.dat'
[IO.Directory]::CreateDirectory((Split-Path $existing -Parent))|Out-Null
[IO.File]::WriteAllText($existing,'personal edits')
Assert-Rejected {& $packageScript -Root $packageRoot} 'existing package content is refused'
if([IO.File]::ReadAllText($existing) -cne 'personal edits'){throw 'Package provisioning overwrote existing content.'}
$freshRoot=Join-Path $fixture 'fresh-packages'
$freshDownloads=Join-Path $freshRoot 'runtime\downloads'
[IO.Directory]::CreateDirectory($freshDownloads)|Out-Null
foreach($file in @(Get-ChildItem -LiteralPath $downloads -File)){Copy-Item -LiteralPath $file.FullName -Destination $freshDownloads}
& $packageScript -Root $freshRoot|Out-Null
if([IO.File]::ReadAllText((Join-Path $freshRoot 'runtime\packages\bridge-0.3.1\owned.dat')) -cne 'verified bridge' -or [IO.File]::ReadAllText((Join-Path $freshRoot 'runtime\packages\dlssnr-310.8.SF-v2\nvngx_dlssnr.dll')) -cne 'verified model' -or [IO.File]::ReadAllText((Join-Path $freshRoot 'runtime\packages\reshade-6.8.0\ReShade64.dll')) -cne 'verified reshade'){throw 'Fresh package entry point did not extract the verified payloads.'}
Write-Output 'PASS: complete package entry point extracts verified ZIPs and embedded ReShade DLL offline'

$helper=Join-Path $repo 'scripts\NeuralProvisioning.ps1'
. $helper
$archivePath=Join-Path $fixture 'tool.zip'
$hash=New-FixtureZip $archivePath @{'tool/bin/compiler.exe'='compiler';'tool/bin/llvm-ar.exe'='archiver';'tool/src/source.cpp'='source'}
$destination=Join-Path $fixture 'extracted'
Expand-NeuralPinnedArchive -ArchivePath $archivePath -Hash $hash -Destination $destination -Prefix 'tool/'
Assert-NeuralExtractedArchive -ArchivePath $archivePath -Hash $hash -Destination $destination -Prefix 'tool/'
Write-Output 'PASS: verified fresh extraction and cached-tree provenance'
[IO.File]::WriteAllText((Join-Path $destination 'tool\bin\compiler.exe'),'changed')
Assert-Rejected {Assert-NeuralExtractedArchive -ArchivePath $archivePath -Hash $hash -Destination $destination -Prefix 'tool/'} 'modified compiler is rejected against pinned archive'
[IO.File]::WriteAllText((Join-Path $destination 'tool\bin\compiler.exe'),'compiler')
[IO.File]::WriteAllText((Join-Path $destination 'tool\bin\llvm-ar.exe'),'changed')
Assert-Rejected {Assert-NeuralExtractedArchive -ArchivePath $archivePath -Hash $hash -Destination $destination -Prefix 'tool/'} 'modified archiver is rejected against pinned archive'
[IO.File]::WriteAllText((Join-Path $destination 'tool\bin\llvm-ar.exe'),'archiver')
[IO.File]::WriteAllText((Join-Path $destination 'tool\src\source.cpp'),'changed')
Assert-Rejected {Assert-NeuralExtractedArchive -ArchivePath $archivePath -Hash $hash -Destination $destination -Prefix 'tool/'} 'modified dependency source is rejected against pinned archive'
[IO.File]::WriteAllText((Join-Path $destination 'tool\src\source.cpp'),'source')
[IO.File]::WriteAllText((Join-Path $destination 'tool\bin\unexpected.dll'),'injected')
Assert-Rejected {Assert-NeuralExtractedArchive -ArchivePath $archivePath -Hash $hash -Destination $destination -Prefix 'tool/'} 'untracked DLL in cached toolchain is rejected'
Assert-Rejected {Expand-NeuralPinnedArchive -ArchivePath $archivePath -Hash $hash -Destination $destination -Prefix 'tool/'} 'extraction never overwrites existing entries'
Assert-Rejected {Expand-NeuralPinnedArchive -ArchivePath $archivePath -Hash ('0'*64) -Destination (Join-Path $fixture 'wrong-hash') -Prefix 'tool/'} 'archive hash is verified before extraction'
foreach($bad in @('../escaped.dat','/absolute.dat','tool/../escaped.dat','tool/file:stream','other/file.dat')){
    $badZip=Join-Path $fixture ([Guid]::NewGuid().ToString('N')+'.zip')
    $badHash=New-FixtureZip $badZip @{'tool/safe.dat'='safe';$bad='unsafe'}
    $badDestination=Join-Path $fixture ([Guid]::NewGuid().ToString('N'))
    Assert-Rejected {Expand-NeuralPinnedArchive -ArchivePath $badZip -Hash $badHash -Destination $badDestination -Prefix 'tool/'} ('unsafe archive entry '+$bad)
    if(Test-Path -LiteralPath $badDestination){throw 'An invalid archive wrote output before every entry was checked.'}
}
$outside=Join-Path $fixture 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null
$linked=Join-Path $fixture 'linked'
New-Item -ItemType Junction -Path $linked -Target $outside|Out-Null
Assert-Rejected {Expand-NeuralPinnedArchive -ArchivePath $archivePath -Hash $hash -Destination $linked -Prefix 'tool/'} 'junction extraction destination is rejected'
if(@(Get-ChildItem -LiteralPath $outside -Force).Count){throw 'Extraction escaped through a junction.'}
Assert-Rejected {Assert-NeuralProvisionTree $linked} 'junction build output directory is rejected'
$linkedPackageRoot=Join-Path $fixture 'linked-packages'
[IO.Directory]::CreateDirectory((Join-Path $linkedPackageRoot 'runtime'))|Out-Null
New-Item -ItemType Junction -Path (Join-Path $linkedPackageRoot 'runtime\packages') -Target $outside|Out-Null
Assert-Rejected {& $packageScript -Root $linkedPackageRoot} 'package entry point rejects reparse ancestors before downloads or extraction'
if(@(Get-ChildItem -LiteralPath $outside -Force).Count){throw 'Package entry point wrote through a junction.'}
$missingBuild=Join-Path $fixture 'scripts\Build-NeuralPinning.ps1'
$fakeCompiler=Join-Path $fixture 'runtime\toolchains\llvm-mingw-20261006-ucrt-x86_64\bin\x86_64-w64-mingw32-clang++.exe'
[IO.Directory]::CreateDirectory((Split-Path $fakeCompiler -Parent))|Out-Null
[IO.File]::WriteAllText($fakeCompiler,'invalid executable must never be invoked')
Assert-Rejected {& $missingBuild -FixturesOnly} 'build refuses unverified cached compiler before execution'
Write-Output 'All provisioning security fixtures passed without network, game or GPU operations.'
