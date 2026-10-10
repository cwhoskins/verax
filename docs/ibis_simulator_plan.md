# IBIS signal-integrity simulator — plan and roadmap

Goal: simulate a net **as a signal-integrity problem**: an IBIS driver, its
package, the board interconnect, the receivers' packages and input models.
Report the waveform at each receiver die pad and the numbers a claim needs:
overshoot, undershoot, ringback, flight time, settle time and threshold
margin. Then judge a design's SI claims against those numbers, the same way
`spice.transient` judges a rail.

*Revised 2026-10-07 after review (`docs/ibis_plan_review.md`). What was
taken from the review and what was not is in the decisions log, entry 5.*

## Implementation status (2026-10-07)

Stages 0-8 are implemented and green (`nimble test`); stage 8's item 7
(IBIS-AMI) is deliberately not, and several stage 8 items stop at the
template (pre-layout) level -- see "Not done". Where the code lives and
what it proves:

| Stage | Where | Proven by |
| --- | --- | --- |
| 0 reader gaps + fixtures | `ibis/reader` (`[Model Spec]`, `[Receiver Thresholds]`, `V_fixture_min/max`), `tests/fixtures/ibis/synthetic.nim` | `test_ibis_modelspec` |
| 1 interpretation | `ibis/behave` | `test_ibis_behave` |
| 2 topology, stimulus, via | `si/topology`, `si/drive`, `pcb/via` | `test_si_topology` |
| 3a reference gate | `si/engine/*`, `si/simulate` | `test_si_engine` (rungs 1, 2, 6), `test_si_reference` (rungs 3, 4, the gate) |
| 3b widenings | multi-drop, vias, lossy ladder (rung 5 vs the exact line in the frequency domain), bit patterns, complete-data min/max | `test_si_widening` |
| 4 measures | `verax/waveform` (moved down from `analysis/measure`), `si/measure` | `test_waveform`, `test_si_measure` |
| 5 constraints | `si/constrain`, `pcb/formats/kicaddru`, `verax constraints` | `test_si_constrain`, `test_pcb_kicaddru` (`kicad-cli` DRC gate, KiCad 10.0.6) |
| 6 board + contract | `si/board`, `analysis/analyses/si`, `analysis/evaluators/si`, role `si_net`, `capSiTran`, `--board=` | `test_si_board`, `test_si_contract`, `designs/si_spi.nim` |
| 7 sweeps, performance, lossy accuracy | `si/sweep` (corner x stimulus x receiver, worst case; ISI patterns; `judge` and `analyzeSiNet` both on it), `si/engine/lu` (band LU over RCM, factor reuse), `si/engine/ratfit` + `si/engine/convline` (recursive convolution), `pcb/impedance.causalLine` | `test_si_sweep`, `test_si_convolution`, `examples/si_bench.nim` |
| 8.1 crosstalk | `pcb/impedance.coupledModes` (Kirschning-Jansen microstrip, Cohn stripline), `CoupledLine` (modal Bergeron), extra drivers + victim probes, template `partner`, `spacingFor` -> KiCad `clearance`, `si_net` victim parts | `test_si_coupled` (exact modal solution, Kb NEXT, microstrip FEXT, min spacing), `test_pcb_kicaddru` (clearance gate), `test_si_contract` |
| 8.2 differential pairs | `[Diff Pin]` `tdelay`, `diffPartner`, `prDiffPair` template (`diffR`, `legMismatch`), differential probe vs `Vdiff`, `deriveDiffConstraints` -> KiCad `skew`, `diff_pair` `driver`/`rx` | `test_si_diff`, `test_pcb_kicaddru` (skew gate), `test_si_contract` |
| 8.3 fixture networks | `ibis/behave.fixtureSeries` + `reconstructNetwork` (L_fixture, R/L/C_dut; probe point a stated choice) | `test_ibis_behave` (Ku/Kd back through a full RK4-generated network, convergence with table resolution) |
| 8.4 PRBS + eye | `si/eye` (PRBS7..31, `eyeOf`), eye figures in the sweep, criteria, `si_net` `min_eye_height`/`min_eye_width` (measured on a board) | `test_si_eye` (closed-form eye of a ramped NRZ wave, RC channel closing), `test_si_contract` |
| 8.5 S-parameter channels | `si/engine/sblock` (impulse response by IFFT, wave-form stamp, DC pi from `S(0)`), template `channel` | `test_si_sparams` (vs Bergeron matched and 75 ohm, vs the convolution line lossy, Touchstone round trip) |
| 8.6 power-aware | `[ISSO PU/PD]`, `[Composite Current]` read; `behave` Ksso + pre-driver current; rail-referenced `NlDevice`; `SiNet.supply`; `si/ssn` | `test_si_ssn` (series circuit on a lifted rail exactly, Ksso exactly, pre-driver extraction exact, bounce scaling with N and L) |

Benchmark (`examples/si_bench.nim`, `-d:release`, i7-13700H): one edge,
point-to-point 0.44 ms (0.74 ms at stage 3); three-drop daisy chain 1.11 ms
(2.35 ms); **3 corners x 3 receivers, both edges + ISI patterns, 10.9 ms**
(the stage 7 exit); a 0.3 m lossy line 1.67 ms by convolution vs 4.80 ms
as a ladder. `verax constraints designs/si_spi.nim` 0.31 s (0.66 s).

**Decided while implementing** (each is in the module doc that owns it):

- *Backward-Euler restart only at discontinuities* (`si/engine/transient`).
  Decision 2/stage 3 said "after each breakpoint"; every `Ku`/`Kd` knot is a
  breakpoint, and restarting at slope-only knots would make a whole vendor
  edge first order. Knots are landed on; only jumps restart.
- *Timing load at the die, without package* (`si/measure`): `Vref/Rref/Cref`
  are `[Model]`-level figures. Recorded as an `Assumption` on every result.
- *Reference change = a different reference plane layer*, even on the same
  net, and a section whose plane covers less than 90 % is refused
  (`si/board`). Conservative until stitching vias are modelled.
- *Package topology* die - R_pkg - L_pkg - pin, C_pkg at the pin: a verax
  convention (IBIS gives values, not topology), an `Assumption`.
- *min/max corners run only on complete data*; no substitution policy yet
  (open decision 2). Unsupported corners are named as `Assumption`s, typ
  always runs.
- *Ringback* is measured from the first peak after the far threshold, not
  from the crossing (the crossing sample would read as a zero margin).
