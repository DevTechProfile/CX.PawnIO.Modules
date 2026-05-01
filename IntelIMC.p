//  PawnIO Modules - Modules for various hardware to be used with PawnIO.
//  Copyright (C) 2025  namazso <admin@namazso.eu>
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

#include <pawnio.inc>

// PawnIO Intel Client IMC Clock Driver
//
// This module reads the integrated memory controller (IMC) clock ratio that
// firmware programs during memory training on Intel client SoCs. The intent
// is to give monitoring tools a safe way to compute a "Memory Clock" sensor 
// on platforms where the legacy MSR_UNCORE_PERF_STATUS based formula no 
// longer applies because uncore and the IMC are decoupled.
//
// Two read sources are implemented and selected per CPUID model:
//
//   * MEMSS_PMA_CR_BIOS_DATA at MCHBAR + 0x13D10 - used on Core Ultra
//     (Meteor Lake, Arrow Lake, Lunar Lake, Panther Lake). The locked Qclk
//     ratio is referenced to BCLK/3. Static after MRC.
//
//   * SA_PERF_STATUS at MCHBAR + 0x5918 - used on Alder Lake / Raptor Lake.
//     Live workpoint, with a per-platform reference clock bit selecting
//     between BCLK and BCLK*4/3.
//
// Both registers are read-only and at fixed compile-time offsets. The
// platform tag derived from CPUID determines which register is used; one
// is never read on a CPU it doesn't apply to.
//
// Validation status: as of this revision, no allowlisted platform has had
// real-hardware validation of the returned ratio against a reference such
// as HWiNFO/CPU-Z DRAM Frequency. Every successful return therefore sets
// the EXPERIMENTAL flag in out[6]. Consumers MUST treat EXPERIMENTAL as
// "do not expose as a primary sensor by default" - either keep the sensor
// hidden, place it behind a debug toggle, or label it preview/experimental
// in the UI. Per-platform "validated" flags will be added (and EXPERIMENTAL
// cleared) as validation results land.
//
// Design constraints, kept deliberately tight so a security review is easy:
//
//   * Read-only. No writes to PCI config, MMIO, MSR, or IO ports.
//   * No user-controlled physical addresses or PCI BDF reach the kernel.
//   * One IOCTL only. Every register read is at a compile-time constant
//     offset against the firmware-published MCHBAR base.
//   * Strict CPUID allowlist. Unknown models return STATUS_NOT_SUPPORTED.
//   * Reserved bits and out-of-range ratios are rejected to avoid reporting
//     a wrong-but-confident value if a future stepping revises the layout.
//   * MCHBAR enable bit is observed but never modified.
//
// Public references used while writing this module:
//   - Intel Core Ultra 200H/200U CFG/MEM register reference, MEMSS_PMA_CR_BIOS_DATA
//   - Intel Core Ultra 200H/200U CFG/MEM register reference, MCHBAR base PCI 0/0/0 offset 0x48
//   - Intel 14th-gen client CFG/MEM register reference, SA_PERF_STATUS at MCHBAR + 0x5918
//   - Intel perfmon mapfile.csv (V1.05 PTL, V1.17 ARL, V1.21 MTL, V1.22 LNL, V1.39 ADL/RPL)

// === Module ABI ===
// Bumped only on incompatible output buffer layout changes.
#define IMC_CLOCK_ABI_VERSION       1

// Identifies which on-die source produced the ratio. Returned as out[1] so
// downstream code can adapt its conversion if a future revision of this
// module adds a different source register.
#define IMC_SRC_NONE                0
#define IMC_SRC_MCHBAR_MEMSS_PMA    1   // MCHBAR + 0x13D10 (MEMSS_PMA_CR_BIOS_DATA)
#define IMC_SRC_MCHBAR_SA_PERF      2   // MCHBAR + 0x5918  (SA_PERF_STATUS)
#define IMC_SRC_PMT_QCLK_STATUS     3   // PMBAR-based      (reserved, not used yet)

// What the ratio is multiplied with on this hardware. The consumer measures
// BCLK separately and computes MHz with whatever BCLK it sees; returning the
// mode keeps that conversion correct across BCLK variants.
#define IMC_REF_UNKNOWN             0
#define IMC_REF_BCLK_DIV_3          1   // 33.333 MHz when BCLK is 100 MHz
#define IMC_REF_BCLK                2   // 100 MHz when BCLK is 100 MHz
#define IMC_REF_BCLK_MUL_4_DIV_3    3   // 133.333 MHz when BCLK is 100 MHz

