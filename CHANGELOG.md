# Changelog

All notable changes to **X3D Undervolt CO Killer** (`Test-UndervoltStability.ps1`).

---

## [v4] — Interactive menu & failure memory

The testing engine is **unchanged** from v3 — same kernels, same profiles, same
verification logic, same results. Everything in this release is about *driving*
the tool: selecting cores without fighting the command line, and having it
remember what failed last time.

### Added

- **Interactive menu.** Launch the script with no arguments and pick everything
  by number:
  - **Cores** — All / previously-failed / type your own / CCD 0 / CCD 1
  - **Test type** — All, Boost, Transient, Heavy, Mid
  - **Duration** — Quick, Standard, Thorough, Overnight, Extreme, or custom seconds
  - **Advanced** — transient period sweep, heavy threads per core, shuffle,
    stop-on-first-error, include AVX2 MID profile, cycle count
  - Live **estimated run time and ETA** recalculated as you change selections.

- **Failure memory / suggested retest.** On launch the tool reads the most recent
  `undervolt_results_*.csv` and `undervolt_test_log.txt` from the script folder. If
  any core failed, it opens with a suggestion screen:
  - Lists the failed cores **and which profile(s) they failed**, parsed from the log.
  - Pre-fills a recommended retest: those cores, that profile, `Thorough` length,
    with the transient sweep enabled.
  - **`Y`** starts it immediately; **`N`** opens the main menu with those cores and
    that test type **already pre-selected**.
  - Reminds you to raise the Curve Optimizer offset in BIOS before retesting.

- **Hard-lock (BSOD) suspect detection in the menu.** If a previous run logged
  `begin core N` but never recorded a result — i.e. the machine froze or blue
  screened — that core is surfaced on the suggestion screen and folded into the
  recommended retest. (v3 printed a similar notice, but it was informational only
  and could not act on it.)

- **CCD quick-select.** On CPUs with 12+ cores the core menu offers CCD 0 and
  CCD 1 as one-key selections (first half / second half), which on the 9950X3D maps
  to the V-Cache die (0–7) and the frequency die (8–15).

- **`-NoMenu` switch** to force the non-interactive path explicitly.

- **Cores are recorded in the run log.** The `=== RUN START ===` line now includes
  the exact core list tested, so a log can be interpreted without the console
  scrollback.

### Fixed

- **`-Cores 6,15` failing with "No valid cores."** Passing an integer array through
  `pwsh -File` hands arguments over as plain strings, so `6,15` could arrive as one
  unparsed string and bind to nothing. The menu removes the need to pass it at all,
  and the typed-core input now accepts **commas, spaces, or both** (`6,15`,
  `6, 15`, `6 15  3` all parse correctly), ignoring anything out of range.

- **Core count in the banner.** It now reports `testing N of M` with the actual
  selected core list, instead of implying a full-CPU run when a subset was chosen.

### Changed

- Duration presets are applied through the menu selection rather than only the
  `-Preset` parameter; `Thorough`, `Overnight`, and `Extreme` still enable shuffle
  automatically, and `Extreme` still enables MID + sweep + 2-thread heavy.
- Explicitly passing any of `-Cores`, `-Mode`, `-Preset`, or `-SecondsPerCore`
  skips the menu entirely, so existing scripted runs and the `.bat` launchers
  behave exactly as they did in v3.

### Unchanged (compatibility)

- All v3 command-line parameters still work identically.
- `Run-Boost.bat`, `Run-Transient.bat`, `Run-Heavy.bat`, and
  `UndervoltTests-Menu.bat` continue to work without modification.
- Log and CSV formats are unchanged, so v3 result files are readable by v4 — which
  is what allows v4 to suggest retests based on a run performed under v3.

### Upgrade notes

Replace `Test-UndervoltStability.ps1` in place; keep the existing
`undervolt_test_log.txt` and `undervolt_results_*.csv` in the same folder so v4 can
read your history. Verify the upgrade took by checking the banner — it should read
**`X3D Undervolt CO Killer  (v4)`**. If it still says `(v3)`, an old copy is being
launched from a different folder.

---

## [v3] — Multi-profile V/F curve coverage

### Added

- **Three stress profiles per core**, replacing v2's single Heavy/Light split,
  because Curve Optimizer instability is operating-point specific:
  - **BOOST** — scalar, 1 thread: highest frequency at lowest voltage (the
    "crashes while browsing" corner).
  - **TRANSIENT** — heavy load toggled on/off every few ms across both SMT
    threads: **di/dt** voltage swings the VRM cannot track.
  - **HEAVY** — sustained widest-vector load: the droop-under-current corner.
  - Optional **MID** (AVX2) profile via `-IncludeMid`.
- **Transient period sweep** (`-TransientSweep`) walking the toggle period across
  roughly 2–17 ms to hit a range of VRM response frequencies.
- **Explicit AVX-512 kernel** using `Vector512` / `Avx512F` intrinsics, selected
  automatically when the CPU and runtime support it, falling back to AVX2
  (`Vector<T>`) and then a portable scalar kernel.
- **`-NoAvx512`** to force the narrower kernels (useful for the boost/light corner,
  where AVX-512's clock penalty works against the test).
- **`Extreme` preset** — all profiles + MID + sweep + 2-thread heavy, 3 cycles.
- 1 ms system timer resolution requested during transient runs (restored on exit)
  for tighter load-step timing.

### Changed

- **Verification is now self-referencing per core.** Each worker derives its own
  reference hash on the core under test instead of comparing against a hash
  computed by the orchestrator. This is what allows different profiles to use
  different instruction sets without false mismatches — and a three-way
  disagreement while establishing the reference is itself reported as immediate
  instability (`REFFAIL`).
- Reworked AVX-512 enablement: v3's earlier approach relied on the
  `DOTNET_PreferredVectorBitWidth` environment variable and a self-relaunch, which
  was fragile and could produce hash mismatches between parent and worker
  processes. Explicit intrinsics removed that entire failure mode.

### Fixed

- Worker exit codes read reliably via `System.Diagnostics.Process` (the previous
  `Start-Process` approach could return `$null` and mark passing cores as failed).
- `$args` no longer shadowed (it is a PowerShell automatic variable).
- Fast hang detection: a dead heartbeat for 45 s is treated as a soft-lock instead
  of waiting out the full grace window.
- Add-Type no longer fails on Windows PowerShell 5.1 (SIMD assembly reference).
- Single-core `-Shuffle` no longer breaks on a scalar return value.

---

## [v2] — Light-load mode and hardening

### Added

- **Light/burst mode** — short work bursts with idle gaps so a core repeatedly
  drops to idle and re-boosts to its top bin.
- Live **boost-clock estimate** per core, plus peak clock in the summary.
- **Crash forensics** — the core under test is flushed to the log *before* it runs,
  so a hard lock still names the guilty core on the next launch.
- Presets (`Quick`/`Standard`/`Thorough`/`Overnight`), **keep-awake**,
  press-**Q**-to-stop, **CSV report** export, and `-StopOnError`.

---

## [v1] — Initial release

- Per-core affinity pinning via child processes.
- Deterministic compute blocks verified against a known-good hash, so a single
  wrong bit is caught as an error rather than waiting for a bugcheck.
- WHEA hardware-error capture per core.
- Live per-core countdown and total time remaining.