- *Constraint criteria are exactly the `si_net` claims* (`verify.siCriteria`):
  no monotonicity or `[Model Spec]` overshoot criterion unless the role
  claims it. The KiCad rule pair is joint: the largest via count that passes
  with the shortest max length over 0..n vias.
- *`verax check` without a board* reports the SI claims as not evaluable,
  pointing at `--board=` and `verax constraints`; it does not print the
  constraint report itself.
- *`capSiTran` is in `offlineCapabilities`* (open decision 4, as recommended).
- *Tolerances* (open decision 3) start at: `Ku`/`Kd` range 0.1, residual 2 %
  of rail span / 2 % of the largest fixture current, conditioning 1e-3.

**Decided while implementing stage 7** (each in the module doc that owns it):

- *Profile first.* Dense LU was ~55 % of a constraint run; then
  `for k, x in seq` deep-copying every device's I/V tables per Newton
  iteration (`pairs` yields by value) was the next 20 %. Fixed: band LU
  over a reverse Cuthill-McKee ordering (one code path; a small net is
  dense at the same cost), the factor reused while the step and every
  device's conductance are unchanged (~5x fewer factorisations), indexed
  hot loops, and **no confirming Newton solve when no device changes table
  segment** (a PWL device is then exactly linear, so the solve is the
  answer; the KCL check still runs).
- *`impedance.rlgc` is not causal*, so it cannot be fitted by a stable
  rational function (fit error > 100 %): its `sqrt(f)` resistance has no
  internal reactance and a constant `tand` has no dispersion. The
  convolution line uses **`impedance.causalLine`**: skin effect
  `Rdc sqrt(1 + jw/w0)` (same DC and high-frequency asymptotes as `rlgc`,
  within 2 % at 1 GHz), dielectric a Djordjevic-Sarkar wideband Debye model
  equal to `rlgc`'s `G + jwC` at the reference frequency. Its delay is the
  dielectric's `eps_inf` asymptote.
- *Fixed real poles, not vector fitting*: log-spaced, 6 per decade, one
  decade beyond the sampled band each side; residues by least squares; DC
  imposed exactly so the operating point is the model's steady state.
  Errors on the rung-5 line: `Yc` < 1e-7, `H` < 1e-3 of peak. A fit worse
  than 1 % falls back to the ladder, warned.
- *Recursive convolution is the default lossy model* (`lmConvolution`):
  46 uV from the exact constant-RLGC line where the ladder is 32 mV, and
  ~3x faster. With frequency-dependent RLGC the single-frequency ladder is
  0.38 V off the exact causal line (its `R(1 GHz)` at DC). `lmLadder` stays
  for comparison and as the fallback; a line under the lumping threshold is
  a ladder.
- *ISI patterns* `0100` and `1011` (an isolated bit from each settled
  level, and the edge back), each transition measured on its own bit
  (`measurePattern`). **A pattern is skipped when every single edge settles
  within its UI** (time-invariance: each bit then starts settled), recorded
  as an `Assumption`; only a net that rings past a UI pays for it.
