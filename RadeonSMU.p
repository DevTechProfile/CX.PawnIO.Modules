//  PawnIO Modules - Modules for various hardware to be used with PawnIO.
//  Copyright (C) 2026  Adrenalift and CapFrameX contributors
//
//  This library is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Lesser General Public
//  License as published by the Free Software Foundation; either
//  version 2.1 of the License, or (at your option) any later version.
//
//  This library is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Lesser General Public License for more details.
//
//  You should have received a copy of the GNU Lesser General Public
//  License along with this library; if not, write to the Free Software
//  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
//
//  SPDX-License-Identifier: LGPL-2.1-or-later

/*
 * RadeonSMU - SMU mailbox and bounded telemetry access for AMD Radeon RDNA
 * GPUs.
 *
 * Replaces WinRing0/InpOut32-style raw physical MMIO for AMD GPU software.
 * Rather than handing out an unrestricted physical read/write primitive, this
 * module owns the SMN index/data sequence and allowlists the SMN addresses a
 * caller may reach.
 *
 * Discovery
 * ---------
 * The module finds the AMD display device by PCI scan and reads its own BAR
 * bases and sizes. Selection is by largest VRAM aperture rather than
 * enumeration order, so an AMD iGPU that enumerates first cannot shadow a
 * discrete card. `ioctl_get_device_info` reports the selected PCI identity in
 * addition to the apertures returned by the legacy `ioctl_get_bounds`.
 *
 * Exposed surface
 * ---------------
 *   - SMN reads/writes restricted to the MP1 C2PMSG register file
 *     (0x03B10900..0x03B10AFF, 128 registers).
 *   - The legacy fixed-size SMU14 metrics read from a caller-supplied address,
 *     bounded to the selected GPU's VRAM aperture.
 *   - Fixed-size SMU11, SMU13.0.0, SMU13.0.7, and SMU14 reads that resolve the
 *     current table address from C2PMSG_80/81 and validate the complete range
 *     against the same VRAM aperture.
 *   - No system RAM access, no other device, no framebuffer write, and no SMN
 *     address outside the mailbox window.
 *
 * The generation-specific reads take no address argument, but this is a
 * convenience rather than an additional security boundary. C2PMSG_80/81 are
 * inside the writable mailbox allowlist, so a caller can steer the derived
 * address; the legacy `ioctl_read_metrics` also accepts an address directly.
 * Every physical read remains bounded to the selected GPU's VRAM aperture.
 *
 * The module deliberately does not send an SMU message to refresh the table.
 * On the tested Navi 21 (RX 6800 XT) and Navi 31 (RX 7900 XTX), C2PMSG_80/81
 * stayed zero while driver telemetry was active. Consequently, no raw metrics
 * table was read on those cards: device discovery and the fail-closed
 * STATUS_DEVICE_NOT_READY path were validated, while the test application
 * obtained displayed metrics through its ADL PMLog fallback. The original
 * pull request author validated a real address and table read on Navi 44.
 *
 * Reference
 * ---------
 *   - Linux amdgpu `smu_cmn.c` for the mailbox protocol and
 *     `amdgpu_device.c` for PCIE_INDEX2/PCIE_DATA2 indirect SMN access.
 *   - `smu11_driver_if_sienna_cichlid.h`,
 *     `smu13_driver_if_v13_0_0.h`, `smu13_driver_if_v13_0_7.h`, and
 *     `smu14_driver_if_v14_0.h` for the metrics layouts and sizes.
 */

#include <pawnio.inc>

/// Version of the extended monitoring interface exposed by this module.
const MODULE_ABI_VERSION = 2;
/// PCI vendor ID for AMD/ATI.
const AMD_VENDOR_ID = 0x1002;

/// BAR5 offset of PCIE_INDEX2, the indirect SMN address register.
const SMN_INDEX_OFFSET = 0x38;
/// BAR5 offset of PCIE_DATA2, the indirect SMN data register.
const SMN_DATA_OFFSET = 0x3C;

/// First SMN address of the MP1 C2PMSG register file (C2PMSG_0).
const MP1_C2PMSG_BASE = 0x03B10900;
/// Byte span of the C2PMSG register file: 128 dword registers.
const MP1_C2PMSG_SPAN = 0x200;
/// High and low halves of the metrics address used by the Navi 44 protocol.
const MP1_C2PMSG_80 = MP1_C2PMSG_BASE + 80 * 4;
const MP1_C2PMSG_81 = MP1_C2PMSG_BASE + 81 * 4;

