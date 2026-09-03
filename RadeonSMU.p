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
 *   - A fixed private monitoring-table transaction for allowlisted RDNA2,
 *     RDNA3, and RDNA4 device families. The module selects the mailbox
 *     commands, validates the firmware-reported address against both the
 *     framebuffer interval and BAR0, and returns one 8-KiB snapshot.
 *   - Four fixed Navi 21 SVI telemetry registers.
 *   - No system RAM access, no other device, no framebuffer write, and no SMN
 *     address outside the mailbox window.
 *
 * The generation-specific reads take no address argument, but this is a
 * convenience rather than an additional security boundary. C2PMSG_80/81 are
 * inside the writable mailbox allowlist, so a caller can steer the derived
 * address; the legacy `ioctl_read_metrics` also accepts an address directly.
 * Every physical read remains bounded to the selected GPU's VRAM aperture.
 *
 * On tested Navi 21 and Navi 31 hardware, C2PMSG_80/81 stayed zero while
 * driver telemetry was active. The fixed private path is therefore separate
 * from the public metrics-pointer path. It exposes no caller-selected message,
 * register, selector, or physical address. Navi 21, Navi 31, and Navi 48
 * private tables were validated with versions 0x003A0010, 0x004E000C, and
 * 0x00660006 respectively. The original pull request author validated the
 * public pointer path on Navi 44.
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
const MODULE_ABI_VERSION = 5;
/// PCI vendor ID for AMD/ATI.
const AMD_VENDOR_ID = 0x1002;

/// BAR5 offset of PCIE_INDEX2, the indirect SMN address register.
const SMN_INDEX_OFFSET = 0x38;
/// BAR5 offset of PCIE_DATA2, the indirect SMN data register.
const SMN_DATA_OFFSET = 0x3C;

/// Navi 21 PCI device range accepted by the private table and SVI reads.
const NAVI21_DEVICE_ID_MIN = 0x73A0;
const NAVI21_DEVICE_ID_MAX = 0x73BF;
/// BAR5 offset and size of the fixed Navi 21 SVI telemetry range.
const NAVI21_SVI_OFFSET = 0x5A00C;
const NAVI21_SVI_DWORDS = 4;

/// RDNA3 PCI device ranges accepted by the private table read.
const RDNA3_DEVICE_ID_MIN_0 = 0x7440;
const RDNA3_DEVICE_ID_MAX_0 = 0x746F;
const RDNA3_DEVICE_ID_MIN_1 = 0x7470;
const RDNA3_DEVICE_ID_MAX_1 = 0x749F;

/// RDNA4 PCI device ranges accepted by the private table read.
const RDNA4_DEVICE_ID_MIN_0 = 0x7550;
const RDNA4_DEVICE_ID_MAX_0 = 0x756F;
const RDNA4_DEVICE_ID_MIN_1 = 0x7590;
const RDNA4_DEVICE_ID_MAX_1 = 0x75AF;

/* Fixed private-tool mailbox registers, commands, and responses. */
const RDNA_TOOL_MESSAGE_OFFSET = 0x58A20;   /* C2PMSG_72  */
const RDNA_TOOL_RESPONSE_OFFSET = 0x58A80;  /* C2PMSG_96  */
const RDNA_TOOL_ARGUMENT_OFFSET = 0x58A88;  /* C2PMSG_98  */
const RDNA_TOOL_ARG_V10_OFFSET = 0x58AB4;   /* C2PMSG_109 */
const RDNA_TOOL_GET_VERSION = 0x14;
const RDNA_TOOL_GET_ADDRESS_HIGH = 0x07;
const RDNA_TOOL_GET_ADDRESS_LOW = 0x08;
const RDNA_TOOL_REFRESH_TABLE = 0x09;
const RDNA_TOOL_REFRESH_SELECTOR = 4;
const RDNA_TOOL_RESPONSE_OK = 1;
const RDNA_TOOL_RESPONSE_BUSY = 0xFC;
const RDNA_TOOL_RSP_PREREQ = 0xFD;
const RDNA_TOOL_RESPONSE_UNKNOWN = 0xFE;
const RDNA_TOOL_POLL_ATTEMPTS = 10000;
const RDNA_TOOL_POLL_DELAY_US = 100;
const RDNA_TOOL_READ_ATTEMPTS = 5;
const RDNA_TOOL_READ_RETRY_DELAY_US = 10000;

