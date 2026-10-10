# MFEM integration — stages 1–5: full-wave RF (vias, microstrip circuits, antennas)

**Status: plan only (2026-10-09). Decisions D1–D6 pending.** Builds on stage 0
(`docs/mfem_integration_plan.md`: shim, `nimble mfem`, Laplace ladder) and
discharges `docs/rf_analysis_plan.md` Phase 6 ("FEM full-wave, sequenced").

## Targets

1. **Via simulation** — S-parameters of a via transition, delay per via, and a
   fitted lumped model (pi L/C + stub line) that can replace the closed-form
   `pcb/via.ViaModel` in `si/`.
2. **Microstrip circuits** — S-parameters of planar distributed circuits:
   Wilkinson divider (with its isolation resistor), single/double stub tuning,
   quarter-wave transformers; authored parametrically or cut from a `Pcb`.
3. **Basic antennas** — input impedance / S11 / bandwidth, radiation pattern,
   directivity, gain and radiation efficiency of printed antennas (patch,
   printed monopole/IFA) and the canonical dipole/monopole.

All three are the same solve — **time-harmonic Maxwell, E-field, Nédélec
elements, complex, one factorization per frequency, one RHS per port** — with
different geometry, boundaries and post-processing. The plan builds that solve
once and specialises it.

## What exists and what is missing

| Have | Missing (this plan) |
| --- | --- |
| Shim + dynlib load + `nimble mfem` (serial, shared, exceptions on) | A complex full-wave entry point; a serial direct solver (MFEM has none built in) |
| `Mesh` with `ekTet4`/`ekPrism6` and named `boundaryFaces` | **A mesher.** `toMfem` only generates boundary elements from outer faces — PEC sheets and ports are *internal* faces |
| `extrude.nim` regions from a `Pcb`, zone fills enforced | Real track outlines (tracks are bounding boxes; arcs and 45° runs are wrong); via barrels |
| `pcb/impedance` (closed-form Z0), `pcb/via` (Johnson closed-form) | A field-solved provenance for either |
| `touchstone/` reader + `SParams` | A Touchstone **writer** |
| `si/engine/sblock` (Touchstone 2-port in transient) | A way for `si/board` to take a per-via override |
| RF annotations `antenna_gain_dbi`, `antenna_efficiency` | Anything that computes them |

## Architecture

```
units, touchstone                         (below everything)
  <- pcb  <- fem/geom2d      polygons: stroke outlines, booleans, arcs -> segments
           <- fem/cdt         constrained Delaunay + quality refinement (pure Nim)
           <- fem/layered     2.5-D mesher: CDT in xy, extruded through z-slices -> Tet4
           <- fem/rf/*        port defs, problem builders, S-matrix assembly, far field
           <- fem/mfem        shim binding (ABI 2: full-wave entry points)
  <- analysis/analyses/{via_fem, rfcircuit_fem, antenna}.nim   interpretation
  <- si/board                 accepts via overrides as data (no si -> fem edge)
```

- `fem` keeps its rule: it produces S-matrices and fields, **not** verdicts.
  "Delay per via", "gain in dBi", "isolation at f0" are `analysis/`.
- **No `si -> fem` edge.** `si/board` gains `viaOverrides: Table[ViaKey,
  ViaOverride]` (a fitted `ViaModel` *or* an `SParams` block for `sblock`);
  `analysis` fills it from `fem` results. Same pattern as RF Phase 6's
  provenance obligation: Z0/S arrive as authored, closed-form, `mlin`, or
  **field-solved**, under one vocabulary, always tagged with provenance.
- `fem/rf` imports `touchstone` for `SParams`; `touchstone` gains `writer.nim`.
- **Solves are never implicit.** `verax check` does not start a multi-minute
  solve. A solve is an explicit command (`verax fem via|circuit|antenna ...`)
  or library call, and writes a cached artifact (`.sNp` + JSON with
  provenance, geometry fingerprint, mesh stats, convergence) under
  `~/.cache/verax/fem/<fingerprint>/` or `-o`. Checks read artifacts; a stale
  fingerprint is `notEvaluated` naming the command to re-run.

### Why a 2.5-D mesher, not gmsh

PCB geometry is layered: every surface is either horizontal (copper on a
layer, dielectric interfaces) or vertical (via barrels, port planes, board and
air-box walls). A constrained Delaunay triangulation of every xy outline,
extruded through every stack-up interface (plus air slices above/below),
gives a conforming mesh with all copper as mesh faces — exactly what PEC
sheets and lumped ports need. Prisms are split into 3 tets with a
global-vertex-index rule (keeps neighbours conforming). Pure Nim, no new
dependency, deterministic (stable fingerprints). It covers all three targets;
it does **not** cover off-axis wire antennas, connectors or 3-D bodies — those
wait for an optional gmsh importer (later, D3).