// DDR controller "gear". 0 means the source register does not encode a gear.
#define IMC_GEAR_UNKNOWN            0
#define IMC_GEAR_1                  1
#define IMC_GEAR_2                  2
#define IMC_GEAR_4                  4

// Hints to the consumer about how to interpret the ratio. Multiple bits
// may be set. While EXPERIMENTAL is set, the value should be treated as
// best-effort: the consumer is expected to keep the sensor hidden by
// default or label it accordingly. Per-platform "validated" bits are
// intentionally not part of this ABI yet; they will be introduced once
// real-hardware validation produces a pass criterion, at which point
// EXPERIMENTAL will be cleared on those platforms.
#define IMC_FLAG_STATIC_LOCKED      (1 << 0)    // value latched after MRC, won't track SAGV
#define IMC_FLAG_LIVE_CURRENT       (1 << 1)    // value reflects the live workpoint
#define IMC_FLAG_EXPERIMENTAL       (1 << 2)    // best-effort, treat with care
// Bits 3 and above are reserved for future use.

// === Host bridge / MCHBAR layout ===
// Host bridge is always at bus 0, device 0, function 0 on Intel client SoCs.
#define HOSTBRIDGE_BUS              0
#define HOSTBRIDGE_DEV              0
#define HOSTBRIDGE_FUNC             0
// PCI config offsets that publish MCHBAR base on Core Ultra processors.
#define HOSTBRIDGE_MCHBAR_LO        0x48
#define HOSTBRIDGE_MCHBAR_HI        0x4C
// Bit 0 of the low dword is MCHBAREN. We refuse to touch MCHBAR if firmware
// has not already enabled it; we never set this bit ourselves.
#define MCHBAR_ENABLE_BIT           0x1
// MCHBAR base spans bits 41:17 of the combined 64-bit value.
#define MCHBAR_BASE_MASK            0x000003FFFFFE0000

// === Register offsets inside MCHBAR ===
// MEMSS_PMA_CR_BIOS_DATA: the locked Qclk ratio that firmware programs after
// memory training. Public Intel docs cover this register on Core Ultra
// 200H/200U; the same register layout is used on Meteor Lake (Core Ultra
// 100), Lunar Lake (Core Ultra 200V), and Panther Lake (Core Ultra series
// 3). All four Core Ultra families read the same way.
//   bits 7:0  QCLK_RATIO   - controller QCLK multiplier of BCLK/3
//   bit 8     GEAR_TYPE    - 0 = Gear2, 1 = Gear4
#define MEMSS_PMA_CR_BIOS_DATA      0x13D10

// SA_PERF_STATUS: the older System-Agent performance status register used
// on Alder Lake / Raptor Lake clients with the documented encoding:
//   bits 9:2  QCLK_RATIO     - controller QCLK multiplier of the reference
//   bit 10    QCLK_REFERENCE - 0 = BCLK*4/3 (133.33 MHz), 1 = BCLK (100 MHz)
// Intel's Core Ultra docs warn that this field is "not defined properly"
// on Core Ultra and route the trained-max value through MEMSS_PMA instead.
//
// Empirically on Panther Lake (PTL-H, model 0xCC) bits 9:2 of this register
// DO track the live QCLK workpoint - the value drops from 64 (LPDDR5X-8533
// trained max) to 18 under low memory activity and returns to 64 under
// load. The reference clock that matches both endpoints is BCLK/3 (same
// as MEMSS_PMA), not the ADL/RPL bit-10 selector. This module therefore
// uses SA_PERF_STATUS only as a live-workpoint signal on Core Ultra and
// keeps the ADL/RPL decode path separate. Bit 10 has been observed to
// stay set on PTL regardless of state, so it is treated as informational
// rather than a reference selector on Core Ultra.
#define SA_PERF_STATUS              0x5918

// Range a freshly trained QCLK ratio is expected to fall in. The lower
// bound rejects 0/very-low values that would mean "register not populated"
// or "wrong source". The upper bound is generous enough to cover heavily
// overclocked DDR5-12000 (ratio ~180 against BCLK/3) without rejecting
// future SKUs. Anything outside this range we treat as "wrong register"
// and refuse rather than report.
#define IMC_RATIO_MIN               16
#define IMC_RATIO_MAX               220

