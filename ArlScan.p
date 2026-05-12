// ArlScan.p — diagnostic-only PCI scanner for Core Ultra OOBMSM discovery.
//
// Drop-in standalone module: doesn't claim any specific BDF, just exposes
// raw PCI-config reads + a sweep IOCTL. Used for Phase 1 of the ARL
// OOBMSM bring-up when 00:0A.0 turns out to be empty (as it does on
// ARL-S desktop).
//
// Run via PawnIOUtil interactive (unrestricted driver, no signing):
//   PawnIOUtil interactive ArlScan.amx
//   ioctl_pci_read 1 0000000a00000000  -> reads (b=0,d=0,f=0,off=0)
//
// Or batch via stdin redirection from PowerShell.

#include <pawnio.inc>

NTSTATUS:main() {
    return STATUS_SUCCESS;
}

/// Read a DWORD from arbitrary PCI config space.
///
/// @param in [0]=bus, [1]=device, [2]=function, [3]=offset
/// @param in_size 4
/// @param out [0]=value
/// @param out_size 1
DEFINE_IOCTL_SIZED(ioctl_pci_read, 4, 1) {
    new bus = in[0];
    new dev = in[1];
    new fn  = in[2];
    new off = in[3];
    new value = 0;
    new NTSTATUS:status = pci_config_read_dword(bus, dev, fn, off, value);
    out[0] = value;
    return status;
}

/// Sweep a (bus, device, function) range and report every endpoint
/// whose vendor-id is Intel (0x8086). Optionally narrow to a class-code
/// match.
///
/// @param in [0]=bus_lo, [1]=bus_hi, [2]=class_match (0 = any),
///          [3]=class_mask (0 = ignore class entirely)
/// @param in_size 4
/// @param out packed entries: [0]=count, then [count] pairs of
///            [bdf32 = (bus<<16)|(dev<<8)|fn, vid_did, class_rev]
///            i.e. 3 cells per entry. Buffer must be sized for
///            1 + 3*N cells; we cap N at 64.
/// @param out_size 1 + 3*64 = 193 cells
DEFINE_IOCTL_SIZED(ioctl_pci_scan_intel, 4, 193) {
    new bus_lo = in[0];
    new bus_hi = in[1];
    new class_match = in[2];
    new class_mask  = in[3];

    new count = 0;
    for (new bus = bus_lo; bus <= bus_hi && count < 64; bus++) {
        for (new dev = 0; dev < 32 && count < 64; dev++) {
            for (new fn = 0; fn < 8 && count < 64; fn++) {
                new vid_did = 0;
                new NTSTATUS:s = pci_config_read_dword(bus, dev, fn, 0, vid_did);
                if (!NT_SUCCESS(s))
                    continue;
                if ((vid_did & 0xFFFF) != 0x8086)
                    continue;
                if (vid_did == 0xFFFFFFFF)
                    continue;
                new class_rev = 0;
                pci_config_read_dword(bus, dev, fn, 0x08, class_rev);
                if (class_mask != 0 && (class_rev & class_mask) != (class_match & class_mask))
                    continue;
                new bdf32 = (bus << 16) | (dev << 8) | fn;
                new base = 1 + count * 3;
                out[base + 0] = bdf32;
                out[base + 1] = vid_did;
                out[base + 2] = class_rev;
                count++;
                // function 0 of a non-multi-function device:
                // if (fn == 0) and header type bit-7 not set, skip 1..7
                // — skipping that optimization, sweep is fast enough.
            }
        }
    }
    out[0] = count;
    return STATUS_SUCCESS;
}

public NTSTATUS:unload() {
    return STATUS_SUCCESS;
}
