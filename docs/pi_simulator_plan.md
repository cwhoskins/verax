# Power-integrity simulator — plan and roadmap

Goal: simulate a routed board's **power distribution** and judge a design's
power claims against it, the way `si/` judges a net's signal claims. Three
questions, asked in this order:

1. **DC** (Part A, first): how much voltage each load loses to the copper
   between it and its source, how hot the board gets, and whether any
   track, neck or via carries more current than it should.
2. **AC** (Part B): the impedance each load sees looking into the
   power-distribution network (PDN) over frequency, and which decoupling
   capacitors, in which existing sites, meet a target at least cost.
3. **Transient** (Part C): each load's rail when its current steps.

*Status (2026-10-09): plan only. Nothing below is implemented.*

## Scope

**In:** board copper (tracks, pours, planes, vias, lands) for every power
net and its return; sources (regulators, connectors) and loads (IC power
pins) bound from the netlist; series parts on a rail (sense resistors,
ferrites, inductors) by their DC resistance; steady-state board temperature
from copper Joule heating and component dissipation; plane-pair and
capacitor behaviour from DC to ~1 GHz; load steps with a stated current
profile.

**Out, by decision:**

- **Die-level modelling** — on-die capacitance, package-to-die networks,
  CPM models. A load port is the board side of the IC's pins. A stated
  package R/L at a pin is accepted as data (B2) but nothing is extracted.
- **Temperature feedback** — copper resistivity, capacitor values and ESR
  are taken at one temperature. The DC thermal solve is **one-way**: Joule
  heat goes into the thermal solve, the temperature does not come back. Each
  result records that as an `Assumption`.
- **Coupling to `si/`** — `si/ssn` stays the SSN tool; no PI result feeds an
  SI run or the reverse. (No `pi` ↔ `si` edge in either direction.)
- Transient thermal (`pkThermalTransient`), enclosure/chassis heat paths,
  forced-air flow fields, full-wave EM, radiated emissions.

## What exists, what this needs

| Have | Where | Used for |
| --- | --- | --- |
| Board model with filled zones, holes, lands, stack-up | `pcb/types`, `formats/kicad` (`Zone.fills`) | geometry of every stage |
| Point-in-shape, polygon flattening, spatial index | `pcb/geometry`, `pcb/index` | rasterising copper (A1) |
| Land → pin binding on a read board | `pcb/graph.bindLandPins` | finding source/load pins on copper |
| Via barrel L, pad/antipad C | `pcb/via` | mounting inductance (B2) |
| Trace R/L per metre, skin effect | `pcb/impedance` (`rlgc`, `causalLine`) | track elements, AC resistance |
| Band LU over RCM; rational fit (real poles) | `si/engine/lu`, `si/engine/ratfit` | must **move down** (A0) |
| Netlist-level rail impedance (ngspice, 100 kHz–100 MHz) | `analysis/analyses/pdn`, `power_rail.targetZ` | the netlist-only answer; stays |
| Load step on a netlist (ngspice) | `analysis/analyses/transient`, `spice.load_step` | the co-simulation host (C3) |
| `esr`/`esl`/`dcr`/`rout`/`lout`/`current_rating` annotations | `netlist/annotations` | capacitor, series-part and VRM models |
| DC-bias derating of Class 2 ceramics | `spice/models/derating` | must **move down** (B2) |
| Ambient range, `delta_t` | `netlist/environment` | thermal ambient (A3) |
| Board → evaluator path, `--board=` | `pcb.BoardRef`, `verify`, `si_spi` | contract integration (A4) |
| FEM problem/mesh vocabulary, MFEM stage 0 | `fem/` | optional oracle only (see decision 1) |

**Missing and supplied by this plan:** load currents by operating state and
corner (nothing says what a part draws — A0), a sparse iterative solver (A0), a copper
conduction model (A1), a thermal model (A3), a plane-pair frequency model
(B1), capacitor mounting inductance from geometry (B2), complex-pole
fitting with passivity (C1), and a demo board with filled pours (A4).