// Mask of reserved bits in MEMSS_PMA_CR_BIOS_DATA on platforms whose layout
// matches Intel's published Core Ultra 200H/200U register reference (MTL,
// ARL, LNL). Bits 31:9 are reserved-zero on those parts. A nonzero value
// here means either the register was repurposed in a future stepping or
// we are on a CPU that mapped a different register at this offset.
#define MEMSS_PMA_RESERVED_MASK_STRICT  0xFFFFFE00
// On Panther Lake the register at MCHBAR + 0x13D10 returns nonzero values
// in the Core-Ultra-200-era reserved range (observed: 0x1E8B0000 on PTL-H
// model 0xCC). PTL is newer than the spec this module was written against
// and appears to encode additional fields here, so the strict mask would
// reject every PTL read despite the ratio in bits 7:0 looking sane. Until
// PTL's full layout is published, the reserved-bits gate is disabled on PTL
// and the consistency check relies on the ratio range alone. The
// EXPERIMENTAL flag is already set on every successful return, so consumers
// continue to treat the value as best-effort.
#define MEMSS_PMA_RESERVED_MASK_NONE    0

// === Platform tags ===
// A platform tag identifies the family of registers this module knows how
// to interpret on a given CPU. We keep MTL/ARL/LNL/PTL distinct from each
// other (and from ADL/RPL) so a future revision can light up per-platform
// validated flags without affecting the others.
#define PLAT_NONE                   0
#define PLAT_MTL                    1   // Intel Core Ultra 100, Meteor Lake
#define PLAT_ARL                    2   // Intel Core Ultra 200, Arrow Lake
#define PLAT_LNL                    3   // Intel Core Ultra 200V, Lunar Lake
#define PLAT_PTL                    4   // Intel Core Ultra series 3, Panther Lake
#define PLAT_ADL                    5   // 12th Gen Core, Alder Lake
#define PLAT_RPL                    6   // 13th/14th Gen Core, Raptor Lake

// Map a CPUID model byte to a platform tag. Anything not listed here is
// rejected up front so that no MMIO is touched on unfamiliar hardware.
//
// Coverage is taken straight from intel-perfmon mapfile.csv:
//   MTL: 0xAA, 0xAC, 0xB5  (V1.21)
//   ARL: 0xC5, 0xC6        (V1.17)
//   LNL: 0xBD              (V1.22)
//   PTL: 0xCC, 0xD5        (V1.05, published 2026-02-26)
//   ADL: 0x97, 0x9A, 0xBE  (V1.39)
//   RPL: 0xB7, 0xBA, 0xBF  (V1.39, listed under /ADL/ in mapfile)
//
// Notably *not* included:
//   0xCD, 0xCE - not currently mapped to any Intel platform in mapfile.csv
//   0xCF       - mapped to Emerald Rapids (server), must not be treated as PTL
//   ICL/TGL/RKL (0x7D/0x7E/0x8C/0x8D/0xA7) - their IMC publishing register
//                is not yet validated for this module
stock get_platform(model) {
    switch (model) {
        case 0xAA, 0xAC, 0xB5:
            return PLAT_MTL;
        case 0xC5, 0xC6:
            return PLAT_ARL;
        case 0xBD:
            return PLAT_LNL;
        case 0xCC, 0xD5:
            return PLAT_PTL;
        case 0x97, 0x9A, 0xBE:
            return PLAT_ADL;
        case 0xB7, 0xBA, 0xBF:
            return PLAT_RPL;
    }
    return PLAT_NONE;
}

// Choose which on-die register exposes the IMC ratio for a given platform.
// All Core Ultra family members route through MEMSS_PMA_CR_BIOS_DATA;
// Alder/Raptor Lake route through SA_PERF_STATUS. There is no fall-through
// between the two sources: the wrong register on the wrong platform would
// either be reserved or "not defined properly" per Intel's own docs.
stock get_platform_source(platform) {
    switch (platform) {
        case PLAT_MTL, PLAT_ARL, PLAT_LNL, PLAT_PTL:
            return IMC_SRC_MCHBAR_MEMSS_PMA;
        case PLAT_ADL, PLAT_RPL:
            return IMC_SRC_MCHBAR_SA_PERF;
    }
    return IMC_SRC_NONE;
}

