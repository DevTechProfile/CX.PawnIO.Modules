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

## Heads-up: PawnIO 2.2.0 is PnP-only

The driver in this bundle is `namazso/PawnIO` v2.2.0, which creates
`\Device\PawnIO` only from inside the PnP `AddDevice` callback —
`DriverEntry` never calls `IoCreateDevice` itself. A plain
`sc.exe create … type= kernel` loads the driver into the kernel but
exposes **no device**, so `PawnIOUtil test` (and every other usermode
call) returns `0x80070002` / `ERROR_FILE_NOT_FOUND`. `Install.ps1` in
this bundle uses exactly that legacy-service pattern and is therefore
**not sufficient by itself for v2.2.0** — you also have to enumerate the
driver as a `Root\PawnIO` software device via the bundled INF. From
elevated PowerShell, after `Install.ps1` has staged the files:

```powershell
$devcon = 'C:\Program Files (x86)\Windows Kits\10\Tools\10.0.26100.0\x64\devcon.exe'
& $devcon install (Resolve-Path .\PawnIO-Bundle\driver\PawnIO.inf) 'Root\PawnIO'
```

`devcon.exe` ships with the WDK (substitute your SDK version). For
`devcon install` to succeed, both `PawnIO.sys` and `pawnio.cat` must be
signed by a cert that lives in `LocalMachine\Root` +
`LocalMachine\TrustedPublisher` (`Install.ps1` already imports
`PawnIO_TestCert.cer` into both). After devcon completes, `\Device\PawnIO`
exists and `PawnIOUtil test` works.

### Marked-for-deletion lock — reboot required

If you ran `Install.ps1` once on a v2.2.0 driver and try to re-install
(or run `devcon install` to fix the missing device), setupapi fails with
error `1072 (ERROR_SERVICE_MARKED_FOR_DELETE)`: the old `PawnIO` service
is still loaded with no `DriverUnload` available, so `sc.exe stop` /
`sc.exe delete` only flag it for deletion. The marked service can't be
recreated until the old image is unloaded, which only happens at the
**next reboot**. Diagnose via `C:\Windows\INF\setupapi.dev.log`
(search for `pawnio` and `Error 1072`).

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
