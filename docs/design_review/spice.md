# `spice/` — turning a netlist into something a simulator can solve

Simulation-only transforms (materialise, flatten, isolate, extract, probes,
boundary drives), device models that stand in for undescribed parts, the
ngspice backend, and the XSPICE code-model toolchain. Imports `netlist`
throughout, and — via `ngspice.nim` only — `schematic`.

## Data structures

| type | shape | notes |
|---|---|---|
| `SimVector` | **variant** on `SimDataKind`: `sdReal → values: seq[float]`, `sdComplex → cvalues: seq[Complex64]` | reading an `.ac` vector as real raises `SpiceSimError` (catchable), not a field defect |
| `SimResult` | plot name, `dataKind`, `vectors: OrderedTable` keyed by lowercased name | exactly one plot per run |
| `IsolationSpec` | name, `maxHops`, `stopKinds`, `railVoltages`, `groundNet`, `requireKnownRails`, `excludeRails`, `openPortLeak` | |
| `Isolated` | fragment `netlist` + `seeds`/`absorbed`/`dropped`/`railNets`/`openPorts` (designator/net names) + `assumptions` | what was *not* simulated is part of the result |
| `BehavioralModel` / `BehavioralResult` | `proc(nl, c, gnd): (handled, notes)` registered by kind, plus a `passesSignal` flag | `handled = false` means *leave the part alone* |
| `ParasiticDefaults`, `SourceDefaults`, `PinModelDefaults` | tables of typical values by package/kind | every use of a default yields an `Assumption` |
| purposes (`spOperating`, `spSmallSignal`, …) | open string constants | select among a part's `simModels` by *question*, not by analysis card |
| XSPICE `ModelSpec`/`PortSpec`/`ParamSpec`/`StateVarSpec` | plain data; **sequence position is the C index** | single source for `.ifs` and C accessors |
| `PortBinding` | `wire(n)`, `wire(p, n)`, `wire([...])`, `nullPort()` | validated against the spec before an `A` line is rendered |

## Patterns

**Simulation-only state stored on the design, applied to a clone.**
`Component.simModels` is inert data; `materializeSimNetlist` clones and
applies the model chosen for a purpose. The design is never mutated
(invariant 2).

**Mutating passes over a clone, in a documented order** (README P6). Each
model pass returns `seq[Assumption]`; each is idempotent-guarded with
attrs markers (`parasitics.expanded`).

**Most-specific-first substitution chain** in `expandPinModels`: a
`subNetlist` or `simReplace` wins → a registered behavioural model for the
kind → per-pin impedances as the last resort. Declining is explicit and
distinct from falling through.

**Boundary as result.** `isolate` grows a fragment through
`kinds.isPassive` parts, never through a rail (unless seeded) or an
unmodellable part, then terminates the cut (ground → `"0"`, rails → ideal
source at a *stated* voltage, open nets → 1 GΩ leak). `dropped` and
`openPorts` are returned, not logged.

**Data, not closures, across the `{.nimcall.}` boundary.**
`SimReplacement.build` must be `{.nimcall.}` (so a design stays plain
data); connector drives are therefore recorded as `boundary.*` pin attrs and
interpreted later.

**Process boundary with an explicit success criterion.** `ngspice.run`
writes a deck with a synthesised `.control` block, treats "parseable
rawfile exists" as success, then scans the log for convergence failures
that ngspice reports as warnings. One analysis per run; setup cards (`.ic`,
`.options`, …) are separated from the analysis card.

**XSPICE: one declarative spec, two generated artefacts.** `codeModel`
emits the `.ifs` and type-checked C accessors from one `ModelSpec`, so ports
and parameters cannot drift between them (as ngspice's two hand-maintained
files can). `-d:xspiceSpecOnly` lets a design import a model to instantiate it
without the source tree.

## What this buys

- **Every simulated number is traceable to what it rests on.** Because each
  pass returns assumptions and `Isolated` returns what it cut, the report can
  list the invented values under the run that used them.
