# MFEM integration — stage 0: dependency + call path

Goal: prove verax can **build against, load, and call** MFEM, and get a
known-exact answer back into a `fem.FemResult`. No board meshing, no
evaluators, no physics beyond a validation Poisson solve. Everything else in
`fem/` stays as-is.

## Constraints that shape the design

- **No dependencies beyond the Nim stdlib** (CLAUDE.md). MFEM is not a nimble
  package and must not become a build-time requirement of `verax`.
- **`nim c`, not `nim cpp`.** MFEM is C++. Binding it with `importcpp` would
  force every program that imports `verax/fem/mfem` (and the CLI) to compile as
  C++. Rejected.
- **Absent toolchain = skip, not fail**, exactly like `$NGSPICE_SRC` /
  `ngspice`. `fem/backend.available()` is where that decision lives.
- MFEM is **not packaged on openSUSE Tumbleweed** (`zypper se mfem`: nothing;
  `hypre-devel` exists but is not needed for a serial build).

## Decision: a C-ABI shim, loaded at runtime

```
verax (nim c)  --std/dynlib-->  libverax_mfem.so  (extern "C", g++)  --links-->  libmfem
```

- `src/verax/fem/mfem/shim.h` / `shim.cpp`: a small `extern "C"` surface over
  MFEM. Opaque handles, plain arrays in/out, integer status codes.
- Built **separately** from verax (a `buildShim` proc + nimble task, same
  pattern as `spice/xspice/build.buildCodeModel`), cached under
  `~/.cache/verax/mfem/`.
- Loaded with `std/dynlib.loadLib`/`symAddr`, **not** the `{.dynlib.}`
  pragma — the pragma aborts the whole process at start-up when the library is
  missing, which would break `available()`'s skip semantics and the CLI.

