# Shared provisioning guards. Dot-sourcing never downloads or executes a toolchain.
Set-StrictMode -Version Latest
$script:ProvisionManager=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'powershell\NeuralGaming.psm1') -Scope Local -Force -PassThru -DisableNameChecking
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
function Assert-NeuralProvisionPath([string]$Path) {
    & $script:ProvisionManager {param($Value) Assert-NeuralRegularPath $Value} $Path
}
function Assert-NeuralProvisionNativePath([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if(([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) -and ([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint)){throw ('Reparse-point provisioning path refused: '+$current)}
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
function Assert-NeuralProvisionTree([string]$Path) {
    Assert-NeuralProvisionPath $Path
    if(-not (Test-Path -LiteralPath $Path)){return}
    $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push([IO.Path]::GetFullPath($Path))
    while($pending.Count){
        $directory=$pending.Pop()
        foreach($item in [IO.Directory]::EnumerateFileSystemEntries($directory)){
            $attributes=[IO.File]::GetAttributes($item)
            if($attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Reparse-point provisioning path refused: '+$item)}
            if($attributes -band [IO.FileAttributes]::Directory){$pending.Push($item)}
        }
    }
}
function Get-NeuralToolchainAssets {
    @(
        @{Name='llvm-mingw-20261006-ucrt-x86_64.zip';Url='https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/llvm-mingw-20261006-ucrt-x86_64.zip';Hash='317492c456aa27ee607a5919f1d2d38dcdc1112516a24d0bf4b00d078f52d17a';Container='';Folder='llvm-mingw-20261006-ucrt-x86_64';Marker='bin\x86_64-w64-mingw32-clang++.exe'},
        @{Name='detours-1dbd4ea.zip';Url='https://api.github.com/repos/microsoft/Detours/zipball/1dbd4ea281d73d478aa8d09a8b83fbd265f715f7';Hash='081d62718217ecf4f9a4098b9e9bca6ab77a1cb88647837320fae67ca6a59a68';Container='Detours-1dbd4ea281d73d478aa8d09a8b83fbd265f715f7';Folder='microsoft-Detours-1dbd4ea';Marker='src\detours.h'}
    )
}
function Open-NeuralPinnedArchive([string]$ArchivePath,[string]$Hash) {
    Assert-NeuralProvisionPath $ArchivePath
    if(-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)){throw ('Pinned archive missing: '+$ArchivePath)}
    $stream=[IO.File]::Open($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$actual=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$sha.Dispose()}
        if($Hash -notmatch '^[0-9A-Fa-f]{64}$' -or $actual -ine $Hash){throw ('Pinned archive hash mismatch: '+$ArchivePath)}
        $stream.Position=0
        return [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$false)
    }catch{$stream.Dispose();throw}
}
function Get-NeuralProvisionArchivePlan($Archive,[string]$Destination,[string]$Prefix='') {
    Assert-NeuralProvisionPath $Destination
    $destinationRoot=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
    $boundary=$destinationRoot+[IO.Path]::DirectorySeparatorChar
    $tree=if($Prefix){[IO.Path]::GetFullPath([IO.Path]::Combine($Destination,$Prefix))}else{$Destination}
    if($Prefix -and -not $tree.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Archive prefix must be contained in the destination.'}
    # The existing manager checks destination ancestry once; this non-following
    # scan checks every existing descendant once. Per-entry canonical validation
    # avoids thousands of repeated PowerShell module/ancestor inspections.
    Assert-NeuralProvisionTree $tree
    $records=New-Object 'Collections.Generic.List[object]';$paths=@{}
    foreach($entry in $Archive.Entries){
        $relative=$entry.FullName
        if(-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match ':|(^|[\\/])\.\.([\\/]|$)' -or ($Prefix -and -not $relative.StartsWith($Prefix,[StringComparison]::Ordinal)) -or (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960){throw ('Unsafe or out-of-package archive entry: '+$relative)}
        $path=[IO.Path]::GetFullPath([IO.Path]::Combine($Destination,$relative))
        if(-not $path.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw ('Archive entry is not contained: '+$relative)}
        $path=$path.TrimEnd('\','/')
        if($paths.ContainsKey($path)){throw ('Duplicate archive entry: '+$relative)}
        $directory=$relative.EndsWith('/') -or $relative.EndsWith('\')
        $paths[$path]=$directory
        $records.Add([pscustomobject]@{Entry=$entry;Path=$path;Directory=$directory})
    }
    if(-not $records.Count){throw 'Empty package archive refused.'}
    foreach($record in $records){
        $parent=[IO.Path]::GetDirectoryName($record.Path)
        while($parent -and $parent -ine $destinationRoot){
            if($paths.ContainsKey($parent) -and -not $paths[$parent]){throw 'Archive entry conflicts with a parent file.'}
            $parent=[IO.Path]::GetDirectoryName($parent)
        }
    }
    return $records
}
function Expand-NeuralPinnedArchive([string]$ArchivePath,[string]$Hash,[string]$Destination,[string]$Prefix='') {
    $archive=Open-NeuralPinnedArchive $ArchivePath $Hash
    try {
        $plan=@(Get-NeuralProvisionArchivePlan $archive $Destination $Prefix)
        # Validate every entry and conflict before creating any output.
        foreach($record in $plan){if(Test-Path -LiteralPath $record.Path){throw ('Existing archive destination conflict: '+$record.Path)}}
        foreach($record in $plan){
            Assert-NeuralProvisionNativePath $record.Path
            if($record.Directory){[IO.Directory]::CreateDirectory($record.Path)|Out-Null;continue}
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($record.Path))|Out-Null
            $output=[IO.File]::Open($record.Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
            try {$input=$record.Entry.Open();try{$input.CopyTo($output)}finally{$input.Dispose()}}finally{$output.Dispose()}
        }
    }finally{$archive.Dispose()}
}
function Assert-NeuralExtractedArchive([string]$ArchivePath,[string]$Hash,[string]$Destination,[string]$Prefix='') {
    $archive=Open-NeuralPinnedArchive $ArchivePath $Hash
    try {
        $tree=if($Prefix){Join-Path $Destination $Prefix.TrimEnd('/','\')}else{$Destination}
        $plan=@(Get-NeuralProvisionArchivePlan $archive $Destination $Prefix);$expected=@{}
        foreach($record in $plan){
            if($record.Directory){if(-not (Test-Path -LiteralPath $record.Path -PathType Container)){throw ('Cached archive directory missing: '+$record.Path)};continue}
            $expected[$record.Path]=$true
            if(-not [IO.File]::Exists($record.Path) -or ([IO.FileInfo]::new($record.Path)).Length -ne $record.Entry.Length){throw ('Cached archive file missing or changed: '+$record.Path)}
            $sha=[Security.Cryptography.SHA256]::Create();$input=$record.Entry.Open()
            try {$entryHash=[BitConverter]::ToString($sha.ComputeHash($input)).Replace('-','')}finally{$input.Dispose();$sha.Dispose()}
            Assert-NeuralProvisionNativePath $record.Path
            $sha=[Security.Cryptography.SHA256]::Create();$input=[IO.File]::Open($record.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {$fileHash=[BitConverter]::ToString($sha.ComputeHash($input)).Replace('-','')}finally{$input.Dispose();$sha.Dispose()}
            if($fileHash -ine $entryHash){throw ('Cached archive file hash changed: '+$record.Path)}
        }
        foreach($file in [IO.Directory]::EnumerateFiles($tree,'*',[IO.SearchOption]::AllDirectories)){
            if(-not $expected.ContainsKey($file)){throw ('Unexpected existing file in cached archive tree: '+$file)}
        }
    }finally{$archive.Dispose()}
}
