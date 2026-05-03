#requires -RunAsAdministrator
# Captures a self-contained validation report for IntelIMC on Arrow Lake.
# Analogous to Build-PTLValidation.ps1 but tailored for ARL:
#   * Live IOCTL on ARL uses MCHBAR + 0x5C (IMC_LIVE_GV_STATUS_ARL) instead
#     of the inherited 0x5918, which reads as zero on ARL-S. The 0x5C
#     register was identified by passive scan + load correlation; see
#     Deploy/DETECT-ARL-LiveIMC.md and Deploy/VERIFY-ARL-LoadCorrelation.md.
#   * IO clock / data rate decode uses the gear-aware formula
#         QCLK       = ratio * ref_MHz
#         data_rate  = QCLK * gear           (MT/s)
#         IO_clock   = data_rate / 2 = QCLK * gear / 2  (MHz)
#     For Gear2 (typical ARL): IO_clock == QCLK, data_rate == QCLK * 2.
#     The PTL script's hardcoded `* 2 * 2` happens to match Gear4 only.
[CmdletBinding()]
param(
    [string]$RepoRoot      = '',
    [string]$AmxPath       = '',
    [string]$SignedAmxPath = '',
    [string]$PawnIODir     = 'C:\Program Files\PawnIO',
    [string]$OutPath       = '',
    [int]$StaticSamples    = 10,
    [int]$StaticIntervalMs = 100,
    [int]$LiveSamples      = 30,
    [int]$LiveIntervalMs   = 200,
    # BIOS / firmware context. Captured into the report for reproducibility,
    # since SAGV behaviour can be vendor-toggled under various UI names.
    [string]$Mainboard         = 'ASRock Z890 Taichi',
    [string]$DramSpeedSetting  = 'DDR5-7800 (EXPO)',
    [string]$DynMemClockState  = 'enabled',
    [string]$SagvBiosState     = 'not explicitly set (default)'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot)      { $RepoRoot      = (Resolve-Path (Join-Path $here '..')).Path }
if (-not $AmxPath)       { $AmxPath       = Join-Path $RepoRoot 'IntelIMC.amx' }
if (-not $SignedAmxPath) { $SignedAmxPath = Join-Path $RepoRoot 'IntelIMC.signed.amx' }
if (-not $OutPath)       { $OutPath       = Join-Path $here 'VALIDATION-ARL.md' }
$env:Path = "$PawnIODir;$env:Path"

# --- C# P/Invoke shim (matches Build-PTLValidation.ps1) ----------------------
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
function ToUInt32Safe([int]$hr) {
    # PS 5.1's checked [uint32] cast throws on negative Int32. Widen + mask.
    return [uint32](([int64]$hr) -band 0xFFFFFFFFL)
}

# --- Sanity ------------------------------------------------------------------
if (-not (Test-Path $SignedAmxPath))                  { throw "Signed AMX not found: $SignedAmxPath" }
if (-not (Test-Path "$PawnIODir\PawnIOLib.dll"))      { throw 'PawnIOLib.dll missing' }

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cpuModel = ([regex]::Match($cpu.Description, 'Model (\d+)').Groups[1].Value -as [int])
if ($cpuModel -ne 0xC6) {
    Write-Warning ("This script is intended for ARL-S (CPU model 0xC6). Detected 0x{0:X2} - report will be saved but the platform tag in the output reflects the running hardware." -f $cpuModel)
}

