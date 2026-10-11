Set-StrictMode -Version Latest
# Log contracts: MGPU Bridge 0.3.1, commit
# 1f8160452379ef57b07a198ea0cc5aea6c8092a5, src/gpu1_context.cpp,
# src/adapter.cpp and src/worker.cpp. ReShade startup clocks omit the date;
# freshness therefore also requires the caller's pre-launch prefix fingerprint.

function Get-NeuralBytesHash {
    param([byte[]]$Bytes,[int]$Count)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes,0,$Count))).Replace('-','') } finally { $sha.Dispose() }
}

function Test-NeuralPositiveCount {
    param([string]$Text)
    [UInt64]$value=0
    return ([UInt64]::TryParse($Text,[ref]$value) -and $value -gt 0)
}

function Get-NeuralLogPrefixHash {
    [CmdletBinding()] param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LogPath)
    $stream=$null
    try {
        try { $stream=[IO.File]::Open($LogPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)) }
        catch [IO.FileNotFoundException] { return 'ABSENT' }
        catch [IO.DirectoryNotFoundException] { return 'ABSENT' }
        $count=[int][Math]::Min(4096,$stream.Length)
        $bytes=New-Object byte[] $count
        $read=0
        while ($read -lt $count) {
            $n=$stream.Read($bytes,$read,$count-$read)
            if ($n -eq 0) { throw 'The log prefix changed while it was read.' }
            $read+=$n
        }
        return Get-NeuralBytesHash -Bytes $bytes -Count $count
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Read-NeuralLogSnapshot {
    param([string]$LogPath)
    $stream=$null
    try {
        $before=New-Object IO.FileInfo $LogPath
        $before.Refresh()
        $stream=[IO.File]::Open($LogPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $length=$stream.Length
        if ($length -eq 0 -or $length -gt 8MB) { throw 'The log is empty or exceeds the 8 MiB observation limit.' }
        $mtime=$before.LastWriteTimeUtc
        $bytes=New-Object byte[] ([int]$length)
        $read=0
        while ($read -lt $length) {
            $n=$stream.Read($bytes,$read,[int]$length-$read)
            if ($n -eq 0) { throw 'The log was truncated while it was read.' }
            $read+=$n
        }
        $after=New-Object IO.FileInfo $LogPath
        $after.Refresh()
        if (-not $after.Exists -or $stream.Length -ne $length -or $after.Length -ne $length -or $after.LastWriteTimeUtc -ne $mtime) { throw 'The log changed while it was read; retry after its writer settles.' }
        $encoding=New-Object Text.UTF8Encoding($false,$true)
        $content=$encoding.GetString($bytes)
        if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content=$content.Substring(1) }
        if ($content.Contains([string][char]0) -or -not $content.EndsWith("`n")) { throw 'The log contains invalid text or an incomplete final line.' }
        return [pscustomobject]@{Text=$content;LastWriteUtc=$mtime;PrefixHash=(Get-NeuralBytesHash -Bytes $bytes -Count ([int][Math]::Min(4096,$length)))}
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-NeuralLogState {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LogPath,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{8}$')][string]$ExpectedRenderLuid,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{8}$')][string]$ExpectedNeuralLuid,
        [AllowNull()][Nullable[DateTime]]$NotBeforeUtc=$null,
        [AllowNull()][string]$PreviousPrefixHash
    )
    $result=[pscustomobject]@{
        Status='Unknown';Fresh=$false;RenderLuid=$null;NeuralLuid=$null;BindingVerified=$false;Armed=$false;Streaming=$false
        Message='No current-session runtime evidence is available.';LastWriteUtc=$null
    }
    try { $snapshot=Read-NeuralLogSnapshot -LogPath $LogPath } catch { $result.Message='The log is missing, unreadable, incomplete or changing; runtime is unverified.'; return $result }
    $result.LastWriteUtc=$snapshot.LastWriteUtc
    $expectedRender=$ExpectedRenderLuid.ToUpperInvariant()
    $expectedNeural=$ExpectedNeuralLuid.ToUpperInvariant()
    $luid='0x(?<high>[0-9A-Fa-f]{8})-0x(?<low>[0-9A-Fa-f]{8})'
    $pair='0x([0-9A-Fa-f]{8})-0x([0-9A-Fa-f]{8})'
    $linePattern='^(?<time>(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d:\d{3}) \[\d+\] \| (?<level>INFO |WARN |ERROR|DEBUG|TRACE) \| (?<body>.*)$'
    $startupPattern="^Initializing crosire's ReShade version '[^']+' \(64-bit\) loaded from '[^']+' into '[^']+' \(0x[0-9A-Fa-f]+\) \.\.\.$"
    $records=New-Object 'Collections.Generic.List[object]'
    $invalid=$false
    $startupCount=0
    $versionSeen=$false
    $ownBinding=$false
    $armed=$false
    $streaming=$false
    $rolesComplete=$false
    $deviceFailed=$false
    $terminated=$false
    $collapsed=$false
    $parseMessage='The log has incomplete or conflicting adapter evidence.'
    foreach ($line in ($snapshot.Text -split "`n")) {
        $line=$line.TrimEnd([char]13)
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*(#|;|//)') { continue }
        if ($line.Length -gt 32768 -or $line -notmatch $linePattern) { $invalid=$true; break }
        $time=$Matches.time
        $body=$Matches.body
        $level=$Matches.level.Trim()
        $records.Add([pscustomobject]@{Time=$time;Body=$body})
        if ($body -match $startupPattern) { $startupCount++; if ($records.Count -ne 1 -or $level -ne 'INFO') { $invalid=$true }; continue }
        if ($body -notmatch '^\[MGPU Bridge\] \[MGPU\]\[(?<tag>[^\]]+)\] (?<text>.*)$') {
            if ($body -match '^Shutting down|^Unloading ReShade') { $terminated=$true; $armed=$false; $streaming=$false }
            continue
        }
        $tag=$Matches.tag; $text=$Matches.text
        # A later logged runtime error revokes a successful-output claim even
        # when its exact failure category is not otherwise understood here.
        if ($level -eq 'ERROR') { $streaming=$false }
        if ($tag -eq 'R141') {
            if ($level -ne 'INFO' -or $versionSeen -or $text -notmatch '^MGPU Bridge 0\.3\.1-t1 \| built .+ \| add-on API 20\.') { $invalid=$true; break }
            $versionSeen=$true; continue
        }
        if ($tag -eq 'T2' -and $text.StartsWith('init_swapchain:')) {
            if ($level -ne 'INFO' -or -not $versionSeen) { $invalid=$true; break }
            if ($text -notmatch ('^init_swapchain: swapchain-derived game luid='+$luid+' established \(the device CreateSwapChainForHwnd was called on\) - overrides the provisional init_device value$')) { $invalid=$true; break }
            $value=$Matches.high.ToUpperInvariant()+'-'+$Matches.low.ToUpperInvariant()
            if ($null -ne $result.RenderLuid -and $result.RenderLuid -cne $value) { $invalid=$true; break }
            $result.RenderLuid=$value; continue
        }
        if ($tag -eq 'T2' -and $text.StartsWith('SELECTED ')) {
            if ($level -ne 'INFO' -or -not $versionSeen) { $invalid=$true; break }
            if ($text -notmatch ('^SELECTED adapter\[\d+\] luid='+$pair+' desc="[^"]+" outputs=\d+ rule="[^"]+" \| game luid='+$pair+' \(source: swapchain\)$')) { $invalid=$true; break }
            $neural=$Matches[1].ToUpperInvariant()+'-'+$Matches[2].ToUpperInvariant()
            $render=$Matches[3].ToUpperInvariant()+'-'+$Matches[4].ToUpperInvariant()
            if ($null -eq $result.RenderLuid -or $render -cne $result.RenderLuid -or ($null -ne $result.NeuralLuid -and $neural -cne $result.NeuralLuid)) { $invalid=$true; break }
            $result.NeuralLuid=$neural; $rolesComplete=$true; continue
        }
        if ($tag -eq 'T3' -and $text.StartsWith('D3D12CreateDevice hr=')) {
            if ($text -notmatch ('^D3D12CreateDevice hr=0x(?<hr>[0-9A-Fa-f]{8}) luid='+$luid+' - .+$')) { $invalid=$true; break }
            if ($null -eq $result.NeuralLuid -or ($Matches.high.ToUpperInvariant()+'-'+$Matches.low.ToUpperInvariant()) -cne $result.NeuralLuid) { $invalid=$true; break }
            if ($Matches.hr -ne '00000000') { $deviceFailed=$true; $armed=$false; $streaming=$false }
            continue
        }
        if ($tag -eq 'T2' -and $text.StartsWith('init_swapchain ')) {
            if ($text -notmatch ('^init_swapchain(?: \(resize\))? luid='+$pair+' - swapchain-derived game luid '+$pair+' already established; not re-selecting$')) { $invalid=$true; break }
            if ($null -eq $result.RenderLuid -or ($Matches[3].ToUpperInvariant()+'-'+$Matches[4].ToUpperInvariant()) -cne $result.RenderLuid) { $invalid=$true; break }
            continue
        }
        if ($tag -eq 'R189' -and $text.StartsWith('BINDING CONFIRMED AT ARM:')) {
            if ($level -ne 'INFO') { $invalid=$true; break }
            if ($text -notmatch ('^BINDING CONFIRMED AT ARM: the game renders on adapter luid='+$pair+' and the bridge is on luid='+$pair+' \("[^"]+"\)\. Different adapters, read from the game''s OWN device rather than from the luid the selection was made against\.$')) { $invalid=$true; break }
            if (-not $rolesComplete -or ($Matches[1].ToUpperInvariant()+'-'+$Matches[2].ToUpperInvariant()) -cne $result.RenderLuid -or ($Matches[3].ToUpperInvariant()+'-'+$Matches[4].ToUpperInvariant()) -cne $result.NeuralLuid) { $invalid=$true; break }
            $ownBinding=$true; continue
        }
        if ($tag -eq 'R189' -and $text.StartsWith('ERROR 207:')) {
            if ($level -ne 'ERROR' -or $text -notmatch ('^ERROR 207: REFUSING TO ARM - the game''s render device reports adapter luid='+$luid+' and the bridge built its device on that same adapter \("[^"]+", rule="[^"]+"\)\. Both stages would run on one card\..+$')) { $invalid=$true; break }
            $actual=$Matches.high.ToUpperInvariant()+'-'+$Matches.low.ToUpperInvariant()
            if (-not $rolesComplete -or $actual -cne $result.NeuralLuid) { $invalid=$true; break }
            # This is read from the frame-producing device itself and overrides
            # the earlier swapchain selection; manual-arm guidance is unsafe.
            $result.RenderLuid=$actual
            $collapsed=$true; $armed=$false; $streaming=$false
            continue
        }
        if ($tag -eq 'P4.0' -and $text.StartsWith('stream arm ')) {
            if ($level -ne 'INFO') { $invalid=$true; break }
            if ($text -notmatch '^stream arm hr=0x(?<hr>[0-9A-Fa-f]{8}) source=(?<width>\d+)x(?<height>\d+) fmt=\d+ rowPitch=\d+ payload=(?<payload>\d+) slot=\d+ ring=(?<ring>\d+) heap=\d+ bytes\. .+ Seal v\d+, \d+ bytes\..*$') { $invalid=$true; break }
            if ($Matches.hr -ne '00000000') { $terminated=$true; $armed=$false; $streaming=$false; continue }
            if (-not $ownBinding -or -not (Test-NeuralPositiveCount $Matches.width) -or -not (Test-NeuralPositiveCount $Matches.height) -or -not (Test-NeuralPositiveCount $Matches.payload) -or -not (Test-NeuralPositiveCount $Matches.ring)) { $invalid=$true; break }
            $armed=$true; $streaming=$false; continue
        }
        if ($tag -eq 'P5.0' -and $text.StartsWith('the bridge window is now showing the ')) {
            if ($level -ne 'INFO') { $invalid=$true; break }
            # In this pinned source nr_final remains null until final_pass_ok.
            # Present=in can show copied input before a successful NR output.
            $outputPattern='^the bridge window is now showing the (?:NEURAL OUTPUT - every pixel on screen is a pixel DLSS-NR produced on the second adapter|SPLIT \(Present=split\) - LEFT half is the frame handed TO DLSS-NR, RIGHT half is what DLSS-NR produced, and BOTH ARE THE SAME FRAME\. Same instant, same camera, same lighting, one white seam between them\. Any difference across that seam is the model and nothing else) - (?:THE WHOLE|a 1:1 centre crop) of the (?<w>\d+)x(?<h>\d+) frame at (?<cw>\d+)x(?<ch>\d+), one CopyTextureRegion, no resampling in this add-on\. The cycling colour returns when the stream ends\.$'
            if ($text -match $outputPattern) {
                if (-not $armed -or -not (Test-NeuralPositiveCount $Matches.w) -or -not (Test-NeuralPositiveCount $Matches.h) -or -not (Test-NeuralPositiveCount $Matches.cw) -or -not (Test-NeuralPositiveCount $Matches.ch)) { $invalid=$true; break }
                $streaming=$true
            } elseif (-not $text.StartsWith('the bridge window is now showing the NEURAL INPUT (mgpu.ini Present=in)')) { $invalid=$true; break }
            continue
        }
        if ($tag -eq 'P4.1' -and $text.StartsWith('EvaluateFeature f=')) {
            # gpu1_context.cpp logs this per-frame tag ONLY on failed evaluates.
            $streaming=$false; continue
        }
        if (($tag -eq 'P4.0' -and $text -match '^(arm failed|STREAM PASSED|STREAM FAILED|FAULT-INJECTED RUN)') -or ($tag -eq 'T5' -and $text -match '^(releasing NGX before the device goes:|entering the ordered release|NGX features released\.)')) { $terminated=$true; $armed=$false; $streaming=$false; continue }
        if (($tag -eq 'T4' -and $text -match '^(device removed: GetDeviceRemovedReason|bridge thread exiting)') -or ($tag -eq 'T3' -and $text.StartsWith('bridge thread exiting'))) { $terminated=$true; $armed=$false; $streaming=$false; continue }
        if (($tag -eq 'P4.1' -and $level -eq 'ERROR') -or ($tag -eq 'P8.1' -and $text.StartsWith('f='))) { $streaming=$false }
    }
    if ($invalid -or $startupCount -ne 1 -or -not $versionSeen -or $records.Count -eq 0) { $result.Message='The log is malformed, incomplete, conflicting or from an unsupported bridge build; runtime is unverified.'; return $result }
    if ($null -eq $NotBeforeUtc -or [string]::IsNullOrWhiteSpace($PreviousPrefixHash)) { $result.Message='Historic log evidence is unverified; a current launch timestamp and pre-launch log fingerprint are required.'; return $result }
    $previous=$PreviousPrefixHash.ToUpperInvariant()
    if (($previous -ne 'ABSENT' -and $previous -notmatch '^[0-9A-F]{64}$') -or $snapshot.PrefixHash -ceq $previous) { $result.Message='The log prefix has not changed since before launch; historic or appended evidence is unverified.'; return $result }
    $anchor=([DateTime]$NotBeforeUtc).ToUniversalTime()
    $now=[DateTime]::UtcNow
    if ($anchor -gt $now.AddSeconds(1) -or $snapshot.LastWriteUtc -lt $anchor -or $snapshot.LastWriteUtc -gt $now.AddSeconds(2)) { $result.Message='The log modification time does not correspond to the current launch.'; return $result }
    try {
        $localAnchor=$anchor.ToLocalTime()
        $clock=[DateTime]::ParseExact($records[0].Time,'HH:mm:ss:fff',[Globalization.CultureInfo]::InvariantCulture).TimeOfDay
        $localStartup=[DateTime]::SpecifyKind($localAnchor.Date.Add($clock),[DateTimeKind]::Unspecified)
        if (($localStartup-$localAnchor).TotalHours -lt -12) { $localStartup=$localStartup.AddDays(1) }
        if ([TimeZoneInfo]::Local.IsInvalidTime($localStartup) -or [TimeZoneInfo]::Local.IsAmbiguousTime($localStartup)) { throw 'Ambiguous startup clock.' }
        $startupUtc=[TimeZoneInfo]::ConvertTimeToUtc($localStartup)
        if ($startupUtc -lt $anchor.AddSeconds(-1) -or $startupUtc -gt $anchor.AddMinutes(5) -or $startupUtc -gt $snapshot.LastWriteUtc.AddSeconds(1)) { throw 'Startup does not correspond to this launch.' }
        $last=$startupUtc
        $day=$localStartup.Date
        foreach ($record in $records) {
            $clock=[DateTime]::ParseExact($record.Time,'HH:mm:ss:fff',[Globalization.CultureInfo]::InvariantCulture).TimeOfDay
            $localLine=[DateTime]::SpecifyKind($day.Add($clock),[DateTimeKind]::Unspecified)
            $utc=[TimeZoneInfo]::ConvertTimeToUtc($localLine)
            if (($utc-$last).TotalHours -lt -12) { $day=$day.AddDays(1); $localLine=$localLine.AddDays(1); $utc=[TimeZoneInfo]::ConvertTimeToUtc($localLine) }
            if ($utc -lt $last.AddSeconds(-1) -or $utc -lt $startupUtc.AddSeconds(-1) -or $utc -gt $snapshot.LastWriteUtc.AddSeconds(1)) { throw 'Inconsistent log clock order.' }
            if ($utc -gt $last) { $last=$utc }
        }
    } catch { $result.Message='The startup timestamp or subsequent log clocks do not correspond to this launch; runtime is unverified.'; return $result }
    $result.Fresh=$true
    if (-not $rolesComplete) { $result.Message=$parseMessage; return $result }
    if ($collapsed) { $result.Status='Mismatch'; $result.Message='The game''s own device reports both stages on the same adapter (ERROR 207); binding is invalid and the bridge refused to arm.'; return $result }
    if ($terminated) { $result.Message='This session logged shutdown, device loss or an ended/failed stream; binding and streaming are no longer current.'; return $result }
    if ($deviceFailed -or $result.RenderLuid -ceq '00000000-00000000' -or $result.NeuralLuid -ceq '00000000-00000000') { $result.Message='The selected bridge device failed to initialize or its identity is invalid; runtime is unverified.'; return $result }
    if ($result.RenderLuid -ceq $result.NeuralLuid -or $expectedRender -ceq $expectedNeural -or $result.RenderLuid -cne $expectedRender -or $result.NeuralLuid -cne $expectedNeural) { $result.Status='Mismatch'; $result.Message='The fresh log adapter roles differ from the configured render and neural cards.'; return $result }
    $result.BindingVerified=$true
    $result.Status='Bound'
    $result.Message='Fresh swapchain and bridge adapter roles match; neural streaming has not been verified.'
    if ($armed) { $result.Armed=$true; $result.Status='Armed'; $result.Message='The stream armed on the verified adapters; successful neural output has not been observed.' }
    if ($streaming -and $armed) { $result.Streaming=$true; $result.Status='Streaming'; $result.Message='This fresh session logged successfully produced neural output on the verified adapters; ongoing stability is not established.' }
    return $result
}

Export-ModuleMember -Function Get-NeuralLogState,Get-NeuralLogPrefixHash