/* Framebuffer bounds. Navi 21 device 73BF/D5 uses the alternate pair. */
const NAVI21_FB_BASE_OFFSET = 0xE54C;
const NAVI21_FB_TOP_OFFSET = 0xE550;
const RDNA3_FB_BASE_OFFSET = 0xE4D4;
const RDNA3_FB_TOP_OFFSET = 0xE4D8;
/// Covers all fixed registers and fits RDNA4's 512-KiB BAR5.
const RDNA_TOOL_MMIO_MAP_SIZE = 0x80000;
const RDNA_TOOL_TABLE_BYTES = 0x2000;
const RDNA_TOOL_TABLE_QWORDS = RDNA_TOOL_TABLE_BYTES / 8;
const RDNA_TOOL_METADATA_QWORDS = 4;
const RDNA_TOOL_OUTPUT_QWORDS =
    RDNA_TOOL_METADATA_QWORDS + RDNA_TOOL_TABLE_QWORDS;

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

/// Retry budget for acquiring two equal complete metrics-pointer snapshots.
const METRICS_ADDRESS_READ_ATTEMPTS = 5;
const METRICS_ADDRESS_RETRY_DELAY_US = 10000;

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

/// True iff device_id belongs to an allowlisted RDNA3 family.
bool:is_rdna3_tool_device(device_id) {
    return ((device_id >= RDNA3_DEVICE_ID_MIN_0 && device_id <= RDNA3_DEVICE_ID_MAX_0) ||
            (device_id >= RDNA3_DEVICE_ID_MIN_1 && device_id <= RDNA3_DEVICE_ID_MAX_1));
}

/// True iff device_id belongs to an allowlisted RDNA4 family.
bool:is_rdna4_tool_device(device_id) {
    return ((device_id >= RDNA4_DEVICE_ID_MIN_0 && device_id <= RDNA4_DEVICE_ID_MAX_0) ||
            (device_id >= RDNA4_DEVICE_ID_MIN_1 && device_id <= RDNA4_DEVICE_ID_MAX_1));
}

/// True iff device_id may use the fixed private monitoring-table protocol.
bool:is_rdna_tool_device(device_id) {
    return ((device_id >= NAVI21_DEVICE_ID_MIN && device_id <= NAVI21_DEVICE_ID_MAX) ||
            is_rdna3_tool_device(device_id) ||
            is_rdna4_tool_device(device_id));
}

/// Map a firmware table version to its known mailbox layout.
rdna_tool_layout(version) {
    switch ((version >>> 16) & 0xFFFF) {
        case 0x0000: return 1;
        case 0x0027: return 2;
        case 0x0028: return 3;
        case 0x0029: return 4;
        case 0x0034: return 5;
        case 0x003A: return 6;
        case 0x004E: return 7;
        case 0x0066: return 8;
        case 0x0044: return 9;
        case 0x0055: return 10;
        case 0x0056: return 11;
    }
    return 0;
}

/// Translate a private mailbox response into an NTSTATUS.
NTSTATUS:rdna_tool_response_status(response) {
    response = response & 0xFFFFFFFF;
    if (response == RDNA_TOOL_RESPONSE_OK)
        return STATUS_SUCCESS;
    if (response == RDNA_TOOL_RESPONSE_BUSY)
        return STATUS_DEVICE_BUSY;
    if (response == RDNA_TOOL_RSP_PREREQ)
        return STATUS_INVALID_DEVICE_STATE;
    if (response == RDNA_TOOL_RESPONSE_UNKNOWN)
        return STATUS_NOT_SUPPORTED;
    return STATUS_UNSUCCESSFUL;
}