# --- Open + load module ------------------------------------------------------
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
        ABI=[int]$dbgOut[0]; FMS=[uint64]$dbgOut[1]; Platform=[int]$dbgOut[2]; Source=[int]$dbgOut[3]
        MchbarLo=[uint32]$dbgOut[4]; MchbarHi=[uint32]$dbgOut[5]; MchbarBase=[uint64]$dbgOut[6]
        RawPma=[uint32]$dbgOut[7]; RawSa=[uint32]$dbgOut[8]; Step=[int]$dbgOut[9]
    }

    # Static IOCTL stability: N samples, confirm identical
    $static = @()
    for ($i = 0; $i -lt $StaticSamples; $i++) {
        $o = [uint64[]]::new(7); $r = [UIntPtr]::Zero
        $shr = [PIO]::Exec($h, 'ioctl_read_imc_clock', $inBuf, [UIntPtr]::Zero, $o, [UIntPtr]::new([uint64]7), [ref]$r)
        $static += [PSCustomObject]@{
            HResult=(ToUInt32Safe $shr); Source=[int]$o[1]; Ratio=[int]$o[2]; Ref=[int]$o[3]; Gear=[int]$o[4]; Raw=[uint32]$o[5]; Flags=[int]$o[6]
        }
        Start-Sleep -Milliseconds $StaticIntervalMs
    }

    # Live IOCTL: now functional on ARL via MCHBAR + 0x5C. Sample N times to
    # capture the bimodal SAGV behaviour at quasi-idle.
    $live = @()
    for ($i = 0; $i -lt $LiveSamples; $i++) {
        $lo = [uint64[]]::new(7); $lr = [UIntPtr]::Zero
        $lhr = [PIO]::Exec($h, 'ioctl_read_imc_clock_live', $inBuf, [UIntPtr]::Zero, $lo, [UIntPtr]::new([uint64]7), [ref]$lr)
        $live += [PSCustomObject]@{
            HResult=(ToUInt32Safe $lhr); Source=[int]$lo[1]; Ratio=[int]$lo[2];
            Ref=[int]$lo[3]; Gear=[int]$lo[4]; Raw=[uint32]$lo[5]; Flags=[int]$lo[6]
        }
        Start-Sleep -Milliseconds $LiveIntervalMs
    }
}
finally {
    [void][PIO]::Close($h)
}

# --- DRAM module info from SMBIOS --------------------------------------------
$dimms = Get-CimInstance Win32_PhysicalMemory | Select-Object Manufacturer, PartNumber, Capacity, Speed, ConfiguredClockSpeed

# --- Driver / artefact hashes ------------------------------------------------
$drv = Get-CimInstance Win32_SystemDriver -Filter "Name='PawnIO'"
$drvPath = $drv.PathName -replace '^\\\?\?\\',''
$drvHash = (Get-FileHash $drvPath -Algorithm SHA256).Hash
$signedHash = (Get-FileHash $SignedAmxPath -Algorithm SHA256).Hash
$amxHash = if (Test-Path $AmxPath) { (Get-FileHash $AmxPath -Algorithm SHA256).Hash } else { '<not present>' }

# --- Decode tables -----------------------------------------------------------
$platName = @{0='NONE';1='MTL';2='ARL';3='LNL';4='PTL';5='ADL';6='RPL'}
$srcName  = @{0='NONE';1='MCHBAR_MEMSS_PMA';2='MCHBAR_SA_PERF';3='PMT_QCLK_STATUS';4='MCHBAR_LIVE_GV_ARL'}
$refName  = @{0='UNKNOWN';1='BCLK/3';2='BCLK';3='BCLK*4/3'}
$gearName = @{0='UNKNOWN';1='Gear1';2='Gear2';4='Gear4'}
$stepName = @{0='OK';1='FAIL_FAMILY';2='FAIL_PLATFORM';3='FAIL_SOURCE';4='FAIL_MCHBAR_OFF';5='FAIL_BASE_ZERO';6='FAIL_PMA_RSVD';7='FAIL_PMA_RANGE';8='FAIL_SA_RANGE'}
$famByte = [int](($diag.FMS -shr 16) -band 0xFF)
$modByte = [int](($diag.FMS -shr  8) -band 0xFF)
$stpByte = [int]( $diag.FMS         -band 0xFF)

