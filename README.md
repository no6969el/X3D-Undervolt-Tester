# X3D Undervolt CO Killer

A single-core stress **and correctness-verification** tester for hunting unstable
Curve Optimizer (CO) / negative-offset undervolts on AMD Ryzen — tuned with the
X3D chips (9950X3D, 9800X3D, 7950X3D, 7800X3D, …) in mind, but works on any x86 CPU.

It doesn't just try to make the CPU crash. It runs deterministic math and **checks
the answer**, so a single wrong bit on one core is caught as an error *before* a
blue screen — and it tests each core at multiple points on its voltage/frequency
curve, because CO instability is operating-point specific.

> **This tool only *reveals* an unstable undervolt you already set in BIOS.**
> It never changes voltage, frequency, Curve Optimizer, power limits, or any
> firmware/registry setting. See [Safety](#safety).

---

## Why it catches what other tools miss

A core can pass hours of a heavy AVX-512 furnace yet reboot while browsing, because
those two loads sit at completely different points on the V/F curve. So each core is
tested with three profiles:

| Profile | Load | What it targets |
|---|---|---|
| **BOOST** | scalar, 1 thread | Highest frequency / **lowest voltage** — the "crashes at idle/browsing" corner. Usually the *easiest* place to expose a too-aggressive offset. |
| **TRANSIENT** | heavy (AVX-512), both SMT threads, toggled on/off every few ms | **di/dt voltage swings** the VRM can't track — the nastiest corner, and one almost no other tool exercises deliberately. |
| **HEAVY** | sustained AVX-512, max current | The **droop-under-load** corner. |

Every profile verifies its results (self-referencing per core), captures **WHEA**
hardware errors, and logs the core under test *before* it runs so a hard lock still
names the guilty core on the next launch.

---

## Requirements

- **Windows 10 or 11.**
- **PowerShell 7.4 or newer** (`pwsh.exe`) for AVX-512. On Windows PowerShell 5.1
  (`powershell.exe`) it falls back to AVX2/scalar automatically — but you want 7.4+.
  Install: `winget install --id Microsoft.PowerShell --source winget`
- An **AVX-512-capable CPU** for the 512-bit path (all Zen 4 / Zen 5, incl. every
  X3D). Without it, the tool uses AVX2 and still works.
- **No administrator rights required.** Core affinity, priority, WHEA log reads, and
  performance counters all work as a normal user. (Elevation is optional.)

Confirm your setup:

```powershell
pwsh -NoProfile -Command '$PSVersionTable.PSVersion; [System.Runtime.Intrinsics.X86.Avx512F]::IsSupported'
```

You want a version **≥ 7.4** and **`True`**.

---

## Quick start

Put `Test-UndervoltStability.ps1` somewhere (e.g. your Desktop) and run it with
**`pwsh`, not `powershell`**:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-UndervoltStability.ps1
```

The banner should read `Kernels: avx512, scalar, simd` and list the three profiles.
If it says AVX2 only, you're on PowerShell < 7.4 (or 5.1) — update PowerShell.

### One-click launchers (batch files)

Drop these in the **same folder** as the script and double-click:

| File | Runs |
|---|---|
| `UndervoltTests-Menu.bat` | A menu: Boost / Transient / Heavy / All / Extreme |
| `Run-Boost.bat` | BOOST profile only |
| `Run-Transient.bat` | TRANSIENT profile only |
| `Run-Heavy.bat` | HEAVY profile only |

The three single-mode launchers pass extra arguments through, e.g.
`Run-Heavy.bat -Preset Thorough -Shuffle`.

---

## Usage

```
pwsh -File .\Test-UndervoltStability.ps1 [options]
```

### Presets

| Preset | Profiles | Time/profile | Cycles | Notes |
|---|---|---|---|---|
| `Quick` | All | 90 s | 1 | Fast sanity check |
| `Standard` *(default)* | All | 150 s | 1 | |
| `Thorough` | All | 300 s | 2 | Shuffled order |
| `Overnight` | All | 600 s | 6 | Shuffled; leave it running |
| `Extreme` | All + AVX2 **MID** | 300 s | 3 | Shuffled, transient **period sweep**, 2-thread heavy |

```powershell
pwsh -File .\Test-UndervoltStability.ps1 -Preset Thorough -Shuffle
pwsh -File .\Test-UndervoltStability.ps1 -Preset Overnight
```

### Key options

| Option | Default | Description |
|---|---|---|
| `-Mode` | `All` | `All`, `Boost`, `Mid`, `Heavy`, or `Transient` (a single profile) |
| `-SecondsPerCore <int>` | preset | Seconds **per profile** per core (`All` = 3 profiles per core) |
| `-Cycles <int>` | preset | Full passes over all cores |
| `-Cores <int[]>` | all | Only test these physical core indices, e.g. `-Cores 3,11` |
| `-Shuffle` | off | Randomize core order each cycle |
| `-ThreadsPerCore <1\|2>` | 1 | Threads for the HEAVY profile |
| `-IncludeMid` | off | Add an AVX2 mid-curve profile |
| `-TransientOnMs / -TransientOffMs` | 3 / 3 | di/dt load-on / idle windows (ms) |
| `-TransientSweep` | off | Sweep the toggle period (~2–17 ms) to hit VRM resonances |
| `-StopOnError` | off | Halt on the first failure |
| `-NoAvx512` | off | Force AVX2/scalar (skips AVX-512) |
| `-NoClocks` | off | Disable the live boost-clock estimate |
| `-LogPath / -ReportPath` | script folder | Override output paths |

### Examples

```powershell
# Just the di/dt killer, longer, with a period sweep
pwsh -File .\Test-UndervoltStability.ps1 -Mode Transient -TransientSweep -SecondsPerCore 600

# Retest only the cores that failed earlier
pwsh -File .\Test-UndervoltStability.ps1 -Cores 3,11 -Preset Thorough

# Hunt the max-boost / idle-crash corner specifically
pwsh -File .\Test-UndervoltStability.ps1 -Mode Boost -SecondsPerCore 900
```

While running, press **Q** to stop cleanly after the current profile.

---

## Reading the results

| Line | Meaning | What to do |
|---|---|---|
| `pass` | Core completed the profile with all results verified correct | Nothing — stable at that operating point |
| `FAIL — wrong result` | Core silently miscalculated (a true undervolt error) | Raise that core's CO offset (less negative) |
| `FAIL — hang / soft-lock` | Worker stopped responding | Raise offset — too aggressive |
| `unstable from the start (REFFAIL…)` | Core couldn't even compute a stable reference | Badly unstable — raise offset significantly |
| `+N WHEA hardware error(s)` | Correctable/uncorrectable errors logged during that core | Concerning even if calc passed — raise offset |
| `peak ~X.XX GHz` | **Informational** boost-clock estimate | **Not** a stability signal (see below) |

**The pass/FAIL/WHEA columns are the verdict. The peak-clock column is not.**
Peak-GHz differences between cores mostly reflect silicon quality, which CCD a core
is on (the V-Cache die clocks lower than the frequency die), and AMD's preferred-core
(CPPC) ranking. A core that *passes* at a slightly lower clock is stable — it's just
boosting lower. The TRANSIENT profile in particular reports lower, noisier peaks by
design (it's toggling load), so don't read per-core stability into that number.

If **one specific core** throws a FAIL or WHEA while others stay clean, that's your
per-core signal: raise just that core's offset (per-core Curve Optimizer). On X3D the
**V-Cache CCD (often cores 0–7)** typically tolerates the least undervolt.

### Output files (written next to the script)

- `undervolt_test_log.txt` — append-only run log; the core under test is flushed
  *before* it starts, so after a hard lock/BSOD the last `begin core N` line names
  the culprit. On the next launch the tool reads this and flags a prior crash.
- `undervolt_results_<timestamp>.csv` — per-core summary (pass/fail/whea/peak) for
  sharing or comparing runs.

---

## Recommended workflow

1. Run `-Preset Standard` (or the menu → **All three**) for a first pass.
2. If a core fails, raise **just that core's** CO offset (e.g. −20 → −15 → −10) and
   retest it: `-Cores <n> -Preset Thorough`.
3. Once nothing fails a `Thorough` pass, confirm with `-Preset Overnight`.
4. Re-validate after any BIOS/AGESA update — silicon behaviour can shift.

Undervolt errors are **intermittent**, so more time and more cycles = more
confidence. "No failures yet" partly means "it hasn't crashed yet," which is exactly
what you want to keep seeing.

---

## Safety

- **User-space only.** The tool runs floating-point math on pinned cores and reads
  performance counters and the event log. It does **not** change voltage, frequency,
  Curve Optimizer, power limits (PPT/TDC/EDC), or any BIOS/registry setting. All of
  the CPU's own protections — thermal throttling, current/power limits, boost
  algorithm — stay fully active.
- **Thermal common sense applies.** The HEAVY and TRANSIENT profiles draw real power
  and make heat. On X3D the cache die runs a hard ~89 °C limit; the chip will
  throttle to protect itself, but make sure your cooler is properly mounted before a
  long run. If temps are fine in Cinebench, they're fine here.
- **Crashes are the point.** A genuinely bad undervolt may **freeze, reboot, or
  BSOD** mid-test — that's the test working, not the tool causing harm. Save your
  work and close anything important first. The log names the last core tested.
- The TRANSIENT profile briefly requests **1 ms system timer resolution**
  (`timeBeginPeriod`) and restores it on exit — a normal, reversible Windows call.

---

## Optional convenience scripts

Included for adding a right-click launcher (not required to use the tester):

- **`Install-RunInPwsh7.ps1`** — adds a per-user "Run in PowerShell 7" entry to the
  `.ps1` right-click menu (registers under `SystemFileAssociations\.ps1`, so it works
  regardless of your default `.ps1` app — Notepad++ etc. stay your editor).
  Uninstall with `-Uninstall`.
- **`Enable-ClassicContextMenu.ps1`** — Windows 11: restores the full classic
  right-click menu so custom entries show at the top level instead of under "Show
  more options." Reversible with `-Revert`.

---

## Known limitations

- **Software load-stepping floor.** The TRANSIENT toggle is limited to roughly
  1–15 ms windows (~65–1000 Hz) by the OS timer, even with 1 ms resolution requested.
  It won't reach the microsecond-scale steps a hardware transient tester or a
  scope-triggered VRM test can, but it's far more aggressive than any steady-state
  tool and hits the mid-frequency bulk-cap / rail response where many marginal
  offsets die.
- **Boost-clock estimate is English-locale only.** It reads the `% Processor
  Performance` counter by its English name; on other Windows display languages the
  live clock readout silently disables (everything else still works). It's an
  estimate (base × performance %), not precise telemetry.
- **CPU temperature/voltage are not read.** That needs a kernel driver
  (LibreHardwareMonitor, HWiNFO, etc.), which is out of scope for a pure PowerShell
  tool. Monitor temps with your usual utility alongside it.
- **Single processor group assumed.** Fine for any desktop Ryzen incl. the 9950X3D
  (32 logical processors, one group). CPUs with 64+ threads (big Threadripper/EPYC)
  spanning multiple groups are not addressed.

---

## Files in this suite

| File | Purpose |
|---|---|
| `Test-UndervoltStability.ps1` | The tester (main program) |
| `UndervoltTests-Menu.bat` | Menu launcher |
| `Run-Boost.bat` / `Run-Transient.bat` / `Run-Heavy.bat` | Single-profile launchers |
| `Install-RunInPwsh7.ps1` | Adds the "Run in PowerShell 7" right-click entry |
| `Enable-ClassicContextMenu.ps1` | Windows 11 classic context menu toggle |

---

## Disclaimer

Provided as-is, without warranty of any kind. Stress testing pushes hardware hard by
design and an unstable system may crash or lose unsaved work. You are responsible for
your own cooling, settings, and data. Use at your own risk.
