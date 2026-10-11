$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)}}
$repo=Split-Path $PSScriptRoot -Parent
$source=Join-Path $repo 'native\NeuralPinnedStartup.cs'
Assert-True (Test-Path -LiteralPath $source -PathType Leaf) 'Startup must have an owned job helper before any launcher runs'
if(-not ('NeuralGaming.Native.PinnedStartup' -as [type])){Add-Type -Path $source -ErrorAction Stop}
Import-Module (Join-Path $repo 'powershell\NeuralGaming.psm1') -Force -DisableNameChecking
$module=Get-Module NeuralGaming
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$folder=Join-Path $repo ('runtime\startup-ownership-test-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($folder)|Out-Null
$outside=$null
function Encode-Command([string]$Text){[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))}
function Quote-Fixture([string]$Text){"'"+$Text.Replace("'","''")+"'"}
try {
    [IO.Directory]::CreateDirectory((Join-Path $folder 'runtime'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'runtime\config.json'),'{"renderUuid":"render","neuralUuid":"display"}')
    $manifest=[pscustomobject]@{Name='fixture';Executable=$shell;GameDirectory=(Split-Path $shell -Parent)}
    & $module {param($Root,$Shell)
        $script:NeuralRoot=$Root;$script:FixtureShell=$Shell
        function script:Get-NeuralGamePinning {param($Name) [pscustomobject]@{Available=$true;Supported=$true;Fingerprint='fixture'}}
        function script:Get-NeuralPinBinaryState {[pscustomobject]@{Available=$true;Fingerprint='fixture';Launcher=$script:FixtureShell;Dll=$script:FixtureShell}}
        function script:Get-NeuralGpus {@()}
        function script:Get-NeuralGpuAdapters {param($Gpus)
            @([pscustomobject]@{Uuid='render';Luid='00000000-00000001';DisplayActive=$false},[pscustomobject]@{Uuid='display';Luid='00000000-00000002';DisplayActive=$true})
        }
        # Keep the real wrapper, ownership helper and OS job. Replace only the
        # experimental GPU launcher with a controlled CPU-only PowerShell tree.
        function script:Start-NeuralPinnedHelper {param($Launcher,$Arguments,$Directory,$Stdout,$Stderr)
            $resultIndex=[Array]::IndexOf([string[]]$Arguments,'--result')+1
            $result=[string]$Arguments[$resultIndex]
            $command=$script:FixtureCommand.Replace('__RESULT__',$result.Replace("'","''"))
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            [NeuralGaming.Native.PinnedStartup]::Start($script:FixtureShell,@('-NoProfile','-EncodedCommand',$encoded),$Directory,$Stdout,$Stderr)
        }
    } $folder $shell
    $outside=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-EncodedCommand',(Encode-Command '[Threading.Thread]::Sleep(30000)')) -WindowStyle Hidden -PassThru
    $null=$outside.Handle
    foreach($mode in @('timeout','crash','invalid','foreign','success')){
        $pidPath=Join-Path $folder ($mode+'-child.pid')
        $childCode='[Threading.Thread]::Sleep(30000)'
        $childEncoded=Encode-Command $childCode
        $end= switch($mode){
            'timeout' {'$child.WaitForExit()'}
            'crash' {'[Environment]::Exit(23)'}
            'invalid' {'[IO.File]::WriteAllText(''__RESULT__'',''{"ProcessId":0,"Status":"Invalid"}'')'}
            'foreign' {'[IO.File]::WriteAllText(''__RESULT__'',''{"ProcessId":'+$outside.Id+',"Status":"Spawned"}'')'}
            'success' {'[IO.File]::WriteAllText(''__RESULT__'',(''{"ProcessId":''+$child.Id+'',"Status":"Spawned"}''))'}
        }
        $helperCode='$ErrorActionPreference=''Stop''; $child=Start-Process -FilePath '+(Quote-Fixture $shell)+' -ArgumentList @(''-NoProfile'',''-EncodedCommand'','+(Quote-Fixture $childEncoded)+') -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText('+(Quote-Fixture $pidPath)+', [string]$child.Id); [Console]::Out.WriteLine(''stdout-marker''); [Console]::Error.WriteLine(''stderr-marker''); '+$end
        & $module {param($Code) $script:FixtureCommand=$Code} $helperCode
        $returned=$null;$failure=$null
        try {$returned=& $module {param($Manifest) Start-NeuralPinnedProcess -Manifest $Manifest -TimeoutMilliseconds 5000} $manifest}
        catch {$failure=$_.Exception.Message}
        Assert-True (Test-Path -LiteralPath $pidPath) ($mode+' CPU fixture creates its child')
        $childId=[int][IO.File]::ReadAllText($pidPath)
        $child=Get-Process -Id $childId -ErrorAction SilentlyContinue
        if($mode -eq 'success'){
            Assert-True ($null -eq $failure -and $returned.Id -eq $childId -and -not $returned.HasExited) 'Successful verified handoff preserves its live owned child'
            # Cleanup uses a retained handle for this test-created child, never an
            # arbitrary PID recovered from a failed launcher result.
            $returned.Kill();$returned.WaitForExit();$returned.Dispose()
        } else {
            $pattern=switch($mode){'timeout' {'timed out'} 'crash' {'helper failed'} 'invalid' {'Invalid native child-process result'} 'foreign' {'outside the owned startup job'}}
            Assert-True ($failure -match $pattern) ($mode+' reports the intended failure')
            if($child){Assert-True ($child.WaitForExit(5000)) ($mode+' failure cancels the owned descendant')}
            Assert-True ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) ($mode+' leaves no running descendant')
            Assert-True (-not $outside.HasExited) ($mode+' cancellation preserves the separate CPU sentinel')
        }
        if($child){$child.Dispose()}
        $operation=Get-ChildItem -LiteralPath (Join-Path $folder 'runtime\pinning\launches') -Directory | Sort-Object CreationTimeUtc -Descending | Select-Object -First 1
        Assert-True (([IO.File]::ReadAllText((Join-Path $operation.FullName 'launcher.stdout.txt'))) -match 'stdout-marker') 'Only redirected stdout carries the fixture output'
        Assert-True (([IO.File]::ReadAllText((Join-Path $operation.FullName 'launcher.stderr.txt'))) -match 'stderr-marker') 'Only redirected stderr carries the fixture error'
    }
    $outside.Kill();$outside.WaitForExit();$outside.Dispose();$outside=$null
    # An inheritable ambient event must not reach the launcher. If a numeric
    # handle happens to be reused in the child, it cannot signal our event.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class StartupFixtureHandles {
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
}
'@ -ErrorAction Stop
    $ambient=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset)
    $probe=$null
    try {
        Assert-True ([StartupFixtureHandles]::SetHandleInformation($ambient.SafeWaitHandle.DangerousGetHandle(),1,1)) 'Create an inheritable ambient event for the handle isolation fixture'
        $probeCode='$event=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset); $event.SafeWaitHandle=New-Object Microsoft.Win32.SafeHandles.SafeWaitHandle([IntPtr]'+$ambient.SafeWaitHandle.DangerousGetHandle().ToInt64()+',$false); try{$event.Set()|Out-Null}catch{}; [Console]::Out.WriteLine(''handle-probe-finished'')'
        $probe=[NeuralGaming.Native.PinnedStartup]::Start($shell,@('-NoProfile','-EncodedCommand',(Encode-Command $probeCode)),(Split-Path $shell -Parent),(Join-Path $folder 'probe.stdout'),(Join-Path $folder 'probe.stderr'))
        Assert-True ($probe.WaitForExit(10000) -and $probe.ExitCode -eq 0) 'The controlled handle probe completes'
        Assert-True (-not $ambient.WaitOne(0)) 'Explicit inheritance excludes unrelated inheritable PowerShell handles'
    } finally {if($probe){$probe.Dispose()};$ambient.Dispose()}
    # Manager death closes its exclusive job handle without requiring a finally
    # block. The controlled helper and grandchild must therefore both exit.
    $managerPidPath=Join-Path $folder 'manager-helper.pid';$orphanPidPath=Join-Path $folder 'manager-child.pid'
    $managerHelper='$child=Start-Process -FilePath '+(Quote-Fixture $shell)+' -ArgumentList @(''-NoProfile'',''-EncodedCommand'','+(Quote-Fixture (Encode-Command '[Threading.Thread]::Sleep(30000)'))+') -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText('+(Quote-Fixture $orphanPidPath)+',[string]$child.Id); $child.WaitForExit()'
    $managerCode='Add-Type -Path '+(Quote-Fixture $source)+'; $launch=[NeuralGaming.Native.PinnedStartup]::Start('+(Quote-Fixture $shell)+',@(''-NoProfile'',''-EncodedCommand'','+(Quote-Fixture (Encode-Command $managerHelper))+'),'+(Quote-Fixture (Split-Path $shell -Parent))+','+(Quote-Fixture (Join-Path $folder 'manager.stdout'))+','+(Quote-Fixture (Join-Path $folder 'manager.stderr'))+'); [IO.File]::WriteAllText('+(Quote-Fixture $managerPidPath)+',[string]$launch.ProcessId); $deadline=[DateTime]::UtcNow.AddSeconds(10); while(-not (Test-Path -LiteralPath '+(Quote-Fixture $orphanPidPath)+') -and [DateTime]::UtcNow -lt $deadline){[Threading.Thread]::Sleep(25)}; [Environment]::Exit(24)'
    $manager=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-EncodedCommand',(Encode-Command $managerCode)) -WindowStyle Hidden -PassThru
    try {
        $null=$manager.Handle
        Assert-True ($manager.WaitForExit(15000) -and $manager.ExitCode -eq 24) 'Controlled startup manager exits without disposing its job'
        foreach($pidPath in @($managerPidPath,$orphanPidPath)){
            Assert-True (Test-Path -LiteralPath $pidPath) 'Manager-death fixture reached both process creation boundaries'
            $owned=Get-Process -Id ([int][IO.File]::ReadAllText($pidPath)) -ErrorAction SilentlyContinue
            if($owned){try{Assert-True ($owned.WaitForExit(5000)) 'Manager death cancels the owned startup tree'}finally{$owned.Dispose()}}
            Assert-True ($null -eq (Get-Process -Id ([int][IO.File]::ReadAllText($pidPath)) -ErrorAction SilentlyContinue)) 'Manager death leaves no running owned startup process'
        }
    } finally {$manager.Dispose()}
    Write-Output 'PASS: timeout, helper crash, invalid/foreign result and manager death cancel the owned CPU tree; sentinel, handoff, redirection and handle isolation preserved. No GPU or game workload ran.'
} finally {
    if($outside){try{if(-not $outside.HasExited){$outside.Kill();$outside.WaitForExit()}}finally{$outside.Dispose()}}
    # On a failed assertion, wait for bounded CPU fixtures rather than killing a
    # process reconstructed from an unchecked identifier.
    foreach($pidFile in @(Get-ChildItem -LiteralPath $folder -Filter '*-child.pid' -ErrorAction SilentlyContinue)){
        $remaining=Get-Process -Id ([int][IO.File]::ReadAllText($pidFile.FullName)) -ErrorAction SilentlyContinue
        if($remaining){$null=$remaining.WaitForExit(35000);$remaining.Dispose()}
    }
    $full=[IO.Path]::GetFullPath($folder);$prefix=[IO.Path]::GetFullPath((Join-Path $repo 'runtime')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $full -Leaf) -notlike 'startup-ownership-test-*'){throw 'Refusing unexpected fixture cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
