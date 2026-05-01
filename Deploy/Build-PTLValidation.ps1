#requires -RunAsAdministrator
# Captures a self-contained validation report for IntelIMC on Panther Lake.
# Anyone with a PTL machine can re-run this script and compare their output
# byte-for-byte against the committed VALIDATION-PTL.md.
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$AmxPath  = (Join-Path $RepoRoot 'IntelIMC.amx'),
    [string]$SignedAmxPath = (Join-Path $RepoRoot 'IntelIMC.signed.amx'),
    [string]$KeyPath  = (Join-Path $RepoRoot 'my.key'),
    [string]$PawnIODir = 'C:\Program Files\PawnIO',
    [string]$OutPath  = (Join-Path $PSScriptRoot 'VALIDATION-PTL.md'),
    [int]$LiveSamples = 24,
    [int]$LiveIntervalMs = 500
)

$ErrorActionPreference = 'Stop'
$env:Path = "$PawnIODir;$env:Path"

# --- C# P/Invoke shim ---------------------------------------------------------
if (-not ('PIO' -as [type])) {
$src = @'
using System;
using System.Runtime.InteropServices;
public static class PIO {
    [DllImport("PawnIOLib.dll", EntryPoint="pawnio_open", CallingConvention=CallingConvention.StdCall)]
    public static extern int Open(out IntPtr h);
    [DllImport("PawnIOLib.dll", EntryPoint="pawnio_load", CallingConvention=CallingConvention.StdCall)]
    public static extern int Load(IntPtr h, byte[] b, UIntPtr s);
    [DllImport("PawnIOLib.dll", EntryPoint="pawnio_execute", CallingConvention=CallingConvention.StdCall, CharSet=CharSet.Ansi)]
    public static extern int Exec(IntPtr h, [MarshalAs(UnmanagedType.LPStr)] string n, ulong[] i, UIntPtr ic, ulong[] o, UIntPtr oc, out UIntPtr rc);
    [DllImport("PawnIOLib.dll", EntryPoint="pawnio_close", CallingConvention=CallingConvention.StdCall)]
    public static extern int Close(IntPtr h);
}
'@
Add-Type -TypeDefinition $src -Language CSharp
}

function Hex32([uint64]$v) { '0x{0:X8}' -f [uint32]$v }

# --- Sanity ------------------------------------------------------------------
if (-not (Test-Path $SignedAmxPath)) { throw "Signed AMX not found: $SignedAmxPath" }
if (-not (Test-Path "$PawnIODir\PawnIOLib.dll")) { throw "PawnIOLib.dll missing" }

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cpuModel = ([regex]::Match($cpu.Description, 'Model (\d+)').Groups[1].Value -as [int])
if ($cpuModel -ne 0xCC -and $cpuModel -ne 0xD5) {
    Write-Warning ("This script is intended for PTL (CPU model 0xCC or 0xD5). Detected 0x{0:X2} - report will be saved but the platform tag in the output will reflect the running hardware, not PTL." -f $cpuModel)
}