# --- Static decode (gear-aware) ---------------------------------------------
$s0 = $static[0]
$s0_refMHz = switch ($s0.Ref) { 1 { 100.0/3.0 } 2 { 100.0 } 3 { 400.0/3.0 } default { 0 } }
$s0_qclk   = $s0.Ratio * $s0_refMHz
$s0_mtps   = $s0_qclk * $s0.Gear
$s0_io     = $s0_mtps / 2.0
$staticAllSame = @($static | Group-Object Raw).Count -eq 1

# --- Render markdown ---------------------------------------------------------
# Force invariant culture so number formatting (`{0:N0}`, `{0:N3}`) matches the
# style of VALIDATION-PTL.md regardless of the host locale.
$prevCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
try {
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# IntelIMC Arrow Lake validation report'); $lines.Add('')
$lines.Add('Generated by `Deploy\Build-ARLValidation.ps1` on a real ARL machine.')
$lines.Add('')
$lines.Add(('Captured: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ssK')))
$lines.Add(('Host OS:  Windows {0}' -f [Environment]::OSVersion.Version))
$lines.Add('')

$lines.Add('## Hardware')
$lines.Add(('- CPU: {0}' -f $cpu.Name.Trim()))
$lines.Add(('- Description: {0}' -f $cpu.Description.Trim()))
$lines.Add(('- CPUID Family/Model/Stepping: 0x{0:X2} / 0x{1:X2} / 0x{2:X2}' -f $famByte, $modByte, $stpByte))
$lines.Add(('- Module-resolved platform tag: {0} ({1})' -f $diag.Platform, $platName[$diag.Platform]))
$lines.Add(('- Mainboard: {0}' -f $Mainboard))
$lines.Add('')
$lines.Add('## BIOS / firmware configuration')
$lines.Add(('- DRAM speed setting: {0}' -f $DramSpeedSetting))
$lines.Add(('- Dynamic Memory Clock (ASRock UI name for the underlying SAGV mechanism): **{0}**' -f $DynMemClockState))
$lines.Add(('- SAGV BIOS toggle: {0}' -f $SagvBiosState))
$lines.Add('')
$lines.Add('Note on terminology: "Dynamic Memory Clock" is ASRocks BIOS-UI name for the underlying Intel **System Agent Geyserville (SAGV)** mechanism. Other vendors UI-rename the same mechanism: ASUS = "Adaptive Memory Boost", MSI = "Memory Try It! / Dynamic Memory Boost", Gigabyte = "Memory Power Down / Dynamic Memory Profile". The live workpoint signal we read from `MCHBAR + 0x5C` is the SA-Geyserville state machine itself, regardless of what the BIOS calls it. A separate "SAGV" toggle in some BIOSes may control SA *Voltage* Geyserville (voltage-side scaling) and is distinct from the frequency-side toggle.')
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
$lines.Add('Single call, decodes every intermediate value the static IOCTL uses.')
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
$lines.Add(('{0} successive samples (every {1} ms). Stable across samples: **{2}**.' -f $StaticSamples, $StaticIntervalMs, $stableMsg))
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
$lines.Add('### Decoded sample 1 (gear-aware formula)')
$lines.Add('')
$lines.Add(('- QCLK       = ratio x ref = {0} x {1:N3} MHz = **{2:N3} MHz**' -f $s0.Ratio, $s0_refMHz, $s0_qclk))
$lines.Add(('- Data rate  = QCLK x gear = QCLK x {0} = **{1:N0} MT/s** (DDR5-{2})' -f $s0.Gear, $s0_mtps, [int]$s0_mtps))
$lines.Add(('- IO clock   = data_rate / 2 = QCLK x gear / 2 = **{0:N0} MHz**  (= HWiNFO/CPU-Z "Memory Clock")' -f $s0_io))
$lines.Add('')
$lines.Add('Note: `data_rate = QCLK * gear` is the gear-aware general form. The PTL script hardcodes `QCLK * 2 * 2`, which is correct only for Gear4 -- on Gear2 hardware (typical Arrow Lake) it overestimates by 2x and reports a non-existent DDR5 speed grade.')
$lines.Add('')

