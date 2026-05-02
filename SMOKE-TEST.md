# Smoke Test — TestMinimal.p

End-to-end recovery + minimum-viable-load procedure for PawnIO 2.2.0+ on a
fresh boot. `TestMinimal.p` is a no-op module (`main() -> STATUS_SUCCESS`)
that exercises the driver's load path without depending on any IOCTL surface
— if it loads, the driver and the build/sign/load toolchain are functional.

## Pre-conditions

| Requirement                | How to verify                                                                      |
|----------------------------|------------------------------------------------------------------------------------|
| Test signing on            | `bcdedit /enum '{current}'` shows `testsigning Yes`                                |
| Memory Integrity / HVCI off | Settings → Privacy & security → Windows Security → Device security → Core isolation |
| `PawnIO Dev Cert` trusted  | `Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher \| ? Subject -match PawnIO` |
| WDK devcon present         | `C:\Program Files (x86)\Windows Kits\10\Tools\10.0.26100.0\x64\devcon.exe`         |
| `pawncc` on `PATH`         | `Get-Command pawncc` → e.g. `C:\Program Files (x86)\Pawn\bin\pawncc.exe`           |
| Runtime staged             | `C:\Program Files\PawnIO\PawnIOUtil.exe` + `PawnIOLib.dll`                         |

## Step 1 — Driver: get `\Device\PawnIO` back after a reboot

**Symptom.** After reboot, the driver is gone:

```powershell
Get-Service -Name PawnIO          # not found
Test-Path '\\?\GLOBALROOT\Device\PawnIO'   # False
Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\PawnIO'   # False
```

The `pawnio.inf` package is still in the driver store
(`pnputil /enum-drivers | sls PawnIO`), but no PnP node was enumerated.

**Why this happens.** PawnIO 2.2.0 is **PnP-only**: `DriverEntry` registers
`AddDevice` but never calls `IoCreateDevice` itself. Without a `Root\PawnIO`
software-device PnP node, `AddDevice` is never fired, so `\Device\PawnIO`
never exists. A legacy `sc.exe create` service alone is therefore
insufficient — the driver loads into the kernel but exposes nothing.

**Fix.** From an elevated PowerShell:

```powershell
& 'D:\Code\PawnIO\Reinstall-FreshDriver.ps1'
```

The script tears down any orphaned PnP node, re-runs
`devcon install …\PawnIO.inf "Root\PawnIO"`, and verifies that the new
device opens from user mode. Expected end state:

```
Service state : Running
PathName      : C:\WINDOWS\system32\DriverStore\FileRepository\pawnio.inf_amd64_<hash>\PawnIO.sys
PnP nodes     : ROOT\SOFTWAREDEVICE\0000 : PawnIO
\\.\PawnIO opens OK
```

## Step 2 — Module: compile `TestMinimal.p`

**Symptom.**

```
core.inc(20) : error 021: symbol already defined: "tolower"
core.inc(24) : error 021: symbol already defined: "toupper"
core.inc(39) : error 021: symbol already defined: "min"
core.inc(43) : error 021: symbol already defined: "max"
core.inc(47) : error 021: symbol already defined: "clamp"
…
```

**Why this happens.** `pawncc` auto-prepends a default prefix file
(`C:\Program Files (x86)\Pawn\include\default.inc`) that pulls in pawncc's
own stdlib `core.inc`. PawnIO's `include\core.inc` defines its own
`tolower`/`toupper`/`min`/`max`/`clamp`/`swapchars`, so they collide.

**Fix.** Block the default prefix with `-p` (no name) and pick the 64-bit
cell size the driver expects:

```powershell
$repo = 'D:\Code\CX.PawnIO.Modules'
& 'C:\Program Files (x86)\Pawn\bin\pawncc.exe' `
    -C64 -p `
    "-i$repo\include" `
    "-o$repo\TestMinimal.amx" `
    "$repo\TestMinimal.p"
```

The single remaining `warning 218: old style forward declarations` lives in
upstream `pawnio.inc` and is harmless. Expected output: ~120 B `.amx`.