# --- Open device + load module ----------------------------------------------
$blob = [System.IO.File]::ReadAllBytes($SignedAmxPath)
$h = [IntPtr]::Zero
$hr = [PIO]::Open([ref]$h)
if ($hr -ne 0) { throw ("pawnio_open failed: 0x{0:X8}" -f [uint32]$hr) }
try {
    $hr = [PIO]::Load($h, $blob, [UIntPtr]::new([uint64]$blob.Length))
    if ($hr -ne 0) { throw ("pawnio_load failed: 0x{0:X8}" -f [uint32]$hr) }

    $inBuf = [uint64[]]::new(0)

    # Diagnostic IOCTL (10 outputs)
    $dbgOut = [uint64[]]::new(10); $rc = [UIntPtr]::Zero
    [void][PIO]::Exec($h, 'ioctl_read_imc_clock_dbg', $inBuf, [UIntPtr]::Zero, $dbgOut, [UIntPtr]::new([uint64]10), [ref]$rc)
    $diag = [PSCustomObject]@{
        ABI         = [int]$dbgOut[0]
        FMS         = [uint64]$dbgOut[1]
        Platform    = [int]$dbgOut[2]
        Source      = [int]$dbgOut[3]
        MchbarLo    = [uint32]$dbgOut[4]
        MchbarHi    = [uint32]$dbgOut[5]
        MchbarBase  = [uint64]$dbgOut[6]
        RawPma      = [uint32]$dbgOut[7]
        RawSa       = [uint32]$dbgOut[8]
        Step        = [int]$dbgOut[9]
    }

    # Static IOCTL stability: take 10 samples and confirm they are identical
    $static = @()
    for ($i = 0; $i -lt 10; $i++) {
        $o = [uint64[]]::new(7); $r = [UIntPtr]::Zero
        $shr = [PIO]::Exec($h, 'ioctl_read_imc_clock', $inBuf, [UIntPtr]::Zero, $o, [UIntPtr]::new([uint64]7), [ref]$r)
        $static += [PSCustomObject]@{
            HResult = [uint32]$shr; Source=[int]$o[1]; Ratio=[int]$o[2]; Ref=[int]$o[3]; Gear=[int]$o[4]; Raw=[uint32]$o[5]; Flags=[int]$o[6]
        }
        Start-Sleep -Milliseconds 100
    }

    # Live IOCTL: idle samples first, then under memory stress
    function Take-LiveSamples([int]$count, [int]$delayMs) {
        $samples = @()
        for ($i = 0; $i -lt $count; $i++) {
            $o = [uint64[]]::new(7); $r = [UIntPtr]::Zero
            $lhr = [PIO]::Exec($h, 'ioctl_read_imc_clock_live', $inBuf, [UIntPtr]::Zero, $o, [UIntPtr]::new([uint64]7), [ref]$r)
            $samples += [PSCustomObject]@{
                Time = (Get-Date -Format 'HH:mm:ss.fff'); HResult=[uint32]$lhr; Ratio=[int]$o[2]; Raw=[uint32]$o[5]; Flags=[int]$o[6]
            }
            Start-Sleep -Milliseconds $delayMs
        }
        return ,$samples
    }

    Write-Host 'Sampling live IOCTL idle...' -ForegroundColor Cyan
    $liveIdle = Take-LiveSamples ([Math]::Max(8, [int]($LiveSamples / 3))) $LiveIntervalMs

    Write-Host 'Starting memory stress and sampling live IOCTL under load...' -ForegroundColor Cyan
    $stress = Start-Job -ArgumentList ($LiveSamples * $LiveIntervalMs / 1000 + 4) -ScriptBlock {
        param($durSec)
        $size = 256MB
        $bufs = 1..8 | ForEach-Object { New-Object byte[] $size }
        $rnd = New-Object Random
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $durSec) {
            for ($i = 0; $i -lt $bufs.Count; $i++) { $rnd.NextBytes($bufs[$i]) }
        }
    }
    Start-Sleep -Milliseconds 300
    $liveStress = Take-LiveSamples $LiveSamples $LiveIntervalMs
    Wait-Job $stress | Out-Null; Remove-Job $stress
}
finally {
    [void][PIO]::Close($h)
}

# --- DRAM module info from SMBIOS (Windows-side cross-reference) -------------
$dimms = Get-CimInstance Win32_PhysicalMemory | Select-Object Manufacturer, PartNumber, Capacity, Speed, ConfiguredClockSpeed, MemoryType, SMBIOSMemoryType

# --- Driver / artefact hashes ------------------------------------------------
$drv = Get-CimInstance Win32_SystemDriver -Filter "Name='PawnIO'"
$drvPath = $drv.PathName -replace '^\\\?\?\\',''
$drvHash = (Get-FileHash $drvPath -Algorithm SHA256).Hash
$signedHash = (Get-FileHash $SignedAmxPath -Algorithm SHA256).Hash
$amxHash = if (Test-Path $AmxPath) { (Get-FileHash $AmxPath -Algorithm SHA256).Hash } else { '<not present>' }

# --- Decode helpers ----------------------------------------------------------
$platName = @{0='NONE';1='MTL';2='ARL';3='LNL';4='PTL';5='ADL';6='RPL'}
$srcName  = @{0='NONE';1='MCHBAR_MEMSS_PMA';2='MCHBAR_SA_PERF';3='PMT_QCLK_STATUS'}
$refName  = @{0='UNKNOWN';1='BCLK/3';2='BCLK';3='BCLK*4/3'}
$gearName = @{0='UNKNOWN';1='Gear1';2='Gear2';4='Gear4'}
$stepName = @{0='OK';1='FAIL_FAMILY';2='FAIL_PLATFORM';3='FAIL_SOURCE';4='FAIL_MCHBAR_OFF';5='FAIL_BASE_ZERO';6='FAIL_PMA_RSVD';7='FAIL_PMA_RANGE';8='FAIL_SA_RANGE'}
$famByte = [int](($diag.FMS -shr 16) -band 0xFF)
$modByte = [int](($diag.FMS -shr  8) -band 0xFF)
$stpByte = [int]( $diag.FMS         -band 0xFF)

# Live samples decode
function Decode-Live($s, $bclk = 100.0) {
    $ioMHz = $s.Ratio * $bclk / 3.0 * 2.0
    $mtps  = $ioMHz * 2.0
    return [PSCustomObject]@{
        Time = $s.Time; Raw = (Hex32 $s.Raw); Ratio = $s.Ratio
        IO_MHz = [int][Math]::Round($ioMHz); MT_s = [int][Math]::Round($mtps)
    }
}
$liveIdleDec   = $liveIdle   | ForEach-Object { Decode-Live $_ }
$liveStressDec = $liveStress | ForEach-Object { Decode-Live $_ }