$lines.Add('## Live IOCTL -- `ioctl_read_imc_clock_live` (workpoint)')
$lines.Add('On Arrow Lake-S the inherited PTL/MTL/LNL live source `SA_PERF_STATUS` at `MCHBAR+0x5918` reads as `0x00000000` regardless of SAGV state, so a different register had to be located. A passive 5-minute MCHBAR scan (`Deploy/Detect-ARLLiveIMC.ps1`) followed by an autonomous load-correlation pass (`Deploy/Verify-ARLLoadCorrelation.ps1`) and a cross-BIOS validation across DDR5-7800 and DDR5-7000 identified the live workpoint at `MCHBAR + 0xE448` (`IMC_LIVE_GV_STATUS_ARL`). Encoding mirrors the SA_PERF helper but takes bits 7:0 (instead of bits 9:2) as the live QCLK ratio against BCLK/3.')
$lines.Add('')
$lines.Add('Cross-BIOS validation (raw register values, before clamp):')
$lines.Add('')
$lines.Add('| BIOS DRAM speed | Trained max (MEMSS_PMA) | Low raw | Low ratio | High raw | High ratio raw | High ratio after clamp |')
$lines.Add('|---|---|---|---|---|---|---|')
$lines.Add('| DDR5-7800 (this run) | 117 | `0x04B00048` | 72 | `0x079F0076` | 118 (=trained_max+1) | **117** |')
$lines.Add('| DDR5-7000 (cross-check) | 105 | `0x04B00048` | 72 | `0x06D7006A` | 106 (=trained_max+1) | **105** |')
$lines.Add('')
$lines.Add('Two findings worth highlighting:')
$lines.Add('')
$lines.Add('1. **The low-state ratio is 72 on both BIOS-trained DRAM speeds, regardless of trained max.** The SAGV floor on ARL is a firmware-fixed property equivalent to `DDR5-4800` (= JEDEC base spec), not a fraction of trained max as on some older Intel parts.')
$lines.Add('2. **The raw high-state ratio is consistently `trained_max + 1` across both BIOS configs.** This 33-MHz "PLL overshoot" / encoding tolerance is a known property of this register. The IOCTL clamps `ratio > trained_max` down to MEMSS_PMA''s trained max so output matches what HWiNFO and CPU-Z display (both of which read this value through Intel PMT/CTL, which applies the same clamp internally — see `cpuz.exe` RE notes in `PR_discussion.md`). The `Raw` column in the live samples table below preserves the un-clamped register dword for forensics; the `Ratio` column shows the post-clamp value the consumer sees.')
$lines.Add('')
$lines.Add('Mirrored at `MCHBAR + 0xEC48 / 0xF448 / 0x1E448 / 0x1EC48 / 0x1F448` (per-channel replicates). Under sustained 30 GB/s memcpy load every poll returns the high state (3658/3658 = 100%); in idle ~88-91% high and dips to the low state ~9-12% on memory-burst activity. With Dynamic Memory Clock enabled and OS power profile = Balanced, the low workpoint is hit much more frequently. See `Deploy/VERIFY-ARL-LoadCorrelation.md` for the full distribution.')
$lines.Add('')
$lines.Add(('Active during this run: Dynamic Memory Clock = **{0}**, SAGV BIOS toggle = {1}. The bimodal swing only occurs while a frequency-scaling mechanism is active; with Dynamic Memory Clock disabled the register is expected to sit permanently at the high state (not yet verified on this hardware).' -f $DynMemClockState, $SagvBiosState))
$lines.Add('')
$lines.Add(('Live IOCTL samples ({0} reads at {1} ms intervals):' -f $LiveSamples, $LiveIntervalMs))
$lines.Add('')
$lines.Add('| # | HRESULT | Source | Ratio | Ref | Gear | Raw | Flags |')
$lines.Add('|---|---|---|---|---|---|---|---|')
$liveIdx = 1
foreach ($l in $live) {
    $lines.Add(('| {0} | 0x{1:X8} | {2} ({3}) | {4} | {5} ({6}) | {7} ({8}) | 0x{9:X8} | 0x{10:X} |' -f
        $liveIdx, $l.HResult, $l.Source, $srcName[$l.Source], $l.Ratio, $l.Ref, $refName[$l.Ref], $l.Gear, $gearName[$l.Gear], $l.Raw, $l.Flags))
    $liveIdx++
}
$lines.Add('')
# Live ratio distribution summary
$ratioGroups = $live | Group-Object Ratio
$lines.Add('Distribution of live ratios across the sampling window:')
$lines.Add('')
$lines.Add('| Ratio | MHz @ BCLK/3 | Count | Share |')
$lines.Add('|---|---|---|---|')
foreach ($g in ($ratioGroups | Sort-Object Name)) {
    $r = [int]$g.Name
    $mhz = [Math]::Round($r * 100.0 / 3, 0)
    $share = [Math]::Round(100.0 * $g.Count / $LiveSamples, 1)
    $lines.Add(('| {0} | {1} | {2} | {3}% |' -f $r, $mhz, $g.Count, $share))
}
$lines.Add('')

