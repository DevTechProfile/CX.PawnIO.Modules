# PR #53 — Analyse der Review-Punkte von namazso

PR: https://github.com/namazso/PawnIO.Modules/pull/53
Branch: `test_infrastructure`
Modul: `IntelIMC.p`
Stand: 2026-05-03

namazso hat in seinem Review-Kommentar vom 2026-05-01 23:44 drei Punkte aufgeworfen.
Daneben steht der allgemeine Hinweis, das Modul auf mindestens einer Plattform zu validieren
(Kommentar 15:06). Im Thread hat zusätzlich `a1ive` zu Punkt 3 widersprochen.

---

## Validierungs-Forderung (Vorab-Hinweis vom 15:06)

> *"I'd much prefer if this was tested on at least one of the supported platforms."*

**Status: bereits erfüllt — und zwar dreifach.** Auf diesem Branch existieren reproduzierbare
Validierungs-Reports mit HWiNFO64-Cross-Reference und SMBIOS-Abgleich:

| Plattform | CPU | Ratio / Gear | Decoded | HWiNFO/SMBIOS | Doc |
|---|---|---|---|---|---|
| PTL (0xCC) | Core Ultra X7 358H | 64 / Gear-bit=1 | DDR5-8533 | 8533 MT/s | `Deploy/VALIDATION-PTL.md` |
| ARL (0xC6) | Core Ultra 9 285K | 117 / Gear2 | DDR5-7800 | 7800 MT/s | `Deploy/VALIDATION-ARL.md` |
| LNL (0xBD) | Core Ultra 7 258V | 64 / Gear4 | LPDDR5x-8533 | 8533 MT/s | `Deploy/VALIDATION-LNL.md` |

`is_platform_validated()` (IntelIMC.p:283-289) löscht das `EXPERIMENTAL`-Flag jetzt für
PTL/ARL/LNL. MTL bleibt explizit als noch nicht validiert markiert. Das ist im
Antwort-Kommentar zu erwähnen — am besten mit Verweis auf die Reports im Branch.

---

## Punkt 1 — MCHBAR komplett (128 kB) für Lesezugriff freigeben?

> *"Is there any argument against just exposing the whole 128 kB region for reading?
> It looks benign and readable without sideeffects."*

**Aktueller Stand:** Das Modul exponiert ausschließlich drei eng definierte IOCTLs
(`ioctl_read_imc_clock`, `ioctl_read_imc_clock_live`, `ioctl_read_imc_clock_dbg`).
Alle Offsets sind Compile-Time-Konstanten; der Aufrufer kann keinen Offset reichen.
Diese Verengung wird im Header (IntelIMC.p:53-63) explizit als Designziel aufgeführt:
*"kept deliberately tight so a security review is easy"*.

**Bewertung:**

- **Pro namazso:** Ein generischer `read_mchbar_dword(offset)`-IOCTL würde künftige
  Sensoren (PMT-Telemetrie, weitere SA-Felder) ohne neuen Modul-Roll-out erlauben.
  Lesen aus MCHBAR ist tatsächlich seiteneffektfrei.
- **Contra:** Die im Modul verbauten Plausibilitäts-Gates (Reserved-Bits-Maske in
  `read_memss_pma`, Ratio-Range `IMC_RATIO_MIN..MAX`) schützen vor "falsches Register /
  falsche Stepping" — sie wirken nur, weil das Modul selbst entscheidet, *welcher*
  Offset gelesen wird. Bei Caller-controlled offset entfällt dieser Schutz, und ein
  User-Space-Tool kann z.B. unbekannte Felder als "Memory Clock" fehlinterpretieren.
- **Praktisches Risiko:** MCHBAR umfasst nicht nur Memory-Controller-Felder, sondern
  auch DMI/PCIe/IMPH-Status. Auch wenn Lesen seiteneffektfrei ist, ist *unkommentiertes*
  Lesen architekturabhängiger Reserved-Felder eine schwächere Schicht im
  Defense-in-Depth-Argument.

