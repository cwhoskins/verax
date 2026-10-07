# Package-root modules

`units.nim`, `eng.nim` and `waveform.nim` sit *below* every submodule (several need them, none may own them). `verify.nim` sits *above* every submodule (it needs `contract` and `analysis` together, and neither may depend on it). `cli.nim` is the binary.

## `units.nim`

Typed quantities (`Volts`/`Ohms`/`Farads`/…/`Fraction`, plus `Degrees`, `Decibels`, `Celsius`) with suffix constructors (`3.3.V`, `20.mohm`, `5.pct`) scaling to SI base units. It exists so `esr = 20.mohm` cannot be misread the way `"20m"` vs `"0.02"` can.

- **Deliberately not a dimensional-analysis system** — no unit arithmetic or derived units. Don't add them.
- `Decibels` stores the dB figure, not the ratio. Nim reads `dB` and `db` as one identifier.
- `Celsius` carries both absolute temperatures and differences (the key it's stated under distinguishes them), is rendered without SI prefixes, and has no kelvin constructor (`20.K` would be ambiguous between a rise and an absolute).
- `Fraction`'s unit string is `""` — see `claimLint` below.
- Disjoint from `pcb/units.nim` (board geometry, `Nm`/`Deg`).

## `eng.nim`

`eng(x, unit)` renders engineering notation for **presentation only**. A value written into a deck must go through `netlist/formats/spice.spiceValue` — SPICE reads `15.9M` as 15.9 *milli*.

## `waveform.nim`

Curve math over sampled axes (crossings, extrema, rise/settle, harmonics), moved down from `analysis/measure` so the SI engine (`si/`, below `analysis`) shares it. `analysis/measure` re-exports it; its rules are in `analysis/CLAUDE.md`.

## `verify.nim`

The runner: checks a `Design` and renders one *readiness report*.

- **It imports `analysis/evaluators/contract_eval` unconditionally.** Without it, a valid claim reports `no evaluator produces X` (false) instead of `requires capSpiceAc, which was not offered` (true and actionable). What is *offered* stays the caller's choice via `allowed`.
- **The report is rendered fresh, not composed** from `report`/`summary`/`explain*` — those each re-list assertions; ordering and de-duplication are the product. Section order: structure, CHECKS, failures, NOT CHECKED, MOVED, summary. `NOT CHECKED` is never collapsed — unchecked must not read as passed. Issues on failed/unchecked results print de-duplicated across the whole report; a passing result's issues are not printed.
- **`CHECKS` is one block per analysis run**, which is why `readiness` goes through `runPlan` (one `seq` per step) not `evaluate` (flattened). Each block shows `ran:` (`Evaluator.setupDoc`, falling back to the setup key; a raising `setupDoc` is caught), `assuming:` (folded by `foldAssumptions` on `(key, value, unit, detail)` — which is why `annotations.note(entity, detail)` exists: a designator baked into the sentence can't be folded), and the claims. `FAILED` and `NOT CHECKED` share `renderClaim`. Claims that reached no test are listed only under `NOT CHECKED`.
- **A `Readiness` never holds an `AnalysisReport`** — a test pins rendered size so curve data can't leak in.
- `--format=text|json|junit`. `renderJson` (`verax.readiness/1`) is hand-built; every float goes through `jnum` so `NaN`/`Inf` become `null`. `results[]` is authoritative and references `checks[]` by index. **Nothing else may write to stdout during `readiness`** or `--format=json | jq` breaks. JUnit maps not-evaluated/not-evaluable to `<skipped>` with the reason as message.
- Margins: `contract/evaluate.marginOf` computes, `verify.marginText` words it — don't re-derive `Expectation.bounds` arithmetic here.
- `--baseline=<path>` diffs against a prior JSON report; a missing/unparseable baseline is a usage error (`exitCompile`), never silently skipped. A unit change is reported as incomparable, never differenced.
- `didYouMean` ranks quantities by edit distance for an unknown quantity. `claimLint` flags a unitless claim against a quantity with a unit (e.g. `<= 5.pct` vs a measurement in percent is off by 100×) — a stopgap until `Evaluator` declares units.
- **Catalog** (`describeRoles`/`describeRole`/`describeQuantities`/`describeAnnotations`) returns strings because both the CLI and MCP server use them. Reachability is *computed* by `claimingRoles()` — expanding every role with all params stated, then each param alone, because a param can *redirect* a claim (`gain_stage.atF`). Role params are stated as the placeholder `"1"`: a string-valued mode parameter therefore selects no branch and hides claims (see `contract/CLAUDE.md`). An expander that raises yields nothing rather than breaking `verax roles`.
- With `$VERAX_KEEP_RUNS` set it calls `schematic/render.keepFullSchematic` (best-effort; the picture code lives in `schematic/`). `$VERAX_SCHEMATIC_LAYOUT`/`--schematic-layout` only accepts `constrained-layered` and never affects simulation.
- **`--board=<file>`** reads a KiCad board and hands it to `readiness(d, allowed, board)`, which stores it in the eval context's scratch (findings §18). **`--si-constraints`** (what `verax constraints` forwards) derives SI routing rules for every `si_net` and stops; `siCriteria` turns the role's claims into the criteria so one statement of intent drives both.
- `validateEnvironment`, `validatePackages`, `validateInterfaces`, `validatePinmux`, `validateBomDefaults` are wired into `readiness` as structural checks.

## `cli.nim`

Thin over the above. It locates verax's sources for `--path:` through validated candidates (`--path:`, `$VERAX_PATH`, walking up for `verax.nimble`, compile-time `currentSourcePath()`, `nimble path verax`, else none) — each checked for `verax/contract/dsl.nim` because nimble deletes the build dir, so a compiled-in path can dangle. It compiles and runs a design as **two processes, never `nim c -r`**, so "doesn't compile" (exit 5) stays distinct from "a claim failed".

## Trap: ideal sources in PDN isolation

`voltage_source` is conductive, so `isPassive` is true and PDN isolation *absorbs* a supply — and an ideal source is a dead short at AC, making every rail read 0 Ω and pass any target. `spice/models.expandSourceImpedance` prevents this; removing it silently restores an always-passing check.