/// Wait until the private mailbox response register becomes nonzero.
NTSTATUS:rdna_tool_wait_response(VA:registers, &response) {
    response = 0;
    for (new attempt = 0; attempt < RDNA_TOOL_POLL_ATTEMPTS; attempt++) {
        new NTSTATUS:status = virtual_read_dword(
            registers + RDNA_TOOL_RESPONSE_OFFSET,
            response);
        if (status != STATUS_SUCCESS)
            return status;
        if ((response & 0xFFFFFFFF) != 0)
            return STATUS_SUCCESS;

        status = microsleep(RDNA_TOOL_POLL_DELAY_US);
        if (status != STATUS_SUCCESS)
            return status;
    }
    return STATUS_IO_TIMEOUT;
}

/// Send one fixed private mailbox command and return its argument register.
NTSTATUS:rdna_tool_send(
    VA:registers,
    argument_offset,
    message,
    bool:has_argument,
    &argument) {
    new response = 0;
    new NTSTATUS:status = rdna_tool_wait_response(registers, response);
    if (status != STATUS_SUCCESS)
        return status;

    status = virtual_write_dword(registers + RDNA_TOOL_RESPONSE_OFFSET, 0);
    if (status != STATUS_SUCCESS)
        return status;

    if (has_argument) {
        status = virtual_write_dword(
            registers + argument_offset,
            argument & 0xFFFFFFFF);
        if (status != STATUS_SUCCESS)
            return status;
    }

    status = virtual_write_dword(
        registers + RDNA_TOOL_MESSAGE_OFFSET,
        message & 0xFFFFFFFF);
    if (status != STATUS_SUCCESS)
        return status;

    status = rdna_tool_wait_response(registers, response);
    if (status != STATUS_SUCCESS)
        return status;

    status = rdna_tool_response_status(response);
    if (status != STATUS_SUCCESS)
        return status;

    status = virtual_read_dword(registers + argument_offset, argument);
    if (status != STATUS_SUCCESS)
        return status;
    argument = argument & 0xFFFFFFFF;
    return STATUS_SUCCESS;
}

/// Read the generation-specific framebuffer interval from fixed BAR5 offsets.
NTSTATUS:rdna_tool_framebuffer_bounds(VA:registers, &fb_base, &fb_top) {
    new base_offset = NAVI21_FB_BASE_OFFSET;
    new top_offset = NAVI21_FB_TOP_OFFSET;
    if (is_rdna3_tool_device(g_device_id) ||
        is_rdna4_tool_device(g_device_id) ||
        (g_device_id == 0x73BF && g_revision_id == 0xD5)) {
        base_offset = RDNA3_FB_BASE_OFFSET;
        top_offset = RDNA3_FB_TOP_OFFSET;
    }

    new base_value = 0, top_value = 0;
    new NTSTATUS:status = virtual_read_dword(registers + base_offset, base_value);
    if (status != STATUS_SUCCESS)
        return status;
    status = virtual_read_dword(registers + top_offset, top_value);
    if (status != STATUS_SUCCESS)
        return status;

    fb_base = (base_value & 0x00FFFFFF) << 24;
    fb_top = (top_value & 0x00FFFFFF) << 24;
    if (fb_top <= fb_base)
        return STATUS_INVALID_ADDRESS;
    return STATUS_SUCCESS;
}