**Empfehlung:** Antworte sachlich mit der Designbegründung — und biete einen Kompromiss
an, falls namazso auf der Erweiterung besteht: einen separaten IOCTL
`ioctl_read_mchbar_dword` mit (a) Allowlist erlaubter Offset-Bereiche oder (b) Range-Check
`[0, 0x20000)` plus dword-Alignment. So bleibt der enge Pfad für die "öffentliche"
Memory-Clock-API erhalten, und der weite Pfad ist klar als "Diagnostik / Forschungs-Surface"
gekennzeichnet.

---

## Punkt 2 — `main()`-Kommentar: Fehlerstatus aus main reicht nicht zurück?

> *"About the comment in `main`: I believe error statuses from main should travel back
> just fine, and a quick review of PawnIO code seems to confirm this. Are you sure it
> didn't work for you?"*

**Aktueller Stand (IntelIMC.p:740-753):**

```pawn
NTSTATUS:main() {
    if (get_arch() != ARCH_X64) return STATUS_NOT_SUPPORTED;
    if (get_cpu_vendor() != CpuVendor_Intel) return STATUS_NOT_SUPPORTED;

    // Intentionally do not gate on CPU model here. Returning success on
    // any Intel x64 lets users on unsupported models still load the
    // module and observe STATUS_NOT_SUPPORTED from the IOCTL itself,
    // which makes "module didn't load" easy to tell apart from "this CPU
    // is not on the allowlist".
    return STATUS_SUCCESS;
}
```

**Wichtig:** Der Kommentar **behauptet gar nicht**, dass Fehlerstatus aus `main` nicht
zurück wandert. Das Modul gibt für x64/Intel-Vendor-Mismatch durchaus
`STATUS_NOT_SUPPORTED` aus `main` zurück. Was *nicht* in `main` gegated wird, ist der
CPUID-Model-Check — und zwar bewusst aus UX-Gründen, damit der Aufrufer "Modul lud nicht"
(z.B. PawnIO-Treiber-Problem) von "CPU ist nicht in der Allowlist" (Modul lud, IOCTL
liefert `STATUS_NOT_SUPPORTED`) unterscheiden kann.

Vermutung: namazso hat den Kommentar als "der Autor glaubt, Fehlerstatus aus main
funktioniere nicht und macht deshalb kein Gating" gelesen. Tatsächlich ist der Grund
pure UX-Differenzierung. Der Original-Commit `43503e7` enthält denselben Kommentar — es
war nie ein Workaround.

**Empfehlung:** Klarstellen, dass die Aussage *nicht* "Fehlerstatus reicht nicht zurück"
lautet, sondern "wir wollen IOCTL-`STATUS_NOT_SUPPORTED` sehen, statt einen Load-Fehler".
Optional den Kommentar zur Vermeidung weiterer Missverständnisse umformulieren — z.B.:

```
// CPU-model gating happens in each IOCTL, not here. This is a UX choice:
// "module loaded but IOCTL returns STATUS_NOT_SUPPORTED" is much easier
// to diagnose than "module failed to load". Errors returned from main
// do propagate; this is not a workaround for that.
```

Damit ist der Punkt vom Tisch — keine Code-Änderung am Verhalten nötig.

---

## Punkt 3 — Restriction nach DID/VID statt CPUID?

> *"It seems that both CPU groups that have this share a DID/VID of 8086/4600
> (according to docs ...), would it make more sense to restrict based on this instead,
> or could this change ... at Intel's discretion?"*

**Wichtiger Kontext:** `a1ive` hat hier bereits **mit Belegen widersprochen** (Kommentar
vom 2026-05-02 02:37, mit Screenshot): DIDs unterscheiden sich **selbst innerhalb
derselben Generation** der Core-CPUs. memtest86plus folgt dem gleichen Muster
(CPUID-basiert, MCHBAR-via-PCI-Config) seit Sandy Bridge.

**Bewertung:**

