# `fem/` — the field-solver interface

A problem statement, mesh vocabulary and backend contract for EM and thermal
field solves over a board, plus an opt-in MFEM call path at stage 0 (load +
a validation Laplace solve). No mesher yet. Imports `netlist` (for `Net`) and,
in `extrude.nim` only, `pcb`.

## Data structures

| type | shape | notes |
|---|---|---|
| `FemProblem` | name, `ProblemKind` (electrostatic, magnetostatic, full-wave, thermal steady/transient), `regions`, `materials: OrderedTable`, `boundaries`, `excitations`, `frequencies`, `ambient`, attrs | value object; `addMaterial`/`addRegion` validate references and z-order |
| `Material` | εr, μr, σ, k, ρ, cp, tanδ in one record | both physics on one material, on purpose |
| `Region` | name, material name, optional `Net`, layer name, `zLow..zHigh`, `outline: seq[(x, y)]` | a prism: one 2-D outline extruded |
| `BoundaryCondition` | `BcKind` + `value`, `coefficientA/B`, region names | one record for all kinds |
| `Excitation` | regions, magnitude, frequency, impedance | |
| `Mesh` / `Node` / `Element` | float metres; element kind + node indices in backend canonical order; region/boundary tags | solver-neutral |
| `Field` | **variant** on `complexValued` (real `values` / complex `cvalues`), `FieldKind`, unit, per-node vs per-element | mirrors `spice/backend.SimVector` |
| `FemResult` | mesh, `fields`, `scalars`, convergence info | |

## Patterns

**Interface first, backend later.** The problem/mesh/result types and the
`writeCase`/`solve`/`available` contract exist before any physics does, so
the board side (`extrude`) and the analysis side can be built against them.

**Validation that warns.** `validate` returns a list of reasons a problem is
ill-posed instead of raising; an empty list is not proof of well-posedness,
and the doc says so.

**Refuse rather than approximate geometry.** `extrudeZones` meshes only
derived `Zone.fills` and refuses (naming every zone) when fills are empty,
rather than meshing the authored outline.

**A dynamically loaded, ABI-checked native shim.** `std/dynlib` (never the
`{.dynlib.}` pragma, which aborts at start-up when missing), a versioned
`extern "C"` shim, `loadStatus()` reporting the first broken link in the
toolchain → file → dlopen → ABI → version chain, exceptions caught at every
shim entry point.

**One unit conversion.** `Nm → metres` happens once, in `extrude`; the mesh
is float metres because nodes don't land on the nm lattice.

## What this buys

- **The board model can be meshed without the solver being finished**, and
  the eventual MFEM backend has a fixed target.
- **Optional heavy dependency without contaminating the build.** Neither the
  `fem` hub nor the CLI imports `fem/mfem`; tests skip by one `available()`
  check; a missing library is a status, not a crash.
- **Consistency with the simulator result type** (`Field` mirrors
  `SimVector`), so post-processing code reads alike.

## Critique

1. **`Region.outline` has no holes.** A region is one simple polygon
   extruded, while `pcb.Polygon` has holes and a real pour's fill has many
   (clearances, thermals). Either a filled area becomes many regions or the
   holes are lost; `extrude` approximates tracks by bounding boxes today. The
   problem type is narrower than the geometry it is fed from.

2. **`BoundaryCondition` and `Excitation` are flat records over every kind.**
   `value`, `coefficientA`, `coefficientB` mean different things per `BcKind`
   (Dirichlet value, Robin a/b, convection h…). A variant per kind would make
   "a port without an impedance" or "a Robin BC without coefficients"
   unrepresentable instead of a `validate` warning.

3. **Zero means unknown in `Material`.** `validate` warns when `kThermal ==
   0` or `epsR == 0 and sigma == 0`. Zero conductivity is a real value (an
   insulator in EM), so the sentinel is ambiguous (README P7).

4. **Regions reference materials and boundaries reference regions by name.**
   Checked at `addRegion` and in `validate`, but nothing checks a material
   removed or renamed later. Consistent with README P5.

5. **`Capability` has no FEM entry.** When a field solve feeds a contract
   quantity it will need a capability (it needs a native library and can take
   minutes), and `Capability` is a closed enum in `contract`.

6. **Material duplicates `pcb.StackMaterial`** (εr, tanδ). Reasonable — FEM
   needs more fields — but a stack-up material's constants are copied, not
   referenced, so a board edit doesn't reach a problem already built.

## Things that look odd but are right

- One `Material` for both physics: a pour is a conductor in EM and a
  spreader in thermal; two types would drift.
- `MFEM_USE_EXCEPTIONS=ON` is load-bearing: otherwise a bad mesh `abort()`s
  the verax process.
- The shim is never built on demand by the binding: a library call must not
  start a multi-minute compile.
