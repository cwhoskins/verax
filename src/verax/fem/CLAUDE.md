# `fem` submodule

Interface to an external finite-element field solver (EM + thermal). Owns the problem statement, mesh vocabulary and backend contract; knows nothing about what question a field answers (that's `analysis`). Depends on `pcb`. **Skeleton: no backend (MFEM intended, opt-in per import) and no mesher.**

- **`types.nim`** — `FemProblem`/`Region`/`Material`/`BoundaryCondition`/`Excitation`. One `Material` carries constants for *both* physics (a pour is a conductor in EM and a spreader in thermal; separate types would drift). `validate` returns warnings rather than raising — a silent pass must not read as proof of a well-posed problem.
- **`mesh.nim`** — solver-neutral `Mesh`. **Coordinates are `float64` metres, not `pcb/units.Nm`** — mesh nodes don't land on the nm lattice. The single nm→m conversion is in `extrude`.
- **`backend.nim`** — `writeCase`/`solve`/`available`. `available()` exists so test skip logic lives in one place. `Field` is a real/complex object variant; `[]`/`cplx`/`mag`/`db` mirror `spice/backend`.
- **`extrude.nim`** — the one module importing `pcb`. Tracks are approximated by bounding boxes (no centre-line offsetting in `pcb/geometry` yet).
  - **`extrudeCopper` must skip `ckZone`** — `pcb/graph.addZone` pushes the *authored* outline as a `ckZone` record; meshing it would double-count copper and get the plane shape wrong.
  - **`extrudeZones` meshes `Zone.fills` and refuses per zone when `fills` is empty**, naming every such zone in one `FemError`. Never fall back to `Zone.outline` (it omits reliefs and clearances).
