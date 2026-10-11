# `analysis/` — asking a question and extracting a number

Static checks over a netlist, simulation-backed analyses, and the adapters
that turn them into contract evaluators. Imports `netlist`, `spice`, `si`,
`contract` (adapters only), `pcb`/`ibis` (SI only).

## Layout

```
analysis.nim            hub: issue, io_check, measure, report — no toolchain
analysis/report.nim     Measurement, AnalysisReport
analysis/io_check.nim   static structural checks (Issue-returning)
analysis/measure.nim    re-export of verax/waveform
analysis/analyses/*     one file per analysis; returns AnalysisReport; knows nothing of contracts
analysis/evaluators/*   one adapter per analysis (same basename); registers an Evaluator
analysis/evaluators/contract_eval.nim   imports and registers them all at module init
```

## Data structures

| type | shape | notes |
|---|---|---|
| `Measurement` | name (open string), value, unit string, `at` (what it's about if not the subject), attrs | the name is the contract `quantity` |
| `AnalysisReport` | name, `measurements: seq`, `issues`, `raw: SimResult`, `assumptions` | the full curve rides along; never reaches `Readiness` |
| `*Spec` (`PdnSpec`, `PsrrSpec`, `TransientSpec`, `LoadStepSpec`, …) | flat value objects with a `default*Spec()` constructor | mix *setup* (sweep range, hops, model defaults) and *limits* (`targetZ`, `minPhaseMargin`) |
| `OperatingPoint` | node → volts (+ branch currents) | cached per run in `EvalContext.scratch` via a `RootObj` wrapper |
| `Issue` | re-exported from `netlist/issue` | |

## Patterns

**Three layers per question.** Pure curve math (`waveform`) → an analysis
that builds the derived netlist, runs it, and measures (`analyses/pdn`) → an
adapter that maps assertions to a spec, calls the analysis once per batch,
and harvests (`evaluators/pdn`). Analyses are usable without contracts
(`examples/pdn_sweep.nim` does).

**Clone-transform-simulate chain** (README P6), assembled by hand in each
analysis with documented ordering rules: flatten before model passes,
pin-model expansion before isolation, parasitics and source impedance after.
Some analyses deliberately don't isolate (`dcsweep`, `transient`, `psrr`,
`derating`, `dc_voltage`), because terminating a rail at its nominal would
measure the assumption.

**Measurement-only mode.** Specs carry their own limits (historical: analyses
predate contracts). Adapters disable them with sentinel values (`Inf`,
`-Inf`, `0` depending on field) so the assertion is the only authority.

**NaN for "not found", records for "invented".** An analysis never raises on
a missing feature; it reports NaN plus an `Issue` explaining why, and every
stand-in value as an `Assumption`.

**Run-scoped shared operating point.** `sharedOperatingPoint(ctx)` solves one
`.op` per `EvalContext` and caches it in `scratch`. `.ac`/`.tran` analyses
derate Class 2 ceramics from it. This is a straight line rather than a fixed
point because DC bias does not depend on capacitance.

**Refusal as a first-class outcome.** `checkInjectionPoint` refuses to drive
a node inside a feedback loop; `analyzeLoopGain` validates its own break;
`analyzePsrr*` refuses an output at the noise floor; `analyzeCurrent` refuses
three-terminal devices. Each returns a named `Issue` and NaN rather than a
number that would pass.

## What this buys

- **Analyses stay reusable outside the contract layer**, and the contract
  layer stays simulator-free — the adapter directory is the only place the
  two meet.
- **Most of the reasoning is in pure, testable code.** `waveform` has no I/O;
  analyses' numeric judgements (band edges, settling, THD windows) are
  testable without ngspice.
- **One mechanism for "this number rests on something nobody said".** The
  `assumptions` list is per report, so the renderer can show assumptions
  under the run they affected.
- **The failure catalogue is encoded.** Every refusal corresponds to a
  measured wrong answer documented in `RESOLVED_FINDINGS.md`; the code is
  shaped by evidence rather than by anticipated generality.

## Critique