/// Query, refresh, validate, and copy one private monitoring-table snapshot.
NTSTATUS:read_rdna_tool_table(result[]) {
    if (!g_ready)
        return STATUS_DEVICE_NOT_READY;
    if (!is_rdna_tool_device(g_device_id))
        return STATUS_NOT_SUPPORTED;
    if (!in_window(0, RDNA_TOOL_MMIO_MAP_SIZE, 0, g_reg_size))
        return STATUS_NOT_SUPPORTED;

    new VA:registers = io_space_map(g_reg_bar, RDNA_TOOL_MMIO_MAP_SIZE);
    if (registers == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    new version = 0;
    new NTSTATUS:status = rdna_tool_send(
        registers,
        RDNA_TOOL_ARGUMENT_OFFSET,
        RDNA_TOOL_GET_VERSION,
        false,
        version);
    if (status != STATUS_SUCCESS) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return status;
    }

    new layout = rdna_tool_layout(version);
    if (layout == 0) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return STATUS_NOT_SUPPORTED;
    }
    new argument_offset = layout == 10
        ? RDNA_TOOL_ARG_V10_OFFSET
        : RDNA_TOOL_ARGUMENT_OFFSET;

    new address_high = 0;
    status = rdna_tool_send(
        registers,
        argument_offset,
        RDNA_TOOL_GET_ADDRESS_HIGH,
        false,
        address_high);
    if (status != STATUS_SUCCESS) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return status;
    }

    new address_low = 0;
    status = rdna_tool_send(
        registers,
        argument_offset,
        RDNA_TOOL_GET_ADDRESS_LOW,
        false,
        address_low);
    if (status != STATUS_SUCCESS) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return status;
    }

    new gpu_address =
        ((address_high & 0xFFFFFFFF) << 32) | (address_low & 0xFFFFFFFF);
    if ((gpu_address & 0x3) != 0) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return STATUS_INVALID_ADDRESS;
    }

    new fb_base = 0, fb_top = 0;
    status = rdna_tool_framebuffer_bounds(registers, fb_base, fb_top);
    if (status != STATUS_SUCCESS) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return status;
    }
    if (!in_window(
            gpu_address,
            RDNA_TOOL_TABLE_BYTES,
            fb_base,
            fb_top - fb_base)) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return STATUS_ACCESS_DENIED;
    }

    new vram_offset = gpu_address - fb_base;
    if (!in_window(vram_offset, RDNA_TOOL_TABLE_BYTES, 0, g_vram_size)) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return STATUS_ACCESS_DENIED;
    }
    new physical_address = g_vram_bar + vram_offset;
    if (!in_window(
            physical_address,
            RDNA_TOOL_TABLE_BYTES,
            g_vram_bar,
            g_vram_size)) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return STATUS_ACCESS_DENIED;
    }

    new VA:table = io_space_map(physical_address, RDNA_TOOL_TABLE_BYTES);
    if (table == NULL) {
        io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    new bool:valid_table = false;
    for (new attempt = 0; attempt < RDNA_TOOL_READ_ATTEMPTS; attempt++) {
        new refresh_argument = RDNA_TOOL_REFRESH_SELECTOR;
        status = rdna_tool_send(
            registers,
            argument_offset,
            RDNA_TOOL_REFRESH_TABLE,
            true,
            refresh_argument);
        if (status != STATUS_SUCCESS) {
            io_space_unmap(table, RDNA_TOOL_TABLE_BYTES);
            io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
            return status;
        }

        new first_qword = 0;
        new bool:all_same = true;
        for (new i = 0; i < RDNA_TOOL_TABLE_QWORDS; i++) {
            new data_low = 0, data_high = 0;
            status = virtual_read_dword(table + i * 8, data_low);
            if (status == STATUS_SUCCESS)
                status = virtual_read_dword(table + i * 8 + 4, data_high);
            if (status != STATUS_SUCCESS) {
                io_space_unmap(table, RDNA_TOOL_TABLE_BYTES);
                io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
                return status;
            }

            new data =
                (data_low & 0xFFFFFFFF) | ((data_high & 0xFFFFFFFF) << 32);
            result[RDNA_TOOL_METADATA_QWORDS + i] = data;
            if (i == 0)
                first_qword = data;
            else if (data != first_qword)
                all_same = false;
        }

        if (!all_same) {
            valid_table = true;
            break;
        }

        if (attempt + 1 < RDNA_TOOL_READ_ATTEMPTS) {
            status = microsleep(RDNA_TOOL_READ_RETRY_DELAY_US);
            if (status != STATUS_SUCCESS) {
                io_space_unmap(table, RDNA_TOOL_TABLE_BYTES);
                io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);
                return status;
            }
        }
    }
    io_space_unmap(table, RDNA_TOOL_TABLE_BYTES);
    io_space_unmap(registers, RDNA_TOOL_MMIO_MAP_SIZE);

    if (!valid_table)
        return STATUS_DATA_ERROR;

    result[0] = version & 0xFFFFFFFF;
    result[1] = gpu_address;
    result[2] = fb_base;
    result[3] = fb_top;
    return STATUS_SUCCESS;
}