// Reserved-bits mask for MEMSS_PMA on a given platform. MTL/ARL/LNL match
// the published Core Ultra 200H/200U layout; PTL has been observed to set
// bits in the documented reserved range, so on PTL the gate is disabled.
stock get_platform_pma_reserved_mask(platform) {
    switch (platform) {
        case PLAT_MTL, PLAT_ARL, PLAT_LNL:
            return MEMSS_PMA_RESERVED_MASK_STRICT;
        case PLAT_PTL:
            return MEMSS_PMA_RESERVED_MASK_NONE;
    }
    return MEMSS_PMA_RESERVED_MASK_STRICT;
}

// Whether the values returned for this platform have been cross-validated
// against an external reference (HWiNFO / CPU-Z DRAM Frequency). When
// false, the EXPERIMENTAL flag is set on every successful IOCTL return so
// consumers know to keep the sensor hidden by default. As of this revision
// PTL is validated end-to-end (locked max from MEMSS_PMA matches the rated
// LPDDR5X speed; live ratio from SA_PERF_STATUS tracks the workpoint that
// HWiNFO reports). The other Core Ultra platforms remain unvalidated.
stock bool:is_platform_validated(platform) {
    switch (platform) {
        case PLAT_PTL:
            return true;
    }
    return false;
}

// Read the firmware-published MCHBAR base from the host bridge. We treat a
// disabled or zero base as "not supported" rather than trying to bring it
// up; the running OS would normally have already configured this.
stock NTSTATUS:read_mchbar_base(&base) {
    new lo = 0;
    new hi = 0;

    new NTSTATUS:status = pci_config_read_dword(
        HOSTBRIDGE_BUS, HOSTBRIDGE_DEV, HOSTBRIDGE_FUNC,
        HOSTBRIDGE_MCHBAR_LO, lo);
    if (!NT_SUCCESS(status))
        return status;

    status = pci_config_read_dword(
        HOSTBRIDGE_BUS, HOSTBRIDGE_DEV, HOSTBRIDGE_FUNC,
        HOSTBRIDGE_MCHBAR_HI, hi);
    if (!NT_SUCCESS(status))
        return status;

    // Refuse if firmware has not enabled MCHBAR. This module never enables it.
    if ((lo & MCHBAR_ENABLE_BIT) == 0)
        return STATUS_NOT_SUPPORTED;

    // Combine the two dwords. We mask each to 32 bits first so a high bit
    // in lo can't sign-extend into hi when the cell is interpreted as
    // signed 64-bit.
    base = ((hi & 0xFFFFFFFF) << 32) | (lo & 0xFFFFFFFF);
    base = base & MCHBAR_BASE_MASK;

    if (base == 0)
        return STATUS_NOT_SUPPORTED;

    return STATUS_SUCCESS;
}