Rejected alternatives: `importcpp` (above); `{.compile: "shim.cpp".}` from Nim
(links with `gcc`, needs MFEM's flags threaded into every verax build);
subprocess driver exchanging files (viable later for `writeCase`/debugging,
but doesn't prove an in-process call, which is this stage's point).

## Steps

### 1. Fetch and build MFEM (dependency management)

`src/verax/fem/mfem/build.nim`, mirroring `xspice/build.nim`:

- `findMfem(mfemDir = ""): MfemToolchain` — `$MFEM_DIR` wins; else
  `~/.cache/verax/mfem-<ver>/install`; else empty (→ unavailable).
  Reads `share/mfem/config.mk` from the install for `MFEM_CXXFLAGS`,
  `MFEM_INCFLAGS`, `MFEM_TPLFLAGS`, `MFEM_EXT_LIBS` rather than hard-coding
  flags.
- `nimble mfem` task: download the **pinned** release tarball from GitHub,
  verify its sha256, then CMake. Pins (verified 2026-10-06), as `const`s in
  `build.nim`:
  - tag `v4.10` → commit `d964264cdb9a13e94a201b6c236c7721e0c8765f`
  - URL `https://codeload.github.com/mfem/mfem/tar.gz/refs/tags/v4.10`
    (unpacks to `mfem-4.10/`)
  - sha256 `d5aabe991b8b5569aa26e2b5d4b59ac617ee10ebac3d45fd6ff9c74b2c1a47dd`

  `github.com/.../archive/...` timed out from this host while `codeload` and
  `git ls-remote` worked; use `codeload` directly.

  ```
  cmake -S mfem-4.10 -B build -DCMAKE_BUILD_TYPE=Release \
        -DMFEM_USE_MPI=OFF -DMFEM_USE_EXCEPTIONS=ON \
        -DBUILD_SHARED_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX=~/.cache/verax/mfem-4.10/install
  cmake --build build -j && cmake --install build
  ```

  - **Serial only** for stage 0. MPI/hypre/METIS are a later, separate decision.
  - In 4.10's `config/defaults.cmake`, `MFEM_USE_MPI`, `MFEM_USE_EXCEPTIONS`
    and `BUILD_SHARED_LIBS` all default `OFF` — pass every one explicitly.
    `config.mk` installs to `<prefix>/share/mfem/config.mk`.
  - **`MFEM_USE_EXCEPTIONS=ON` is load-bearing**: otherwise `mfem_error`
    calls `abort()` and a bad mesh kills the verax process. With it, the shim
    catches `mfem::ErrorException` (and `std::exception`) at every entry point.
  - Shared + PIC so the shim `.so` can link it; `rpath` the shim to the install
    `lib/` so no `LD_LIBRARY_PATH` is needed.

### 2. The shim (`shim.h` / `shim.cpp`)

Minimum surface, in the order the tests exercise it:

```c
int         vx_mfem_abi_version(void);          // shim<->Nim ABI check
const char* vx_mfem_version(void);              // mfem::GetVersionStr()
const char* vx_mfem_last_error(void);           // thread_local buffer

typedef struct vx_mesh vx_mesh;
int  vx_mesh_cartesian_2d(int nx, int ny, double sx, double sy, vx_mesh** out);
int  vx_mesh_from_arrays(int dim, int nverts, const double* xyz,
                         int nelem, int elemGeom, const int* conn,
                         const int* attr, vx_mesh** out);
int  vx_mesh_counts(const vx_mesh*, int* nv, int* ne, int* nbe);
void vx_mesh_free(vx_mesh*);

// -lap(u) = 0, u = g on boundary, H1 order p; nodal values out.
int  vx_solve_laplace_dirichlet(const vx_mesh*, int order,
                                const double* bcCoeffs /* g = a + bx + cy + dz */,
                                double* nodalOut, int nodalLen,
                                double* residualOut, int* itersOut);
```

Rules: every entry point is `noexcept` with a `try/catch` returning nonzero +
`vx_mfem_last_error()`; no C++ type crosses the boundary; caller owns output
buffers; `vx_*_free` for every handle.

Built by `buildShim(tc: MfemToolchain): string` → `g++ -shared -fPIC
-std=c++17 shim.cpp $MFEM flags -Wl,-rpath,...` into
`~/.cache/verax/mfem/libverax_mfem-<abi>.so`; rebuild when `shim.cpp` hash or
MFEM version changes (encode both in the filename).

### 3. Nim binding (`src/verax/fem/mfem.nim`)

- Loads the shim via `std/dynlib` on first use; checks `vx_mfem_abi_version`.
- `available*(): bool` — shim found, loads, ABI matches. Never raises.
- `mfemVersion*(): string`.
- `MfemMesh` wrapping `vx_mesh*` with `=destroy` → `vx_mesh_free`, `=copy`
  disabled.
- `toMfem*(m: Mesh): MfemMesh` — translate verax `Mesh` (Tri3/Quad4/Tet4/Hex8
  only; raise `FemError` on the rest). **Node-order audit needed**: verax says
  "backend's canonical local order", so document MFEM's order for each kind
  in `mesh.nim` and check orientation (MFEM requires positive-Jacobian
  elements; `Mesh::FinalizeTopology` / `CheckElementOrientation(true)`).
- Status codes → `FemSolveError` carrying `vx_mfem_last_error()`.
- Not imported by `verax/fem` hub; opt-in via `import verax/fem/mfem`.
  `cli.nim` must not import it in this stage.

### 4. Validation ladder (`tests/test_fem_mfem.nim`)

Skipped with a message when `available()` is false. Each rung isolates one
failure class:

| # | Test | Proves |
|---|------|--------|
| 1 | `mfemVersion()` starts with `"MFEM v4.10"` | shim built, `.so` resolves, rpath works |
| 2 | ABI mismatch → `available()` false, no crash | load-failure path is graceful |
| 3 | `vx_mesh_cartesian_2d(4,4,…)` → 25 verts, 16/32 elems | object lifetime across the boundary |
| 4 | Element with a bad node index → `FemSolveError` with MFEM's message, process alive | exceptions caught, not `abort()` |
| 5 | Laplace on unit square, `g = 1 + 2x - 3y`, order 1 → max nodal error < 1e-10 | a real solve; linear solution is reproduced *exactly* by P1, so any error is a bug, not discretisation |
| 6 | Same as 5 but mesh built in Nim (`Mesh` of Tri3) → `toMfem` → solve | the verax→MFEM translation path `solve()` will use |
| 7 | Same as 5 on a Tet4 cube, order 2 | 3-D + higher order |

**Load smoke test — `tests/test_fem_mfem_load.nim`** (separate file, small,
the first thing to run when anything above fails):

- `mfem.loadStatus*(): MfemLoadStatus` — `object` with `toolchainFound`,
  `mfemDir`, `shimPath`, `shimExists`, `loaded`, `loadError` (the
  `dlerror`-equivalent text from `std/dynlib`), `abiExpected`, `abiGot`,
  `version`. `available()` is `loadStatus().loaded and abi matches`.
  `$` renders it as a short multi-line report.
- The test always `echo`s that report. If no toolchain is found it prints
  `SKIP: <report>` and exits 0. If a toolchain **is** found, it asserts
  `shimExists`, `loaded`, ABI match, and `version.startsWith("MFEM v4.10")` —
  a found-but-broken install is a failure, not a skip.
- `nimble mfemcheck` task: compile + run this file, so "is MFEM wired up?"
  is one command.

Plus an unconditional test (no MFEM needed) that `available()` is false and
doesn't raise when `$MFEM_DIR` points nowhere.

### 5. Docs / bookkeeping

- `fem/CLAUDE.md`: shim architecture, `$MFEM_DIR`, the exceptions flag, the
  dynlib-not-pragma rule.
- Root `CLAUDE.md` "Skipped, not failed" line: add `tests/test_fem_mfem.nim`
  needs `$MFEM_DIR` or `nimble mfem`.
- `docs/architecture.md` line ~71: "no backend yet" → "MFEM call path only".
- `examples/fem_laplace.nim` (not in `nimble test`).

## Out of scope (next stages)

Implementing `backend.solve(FemProblem, Mesh)` for real physics; a mesher
(gmsh or MFEM's own) and the `extrude` → mesh path; electrostatic C-extraction
/ DC IR-drop / thermal; MPI/hypre; `writeCase` (MFEM `.mesh` + GLVis output is
a cheap later add); an `analysis/evaluators/` hook; CI.

## Decisions (user, 2026-10-06)

1. Pin the `v4.10` release (pins above).
2. `nimble mfem` downloads from GitHub.
3. Shared `libmfem.so` (`BUILD_SHARED_LIBS=ON`), shim rpath'd to it.