- DID-basierte Restriction wäre nicht *robuster*, sondern **brüchiger**: Pro Generation
  existieren mehrere DIDs (Mobile/Desktop/Workstation/SoC-Varianten), die alle einzeln
  gepflegt werden müssten. CPUID-Model dagegen ist 1:1 zu Intels eigener `mapfile.csv`
  (im Header IntelIMC.p:197-203 referenziert, im Repo unter `intel-perfmon/`).
- namazsos eigenes Argument ("könnte sich bei gleichem DID die Semantik ändern") gilt
  **identisch** für CPUID — beides sind Intel-vergebene Identifier. Es gibt keinen Vorteil.
- Die fragliche Register-Identität ist nicht "welche Host-Bridge-Variante", sondern
  "welches Silizium / welche IMC-Version" — und das ist genau CPUID FMS, nicht DID.
- Das Modul **muss ohnehin** CPUID lesen, weil es zwischen MEMSS_PMA-Pfad (Core Ultra)
  und SA_PERF-Pfad (ADL/RPL) differenziert. DID lesen wäre ein zusätzlicher Pfad ohne
  Gewinn.

**Empfehlung:** a1ives Punkt aufgreifen ("DIDs varianten innerhalb einer Generation,
siehe sein Screenshot") und ergänzen: das Modul gleicht die Allowlist gegen Intels
offizielle `mapfile.csv` ab (ist im Repo unter `intel-perfmon/` vorhanden). Damit ist
die Pflege auditbar und folgt Intels eigener Plattform-Klassifikation. DID-Filtering
wäre keine zusätzliche Sicherheit, nur zusätzliche Pflege-Last.

---

## Vorgeschlagene Antwort-Strategie an namazso

1. **Validierungs-Status zuerst** — erledigt auf 3 Plattformen, Reports im Branch
   verlinken. Das nimmt seiner Hauptforderung den Wind aus den Segeln.
2. **Punkt 2 ist ein Missverständnis** — höflich klarstellen, ggf. den Kommentar
   umformulieren (s.o.).
3. **Punkt 3 ist faktisch entkräftet** — auf a1ives Antwort verweisen, mapfile.csv-
   Audit-Pfad nennen.
4. **Punkt 1 ist eine echte Designdiskussion** — die Gründe für das enge Surface
   darlegen und einen optionalen Kompromiss-Pfad (separater diagnostic IOCTL mit
   Bounds-Check) anbieten, falls namazso das Surface erweitern will.

Punkte 2 und 3 lassen sich ohne Code-Änderung schließen (Punkt 2 maximal mit einer
Kommentar-Schärfung). Punkt 1 ist die einzige offene Designfrage, und die ist begründbar
in beide Richtungen.

---

## Phase 2: PMT/CTL-Migration (zukünftiger Pfad, nicht für diesen PR)

Während der ARL-Live-Pfad-Bring-up haben wir cpuz.exe und seinen Kernel-Treiber statisch
analysiert (siehe `Deploy/DETECT-ARL-LiveIMC*.md` und `Deploy/VERIFY-ARL-LoadCorrelation.md`
für die Hardware-Side; der RE-Befund hier ist die Code-Side). Die wichtigsten Ergebnisse:

**CPU-Z-Treiber** (`cpuz1xx_x64.sys`, 44 KB, generisch):
- Enthält nur **eine** unserer ARL-Offset-Konstanten als Byte-Pattern: `0x5918` (SA_PERF)
- Die Offsets `0x13D10` (MEMSS_PMA), `0x13D98` (PTGRAM), `0xE448` (unsere Live-Quelle)
  fehlen komplett im Binary
- Das ist der typische Generic-Read-Driver-Aufbau: read-PCI-Config / read-MMIO /
  read-MSR Primitives, die Offsets kommen vom User-Space-Frontend

**cpuz.exe** (7.2 MB, nicht gepackt):
- Auch hier nur `0x5918` als Offset-Byte-Pattern. `0x13D10`, `0x13D98`, `0xE448`
  ebenfalls nicht vorhanden
- ASCII-Strings als Hinweis auf den verwendeten Mechanismus:
  - `"PCI extended capability"` → walked PCIe Extended Config (Offsets > 0xFF, via MMCFG)
  - `"PMT version"` / `"PMTV"` / `"pmtv"` → reads Intel PMT discovery headers
  - **`"ctlPowerTelemetryGet"`** → Intel oneAPI Control Library function; offizieller
    Telemetry-API-Eintrittspunkt
  - `"uncore_frequency"` → Linux-sysfs-Naming, vermutlich vom intel_uncore_frequency_tpmi-
    Treiber portierter Code
- Die ASCII-GUIDs im Binary (`8e0f7a12-...`, `e2011457-...` etc.) sind Windows-OS-
  Compatibility-Manifest-GUIDs und nicht PMT-Telemetry-IDs (false lead, korrigiert)

**Daraus abgeleiteter Mechanismus** für CPU-Z auf Core Ultra:

1. PCIe-Extended-Config-Walk auf Bus 0 nach DVSEC-Capabilities (Cap-ID `0x23`,
   Vendor `0x8086`)
2. Discovery der PMT-Telemetry-Endpoints, Match auf Memory-Subsystem-GUID
3. MMIO-Map auf den Telemetry-Block, Counter-Tabelle parsen
4. Read der "current memory clock"-Counter — bereits in der vom Hardware bzw.
   Intel-Firmware geclampten kanonischen Form (`{72, 117}` ohne unser +1 PLL-Overshoot)

Auf älteren Plattformen (ADL/RPL) fällt CPU-Z auf den klassischen MCHBAR+0x5918-Pfad
zurück (das ist warum dieser eine Offset im Binary steht).

### Phase-2-Migration-Plan (zukünftig)

Wenn / sobald wir PMT/CTL in PawnIO implementieren wollen:

- **Trigger-Bedingungen**: neue Plattform bricht den aktuellen MCHBAR-Pfad (siehe
  ARL-Effekt auf MTL-Nachfolger), oder Konsumenten brauchen zusätzliche PMT-Counter
  (DRAM Voltage, MC Power, PMT-basierte Uncore Frequency etc.) die nur über PMT
  verfügbar sind. Dann wäre PMT-Discovery sowieso nötig und der Live-Frequency-Reader
  wäre billiger Beifang.
- **Aufwand**: ~200-300 Zeilen Pawn für PCIe-Extended-Config-Walk + DVSEC Discovery +
  GUID-Match + Telemetry-Block-Parser
- **Vorteile**:
  - Eliminiert das bits[7:0]+1-PLL-Overshoot-Quirk auf ARL nativ (statt Clamp)
  - Vereinheitlicht den Live-Pfad über MTL/LNL/PTL/ARL und zukünftige Core Ultra
  - Selber Discovery-Code generalisiert auf Server (SPR/GNR) und discrete GPUs (Battlemage)
- **Risiken**:
  - Bricht working code auf MTL/LNL/PTL die aktuell sauber sind
  - Re-Validation auf 3 Plattformen nötig (MTL haben wir keine Hardware)
  - PMT-GUIDs müssen pro Plattform gepflegt werden (Intel veröffentlicht sie inzwischen
    im offenen `intel/Intel-PMT`-Repo)

### Aktuelle pragmatische Lösung (in diesem PR)

ARL liest `MCHBAR + 0xE448` mit `bits[7:0]` als Live-Ratio-Quelle. Die Hardware encodet
den High-State als `trained_max + 1` (33-MHz-Overshoot). Der Live-IOCTL clampt diesen Raw-
Wert via `if (ratio > trained_max) ratio = trained_max;` zurück auf MEMSS_PMAs trained
max, sodass `ratio` exakt das matcht was HWiNFO/CPU-Z anzeigen. Die `Raw`-Spalte im Output
behält den un-clamped Register-Dword für Forensik.

Damit:
- Konsumenten bekommen kanonische `{72, 117}` (oder `{72, 105}` bei DDR5-7000) Werte —
  identisch zu CPU-Z/HWiNFO
- Hardware-Wahrheit bleibt im Raw-Feld erhalten
- Kein Verlust an Diagnose-Capabilities, kein Reviewer-Friction durch abweichende Werte
- Phase-2-PMT bleibt dokumentiertes Future-Work, nicht Blocker für diesen PR

---

## Anhang: Ghidra-Disassembly-Befunde (cpuz_drv.sys)

Cross-validierung der oben abgeleiteten "Driver ist generisch + Logic in cpuz.exe"-Hypothese
durch tatsächliche Disassembly mit Ghidra 12.0.4 headless. Ziel war zu prüfen ob die Strings-
und Byte-Pattern-Befunde standhalten wenn man den Driver-Code wirklich anschaut.

### Setup

- **Tool**: Ghidra 12.0.4 PUBLIC headless mit `analyzeHeadless.bat`
- **Java**: Microsoft OpenJDK 21.0.10 (LTS)
- **Target**: `cpuz_drv.sys` (44 KB, x86 PE/64-bit, randomly-named at
  `C:\ProgramData\CPUID Software\cpu-z\<random>`, registriert als Service `cpuz161`)
- **Custom Java GhidraScripts** (in `/tmp/ghidra_scripts/`): `InspectDriver.java`
  (Imports + key API call sites + hardcoded immediates) und `DecompileV2.java`
  (DriverEntry + IOCTL-Handler decompile via `DecompInterface`)

### DriverEntry (FUN_00011780, 530 bytes / 113 insns)

```c
DriverEntry(DRIVER_OBJECT *drvObj) {
    L"\\Device\\cpuz161"
    L"\\DosDevices\\CPUZ161"          // pre-Vista
    L"\\DosDevices\\Global\\CPUZ161"  // Vista+
    IoCreateDevice(...)
    PsGetVersion(&buildNum, ...)       // major < 5 picks old, ≥5 picks Global
    IoCreateSymbolicLink(picked, dev)
    drvObj->MajorFunction[IRP_MJ_CREATE]         = FUN_000119a0  // +0x70
    drvObj->MajorFunction[IRP_MJ_CLOSE]          = FUN_000119a0  // +0x80
    drvObj->MajorFunction[IRP_MJ_DEVICE_CONTROL] = FUN_000119a0  // +0xe0
    drvObj->DriverUnload                         = FUN_00017140  // +0x68
}
```

User-Space connectet zu `\\.\CPUZ161` und schickt IOCTLs. Drei IRP-Types werden vom selben
Mega-Handler `FUN_000119a0` verarbeitet (= 4833 instructions, 20823 bytes).

### Imports (Kernel-APIs die der Driver braucht)

```
ExAllocatePoolWithTag, ExFreePoolWithTag
HalGetBusDataByOffset, HalSetBusDataByOffset       // PCI Config Read/Write
IoCreateDevice, IoCreateSymbolicLink, IoDeleteDevice
IoBuildDeviceIoControlRequest                       // forward IOCTL to other driver
KeQueryPerformanceCounter, KeStallExecutionProcessor
MmMapIoSpace, MmUnmapIoSpace                        // generic MMIO
ObfDereferenceObject, PsGetVersion
RtlInitUnicodeString, RtlAnsiStringToUnicodeString
SeSinglePrivilegeCheck                               // privilege guard
```

Notabel **fehlend**: `MmGetSystemRoutineAddress` (= keine dynamische API-Auflösung),
`MmAllocateContiguousMemory` (= keine DMA-Buffer), `ZwOpenSection` (= kein
`\Device\PhysicalMemory`-Pfad).

### IOCTL-Surface: 51 distinkte Codes, alle DeviceType `0x9C40`, METHOD_BUFFERED

Aus dem Switch-Statement in FUN_000119a0 extrahiert:

| Function-Range | Vermutete Bedeutung | MmMapIoSpace? |
|---|---|---|
| 2304-2306 (`0x9c402400-08`) | Connect/disconnect/version | nein |
| 2320-2323 (`0x9c402440-4c`) | **MSR Read/Write** mit Allowlist auf MSRs `0x19C` (THERM_STATUS), `0x1B1` (PACKAGE_THERM_STATUS), `0x607-0x608` und AMD-MSRs `0xc0010232..0xc001024a` | nein |
| 2336-2338 (`0x9c402480-88`) | **PCI Config Read** (Byte/Word/Dword via HalGetBusDataByOffset) | nein |
| 2352-2354 (`0x9c4024c0-c8`) | **Timed MSR/HPET measurements** (CPU-Frequency-Calibration via TSC-Delta) | ja |
| 2384-2394 (`0x9c402540-68`) | **MMIO Read/Write** Byte/Word/Dword/Qword at user-provided phys addr | ja, 11× |
| 2401-2406, 2416-2420 | Multi-byte MMIO Reads / Variants | ja |
| 2432-2434 (`0x9c402600-08`) | Hardcoded Reads von `0xFFC00000` (= BIOS ROM region) | ja |
| 2448-2451 (`0x9c402640-4c`) | Mehr MMIO Ops | ja |
| 2464-2480 (`0x9c402680-c0`) | Hardcoded Reads von `0xFED80A00` (= PCH P2SB region) | ja |
| 2496 (`0x9c402700`) | (vermutlich Time-Stamp / Last-IOCTL) | nein |

Privilege-Guards: `SeSinglePrivilegeCheck(10, 1)` (= `SeTcbPrivilege`) für die schreibenden
IOCTLs. Reads sind ohne Privilege erlaubt — das matched zu CPU-Z's "User kann ohne Admin-
Rechte Read-Only-Daten sehen, aber für Tweaks braucht's Admin"-UX.

### Beispiel: das generische MMIO-Read-IOCTL `0x9c402540`

```c
case 0x9c402540: {
    uVar27 = CONCAT44(uStack_1dc, local_1e0);   // user input: 64-bit phys address
    plVar19 = FUN_00011220(uVar27, uVar15);     // mapping cache lookup
    if (plVar19 == 0) {
        lVar23 = MmMapIoSpace(uVar27, uVar15, 0);   // map user's phys addr
        if (lVar23 != 0) {
            for (i = 0; i < uVar15; i++)
                output[i+4] = ((byte*)lVar23)[i];   // copy to user buffer
            MmUnmapIoSpace(lVar23, uVar15);
        }
    } else {
        // re-use existing cached mapping
    }
    IRP->IoStatus.Information = uVar15 + 4;
    IRP->IoStatus.Status = STATUS_SUCCESS;
}
```

Der Driver liest **was der User-Space als Adresse mitschickt** — er kennt keine
Plattform-spezifische Logik.

### Hardcoded Konstanten im gesamten Driver

| Konstante | Hits | Bedeutung |
|---|---|---|
| `0x48` | **32** Hits in 7 Funktionen | PCI-Config-Offset für MCHBAR_LO (Standard für alle Intel Client Chipsets) |
| `0x4C` | implizit über 0x48+4 | MCHBAR_HI |
| `0xFFC00000` | 1 in IOCTL 2432 | BIOS ROM region read (für Firmware-Info / DMI table) |
| `0xFED80A00` | 2 in IOCTL 2464/2466 | PCH P2SB region (für Sideband-Telemetry) |
| **`0x5918`** | 0 in Driver, 1 in cpuz.exe | SA_PERF_STATUS — nur User-Space-Logic |
| **`0x13D10`, `0x13D98`, `0xE448`** | 0 in Driver UND 0 in cpuz.exe (als Byte-Pattern!) | IMC-Offsets sind **berechnet zur Laufzeit**, nicht als Immediates kompiliert |

Die Tatsache dass auch `cpuz.exe` keinen einzigen unserer ARL-Offsets als Byte-Pattern
enthält (außer 0x5918 für ältere Plattformen), bedeutet: cpuz.exe muss diese Offsets via
**PMT-Discovery zur Laufzeit auflösen** — was perfekt mit den Strings `"PCI extended capability"`,
`"PMT version"`, `"ctlPowerTelemetryGet"` zusammenpasst die wir vorher in cpuz.exe fanden.

### Bestätigte Architektur

```
                              IOCTLs (DeviceCode 0x9C40)
   ┌─────────────────┐   ───────────────────────────►   ┌───────────────────┐
   │   cpuz.exe      │                                  │   cpuz_drv.sys    │
   │   (User-Space)  │   ◄───────────────────────────   │   (Kernel-Treiber)│
   │                 │      Antwort-Bytes               │                   │
   ├─────────────────┤                                  ├───────────────────┤
   │ * PMT-Discovery │                                  │ * MMIO read/write │
   │ * GUID-Match    │                                  │ * PCI-Config R/W  │
   │ * Reg-Decode    │                                  │ * MSR R/W (allowl)│
   │ * Display-Logic │                                  │ * Port I/O        │
   │ * Plattform-DB  │                                  │ * KeQueryPerfCnt  │
   └─────────────────┘                                  └───────────────────┘
```

Die ENTIRE plattformspezifische Logic (MCHBAR-Offsets, Bit-Field-Decoding, PMT-GUID-
Matching, Clamps für UI-Display) sitzt in cpuz.exe. Der Driver ist purely Hardware-Access-
Primitives, ähnlich zu WinRing0, RW-Everything, oder unserem PawnIO-Treiber.

### Implikationen für unseren Phase-2 PMT/CTL-Pfad

Wenn wir später PMT-Discovery in PawnIO einbauen wollen, brauchen wir Primitives die
cpuz_drv.sys auch hat:

- ✅ **MMIO Read/Write**: `io_space_map` + `virtual_read_dword` (haben wir bereits)
- ✅ **PCI Config Read** (offsets 0..0xFF): `pci_config_read_dword` (haben wir bereits)
- ⚠️ **PCIe Extended Config Read** (offsets 0x100..0xFFF, via MMCFG): müsste neu — typischer
  Weg ist ACPI-MCFG-Tabellen-Lookup für die MMCFG-Base-Adresse, dann via `io_space_map`
  des Bus/Device/Function-Slots
- ✅ **MSR Read** mit Allowlist: `msr_read` (IntelMSR.p hat das Pattern)

Nur die MMCFG-/Extended-Config-Schicht ist neu. Mit der könnten wir DVSEC-Discovery
(Cap-ID 0x23, Vendor 0x8086) implementieren und PMT-Telemetry-Endpunkte enumerieren.

---

## Roh-Quellen (für späteren Abgleich)

### namazso, Kommentar 2026-05-01 15:06 UTC

> Hi,
>
> You can test without signatures with the unrestricted driver:
>
> https://github.com/namazso/PawnIO.Modules/wiki/Getting-started-with-PawnIO
>
> I'd much prefer if this was tested on at least one of the supported platforms.

### namazso, Kommentar 2026-05-01 23:44 UTC (edited 23:49)

> I did a quick review on the code, I have some observations:
>
> - Is there any argument against just exposing the whole 128 kB region for reading?
>   It looks benign and readable without sideeffects.
> - About the comment in `main`: I believe error statuses from main should travel back
>   just fine, and a quick review of PawnIO code seems to confirm this. Are you sure it
>   didn't work for you?
> - It seems that both CPU groups that have this share a DID/VID of 8086/4600 (according
>   to docs, but it's not on https://pci-ids.ucw.cz/ ), would it make more sense to
>   restrict based on this instead, or could this change (or rather, remain the same
>   while the semantics for accessing it change) at Intel's discretion?

### a1ive, Kommentar 2026-05-02 02:37 UTC (Antwort auf Punkt 3)

> > It seems that both CPU groups that have this share a DID/VID of 8086/4600 ...
>
> Even within the same generation of Core CPUs, the DID is not the same.
> [Screenshot: https://github.com/user-attachments/assets/b514c275-9562-488a-a1f1-2403a13b4381]
>
> The method for reading MCHBAR has been compatible with later generations since at
> least Sandy Bridge, see
> https://github.com/memtest86plus/memtest86plus/blob/main/system/imc/x86/intel_snb.c