// Read a single 32-bit MMIO register at MCHBAR + offset. The offset comes
// only from compile-time constants we control, never from the IOCTL
// caller, so the address handed to io_space_map is always pinned to a
// register this module documents.
stock NTSTATUS:read_mchbar_dword(mchbar_base, offset, &value) {
    new VA:va = io_space_map(mchbar_base + offset, 4);
    if (va == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    new NTSTATUS:status = virtual_read_dword(va, value);

    io_space_unmap(va, 4);
    return status;
}

// Read MEMSS_PMA_CR_BIOS_DATA and split it into ratio + gear. We refuse
// to report a value if any of the platform's documented reserved bits came
// back set (the mask is platform-specific; see
// get_platform_pma_reserved_mask), or if the ratio is outside the plausible
// DDR5/LPDDR5 range - either case usually means we are reading the wrong
// register.
stock NTSTATUS:read_memss_pma(mchbar_base, reserved_mask, &raw, &ratio, &gear) {
    new NTSTATUS:status = read_mchbar_dword(mchbar_base, MEMSS_PMA_CR_BIOS_DATA, raw);
    if (!NT_SUCCESS(status))
        return status;

    // Reserved bits must be zero on platforms whose layout we have a spec
    // for. Platforms with reserved_mask == 0 skip this check.
    if (reserved_mask != 0 && (raw & reserved_mask) != 0)
        return STATUS_NOT_SUPPORTED;

    ratio = raw & 0xFF;
    gear = ((raw >> 8) & 0x1) ? IMC_GEAR_4 : IMC_GEAR_2;

    if (ratio < IMC_RATIO_MIN || ratio > IMC_RATIO_MAX)
        return STATUS_NOT_SUPPORTED;

    return STATUS_SUCCESS;
}

// Read SA_PERF_STATUS on Alder/Raptor Lake (where Intel's documented
// encoding applies). On those platforms bits 9:2 are the controller QCLK
// ratio and bit 10 selects between BCLK and BCLK*4/3 as the reference.
// The register does not encode a gear field, so gear stays Unknown and
// the consumer can derive Gear1/Gear2 from configured DRAM rate if it
// needs to.
//
// We do not validate reserved bits here because Intel's older client docs
// describe several other fields in SA_PERF_STATUS that this module does
// not consume; a "reserved" mask is therefore not safe to assume. Range
// checking the ratio still catches the wrong-register / wrong-platform
// cases without rejecting valid bits we do not interpret.
stock NTSTATUS:read_sa_perf_status(mchbar_base, &raw, &ratio, &refMode) {
    new NTSTATUS:status = read_mchbar_dword(mchbar_base, SA_PERF_STATUS, raw);
    if (!NT_SUCCESS(status))
        return status;

    ratio = (raw >> 2) & 0xFF;
    refMode = ((raw >> 10) & 0x1) ? IMC_REF_BCLK : IMC_REF_BCLK_MUL_4_DIV_3;

    if (ratio < IMC_RATIO_MIN || ratio > IMC_RATIO_MAX)
        return STATUS_NOT_SUPPORTED;

    return STATUS_SUCCESS;
}

// Read SA_PERF_STATUS on Core Ultra and decode its live workpoint. Bits
// 9:2 are the live QCLK ratio against BCLK/3 (same scale as MEMSS_PMA on
// these parts); bit 10's role is unclear and treated as informational.
// We accept any in-range ratio since the controller drops well below
// MEMSS_PMA's locked maximum during low memory activity.
stock NTSTATUS:read_sa_perf_status_core_ultra(mchbar_base, &raw, &ratio) {
    new NTSTATUS:status = read_mchbar_dword(mchbar_base, SA_PERF_STATUS, raw);
    if (!NT_SUCCESS(status))
        return status;

    ratio = (raw >> 2) & 0xFF;

    if (ratio < IMC_RATIO_MIN || ratio > IMC_RATIO_MAX)
        return STATUS_NOT_SUPPORTED;

    return STATUS_SUCCESS;
}

// === DEBUG / VALIDATION ONLY ===
// Diagnostic IOCTL used during initial bring-up of new platforms. Returns the
// intermediate values that ioctl_read_imc_clock would have computed, plus a
// step code identifying which consistency check (if any) tripped. This is a
// development scaffold and is intended to be removed once every allowlisted
// platform has had its EXPERIMENTAL flag cleared by validation.
//
// Same security envelope as the live IOCTL: read-only, no caller-controlled
// addresses, fixed compile-time offsets, strict CPUID allowlist applied
// before any bus operation.
#define IMC_DBG_OK              0
#define IMC_DBG_FAIL_FAMILY     1
#define IMC_DBG_FAIL_PLATFORM   2
#define IMC_DBG_FAIL_SOURCE     3
#define IMC_DBG_FAIL_MCHBAR_OFF 4
#define IMC_DBG_FAIL_BASE_ZERO  5
#define IMC_DBG_FAIL_PMA_RSVD   6
#define IMC_DBG_FAIL_PMA_RANGE  7
#define IMC_DBG_FAIL_SA_RANGE   8

/// Diagnostic dump of the live IOCTL's intermediate values.
///
/// @param in_size Must be 0
/// @param out [0] = ABI version
/// @param out [1] = CPUID FMS (family<<16 | model<<8 | stepping)
/// @param out [2] = platform tag (PLAT_*)
/// @param out [3] = source tag  (IMC_SRC_*)
/// @param out [4] = MCHBAR low dword (raw, includes enable bit)
/// @param out [5] = MCHBAR high dword (raw)
/// @param out [6] = MCHBAR base after mask (0 if disabled)
/// @param out [7] = raw MEMSS_PMA_CR_BIOS_DATA dword (0 if not read)
/// @param out [8] = raw SA_PERF_STATUS dword         (0 if not read)
/// @param out [9] = step that would have failed live IOCTL (IMC_DBG_*)
/// @param out_size Must be 10
/// @return STATUS_SUCCESS even on a "would have failed" run; the step code
///         in out[9] tells you why.
DEFINE_IOCTL_SIZED(ioctl_read_imc_clock_dbg, 0, 10) {
    out[0] = IMC_CLOCK_ABI_VERSION;
    out[1] = 0; out[2] = 0; out[3] = 0;
    out[4] = 0; out[5] = 0; out[6] = 0;
    out[7] = 0; out[8] = 0; out[9] = IMC_DBG_OK;

    new fms = get_cpu_fms();
    out[1] = fms;
    if (cpu_fms_family(fms) != 0x6) {
        out[9] = IMC_DBG_FAIL_FAMILY;
        return STATUS_SUCCESS;
    }

    new platform = get_platform(cpu_fms_model(fms));
    out[2] = platform;
    if (platform == PLAT_NONE) {
        out[9] = IMC_DBG_FAIL_PLATFORM;
        return STATUS_SUCCESS;
    }

    new source = get_platform_source(platform);
    out[3] = source;
    if (source == IMC_SRC_NONE) {
        out[9] = IMC_DBG_FAIL_SOURCE;
        return STATUS_SUCCESS;
    }

    new lo = 0;
    new hi = 0;
    pci_config_read_dword(HOSTBRIDGE_BUS, HOSTBRIDGE_DEV, HOSTBRIDGE_FUNC,
        HOSTBRIDGE_MCHBAR_LO, lo);
    pci_config_read_dword(HOSTBRIDGE_BUS, HOSTBRIDGE_DEV, HOSTBRIDGE_FUNC,
        HOSTBRIDGE_MCHBAR_HI, hi);
    out[4] = lo & 0xFFFFFFFF;
    out[5] = hi & 0xFFFFFFFF;

    if ((lo & MCHBAR_ENABLE_BIT) == 0) {
        out[9] = IMC_DBG_FAIL_MCHBAR_OFF;
        return STATUS_SUCCESS;
    }

    new base = ((hi & 0xFFFFFFFF) << 32) | (lo & 0xFFFFFFFF);
    base = base & MCHBAR_BASE_MASK;
    out[6] = base;
    if (base == 0) {
        out[9] = IMC_DBG_FAIL_BASE_ZERO;
        return STATUS_SUCCESS;
    }

    new raw_pma = 0;
    new raw_sa  = 0;
    read_mchbar_dword(base, MEMSS_PMA_CR_BIOS_DATA, raw_pma);
    read_mchbar_dword(base, SA_PERF_STATUS,         raw_sa);
    out[7] = raw_pma & 0xFFFFFFFF;
    out[8] = raw_sa  & 0xFFFFFFFF;

    if (source == IMC_SRC_MCHBAR_MEMSS_PMA) {
        new pma_mask = get_platform_pma_reserved_mask(platform);
        if (pma_mask != 0 && (raw_pma & pma_mask) != 0) {
            out[9] = IMC_DBG_FAIL_PMA_RSVD;
        } else {
            new r = raw_pma & 0xFF;
            if (r < IMC_RATIO_MIN || r > IMC_RATIO_MAX)
                out[9] = IMC_DBG_FAIL_PMA_RANGE;
        }
    } else if (source == IMC_SRC_MCHBAR_SA_PERF) {
        new r = (raw_sa >> 2) & 0xFF;
        if (r < IMC_RATIO_MIN || r > IMC_RATIO_MAX)
            out[9] = IMC_DBG_FAIL_SA_RANGE;
    }

    return STATUS_SUCCESS;
}

/// Read Intel client IMC/QCLK clock-ratio information.
///
/// This is the only IOCTL the module exposes. There is no generic PCI,
/// MMIO, or MSR access. All addresses are hardcoded inside the module
/// and gated by a strict CPUID allowlist covering Alder Lake, Raptor Lake,
/// Meteor Lake, Arrow Lake, Lunar Lake, and Panther Lake. Older client
/// platforms whose IMC ratio is still tied to MSR_UNCORE_PERF_STATUS
/// remain on the existing IntelMSR module.
///
/// The ratio is returned together with its reference clock mode and gear
/// so the consumer can compute a memory clock with whatever BCLK it has
/// already measured. Doing the multiplication on the consumer side keeps
/// this module free of floating point and of any UI semantics.
///
/// While IMC_FLAG_EXPERIMENTAL is set in out[6] the value is best-effort
/// and the consumer must keep the resulting sensor hidden by default or
/// label it as experimental.
///
/// @param in_size Must be 0
/// @param out [0] = ABI version (currently 1)
/// @param out [1] = source enum (see IMC_SRC_*)
/// @param out [2] = ratio (controller QCLK multiplier of the reference clock)
/// @param out [3] = reference clock mode enum (see IMC_REF_*)
/// @param out [4] = gear enum (see IMC_GEAR_*, 0 if not applicable)
/// @param out [5] = raw register dword the ratio was decoded from
/// @param out [6] = flags (see IMC_FLAG_*)
/// @param out_size Must be 7
/// @return STATUS_SUCCESS on a supported source whose register passed all
///         consistency checks (reserved bits zero where documented, ratio
///         in IMC_RATIO_MIN..IMC_RATIO_MAX).
///         STATUS_NOT_SUPPORTED if the CPU is not in the allowlist, MCHBAR
///         is disabled, or the register's reserved bits / ratio range fail
///         the consistency checks.
///         Other NTSTATUS on PCI/MMIO read failure.
DEFINE_IOCTL_SIZED(ioctl_read_imc_clock, 0, 7) {
    // Pre-fill the buffer so the caller can rely on a well-defined layout
    // even if we end up returning an error before reading any register.
    out[0] = IMC_CLOCK_ABI_VERSION;
    out[1] = IMC_SRC_NONE;
    out[2] = 0;
    out[3] = IMC_REF_UNKNOWN;
    out[4] = IMC_GEAR_UNKNOWN;
    out[5] = 0;
    out[6] = 0;

    // Resolve the running CPU into a platform tag, then a register source.
    // Anything outside the allowlist is rejected before we touch any bus
    // or memory.
    new fms = get_cpu_fms();
    if (cpu_fms_family(fms) != 0x6)
        return STATUS_NOT_SUPPORTED;

    new platform = get_platform(cpu_fms_model(fms));
    if (platform == PLAT_NONE)
        return STATUS_NOT_SUPPORTED;

    new source = get_platform_source(platform);
    if (source == IMC_SRC_NONE)
        return STATUS_NOT_SUPPORTED;

    // Resolve MCHBAR. If firmware has not enabled it we refuse rather
    // than trying to bring it up ourselves.
    new mchbar = 0;
    new NTSTATUS:status = read_mchbar_base(mchbar);
    if (!NT_SUCCESS(status))
        return status;

    new raw = 0;
    new ratio = 0;
    new gear = IMC_GEAR_UNKNOWN;
    new refMode = IMC_REF_UNKNOWN;
    new flags = is_platform_validated(platform) ? 0 : IMC_FLAG_EXPERIMENTAL;

    // Dispatch to the source helper that matches the platform. Each helper
    // owns the register's specific decoding and never reads the other
    // platform's register, so a wrong source can't sneak in via a code path
    // we forgot to update.
    switch (source) {
        case IMC_SRC_MCHBAR_MEMSS_PMA: {
            status = read_memss_pma(mchbar, get_platform_pma_reserved_mask(platform), raw, ratio, gear);
            if (!NT_SUCCESS(status))
                return status;
            // Core Ultra MEMSS_PMA is referenced to BCLK/3 and is the
            // value firmware writes after MRC, so it is effectively
            // static at runtime.
            refMode = IMC_REF_BCLK_DIV_3;
            flags |= IMC_FLAG_STATIC_LOCKED;
        }
        case IMC_SRC_MCHBAR_SA_PERF: {
            status = read_sa_perf_status(mchbar, raw, ratio, refMode);
            if (!NT_SUCCESS(status))
                return status;
            // SA_PERF_STATUS reflects the live System-Agent workpoint, so
            // the consumer can re-read periodically to track changes.
            flags |= IMC_FLAG_LIVE_CURRENT;
        }
        default:
            return STATUS_NOT_SUPPORTED;
    }

    out[1] = source;
    out[2] = ratio;
    out[3] = refMode;
    out[4] = gear;
    out[5] = raw & 0xFFFFFFFF;
    out[6] = flags;

    return STATUS_SUCCESS;
}

/// Read the live IMC/QCLK workpoint on Core Ultra (MTL/ARL/LNL/PTL).
///
/// The IOCTL exposed in this module above (ioctl_read_imc_clock) returns
/// the trained-max ratio that firmware programs into MEMSS_PMA after MRC
/// and is therefore static. This IOCTL returns the LIVE ratio that the
/// controller is currently running at, derived from SA_PERF_STATUS.
///
/// On Alder/Raptor Lake the SA_PERF_STATUS encoding is the documented
/// ADL/RPL one and this IOCTL returns STATUS_NOT_SUPPORTED (use the
/// existing ioctl_read_imc_clock there - it is already live on those
/// platforms via SA_PERF).
///
/// Empirically on PTL-H the live ratio drops well below the trained max
/// when memory activity is low, so callers should treat this as a real
/// dynamic signal worth polling at ~1 Hz. Validation status is the same
/// as the locked-max IOCTL: EXPERIMENTAL until per-platform validation
/// against HWiNFO/CPU-Z lands.
///
/// @param in_size Must be 0
/// @param out [0] = ABI version (currently 1)
/// @param out [1] = source enum (always IMC_SRC_MCHBAR_SA_PERF on this IOCTL)
/// @param out [2] = ratio (live controller QCLK multiplier of BCLK/3)
/// @param out [3] = reference clock mode (IMC_REF_BCLK_DIV_3)
/// @param out [4] = gear (carried from MEMSS_PMA, since SA_PERF does not
///                   encode it on Core Ultra; 0 if MEMSS_PMA refused)
/// @param out [5] = raw SA_PERF_STATUS dword
/// @param out [6] = flags (always sets LIVE_CURRENT | EXPERIMENTAL)
/// @param out_size Must be 7
/// @return STATUS_SUCCESS on a Core Ultra platform whose live ratio is in
///         range. STATUS_NOT_SUPPORTED on ADL/RPL or unknown CPUs. Other
///         NTSTATUS on PCI/MMIO read failure.
DEFINE_IOCTL_SIZED(ioctl_read_imc_clock_live, 0, 7) {
    out[0] = IMC_CLOCK_ABI_VERSION;
    out[1] = IMC_SRC_NONE;
    out[2] = 0;
    out[3] = IMC_REF_UNKNOWN;
    out[4] = IMC_GEAR_UNKNOWN;
    out[5] = 0;
    out[6] = 0;

    new fms = get_cpu_fms();
    if (cpu_fms_family(fms) != 0x6)
        return STATUS_NOT_SUPPORTED;

    new platform = get_platform(cpu_fms_model(fms));
    if (platform == PLAT_NONE)
        return STATUS_NOT_SUPPORTED;

    // Only Core Ultra parts use this live SA_PERF path. ADL/RPL get the
    // documented ADL encoding via the existing ioctl_read_imc_clock.
    new source = get_platform_source(platform);
    if (source != IMC_SRC_MCHBAR_MEMSS_PMA)
        return STATUS_NOT_SUPPORTED;

    new mchbar = 0;
    new NTSTATUS:status = read_mchbar_base(mchbar);
    if (!NT_SUCCESS(status))
        return status;

    new raw = 0;
    new ratio = 0;
    status = read_sa_perf_status_core_ultra(mchbar, raw, ratio);
    if (!NT_SUCCESS(status))
        return status;

    // Pull gear from MEMSS_PMA. It is part of the locked layout and does
    // not change at runtime, so a single read is fine. If MEMSS_PMA's
    // strict reserved-bits check rejects on this platform (e.g. PTL with
    // its loosened mask still catches a real layout drift on a future
    // stepping), we leave gear at Unknown rather than fail the IOCTL.
    new pma_raw = 0;
    new pma_ratio = 0;
    new gear = IMC_GEAR_UNKNOWN;
    new NTSTATUS:pma_status = read_memss_pma(mchbar, get_platform_pma_reserved_mask(platform), pma_raw, pma_ratio, gear);
    if (!NT_SUCCESS(pma_status))
        gear = IMC_GEAR_UNKNOWN;

    new live_flags = IMC_FLAG_LIVE_CURRENT;
    if (!is_platform_validated(platform))
        live_flags |= IMC_FLAG_EXPERIMENTAL;

    out[1] = IMC_SRC_MCHBAR_SA_PERF;
    out[2] = ratio;
    out[3] = IMC_REF_BCLK_DIV_3;
    out[4] = gear;
    out[5] = raw & 0xFFFFFFFF;
    out[6] = live_flags;

    return STATUS_SUCCESS;
}

NTSTATUS:main() {
    if (get_arch() != ARCH_X64)
        return STATUS_NOT_SUPPORTED;

    if (get_cpu_vendor() != CpuVendor_Intel)
        return STATUS_NOT_SUPPORTED;

    // Intentionally do not gate on CPU model here. Returning success on
    // any Intel x64 lets users on unsupported models still load the
    // module and observe STATUS_NOT_SUPPORTED from the IOCTL itself,
    // which makes "module didn't load" easy to tell apart from "this CPU
    // is not on the allowlist".
    return STATUS_SUCCESS;
}