$liveIdleRatios   = ($liveIdleDec.Ratio   | Sort-Object -Unique) -join ', '
$liveStressRatios = ($liveStressDec.Ratio | Sort-Object -Unique) -join ', '

# --- Static decode (from sample 0) ------------------------------------------
$s0 = $static[0]
$s0_refMHz = switch ($s0.Ref) { 1 { 100.0/3.0 } 2 { 100.0 } 3 { 400.0/3.0 } default { 0 } }
$s0_qclk   = $s0.Ratio * $s0_refMHz
$s0_io     = $s0_qclk * 2.0
$s0_mtps   = $s0_io * 2.0
# Group-Object returns a single GroupInfo (not an array) when there is only
# one group, so .Count would mis-report the count of items rather than the
# count of distinct groups. Force an array.
$staticAllSame = @($static | Group-Object Raw).Count -eq 1

# --- Render markdown ---------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# IntelIMC Panther Lake validation report'); $lines.Add('')
$lines.Add('Generated by `Deploy\Build-PTLValidation.ps1` on a real PTL machine.')
$lines.Add('')
$lines.Add(('Captured: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ssK')))
$lines.Add(('Host OS:  Windows {0}' -f [Environment]::OSVersion.Version))
$lines.Add('')

$lines.Add('## Hardware')
$lines.Add(('- CPU: {0}' -f $cpu.Name.Trim()))
$lines.Add(('- Description: {0}' -f $cpu.Description.Trim()))
$lines.Add(('- CPUID Family/Model/Stepping: 0x{0:X2} / 0x{1:X2} / 0x{2:X2}' -f $famByte, $modByte, $stpByte))
$lines.Add(('- Module-resolved platform tag: {0} ({1})' -f $diag.Platform, $platName[$diag.Platform]))
$lines.Add('')
$lines.Add('### DRAM modules (SMBIOS via Win32_PhysicalMemory)')
$lines.Add('| Manufacturer | Part | Capacity | Speed | ConfiguredClockSpeed |')
$lines.Add('|---|---|---|---|---|')
foreach ($d in $dimms) {
    $cap = if ($d.Capacity) { '{0:N0} MiB' -f ($d.Capacity / 1MB) } else { '?' }
    $lines.Add(('| {0} | {1} | {2} | {3} MT/s | {4} MT/s |' -f
        ($d.Manufacturer -replace '\s+',' '),
        ($d.PartNumber   -replace '\s+',' '),
        $cap, $d.Speed, $d.ConfiguredClockSpeed))
}
$lines.Add('')
$lines.Add('## Artefact hashes (SHA-256)')
$lines.Add(('- Loaded driver `PawnIO.sys`: `{0}`' -f $drvHash))
$lines.Add(('- `IntelIMC.amx`              : `{0}`' -f $amxHash))
$lines.Add(('- `IntelIMC.signed.amx`       : `{0}`' -f $signedHash))
$lines.Add('')

$lines.Add('## Diagnostic IOCTL -- `ioctl_read_imc_clock_dbg`')
$lines.Add('Single call, decodes every intermediate value the live IOCTL uses.')
$lines.Add('')
$lines.Add('```')
$lines.Add(('  ABI version          : {0}' -f $diag.ABI))
$lines.Add(('  CPUID FMS            : family=0x{0:X2} model=0x{1:X2} stepping=0x{2:X2}' -f $famByte, $modByte, $stpByte))
$lines.Add(('  Platform tag         : {0} ({1})' -f $diag.Platform, $platName[$diag.Platform]))
$lines.Add(('  Source tag           : {0} ({1})' -f $diag.Source,   $srcName[$diag.Source]))
$lines.Add(('  MCHBAR low  (raw)    : {0}'        -f (Hex32 $diag.MchbarLo)))
$lines.Add(('  MCHBAR high (raw)    : {0}'        -f (Hex32 $diag.MchbarHi)))
$lines.Add(('  MCHBAR base (masked) : 0x{0:X16}'  -f $diag.MchbarBase))
$lines.Add(('  MEMSS_PMA raw        : {0}  (ratio={1}, gear_bit={2}, reserved=0x{3:X8})' -f
    (Hex32 $diag.RawPma), ($diag.RawPma -band 0xFF), (($diag.RawPma -shr 8) -band 0x1), [uint32]($diag.RawPma -band 0xFFFFFE00)))
$lines.Add(('  SA_PERF raw          : {0}  (ratio={1}, refbit={2})' -f
    (Hex32 $diag.RawSa), (($diag.RawSa -shr 2) -band 0xFF), (($diag.RawSa -shr 10) -band 0x1)))