/* Public metrics sizes, verified against the Linux amdgpu headers named in
 * the reference section above. SMU11 has 136-byte Base, 156-byte V2,
 * 164-byte V3, and 160-byte V4 layouts, so its fixed read uses the largest. */
const SMU11_METRICS_DWORDS = 41;  /* 164 bytes */
const SMU13_0_0_METRICS_DWORDS = 61;  /* 244 bytes, Navi 31/32 */
const SMU13_0_7_METRICS_DWORDS = 60;  /* 240 bytes, Navi 33    */
const SMU14_METRICS_DWORDS = 65;  /* 260 bytes */

/* Radeon discrete-GPU addresses exposed by this protocol use this VRAM MC
 * base. The derived offset must still fit the selected PCI BAR0 aperture. */
const GPU_VRAM_MC_BASE = 0x8000000000;

/* Fallback register-BAR window, used only if the BAR5 size probe returns an
 * implausible result. The physical SMN index/data pair must still fit. */
const REG_SPAN = 0x100000;
/// Sanity bound on the probed BAR5 size; larger is treated as a bad read.
const REG_SIZE_MAX = 0x1000000;      /* 16 MB */
/// Sanity bound on the probed BAR0 size; larger is treated as a bad read.
const VRAM_SIZE_MAX = 0x1000000000;  /* 64 GB */

/* Selected PCI device and apertures, populated once during module load. */
new g_ready = 0;
new g_pci_bus = 0;
new g_pci_device = 0;
new g_pci_function = 0;
new g_device_id = 0;
new g_revision_id = 0;
new g_subsystem_vendor_id = 0;
new g_subsystem_device_id = 0;
new g_reg_bar = 0;
new g_reg_size = 0;
new g_vram_bar = 0;
new g_vram_size = 0;

/* ---------------------------------------------------------------------
 * Discovery
 * ------------------------------------------------------------------- */

