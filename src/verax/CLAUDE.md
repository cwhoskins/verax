# Package-root modules

`units.nim`, `stated.nim`, `eng.nim`, `waveform.nim`, `plot.nim` and `touchstone/` sit *below* every submodule that uses them (several need them, none may own them). `verify.nim` sits *above* every submodule (it needs `contract` and `analysis` together, and neither may depend on it). `run_archive.nim` sits above `spice` and `schematic`. `cli.nim` is the binary.

## `touchstone/`

`SParams` (single reference `z0`, row-major complex matrices per frequency), a reader normalising the 2-port order, and dB conversions kept as **two named pairs** (voltage-ratio 20·log, power-ratio 10·log) — never one generic helper. Used by `pcb/tline` and `si`. Per-port reference impedances (Touchstone v2) are unsupported.

## `run_archive.nim`

Importing it installs `spice/ngspice`'s `RunPictureWriter` hook so `$VERAX_KEEP_RUNS` gets a `runNNN.svg`/`.json` of each derived netlist. It exists so `spice` never imports `schematic` (which would link the layout engine into every simulation). `verify` imports it; anything else that wants archive pictures must too — without it the deck/raw/log are still archived, only the picture is skipped.

## `units.nim`

Typed quantities (`Volts`/`Ohms`/`Farads`/…/`Fraction`, plus `Degrees`, `Decibels`, `Celsius`) with suffix constructors (`3.3.V`, `20.mohm`, `5.pct`) scaling to SI base units. It exists so `esr = 20.mohm` cannot be misread the way `"20m"` vs `"0.02"` can.