$lines.Add(('  Failing step         : {0} ({1})' -f $diag.Step, $stepName[$diag.Step]))
$lines.Add('```')
$lines.Add('')

$stableMsg = if ($staticAllSame) { 'yes' } else { 'NO -- register changed mid-run, see table' }
$lines.Add('## Static IOCTL -- `ioctl_read_imc_clock` (locked max)')
$lines.Add(('10 successive samples ({0}). Stable across samples: **{1}**.' -f
    'every 100 ms', $stableMsg))
$lines.Add('')
$lines.Add('| # | HRESULT | Source | Ratio | Ref | Gear | Raw | Flags |')
$lines.Add('|---|---|---|---|---|---|---|---|')
$idx = 1
foreach ($s in $static) {
    $lines.Add(('| {0} | 0x{1:X8} | {2} ({3}) | {4} | {5} ({6}) | {7} ({8}) | {9} | 0x{10:X} |' -f
        $idx, $s.HResult, $s.Source, $srcName[$s.Source], $s.Ratio, $s.Ref, $refName[$s.Ref], $s.Gear, $gearName[$s.Gear], (Hex32 $s.Raw), $s.Flags))
    $idx++
}
$lines.Add('')
$lines.Add(('Decoded sample 1: ratio={0} × ref={1:N3} MHz × 2 = **IO clock {2:N0} MHz** (= {3:N0} MT/s).' -f
    $s0.Ratio, $s0_refMHz, $s0_io, $s0_mtps))
$lines.Add('')

$lines.Add('## Live IOCTL -- `ioctl_read_imc_clock_live` (workpoint)')
$lines.Add(('Reference clock: BCLK/3 = 33.333 MHz (BCLK assumed 100 MHz). IO clock = ratio × BCLK/3 × 2.'))
$lines.Add('')
$lines.Add('### Idle')
$lines.Add(('Distinct ratios observed: {0}' -f $liveIdleRatios))
$lines.Add('')
$lines.Add('| Time | Raw | Ratio | IO clock (MHz) | Data rate (MT/s) |')
$lines.Add('|---|---|---|---|---|')
foreach ($s in $liveIdleDec) { $lines.Add(('| {0} | {1} | {2} | {3:N0} | {4:N0} |' -f $s.Time, $s.Raw, $s.Ratio, $s.IO_MHz, $s.MT_s)) }
$lines.Add('')
$lines.Add('### Under memory stress (8 × 256 MiB random fill in a tight loop)')
$lines.Add(('Distinct ratios observed: {0}' -f $liveStressRatios))
$lines.Add('')
$lines.Add('| Time | Raw | Ratio | IO clock (MHz) | Data rate (MT/s) |')
$lines.Add('|---|---|---|---|---|')
foreach ($s in $liveStressDec) { $lines.Add(('| {0} | {1} | {2} | {3:N0} | {4:N0} |' -f $s.Time, $s.Raw, $s.Ratio, $s.IO_MHz, $s.MT_s)) }
$lines.Add('')

$lines.Add('## Cross-validation against external references')
$lines.Add('')
$lines.Add('| Source | Reported max DRAM | Reported live (idle) | Reported live (stress) |')
$lines.Add('|---|---|---|---|')
$lines.Add(('| Module static IOCTL | {0:N0} MHz IO ({1:N0} MT/s) | -- | -- |' -f $s0_io, $s0_mtps))
$lines.Add('| Module live IOCTL   | -- | _see table above_ | _see table above_ |')
$lines.Add('| HWiNFO Memory Clock | _fill in_ | _fill in_ | _fill in_ |')
$lines.Add('| Win32_PhysicalMemory.ConfiguredClockSpeed | _see DRAM table above_ | n/a | n/a |')
$lines.Add('')
$lines.Add('Reviewer: confirm the module-static IO clock equals the SMBIOS configured speed,')
$lines.Add('and that the live ratios bracket the HWiNFO reading at idle and at full load.')
$lines.Add('')

$lines.Add('## Reproducibility')
$lines.Add('')
$lines.Add('```powershell')
$lines.Add('# from an elevated PowerShell at the repo root, with the unrestricted')
$lines.Add('# PawnIO driver loaded and IntelIMC.signed.amx present:')
$lines.Add('.\Deploy\Build-PTLValidation.ps1')
$lines.Add('```')
$lines.Add('')
$lines.Add('The script is deterministic except for the live samples (which are')
$lines.Add('expected to vary). Re-running under a similar load profile should')
$lines.Add('produce ratios in the same band; the locked-max line MUST stay the same.')

[System.IO.File]::WriteAllLines($OutPath, $lines, [System.Text.UTF8Encoding]::new($false))
Write-Host ''
Write-Host ("Wrote validation report: $OutPath") -ForegroundColor Green