/// Discover the AMD VGA controller with the largest VRAM aperture, validate
/// and probe its BARs, record its PCI identity, and set g_ready on success.
find_gpu_and_probe() {
    new best_bus = -1, best_device = -1;
    new best_vram_bar = 0, best_vram_size = 0;
    new best_vendor_device = 0, best_class_revision = 0;
    new best_subsystem = 0;

    for (new bus = 0; bus <= 255; bus++) {
        for (new device = 0; device < 32; device++) {
            new vendor_device = 0;
            if (pci_config_read_dword(bus, device, 0, 0x00, vendor_device) != STATUS_SUCCESS)
                continue;
            if ((vendor_device & 0xFFFF) != AMD_VENDOR_ID)
                continue;

            new class_revision = 0;
            if (pci_config_read_dword(bus, device, 0, 0x08, class_revision) != STATUS_SUCCESS)
                continue;
            if (((class_revision >>> 24) & 0xFF) != 0x03)
                continue;
            if (((class_revision >>> 16) & 0xFF) != 0x00)
                continue;

            new bar0_low = 0, bar0_high = 0;
            if (pci_config_read_dword(bus, device, 0, 0x10, bar0_low) != STATUS_SUCCESS)
                continue;
            if ((bar0_low & 0x1) != 0)
                continue;
            if (((bar0_low >>> 1) & 0x3) != 0x2)
                continue;
            if (pci_config_read_dword(bus, device, 0, 0x14, bar0_high) != STATUS_SUCCESS)
                continue;

            new vram_bar = (bar0_high << 32) | (bar0_low & 0xFFFFFFF0);

            /* Probe BAR0 exactly as the PR implementation does. Restore both
             * halves immediately, and reject every implausible result. */
            new mask_low = 0, mask_high = 0;
            if (pci_config_write_dword(bus, device, 0, 0x10, 0xFFFFFFFF) != STATUS_SUCCESS)
                continue;
            if (pci_config_write_dword(bus, device, 0, 0x14, 0xFFFFFFFF) != STATUS_SUCCESS) {
                pci_config_write_dword(bus, device, 0, 0x10, bar0_low);
                continue;
            }
            new NTSTATUS:read_low_status = pci_config_read_dword(bus, device, 0, 0x10, mask_low);
            new NTSTATUS:read_high_status = pci_config_read_dword(bus, device, 0, 0x14, mask_high);
            pci_config_write_dword(bus, device, 0, 0x10, bar0_low);
            pci_config_write_dword(bus, device, 0, 0x14, bar0_high);
            if (read_low_status != STATUS_SUCCESS || read_high_status != STATUS_SUCCESS)
                continue;

            new mask = (mask_high << 32) | (mask_low & 0xFFFFFFF0);
            new vram_size = (~mask) + 1;
            if (vram_size <= 0 || vram_size > VRAM_SIZE_MAX)
                continue;

            if (vram_size > best_vram_size ||
                (vram_size == best_vram_size && bus > best_bus)) {
                new subsystem = 0;
                pci_config_read_dword(bus, device, 0, 0x2C, subsystem);

                best_vram_size = vram_size;
                best_vram_bar = vram_bar;
                best_bus = bus;
                best_device = device;
                best_vendor_device = vendor_device;
                best_class_revision = class_revision;
                best_subsystem = subsystem;
            }
        }
    }

    if (best_bus < 0)
        return;

    new bar5_low = 0;
    if (pci_config_read_dword(best_bus, best_device, 0, 0x24, bar5_low) != STATUS_SUCCESS)
        return;
    if ((bar5_low & 0x1) != 0)
        return;

    new bar5_type = (bar5_low >>> 1) & 0x3;
    if (bar5_type != 0x0 && bar5_type != 0x2)
        return;

    new bar5_high = 0;
    if (bar5_type == 0x2 &&
        pci_config_read_dword(best_bus, best_device, 0, 0x28, bar5_high) != STATUS_SUCCESS)
        return;
    new reg_bar = (bar5_high << 32) | (bar5_low & 0xFFFFFFF0);

    new bar5_mask = 0;
    if (pci_config_write_dword(best_bus, best_device, 0, 0x24, 0xFFFFFFFF) != STATUS_SUCCESS)
        return;
    new NTSTATUS:bar5_read_status =
        pci_config_read_dword(best_bus, best_device, 0, 0x24, bar5_mask);
    pci_config_write_dword(best_bus, best_device, 0, 0x24, bar5_low);
    if (bar5_read_status != STATUS_SUCCESS)
        return;

    bar5_mask = bar5_mask & 0xFFFFFFF0;
    new reg_size = 0;
    if (bar5_mask != 0)
        reg_size = ((~bar5_mask) & 0xFFFFFFFF) + 1;
    if (reg_size <= 0 || reg_size > REG_SIZE_MAX)
        reg_size = REG_SPAN;
    if (reg_size < SMN_DATA_OFFSET + 4)
        return;

    g_pci_bus = best_bus;
    g_pci_device = best_device;
    g_pci_function = 0;
    g_device_id = (best_vendor_device >>> 16) & 0xFFFF;
    g_revision_id = best_class_revision & 0xFF;
    g_subsystem_vendor_id = best_subsystem & 0xFFFF;
    g_subsystem_device_id = (best_subsystem >>> 16) & 0xFFFF;
    g_reg_bar = reg_bar;
    g_reg_size = reg_size;
    g_vram_bar = best_vram_bar;
    g_vram_size = best_vram_size;
    g_ready = 1;
}

/* ---------------------------------------------------------------------
 * Bounds and SMN access
 * ------------------------------------------------------------------- */

/// True iff [address, address + length) lies inside [base, base + size).
///
/// This form is overflow-safe for signed 64-bit Pawn cells: it never adds to
/// address or base before validating the subtraction and remaining length.
bool:in_window(address, length, base, size) {
    if (size <= 0 || length <= 0)
        return false;
    if (address < base)
        return false;
    new offset = address - base;
    if (offset > size)
        return false;
    if (length > size - offset)
        return false;
    return true;
}

/// True iff smn_address is dword-aligned and inside the MP1 C2PMSG file.
bool:smn_allowed(smn_address) {
    if ((smn_address & 0x3) != 0)
        return false;
    return in_window(smn_address, 4, MP1_C2PMSG_BASE, MP1_C2PMSG_SPAN);
}