1. **Confirmed bug: `spice.psrr_ac` setup key omits `at_f`.**
   `psrrAcKey` (`evaluators/psrr.nim:61`) keys on source/input/output and
   `f_from`/`f_to`; `runPsrrAc` builds the spec from `batch[0]`, including
   `spec.atF = conditionFloat(batch[0], "at_f", 0)`, and `analyzePsrrAc` only
   emits `psrr_at_f` when `spec.atF > 0`. So:
   - two `psrr_at_f` claims on one rail at different `at_f` share one run and
     both are answered at the first claim's frequency;
   - a `psrr_min_db` claim and a `psrr_at_f` claim on the same rail and band
     share one run; if the `psrr_min_db` claim is `batch[0]`, `atF = 0` and
     the `psrr_at_f` claim gets "analysis produced no 'psrr_at_f'".
   `opamp.nim` and `match.nim` include `at_f` in their keys for exactly this
   reason (`opamp.nim:30` says so). Found by reading, not by running a design.
   **Fixed 2026-10-10:** `at_f` joins the key; `tests/test_contract_eval_spice.nim` pins three claims to three runs (and fails without the fix).

2. **The key/run agreement is the structural weakness behind (1).** Every
   adapter hand-writes a `setupKey` that concatenates `$conditionFloat(...)`
   for the conditions it thinks matter, and a `run` that reads conditions
   from `batch[0]`. Nothing ties the two lists together. The fix pattern that
   would remove the class — derive the key from the same spec-builder the run
   uses (`$psrrSpecOf(a)`) — is available in every adapter, since each
   already has a `*SpecOf(a)` proc.
   **Fixed 2026-10-10 (R1/R5):** every adapter keys on `topology & specKey(xSpecOf(a))`, the same spec its run uses; evaluators declare the conditions they read, and `tests/test_contract_eval_keys.nim` fails if any declared condition doesn't change the key. Two latent omissions surfaced: the op-amp and start-up keys ignored the `output` binding the run reads.

3. **Specs conflate setup and limits.** Disabling a limit needs a
   field-specific sentinel (`Inf` for `targetZ`, `-Inf` for
   `minPhaseMargin`, `0` for `currentLimit`); `analysis/CLAUDE.md` lists them
   because getting one wrong makes an analysis emit a limit-violation issue
   the assertion never stated. Separating `*Setup` from `*Limits` (with
   `Option` limits) would make measurement-only mode the default.

4. **Each analysis re-assembles the transform chain.** `pdn`, `startup`,
   `opamp` each call `materialize → flatten → expandPinModels → isolate →
   parasitics → source impedance → probe` in their own code, with their own
   flags (`modelUnmodelledParts`, `modelSources`, `flattenHierarchy`,
   `keepInstances`). The order rules are shared; the code isn't. A shared
   "prepare fragment" builder parameterised by those flags would leave one
   place to get the order right.

5. **`Measurement` lookup is by name in a `seq`**, and per-part analyses
   (`analyzeCurrent`) emit several measurements with the same name
   distinguished by `at`. `harvest` takes the first match by name, so any
   adapter for a multi-subject analysis must not use it (the current adapter
   has its own `harvestPart`). The convention is safe but easy to violate for
   a new adapter.

6. **Units are strings on both sides** (`Measurement.unit`,
   `Assertion.unit`). An analysis can emit `"ohm"` and a claim say `"Ω"`, and
   `verdict` declares a unit mismatch; an analysis that forgets a unit makes
   every claim against it unit-unchecked.
   **Fixed 2026-10-10 (R1/R5):** `Evaluator.units` declares each quantity's unit; `plan` refuses a mismatched claim before running, `verdict` refuses a measurement that contradicts the declaration, and every built-in declares every quantity (tested). Still strings, compared case-insensitively.

7. **Registration by import side effect.** `contract_eval` registers at
   module init; `registerSimulatedEvaluators` is exported so a cleared
   registry can be restored. Any program that wants a subset of evaluators
   has to clear and re-register.

8. **`analysis` depends on `contract`** (adapters), and `analyses/si.nim`
   depends on `pcb` + `ibis` + `si`. The hub keeps the expensive parts
   opt-in, but the submodule as a whole is the widest-fan-in point in the
   tree below `verify`.

## Things that look odd but are right

- `final_v` is produced by `spice.startup`, not `spice.transient`, because
  one quantity has one producer.
- `spice.current_path`'s setup key is the window *only* — one `.tran`
  answers every part's current; `Measurement.at` keeps parts apart.
- Two PSRR evaluators, not one with a mode: a `.tran` tone and an `.ac` sweep
  need different capabilities, and `needs` is one set per evaluator.
- `dropout_v` is NaN when regulation never broke: "no dropout found" and "the
  dropout is small" are opposite conclusions.
