// MsrScan.p — diagnostic-only MSR sweeper for ARL NGU/D2D source hunt.
// No allow-list; relies on PawnIO's __try/__except around __readmsr to
// suppress #GP from undefined indices.
//
// Run via Test-MsrScan.ps1 against the unrestricted PawnIO driver.

#include <pawnio.inc>

NTSTATUS:main() {
    return STATUS_SUCCESS;
}

/// Read an arbitrary MSR. Returns the raw 64-bit value; on #GP /
/// other exception, returns the NTSTATUS as a "value" of 0xC...0000
/// pattern that the caller can detect (and the actual NTSTATUS as the
/// IOCTL return code).
///
/// @param in [0] = MSR index
/// @param in_size 1
/// @param out [0] = MSR value
/// @param out_size 1
DEFINE_IOCTL_SIZED(ioctl_msr_read_any, 1, 1) {
    new msr = in[0];
    new value = 0;
    new NTSTATUS:status = msr_read(msr, value);
    out[0] = value;
    return status;
}

/// Sweep a contiguous MSR index range and return values for indices
/// that read successfully. Caps at 256 hits per call.
///
/// @param in [0] = first MSR, [1] = last MSR (inclusive)
/// @param in_size 2
/// @param out [0] = count of hits, then [count] pairs of [msr_idx, value]
///            (2 cells each).  out_size = 1 + 2*256 = 513.
DEFINE_IOCTL_SIZED(ioctl_msr_sweep, 2, 513) {
    new lo = in[0];
    new hi = in[1];
    new count = 0;
    for (new m = lo; m <= hi && count < 256; m++) {
        new value = 0;
        new NTSTATUS:status = msr_read(m, value);
        if (!NT_SUCCESS(status))
            continue;
        new base = 1 + count * 2;
        out[base + 0] = m;
        out[base + 1] = value;
        count++;
    }
    out[0] = count;
    return STATUS_SUCCESS;
}

public NTSTATUS:unload() {
    return STATUS_SUCCESS;
}