/// Perform one indirect SMN read through BAR5 PCIE_INDEX2/PCIE_DATA2.
NTSTATUS:smn_read(smn_address, &value) {
    new VA:virtual_address = io_space_map(g_reg_bar + SMN_INDEX_OFFSET, 8);
    if (virtual_address == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    new NTSTATUS:status = virtual_write_dword(virtual_address, smn_address);
    if (status == STATUS_SUCCESS)
        status = virtual_read_dword(virtual_address + 4, value);
    io_space_unmap(virtual_address, 8);
    return status;
}

/// Perform one indirect SMN write through BAR5 PCIE_INDEX2/PCIE_DATA2.
NTSTATUS:smn_write(smn_address, value) {
    new VA:virtual_address = io_space_map(g_reg_bar + SMN_INDEX_OFFSET, 8);
    if (virtual_address == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    new NTSTATUS:status = virtual_write_dword(virtual_address, smn_address);
    if (status == STATUS_SUCCESS)
        status = virtual_write_dword(virtual_address + 4, value);
    io_space_unmap(virtual_address, 8);
    return status;
}

/// Resolve the current metrics pointer exposed through the Navi 44 register
/// protocol and translate it into the selected BAR0 aperture.
///
/// Reading high/low/high rejects a torn register pair. The resulting range is
/// checked both as a VRAM offset and as a translated host physical address.
NTSTATUS:resolve_metrics_buffer(length, &gpu_address, &vram_offset, &physical_address) {
    gpu_address = 0;
    vram_offset = 0;
    physical_address = 0;

    if (!g_ready)
        return STATUS_DEVICE_NOT_READY;
    if (length <= 0 || length > SMU14_METRICS_DWORDS * 4)
        return STATUS_INVALID_PARAMETER;

    new high_before = 0, high_after = 0, low = 0;
    new bool:stable = false;
    for (new attempt = 0; attempt < 4; attempt++) {
        new NTSTATUS:status = smn_read(MP1_C2PMSG_80, high_before);
        if (status != STATUS_SUCCESS)
            return status;
        status = smn_read(MP1_C2PMSG_81, low);
        if (status != STATUS_SUCCESS)
            return status;
        status = smn_read(MP1_C2PMSG_80, high_after);
        if (status != STATUS_SUCCESS)
            return status;
        if ((high_before & 0xFFFFFFFF) == (high_after & 0xFFFFFFFF)) {
            stable = true;
            break;
        }
    }
    if (!stable)
        return STATUS_RETRY;

    gpu_address = ((high_before & 0xFFFFFFFF) << 32) | (low & 0xFFFFFFFF);
    if ((gpu_address & 0x3) != 0)
        return STATUS_INVALID_ADDRESS;
    if (gpu_address < GPU_VRAM_MC_BASE)
        return STATUS_DEVICE_NOT_READY;

    vram_offset = gpu_address - GPU_VRAM_MC_BASE;
    if (!in_window(vram_offset, length, 0, g_vram_size))
        return STATUS_ACCESS_DENIED;

    physical_address = g_vram_bar + vram_offset;
    if (!in_window(physical_address, length, g_vram_bar, g_vram_size))
        return STATUS_ACCESS_DENIED;
    return STATUS_SUCCESS;
}

/// Resolve, map, and copy a fixed-size current metrics table.
NTSTATUS:read_current_metrics(dword_count, result[]) {
    new gpu_address = 0, vram_offset = 0, physical_address = 0;
    new length = dword_count * 4;
    new NTSTATUS:status = resolve_metrics_buffer(
        length,
        gpu_address,
        vram_offset,
        physical_address);
    if (status != STATUS_SUCCESS)
        return status;

    new VA:virtual_address = io_space_map(physical_address, length);
    if (virtual_address == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    for (new i = 0; i < dword_count; i++) {
        new value = 0;
        status = virtual_read_dword(virtual_address + i * 4, value);
        if (status != STATUS_SUCCESS) {
            io_space_unmap(virtual_address, length);
            return status;
        }
        result[i] = value & 0xFFFFFFFF;
    }

    io_space_unmap(virtual_address, length);
    return STATUS_SUCCESS;
}

/* ---------------------------------------------------------------------
 * Legacy PR #110 IOCTLs
 * ------------------------------------------------------------------- */

/// Read one dword from the SMU message mailbox.
///
/// @param in [0] = SMN address. Must be dword-aligned and inside the MP1
///           C2PMSG register file (0x03B10900..0x03B10AFF); any other
///           address returns STATUS_ACCESS_DENIED.
/// @param in_size Must be 1
/// @param out [0] = register value, zero-extended to 64 bits
/// @param out_size Must be 1
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_read_smn, 1, 1) {
    if (!g_ready)
        return STATUS_DEVICE_NOT_READY;
    new smn_address = in[0];
    if (!smn_allowed(smn_address))
        return STATUS_ACCESS_DENIED;

    new value = 0;
    new NTSTATUS:status = smn_read(smn_address, value);
    out[0] = value & 0xFFFFFFFF;
    return status;
}

/// Write one dword to the SMU message mailbox.
///
/// Writing an ID to C2PMSG_66 issues a PPSMC message. The module deliberately
/// gates addresses rather than message IDs, matching the RyzenSMU approach.
///
/// @param in [0] = SMN address. Must be dword-aligned and inside the MP1
///           C2PMSG register file (0x03B10900..0x03B10AFF); any other
///           address returns STATUS_ACCESS_DENIED.
///           [1] = value to write; only the low 32 bits are used.
/// @param in_size Must be 2
/// @param out [0] = status of the underlying register write
/// @param out_size Must be 1
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_write_smn, 2, 1) {
    if (!g_ready)
        return STATUS_DEVICE_NOT_READY;
    new smn_address = in[0];
    if (!smn_allowed(smn_address)) {
        out[0] = _:STATUS_ACCESS_DENIED & 0xFFFFFFFF;
        return STATUS_ACCESS_DENIED;
    }

    new NTSTATUS:status = smn_write(smn_address, in[1] & 0xFFFFFFFF);
    out[0] = _:status & 0xFFFFFFFF;
    return status;
}

/// Read the SMU14-sized metrics buffer at a caller-selected VRAM address.
///
/// @deprecated Use a generation-specific metrics ioctl, which resolves the
///             address inside the module.
/// @param in [0] = dword-aligned host physical address inside the selected
///           GPU's VRAM aperture
/// @param in_size Must be 1
/// @param out 65 raw DWORDs (260 bytes)
/// @param out_size Must be 65
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_read_metrics, 1, SMU14_METRICS_DWORDS) {
    if (!g_ready)
        return STATUS_DEVICE_NOT_READY;
    new physical_address = in[0];
    new length = SMU14_METRICS_DWORDS * 4;
    if ((physical_address & 0x3) != 0)
        return STATUS_INVALID_PARAMETER;
    if (!in_window(physical_address, length, g_vram_bar, g_vram_size))
        return STATUS_ACCESS_DENIED;

    new VA:virtual_address = io_space_map(physical_address, length);
    if (virtual_address == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;
    for (new i = 0; i < SMU14_METRICS_DWORDS; i++) {
        new value = 0;
        new NTSTATUS:status = virtual_read_dword(virtual_address + i * 4, value);
        if (status != STATUS_SUCCESS) {
            io_space_unmap(virtual_address, length);
            return status;
        }
        out[i] = value & 0xFFFFFFFF;
    }
    io_space_unmap(virtual_address, length);
    return STATUS_SUCCESS;
}

/// Report which GPU apertures the module selected and enforces.
///
/// The module refuses to load when discovery fails, so ready is one for a
/// successfully loaded instance.
/// @param in Ignored
/// @param in_size Must be 1
/// @param out [0] = ready; [1]/[2] = register BAR base/size;
///            [3]/[4] = VRAM BAR base/size
/// @param out_size Must be 5
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_get_bounds, 1, 5) {
    out[0] = g_ready;
    out[1] = g_reg_bar;
    out[2] = g_reg_size;
    out[3] = g_vram_bar;
    out[4] = g_vram_size;
    return STATUS_SUCCESS;
}

