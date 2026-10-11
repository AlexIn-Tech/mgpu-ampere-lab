# Session-scoped AutoArm override. The recovery record is written before the INI changes.
function Read-NeuralAutoArm([string]$Text) {
    $entries=@([regex]::Matches($Text,'(?im)^[ \t]*(?<key>AutoArm)(?<gap>[ \t]*)=[ \t]*(?<value>[^\r\n]*)\r?$'))
    if($entries.Count -ne 1 -or $entries[0].Groups['key'].Value -cne 'AutoArm' -or $entries[0].Groups['gap'].Value -ne '' -or $entries[0].Groups['value'].Value.Trim() -notmatch '^[01]$'){
        throw 'Require one canonical AutoArm=0 or AutoArm=1 entry without duplicates.'
    }
    [int]$entries[0].Groups['value'].Value.Trim()
}
function Write-NeuralAutoArmBytes([string]$Path,[byte[]]$Bytes) {
    Assert-NeuralRegularPath $Path
    $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $backup=$temp+'.bak'
    try {
        [IO.File]::WriteAllBytes($temp,$Bytes)
        [IO.File]::Replace($temp,$Path,$backup)
    } finally {foreach($file in @($temp,$backup)){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}}
}
function Convert-NeuralAutoArmBytes([string]$Text,[byte[]]$Original) {
    $utf8=[Text.UTF8Encoding]::new($false)
    $bytes=$utf8.GetBytes($Text)
    if($Original.Length -ge 3 -and $Original[0] -eq 239 -and $Original[1] -eq 187 -and $Original[2] -eq 191){$bytes=[byte[]](@(239,187,191)+$bytes)}
    return ,$bytes
}
function Set-NeuralLaunchAutoArm([string]$Name,[ValidateSet(0,1)][int]$Value=0) {
    $manifest=Get-NeuralManifest $Name
    $path=Get-NeuralOwnedPath $manifest.GameDirectory 'mgpu.ini'
    if(Get-NeuralBindingRecord $Name 'autoarm'){throw 'Pending AutoArm recovery. Close the game and use Recover before launching.'}
    if((Get-Item -LiteralPath $path).Length -gt 32768){throw 'mgpu.ini is too large for session AutoArm recovery.'}
    $original=[IO.File]::ReadAllBytes($path);$text=[IO.File]::ReadAllText($path)
    $previous=Read-NeuralAutoArm $text
    $updated=[regex]::Replace($text,'(?m)^([ \t]*AutoArm=[ \t]*)[01]([ \t]*\r?)$',('${1}'+$Value+'${2}'))
    if((Read-NeuralAutoArm $updated) -ne $Value){throw 'Cannot set AutoArm before launch.'}
    $bytes=Convert-NeuralAutoArmBytes $updated $original
    Write-NeuralBindingRecord $Name 'autoarm' ([pscustomobject]@{Version=1;Executable=$manifest.Executable;Original=[Convert]::ToBase64String($original);PreviousAutoArm=$previous;EnabledTextHash=(Get-NeuralTextHash $updated)})
    Write-NeuralAutoArmBytes $path $bytes
    if((Read-NeuralAutoArm ([IO.File]::ReadAllText($path))) -ne $Value){throw 'AutoArm read-back failed; game was not launched.'}
}
function Restore-NeuralLaunchAutoArm([string]$Name) {
    $record=Get-NeuralBindingRecord $Name 'autoarm'
    if(-not $record){return}
    $manifest=Get-NeuralManifest $Name
    if($record.Version -ne 1 -or $record.Executable -ine $manifest.Executable -or $record.PreviousAutoArm -notin @(0,1)){throw 'Invalid AutoArm recovery record.'}
    $path=Get-NeuralOwnedPath $manifest.GameDirectory 'mgpu.ini'
    $current=[IO.File]::ReadAllText($path);$value=Read-NeuralAutoArm $current
    $original=[Convert]::FromBase64String($record.Original)
    if((Get-NeuralTextHash $current) -ceq $record.EnabledTextHash){
        Write-NeuralAutoArmBytes $path $original
    } elseif($value -ne $record.PreviousAutoArm){
        # Preserve calibration/other INI edits made while the game ran.
        $restored=[regex]::Replace($current,'(?m)^([ \t]*AutoArm=[ \t]*)[01]([ \t]*\r?)$',('${1}'+$record.PreviousAutoArm+'${2}'))
        Write-NeuralAutoArmBytes $path (Convert-NeuralAutoArmBytes $restored ([IO.File]::ReadAllBytes($path)))
    }
    Remove-NeuralBindingRecord $Name 'autoarm'
}
