# X3D Undervolt CO Killer

Find the Curve Optimizer offset that *looks* fine until Windows freezes mid-browse.

This is a **single-core stress + correctness check** for AMD Ryzen undervolts — especially X3D chips (9950X3D, 9800X3D, 7950X3D, 7800X3D, …). It pins one physical core at a time, runs deterministic math, and **checks the answer**, so a flipped bit shows up as a failure before you get a blue screen. It works on any x86 CPU; the profiles are just tuned with X3D’s V/F quirks in mind.

> **It only reveals an unstable undervolt you already set in BIOS.** It never changes voltage, frequency, Curve Optimizer, power limits, or any firmware/registry setting. See [Safety](#safety).

---

## Why other tools miss it

A core can survive hours of heavy AVX-512 and still reboot while idle, because those loads sit at different points on the voltage/frequency curve. Each core is exercised with three profiles:

| Profile | Load | What it targets |
|---|---|---|
| **BOOST** | scalar, 1 thread | Highest frequency / **lowest voltage** — the “crashes while browsing” corner. Often the easiest place to expose an aggressive offset. |
| **TRANSIENT** | heavy (AVX-512), both SMT threads, toggled every few ms | **di/dt** swings the VRM struggles to track — a corner almost no steady-state tool hits on purpose. |
| **HEAVY** | sustained AVX-512, max current | The **droop-under-load** corner. |

Every profile verifies its own results (self-referencing per core), watches for **WHEA** hardware errors, and flushes “core under test” to the log *before* the run — so after a hard lock, the next launch still names the suspect.

---

## Requirements

- **Windows 10 or 11**
- **PowerShell 7.4+** (`pwsh.exe`) for AVX-512. Windows PowerShell 5.1 falls back to AVX2/scalar automatically — usable, but you want 7.4+.  
  Install: `winget install --id Microsoft.PowerShell --source winget`
- **AVX-512 CPU** for the 512-bit path (all Zen 4 / Zen 5, including every X3D). Without it, AVX2/scalar still work.
- **No admin required.** Affinity, priority, WHEA reads, and performance counters work as a normal user.

Confirm:

```powershell
pwsh -NoProfile -Command '$PSVersionTable.PSVersion; [System.Runtime.Intrinsics.X86.Avx512F]::IsSupported'
```

You want version **≥ 7.4** and **`True`**.

---

## Quick start

1. Download / copy `Test-UndervoltStability.ps1` (and the `.bat` launchers if you want them) into one folder.
2. Prefer **`pwsh`, not `powershell`**:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-UndervoltStability.ps1
```

With **no arguments**, v4 opens an **interactive menu**: pick cores, test type, duration, and advanced options. If a previous run left failures (or an unfinished “begin core N” after a lock), it offers a one-key suggested retest first.

The run banner should say `X3D Undervolt CO Killer  (v4)` and list kernels like `avx512, scalar, simd`. If you only see AVX2, update PowerShell.

### One-click batch launchers

Same folder as the script; double-click:

| File | What it does |
|---|---|
| `UndervoltTests-Menu.bat` | Simple profile picker: Boost / Transient / Heavy / All / Extreme |
| `Run-Boost.bat` | BOOST only (extra args pass through) |
| `Run-Transient.bat` | TRANSIENT only |
| `Run-Heavy.bat` | HEAVY only |

The `.bat` menu is a **shortcut to a profile** (it passes `-Mode` / `-Preset` and skips the PowerShell menu). For failure memory, CCD quick-select, and live ETA, launch the `.ps1` with no arguments instead.

Examples:

```powershell
Run-Heavy.bat -Preset Thorough -Shuffle
```

---

## Usage (command line)

Passing `-Cores`, `-Mode`, `-Preset`, or `-SecondsPerCore` skips the interactive menu (so scripts and the `.bat` files behave like v3). Use `-NoMenu` to force the non-interactive path even with no other args.

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
| `-Mode` | `All` | `All`, `Boost`, `Mid`, `Heavy`, or `Transient` |
| `-SecondsPerCore <int>` | preset | Seconds **per profile** per core (`All` = 3 profiles per core) |
| `-Cycles <int>` | preset | Full passes over all selected cores |
| `-Cores <int[]>` | all | Physical core indices, e.g. `-Cores 3,11` |
| `-Shuffle` | off | Randomize core order each cycle |
| `-ThreadsPerCore <1\|2>` | 1 | Threads for the HEAVY profile |
| `-IncludeMid` | off | Add AVX2 mid-curve profile |
| `-TransientOnMs` / `-TransientOffMs` | 3 / 3 | di/dt on / off windows (ms) |
| `-TransientSweep` | off | Sweep toggle period (~2–17 ms) |
| `-StopOnError` | off | Halt on first failure |
| `-NoAvx512` | off | Force AVX2/scalar |
| `-NoClocks` | off | Disable live boost-clock estimate |
| `-NoMenu` | off | Skip interactive menu |
| `-LogPath` / `-ReportPath` | script folder | Override output paths |

### Examples

```powershell
# di/dt killer, longer, with period sweep
pwsh -File .\Test-UndervoltStability.ps1 -Mode Transient -TransientSweep -SecondsPerCore 600

# retest only cores that failed earlier
pwsh -File .\Test-UndervoltStability.ps1 -Cores 3,11 -Preset Thorough

# max-boost / idle-crash corner
pwsh -File .\Test-UndervoltStability.ps1 -Mode Boost -SecondsPerCore 900
```

While running, press **Q** to stop cleanly after the current profile.

---

## Reading the results

| Line | Meaning | What to do |
|---|---|---|
| `pass` | Core finished; results verified | Stable at that operating point |
| `FAIL — wrong result` | Silent miscalc (true undervolt error) | Raise that core’s CO offset (less negative) |
| `FAIL — hang / soft-lock` | Worker stopped responding | Raise offset |
| `unstable from the start (REFFAIL…)` | Couldn’t even compute a stable reference | Badly unstable — raise offset significantly |
| `+N WHEA hardware error(s)` | Hardware errors during that core | Concerning even if calc passed — raise offset |
| `peak ~X.XX GHz` | Informational boost estimate | **Not** a stability signal |

**Pass / FAIL / WHEA are the verdict. Peak clock is not.** Peak-GHz differences mostly reflect silicon quality, which CCD a core sits on (V-Cache clocks lower), and CPPC preferred-core ranking. TRANSIENT peaks look lower and noisier by design (load is toggling).

If **one core** fails while others stay clean, raise **just that core’s** per-core Curve Optimizer offset. On dual-CCD X3D parts the **V-Cache CCD (often cores 0–7)** usually tolerates the least undervolt.

### Output files (next to the script)

- `undervolt_test_log.txt` — append-only run log; “begin core N” is flushed before work starts. After a BSOD/lock, the next launch can flag that core. **Local runtime file — do not commit.**
- `undervolt_results_<timestamp>.csv` — per-core summary for comparing runs. Also local; v4 reads the newest CSV to suggest retests.

---

## Recommended workflow

1. Run with no args (menu → **All** / Standard) or `-Preset Standard` for a first pass.
2. If a core fails, raise **just that core’s** CO offset (e.g. −20 → −15 → −10) and retest: `-Cores <n> -Preset Thorough` (or accept the suggested retest on next launch).
3. When nothing fails a `Thorough` pass, confirm with `-Preset Overnight`.
4. Re-validate after any BIOS/AGESA update.

Undervolt errors are intermittent. More time and more cycles = more confidence. “No failures yet” partly means “it hasn’t crashed yet” — which is exactly what you want to keep seeing.

---

## Safety

- **User-space only.** Floating-point work on pinned cores, performance counters, and the event log. No voltage/frequency/CO/PPT/TDC/EDC or BIOS/registry changes. CPU protections stay active.
- **Heat is real.** HEAVY and TRANSIENT draw power. X3D cache dies sit near a hard ~89 °C limit and will throttle; make sure cooling is solid before a long run.
- **Crashes are the point.** A bad undervolt may freeze, reboot, or BSOD mid-test. Save work first. The log names the last core tested.
- TRANSIENT briefly requests **1 ms** timer resolution (`timeBeginPeriod`) and restores it on exit.

---

## Known limitations

- **Software load-step floor.** TRANSIENT toggles are roughly 1–15 ms (~65–1000 Hz) even with 1 ms resolution — not microsecond hardware steps, but much more aggressive than steady-state tools.
- **Boost-clock estimate is English-locale only.** It reads `% Processor Performance` by English name; other display languages silently disable the readout (everything else still works). Estimate = base × performance %, not precise telemetry.
- **No temp/voltage sensors.** That needs a kernel driver (HWiNFO, etc.). Monitor temps with your usual tool alongside.
- **Single processor group.** Fine for desktop Ryzen including 9950X3D (32 logicals, one group). 64+ thread Threadripper/EPYC spanning groups are not addressed.
- **CCD menu split** is “first half / second half” of physical cores when there are 12+. That matches dual-CCD 16-core X3D (0–7 / 8–15); it is a convenience heuristic, not a topology probe.

---

## Files in this repository

| File | Purpose |
|---|---|
| `Test-UndervoltStability.ps1` | Tester (v4: interactive menu + failure memory) |
| `UndervoltTests-Menu.bat` | Simple profile menu launcher |
| `Run-Boost.bat` / `Run-Transient.bat` / `Run-Heavy.bat` | Single-profile launchers |
| `CHANGELOG.md` | Version history |

Runtime artifacts created next to the script (gitignored if you use the recommended `.gitignore`): `undervolt_test_log.txt`, `undervolt_results_*.csv`.

---

## Disclaimer

Provided as-is, without warranty of any kind. Stress testing pushes hardware hard by design; an unstable system may crash or lose unsaved work. You are responsible for your cooling, settings, and data. Use at your own risk.