- **Deliberately not a dimensional-analysis system** — no unit arithmetic or derived units. Don't add them.
- `Decibels` stores the dB figure, not the ratio. Nim reads `dB` and `db` as one identifier.
- `Celsius` carries both absolute temperatures and differences (the key it's stated under distinguishes them), is rendered without SI prefixes, and has no kelvin constructor (`20.K` would be ambiguous between a rise and an absolute).
- `Fraction`'s unit string is `""` — see `claimLint` below.
- Disjoint from `pcb/units.nim` (board geometry, `Nm`/`Deg`).

## `stated.nim`

`Stated[T]{source: AnnSource, value}` — the one idiom for "not stated". `netlist`'s `AnnValue[T]` is this type. Rules: **`NaN` means only "measured, and the feature was not there"** (no anti-resonance, no dropout); zero is never "unknown" where zero is physical; plain presence with no provenance is `std/options.Option`, `Stated` is for a value whose origin a report shows (`fem.Material` constants, `bom.BomItem` ratings, `pcb` `copperWeight`/`finishedDia`/`height`). `has`, `get` (raises when absent), `get(fallback)`, `stated(v, source)`, `absent(T)`. Modules re-export it as `import ../stated as statedmod; export statedmod` — a bare `export stated` resolves to the proc, not the module. IBIS's per-corner `present` flags are deliberately kept (format-faithful).

## `eng.nim`

`eng(x, unit)` renders engineering notation for **presentation only**. A value written into a deck must go through `netlist/formats/spice.spiceValue` — SPICE reads `15.9M` as 15.9 *milli*.

## `waveform.nim`

Curve math over sampled axes (crossings, extrema, rise/settle, harmonics), moved down from `analysis/measure` so the SI engine (`si/`, below `analysis`) shares it. `analysis/measure` re-exports it; its rules are in `analysis/CLAUDE.md`.

## `plot.nim`

SVG line plots for reports, stdlib-only over `eng`: `Plot` (axes, `Series`, `Limit`s with an optional x band, `Marker`s, `VLine`s), `plotSvg`, `stackSvg` (panels sharing x; one legend; x labels at the bottom — a Bode plot). Colours are `var(--vx-s1..8, fallback)` in the dataviz reference order, so the embedding page themes them. Each panel carries `data-xmap`/`data-ymap` and each line `data-name` for a page-side crosshair. Tick labels get enough significant digits to stay distinct (`tickSig`); series are min/max-decimated to `maxPlotPoints`. Presentation only.

## `readiness.nim`

`Check`/`Readiness`, `readiness(d, allowed, board, onStep)`, `exitCode`/`exitLabel`, `claimLint`, `availableCapabilities`, and the wording helpers both renderers share (`capList`, `foldAssumptions`, `marginText`, `statusMark`, `statusJsonName`, `sevLabel`, `claimLabel`, `didYouMean`). Split out of `verify` so `report` can sit between them; `verify` re-exports it, so `import verax/verify` still sees all of it. `Check.step` is the plan-step index (checks with no visible result are dropped, so it is not the check's position). `onStep` goes into `EvalContext.onStep`.

## `report/` and `report.nim`

The simulation test report — see `report/CLAUDE.md`. `verify` imports it for `--report=`.

## `verify.nim`

The runner: checks a `Design` and renders one *readiness report*.

- **It imports `analysis/evaluators/contract_eval` unconditionally.** Without it, a valid claim reports `no evaluator produces X` (false) instead of `requires capSpiceAc, which was not offered` (true and actionable). What is *offered* stays the caller's choice via `allowed`.
- **The report is rendered fresh, not composed** from `report`/`summary`/`explain*` — those each re-list assertions; ordering and de-duplication are the product. Section order: structure, CHECKS, failures, NOT CHECKED, MOVED, summary. `NOT CHECKED` is never collapsed — unchecked must not read as passed. Issues on failed/unchecked results print de-duplicated across the whole report; a passing result's issues are not printed.
- **`CHECKS` is one block per analysis run**, which is why `readiness` goes through `runPlan` (one `seq` per step) not `evaluate` (flattened). Each block shows `ran:` (`Evaluator.setupDoc`, falling back to the setup key; a raising `setupDoc` is caught), `assuming:` (folded by `foldAssumptions` on `(key, value, unit, detail)` — which is why `annotations.note(entity, detail)` exists: a designator baked into the sentence can't be folded), and the claims. `FAILED` and `NOT CHECKED` share `renderClaim`. Claims that reached no test are listed only under `NOT CHECKED`.
- **A `Readiness` never holds an `AnalysisReport`** — a test pins rendered size so curve data can't leak in. The HTML report gets curves through the run observer instead (`report/collect`).
- `--report=<file>` runs `collectReport` in place of `readiness`, writes the report (its message to **stderr**, so `--format=json` stays parseable), and prints/returns exactly what it would have otherwise.
- `--format=text|json|junit`. `renderJson` (`verax.readiness/1`) is hand-built; every float goes through `jnum` so `NaN`/`Inf` become `null`. `results[]` is authoritative and references `checks[]` by index. **Nothing else may write to stdout during `readiness`** or `--format=json | jq` breaks. JUnit maps not-evaluated/not-evaluable to `<skipped>` with the reason as message.
- Margins: `contract/evaluate.marginOf` computes, `readiness.marginText` words it — don't re-derive `Expectation.bounds` arithmetic here.
- `--baseline=<path>` diffs against a prior JSON report; a missing/unparseable baseline is a usage error (`exitCompile`), never silently skipped. A unit change is reported as incomparable, never differenced.
- `didYouMean` ranks quantities by edit distance for an unknown quantity. `claimLint` flags a unitless claim against a quantity with a unit (e.g. `<= 5.pct` vs a measurement in percent is off by 100×), using the producer's declared `Evaluator.units` (so unrun claims are flagged too), else the measured unit. `verax quantities` shows each quantity's unit and the conditions it accepts.
- **Catalog** (`describeRoles`/`describeRole`/`describeQuantities`/`describeAnnotations`) returns strings so any front end (the CLI, the Python binding) can use them. Reachability is *computed* by `claimingRoles()` — expanding every role with all params stated, then each param alone, because a param can *redirect* a claim (`gain_stage.atF`). Role params are stated as the placeholder `"1"`: a string-valued mode parameter therefore selects no branch and hides claims (see `contract/CLAUDE.md`). An expander that raises yields nothing rather than breaking `verax roles`.
- With `$VERAX_KEEP_RUNS` set it calls `schematic/render.keepFullSchematic` (best-effort; the picture code lives in `schematic/`). `$VERAX_SCHEMATIC_LAYOUT`/`--schematic-layout` only accepts `constrained-layered` and never affects simulation.
- **`--board=<file>`** reads a KiCad board and hands it to `readiness(d, allowed, board)`, which stores it in the eval context's scratch (findings §18). **`--si-constraints`** (what `verax constraints` forwards) derives SI routing rules for every `si_net` and stops; `siCriteria` turns the role's claims into the criteria so one statement of intent drives both.
- `validateEnvironment`, `validatePackages`, `validateInterfaces`, `validatePinmux`, `validateBomDefaults` are wired into `readiness` as structural checks.

## `cli.nim`

Thin over the above. It locates verax's sources for `--path:` through validated candidates (`--path:`, `$VERAX_PATH`, walking up for `verax.nimble`, compile-time `currentSourcePath()`, `nimble path verax`, else none) — each checked for `verax/contract/dsl.nim` because nimble deletes the build dir, so a compiled-in path can dangle. It compiles and runs a design as **two processes, never `nim c -r`**, so "doesn't compile" (exit 5) stays distinct from "a claim failed".

## Trap: ideal sources in PDN isolation

`voltage_source` is conductive, so `isPassive` is true and PDN isolation *absorbs* a supply — and an ideal source is a dead short at AC, making every rail read 0 Ω and pass any target. `spice/models.expandSourceImpedance` prevents this; removing it silently restores an always-passing check.
