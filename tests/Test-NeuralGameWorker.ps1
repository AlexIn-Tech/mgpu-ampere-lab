$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$folder=Join-Path $root 'runtime\gui\operations'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$worker=Join-Path $root 'scripts\Invoke-NeuralGameAction.ps1'
$hostPath=(Get-Process -Id $PID).Path
function Invoke-FixtureRequest($Request,[string]$Result) {
    $path=Join-Path $folder ([Guid]::NewGuid().ToString('N')+'.request.json')
    [IO.File]::WriteAllText($path,($Request | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $savedPreference=$ErrorActionPreference
    try {
        # Windows PS surfaces native stderr as error records; expected failures are data here.
        $ErrorActionPreference='Continue'
        & $hostPath -NoProfile -ExecutionPolicy Bypass -File $worker -RequestPath $path -ResultPath $Result 2>&1 | Out-Null
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$savedPreference }
    return $code
}
$result=Join-Path $folder ([Guid]::NewGuid().ToString('N')+'.result.json')
$code=Invoke-FixtureRequest @{Root=$root;Action='Unsupported';GameId='none'} $result
$record=Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json
if ($code -eq 0 -or $record.Success -or $record.Message -notmatch 'Unsupported') { throw 'Worker must persist readable action errors and exit nonzero.' }
Write-Output 'PASS: worker action error protocol'
$result=Join-Path $folder ([Guid]::NewGuid().ToString('N')+'.result.json')
$code=Invoke-FixtureRequest @{Root='C:\wrong-install';Action='Patch';GameId='none'} $result
$record=Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json
if ($code -eq 0 -or $record.Success -or $record.Message -notmatch 'installation') { throw 'Worker must reject a different installation root before mutations.' }
Write-Output 'PASS: wrong installation root rejected'
$result=Join-Path $root ('runtime\outside-worker-'+[Guid]::NewGuid().ToString('N')+'.json')
$code=Invoke-FixtureRequest @{Root=$root;Action='Unsupported'} $result
if ($code -eq 0 -or (Test-Path -LiteralPath $result)) { throw 'Worker must never write outside its operation directory.' }
Write-Output 'PASS: result path containment'
Write-Output 'All worker boundary tests passed without real game actions.'