- **A part can be asked different questions with different models** without
  the design choosing one up front (averaged vs switching regulator).
- **Unmodellable parts degrade honestly.** The behavioural registry plus the
  explicit "decline" result prevents the classic wrong answer (an LDO as two
  resistors reading 0 V).
- **`VERAX_KEEP_DECKS` / `--keep-runs`** make the derived circuit inspectable,
  which is the only way to debug a pipeline whose input is not what anyone
  wrote.
- **`SimVector` as a variant** makes the most common post-processing mistake
  (treating complex AC data as real) a catchable error.

## Critique

1. **`ngspice.nim` imports the whole `schematic` hub** to render per-run
   SVG/JSON into the archive. That makes every simulation-backed analysis link
   the ~9k-line layout engine, and adds an edge the top-level dependency
   order doesn't list. The archive writer is the natural owner of that call
   (it could be a hook `verify` installs, the same way `analysis` installs
   evaluators into `contract`).
   **Fixed 2026-10-10:** `ngspice.setRunPictureWriter` hook; `verax/run_archive` installs the schematic writer and `verify` imports it.

2. **Phase ordering is not in the types.** `flatten`, `expandPinModels`,
   `isolate`, `expandCapacitorParasitics`, `expandSourceImpedance` all take
   and return (or mutate) a `Netlist`. Running parasitics before isolation, or
   model passes before flatten, compiles and produces a plausible wrong
   number. `applySimReplacements` documents two further ordering limitations
   (exclude matching and bare-name lookups after flatten).

3. **Designator synthesis can collide.** `replaceComponent` derives
   `prefix & trailingDigits` (`U1 → V1`) and calls `addComponent`, which
   raises on a duplicate. A design with both `U1` (regulator, replaced by a
   source) and `V1` will fail at materialisation with a duplicate-designator
   error rather than choosing a free name. `isolate` has a
   `uniqueDesignator` helper; `transform` does not use one.

4. **Behavioural models are keyed by `Component.kind` strings with aliases
   listed inline** (`"regulator", "ldo", "vreg", "dcdc", …`). A design using
   `"linear_regulator"` silently falls through to per-pin impedances — with
   an assumption recorded, but the stand-in it gets is the one the module
   doc calls a confident wrong answer for regulators. There is no "known but
   unmodelled kind" warning distinct from "unknown kind".

5. **Mutation-heavy model passes plus "snapshot net names before
   `removeComponent`"** (`disconnect` nulls `Pin.net`) is a trap that has to
   be restated in `switch.nim` and in the netlist docs. A replace primitive
   that captures pin→net before removing would retire it.

6. **One analysis per `run` is a real constraint pushed upward.** It is
   ngspice's (`write` keeps one plot), handled correctly, but it means the
   shared operating point and the `.ac` it feeds are two processes, and the
   `.tran` after them a third.

7. **Raw ASCII rawfile parsing is format-fragile by necessity** — the
   `--save-currents` exclusion for `.ac` exists because a real token in a
   complex plot breaks the parser. That is handled, but it shows the parser
   is strict about a format ngspice does not formally specify.

8. **Model defaults live in code tables** (`defaultParasitics`,
   `defaultSourceImpedance`, per-package ESL). They are reported as
   assumptions every time, which is the right honesty, but there is no way to
   override a table for a project short of stating values per part.

## Things that look odd but are right

- `voltage_source` is "passive" to `isolate` (it is conductive), so
  isolation would absorb a supply and an ideal source would short the rail
  at AC — `expandSourceImpedance` is the fix and must not be removed.
- `flatten` lives in `spice/`, not `netlist/`: it destroys the hierarchy the
  designer wrote, so it is a simulation-only concession.
- The op-amp macromodel is emitted flat, not as an instance, because `isolate`
  does not traverse a `subNetlist`.
- Clamping only for large-signal callers: `min`/`max` has zero derivative at
  the limit, so a clamp would kill AC gain at a rail-biased stage.
