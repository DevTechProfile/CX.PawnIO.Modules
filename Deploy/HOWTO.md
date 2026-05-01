# IntelIMC Test Bundle — How To

`PawnIO-IntelIMC-Bundle.zip` packages the unrestricted PawnIO driver, its
test cert, the usermode runtime, and a pre-signed `IntelIMC.amx` so the
module can be tried on a fresh Windows machine without rebuilding any of
the kernel-side bits.

## Quick start on the target machine

1. **Enable test signing** (one-time, requires reboot)
   ```powershell
   bcdedit /set testsigning on
   Restart-Computer
   ```
   Also disable Memory Integrity / VBS / HVCI in
   *Settings → Privacy & security → Windows Security → Device security →
   Core isolation*. It blocks self-signed drivers regardless of the
   testsigning flag.

2. **Unpack and install** (elevated PowerShell)
   ```powershell
   Expand-Archive .\PawnIO-IntelIMC-Bundle.zip -DestinationPath .\PawnIO-Bundle
   cd .\PawnIO-Bundle
   .\Install.ps1
   ```

3. **Run a test**
   ```powershell
   .\test\Test-IntelIMC.ps1 -AmxPath (Resolve-Path .\module\IntelIMC.signed.amx).Path
   ```

`Install.ps1` is idempotent and safe to re-run when you swap in a newer
driver or AMX. `Uninstall.ps1` reverses everything except the testsigning
flag (toggle that with `bcdedit /set testsigning off` if you want).

## What runs out of the box

| CPU family   | CPUID model | IOCTL behaviour                                 |
|--------------|-------------|-------------------------------------------------|
| Panther Lake | 0xCC, 0xD5  | Validated; both IOCTLs return without `EXPERIMENTAL` |
| Other Core Ultra (MTL/ARL/LNL), Alder/Raptor Lake | listed in `IntelIMC.p` | IOCTLs return data; `EXPERIMENTAL` flag set until cross-checked |
| Anything else | — | `STATUS_NOT_SUPPORTED` from the IOCTL (the module still loads) |

To clear `EXPERIMENTAL` on a newly-validated platform: edit
`is_platform_validated` in `IntelIMC.p`, recompile, sign, and rebuild the
bundle.

## Rebuilding the bundle

The intermediate `Deploy/bundle/` staging directory is gitignored. To
regenerate the zip after changing the driver, runtime, or `.amx`:

```powershell
# (re)stage files
$bundle = '.\Deploy\bundle'
Remove-Item $bundle -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $bundle\driver, $bundle\runtime, $bundle\module, $bundle\test -Force | Out-Null
Copy-Item C:\Users\Intel\source\repos\PawnIO\build\PawnIO\PawnIO_unsigned.sys $bundle\driver\
Copy-Item C:\Users\Intel\source\repos\PawnIO\build\PawnIO_TestCert.cer        $bundle\driver\
Copy-Item 'C:\Program Files\PawnIO\PawnIOLib.dll'  $bundle\runtime\
Copy-Item 'C:\Program Files\PawnIO\PawnIOUtil.exe' $bundle\runtime\
Copy-Item .\IntelIMC.signed.amx $bundle\module\
Copy-Item .\Test-IntelIMC.ps1   $bundle\test\

# keep Install.ps1, Uninstall.ps1, README.md in $bundle (already committed
# elsewhere if you've kept them under version control)

Compress-Archive -Path "$bundle\*" -DestinationPath .\Deploy\PawnIO-IntelIMC-Bundle.zip -Force
```

## Licence note

The bundled `PawnIO_unsigned.sys` is built from a locally-modified copy of
[namazso/PawnIO](https://github.com/namazso/PawnIO) (GPL-2.0). The
modification is a one-line off-by-one fix in
`PawnIO/PawnIO/src/amx_loader.h` that changes the post-load buffer-bound
check from `>=` to `>`. Anyone redistributing the bundled binary must make
the corresponding source available per GPL-2.0 — point recipients at the
upstream repo plus that one-line patch.
