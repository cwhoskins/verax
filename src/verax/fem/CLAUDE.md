# `fem` submodule

Interface to an external finite-element field solver (EM + thermal). Owns the problem statement, mesh vocabulary and backend contract; knows nothing about what question a field answers (that's `analysis`). Depends on `pcb`. **Skeleton: the only backend is `fem/mfem`, stage 0 (call path + a validation Laplace solve), opt-in per import; no mesher.**

- **`types.nim`** — `FemProblem`/`Region`/`Material`/`BoundaryCondition`/`Excitation`. One `Material` carries constants for *both* physics (a pour is a conductor in EM and a spreader in thermal; separate types would drift). `validate` returns warnings rather than raising — a silent pass must not read as proof of a well-posed problem.
- **`mesh.nim`** — solver-neutral `Mesh`. **Coordinates are `float64` metres, not `pcb/units.Nm`** — mesh nodes don't land on the nm lattice. The single nm→m conversion is in `extrude`.
- **`backend.nim`** — `writeCase`/`solve`/`available`. `available()` exists so test skip logic lives in one place. `Field` is a real/complex object variant; `[]`/`cplx`/`mag`/`db` mirror `spice/backend`.
- **`extrude.nim`** — the one module importing `pcb`. Tracks are approximated by bounding boxes (no centre-line offsetting in `pcb/geometry` yet).
  - **`extrudeCopper` must skip `ckZone`** — `pcb/graph.addZone` pushes the *authored* outline as a `ckZone` record; meshing it would double-count copper and get the plane shape wrong.
  - **`extrudeZones` meshes `Zone.fills` and refuses per zone when `fills` is empty**, naming every such zone in one `FemError`. Never fall back to `Zone.outline` (it omits reliefs and clearances).

## `mfem.nim` + `mfem/` — MFEM call path (stage 0)

`nim c` -> `std/dynlib` -> `libverax_mfem-<abi>-<mfem ver>-<src hash>.so` (an `extern "C"` shim, `mfem/shim.cpp`) -> `libmfem`. Plan and rationale: `docs/mfem_integration_plan.md`. Neither the `verax/fem` hub nor `cli.nim` may import `fem/mfem`.

- **`nimble mfem`** (`mfem/build.nim`): downloads the pinned MFEM v4.10 tarball (`codeload.github.com`; `github.com/.../archive` timed out from the dev host), verifies its sha256, builds **serial shared** MFEM into `~/.cache/verax/mfem-4.10/install` (`$VERAX_CACHE` overrides the root), then compiles the shim into `~/.cache/verax/mfem/`. **`nimble mfemcheck`** prints `loadStatus()` and asserts it when a toolchain is found.
- **`$MFEM_DIR`** = an install prefix (has `share/mfem/config.mk`); it wins over the cache. A set-but-wrong `$MFEM_DIR` is "not found", never a silent fall-through to the cache. Compile flags are read from `config.mk` (with `$(VAR)` expanded -- they go to `g++`, not `make`).
- **`MFEM_USE_EXCEPTIONS=ON` is load-bearing**: without it `mfem_error` `abort()`s and a bad mesh kills the verax process. Every shim entry point is one `try/catch(...)` returning nonzero + `vx_mfem_last_error()`. `MFEM_USE_MPI`, `MFEM_USE_EXCEPTIONS`, `BUILD_SHARED_LIBS` all default OFF in 4.10, so all are passed explicitly.
- **Load with `std/dynlib`, never the `{.dynlib.}` pragma**: the pragma aborts the process at start-up when the library is missing, which would break `available()`'s skip semantics. `loadStatus()` walks toolchain -> shim file -> dlopen -> ABI -> version and reports the first broken link; `available()` never raises.
- The shim is **not built on demand** by the binding (a library call must not start a multi-minute compile); it says "run `nimble mfem`". Bump `VX_MFEM_ABI_VERSION` (shim.h) **and** `shimAbiVersion` (build.nim) together on any signature change.
- `toMfem` takes one first-order element kind per mesh (Tri3/Quad4/Tet4/Hex8); the shim finalizes with `fix_orientation`, so negative-Jacobian elements are flipped (MFEM prints "Elements with wrong orientation: n / m (fixed)"). Region `r` -> MFEM attribute `r + 2`.
- Tests: `tests/test_fem_mfem_load.nim` first, then the ladder `tests/test_fem_mfem.nim` (linear Laplace solution must be reproduced to ~1e-15 by P1/P2; any real error is a bug).