/* ---------------------------------------------------------------------
 * ABI 2 monitoring IOCTLs
 * ------------------------------------------------------------------- */

/// Report the selected GPU, apertures, metrics address, and supported sizes.
///
/// Address fields are zero when C2PMSG_80/81 do not expose a usable pointer.
/// Device identity and bounds remain available in that state.
/// @param in Ignored
/// @param in_size Must be 0
/// @param out [0] = module ABI; [1..7] = PCI identity; [8..11] = register and
///            VRAM BAR base/size; [12..14] = GPU address, VRAM offset, and host
///            physical address; [15..18] = RDNA2, RDNA3.0, RDNA3.7, and RDNA4
///            metrics DWORD counts
/// @param out_size Must be 19
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_get_device_info, 0, 19) {
    if (!g_ready)
        return STATUS_DEVICE_NOT_READY;

    new gpu_address = 0, vram_offset = 0, physical_address = 0;
    new NTSTATUS:address_status = resolve_metrics_buffer(
        SMU14_METRICS_DWORDS * 4,
        gpu_address,
        vram_offset,
        physical_address);
    if (address_status != STATUS_SUCCESS) {
        gpu_address = 0;
        vram_offset = 0;
        physical_address = 0;
    }

    out[0] = MODULE_ABI_VERSION;
    out[1] = g_pci_bus;
    out[2] = g_pci_device;
    out[3] = g_pci_function;
    out[4] = g_device_id;
    out[5] = g_revision_id;
    out[6] = g_subsystem_vendor_id;
    out[7] = g_subsystem_device_id;
    out[8] = g_reg_bar;
    out[9] = g_reg_size;
    out[10] = g_vram_bar;
    out[11] = g_vram_size;
    out[12] = gpu_address;
    out[13] = vram_offset;
    out[14] = physical_address;
    out[15] = SMU11_METRICS_DWORDS;
    out[16] = SMU13_0_0_METRICS_DWORDS;
    out[17] = SMU13_0_7_METRICS_DWORDS;
    out[18] = SMU14_METRICS_DWORDS;
    return STATUS_SUCCESS;
}