/// Preserve the Navi 21-only entry point introduced by ABI 3.
NTSTATUS:read_navi21_tool_table(result[]) {
    if (g_device_id < NAVI21_DEVICE_ID_MIN || g_device_id > NAVI21_DEVICE_ID_MAX)
        return STATUS_NOT_SUPPORTED;
    return read_rdna_tool_table(result);
}

/// Read four fixed Navi 21 SVI telemetry dwords from BAR5.
NTSTATUS:read_navi21_svi(result[]) {
    new length = NAVI21_SVI_DWORDS * 4;
    if (!g_ready)
        return STATUS_DEVICE_NOT_READY;
    if (g_device_id < NAVI21_DEVICE_ID_MIN || g_device_id > NAVI21_DEVICE_ID_MAX)
        return STATUS_NOT_SUPPORTED;
    if (!in_window(NAVI21_SVI_OFFSET, length, 0, g_reg_size))
        return STATUS_NOT_SUPPORTED;

    new VA:virtual_address = io_space_map(g_reg_bar + NAVI21_SVI_OFFSET, length);
    if (virtual_address == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    for (new i = 0; i < NAVI21_SVI_DWORDS; i++) {
        new value = 0;
        new NTSTATUS:status = virtual_read_dword(virtual_address + i * 4, value);
        if (status != STATUS_SUCCESS) {
            io_space_unmap(virtual_address, length);
            return status;
        }
        result[i] = value & 0xFFFFFFFF;
    }

    io_space_unmap(virtual_address, length);
    return STATUS_SUCCESS;
}

/// Read one metrics-pointer candidate whose high half is internally stable.
NTSTATUS:read_metrics_pointer_candidate(&address) {
    address = 0;

    new high_before = 0, high_after = 0, low = 0;
    new NTSTATUS:status = smn_read(MP1_C2PMSG_80, high_before);
    if (status != STATUS_SUCCESS)
        return status;
    status = smn_read(MP1_C2PMSG_81, low);
    if (status != STATUS_SUCCESS)
        return status;
    status = smn_read(MP1_C2PMSG_80, high_after);
    if (status != STATUS_SUCCESS)
        return status;
    if ((high_before & 0xFFFFFFFF) != (high_after & 0xFFFFFFFF))
        return STATUS_RETRY;

    address = ((high_before & 0xFFFFFFFF) << 32) | (low & 0xFFFFFFFF);
    return STATUS_SUCCESS;
}

/// Resolve the current metrics pointer exposed through the Navi 44 register
/// protocol and translate it into the selected BAR0 aperture.
///
/// Two equal high/low/high snapshots reject torn or changing register pairs.
/// The resulting range is checked both as a VRAM offset and as a translated
/// host physical address.
NTSTATUS:resolve_metrics_buffer(length, &gpu_address, &vram_offset, &physical_address) {
    gpu_address = 0;
    vram_offset = 0;
    physical_address = 0;

    if (!g_ready)
        return STATUS_DEVICE_NOT_READY;
    if (length <= 0 || length > SMU14_METRICS_DWORDS * 4)
        return STATUS_INVALID_PARAMETER;

    new NTSTATUS:last_status = STATUS_RETRY;
    for (new attempt = 0; attempt < METRICS_ADDRESS_READ_ATTEMPTS; attempt++) {
        new first_address = 0, second_address = 0;
        new NTSTATUS:status = read_metrics_pointer_candidate(first_address);
        if (status != STATUS_SUCCESS && status != STATUS_RETRY)
            return status;

        if (status == STATUS_SUCCESS)
            status = read_metrics_pointer_candidate(second_address);
        if (status != STATUS_SUCCESS && status != STATUS_RETRY)
            return status;

        if (status == STATUS_SUCCESS && first_address == second_address) {
            if ((first_address & 0x3) != 0) {
                last_status = STATUS_INVALID_ADDRESS;
            } else if (first_address < GPU_VRAM_MC_BASE) {
                last_status = STATUS_DEVICE_NOT_READY;
            } else {
                new candidate_offset = first_address - GPU_VRAM_MC_BASE;
                new candidate_physical = g_vram_bar + candidate_offset;
                if (!in_window(candidate_offset, length, 0, g_vram_size) ||
                    !in_window(
                        candidate_physical,
                        length,
                        g_vram_bar,
                        g_vram_size)) {
                    last_status = STATUS_ACCESS_DENIED;
                } else {
                    gpu_address = first_address;
                    vram_offset = candidate_offset;
                    physical_address = candidate_physical;
                    return STATUS_SUCCESS;
                }
            }
        } else {
            last_status = STATUS_RETRY;
        }

        if (attempt + 1 < METRICS_ADDRESS_READ_ATTEMPTS) {
            status = microsleep(METRICS_ADDRESS_RETRY_DELAY_US);
            if (status != STATUS_SUCCESS)
                return status;
        }
    }

    return last_status;
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
 * ABI 5 monitoring IOCTLs
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
///            public metrics DWORD counts; [19] = Navi 21 SVI DWORD count;
///            [20] = private monitoring-table QWORD count, excluding metadata
/// @param out_size Must be 21
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_get_device_info, 0, 21) {
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
    out[19] = NAVI21_SVI_DWORDS;
    out[20] = RDNA_TOOL_TABLE_QWORDS;
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

/// Read the fixed Navi 21 SVI telemetry range.
///
/// This entry point accepts only Navi 21 PCI device IDs. It performs no
/// mailbox or I2C transaction.
/// @param in Ignored
/// @param in_size Must be 0
/// @param out Four raw DWORDs from BAR5 offset 0x5A00C
/// @param out_size Must be 4
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_read_navi21_svi, 0, NAVI21_SVI_DWORDS) {
    return read_navi21_svi(out);
}

/// Refresh and read the private Navi 21 monitoring table.
///
/// This ABI-3 compatibility entry point accepts only Navi 21 PCI device IDs.
/// Firmware selects the address; the complete range is validated before use.
/// @param in Ignored
/// @param in_size Must be 0
/// @param out [0] = table version; [1] = GPU address; [2]/[3] = framebuffer
///            base/top; [4..1027] = 8192 raw table bytes as 1024 QWORDs
/// @param out_size Must be 1028
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_read_navi21_tool_table, 0, RDNA_TOOL_OUTPUT_QWORDS) {
    return read_navi21_tool_table(out);
}

/// Refresh and read the private RDNA2, RDNA3, or RDNA4 monitoring table.
///
/// Device IDs, messages, arguments, register offsets, and read size are fixed
/// by the module. Firmware selects the address; the complete range is checked
/// against both the GPU framebuffer interval and the selected BAR0 aperture.
/// Unknown devices and table-layout families fail closed.
/// @param in Ignored
/// @param in_size Must be 0
/// @param out [0] = table version; [1] = GPU address; [2]/[3] = framebuffer
///            base/top; [4..1027] = 8192 raw table bytes as 1024 QWORDs
/// @param out_size Must be 1028
/// @return An NTSTATUS
DEFINE_IOCTL_SIZED(ioctl_read_rdna_tool_table, 0, RDNA_TOOL_OUTPUT_QWORDS) {
    return read_rdna_tool_table(out);
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