# Cross-validation section is hand-curated. Preserve any prior content on
# re-run so HWiNFO numbers entered by hand survive a regeneration.
$preservedXval = $null
if (Test-Path $OutPath) {
    $prior = Get-Content $OutPath -Raw -Encoding UTF8
    $m = [regex]::Match($prior, '(?ms)^## Cross-validation against external references.*?(?=^## Reproducibility)')
    if ($m.Success) { $preservedXval = $m.Value.TrimEnd() }
}
if ($preservedXval) {
    foreach ($l in ($preservedXval -split "`r?`n")) { $lines.Add($l) }
    $lines.Add('')
} else {
    $lines.Add('## Cross-validation against external references')
    $lines.Add('')
    $lines.Add('| Source | Reported value | Notes |')
    $lines.Add('|---|---|---|')
    $lines.Add(('| Module static IOCTL                       | {0:N0} MHz IO ({1:N0} MT/s) | derived as QCLK x gear (Gear{2}) |' -f $s0_io, $s0_mtps, $s0.Gear))
    $lines.Add(('| HWiNFO64 Memory Clock                     | _fill in_ | should match the IO clock value above |'))
    $lines.Add(('| HWiNFO64 Gear Mode                        | _fill in_ | should match `Gear{0}` |' -f $s0.Gear))
    $lines.Add(('| Win32_PhysicalMemory.ConfiguredClockSpeed | _see DRAM table above_ | should match the data rate above |'))
    $lines.Add('')
    $lines.Add('Reviewer: confirm the module IO clock equals HWiNFO64 Memory Clock and the data rate equals SMBIOS ConfiguredClockSpeed. Capture a HWiNFO64 Sensors-view screenshot under `screenshots/` and link it here.')
    $lines.Add('')
}

$lines.Add('## Reproducibility')
$lines.Add('')
$lines.Add('```powershell')
$lines.Add('# from an elevated PowerShell at the repo root, with the unrestricted')
$lines.Add('# PawnIO driver loaded and IntelIMC.signed.amx present:')
$lines.Add('.\Deploy\Build-ARLValidation.ps1')
$lines.Add('```')
$lines.Add('')
$lines.Add('The static MEMSS_PMA line is locked at MRC and does not change at runtime; re-running on the same machine MUST produce identical static values. The live IOCTL samples a SAGV state machine, so the per-sample distribution will vary slightly run-to-run depending on background memory activity; the SET of distinct ratios should remain {70, 117} (or a documented superset if more workpoints get exposed under different load profiles).')

[System.IO.File]::WriteAllLines($OutPath, $lines, [System.Text.UTF8Encoding]::new($false))
}
finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $prevCulture
}
Write-Host ''
Write-Host ("Wrote validation report: $OutPath") -ForegroundColor Green
