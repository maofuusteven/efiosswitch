<#
.SYNOPSIS
    efiosswitch - Simple and safe PowerShell UEFI OS switcher.

.DESCRIPTION
    Portable, single-file script. Uses ONLY built-in Windows components
    (bcdedit.exe, Storage cmdlets, kernel32 QueryDosDevice, shutdown.exe).
    No third-party tools, no raw NVRAM writes, no firmware flashing.

    Flow:
      1. Self-elevates (UAC prompt) if not running as Administrator.
      2. Verifies the system is booted in UEFI mode.
      3. Scans firmware (NVRAM) boot entries and resolves their path and
         the disk / partition (EFI System Partition) they live on.
      4. Asks which entry to boot, and whether to make it the boot priority.
      5. Writes {fwbootmgr} bootsequence (one-time boot) and, optionally,
         displayorder (permanent priority) through bcdedit.
      6. Flushes volume caches, checks NTFS dirty state, stops background
         jobs, then performs a full restart (not Fast Startup / hibernate)
         so every NTFS volume is cleanly unmounted.

.EXAMPLE
    Right-click > Run with PowerShell, or:
    powershell.exe -ExecutionPolicy Bypass -File .\efiosswitch.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Self-elevation
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    if (-not $PSCommandPath) {
        Write-Host 'Please save this script as efiosswitch.ps1 and run it from the file.' -ForegroundColor Red
        exit 1
    }
    try {
        $psExe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
        )
    }
    catch {
        Write-Host 'Administrator privilege was denied. Exiting.' -ForegroundColor Red
        Start-Sleep -Seconds 2
    }
    exit
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$script:Line = '=' * 47

# 32-bit PowerShell on 64-bit Windows must use Sysnative to reach real bcdedit
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $script:BcdPath = Join-Path $env:windir 'Sysnative\bcdedit.exe'
}
else {
    $script:BcdPath = Join-Path $env:windir 'System32\bcdedit.exe'
}