### Conductors and ports (first cut)

- **Copper = zero-thickness PEC sheets** (internal boundary faces), via
  barrels = PEC vertical faces on the drill polygon (drill interior removed).
  Thickness error is ~t/h on Z0; recorded as an `Assumption`. Conductor loss
  via a surface-impedance (Leontovich) BC is stage 6.
- **Dielectric loss** from `Material.lossTangent` (complex εr) — free.
- **Lumped ports**: a rectangle of mesh faces between a trace end and its
  reference, with a resistive termination `Z_ref` and a uniform-E
  excitation (MFEM/Palace-style lumped port). V, I per port → Z/Y → S.
  Wave ports (2-D eigenmode on the port plane) are stage 6.
- **Lumped RLC elements** (the Wilkinson resistor, a matching capacitor):
  the same surface-impedance rectangle with `Z(ω) = R + jωL + 1/(jωC)`,
  not excited.
- **Outer boundary**: PEC (shielded), first-order absorbing (Robin
  `n×∇×E − jk n×(n×E) = 0`), or PML (stage 5).

## Stages

Each stage has a validation ladder where the first rungs have **exact**
answers, so a failure is a bug, not discretisation (stage 0's discipline).
Every S-result is also checked for **reciprocity** (`|Sij − Sji|`) and
**passivity** (eigenvalues of `I − SᴴS` ≥ −tol) — reported, never silent.

### Stage 1 — Geometry, 2-D mesher, field-solved Z0 (no full-wave yet)

Low risk; reuses the existing H1 Laplace path; gives the RF-plan's
"field-solved Z0" provenance immediately and is what lumped-port
de-embedding needs later.

- `fem/geom2d.nim`: stroke → polygon outline (round/square caps, arcs
  segmented to a chord tolerance), polygon union/difference for a layer,
  point-in-polygon. Fix `extrude.extrudeCopper` to use real outlines.
- `fem/cdt.nim`: constrained Delaunay + Ruppert refinement with a size field
  (min angle ~25°, edge length ≤ `h(x,y)`); refuses self-intersecting input
  by name.
- `fem/rf/crosssection.nim`: 2-D cross-section of a line (or coupled pair)
  from `pcb/tline.LineSpec`; two H1 electrostatic solves (with dielectric,
  and with vacuum) → `C`, `C0` → `Z0 = 1/(c·√(C·C0))`, `εeff = C/C0`;
  coupled: odd/even. Shim ABI 2 adds a Poisson solve with per-attribute ε and
  per-boundary-attribute Dirichlet values.
- `touchstone/writer.nim` (round-trips through the reader).

Ladder: (1) coax, `Z0 = 60/√εr · ln(b/a)` exact → error falls at the
expected rate under refinement; (2) parallel plate, wide strip → `εr·w/h`;
(3) microstrip and stripline vs `pcb/impedance` (Hammerstad-Jensen,
IPC-2141) within their stated accuracy; (4) coupled microstrip odd/even vs
`coupledModes`. Ships `field_solved` as a Z0 provenance in `pcb/impedance`
consumers (via `analysis`).

### Stage 2 — Layered 3-D mesher + full-wave solve

- `fem/layered.nim`: `LayeredGeometry` (stack of z-slices with materials;
  per-layer xy polygons tagged PEC/port/RLC/void; via drills spanning a z
  range) → `Mesh` of Tet4 with internal boundary faces tagged. Size field
  from `λ_min/10` in each dielectric plus refinement near metal edges.
- `fem/mfem` ABI 2 (bump `VX_MFEM_ABI_VERSION` + `shimAbiVersion`):
  - `vx_mesh_from_arrays_bdr`: explicit boundary elements + attributes,
    including internal faces.
  - `vx_fullwave_setup(mesh, order, materials[attr]{εr', εr'', μr, σ},
    boundaries[battr]{PEC | absorbing | port{Zref, e-direction} |
    rlc{R,L,C, e-direction}}) -> vx_fw*`
  - `vx_fullwave_solve(fw, freq, nports, Vout, Iout)` — assemble
    `ComplexSesquilinearForm` (curl-curl − k²ε + jωμσ + boundary terms),
    factor once with `ComplexUMFPackSolver`, solve once per port.
  - `vx_fullwave_export(fw, path)` — ParaView/GLVis output for debugging.
- `fem/rf/fullwave.nim`: `FemProblem(pkFullWave)` + `Mesh` → sweep →
  `SParams` (Z from V/I, renormalised to each port's `Z_ref`). Discrete
  sweep; interpolation between points is linear and stated.
- `FemProblem`: `Excitation` already has `impedance`; add explicit port
  geometry rather than overloading `regions` (new `ports` field, per the
  no-field-overloading rule).

Ladder: (1) curl-curl manufactured plane-wave solution in a box → P1/P2
convergence rates; (2) PEC cavity: driven response peaks at the analytic
TE101 frequency; (3) a lumped port terminated by an equal lumped resistor
across a short parallel-plate gap → `|S11| < −30 dB` at low f;
(4) uniform microstrip thru: `|S21| ≈ 1`, `∠S21 = −β·L` with `εeff` from
stage 1; (5) reciprocity/passivity invariants on all of the above.

### Stage 3 — Via studies (target 1)

- `fem/rf/viastudy.nim`: builds a `LayeredGeometry` from `pcb/via.ViaGeometry`
  (pad, antipad, drill, entry/exit layers, backdrill residual, return vias
  at a stated pitch) or from a `Pcb` hole + its two connecting tracks.
  Feed lines of known length each side; lumped ports at their far ends.
- **De-embedding**: remove the feed lines using `Z0`/`γ` from the stage-1
  cross-section (or a 2×-thru of the same feeds, solved alongside — chosen
  per study, recorded).
- `analysis/analyses/via_fem.nim` produces, per via:
  - `.s2p` (de-embedded) and the raw one;
  - **delay**: group delay of de-embedded S21 at low frequency, and
    *excess* delay vs. a straight line of the same length;
  - **lumped model**: pi `C/2–L–C/2` fitted from the low-frequency ABCD
    (`B ≈ jωL`, `C ≈ jωC_total`), plus the stub as a line fitted to the
    stub-resonance notch → a `ViaModel` with `provenance = field_solved`;
  - fit residual over the band, so "lumped is good to X GHz" is a number.
- `si/board`: `viaOverrides` (fitted model or S-block via `sblock`).
- CLI: `verax fem via designs/foo.nim --board=foo.kicad_pcb [--net=N]
  [--fmax=20G] -o out/` and a stand-alone `--via-geom=...` form.

Ladder: (1) through-via with no stub vs. a coax of the same drill/antipad
(near-exact Z0 for a coaxial via); (2) stub notch at the quarter-wave
frequency `c/(4·L_stub·√εr)` within mesh tolerance; (3) backdrilled vs.
not — notch moves/disappears; (4) lumped fit vs. `pcb/via` Johnson model
(expect tens of percent, documented, not asserted); (5) an `si_spi.nim`
transient with closed-form vs. field-solved vias, differences reported.

### Stage 4 — Microstrip circuits (target 2)

- `fem/rf/primitives.nim`: parametric builders from design values —
  Wilkinson (`f0`, `Z0`, ring or meander arms, resistor footprint), open/short
  single stub and double stub, quarter-wave transformer, (optional) branch-line
  coupler. Each returns a `LayeredGeometry` plus port and RLC definitions.
- `fem/rf/cut.nim`: a `Pcb` region by net(s) — the copper of the named nets,
  the reference plane under them, the stack-up, ports at the pads of the
  named components (an `rf_port` role from RF Phase 3, or explicit pins),
  and passives on the net as lumped RLC from their `spec:` values.
  Refuses (named) where the cut is ambiguous: copper of another net crossing
  the window, a part on the net with no value.
- `analysis/analyses/rfcircuit_fem.nim`: S-matrix → `return_loss`,
  `insertion_loss`, `isolation`, `vswr` quantities (RF-plan names) with
  `field_solved` provenance; claims evaluated at the role's frequencies.

Ladder: (1) quarter-wave transformer — `|S11|` minimum at `f0` (ideal
network theory); (2) open stub — notch at `f0` where `L = λ/4·(√εeff)`,
shifted by the open-end correction (compared to Hammerstad's Δl formula);
(3) Wilkinson at `f0`: `|S21| = |S31| ≈ −3.01 dB` + dielectric loss,
`|S23| < −20 dB`, `|S11| < −20 dB`, symmetry `S21 = S31` to solver
precision; (4) when RF Phase 3 ships, the same circuits vs ngspice `mlin`.

### Stage 5 — Antennas (target 3)

- Radiation boundary: first-order absorbing BC (stage 2) at ≥ λ/4 from the
  antenna, then **PML** (complex-stretched coordinates as material tensors;
  MFEM ex25 is the reference) as the default for pattern accuracy.
- `fem/rf/farfield.nim` + shim `vx_fullwave_farfield`: near-to-far-field
  transform over a closed Huygens surface (the box faces inside the PML),
  evaluated on a θ/φ grid → `E_θ`, `E_φ`.
- `analysis/analyses/antenna.nim`: `Z_in`, S11 vs frequency, −10 dB
  bandwidth, resonant frequency, directivity, **gain** (`4π U / P_accepted`),
  **radiation efficiency** (`P_rad / P_accepted`, with `P_rad` from the
  far-field integral *and* from the Poynting flux through the Huygens surface
  — their disagreement is reported as a mesh-quality figure), pattern cuts
  (E/H plane) as data. Feeds the existing `antenna_gain_dbi` /
  `antenna_efficiency` annotations as checkable claims.
- Primitives: rectangular patch (inset or probe/via feed), printed monopole
  over a ground clearance, IFA.

Ladder: (1) Hertzian (short) dipole far field — `sin θ` pattern,
`D = 1.5` (1.76 dBi) exact; (2) half-wave dipole (thin strip, equivalent
radius `w/4`): `Z_in ≈ 73 + j42 Ω` at `L = λ/2`, `D = 2.15 dBi`;
(3) quarter-wave monopole over a large ground: `Z_in ≈ 36.5 Ω`, `D ≈ 5.15 dBi`;
(4) patch: resonance vs Balanis cavity-model `f_r` within its known few-%
error; pattern broadside.

### Stage 6 — Later, not scheduled

Wave ports (2-D port eigenmode; removes lumped-port parasitics); conductor
loss (surface impedance from `σ`, roughness from the RF annotations); thick
copper; adaptive frequency sweep / model-order reduction; adaptive mesh
refinement on an error indicator; MPI + hypre AMS for large problems; a gmsh
`.msh` importer for non-layered geometry; Palace as an independent oracle on
the stage 3–5 ladders.

## Decisions (pending)

| # | Question | Recommendation |
| --- | --- | --- |
| D1 | Write the full-wave solve in our shim, or drive **AWS Palace** (MFEM-based, does lumped/wave ports, S-params, far-field) as a subprocess? | **Own shim.** Keeps the in-process call path stage 0 proved, serial, small. Palace needs MPI + hypre + MUMPS/SLEPc and a heavy build; better as a later cross-check oracle. |
| D2 | Serial direct solver: MFEM has none built in; indefinite Maxwell needs one. | **`MFEM_USE_SUITESPARSE=ON` (UMFPACK)**. Use system `suitesparse-devel` when present (it is in openSUSE, not installed here); `nimble mfem` builds it from a pinned tarball otherwise. Changes the cached MFEM build. |
| D3 | Mesher: in-house 2.5-D CDT + extrusion, or gmsh? | **In-house**, for the reasons above (layered geometry, stdlib-only, deterministic, gmsh not installed). gmsh importer in stage 6. |
| D4 | Copper as zero-thickness PEC sheets first? | **Yes**, with the thickness error stated as an `Assumption`; surface impedance and thick copper in stage 6. |
| D5 | Lumped ports first, wave ports later? | **Yes.** Lumped ports + de-embedding cover all three targets at PCB frequencies. |
| D6 | How results reach `verax check`. | **Explicit `verax fem ...` command → cached artifact**; checks read it and report `notEvaluated` (with the command) on a stale fingerprint. No implicit solves. |

## Risks

- **Problem size, serial.** Rough Tet4/ND1 counts: a via study ~50–200 k
  unknowns (UMFPACK, seconds–minutes per frequency); a 2.4 GHz Wilkinson with
  air box ~200–500 k; an antenna with PML ~0.5–1.5 M — at the edge of a
  serial direct solve (memory first). Mitigations in order: ND order 1 with
  graded mesh; symmetry planes (PEC/PMC) for symmetric circuits/antennas;
  then stage 6 MPI.
- **Lumped-port parasitics** dominate a via's tiny L/C if not de-embedded —
  why stage 1's cross-section solve comes first.
- **CDT robustness** (near-collinear edges from arc segmentation, slivers
  at copper/antipad tangency): exact orientation predicates (Shewchuk-style
  adaptive) from the start; snap to the nm lattice before triangulating.
- **Frequency sweep cost** scales with points; S-params between sweep points
  are interpolated, which can miss a sharp stub notch — sweep density is a
  stated parameter and notches are refined by bisection on `|S21|`.

## Docs / bookkeeping per stage

`fem/CLAUDE.md` (mesher, ABI 2, PEC-sheet convention); root `CLAUDE.md`
(new `verax fem` commands, skipped-test list); `docs/architecture.md` (new
edges `touchstone <- fem`, `fem <- analysis`, via overrides into `si`);
`docs/rf_analysis_plan.md` Phase 6 → points here; examples
`examples/fem_{coax_z0,via,wilkinson,patch}.nim` (not in `nimble test`).
