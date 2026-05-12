// MmioProbe.p - diagnostic-only MMIO probe for the ARL-S NGU/D2D base
// hunt. Maps a user-supplied phys address with io_space_map, reads
// up to 64 dwords (256 bytes) via virtual_read_dword, unmaps. Each
// failed dword read becomes 0xFFFFFFFE in the output (sentinel) so the
// caller sees which lanes faulted.
//
// Risk: reading from an invalid phys address can in principle trigger
// a CPU-bus abort that bypasses SEH and bug-checks the system. Caller
// should only probe phys addresses known to belong to a real PCI BAR
// or chipset MMIO aperture.

#include <pawnio.inc>

NTSTATUS:main() {
    return STATUS_SUCCESS;
}

/// Map a phys range, read N dwords, unmap.
///
/// @param in [0]=phys lo (LE u64 low), [1]=phys hi, [2]=len_dwords
/// @param in_size 3
/// @param out N dwords (up to 64) - failed reads written as 0xFFFFFFFE.
/// @param out_size 64
DEFINE_IOCTL_SIZED(ioctl_mmio_read_block, 3, 64) {
    new pa_lo = in[0];
    new pa_hi = in[1];
    new len_dwords = in[2];
    if (len_dwords < 1 || len_dwords > 64)
        return STATUS_INVALID_PARAMETER;
    new pa = (pa_hi << 32) | (pa_lo & 0xFFFFFFFF);
    new size = len_dwords * 4;
    new VA:va = io_space_map(pa, size);
    if (va == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;
    for (new i = 0; i < len_dwords; i++) {
        new value = 0;
        new NTSTATUS:status = virtual_read_dword(va + i * 4, value);
        if (NT_SUCCESS(status))
            out[i] = value & 0xFFFFFFFF;
        else
            out[i] = 0xFFFFFFFE;
    }
    io_space_unmap(va, size);
    return STATUS_SUCCESS;
}

public NTSTATUS:unload() {
    return STATUS_SUCCESS;
}