## Step 3 — Sign + load

The driver is built with `PAWNIO_UNRESTRICTED=ON`, so the signature is
**not** verified — but `PawnIOUtil` still expects the
`[u32 siglen][sig][amx]` blob format, so we have to wrap the AMX (any RSA
key works).

```powershell
# one-off: generate an RSA-2048 PEM key (gitignored as my.key)
& "$repo\New-PawnIOKey.ps1" -OutPath "$repo\my.key"

# wrap the AMX
& 'C:\Program Files\PawnIO\PawnIOUtil.exe' sign `
    "$repo\TestMinimal.amx" `
    "$repo\TestMinimal.signed.amx" `
    "$repo\my.key"

# load it (smoke test = exit 0)
& 'C:\Program Files\PawnIO\PawnIOUtil.exe' test "$repo\TestMinimal.signed.amx"
```

`PawnIOUtil test` opens `\\.\PawnIO`, sends `IOCTL_PIO_LOAD_BINARY` with the
blob, the driver runs the module's `main()` (returns `STATUS_SUCCESS`),
then closes the handle. Exit code 0 = full path works.

## End-to-end recovery script

For a fresh boot where everything needs to come up:

```powershell
# 1. Driver
& 'D:\Code\PawnIO\Reinstall-FreshDriver.ps1'

# 2. Module
$repo = 'D:\Code\CX.PawnIO.Modules'
if (-not (Test-Path "$repo\my.key")) { & "$repo\New-PawnIOKey.ps1" -OutPath "$repo\my.key" }
& 'C:\Program Files (x86)\Pawn\bin\pawncc.exe' -C64 -p "-i$repo\include" `
    "-o$repo\TestMinimal.amx" "$repo\TestMinimal.p"
& 'C:\Program Files\PawnIO\PawnIOUtil.exe' sign `
    "$repo\TestMinimal.amx" "$repo\TestMinimal.signed.amx" "$repo\my.key"
& 'C:\Program Files\PawnIO\PawnIOUtil.exe' test "$repo\TestMinimal.signed.amx"
if ($LASTEXITCODE -eq 0) { 'SMOKE TEST PASSED' } else { "FAILED ($LASTEXITCODE)" }
```

## Failure-mode cheat sheet

| Exit / error                                              | Likely cause                                   | Fix                                                                  |
|-----------------------------------------------------------|------------------------------------------------|----------------------------------------------------------------------|
| `0x80070002 ERROR_FILE_NOT_FOUND` from `PawnIOUtil`       | `\Device\PawnIO` missing                       | Step 1 (Reinstall-FreshDriver.ps1)                                   |
| `0x000003E5 / STATUS_PENDING` style hang                  | Driver loaded but PnP not finished             | Wait, then re-run; if persistent, reboot and re-run Step 1           |
| `0xC0000022 STATUS_ACCESS_DENIED` opening `\\.\PawnIO`    | Not elevated                                   | Re-launch PowerShell as admin                                        |
| `error 021: symbol already defined` from pawncc           | Default prefix included                        | Add `-p` to pawncc invocation                                        |
| `error 017: undefined symbol "main"` style                | `-i` doesn't point at PawnIO `include\`        | Check `-i$repo\include`                                              |
| `pawncc` exit 1, no errors printed                        | Wrong cell size, AMX would not load anyway     | Add `-C64`                                                           |
| `STATUS_INVALID_IMAGE_FORMAT` on load                     | Blob has no signature header                   | Re-run `PawnIOUtil sign …`                                           |
| `STATUS_INVALID_SIGNATURE` on load                        | Driver was built **without** `PAWNIO_UNRESTRICTED`; key not in `k_trusted_keys` | Rebuild driver with `-DPAWNIO_UNRESTRICTED=ON`, or sign with a trusted key |
| `1072 ERROR_SERVICE_MARKED_FOR_DELETE` from devcon install | Old PawnIO image still loaded (no `DriverUnload`) | Reboot, then re-run Step 1                                           |
