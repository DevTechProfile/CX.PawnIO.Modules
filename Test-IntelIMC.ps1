#requires -RunAsAdministrator
# Drives ioctl_read_imc_clock from IntelIMC.amx via PawnIOLib.dll and decodes the
# 7-cell output buffer against the constants documented in IntelIMC.p.
#
# Usage (from an elevated PowerShell, in the repo root):
#   .\Test-IntelIMC.ps1
#   .\Test-IntelIMC.ps1 -BclkMHz 100 -AmxPath .\IntelIMC.amx

[CmdletBinding()]
param(
    [string]$AmxPath  = (Join-Path $PSScriptRoot 'IntelIMC.amx'),
    [string]$PawnIODir = 'C:\Program Files\PawnIO',
    [double]$BclkMHz  = 100.0
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $AmxPath))                   { throw "AMX not found: $AmxPath" }
if (-not (Test-Path "$PawnIODir\PawnIOLib.dll")) { throw "PawnIOLib.dll not found in $PawnIODir" }
$env:Path = "$PawnIODir;$env:Path"

$src = @'
using System;
using System.Runtime.InteropServices;
public static class PawnIO {
    [DllImport("PawnIOLib.dll", EntryPoint="pawnio_version", CallingConvention=CallingConvention.StdCall)]
    public static extern int pawnio_version(out uint version);
    [DllImport("PawnIOLib.dll", EntryPoint="pawnio_open", CallingConvention=CallingConvention.StdCall)]
    public static extern int pawnio_open(out IntPtr handle);
    [DllImport("PawnIOLib.dll", EntryPoint="pawnio_load", CallingConvention=CallingConvention.StdCall)]
    public static extern int pawnio_load(IntPtr handle, byte[] blob, UIntPtr size);
    [DllImport("PawnIOLib.dll", EntryPoint="pawnio_execute", CallingConvention=CallingConvention.StdCall, CharSet=CharSet.Ansi)]
    public static extern int pawnio_execute(IntPtr handle,
        [MarshalAs(UnmanagedType.LPStr)] string name,
        ulong[] inBuf, UIntPtr inCount,
        ulong[] outBuf, UIntPtr outCount,
        out UIntPtr returnCount);
    [DllImport("PawnIOLib.dll", EntryPoint="pawnio_close", CallingConvention=CallingConvention.StdCall)]
    public static extern int pawnio_close(IntPtr handle);
}
'@
if (-not ('PawnIO' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

function ConvertTo-UInt32([int]$hr) {
    # Reinterpret Int32 bits as UInt32. PowerShell's checked [uint32] cast
    # throws on negative Int32, so we widen and mask instead.
    return [uint32](([int64]$hr) -band 0xFFFFFFFFL)
}
function Format-HResult([int]$hr) { '0x{0:X8}' -f (ConvertTo-UInt32 $hr) }

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cpuModelDec = ([regex]::Match($cpu.Description, 'Model (\d+)').Groups[1].Value -as [int])
"Host CPU       : $($cpu.Name)"
"               : $($cpu.Description)  (Model 0x{0:X2})" -f $cpuModelDec
'AMX            : {0} ({1} bytes, SHA256 {2})' -f $AmxPath,
    (Get-Item $AmxPath).Length,
    ((Get-FileHash $AmxPath -Algorithm SHA256).Hash.Substring(0,16) + '...')

$ver = 0
[void][PawnIO]::pawnio_version([ref]$ver)
$maj = ($ver -shr 16) -band 0xFFFF; $min = ($ver -shr 8) -band 0xFF; $pat = $ver -band 0xFF
"PawnIOLib      : $maj.$min.$pat"

$h = [IntPtr]::Zero
$hr = [PawnIO]::pawnio_open([ref]$h)
'pawnio_open    : {0}, handle=0x{1:X}' -f (Format-HResult $hr), $h.ToInt64()
if ($hr -ne 0) {
    $u = ConvertTo-UInt32 $hr
    if     ($u -eq 0x80070005) { Write-Error 'E_ACCESSDENIED - run from an elevated PowerShell.' }
    elseif ($u -eq 0x80070057) { Write-Error 'E_INVALIDARG from pawnio_open - check PawnIOLib.dll/driver versions match.' }
    else                       { Write-Error "pawnio_open failed: $(Format-HResult $hr)" }
    return
}

try {
    $blob = [System.IO.File]::ReadAllBytes($AmxPath)
    $hr = [PawnIO]::pawnio_load($h, $blob, [UIntPtr]::new([uint64]$blob.Length))
    'pawnio_load    : {0}' -f (Format-HResult $hr)
    if ($hr -ne 0) { Write-Error "pawnio_load failed: $(Format-HResult $hr)"; return }

    $inBuf  = [uint64[]]::new(0)
    $outBuf = [uint64[]]::new(7)
    $ret    = [UIntPtr]::Zero
    $hr = [PawnIO]::pawnio_execute($h, 'ioctl_read_imc_clock',
        $inBuf,  [UIntPtr]::new([uint64]0),
        $outBuf, [UIntPtr]::new([uint64]7),
        [ref]$ret)
    'pawnio_execute : {0}, return_count={1}' -f (Format-HResult $hr), $ret.ToUInt64()

    if ($hr -ne 0) {
        # NTSTATUS surfaced as HRESULT 0xC0000000 | status. Compare as hex strings to
        # avoid PowerShell 5.1's signed-Int32 parsing of 0xC0000000-class literals.
        switch (Format-HResult $hr) {
            '0xC00000BB' { Write-Warning 'STATUS_NOT_SUPPORTED - module rejected the platform / register.' }
            '0xC0000022' { Write-Warning 'STATUS_ACCESS_DENIED' }
            '0x80070057' { Write-Warning 'E_INVALIDARG - function name unknown to module, or in/out cell counts wrong.' }
            default      { Write-Warning ("Unmapped HRESULT/NTSTATUS: $(Format-HResult $hr)") }
        }
    }

    ''
    'Raw output:'
    for ($i = 0; $i -lt 7; $i++) {
        '  out[{0}] = 0x{1:X16} ({1})' -f $i, $outBuf[$i]
    }

    if ($hr -ne 0) {
        # Live IOCTL refused; ask the diagnostic IOCTL why.
        ''
        '--- Calling diagnostic IOCTL ioctl_read_imc_clock_dbg ---'
        $dbgOut = [uint64[]]::new(10)
        $dbgRet = [UIntPtr]::Zero
        $dhr = [PawnIO]::pawnio_execute($h, 'ioctl_read_imc_clock_dbg',
            $inBuf,  [UIntPtr]::new([uint64]0),
            $dbgOut, [UIntPtr]::new([uint64]10),
            [ref]$dbgRet)
        'pawnio_execute(dbg) : {0}, return_count={1}' -f (Format-HResult $dhr), $dbgRet.ToUInt64()
        if ($dhr -eq 0) {
            $stepNames = @{
                0='OK (would have succeeded)'
                1='FAIL_FAMILY (CPU family != 6)'
                2='FAIL_PLATFORM (CPU model not in allowlist)'
                3='FAIL_SOURCE (no register source for platform)'
                4='FAIL_MCHBAR_OFF (MCHBAR enable bit clear)'
                5='FAIL_BASE_ZERO (MCHBAR base masked to 0)'
                6='FAIL_PMA_RSVD (MEMSS_PMA reserved bits 31:9 nonzero)'
                7='FAIL_PMA_RANGE (MEMSS_PMA ratio out of [16,220])'
                8='FAIL_SA_RANGE (SA_PERF ratio out of [16,220])'
            }
            $fms        = [uint64]$dbgOut[1]
            $famByte    = [int](($fms -shr 16) -band 0xFF)
            $modByte    = [int](($fms -shr  8) -band 0xFF)
            $stpByte    = [int]( $fms          -band 0xFF)
            $platNames  = @{0='NONE';1='MTL';2='ARL';3='LNL';4='PTL';5='ADL';6='RPL'}
            $srcNames   = @{0='NONE';1='MCHBAR_MEMSS_PMA';2='MCHBAR_SA_PERF';3='PMT_QCLK_STATUS'}

            $rawPma     = [uint64]$dbgOut[7]
            $pmaRatio   = [int]($rawPma -band 0xFF)
            $pmaGear    = [int](($rawPma -shr 8) -band 0x1)
            $pmaRsvd    = [uint64]($rawPma -band 0xFFFFFE00)

            $rawSa      = [uint64]$dbgOut[8]
            $saRatio    = [int](($rawSa -shr 2) -band 0xFF)
            $saRefBit   = [int](($rawSa -shr 10) -band 0x1)

            $step       = [int]$dbgOut[9]

            ''
            'Diagnostic decode:'
            "  ABI version          : $($dbgOut[0])"
            '  CPUID FMS            : family=0x{0:X2} model=0x{1:X2} stepping=0x{2:X2}' -f $famByte,$modByte,$stpByte
            "  Platform tag         : $($dbgOut[2]) ($($platNames[[int]$dbgOut[2]]))"
            "  Source tag           : $($dbgOut[3]) ($($srcNames[[int]$dbgOut[3]]))"
            '  MCHBAR low  (raw)    : 0x{0:X8}'  -f $dbgOut[4]
            '  MCHBAR high (raw)    : 0x{0:X8}'  -f $dbgOut[5]
            '  MCHBAR base (masked) : 0x{0:X16}' -f $dbgOut[6]
            '  MEMSS_PMA raw        : 0x{0:X8}  (ratio={1}, gear_bit={2}, reserved=0x{3:X8})' -f $rawPma,$pmaRatio,$pmaGear,$pmaRsvd
            '  SA_PERF raw          : 0x{0:X8}  (ratio={1}, refbit={2})' -f $rawSa,$saRatio,$saRefBit
            "  Failing step         : $step ($($stepNames[$step]))"
        }
        return
    }

    $abi      = [int]$outBuf[0]
    $source   = [int]$outBuf[1]
    $ratio    = [int]$outBuf[2]
    $refMode  = [int]$outBuf[3]
    $gear     = [int]$outBuf[4]
    $raw      = [uint32]$outBuf[5]
    $flags    = [int]$outBuf[6]

    $sourceName  = @{0='NONE'; 1='MCHBAR_MEMSS_PMA'; 2='MCHBAR_SA_PERF'; 3='PMT_QCLK_STATUS'}[$source]
    $refName     = @{0='UNKNOWN'; 1='BCLK/3'; 2='BCLK'; 3='BCLK*4/3'}[$refMode]
    $gearName    = @{0='UNKNOWN'; 1='Gear1'; 2='Gear2'; 4='Gear4'}[$gear]

    $flagNames = @()
    if ($flags -band 1) { $flagNames += 'STATIC_LOCKED' }
    if ($flags -band 2) { $flagNames += 'LIVE_CURRENT'  }
    if ($flags -band 4) { $flagNames += 'EXPERIMENTAL'  }
    if (-not $flagNames) { $flagNames = @('(none)') }

    ''
    'Decoded:'
    "  ABI version  : $abi"
    "  Source       : $source ($sourceName)"
    "  Ratio        : $ratio"
    "  Ref clock    : $refMode ($refName)"
    "  Gear         : $gear ($gearName)"
    "  Raw register : 0x{0:X8}" -f $raw
    "  Flags        : 0x{0:X} ({1})" -f $flags, ($flagNames -join ' | ')

    # Compute memory clock the way a consumer would.
    $refMHz = switch ($refMode) {
        1 { $BclkMHz / 3.0 }
        2 { $BclkMHz }
        3 { $BclkMHz * 4.0 / 3.0 }
        default { $null }
    }
    if ($null -ne $refMHz) {
        $qclkMHz = $ratio * $refMHz
        # On Core Ultra MEMSS_PMA, QCLK is the quad-pumped clock = data_rate / 4,
        # so the DRAM IO clock (the "MHz" tools like HWiNFO/CPU-Z report) is QCLK * 2.
        # The Gear field tells you the controller-fabric ratio vs DRAM, but the
        # IO clock derivation from QCLK is the same regardless of gear.
        $ioClockMHz = $qclkMHz * 2.0
        ''
        'Computed memory clock (assumes BCLK = {0} MHz):' -f $BclkMHz
        '  ref clock  : {0:N3} MHz' -f $refMHz
        '  QCLK       : {0:N3} MHz' -f $qclkMHz
        '  IO clock   : {0:N0} MHz   (compare to HWiNFO "Memory Clock")' -f $ioClockMHz
    }

    # Also probe the live workpoint IOCTL. Returns STATUS_NOT_SUPPORTED on
    # ADL/RPL (the static IOCTL is already live there).
    ''
    'Live workpoint (ioctl_read_imc_clock_live):'
    $liveOut = [uint64[]]::new(7)
    $liveRet = [UIntPtr]::Zero
    $liveHr = [PawnIO]::pawnio_execute($h, 'ioctl_read_imc_clock_live',
        $inBuf,  [UIntPtr]::new([uint64]0),
        $liveOut, [UIntPtr]::new([uint64]7),
        [ref]$liveRet)
    if ($liveHr -ne 0) {
        '  HRESULT      : {0}  (live IOCTL not applicable here)' -f (Format-HResult $liveHr)
    } else {
        $liveRatio = [int]$liveOut[2]
        $liveRaw   = [uint32]$liveOut[5]
        $liveIoMHz = $liveRatio * $BclkMHz / 3.0 * 2.0
        '  Raw SA_PERF  : 0x{0:X8}' -f $liveRaw
        '  Live ratio   : {0}' -f $liveRatio
        '  Live IO clock: {0:N0} MHz' -f $liveIoMHz
        '  Live data    : {0:N0} MT/s' -f ($liveIoMHz * 2.0)
    }
}
finally {
    [void][PawnIO]::pawnio_close($h)
}
