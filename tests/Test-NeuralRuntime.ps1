[CmdletBinding()] param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert-True($Condition,[string]$Message) { if (-not $Condition) { throw ('FAIL: '+$Message) } }
$root=Split-Path $PSScriptRoot -Parent
$modulePath=Join-Path $root 'powershell\NeuralGaming.Runtime.psm1'
Assert-True (Test-Path -LiteralPath $modulePath) 'Runtime observation module must exist'
Import-Module $modulePath -Force
$fixture=Join-Path $root ('runtime\runtime-test-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$logPath=Join-Path $fixture 'ReShade.log'
$render='00000000-00014B7A'
$neural='00000000-000134A3'
$sessionUtc=[DateTime]::UtcNow.AddSeconds(-30)
$startupUtc=$sessionUtc.AddSeconds(1)
$stamp=$startupUtc.ToLocalTime().ToString('HH:mm:ss:fff',[Globalization.CultureInfo]::InvariantCulture)
function New-LogLine([string]$Text,[string]$Level='INFO',[int]$Offset=0) {
    $t=$startupUtc.AddMilliseconds($Offset).ToLocalTime().ToString('HH:mm:ss:fff',[Globalization.CultureInfo]::InvariantCulture)
    return ('{0} [83152] | {1,-5} | {2}' -f $t,$Level,$Text)
}
$startup=New-LogLine "Initializing crosire's ReShade version '6.8.0.2155' (64-bit) loaded from 'C:\fixture\dxgi.dll' into 'C:\fixture\Game.exe' (0x491EA19E) ..."
$version=New-LogLine '[MGPU Bridge] [MGPU][R141] MGPU Bridge 0.3.1-t1 | built Oct 10 2026 00:00:09 | add-on API 20. IDENTIFY EVERY LOG BY THIS LINE.' -Offset 1
$swap=New-LogLine "[MGPU Bridge] [MGPU][T2] init_swapchain: swapchain-derived game luid=0x00000000-0x00014B7A established (the device CreateSwapChainForHwnd was called on) - overrides the provisional init_device value" -Offset 2
$selected=New-LogLine '[MGPU Bridge] [MGPU][T2] SELECTED adapter[0] luid=0x00000000-0x000134A3 desc="NVIDIA GeForce RTX 3090" outputs=1 rule="exclusion (luid != swapchain game luid) + software filter" | game luid=0x00000000-0x00014B7A (source: swapchain)' -Offset 3
$device=New-LogLine '[MGPU Bridge] [MGPU][T3] D3D12CreateDevice hr=0x00000000 luid=0x00000000-0x000134A3 - device live on the second adapter; game rendering unaffected' -Offset 4
$binding=New-LogLine '[MGPU Bridge] [MGPU][R189] BINDING CONFIRMED AT ARM: the game renders on adapter luid=0x00000000-0x00014B7A and the bridge is on luid=0x00000000-0x000134A3 ("NVIDIA GeForce RTX 3090"). Different adapters, read from the game''s OWN device rather than from the luid the selection was made against.' -Offset 5
$arm=New-LogLine '[MGPU Bridge] [MGPU][P4.0] stream arm hr=0x00000000 source=3440x1440 fmt=28 rowPitch=13824 payload=19906560 slot=19907072 ring=4 heap=79691776 bytes. The heap is created on the GAME''s device: its command list can only reference resources from the device that made it. | DEPTH mode=1 (TRANSPORTED AND BOUND) 3440x1440 fmt=41 pitch=13824 bytes=19906560 at slot offset 19907072, held 0 frame(s) waiting for ReShade to bind depth. Seal v2, 192 bytes.' -Offset 6
$output=New-LogLine '[MGPU Bridge] [MGPU][P5.0] the bridge window is now showing the NEURAL OUTPUT - every pixel on screen is a pixel DLSS-NR produced on the second adapter - THE WHOLE of the 3440x1440 frame at 3440x1440, one CopyTextureRegion, no resampling in this add-on. The cycling colour returns when the stream ends.' -Offset 7
$base=@($startup,$version,$swap,$selected,$device)
function Write-Fixture([string[]]$Lines,[switch]$Partial) {
    $text=[string]::Join("`r`n",$Lines)
    if (-not $Partial) { $text+="`r`n" }
    [IO.File]::WriteAllText($logPath,$text,[Text.UTF8Encoding]::new($false))
}
function Read-State([switch]$Historic) {
    $args=@{LogPath=$logPath;ExpectedRenderLuid=$render;ExpectedNeuralLuid=$neural}
    if (-not $Historic) { $args.NotBeforeUtc=$sessionUtc; $args.PreviousPrefixHash='ABSENT' }
    return Get-NeuralLogState @args
}
function Assert-State([string]$Status,[bool]$Fresh,[bool]$Binding,[bool]$Armed,[bool]$Streaming,[string]$Message) {
    $s=Read-State
    Assert-True ($s.Status -ceq $Status -and $s.Fresh -eq $Fresh -and $s.BindingVerified -eq $Binding -and $s.Armed -eq $Armed -and $s.Streaming -eq $Streaming) ($Message+'; actual='+($s | ConvertTo-Json -Compress))
    Assert-True ($s.Message.Length -gt 0) 'Every result supplies a readable explanation'
}
$missing=Get-NeuralLogState -LogPath (Join-Path $fixture 'missing.log') -ExpectedRenderLuid $render -ExpectedNeuralLuid $neural -NotBeforeUtc $sessionUtc
Assert-True ($missing.Status -eq 'Unknown' -and -not $missing.Fresh -and $null -eq $missing.LastWriteUtc) 'Missing log is unverified'
Write-Fixture ($base+@($binding,$arm,$output))
$historic=Read-State -Historic
Assert-True ($historic.Status -eq 'Unknown' -and -not $historic.Fresh -and -not $historic.BindingVerified -and -not $historic.Armed -and -not $historic.Streaming -and $historic.RenderLuid -ceq $render) 'A log without the current session anchor remains historic and unverified'
Assert-State 'Streaming' $true $true $true $true 'Exact source-format neural output proves produced live output'
Assert-True ((Read-State).LastWriteUtc.Kind -eq [DateTimeKind]::Utc) 'LastWriteUtc is a UTC timestamp'
$split=$output -replace 'NEURAL OUTPUT - every pixel on screen is a pixel DLSS-NR produced on the second adapter','SPLIT (Present=split) - LEFT half is the frame handed TO DLSS-NR, RIGHT half is what DLSS-NR produced, and BOTH ARE THE SAME FRAME. Same instant, same camera, same lighting, one white seam between them. Any difference across that seam is the model and nothing else'
Write-Fixture ($base+@($binding,$arm,$split))
Assert-State 'Streaming' $true $true $true $true 'Split presentation confirms the successful model output half'
Write-Fixture $base
Assert-State 'Bound' $true $true $false $false 'Selection verifies roles without claiming the stream armed'
Write-Fixture ($base+@($binding))
Assert-State 'Bound' $true $true $false $false 'Binding confirmation precedes allocation and does not itself prove successful arm'
Write-Fixture ($base+@($binding,$arm))
Assert-State 'Armed' $true $true $true $false 'Arm alone does not prove the neural stage produced output'
Write-Fixture ($base+@($binding,$arm,(New-LogLine '[MGPU Bridge] [MGPU][P4.1] neural stage: UP | passes=1 | evaluates=0 (=0 frames x 1 passes) failures=0 | output sample identical to the previous frame 0 times (0.0%)' -Offset 7)))
Assert-State 'Armed' $true $true $true $false 'A neural stage summary without produced live output is insufficient'
$probes=@(
    (New-LogLine '[MGPU Bridge] [MGPU][P1.2] EvaluateFeature B_high intensity=2.00 depth=no: result=0x00000001 (Success) changed=99.48%' -Offset 5),
    (New-LogLine '[MGPU Bridge] [MGPU][P4.2] EvaluateFeature depth=yes: result=0x00000001 (Success)' -Offset 6),
    (New-LogLine '[MGPU Bridge] [MGPU][R101] CALIBRATOR mode=2 | evaluates=0 captured=0 | eval-copies=0 eval-skips=0.' -Offset 7),
    (New-LogLine '[MGPU Bridge] [MGPU][R280] MVEC EXTRACT armed on a D3D12 chain (3440x1440): first launch - the source is decided by usage signature.' -Offset 8),
    (New-LogLine '[MGPU Bridge] [MGPU][P4.1] CreateFeature(Reserved18) handle 1/1 3440x1440 fmt=28: result=0x00000001 (Success)' -Offset 9)
)
Write-Fixture ($base+$probes)
Assert-State 'Bound' $true $true $false $false 'Startup probes, feature creation and unrelated armed tags never prove live streaming'
Write-Fixture ($base+@($binding,$arm,(New-LogLine '[MGPU Bridge] [MGPU][P5.0] the bridge window is now showing the NEURAL INPUT (mgpu.ini Present=in) - the transited game frame as it was handed to DLSS-NR, BEFORE the neural stage.' -Offset 7)))
Assert-State 'Armed' $true $true $true $false 'Input presentation does not establish a successful neural output'
Write-Fixture ($base+@($binding,$arm,$output,(New-LogLine '[MGPU Bridge] [MGPU][P4.1] EvaluateFeature f=40 pass 1/1: 0xBAD00001 (FAIL_FeatureNotSupported)' -Level ERROR -Offset 8)))
Assert-State 'Armed' $true $true $true $false 'A later neural evaluation failure revokes streaming evidence'
Write-Fixture ($base+@($binding,$arm,$output,(New-LogLine '[MGPU Bridge] [MGPU][SEAL] CONTRACT MISMATCH f=50: seal 1x1 fmt=28 pitch=256 bytes=256 | expected 3440x1440 fmt=28 pitch=13824 bytes=19906560' -Level ERROR -Offset 8)))
Assert-State 'Armed' $true $true $true $false 'A later transport error also revokes streaming evidence'
Write-Fixture ($base+@($binding,$arm,$output,(New-LogLine '[MGPU Bridge] [MGPU][T5] releasing NGX before the device goes: armed=1 neural=1 NR handles=1/0 SR handle=no. THIS IS THE STEP THAT WAS MISSING' -Offset 8)))
Assert-State 'Unknown' $true $false $false $false 'Shutdown must also revoke binding and manual-arm eligibility'
Write-Fixture ($base+@($binding,$arm,$output,(New-LogLine '[MGPU Bridge] [MGPU][P4.0] STREAM PASSED - 600 game frames sealed, transited and checked with no drop, no reorder, no alias and no contract mismatch.' -Offset 8)))
Assert-State 'Unknown' $true $false $false $false 'A completed bounded stream is no longer eligible to arm'
Write-Fixture ($base+@($binding,$arm,$output,(New-LogLine '[MGPU Bridge] [MGPU][T4] device removed: GetDeviceRemovedReason hr=0x887A0005 (sticky - the bridge is stopping)' -Level ERROR -Offset 8)))
Assert-State 'Unknown' $true $false $false $false 'Device loss revokes binding and live flags'
Write-Fixture ($base+@((New-LogLine '[MGPU Bridge] [MGPU][R189] ERROR 207: REFUSING TO ARM - the game''s render device reports adapter luid=0x00000000-0x000134A3 and the bridge built its device on that same adapter ("NVIDIA GeForce RTX 3090", rule="exclusion (luid != swapchain game luid) + software filter"). Both stages would run on one card. The selection was made against the swapchain-derived luid; this line is the game''s OWN device, read at arm, and it is the authority. If this machine has an integrated GPU enabled, the rule 4 tiebreak is live - see [MGPU][T2] for the adapter table.' -Level ERROR -Offset 5)))
Assert-State 'Mismatch' $true $false $false $false 'Own-device ERROR207 overrides earlier matching T2 roles and denies manual arm'
Assert-True ((Read-State).RenderLuid -ceq $neural) 'ERROR207 reports the authoritative own-device render identity'
Write-Fixture ($base+@($binding,($arm -replace 'hr=0x00000000','hr=0x80070057'),(New-LogLine '[MGPU Bridge] [MGPU][P4.0] arm failed - the stream is inert for this launch and the game''s command list is never touched' -Level ERROR -Offset 7)))
Assert-State 'Unknown' $true $false $false $false 'An inert stream after allocation failure is ineligible to arm'
Write-Fixture ($base -replace '0x00000000-0x000134A3','0x00000000-0x00014B7A')
Assert-State 'Mismatch' $true $false $false $false 'Same physical adapter is rejected'
Write-Fixture ($base -replace '0x00000000-0x00014B7A','0x00000000-0x00015555')
Assert-State 'Mismatch' $true $false $false $false 'Unexpected game adapter is rejected'
Write-Fixture @($startup,$version,(New-LogLine '[MGPU Bridge] [MGPU][T2] init_device luid=0x00000000-0x00014B7A captured as PROVISIONAL game luid' -Offset 2))
Assert-State 'Unknown' $true $false $false $false 'Provisional init_device cannot establish the game renderer'
Write-Fixture ($base+@(($binding -replace '0x00000000-0x000134A3','0x00000000-0x00019999'),$arm,$output))
Assert-State 'Unknown' $false $false $false $false 'Conflicting own-device and startup bindings fail closed'
Write-Fixture ($base+@('# '+$binding,'# '+$arm,'# '+$output))
Assert-State 'Bound' $true $true $false $false 'Commented log-like text is not runtime evidence'
Write-Fixture ($base+@($binding,$arm,$output)) -Partial
Assert-State 'Unknown' $false $false $false $false 'Partial final line fails closed during concurrent writing'
Write-Fixture (@($startup,$version,($swap -replace '0x00014B7A','not-a-luid'),$selected,$device))
Assert-State 'Unknown' $false $false $false $false 'Malformed binding tags are unverified'
Write-Fixture ($base+@($binding,($arm -replace 'payload=19906560','payload=99999999999999999999999999999999')))
Assert-State 'Unknown' $false $false $false $false 'Malformed numeric fields fail closed without throwing'
Write-Fixture ($base+@($binding,$arm,($output -replace '\| INFO  \|','| ERROR |')))
Assert-State 'Unknown' $false $false $false $false 'An error-level positive-output lookalike is not source-format success evidence'
Write-Fixture ($base+@($binding,$arm,$output,$startup))
Assert-State 'Unknown' $false $false $false $false 'Combined sessions cannot reuse earlier binding or output'
Write-Fixture ($base+@($binding,$arm,$output) -replace 'MGPU Bridge 0.3.1-t1','MGPU Bridge 99.0.0')
Assert-State 'Unknown' $false $false $false $false 'Unsupported source formats cannot establish a verified runtime'
$stale=($startupUtc.AddHours(-2).ToLocalTime().ToString('HH:mm:ss:fff',[Globalization.CultureInfo]::InvariantCulture))
Write-Fixture ($base+@($binding,$arm,$output) -replace [regex]::Escape($stamp),$stale)
[IO.File]::SetLastWriteTimeUtc($logPath,[DateTime]::UtcNow)
Assert-State 'Unknown' $false $false $false $false 'A touched old startup does not become current-session evidence'
Write-Fixture ($base+@($binding,$arm,$output))
Assert-True ((Get-NeuralLogPrefixHash -LogPath (Join-Path $fixture 'missing.log')) -ceq 'ABSENT') 'Pre-launch fingerprint distinguishes a missing log'
$emptyPath=Join-Path $fixture 'empty.log'
[IO.File]::WriteAllBytes($emptyPath,[byte[]]@())
Assert-True ((Get-NeuralLogPrefixHash -LogPath $emptyPath) -ceq 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855') 'An existing empty log has an explicit fingerprint'
$oldHash=Get-NeuralLogPrefixHash -LogPath $logPath
Assert-True ($oldHash -cmatch '^[0-9A-F]{64}$') 'Fingerprint is SHA256 of the raw log prefix'
$same=Get-NeuralLogState -LogPath $logPath -ExpectedRenderLuid $render -ExpectedNeuralLuid $neural -NotBeforeUtc $sessionUtc -PreviousPrefixHash $oldHash
Assert-True ($same.Status -eq 'Unknown' -and -not $same.Fresh) 'Unchanged historic prefix fails even with a fresh modification time and identical startup clock'
$noPrefix=Get-NeuralLogState -LogPath $logPath -ExpectedRenderLuid $render -ExpectedNeuralLuid $neural -NotBeforeUtc $sessionUtc
Assert-True ($noPrefix.Status -eq 'Unknown' -and -not $noPrefix.Fresh) 'A launch timestamp alone cannot establish that the log belongs to this boot'
$sha=[Security.Cryptography.SHA256]::Create()
try {
    $raw=[IO.File]::ReadAllBytes($logPath)
    $expectedHash=([BitConverter]::ToString($sha.ComputeHash($raw,0,[int][Math]::Min(4096,$raw.Length)))).Replace('-','')
    Assert-True ($oldHash -ceq $expectedHash) 'Fingerprint hashes bytes rather than decoded text'
} finally { $sha.Dispose() }
Write-Fixture ($base+@((New-LogLine ('Padding '+('z' * 6000)) -Offset 5),$binding,$arm,$output))
$oldHash=Get-NeuralLogPrefixHash -LogPath $logPath
[IO.File]::AppendAllText($logPath,((New-LogLine 'Historic log touched by a later diagnostic' -Offset 8)+"`r`n"),[Text.UTF8Encoding]::new($false))
$appended=Get-NeuralLogState -LogPath $logPath -ExpectedRenderLuid $render -ExpectedNeuralLuid $neural -NotBeforeUtc $sessionUtc -PreviousPrefixHash $oldHash
Assert-True ($appended.Status -eq 'Unknown' -and -not $appended.Fresh) 'Appending historic evidence cannot establish a new session'
Write-Fixture ($base+@($binding,$arm,$output))
$renewed=Get-NeuralLogState -LogPath $logPath -ExpectedRenderLuid $render -ExpectedNeuralLuid $neural -NotBeforeUtc $sessionUtc -PreviousPrefixHash $oldHash
Assert-True ($renewed.Status -eq 'Streaming' -and $renewed.Fresh) 'A replaced prefix and corresponding startup establish a new session'
Write-Fixture @('a' * (8*1024*1024+1))
Assert-State 'Unknown' $false $false $false $false 'Oversized logs are bounded and unverified'
Write-Fixture ($base+@($binding,$arm,$output))
$shared=[IO.File]::Open($logPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
try { Assert-State 'Streaming' $true $true $true $true 'A reader supports concurrently open writer handles' } finally { $shared.Dispose() }
$exclusive=[IO.File]::Open($logPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    Assert-State 'Unknown' $false $false $false $false 'An exclusive writer makes log state unverified'
    $threw=$false
    try { Get-NeuralLogPrefixHash -LogPath $logPath | Out-Null } catch { $threw=$true }
    Assert-True $threw 'Fingerprint read errors must throw rather than pretending the file was absent'
} finally { $exclusive.Dispose() }
Write-Output ('All runtime observation tests passed using '+$PSVersionTable.PSVersion+'. No game files or native processes were touched.')