## Architecture

New submodule **`pi/`**, a sibling of `si/`:

```
units/eng/waveform  <-  numeric (new)  <-  pcb  <-  pi  <-  analysis  <-  verify
                                    netlist  <-  pi
                                    parts    <-  pi   (B2: derating, B4: catalogue values)
```

- `pi` depends on `pcb`, `netlist`, `parts` and the new `numeric`. **No
  `pi -> spice`, no `pi -> si`, no `pi -> fem`.** The ngspice co-simulation
  (C3) is stitched together in `analysis`, which may import both: `pi`
  emits a `Netlist` fragment, `analysis` hands it to `spice`.
- **`numeric/`** (new, below `pcb`): `lu` and `ratfit` move down out of
  `si/engine/` (both `si` and `pi` need them; CLAUDE.md: "when a type is
  needed by two siblings it moves down"). `si/engine` keeps thin re-exports
  for one release, or just updates imports. New here: `sparse` (CSR,
  RCM), `pcg` (preconditioned conjugate gradient, IC(0) and Jacobi), `cband`
  (complex band LU for B1).
- **`pi/`** files, by stage:

| File | Stage | What |
| --- | --- | --- |
| `pi/loads.nim` | A0 | sources, loads, series parts, return nets for a rail, from a `Pcb` + its `Netlist` |
| `pi/raster.nim` | A1 | copper → cells per (layer, net), face-coverage conductances |
| `pi/dcmodel.nim` | A1 | cells + track elements + vias + lands → one conductance network |
| `pi/dc.nim` | A1 | solve, per-load drop, per-element current |
| `pi/ampacity.nim` | A2 | current density, track/via current vs allowance |
| `pi/thermal.nim` | A3 | layered thermal network, Joule + component sources, convection |
| `pi/map.nim` | A4 | per-layer SVG maps (voltage, current density, temperature) |
| `pi/acmodel.nim` | B1 | plane-pair RLGC grid, track L, ports |
| `pi/decap.nim` | B2 | capacitor + mounting model, VRM model |
| `pi/zport.nim` | B3 | port reduction, `Z(f)` at loads |
| `pi/optimize.nim` | B4 | decap selection over existing sites |
| `pi/macromodel.nim` | C1 | vector fit, passivity, netlist export |
| `pi/step.nim` | C2 | native load-step simulation |

- `analysis/analyses/pi.nim` + `analysis/evaluators/pi.nim` adapt it to the
  contract (mirroring `si`). New roles live in
  `contract/roles/power.nim`.
- Capabilities: **`capPiDc`, `capPiAc`, `capPiTran`** — native, in
  `offlineCapabilities` like `capSiTran`. C3 additionally needs `capTran`.

## Part A — DC (first)

### A0 — Foundations

1. **Move `lu`/`ratfit` to `numeric/`**; `si` imports updated; `nimble
   test` unchanged.
2. **`numeric/sparse` + `numeric/pcg`.** CSR assembly from triplets, RCM,
   PCG with geometric multigrid on the uniform grid (IC(0), then Jacobi, as
   fallbacks), stated
   tolerance, iteration cap; **a non-converged solve is a status, never a
   result** (as `si`'s `ssSolverFailed`). Gate: 2D Poisson on a grid vs the
   band LU to 1e-10 relative; SPD check on a random conductance network.
3. **Load currents: power states and scenarios.** A part does not draw one
   current — it draws one per operating state (sleep, idle, active, radio
   TX…), each with a spread. A scalar annotation can't hold that (`AnnDef`
   is one float per key, and encoding states into key names would be field
   overloading), so this is **typed netlist data**, geometry-free, on
   `Component`:
   - **`PowerState`** — per part: a name, and per supply pin *or pin group*
     (`VDD` = all pins named `VDD*`) a current as **min/typ/max**. Authored
     with the part, so a part library (`designs/lib/stm32h563.nim`) carries
     its states to every design that uses it:
     ```nim
     power_state U1, "active": VDD = (typ: 45.mA, max: 60.mA); VDDA = 2.mA
     power_state U1, "sleep":  VDD = (typ: 2.uA, max: 10.uA)
     ```
     A bare value is typ only. A pin group's current is split equally over
     its pins (an `Assumption` naming the part) unless stated per pin.
   - **`Scenario`** — design level: a name and one state per part
     (`scenario "logging": U1 = active, U3 = tx`). A part that has states
     but isn't named in a scenario takes its declared `default` state; a
     part with states and no default is refused by name, never treated as
     drawing nothing. A scenario may also set a source's voltage corner.
   - **Corners**: a run picks `min`, `typ` or `max`. As in `si/` (min/max run
     only on complete data), a corner some part lacks is **skipped and
     named**, never filled from typ; typ is required. Claims say which
     scenario and corner they hold for (`Assertion.condition["scenario"]`,
     `["corner"]`); by default DC drop and ampacity claims hold at `max` in
     every scenario, thermal at the claim's stated corner.
   - **Transitions** between two states (`sleep -> active`, with a stated
     edge time) are the load step: `ΔI = I_to,max − I_from,min`. Part B
     derives a target impedance from them and Part C uses them as stimulus.
   - **Return current** leaves through the part's ground pins, split
     equally (an `Assumption`) unless stated per pin.
   - **Power tree**: a regulator's input draw follows from its outputs'
     loads in the same scenario/corner (`P_out / (η·V_in)` with a stated
     `efficiency`; an LDO's input current = its output current), so upstream
     rails see the right load without restating it.
   - A rail with **no stated load in a scenario** is not answerable, never
     "0 A, 0 V drop".
   - Later widening (not this plan): states read from `.op` currents.
4. **Sources.** A regulator's output pins, or a connector pin, bound by the
   role (A4). Remote sense: the role's optional `sense`/`sense_return`
   pins become a constraint `V(sense) − V(sense_return) = Vnom` (one extra
   unknown, the source voltage); without them the output pins are held at
   `Vnom`. Several sources on one rail (parallel regulators, a connector
   and a regulator) are each held at their own stated voltage.
5. **`pi/loads.nim`** collects, for one rail: its net(s), its return net,
   source pins, load pins with currents, and **series two-terminal parts**
   between rail sub-nets (resistor value, inductor/ferrite `dcr`) — so a
   rail split by a sense resistor or a bead is one problem. Refused by name:
   a series part with no DC resistance stated, a load pin with no land on
   the board, a net with no copper.

### A1 — DC conduction (IR drop)

**Model** (decision 1): a hybrid 2.5D conductance network.

- **Pours and planes** (`Zone.fills`, `ckFill`): rasterised per layer on a
  uniform grid (default cell 0.2 mm, `PiOptions.cell`). Each cell's
  coverage and each **shared face's coverage fraction** (4×4 sub-samples)
  sets the face conductance `σ·t·(face coverage)` — so a neck narrower than
  a cell still conducts in proportion. `Zone.fills` empty → refused per
  zone, never the outline (`pcb/CLAUDE.md`). `ckZone` skipped.
- **Tracks** (`ckTrack` arcs and segments): **1-D resistor elements**, not
  raster — `R = ρL/(w·t)` is exact at DC and a 0.15 mm trace would be
  unresolved on any affordable grid. A track end inside a pour connects to
  the covering cells (weighted by distance); a track end on a land
  connects to the land.
- **Lands**: the cells under the land on its layer are tied by a
  high-conductance star to a land node; loads and sources inject at the land
  node. THT lands appear on every layer they span.
- **Vias**: barrel resistance `ρ·h / (π·(d_drill − t_p)·t_p)` between the
  layer nodes it spans; plating `t_p` defaults to 25 µm (`Assumption`;
  `Hole.finishedDia` refines it when present). Via-in-pad joins its land.
- **Copper thickness** from `StackEntry.thickness`, else `copperWeight`,
  else 35 µm (`Assumption`); outer layers add a stated plating build-up
  (default 0, `Assumption`). `ρ` = 1.72e-8 Ω·m at 20 °C (`Assumption`,
  same as `TlineSpec.rho`).
- Unknowns are only cells carrying the rail or return net, so a 100×100 mm
  four-layer board is ~10⁵–10⁶ unknowns: PCG, not LU.

**Solve and results** (`pi/dc.nim`), per rail:

- The **return net is solved once with every rail's return current**
  superposed (ground carries them all); each rail net is solved with its own
  loads. The drop a load sees is `Vnom − (V(rail pins) − V(return pins))`,
  reported split into supply-side and return-side parts (a fix differs).
- Per load: `pi_v_load` (worst pin), `pi_drop_v`, `pi_drop_pct`. Per rail:
  total copper loss `pi_copper_loss_w`, worst load.
- Per element: current through every track, via and series part; per cell:
  current density (feeds A2 and A3).
- **Accuracy is reported, not assumed**: every solve repeats at cell/2 on
  request (`PiOptions.convergenceCheck`, on in tests); the change in the
  worst drop is stated on the result.

**Oracles** (`tests/test_pi_dc.nim`), each exact:

1. Straight track: `ρL/(wt)`; a track chain with branches vs Kirchhoff by
   hand.
2. Rectangular sheet, full-edge contacts: `Rs·L/W` (raster converges to it).
3. **Annulus** with inner/outer ring contacts: `ln(b/a) / (2π σ t)` —
   tests curved boundaries and coverage weighting.
4. Two-layer plane joined by an N-via array: plane drops + `R_via/N`.
5. Remote sense: the sense point lands at `Vnom` exactly; the source rises
   by the source-side drop.
6. Return-path superposition: two rails sharing a ground; the ground drop
   equals the sum of each alone (linearity).
7. Optional: MFEM (`$MFEM_DIR`) 3-D conduction on the same extruded copper
   (`fem/extrude`) within 2 % — needs the shim widened to a piecewise
   conductivity with Neumann current terminals; skips without MFEM.

### A2 — Current density and ampacity

- **Tracks**: current per track section vs an allowed current for a
  **stated** temperature rise (`maxTrackRise` on the role — no default
  limit; CLAUDE.md "never invent a default limit"). Closed form per
  decision 3: IPC-2221 `I = k·ΔT^0.44·A^0.725` (k = 0.048 external, 0.024
  internal). Reported as `pi_track_current_ratio` (I / I_allowed, worst
  section) with the section's location and layer.
- **Vias**: current per via vs the same formula on barrel cross-section, and
  the share of a via array's current carried by its worst via (arrays don't
  share evenly — the solve says how unevenly). `pi_via_current_max`.
- **Pours**: peak current density `pi_j_max` (A/mm²) and its location;
  necks are where pours fail and closed-form ampacity has nothing to say.
- When A3 runs, the **simulated** temperature rise of each track/cell is the
  better ampacity answer (neighbouring copper and planes spread heat that
  IPC-2221 ignores) and is reported alongside; the closed form stays as the
  conservative, solver-free figure.
- Oracles: IPC-2221 formula vs its published table points; via split in a
  symmetric array is exactly even, in a line array the nearest via carries
  most (monotone check).

### A3 — Steady-state thermal

**Model**: the A1 raster, extended through the stack: one thermal node grid
per copper layer and per dielectric layer.

- In-plane conductance per layer from copper coverage (k_Cu = 385 W/m·K)
  plus dielectric (FR-4 in-plane 0.8, through-plane 0.3 W/m·K —
  `Assumption`s, per-material override through `StackMaterial.attrs`).
- Vertical conductance between layers through the dielectric, **plus every
  via as a copper column** (plated vias dominate the vertical path).
- **Sources**: Joule heat `I²R` per cell/track/via from A1 (one-way); each
  component's dissipation over its land cells. Component dissipation comes
  from a new annotation `p_dissipation` (W, `asComponent`), or a
  regulator's `(1/η − 1)·P_out` when the role states `efficiency`, or a
  resistor's `I²R` from A1 when it is a series part. A component with no
  figure dissipates nothing, **listed** as an `Assumption` (never silently
  0 W).
- **Boundary**: convection to `t_ambient_max` (`netlist/environment`) from
  top and bottom faces, `h` = 10 W/m²·K each (still air, radiation
  linearised in — `Assumption`; new environment keys `h_top`/`h_bottom`
  override). Edges adiabatic. No chassis, no mounting-hole heat sinks
  (later: a stated `t_fixed` on a hole's land).
- **Results**: temperature per cell per layer; `pi_t_max` (board), each
  component's board temperature under its body `pi_t_board`, and when the
  part states `theta_jb` (new) a junction estimate `pi_t_junction = T_board
  + P·θ_JB`. This is the derivation `docs/findings.md` left open for
  `delta_t`: the board solve supplies it, and an authored `delta_t` **stays
  the override** (findings). Aligns with the `thermal` role findings
  proposes (`maxPower`, `thetaJA`, `tJMax`) — that role gets a board-backed
  evaluator here; `θ_JA` is not used on a board result (it already contains
  a board).
- Oracles: 1-D slab with convection on both faces (exact); a **long trace
  as a fin** — uniform heating, convecting, ends held — `cosh` closed form;
  a disc source on a large plate vs the Bessel-`K0` solution; energy
  balance (total convected = total dissipated) to solver tolerance on every
  run, asserted not just tested.

### A4 — Contract, CLI, demo

- **Role `pi_rail`** (`contract/roles/power.nim`): net `rail`, net `return`,
  part `source` (or `source` pins), optional `sense`/`sense_return`,
  params `voltage` (or read from the rail), `maxDrop`/`maxDropPct`,
  `maxTrackRise`, `maxCurrentDensity`, `maxBoardTemp`, `efficiency`. Each
  claim only when its limit is stated. Claims are **per load pin** (subjects
  are pins, like `si_net`) — a drop is a location, not a rail.
- **Role `thermal`** (as findings proposes), with a board-backed evaluator
  for `pi_t_junction`/`pi_t_board`.
- `verax check designs/foo.nim --board=foo.kicad_pcb` evaluates PI claims;
  without a board they are reported not evaluable, pointing at `--board=`
  (as `si_net`).
- **`verax pi designs/foo.nim --board=foo.kicad_pcb [--rail=NET]
  [--map=DIR] [--cell=0.2mm] [--format=text|json]`**: the report without
  judging, and with `--map` per-layer SVG maps (voltage, current density,
  temperature). Text/SVG only — verax is non-GUI.
- **Demo `designs/pi_demo.nim`** + a hand-written four-layer
  `designs/pi_demo/pi_demo.kicad_pcb` (buck → 3.3 V plane → MCU + a
  current-hungry load through a neck and a bead; ground plane; a thin
  track that fails ampacity on purpose behind a `maxTrackRise` only the
  demo states). Pours are filled with `kicad-cli pcb drc --refill-zones
  --save-board` (KiCad 10), then the fills are what verax reads. Its
  `nimble verify` passes its own board, like `si_spi`.
- Exit for Part A: oracles green, demo checks, `verax pi` on the demo in
  < 2 s at 0.2 mm cells (`-d:release`), docs (`pi/CLAUDE.md`,
  `architecture.md`, `designs/CLAUDE.md`) updated.

## Part B — AC impedance and decoupling

### B1 — Board frequency model

- **Plane pairs**: the A1 raster (coarser: cell ≤ λ_min/20, default 1 mm
  at 1 GHz on FR-4) becomes a 2-D **RLGC grid** between each power shape
  and its adjacent reference plane: per cell `C = ε·A/d`, `G = ωC·tanδ`,
  per face `L = μ₀·d·(length/width)` plus copper internal inductance and
  `R` with skin effect (`impedance.causalLine`'s form). Captures cavity
  resonances, which a netlist cannot (why `analyzePdn` stops at 100 MHz).
- **Traces-only rails**: tracks as series R-L elements (`impedance.rlgc`
  for their own reference plane); a section with no reference is
  `route_no_reference`, as in `si`.
- **Vias between plane pairs**: barrel L from `pcb/via`.
- **Ports**: each load (its power/return pin pair — **board side of the
  package**, die out of scope), each capacitor site, each source. A stated
  `package_r`/`package_l` at a load pin is added in series as data.
- Solve: complex sparse LU (`numeric/cband` over RCM) per frequency, log
  sweep 10 kHz–1 GHz, 20 pts/decade.
- Oracles: rectangular plane pair vs the **analytic cavity double sum**
  (Lei/Okoshi) — resonance frequencies to < 1 %, `|Z|` to a few % below the
  first resonance; a tiny plane must collapse to a lumped `C`; one via
  between planes vs its `pcb/via` inductance.

### B2 — Capacitor, mounting and VRM models

- **Capacitor**: `C` (DC-bias derated at the rail voltage — **`derating`
  moves from `spice/models` down to `parts/`** so `pi` and `spice` share
  it), `esr`, `esl` from annotations or the catalogue entry (catalogue
  schema widened with `esr`/`esl`/`price`; absent → `Assumption`s from a
  stated per-case-code table).
- **Mounting inductance from the board**, the main gain over the netlist:
  land-to-via track loop + via barrels down to the plane pair + spreading
  inductance into the plane, all from geometry; reported per site so a
  badly mounted cap is named.
- **VRM**: series `rout` + `lout` (existing annotations) behind an ideal
  source — flat below its loop bandwidth, which is all an R-L can say; the
  regulator's real loop is C3's job. Absent → `Assumption`.
- Oracles: one cap's series resonance `1/(2π√(L·C))` and minimum `|Z| = ESR`
  exact; mounting L of a standard 0402 + two vias vs the closed-form loop
  (and, with MFEM, a magnetostatic extraction — optional).

### B3 — Load impedance and contract

- Per load port: `Z(f)`, `pi_z_max_in_band` (worst over the claimed band),
  `pi_z_antiresonance` (each peak and its frequency), and which capacitors
  dominate each band (sensitivity `∂|Z|/∂site`, cheap from the reduced
  model).
- **Target impedance**, per load (a pin group) or per rail, in one of
  three forms — never a default:
  1. **Mask**: a typed **`ImpedanceMask`** — `(f, |Z|)` breakpoints,
     interpolated linearly in log-log between them, so the usual vendor
     shapes are direct (flat to a corner, then rising 20 dB/decade). Named
     and declared once, referenced by the role (`mask = "core_mask"`),
     because role params are strings and a list must not be encoded into
     one:
     ```nim
     impedance_mask "core_mask":
       100.kHz: 30.mohm
       10.MHz:  30.mohm
       100.MHz: 300.mohm
     ```
  2. **Flat** `targetZ` over `targetFrom`..`targetTo` (a two-point mask).
  3. **Derived** from stated `ripplePct` and the scenario transitions:
     `Z_t = V·ripplePct / ΔI` for the largest transition, flat.
  The claim holds only between the mask's first and last breakpoints.
- **`fMax`, the highest frequency of interest**, stated per rail
  (required for any AC claim). It sets the sweep stop, the AC cell size
  (≤ λ(fMax)/20 in the slowest dielectric), the macromodel fit band (C1),
  and a mask may not extend past it. Nothing above `fMax` is reported or
  claimed — and a mask that ends below it leaves the rest unclaimed, said
  in the report. `fMin` likewise (default: the VRM's stated loop bandwidth
  /10, else stated).
- `pi_rail` gains `mask`/`targetZ`/`ripplePct`/`fMin`/`fMax`; claims per
  load pin group, reported as worst margin to the mask (`pi_z_mask_margin`,
  dB, and the frequency where it occurs) as well as `pi_z_max_in_band`.
  **Distinct quantity from `power_rail.z_max_in_band`** (decision 5): that
  one is the rail node on a netlist, this one is a location on a board, and
  one name would let the weaker answer satisfy the stronger claim.
- Consistency oracle: a board whose planes are negligible vs
  `analyzePdn` on the equivalent lumped netlist (skips without ngspice).

### B4 — Decoupling optimisation

- **Search space: existing capacitor sites on the board** (a sourced
  board's writer refuses new footprints — `pcb/CLAUDE.md`), each assigned
  one catalogue capacitor whose case fits the footprint, or *do not
  populate*. A pre-layout mode takes a template instead: N candidate sites
  of stated mounting inductance, and returns how many of which value.
- **Fast evaluation**: the board is reduced once per frequency to the port
  matrix over (loads + sites + source); a candidate set is then a small
  Schur update per frequency, not a board solve.
- **Algorithm**: deterministic greedy (add the site/value that most reduces
  the worst violation) then local search (remove/swap until no single move
  improves), objective **total price** when the catalogue has prices,
  else **part count**, then **number of distinct values**. No stochastic
  methods (results must reproduce).
- Output: `verax decap designs/foo.nim --board=… --bom-catalog=…
  [--rail=NET] [--format=json]` — per site the chosen MPN or DNP, `Z(f)`
  margin before/after, and sites that do nothing (removal candidates).
  JSON is shaped so the BOM compiler can take it as an override (a later
  `--bom-lock`-like input; not in this plan).
- Oracles: a single site with a target only one value meets → that value;
  an infeasible target → reported infeasible with the best margin, never
  a "best effort" pass; result invariant under site order.

## Part C — Transient load steps

### C1 — Macromodel

- Vector fitting with **complex-conjugate poles** (widening `numeric/ratfit`,
  which fits real poles only — PDN resonances need complex ones) of the
  port matrix `Z(s)` from B3, common poles across entries.
- **Passivity**: check (`Re{eig Z(jω)} ≥ 0` on a dense sweep plus the
  Hamiltonian test) and enforce by residue perturbation; a model still
  non-passive after enforcement is refused — a non-passive model can grow
  without bound in time.
- Export as a **`Netlist` subcircuit** (Foster RLC realisation) so the
  existing SPICE path can run it (C3) without a `pi -> spice` edge.
- Oracles: fit error < 1 % of peak on B1's cavity case; a passive RLC
  ladder refitted is passive; time response of the exported subckt vs the
  inverse FFT of `Z(f)·I(f)`.

### C2 — Native load step

- Stimulus per load: a **state transition** from A0 (`sleep -> active`,
  its `ΔI` at the run's corner and its stated edge time), optional
  repetition/duty, or a PWL. Linear PDN by recursive convolution of the
  fitted model (the `si/engine/convline` technique), VRM as B2's R-L **plus
  an optional first-order loop** (`loopBandwidth` on the role) — stated
  as the simple model it is.
- Results per load: `pi_step_droop_v`, `pi_step_overshoot_v`,
  `pi_step_recover_s`, `pi_step_v_min` — distinct from `spice.load_step`'s
  `step_*` (different subject: a load location on a board). Measures from
  `verax/waveform`.
- Fast enough to sit inside B4 as an alternative objective (droop rather
  than `|Z|`) — an option, not the default.
- Oracles: lumped RLC under a step (exact); time-domain result vs IFFT of
  `Z·I` to < 1 %.

### C3 — Co-simulation with the regulator's model

- `analysis/analyses/pi.nim` replaces the ideal rail connection in the
  netlist with C1's subcircuit (ports bound to the regulator output and
  each load's pins) and runs the existing `spice.load_step` path — so a
  regulator with a real switching/loop model (`lt8640a_buck`) drives the
  extracted board. Needs `capTran`; skips without ngspice.
- Oracle: with an ideal-source regulator, C3 matches C2 to tolerance.

### C4 — Contract

- `pi_rail` gains `maxStepDroop`/`maxStepOvershoot`/`maxRecover`; the
  evaluator prefers C3 when a regulator model and ngspice exist, else C2,
  and the result says which ran (`Assumption`).

## Decisions

Reviewed with the user 2026-10-09.

1. **Native grid solver as the engine, MFEM as an opt-in backend later —
   open, awaiting the user.** MFEM is the better FE library; what it
   lacks here is everything around the solve:
   - *No mesher.* MFEM needs a conforming mesh; nothing in verax makes one
     (`fem/CLAUDE.md`: "no mesher"). A board's pours are thousands of
     polygons with reliefs and clearances, 35 µm thick over 100 mm. Either a
     constrained 2-D triangulator per layer (then coupling layers through
     vias, which does not map onto one MFEM finite-element space) or a full
     3-D mesh at a 3000:1 aspect ratio. Either is the largest single piece
     of work in the whole plan, and it is absent under both options.
   - *Not on the default path.* `cli.nim` may not import `fem/mfem`, and
     MFEM needs `nimble mfem` (minutes of C++). An MFEM engine means
     `verax check --board=` cannot judge PI claims on a stock install
     unless that rule changes.
   - *Solver speed is not where MFEM wins in our build.* Serial MFEM has no
     hypre (BoomerAMG needs `MFEM_USE_MPI`); it offers PCG with Jacobi/
     Gauss-Seidel smoothers — what A0 writes anyway. On a uniform grid a
     **geometric multigrid** preconditioner is short to write and makes the
     native solve O(N), so ~10⁶ unknowns in seconds.
   - *Where MFEM is better:* adaptive refinement at necks and corners,
     higher-order elements, true 3-D (current crowding in thick copper and
     via barrels), and a later full-wave path. Those are accuracy and
     generality, and they are why it stays as the oracle.
   Proposal: `pi` builds a solver-neutral conduction problem; the grid
   solver is the default backend; an MFEM backend (once a mesher exists)
   is opt-in and cross-checked against it.
2. **Load currents: power states (min/typ/max per pin group), design
   scenarios, and transitions** — revised per the user (A0 item 3).
3. **Ampacity: IPC-2221 closed form + the A3 simulated rise** — agreed.
4. **Solve the return net** — agreed.
5. **New `pi_*` quantities** rather than reusing `z_max_in_band` /
   `step_*` — explained to the user, awaiting confirmation. The registry
   enforces one producer per quantity (`contract/evaluate.registerEvaluator`
   raises otherwise), so reuse means replacing the netlist `pdn` evaluator;
   and the subjects differ (a rail node vs a load location on a board).
6. **Decap optimiser** (existing sites + template mode, cost then count,
   deterministic) — agreed, with targets as an **`ImpedanceMask`** over
   frequency and a stated **`fMax`** (B3).
7. **Defaults**, all recorded as `Assumption`s: cell 0.2 mm (DC) / derived
   from `fMax` (AC), plating 25 µm, ρ = 1.72e-8 Ω·m, h = 10 W/m²·K per
   face, FR-4 k = 0.8/0.3 W/m·K, unstated copper 35 µm.
8. **`numeric/` as the shared home** for `lu`/`ratfit`/`sparse`/`pcg`/
   multigrid — name and placement (below `pcb`).

## Order and dependencies

A0 → A1 → (A2 ∥ A3) → A4 is the first deliverable; Part B needs A0/A1's
raster and ports; Part C needs B3. Within B, B4 needs B1–B3 and the
catalogue widening. The `derating` move (B2) and `ratfit` widening (C1)
touch `spice`/`si` — each lands with its stage and re-runs those suites.
