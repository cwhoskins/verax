# `si/` — a native signal-integrity engine

Simulates one net (IBIS driver → package → board interconnect → IBIS
receivers, plus optional victim, differential partner, Touchstone channel and
power-aware rails) on an in-tree transient engine, measures it, sweeps
corners/edges/patterns, and inverts the question to derive routing
constraints. Imports `ibis`, `pcb`, `netlist`, `touchstone`, `waveform`; **no
`spice` edge**, so SI runs without ngspice.

## Data structures

Three representations, lowered in sequence: `RouteTree`/`SiTemplate` →
`SiNet` → `mna.Circuit` → band-LU `System`.

| type | shape | notes |
|---|---|---|
| `SiNet` | node names (0 = ground), `elements: seq[SiElement]`, driver behaviour + port, receivers + ports, `extraDrivers` (with `DriveMode`), `conductorNames`, `diffReceivers`, `supply`, `unsupported: seq[string]`, assumptions, issues | the problem statement; `unsupported` non-empty means "cannot simulate, here is exactly why" |
| `SiElement` | **one flat struct** for every kind: `kind`, `a`/`b`, `value`, `z0`/`td`, `r/l/g/c/length`, `spec`/`hasSpec`/`fRef`, `a2`/`b2`, `zEven/zOdd/tdEven/tdOdd`, `sparams` | fields used depend on `kind` |
| `SiPort` | label (`"U1.7"`), die node, pin node, package RLC, conductor | |
| `SiTemplate` / `TemplateParams` | parametric pre-layout topologies (point-to-point, daisy chain, star; series R, vias, stub, termination; partner) with `build(params) → SiNet` | what `constrain` sweeps |
| `Stimulus` / `DriveWaves` | edge or bit pattern → `Ku`/`Kd` as `Pwl` | |
| `Pwl` | breakpoints; a jump is two points at one time, right-continuous | discontinuities are first-class |
| `mna.Circuit` | typed element seqs (`Res`, `Cap`, `Ind`, `VSrc`, `ISrc`, `Line`, `ConvLine`, `CoupledLine`, `SBlock`, `NlDevice`) | the solver's view |
| `NlDevice` | node, weighted curves, optional rail references and `Ksso` factors | IBIS buffers as PWL nonlinear current sources |
| `Layout` / `System` / `Pattern` / `BandLu` | unknown placement, dense `n×n` assembly, RCM ordering, band factorisation | |
| `SiResult` | `SiStatus` (ok/unsupported/solverFailed) + reason, time axis, per-port voltage/current waves | status first; a failed solve is never a waveform |
| `SiSweep` / `WorstCase` / `Probe` | per probe per figure, the worst value and the run that set it, every measured edge kept | |
| `Criteria` / `Sweep` / `Interval` / `ConstraintReport` | passing intervals of a swept parameter, with bisection only between valid samples | |

## Patterns

**Own problem representation instead of reusing `Netlist`.** An SI net needs
transmission lines, coupled modes, S-parameter blocks, IBIS ports with
package RLC and rail-referenced devices, none of which `Netlist` models
natively. `SiNet` is index-based data designed for the solver.

**Refuse with a reason at every layer.** `board.nim` refuses a route with no
return path, a reference change, a pour or a loop; `topology` refuses
`POWER`/`GND`/`NC` pins and unresolved model selectors; `simulate` returns
`ssUnsupported`/`ssSolverFailed` with time, node and step. These map onto
`esNotEvaluable`/`esNotEvaluated` without loss.

**One measurement path for checking and for deriving.** `analysis/analyses/si`
(the check) and `constrain.judge` (the inverse) both run `sweep.sweepNet`, so
a constraint and the claim it serves measure identically.

**Numerical policy centralised.** `engine/transient.nim`'s module doc owns
the integration choices (trapezoidal with Backward-Euler restarts only at
true discontinuities, line lumping threshold, step control); the rest of the
engine follows it.

**Performance by reuse, not by cleverness.** LU factors reused while the
linear matrix and every device's segment are unchanged; when no device
changes segment the first Newton solve is exact; per-step loops index rather
than iterate by value.

**Bisect only between valid samples.** An invalid grid point is a gap, never
a fail, so a constraint interval is never extended across a point the
engine could not evaluate.

## What this buys

- **SI without an external simulator**, which makes it part of the offline
  capability set and testable everywhere.
- **Pre-layout and post-layout from one engine.** Templates drive
  `verax constraints`; `board.nim` lowers a routed KiCad net onto the same
  `SiNet`.
- **Answers as intervals with provenance** (`AnswerIdentity`, assumptions),
  which is the right shape for a routing rule.
- **A solver whose failure modes are explicit**, which is what lets the
  contract layer distinguish "can't model this" from "tried and failed".

## Critique

1. **`SiElement` is a fat record, not a variant.** Every element carries
   every kind's fields; which are meaningful depends on `kind`. The rest of
   the codebase uses object variants for exactly this (`Curve`, `Shape`,
   `Aperture`, `Expectation`, `SimVector`), and `mna.Circuit` itself uses
   separate typed seqs. A misread field (`value` on a line) is silently zero
   rather than a field-access error.

2. **Three circuit representations in the tree** (`Netlist`, `SiNet`,
   `mna.Circuit`), plus `fem.FemProblem`. Each is justified, but `SiNet` and
   `Circuit` overlap heavily (both have R/L/C/V/line elements by index), with
   a lowering step between them; `SiNet` mostly adds ports, behaviours and
   provenance. The split is defensible as "problem vs. solver"; it does
   double the places a new element kind must be added.

3. **Dense assembly feeding a band solver.** `System.a` is a row-major
   `n×n` dense matrix that is cleared and re-stamped, then factored banded.
   For the net sizes in scope this is fine; assembly and `clear` are O(n²)
   per step while factorisation is O(n·bw²), so on long lossy-ladder nets the
   dense side will dominate before the solver does.

4. **Many `has*`/`present` flags** (`hasSpec`, `hasVdiff`, `hasViaStub`,
   `SiSupply.present`) — another local presence idiom (README P7), with a
   constructor (`templateParams`) needed so callers don't get `hasViaStub`
   wrong.
   **Partly fixed 2026-10-10 (R5):** `vdiff`/`hasVdiff` pairs and `SiSupply.present` are `Option`s (and `SsnSpec.supply` no longer uses NaN). `hasSpec`, `hasViaStub`, `hasTiming` remain.

5. **Crosstalk and differential extraction are pre-layout only.** By design
   and documented: the board path cannot extract coupled traces, so those
   claims are always not-evaluable on a real board. The data model
   (`sekCoupledLine`, conductors) is ready; `pcb/` has no coupled-geometry
   extraction to feed it.

6. **`constrain.nim` (700 lines) mixes search, criteria, tables, rules of
   thumb and two renderers.** The search algorithm and its reporting would be
   easier to reason about apart.

## Things that look odd but are right

- Backward-Euler restarts only at jumps, not at every `Ku`/`Kd` knot —
  restarting at slope-only knots would make a whole vendor edge first order.
- Never-settles is `+Inf` (fails a budget), not NaN; undefined-in-any-run is
  NaN, never "the worst of the runs that produced one".
- The LU pattern must include device↔rail entries, or the band LU silently
  drops them.
- `rlgc` is never fed to `ratfit` — it is not causal.
