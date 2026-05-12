Thanks for taking the time to review.

### Validation status

The module is now validated on three Core Ultra platforms with HWiNFO64 cross-checks and SMBIOS DIMM-speed match:

| Platform | CPU / CPUID | Module result | Cross-checked against |
|---|---|---|---|
| Panther Lake | Core Ultra X7 358H / 0xCC | ratio 64, Gear4, **IO 4,267 MHz / 8,533 MT/s** | HWiNFO Memory Clock 4,266.7 MHz, Gear 4; SMBIOS 8,533 MT/s |
| Arrow Lake | Core Ultra 9 285K / 0xC6 | ratio 117, Gear2, **QCLK 3,900 MHz / 7,800 MT/s** | HWiNFO Memory Clock 3,899.6 MHz, Gear 2; SMBIOS 7,800 MT/s; G.Skill EXPO DDR5-7800 |
| Lunar Lake | Core Ultra 7 258V / 0xBD | ratio 64, Gear4, **QCLK 2,133.3 MHz / 8,533 MT/s** | HWiNFO Memory Clock 2,133.3 MHz, Ratio 21.33x; SMBIOS 8,533 MT/s |

On LNL, HWiNFO64's Gear Mode reads `2` while the module decodes `Gear4` from `MEMSS_PMA` bit 8. Only the Gear4 interpretation reconstructs the SMBIOS data rate (`64 × BCLK/3 × 4 = 8,533 MT/s`); HWiNFO appears to label a different ratio (controller-fabric vs WCK:CK) under the same name on LPDDR5x. Both are internally consistent — see `Deploy/VALIDATION-LNL.md` for the full discussion.

Full reports are in the branch under `Deploy/VALIDATION-{PTL,ARL,LNL}.md`. `is_platform_validated()` (IntelIMC.p:227) clears `IMC_FLAG_EXPERIMENTAL` for these three. MTL and NVL stay flagged as unvalidated.

### Point 2 — comment in `main()`

The comment was not saying that error statuses from `main` don't propagate. They do, and the module already returns `STATUS_NOT_SUPPORTED` from `main` for non-x64 / non-Intel hosts.

What I deliberately don't gate in `main` is the **CPU-model check**, and the reason is UX, not a workaround:

- "Module loaded, IOCTL returns `STATUS_NOT_SUPPORTED`" → the user knows their CPU is simply not on the allowlist.
- "Module failed to load" → could be a PawnIO driver issue, a missing dependency, or anything else.

The first is easy to tell apart from infrastructure problems; the second isn't.

The comment has been reworded to say exactly that (IntelIMC.p:726-727):

```pawn
// No model gate here; per-IOCTL allowlist returns STATUS_NOT_SUPPORTED
// so callers can distinguish "didn't load" from "model not allowlisted".
```

### Point 3 — DID/VID instead of CPUID

@a1ive already covered this with the screenshot above: DIDs differ within the same generation, so DID-based gating is more brittle than CPUID, not less.

CPUID also matches Intel's own platform classification. The allowlist in this module is cross-checked against `mapfile.csv` from Intel's public `intel-perfmon` repo (referenced at IntelIMC.p:46 and IntelIMC.p:162, mirrored under `intel-perfmon/` here for offline audit). That gives an auditable upstream source for what each model is.

The "Intel could change semantics" concern applies equally to DID and CPUID, so DID brings no extra safety — only extra maintenance per SKU.

### Point 1 — exposing the full 128 kB MCHBAR region

This is the one that's worth a longer reply. The narrow surface is intentional, and the security envelope at the top of the file lists it as a design goal (IntelIMC.p:35-41):

> - Read-only (no writes to PCI cfg / MMIO / MSR / IO).
> - No caller-controlled physical addresses or PCI BDF.
> - Fixed compile-time MCHBAR offsets only.
> - Strict CPUID allowlist; unknown models return `STATUS_NOT_SUPPORTED`.
> - Reserved-bits and ratio-range checks reject wrong-register reads.
> - MCHBAR enable bit is observed, never set.

The narrowness is what makes the safety checks meaningful:

- The reserved-bits mask in `read_memss_pma` and the `IMC_RATIO_MIN..MAX` range check work *because* the module knows which register it's reading. A wrong-stepping or wrong-platform read fails closed.
- A user-space tool can't accidentally turn an unknown MCHBAR field into a "Memory Clock" sensor.
- The audit surface for a security review stays small and stable.

A generic `read_mchbar_dword(offset)` would lose all of that. MCHBAR isn't only IMC — it also covers DMI, PCIe, IMPH, etc. Reads are side-effect-free, agreed, but exposing arbitrary architectural reserved fields weakens the defense-in-depth story: the module would no longer be self-contained in what it reads.

If you'd like a wider surface for diagnostics or future sensors, I'd suggest a *separate* IOCTL — for example `ioctl_read_mchbar_dword` — with either:

- an allowlist of permitted offset ranges, or
- a bounds check `[0, 0x20000)` plus dword alignment.

That keeps the public Memory-Clock API tight and labels the wider path explicitly as a diagnostic / research surface. Happy to fold either option into this PR if you'd prefer to widen it.