- *Settling is judged against the exact settled level*: the DC point with
  the driver held at the end of that edge's table. A single edge still
  ringing at the end of its run is re-run 4x longer (twice at most). Before
  this, settle time was read around a run's last sample, which on a
  ringing net was still moving: **`designs/si_spi`'s MOSI settle claims had
  passed falsely** (3.6 ns reported; its unterminated Y rings at ~690 MHz,
  Q ~ 100, and settles to 2 % only ~31 ns after the edge, past a 20 ns UI).
  The demo now runs at 10 MHz (`ui = 100.ns`, user's choice), its header
  saying why.
- *`judge` (stage 5) runs on `sweepNet`*, so `verax constraints` and
  `verax check` measure identically; `Criteria.ui` (from the role's `ui`)
  adds the patterns. A pattern run lasts its last bit.

**Decided while implementing stage 8** (each in the module doc that owns it):

- *Coupled cross-sections from published closed forms, not the lumped
  mutual-C estimate.* The old `z0Differential` had one velocity for both
  modes, so microstrip far-end crosstalk was zero by construction.
  `coupledModes` is Kirschning-Jansen (static) for microstrip and Cohn
  for stripline (scaled to the IPC-2141 single line); `z0Differential`
  now reads it. Constants were checked against qucsator's implementation.
- *A coupled line is never lumped* (that needs a mutual inductance): its
  faster mode bounds `h`. *The coupled section is lossless.*
- *Several conductors, one net object*: `extraDrivers` with a `DriveMode`
  rather than separate nets; probes are typed (signal / differential /
  leg / victim) so a victim is never judged on flight time and a leg never
  on thresholds it does not have.
- *Spacing is derived on a route that is exactly the parallel run*: at the
  length rule's limit the aggressor's own flight time fails whatever the
  gap (found on `si_spi`: "none passes" up to 2 mm).
- *Crosstalk is pre-layout only*: on a board the claims are
  `esNotEvaluable` (coupled-trace extraction does not exist), so the demo
  `si_spi` does not claim it (its `nimble verify` would exit 3).
- *The fixture network's probe point is a choice*: IBIS shows it only in
  Figure 18. Default the DUT pin (the dut parasitics exist "if the waveform
  includes the effects of pin inductance"), `ExtractTolerances.probe`
  switches, an `Assumption` says which. Implemented in `ibis/behave` (it
  cannot import `si/`) with the engine's trapezoidal companion models, not
  the engine itself.
- *The reconstruction tolerance is unchanged* (open decision 3): a fixture
  network the tables do not match passes 2 % of the swing with exactly two
  fixtures (the solve reconstructs by construction); it shows in the
  coefficients and, with a third fixture, a 250x least-squares residual.
- *The eye is folded on an offset search*, not aligned by a flight time:
  the offset absorbs the channel delay; width is capped at one UI and,
  with thresholds, means every bit past `Vinh`/`Vinl`.
- *S-parameters by impulse response, not a rational fit*: real-pole
  fitting cannot follow a channel's resonances; IFFT + cosine taper over
  the top 20 % + a DC correction onto the main tap, history interpolated
  like Bergeron's (`h <= dt`). Non-causal energy over 1 % is an issue.
- *Power-aware semantics from IBIS 7.2*: `Ksso = Isso(Vtable)/Isso(0)`,
  `Vtable_pu` = the rail's droop, `Vtable_pd` = the ground's rise, updated
  per step (lagged one step). Pre-driver current = `[Composite Current]`
  minus the I/V tables' power-terminal current, rail to rail at each
  transition. `C_comp` stays on the global ground (IBIS's reference unless
  split).
- *Engine traps found*: the band-LU pattern must include device-to-rail
  Jacobian entries (else silently dropped), and Newton's segment damping
  must damp the rails a device hangs from (a pad on a table knot with a
  moving rail oscillated at DC).

**Not done:** IBIS-AMI (stage 8.7, by design); the optional ngspice
oracle and PyBERT cross-checks (PyBERT is not installed here; it would
cross-check `convline` and `eye`); board-level crosstalk and
differential pairs (coupled-trace extraction from a routed board), a
Touchstone part bound to a board component (splits the net), and
`intra_pair_skew`/`z_diff` evaluated on a board; lossy coupled lines;
`[Composite Current]` under network fixtures; SSN through a board PDN
(`analysis` PDN work) and as role claims; the `zout`/slew
linearisation, `verax layout` writing the `.kicad_dru` beside its board,
`D_overshoot_*`/`[Model Spec]` limits as role claims, hysteresis
thresholds. From stage 7: adaptive (LTE-controlled) steps -- `h` is fixed
at `min(tr/20, td)` between edges, which is what a long pattern (a PRBS)
costs; parallel sweeps; board extraction still defaults to ideal lines
(`BoardNetSpec.lossy`). Two `pcb` read-side gaps found on the way are
findings §32.

## What exists today (before implementation)

| Piece | State | Where |
| --- | --- | --- |
| `.ibs` parser, IBIS 3.2 core: I/V tables, `[Ramp]`, V/T waveforms + fixtures (`R/V/C/L_fixture`, `R/L/C_dut`), `C_comp`, package RLC, triplets with per-corner presence (`get` raises on an absent corner) | **done**. No writer, deliberately. | `ibis/parse`, `ibis/reader`, `ibis/types` |
| `Vinl`/`Vinh`/`Vmeas`/`Cref`/`Rref`/`Vref` on `[Model]` | **done** | `ibis/types` |
| `[Model Spec]`, `[Receiver Thresholds]`, overshoot limits | **missing** (typed); reachable only via `raw`/`sections` | n/a |
| Binding a `[Component]` to a designator and checking pin names; `modelFor` resolves a pin's literal model name | **done**. No `[Model Selector]` choice. | `ibis/attach` |
| Net copper → `RouteTree` (branching, vias as nodes, return path per run) | **done** | `pcb/trace` |
| Hole/via geometry (kinds, drill/finished diameter, pads, layer span) | **done** (data only, no electrical model) | `pcb/types` |
| Closed-form Z0 / εeff / RLGC(f) / delay / ladder / ABCD / S-params per edge; unresolved returns reported as issues with `NaN` | **done** | `pcb/impedance`, `pcb/tline` |
| KiCad `.kicad_pcb` reader | **done** | `pcb/formats/kicad` |
| Measurement helpers (interpolation, crossings, extrema, rise time, settling) | **done**, but above `si/` in the dependency order (see stage 4) | `analysis/measure` |
| Result states: `esPass` / `esFail` / `esNotEvaluated` / `esNotEvaluable` | **done** | `contract/evaluate` |
| IBIS → simulatable model | **missing** | n/a |
| A transient solver with transmission lines | **missing** (`spice/` has none either: `transmission_line` has a prefix and nothing else) | n/a |
| A board reachable by evaluators | **missing** (findings §18) | n/a |
| `.kicad_dru` writer | **missing** | n/a |

The parser and the interconnect math are both built. The simulator is the
layer that joins them.

## Scope

**v1 (stages 1–7):** single-ended, point-to-point or multi-drop nets; one
driver switching at a time; typ/min/max corners *where the data supports
them* (decision 7); lossless and lossy uncoupled lines; vias with stubs;
edges or a short bit pattern as stimulus.

**v1 is reached through a narrow first gate.** Before any widening, the
engine must pass the **reference case** (stage 3a): one `Output` or
`Open_drain` driver, one `Input` receiver, one uniform lossless line,
package R/L/C, `C_comp`, one edge, typ corner only. Each widening after
that — multi-drop, lossy ladder, patterns, min/max, vias — lands one at a
time, each with its own independently derived reference fixture and a
stated unsupported case.

**Two uses, one engine:**

- **Check** (stage 6): a routed board exists. Do this net's SI claims hold?
- **Derive constraints** (stage 5): before or during layout, ask *what
  routing rules* make the claims hold. How long can this trace be? How many
  vias may it take? Does it need stub removal (backdrill)? Does it need a
  series termination, and what value? The answer is a rule the layout must
  obey, not a pass/fail on a layout that doesn't exist yet. It can be
  emitted as KiCad custom design rules.

**Not v1** (each has a later stage): crosstalk/coupled lines, differential
pairs (`[Diff Pin]`), PRBS + eye diagrams, S-parameter channels, power-aware
models (`[Composite Current]`, `[ISSO PU/PD]`), IBIS-AMI, `[External Model]`,
EBD/ICM packages, `[Driver Schedule]` multi-stage buffers, V/T fixtures with
`L_fixture`/`R_dut`/`L_dut`/`C_dut` (decision 2).

## Design decisions

### 1. Keep the IBIS interpretation independent of the engine

The hard part of IBIS simulation is not the solver. It is turning a `.ibs`
into a behaviour: picking corners, re-referencing tables, and extracting the
switching coefficients `Ku(t)`/`Kd(t)` from the V/T waveforms. That is pure
math over `ibis/types`, so it goes in **`ibis/behave.nim`**, which depends
on nothing but `ibis/types`.

**Boundary:** `behave` produces immutable, source-traceable *data* —
resolved absolute-voltage tables, the selected corner and every
substitution made to reach it, `Ku`/`Kd` samples, extraction residuals, and
`Assumption`s. It produces no solver devices and no verdicts. This widens
`ibis/`'s current "parsing only" scope, so the same change updates
`src/verax/ibis/CLAUDE.md` (which today also says turning a model into a
device is `spice/models`' job) and `docs/architecture.md`.

### 2. Normative conventions (stage 1 must fix these before code)

One short section in `ibis/behave.nim`'s module doc, mirrored here once
written, and encoded in the fixtures:

- **Spec reference.** Interpretation follows the IBIS 7.x specification
  text (the newest revision clarifies the older rules without changing
  them for the 3.2 subset we read). Every rule below cites its clause in
  the module doc. **Nothing here is worked out from memory**; in
  particular the clamp rule is checked against the spec text before it is
  coded.
- **Voltage reference.** All voltages are absolute, relative to the
  model's ground. `I_pu`/`I_pc` are tabulated against `V_rail − v`;
  `behave` converts every table to absolute pad voltage once, so engines
  never see the IBIS reference convention. Rails come from `[Voltage
  Range]` or the `*_reference` keywords.
- **Current sign.** Positive pad current flows *out of* the die into the
  pad node. A receiver with no stimulus must sink or source current only
  through its clamps and `C_comp`; a test asserts it cannot act as a driver
  by sign error.
- **Clamps are always on, and the pullup/pulldown tables are measured with
  the clamp current already subtracted.** The usual bug is adding the clamp
  current twice. Cite the clause; encode the convention in a fixture whose
  answer is wrong by a known amount if clamps are double-counted.
- **Table interpolation.** Linear between points. Outside the table range,
  extend the end segment linearly (flat extrapolation turns a clamp off),
  and raise an `Issue` when a pad leaves the table range by more than a
  stated margin.
- **Initial conditions.** A DC operating point with `Ku`/`Kd` at their
  `t = 0` values, solved by Newton, not assumed.
- **Supplies.** Ideal voltage sources at the rail values for the corner.

The driver equation every engine implements:

```
I_pad(t) = Ku(t)·I_pu(v) + Kd(t)·I_pd(v) + I_gc(v) + I_pc(v) − C_comp·dv/dt
```

(tables already in absolute pad voltage and the sign convention above.)

### 3. Extracting `Ku`/`Kd`

- **Which waveforms are usable.** `R_fixture`, `V_fixture` and `C_fixture`
  are supported: with `v(t)` given, the fixture current is algebraic. A
  waveform with nonzero `L_fixture`, `R_dut`, `L_dut` or `C_dut` is **not
  used** for extraction and is reported as an unsupported waveform, naming
  the parameter. It is not silently simplified. (Supporting it needs a
  simulation-based extraction; see stage 8.)
- **Two or more usable waveforms per edge (the normal case):** at each time
  step, solve the 2×2 linear system in `Ku`, `Kd`. Each fixture gives one
  equation: the driver equation (decision 2) with *all* its terms — pullup,
  pulldown, both clamps and `C_comp·dv/dt` — set equal to the fixture
  current `(v − V_fixture)/R_fixture + C_fixture·dv/dt`. Omitting the
  clamp or `C_comp` terms makes `Ku`/`Kd` absorb them, and the result
  stops reproducing any other load.
  - Resample the waveforms onto a common time axis first. Require
    monotonic timestamps and overlapping time ranges, or reject the pair.
  - `v(t)` is piecewise linear, so `dv/dt` is the per-segment slope; at a
    knot use the mean of the two adjacent slopes.
  - Check conditioning. A singular or ill-conditioned pair (two fixtures
    too similar to separate pullup from pulldown) is rejected, not solved.
  - With more than two usable waveforms, solve least squares and keep the
    residual.
- **Fewer than two usable waveforms, or `[Ramp]` only (fallback):** assume
  `Ku + Kd = 1` and a linear ramp. Scale the 20–80 % `dt` to 0–100 % (÷0.6).
  This is the spec's own ramp-only model, so it is allowed, but it is
  recorded as an `Assumption` because it is visibly less accurate.
- **No clamping.** The unconstrained `Ku`/`Kd` are kept as solved;
  independent clamping to `[0, 1]` changes the fit. A coefficient outside
  `[0, 1]` by more than a tolerance is a *warning* (real vendor files do
  this, and it means the waveforms and the I/V tables disagree).
- **Reconstruction residual decides availability.** For each edge × corner,
  re-drive every usable fixture with the extracted coefficients and compare
  voltage *and* current to the table. The residuals are kept in the
  result. Above the acceptance tolerance, that edge × corner is
  **unavailable for verdicts** (`esNotEvaluable`, decision 6), not
  advisory.

### 4. Engine: native Nim, no ngspice backend

*Decided 2026-10-06.* The simulator is a native Nim transient engine
(`si/engine/`). There is **no production ngspice backend**. Once the native
engine exists, an ngspice path adds nothing a user needs: it would be slower,
an external dependency, and worse at long patterns and S-parameter channels.
The validation ladder in stage 3 replaces it as a reference:

- Linear I/V tables give closed-form driver behaviour.
- Bergeron lines are exact for lossless sections.
- The waveform reconstruction check uses the vendor's own data.
- `tline.sparams` gives a frequency-domain check for lossy sections.

The gap is the full nonlinear case (vendor tables + clamps + reflections)
with no closed form. For that, stage 3 allows an optional, **test-only**
ngspice oracle: a deck emitter under `tests/` that skips when ngspice is
absent, like `test_spice_ngspice`. It is not an `si/` module and ships
nothing. It is corroboration, never the only validation, and it is built
only once it can be pinned: a fixed deck convention, an ngspice version
range, a stated resampling and comparison policy, and fixtures we are
allowed to commit. Synthetic fixtures remain the mandatory CI oracle.

### 5. Where it lives: a new `si/` submodule

Building an SI net needs `ibis` and `pcb`, so `si/` sits **above `ibis/`
and `pcb/`**, and below `analysis/`, whose evaluators import it. It does
**not** depend on `spice/`, so SI works on a machine without ngspice.
Nothing below `si/` imports it. Board physics stays in `pcb/`, not `ibis/`.

```
analysis/evaluators/si.nim
        |
       si/   topology · drive · engine/ · measure · constrain
      /   \
  ibis/   pcb/          (+ a waveform leaf below both, stage 4)
```

`contract` gains no edge to `pcb`. At verification time, a board reaches the
SI evaluator as *external verification context* through
`EvalContext.scratch`, after a `Design`-to-board adapter exists
(findings §18, `docs/architecture.md`). "Design gains a Pcb" is shorthand
for that, not a type-level field.

### 6. Result states: unsupported ≠ solver failure ≠ failed claim

These map onto the existing `EvalStatus`, so `verax check` can tell them
apart:

| Situation | Status | Carries |
| --- | --- | --- |
| Input or model support missing: unsupported waveform fixture, absent corner without a permitted substitution, unbound pin, via or reference change not modelled, branch before multi-drop lands | `esNotEvaluable` | the precise limitation |
| Solver failure: Newton non-convergence after retries, retry exhaustion | `esNotEvaluated` | an `Issue` with time, node and step |
| Simulated, limit not met | `esFail` | the worst corner, named |
| Simulated, limit met | `esPass` | the `Assumption`s in force |

A solver failure **cannot satisfy a claim**. `SiResult` has a status field
so a failed run cannot be mistaken for a waveform.

### 7. Corners are a per-field compatibility matrix

`Triplet` records presence per corner and raises on an absent read. A
corner may exist for `[Voltage Range]` but not for an I/V row, a waveform,
the package or `C_comp`. So there is no single `resolveCorner` that
assumes completeness:

- `resolveCorner` walks every field the simulation needs and returns the
  values *plus a list of substitutions* (e.g. "`C_comp` min absent, used
  typ"), each an `Assumption`.
- A substitution is permitted only by an explicit policy. **Until that
  policy exists, only typ runs**, and a requested min/max with missing data
  is `esNotEvaluable`, never an unlabelled three-corner answer.
- The min/max pairing for `C_comp` (IBIS does not tie its columns to
  slow/fast) is a *verax policy*, documented as such with its reasoning,
  not presented as industry fact. It is settled after an inventory of
  which fields real vendor files actually populate.

### 8. The topology is data, not a `Netlist`

`si/topology.nim` defines `SiNet`, an engine-agnostic graph: a driver
(behaviour + pad node), receivers (input model + pad node), and elements
(lumped R/L/C, ideal line `(Z0, td)`, lossy line `(RLGC/m, length)`). It has
two builders:

- **From a template (pre-layout, stage 2):** a *parametric* topology for
  constraint derivation (stage 5), e.g. driver → series R → `n` vias → `L`
  of trace on a layer → receivers. The free parameters are named, and the
  stackup gives Z0, delay and via geometry. A fixed instance of a template
  is also the cheapest way to write tests, so stages 1–5 do not wait on
  findings §18. A hand-typed fixed topology is *not* a user-facing check.
  It answers no question anyone asks.
- **From a board (stage 6):** `RouteTree` + `IbisBinding`s → one element
  per `RouteEdge` section, `[Pin]`/`[Package]` RLC as lumped elements.
  Built after the forward path is validated, not before.

**Pin → behaviour mapping** (needed by both builders, specified in stage 2):
the net names one driver pin and its receiver pins; each pin goes through
its designator's `IbisBinding`. `modelFor` returns the literal `[Pin]` model
name only; a `[Model Selector]` name needs an explicit choice, recorded per
designator under a new `spec:`/annotation key (not `partNumber`). `POWER`,
`GND` and `NC` pins on an SI net, an unbound pin, or an unresolved selector
make the net `esNotEvaluable` with the pin named.

## Stages

Every stage ends green on `nimble test` (grep the output, not the exit
code). The native engine needs no toolchain. The only tests that skip are
the optional cross-checks (ngspice oracle, PyBERT) and the `kicad-cli` gate
for emitted rules.

### Stage 0: prerequisites (small)

- Fixtures: synthetic `.ibs` inputs whose I/V tables are linear (a
  resistor), so every downstream number has a closed form. Also: complete
  and incomplete corners, one- and two-waveform edges, a selector case,
  malformed rows, and a waveform with an unsupported fixture parasitic.
  Inline strings where the existing tests already do that; a
  `tests/fixtures/ibis/` directory only for files that are too long inline.
  Do not commit vendor files (licensing). Keep a gitignored
  `tests/fixtures/ibis/vendor/` for manual runs.
- Reader gaps that v1 needs: `[Model Spec]` (`Vinh`/`Vinl` per corner,
  `S_overshoot_high/low`, `D_overshoot_*`) and `[Receiver Thresholds]`. For
  each: typed fields, grammar, units, and corner/presence semantics that
  reuse `Triplet`'s absence rule. Add new fields and leave existing ones
  alone (no field overloading). Check that `V_fixture_min/max` survive into
  `Waveform`.
- **Exit:** every fixture parses, and the parsed typed and `raw` fields
  match what the fixture asserts (there is no writer, so no round-trip
  claim). The new keywords have tests, and the existing `test_ibis_*` stay
  green.

### Stage 1: `ibis/behave.nim`, the interpretation layer

- Write decision 2's conventions into the module doc with spec citations
  first, then the code.
- `DriverBehaviour`/`ReceiverBehaviour`: absolute-voltage I/V tables,
  rails, `C_comp`, `Ku`/`Kd` series per edge, residuals, substitutions,
  provenance (which file/model/table each value came from).
- `resolveCorner(model, corner)`: decision 7. **Typ only** in this stage.
- `switchingCoefficients(model, edge, corner)`: decision 3.
- Model-type gating: `Input`/`Terminator` produce receivers only;
  `Open_drain`/`Open_sink` have no pullup; `3-state`/`I/O` support both.
  Every other type (ECL variants, `Series`, …) is `esNotEvaluable` until
  added.
- Optional: expose the PyIBIS-AMI-style `zout`/slew linearisation, for the
  cross-check below.
- **Exit:** pure-Nim tests. Linear-table fixtures give exact `Ku`/`Kd`. The
  ramp fallback matches its closed form. A double-counted-clamp fixture
  fails. Incomplete, singular and unsupported-fixture data is classified
  deterministically. An inconsistent fixture triggers the out-of-range
  warning and, past tolerance, unavailability.

### Stage 2: `si/topology.nim` + `si/drive.nim`

- `SiNet` and the template builder (decision 8), and the pin → behaviour
  mapping.
- Stimulus: single rising/falling edge, or a bit string at a given UI. A bit
  pattern stitches `Ku`/`Kd` edges at each transition, so a repeated
  rise→fall needs the edge to have settled. Warn when the UI is shorter than
  the waveform table.
- **Via model** (`pcb/via.nim`, closed form beside `pcb/impedance`), built
  on the hole/via data `pcb/types` already has — no new geometry types:
  barrel L, pad/antipad C, and the **stub** (barrel beyond the exit layer)
  as an open-ended line segment so its quarter-wave resonance appears.
  Backdrill shortens the stub to a residual length. It carries an
  `Assumption`, the same as Z0; `fem/` can replace it later. **A via whose
  transition changes the return reference is an `Issue` and
  `esNotEvaluable`**, never silently a barrel L/C — the return transition is
  often as consequential as the barrel.
- **Exit:** templates build the expected element lists; the via model
  matches a published closed-form case. Vias are not used by the engine
  until stage 3b validates them.

### Stage 3: `si/engine/`, the native transient engine

The core of the work, built in this order so each layer is tested before
the next one depends on it. The numerical policy below is fixed in the
module docs **before** coding; the numbers are starting values, tuned only
with a test showing why.

1. **Linear MNA core** (`engine/mna.nim`): node/branch stamping for R, L, C
   and sources. Dense LU is enough at SI scale (tens to low hundreds of
   nodes); sparse only if profiling asks.
   - **Time grid:** fixed base step `h ≤ min(shortest td, t_r/20)`, where
     `t_r` is the fastest edge in the stimulus. Breakpoints at every
     `Ku`/`Kd` knot and stimulus edge, merged into one sorted, de-duplicated
     list; the step is shortened to land on each.
   - **Integration:** trapezoidal. After each breakpoint, the next two
     steps are backward Euler at `h/2`, then trapezoidal resumes. This damps
     trapezoidal's numerical ringing on discontinuities, and it is the whole
     rule.
2. **Lossless lines** (`engine/bergeron.nim`): method of characteristics.
   Each end is a `Z0` conductance plus a history current source delayed by
   `td`. Exact, no internal nodes.
   - `h ≤ td` keeps the two ends decoupled (the history is always in the
     past); it is a correctness condition, not a stability rule.
   - `td` is generally not a multiple of `h`, so the delayed history is
     **linearly interpolated** between stored samples. That interpolation is
     what the line tests measure.
   - A section shorter than some fraction of `t_r` becomes a lumped π
     instead, so it does not drive `h` down. Pick the threshold and test
     both sides of it.
3. **Nonlinear devices** (`engine/newton.nim`): Newton–Raphson over the
   piecewise-linear tables; derivatives are exact per segment, so the
   companion model is a conductance plus a current. Damp the step on
   segment changes.
   - **Convergence:** every node `|Δv| < reltol·|v| + vabstol` *and* every
     KCL residual `< iabstol` (start: `1e-4`, `1 µV`, `1 nA`).
   - **Failure:** after 50 iterations, halve `h` and retry; after 10
     halvings, stop. The result is `esNotEvaluated` with an `Issue` naming
     time, node and step. Never return a silently wrong waveform.
   - First test this on a plain nonlinear shunt I/V element, before any
     IBIS device exists.
4. **IBIS devices** (`engine/ibisdev.nim`): the driver equation with
   `Ku`/`Kd` interpolated at `t`; receivers as clamps + `C_comp`.
5. **Lossy lines:** `tline.ladder` sections through the linear core, with
   an explicit section-count rule (each section's delay `≤ t_r/10`) and a
   test that doubling the count changes the answer by less than the
   tolerance. Recursive convolution comes later (stage 7).

- **Stage 3a — the reference case gate.** Rungs 1–4 below on the reference
  case only (see Scope). Nothing in 3b starts until 3a is green.
- **Stage 3b — widening, one at a time:** multi-drop (branching lines),
  vias, the lossy ladder, bit patterns, min/max corners (once decision 7's
  policy exists). Each lands with its own reference fixture and an
  unsupported case.
- Output `SiResult`: status (decision 6), time + voltage *and current* per
  pad node, plus the `Assumption`s and `Issue`s collected on the way.
- **Validation ladder, in order.** Every golden waveform states its
  derivation (closed form or lattice diagram), tolerances in SI units, and
  the sampling policy. Each is also run at `h` and `h/2` and must agree —
  convergence, not just matching sampled points.
  1. RC/RL/RLC step responses against closed form (core only), including
     very small and zero time constants.
  2. Lossless line, matched / open / shorted / mismatched: the lattice-
     diagram step response, with plateaus and timing exact. Physical
     invariants: nothing arrives before `td`; a matched line reflects
     nothing; open/short reflection signs are right; a passive linear
     channel creates no energy.
  3. Linear-table driver into a resistor = resistive divider with the
     analytic ramp. Compare current as well as voltage.
  4. **Reconstruction:** the model driving its own waveform fixture
     reproduces its `[Rising/Falling Waveform]` table in voltage and
     current. This is an *internal consistency* check — it shares the
     parser, extraction and fixture assumptions — so it supplements rungs
     1–3, it does not replace them.
  5. Lossy line: rise-time degradation agrees with `tline.sparams` (a
     frequency-domain cross-check). (3b.)
  6. Robustness: repeated timestamps, non-monotonic tables, discontinuous
     slopes, steep clamp knees, forced non-convergence (must give
     `esNotEvaluated`), retry exhaustion, deterministic ordering of equal
     breakpoints.
  7. *Optional, test-only:* vendor-file nonlinear cases against the ngspice
     oracle (decision 4). Skips without ngspice.
- **Exit:** rungs 1–4 and 6 pass for 3a; rung 5 and each widening's own
  fixture for 3b. Record a timing benchmark (single edge, three-drop net,
  target ~10 ms on a stated developer machine) as a documented benchmark,
  not a CI assertion — CI hardware varies.

### Stage 4: `si/measure.nim`, the numbers a claim reads

- **First, move shared helpers down.** `analysis/measure` sits above `si/`,
  so `si/` cannot import it. Extract the domain-neutral time-axis helpers
  (interpolation, crossings, extrema, rise time, settling) into a leaf
  below both, with its own tests, and have `analysis/measure` re-use it. Do
  not duplicate them.
- Then the SI-specific definitions, in `si/measure`:
  - Threshold crossings against `Vinh`/`Vinl` (the `[Model Spec]` value if
    present, else `[Model]`).
  - **Flight time** = crossing at the receiver − crossing of the same driver
    into its `Vref`/`Rref`/`Cref` timing load at `Vmeas`. IBIS's own
    definition; it removes buffer delay, which the datasheet's Tco already
    counts. The timing-load run is itself a tiny native simulation.
  - Overshoot/undershoot vs. `[Model Spec]` limits and the receiver's
    abs-max; ringback into the threshold band; monotonicity through the
    band; settle time. Every voltage limit states its reference.
- No contract registration yet.
- **Exit:** each measure has analytic tests on synthetic waveforms, plus one
  end-to-end test on a stage 3a run. A deterministic end-to-end result with
  no ngspice or KiCad.

### Stage 5: constraint derivation (`si/constrain.nim`)

The inverse question: given a template (decision 8), the stackup, the IBIS
bindings and pass criteria, **which parameter values pass?**

**Gate:** a parameter is swept only once the forward path it exercises is
validated in stage 3 — e.g. via count only after vias pass 3b, length on a
lossy layer only after the ladder passes. It does not wait on board
extraction (stage 6): the template, not a board, is its input.

- **Criteria:** the stage 4 measures against limits. Defaults come from the
  IBIS data (`Vinh`/`Vinl`, `[Model Spec]` overshoot limits). A timing
  budget (max flight time, settle by UI) is supplied by the caller, and
  from stage 6 on comes from the contract. Every point is judged at every
  corner the data supports (decision 7); the worst one decides, and the
  report says which corners were run.
- **Search — do not assume monotonic.** Ringback and overshoot against
  length are *not* monotonic: a short line looks lumped, a long one shows
  reflections, and there are bad windows in between. Sweep each continuous
  parameter on a coarse grid; bisect a pass/fail transition **only between
  two valid samples** (a solver failure is not a "fail"). The answer is a
  set of passing intervals, reported with the grid resolution and any
  unexamined gaps. Integer parameters (via count, termination present or
  not) are enumerated.
- **Two-parameter trade-offs as tables, not optimisation.** E.g. max length
  for 0, 1, 2 and 3 vias, or max length with and without a series R (and
  the best R from a short sweep). No general N-D optimiser.
- **Stub removal** is answered as a comparison: the max stub that passes vs.
  the actual stub for each layer transition the stackup allows (e.g. L1→L3
  on a 6-layer board leaves an L3→L6 stub). Answer: per transition,
  "backdrill: needed / not needed", or "avoid this transition".
- **Explain every answer.** The binding failure mode ("> 142 mm fails
  ringback margin at the min corner, receiver U3"), and beside it the
  rule-of-thumb figure (critical length ≈ `t_r / (2·t_pd)`, stub resonance
  at `c / (4·L_stub·√εeff)`). When the two disagree badly, that is worth
  seeing.
- **An answer's identity** includes the template, stackup, termination,
  driver model and mode, receivers, corners and assumptions. A "max length"
  stripped of those is not reported.
- **Output, in two steps:**
  1. A versioned constraint report: text/JSON, the same formats as
     `verax bom`. This is stage 5's deliverable.
  2. **KiCad custom rules** (`.kicad_dru`), a separate sub-step with its
     own acceptance: `length` and `via_count` per net or net class, via a
     new writer in `pcb/formats/`. Constraints KiCad cannot express
     (backdrill, termination value) stay in the report. `kicad-cli` has no
     standalone DRU parser; KiCad loads `<project>.kicad_dru` beside the
     `.kicad_pro`. So the gate is: a fixture board + project + emitted
     rules, `kicad-cli pcb drc`, and a deliberately violating track that
     **must** be reported — proving the file is both parsed and enforced.
     Pin the KiCad version the gate was proven on (10.0.6 today). Then
     `verax layout` can write the `.kicad_dru` next to the board it
     generates.
- CLI: `verax constraints designs/foo.nim [--net=…] [--stackup-layers=N]
  [--dru=out.kicad_dru]`.
- **Exit:**
  - A synthetic linear-driver case whose max length has a closed form, found
    to within bisection tolerance.
  - A deliberately non-monotonic case that comes back as two intervals.
  - A stub case whose verdict flips across the resonance.
  - The `kicad-cli` DRC gate above (DRU sub-step only).

### Stage 6: board extraction and contract wiring (makes it part of `verax check`)

- **Board builder** (decision 8): an unbranched route first, from
  `RouteTree` sections characterised by `pcb/tline`. Unresolved or
  reference-changing sections (`tline` already reports them as issues with
  `NaN`), branches before multi-drop has passed 3b, unsupported vias, and
  implicit bindings or selectors are `esNotEvaluable` — never turned into an
  optimistic result. Tests: route length, layer and return-path identity,
  branch rejection then support, pin-to-binding mapping, via span, every
  fallback assumption. Its section lengths and Z0 match
  `tline.characterize` on a KiCad fixture.
- **Shared prerequisite (findings §18):** the `Design`-to-board adapter, a
  board reaching evaluators through `EvalContext.scratch` (decision 5). The
  same work unblocks the `diff.nim` evaluators.
- An `IbisBinding` source: a `spec:` / annotation naming the `.ibs` path,
  `[Component]` and `[Model Selector]` choice per designator. New key; do
  not reuse `partNumber`.
- Quantities, registered only for measures proven in stage 4:
  `si_overshoot_v`, `si_undershoot_v`, `si_ringback_margin_v`,
  `si_flight_time`, `si_settle_time`, `si_threshold_margin_v`. Run
  `verax quantities` to confirm.
- Role `si_net(driver, receivers, edge_rate?, ui?)` expands to those
  assertions. The **same assertions are stage 5's pass criteria**, so one
  statement of intent drives both deriving the rules before layout and
  checking the board after it.
- `verax check` with a board checks the claims. Without a board, it can
  report the derived constraints instead, so a design with no layout still
  gets an SI answer.
- Evaluator `analysis/evaluators/si.nim` runs every supported corner and
  reports the **worst corner**, named, with the decision 6 statuses.
- **Capability `capSiTran`.** Not `capSpiceTran`: that would wrongly skip
  the native engine on a machine without ngspice (no field overloading).
  It is a registry change, so specify all of: `capLabel` (`"si"`), the
  `--caps` spelling (`si`), membership in `allCapabilities`, whether it is
  in the default `offlineCapabilities` (open decision 4), readiness
  rendering in `plan`, and tests for each.
- A design under `designs/` exercising it. The datalogger's SPI/SDIO nets
  are the obvious first users once its board exists.
- **Exit:** a board fixture produces a traceable forward result; the
  readiness report distinguishes unsupported input, solver failure and a
  failed assertion; `nimble verify` is clean; `verax check` prints SI
  pass/fail with assumptions.

### Stage 7: sweeps, performance, lossy accuracy

*Done 2026-10-07; see "Implementation status".*

- Corner × pattern × receiver sweeps with a worst-case report. Stage 5's
  searches are the main load: each answer costs tens to hundreds of
  simulations.
- Profile against the stage 3 benchmark and fix what it shows. Likely:
  reusing the LU factorisation while the timestep and the set of active
  table segments are unchanged, and a sparse solver for big multi-drop
  buses.
- Lossy lines by recursive convolution (a rational/pole-residue fit of
  `impedance.rlgc` over frequency). Replaces the ladder where accuracy or
  speed needs it, checked against the ladder and `tline.sparams`.
- **Exit:** a 3-corner × 3-receiver sweep in interactive time, and
  convolution parity with the ladder.

### Stage 8: extensions, roughly by value

*Done 2026-10-07 except item 7; see "Implementation status" for what each
item covers and what stops at the template.*

1. **Crosstalk:** coupled-line elements from `impedance.z0Differential`
   odd/even modes (modal decomposition into two Bergeron lines).
   Aggressor/victim setup, with NEXT/FEXT at the victim receivers. Stage 5
   then also derives a **spacing** constraint (KiCad `clearance` per net
   class).
2. **Differential pairs:** `[Diff Pin]`, `tdelay`, and differential
   thresholds `Vdiff`. Pairs with the `diff.nim` evaluators.
3. **Full V/T fixture networks:** extract `Ku`/`Kd` by simulating the
   fixture (`L_fixture`, `R/L/C_dut`) in the engine instead of
   algebraically, so those waveforms stop being unsupported.
4. **PRBS + eye diagram:** eye height/width as quantities. Cross-check
   against PyBERT (see "External cross-checks").
5. **S-parameter channels:** a Touchstone block as an element, via
   `verax/touchstone` + convolution.
6. **Power-aware:** `[Composite Current]`, `[ISSO PU/PD]` for SSN/ground
   bounce. This joins `analysis` PDN work.
7. IBIS-AMI: probably never in-process, because it needs vendor `.so`/`.dll`
   models. Listed so it is not mistaken for an oversight.

## External cross-checks: PyBERT / PyIBIS-AMI

PyBERT and PyIBIS-AMI are open source and worth using, but only for what they
actually compute. PyIBIS-AMI's `ibis.Model` **linearises** a buffer. It
takes one `zout` from the slope of the pullup/pulldown tables at one
voltage, plus `ccomp` and one slew rate from `[Ramp]`. It does not run the
nonlinear transient. So it can check:

- **Parsing:** both readers agree on tables, `C_comp`, ramp and package
  values for the same vendor file (stage 0).
- **Small-signal extraction:** `ibis/behave` can expose the same `zout`/slew
  linearisation, and the two should match on the same file (stage 1).
- **Linear-channel results:** PyBERT's channel model gives insertion loss,
  step/pulse response and eye for a lossy line. These cross-check stage 7's
  convolution lines and stage 8's PRBS/eye work.

It **cannot** check stage 3's nonlinear waveforms (clamps, reflections into
a nonlinear driver) or stage 5's answers where nonlinearity decides them.
Those rely on the stage 3 ladder and the optional ngspice oracle. Use it as
a script under `tests/` that skips when Python/PyBERT is absent, never as a
dependency. Like the ngspice oracle, it records tool version, script,
tolerances and mismatch artefacts.

## Risks

- **Vendor `.ibs` quality.** Waveforms often disagree with I/V tables. The
  reconstruction residual (decision 3) makes this visible and, past
  tolerance, makes the edge unavailable rather than silently skewing
  results.
- **Native solver robustness** is the big risk with no mature simulator
  underneath. Non-monotonic table segments, steep clamp knees and stiff
  package L/C are where Newton stalls. Mitigated by the stage 3 policy;
  failures are `esNotEvaluated`, never a waveform. Collect every vendor
  file that breaks it into the gitignored vendor set.
- **Closed-form Z0 and via accuracy.** `pcb/impedance` and `pcb/via` are
  quasi-static and closed-form. Every board-derived result carries that
  caveat as an `Assumption` until `fem/` can supply 2-D field-solved RLGC.
  That later swap is the main reason for `fem/` to exist.
- **Constraint search cost.** A non-monotonic sweep × 3 corners × several
  parameters is hundreds of runs per net. The main reason stage 7 exists.
- **False confidence in derived rules.** A derived rule amplifies every
  unresolved IBIS, numerical and template assumption into something the
  layout obeys. If the real route has a via or branch the template didn't,
  the rule is wrong. Mitigations: stage 5's gate (only sweep validated
  physics), the answer's identity, and the stage 6 check on the real board
  as backstop. The report says so.
- **Return path.** `trace` resolves a reference plane, but plane gaps,
  stitching vias and reference changes are not in the line model. A
  section or via whose reference changes is an `Issue` and
  `esNotEvaluable`; it is never modelled silently.

## Open decisions

1. **Supported model-type matrix** beyond stage 1's list (ECL variants,
   `Series`, `Series_switch`, `I/O_open_*`): which, and when?
2. **Corner substitution policy** (decision 7): which substitutions may
   ever support a contract verdict, and the `C_comp` min/max pairing.
   Settle after a vendor-file field inventory.
3. **Acceptance tolerances** for `Ku`/`Kd` reconstruction residual and the
   out-of-`[0, 1]` warning. Set from synthetic fixtures, then checked
   against the vendor set.
4. **`capSiTran` by default?** It needs no external tool, so it fits
   `offlineCapabilities`; the cost is that a plain `verax check` then runs
   simulations. Recommendation: include it, revisit if checks get slow.

## Decisions log

1. ~~Engine order~~ **Native only** (user, 2026-10-06). ngspice survives
   only as an optional test oracle (decision 4).
2. **Pre-layout use = constraint derivation** (user, 2026-10-06). Not a
   hand-typed fixed topology (no one would use it), but routing rules
   derived from a parametric template: max length, via count, backdrill,
   termination (stage 5).
3. ~~Native engine optional~~ The native engine is **core** (user, 2026-10-06).
4. **Cross-checks:** PyBERT/PyIBIS-AMI for parsing, linearised values and
   linear channels; ngspice optional for nonlinear transients (user
   suggested PyBERT, 2026-10-06).
5. **Review integrated** (2026-10-07, `docs/ibis_plan_review.md`).
   - *Taken:* the full-equation `Ku`/`Kd` solve with conditioning and
     residuals; unsupported fixture parasitics rejected, not dropped; no
     `[0, 1]` clamping, residual-gated availability; per-field corner
     matrix, typ first; a written numerical policy and delayed-history
     interpolation; a reference-case gate before widening; the result-state
     mapping; pin/selector mapping; helpers moved down; the
     `ibis/CLAUDE.md`/architecture update; `capSiTran` specified in full;
     "parses" not "round-trips"; reconstruction relabelled internal
     consistency; physical-invariant and current-based tests; the timing
     target as a benchmark, not a CI test; DRU split out behind a
     DRC-enforcement gate; board extraction moved after the forward path.
   - *Not taken:* deferring constraint derivation until after board-based
     verification. It is the user's chosen pre-layout use (entry 2), and
     its correctness depends on the forward engine, not on board
     extraction. It is instead gated per parameter on validated physics
     (stage 5). Multi-drop, lossy lines, patterns and vias stay in v1, but
     behind the stage 3a gate and landed one at a time. The ramp-only
     fallback stays (with an `Assumption`): it is the spec's own model, not
     an invented simplification.