function Show-Banner {
    Clear-Host
    Write-Host $script:Line
    Write-Host 'efiosswitch - Simple and safe AI generated PowerShell script OS'
    Write-Host 'switcher based on UEFI'
    Write-Host $script:Line
    Write-Host ''
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', ' OK ', 'WARN', 'FAIL')][string]$Level = 'INFO')
    $color = switch ($Level) {
        ' OK ' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Invoke-Bcd {
    param([string[]]$Arguments)
    $out = & $script:BcdPath @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    [pscustomobject]@{ Output = @($out); ExitCode = $code }
}

function Stop-WithPause {
    param([string]$Message, [int]$Code = 1)
    Write-Host ''
    Write-Host $Message -ForegroundColor Red
    Write-Host ''
    Read-Host 'Press Enter to exit' | Out-Null
    exit $Code
}

# ---------------------------------------------------------------------------
# Native helper: map \\?\Volume{GUID}\ -> \Device\HarddiskVolumeN
# (kernel32 QueryDosDevice, part of Windows itself)
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class EfiNativeDos {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint QueryDosDevice(string lpDeviceName, StringBuilder lpTargetPath, uint ucchMax);
}
"@

# ---------------------------------------------------------------------------
# Firmware data (bcdedit /enum firmware /v)
# ---------------------------------------------------------------------------
function Read-BcdBlocks {
    param([string[]]$Lines)

    $text   = ($Lines -join "`n")
    $chunks = [regex]::Split($text, "\n[ \t]*\n")
    $blocks = @()

    foreach ($chunk in $chunks) {
        $props   = @{}
        $lastKey = $null
        $seenDash = $false
        foreach ($raw in ($chunk -split "`n")) {
            $ln = $raw.TrimEnd()
            if ($ln -eq '') { continue }
            if ($ln -match '^-{3,}$') { $seenDash = $true; continue }
            if (-not $seenDash) { continue }   # header line of the block

            if ($ln -match '^\s+(\S.*)$' -and $lastKey) {
                $props[$lastKey] += $Matches[1].Trim()       # continuation line
            }
            elseif ($ln -match '^(\S+)\s+(.+)$') {
                $lastKey = $Matches[1].ToLower()
                $props[$lastKey] = @($Matches[2].Trim())
            }
        }
        if ($props.Count -gt 0) { $blocks += , $props }
    }
    return $blocks
}

function Get-FirmwareData {
    $r = Invoke-Bcd @('/enum', 'firmware', '/v')
    if ($r.ExitCode -ne 0) {
        throw "bcdedit could not read firmware entries. This system is probably not booted in UEFI mode.`n$($r.Output -join "`n")"
    }
    $blocks = Read-BcdBlocks -Lines $r.Output

    # In verbose mode bcdedit prints well-known objects by GUID, not by alias.
    # {fwbootmgr} == {a5a30fa2-3d06-4e9f-b5f4-a01df9d1fcba}
    $mgrGuid = '{a5a30fa2-3d06-4e9f-b5f4-a01df9d1fcba}'
    $mgr = $null
    foreach ($b in $blocks) {
        if (-not $b.ContainsKey('identifier')) { continue }
        $bid = $b['identifier'][0]
        if ($bid -ieq '{fwbootmgr}' -or $bid -ieq $mgrGuid) { $mgr = $b; break }
    }
    # Fallback (any language/format): the manager is the block that has a
    # displayorder but no boot path.
    if (-not $mgr) {
        foreach ($b in $blocks) {
            if ($b.ContainsKey('displayorder') -and -not $b.ContainsKey('path')) { $mgr = $b; break }
        }
    }

    $entries = @()
    foreach ($b in $blocks) {
        if (-not $b.ContainsKey('identifier')) { continue }
        if ($mgr -and [object]::ReferenceEquals($b, $mgr)) { continue }
        $id = $b['identifier'][0]
        if ($b.ContainsKey('path') -or $b.ContainsKey('description')) {
            $entries += [pscustomobject]@{
                Id          = $id
                Description = if ($b.ContainsKey('description')) { ($b['description'] -join ' ') } else { '(no description)' }
                Path        = if ($b.ContainsKey('path')) { $b['path'][0] } else { '' }
                Device      = if ($b.ContainsKey('device')) { $b['device'][0] } else { '' }
            }
        }
    }
    [pscustomobject]@{
        Manager = $mgr
        Entries = $entries
        Raw     = $r.Output
    }
}

# ---------------------------------------------------------------------------
# Partition / disk resolution
# ---------------------------------------------------------------------------
function Get-VolumeMap {
    $map = @{}
    $parts = @()
    try { $parts = @(Get-Partition -ErrorAction Stop) } catch { return $map }

    foreach ($p in $parts) {
        foreach ($ap in @($p.AccessPaths)) {
            if ($ap -match '^\\\\\?\\Volume\{([0-9a-fA-F\-]+)\}\\?$') {
                $sb = New-Object System.Text.StringBuilder 1024
                $n  = [EfiNativeDos]::QueryDosDevice("Volume{$($Matches[1])}", $sb, 1024)
                if ($n -gt 0) {
                    $map[$sb.ToString().ToLower()] = [pscustomobject]@{
                        Partition = $p
                        VolPath   = $ap
                    }
                }
            }
        }
    }
    return $map
}

function Resolve-EntryLocation {
    param($Entry, $VolumeMap)

    $result = [ordered]@{
        Location = 'Unknown (device not resolvable)'
        Volume   = ''
        File     = 'Unknown'
    }

    $dev = $Entry.Device
    $part = $null
    $volPath = $null

    if ($dev -match '(\\Device\\HarddiskVolume\d+)') {
        $key = $Matches[1].ToLower()
        $result.Volume = $Matches[1]
        if ($VolumeMap.ContainsKey($key)) {
            $part    = $VolumeMap[$key].Partition
            $volPath = $VolumeMap[$key].VolPath
        }
    }
    elseif ($dev -match 'partition=([A-Za-z]):') {
        try {
            $part = Get-Partition -DriveLetter $Matches[1] -ErrorAction Stop
            $volPath = ($part.AccessPaths | Where-Object { $_ -like '\\?\Volume*' } | Select-Object -First 1)
            $result.Volume = "$($Matches[1]):"
        }
        catch { }
    }
    elseif ($dev) {
        $result.Volume = $dev
    }

    if ($part) {
        $kind = if ($part.GptType -ieq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') { 'EFI System' } else { "$($part.Type)" }
        $mb   = [math]::Round($part.Size / 1MB)
        $result.Location = "Disk $($part.DiskNumber) / Partition $($part.PartitionNumber) ($kind, $mb MB)"
    }

    if ($volPath -and $Entry.Path) {
        try {
            $full = $volPath.TrimEnd('\') + $Entry.Path
            $result.File = if ([System.IO.File]::Exists($full)) { 'Found' } else { 'MISSING on partition' }
        }
        catch { $result.File = 'Unknown' }
    }
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Clean-up: flush caches, report NTFS dirty state, stop background work
# ---------------------------------------------------------------------------
function Invoke-SafeCleanup {
    Write-Log 'Stopping background jobs started by this session...'
    try { Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue; Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue } catch { }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    Write-Log 'Background operations stopped.' ' OK '

    Write-Log 'Flushing file system caches on all mounted NTFS volumes...'
    $vols = @()
    try {
        $vols = @(Get-Volume -ErrorAction Stop | Where-Object {
            $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS'
        })
    } catch { }

    foreach ($v in $vols) {
        $dl = "$($v.DriveLetter):"
        try {
            Write-VolumeCache -DriveLetter $v.DriveLetter -ErrorAction Stop
            Write-Log "Flushed $dl" ' OK '
        }
        catch {
            Write-Log "Could not flush $dl ($($_.Exception.Message))" 'WARN'
        }

        try {
            $q = (& fsutil.exe dirty query $dl 2>&1 | Out-String).Trim()
            if ($q -match 'NOT\s+Dirty') { Write-Log "NTFS state $dl : clean" ' OK ' }
            elseif ($q -match 'Dirty')   { Write-Log "NTFS state $dl : DIRTY - Windows will run a disk check on next start of that volume." 'WARN' }
            else                         { Write-Log "NTFS state $dl : $q" }
        }
        catch { Write-Log "NTFS state $dl : unavailable" 'WARN' }
    }
}

# ===========================================================================
# MAIN
# ===========================================================================
try {
    Show-Banner

    # --- UEFI check -------------------------------------------------------
    $fw = $null
    try { $fw = Get-FirmwareData }
    catch { Stop-WithPause "UEFI firmware entries are unavailable.`n$($_.Exception.Message)" }

    if (-not $fw.Manager) {
        Write-Host '--- raw bcdedit /enum firmware /v output ---' -ForegroundColor DarkGray
        $fw.Raw | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
        Write-Host '--------------------------------------------' -ForegroundColor DarkGray
        Stop-WithPause 'Firmware Boot Manager could not be identified in the output above. Please send this output for diagnosis.'
    }
    if ($fw.Entries.Count -eq 0) { Stop-WithPause 'No firmware boot entries were found in NVRAM.' }

    Write-Host 'Scanning EFI entries...' -ForegroundColor Cyan
    $volMap = Get-VolumeMap

    # --- Order entries by current firmware displayorder -------------------
    $order = @()
    if ($fw.Manager.ContainsKey('displayorder')) { $order = @($fw.Manager['displayorder']) }

    $sorted = @()
    foreach ($o in $order) { $sorted += @($fw.Entries | Where-Object { $_.Id -ieq $o }) }
    $sorted += @($fw.Entries | Where-Object { $order -inotcontains $_.Id })

    $list = @()
    $i = 1
    foreach ($e in $sorted) {
        $loc = Resolve-EntryLocation -Entry $e -VolumeMap $volMap
        $list += [pscustomobject]@{
            Num      = $i
            Id       = $e.Id
            Name     = $e.Description
            Path     = $e.Path
            Location = $loc.Location
            Volume   = $loc.Volume
            File     = $loc.File
            InOrder  = ($order -icontains $e.Id)
        }
        $i++
    }

    # --- Display ----------------------------------------------------------
    Show-Banner
    foreach ($x in $list) {
        $tag = ''
        if ($x.Num -eq 1 -and $x.InOrder) { $tag = '  <- current boot priority' }
        Write-Host ("[{0}] {1}{2}" -f $x.Num, $x.Name, $tag) -ForegroundColor White
        Write-Host ("    ID       : {0}" -f $x.Id)
        Write-Host ("    Path     : {0}" -f $(if ($x.Path) { $x.Path } else { '(none)' }))
        Write-Host ("    Location : {0}" -f $x.Location)
        if ($x.Volume) { Write-Host ("    Volume   : {0}" -f $x.Volume) }
        $fc = switch -Wildcard ($x.File) { 'Found' { 'Green' } 'MISSING*' { 'Red' } default { 'DarkGray' } }
        Write-Host ("    EFI file : {0}" -f $x.File) -ForegroundColor $fc
        Write-Host ''
    }

    # --- Prompt: OS number ------------------------------------------------
    $max = $list.Count
    $choice = $null
    while ($null -eq $choice) {
        $in = Read-Host "Type the OS number [1 - $max]"
        if ($in -match '^\d+$' -and [int]$in -ge 1 -and [int]$in -le $max) { $choice = $list[[int]$in - 1] }
        else { Write-Host "Invalid input. Enter a number from 1 to $max." -ForegroundColor Yellow }
    }

    if ($choice.File -like 'MISSING*') {
        Write-Host ''
        Write-Host "WARNING: the EFI file for this entry was not found on its partition." -ForegroundColor Yellow
        $go = Read-Host 'Continue anyway? [y / n]'
        if ($go -notmatch '^(y|yes)$') { Stop-WithPause 'Cancelled by user. Nothing was changed.' 0 }
    }

    # --- Prompt: priority -------------------------------------------------
    $setPriority = $null
    while ($null -eq $setPriority) {
        $in = Read-Host 'Set it as boot priority? [y / n]'
        if ($in -match '^(y|yes)$') { $setPriority = $true }
        elseif ($in -match '^(n|no)$') { $setPriority = $false }
        else { Write-Host 'Please answer y or n.' -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host $script:Line
    Write-Host ''
    Write-Log "Target entry : $($choice.Name) $($choice.Id)"
    Write-Log ("Mode         : " + $(if ($setPriority) { 'Boot once + set as boot priority' } else { 'Boot once only' }))

    # --- Safety snapshot of current firmware boot configuration -----------
    $snapDir = if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot -PathType Container)) { $PSScriptRoot } else { $env:TEMP }
    $snap = Join-Path $snapDir ("efiosswitch_backup_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $fw.Raw | Out-File -LiteralPath $snap -Encoding ASCII
        Write-Log "Firmware boot snapshot saved: $snap" ' OK '
    }
    catch {
        $snap = Join-Path $env:TEMP (Split-Path $snap -Leaf)
        try { $fw.Raw | Out-File -LiteralPath $snap -Encoding ASCII; Write-Log "Firmware boot snapshot saved: $snap" ' OK ' }
        catch { Write-Log 'Could not save firmware snapshot (continuing, no changes made yet).' 'WARN' }
    }

    # --- Write one-time boot (BootNext equivalent) ------------------------
    Write-Log 'Writing one-time boot instruction (bootsequence) to NVRAM...'
    $r = Invoke-Bcd @('/set', '{fwbootmgr}', 'bootsequence', $choice.Id)
    if ($r.ExitCode -ne 0) { throw "Failed to set bootsequence.`n$($r.Output -join "`n")" }
    Write-Log 'One-time boot instruction written.' ' OK '

    # --- Optional: change boot priority order -----------------------------
    if ($setPriority) {
        Write-Log 'Moving entry to the top of the firmware boot order (displayorder)...'
        $r = Invoke-Bcd @('/set', '{fwbootmgr}', 'displayorder', $choice.Id, '/addfirst')
        if ($r.ExitCode -ne 0) { throw "Failed to set displayorder.`n$($r.Output -join "`n")" }
        Write-Log 'Boot priority order updated.' ' OK '
    }

    # --- Verify -----------------------------------------------------------
    Write-Log 'Verifying NVRAM values...'
    $chk = Get-FirmwareData
    $okSeq = $chk.Manager.ContainsKey('bootsequence') -and (@($chk.Manager['bootsequence']) -icontains $choice.Id)
    if (-not $okSeq) { throw 'Verification failed: bootsequence does not contain the chosen entry.' }
    if ($setPriority) {
        $okOrd = $chk.Manager.ContainsKey('displayorder') -and (@($chk.Manager['displayorder'])[0] -ieq $choice.Id)
        if (-not $okOrd) { throw 'Verification failed: chosen entry is not first in displayorder.' }
    }
    Write-Log 'NVRAM values verified.' ' OK '

    # --- Cleanup ----------------------------------------------------------
    Invoke-SafeCleanup

    # --- Restart (full restart, never Fast Startup) -----------------------
    Write-Host ''
    Write-Log "Restarting into '$($choice.Name)'. Press any key within 10 seconds to cancel."
    $cancel = $false
    for ($s = 10; $s -ge 1; $s--) {
        Write-Host ("`r[INFO] Restart in {0,2} s " -f $s) -NoNewline
        $end = (Get-Date).AddSeconds(1)
        while ((Get-Date) -lt $end) {
            try { if ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null; $cancel = $true; break } } catch { }
            Start-Sleep -Milliseconds 100
        }
        if ($cancel) { break }
    }
    Write-Host ''

    if ($cancel) {
        $null = Invoke-Bcd @('/deletevalue', '{fwbootmgr}', 'bootsequence')
        Write-Log 'Restart cancelled. One-time boot instruction removed.' 'WARN'
        if ($setPriority) { Write-Log "Boot priority change remains. Snapshot for manual restore: $snap" 'WARN' }
        Read-Host 'Press Enter to exit' | Out-Null
        exit 0
    }

    Write-Log 'Restarting now...' ' OK '
    & shutdown.exe /r /t 0 /c "efiosswitch: restarting into $($choice.Name)"
    exit 0
}
catch {
    Write-Host ''
    Write-Log $_.Exception.Message 'FAIL'
    Write-Log 'No further changes were made. Firmware snapshot (if saved) can be used to restore the order manually with bcdedit.' 'WARN'
    Write-Host ''
    Read-Host 'Press Enter to exit' | Out-Null
    exit 1
}