/// Resolve the current metrics pointer for diagnostics without reading it.
///
/// @param in Ignored
/// @param in_size Must be 0
/// @param out [0] = GPU address; [1] = VRAM offset; [2] = host physical address
/// @param out_size Must be 3
/// @return An NTSTATUS; fails while C2PMSG_80/81 expose no usable pointer
DEFINE_IOCTL_SIZED(ioctl_get_metrics_address, 0, 3) {
    new NTSTATUS:status = resolve_metrics_buffer(
        SMU14_METRICS_DWORDS * 4,
        out[0],
        out[1],
        out[2]);
    return status;
}

/// Read the current SMU11 (RDNA2) metrics table.
///
/// @param in Ignored
/// @param in_size Must be 0
/// @param out 41 raw DWORDs (164 bytes)
/// @param out_size Must be 41
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_read_metrics_rdna2, 0, SMU11_METRICS_DWORDS) {
    return read_current_metrics(SMU11_METRICS_DWORDS, out);
}

/// Read the current SMU13.0.0-layout (RDNA3) metrics table.
///
/// @param in Ignored
/// @param in_size Must be 0
/// @param out 61 raw DWORDs (244 bytes)
/// @param out_size Must be 61
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_read_metrics_rdna3_0, 0, SMU13_0_0_METRICS_DWORDS) {
    return read_current_metrics(SMU13_0_0_METRICS_DWORDS, out);
}

/// Read the current SMU13.0.7 (RDNA3) metrics table.
///
/// @param in Ignored
/// @param in_size Must be 0
/// @param out 60 raw DWORDs (240 bytes)
/// @param out_size Must be 60
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_read_metrics_rdna3_7, 0, SMU13_0_7_METRICS_DWORDS) {
    return read_current_metrics(SMU13_0_7_METRICS_DWORDS, out);
}

/// Read the current SMU14 (RDNA4) metrics table.
///
/// @param in Ignored
/// @param in_size Must be 0
/// @param out 65 raw DWORDs (260 bytes)
/// @param out_size Must be 65
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_read_metrics_rdna4, 0, SMU14_METRICS_DWORDS) {
    return read_current_metrics(SMU14_METRICS_DWORDS, out);
}

/* ---------------------------------------------------------------------
 * Lifecycle
 * ------------------------------------------------------------------- */

NTSTATUS:main() {
    if (get_arch() != ARCH_X64)
        return STATUS_NOT_SUPPORTED;

    g_ready = 0;
    g_pci_bus = 0;
    g_pci_device = 0;
    g_pci_function = 0;
    g_device_id = 0;
    g_revision_id = 0;
    g_subsystem_vendor_id = 0;
    g_subsystem_device_id = 0;
    g_reg_bar = 0;
    g_reg_size = 0;
    g_vram_bar = 0;
    g_vram_size = 0;
    find_gpu_and_probe();

    if (!g_ready)
        return STATUS_NOT_SUPPORTED;
    return STATUS_SUCCESS;
}

public NTSTATUS:unload() {
    return STATUS_SUCCESS;
}
