## MFEM backend, **stage 0: the call path only.** Proves verax can load, call
## and get a known-exact answer back from MFEM; there is no board meshing, no
## `solve(FemProblem, Mesh)` and no physics beyond a Laplace validation solve.
##
## Opt-in: `import verax/fem/mfem`. Neither the `verax/fem` hub nor `cli.nim`
## imports this, so a design that never asks for a field solve never touches
## MFEM, `dlopen` or a C++ toolchain.
##
## **Architecture:** `nim c` -> `std/dynlib` -> `libverax_mfem-*.so` (an
## `extern "C"` shim, `mfem/shim.cpp`) -> `libmfem`. Rejected: `importcpp`
## (forces every importer, the CLI included, to `nim cpp`).
##
## **The shim is loaded with `std/dynlib`, never the `{.dynlib.}` pragma.**
## The pragma resolves at process start and aborts the whole program when the
## library is missing; `available()` must instead be able to say "no" and let
## a test skip. Nothing here raises when MFEM is absent except the procs that
## need it, and those raise `FemSolveError` naming `nimble mfem`.
##
## The shim is deliberately **not built on demand**: a library call that
## silently starts a multi-minute C++ compile is worse than one that says
## "run `nimble mfem`". `loadStatus()` reports exactly which link of
## toolchain -> shim file -> dlopen -> ABI -> version is broken.

import std/[dynlib, os, tables]
import ./backend
import ./mfem/build
export backend
export build.shimAbiVersion

type
  MfemLoadStatus* = object
    toolchainFound*: bool
    mfemDir*: string
    shimPath*: string
    shimExists*: bool
    loaded*: bool
    loadError*: string
      ## What `std/dynlib` could not do (missing symbol, `dlopen` refusal).
    abiExpected*: int
    abiGot*: int
      ## -1 when the shim was not loaded.
    version*: string
      ## `mfem::GetVersionStr()`; empty when not loaded.

  MfemMesh* = object
    ## Owns a `vx_mesh*`. Copying is disabled: two owners would double-free.
    h: pointer

  LaplaceSolution* = object
    nodal*: seq[float]
      ## One value per H1 dof; for order 1 dof `i` is mesh vertex `i`.
    residual*: float
    iterations*: int

  ShimApi = object
    abiVersion: proc (): cint {.cdecl.}
    version: proc (): cstring {.cdecl.}
    lastError: proc (): cstring {.cdecl.}
    cartesian2d: proc (nx, ny: cint, sx, sy: cdouble, o: ptr pointer): cint {.cdecl.}
    fromArrays: proc (dim, nverts: cint, xyz: ptr cdouble, nelem, geom: cint,
                      conn, attr: ptr cint, o: ptr pointer): cint {.cdecl.}
    counts: proc (m: pointer, nv, ne, nbe: ptr cint): cint {.cdecl.}
    meshFree: proc (m: pointer) {.cdecl, raises: [].}
    ndofs: proc (m: pointer, order: cint, n: ptr cint): cint {.cdecl.}
    dofCoords: proc (m: pointer, order: cint, xyz: ptr cdouble, len: cint): cint {.cdecl.}
    solveLaplace: proc (m: pointer, order: cint, bc: ptr cdouble,
                        nodal: ptr cdouble, nodalLen: cint,
                        residual: ptr cdouble, iters: ptr cint): cint {.cdecl.}

var
  api: ShimApi
  loadedPath = ""
  handles: seq[(string, LibHandle)]
    ## One `dlopen` per distinct path for the process; `loadStatus` is called
    ## freely and must not leak a handle each time.

proc `=copy`*(a: var MfemMesh, b: MfemMesh) {.error.}

proc `=destroy`*(m: MfemMesh) =
  if m.h != nil and api.meshFree != nil: api.meshFree(m.h)

proc `$`*(s: MfemLoadStatus): string =
  result = "MFEM load status:\n" &
    "  toolchain: " & (if s.toolchainFound: "found at " & s.mfemDir
                       else: "NOT found (set $MFEM_DIR or run `nimble mfem`)") & "\n" &
    "  shim:      " & (if s.shimPath.len == 0: "(no path)" else: s.shimPath) &
      (if s.shimExists: "" else: "  [missing: run `nimble mfem`]") & "\n" &
    "  loaded:    " & $s.loaded &
      (if s.loadError.len > 0: "  (" & s.loadError & ")" else: "") & "\n" &
    "  abi:       expected " & $s.abiExpected & ", got " & $s.abiGot & "\n" &
    "  version:   " & (if s.version.len > 0: s.version else: "(unknown)")

proc loadStatus*(abiExpected = shimAbiVersion): MfemLoadStatus =
  ## Walks toolchain -> shim file -> `dlopen` -> symbols -> ABI -> version and
  ## stops at the first broken link, recording why. Never raises. Re-reads
  ## `$MFEM_DIR` each call (tests repoint it); `dlopen` itself is cached.
  result.abiExpected = abiExpected
  result.abiGot = -1
  let tc = try: findMfem() except CatchableError: MfemToolchain()
  result.toolchainFound = tc.found
  if not tc.found: return
  result.mfemDir = tc.mfemDir
  result.shimPath = shimPath(tc)
  result.shimExists = fileExists(result.shimPath)
  if not result.shimExists: return

  var lib: LibHandle
  for (p, h) in handles:
    if p == result.shimPath: lib = h
  if lib == nil:
    lib = loadLib(result.shimPath)
    if lib == nil:
      result.loadError = "dlopen failed for " & result.shimPath &
        " (libmfem not resolvable through the shim's rpath?)"
      return
    handles.add (result.shimPath, lib)

  template sym(field: untyped, name: string) =
    let p = symAddr(lib, name)
    if p == nil:
      result.loadError = "shim has no symbol " & name
      return
    api.field = cast[typeof(api.field)](p)
  sym(abiVersion, "vx_mfem_abi_version")
  result.abiGot = int(api.abiVersion())
  if result.abiGot != abiExpected: return
  sym(version, "vx_mfem_version")
  sym(lastError, "vx_mfem_last_error")
  sym(cartesian2d, "vx_mesh_cartesian_2d")
  sym(fromArrays, "vx_mesh_from_arrays")
  sym(counts, "vx_mesh_counts")
  sym(meshFree, "vx_mesh_free")
  sym(ndofs, "vx_h1_ndofs")
  sym(dofCoords, "vx_h1_dof_coords")
  sym(solveLaplace, "vx_solve_laplace_dirichlet")
  result.version = $api.version()
  result.loaded = true
  loadedPath = result.shimPath

proc available*(abiExpected = shimAbiVersion): bool =
  ## True when the shim loads and its ABI matches. Never raises.
  try: loadStatus(abiExpected).loaded
  except CatchableError: false

proc mfemVersion*(): string =
  let s = loadStatus()
  if s.loaded: s.version else: ""

proc requireShim() =
  let s = loadStatus()
  if not s.loaded:
    raise newException(FemSolveError,
      "MFEM is not available; run `nimble mfem` (or set $MFEM_DIR to an " &
      "install and run it to build the shim).\n" & $s)

proc check(code: cint, what: string) =
  if code != 0:
    raise newException(FemSolveError, what & ": " & $api.lastError())

# --- meshes ---------------------------------------------------------------------

proc cartesian2d*(nx, ny: int, sx = 1.0, sy = 1.0): MfemMesh =
  ## `2*nx*ny` triangles on `[0,sx] x [0,sy]`.
  requireShim()
  check api.cartesian2d(cint nx, cint ny, sx, sy, addr result.h), "cartesian2d"

proc counts*(m: MfemMesh): tuple[nv, ne, nbe: int] =
  var a, b, c: cint
  check api.counts(m.h, addr a, addr b, addr c), "counts"
  (int a, int b, int c)

proc geomCode(k: ElementKind): cint =
  case k
  of ekTri3: 2
  of ekQuad4: 3
  of ekTet4: 4
  of ekHex8: 5
  else:
    raise newException(FemError,
      "MFEM stage 0 translates Tri3/Quad4/Tet4/Hex8 only, not " & $k &
      "; state the mesh with first-order elements.")

proc fromArrays*(dim: int, xyz: seq[float], kind: ElementKind,
                 conn: seq[int], attr: seq[int] = @[]): MfemMesh =
  ## Raw path: `xyz` is 3 doubles per vertex, `conn` is `nodeCountFor[kind]`
  ## indices per element. A bad vertex index raises `FemSolveError` carrying
  ## the shim's message (the exception is caught C++-side, not `abort()`).
  requireShim()
  let npe = nodeCountFor[kind]
  let nelem = conn.len div npe
  let conn32 = block:
    var c = newSeq[cint](conn.len)
    for i, v in conn: c[i] = cint v
    c
  var a32 = newSeq[cint](nelem)
  for i in 0 ..< nelem: a32[i] = cint(if i < attr.len: attr[i] else: 1)
  check api.fromArrays(cint dim, cint(xyz.len div 3),
        (if xyz.len > 0: unsafeAddr xyz[0] else: nil), cint nelem, geomCode(kind),
        (if conn32.len > 0: addr conn32[0] else: nil),
        (if a32.len > 0: addr a32[0] else: nil), addr result.h), "fromArrays"

proc toMfem*(m: Mesh): MfemMesh =
  ## Translate a verax `Mesh`: one element kind per mesh, first order only.
  ## **Node order:** MFEM's local order for Tri3, Quad4, Tet4 and Hex8 is the
  ## conventional one (counter-clockwise faces, hex bottom face 0-3 then top
  ## 4-7) -- see `mesh.nim`. Orientation is *not* left to chance: the shim
  ## finalizes with `fix_orientation`, so a negative-Jacobian element is
  ## flipped rather than silently giving a wrong stiffness matrix.
  ## Element region `r` becomes MFEM attribute `r + 2`, so an air-box
  ## filler (-1) is attribute 1 and attributes stay >= 1 as MFEM requires.
  m.check()
  if m.elements.len == 0:
    raise newException(FemError, "cannot translate a mesh with no elements")
  let kind = m.elements[0].kind
  let geom = geomCode(kind)
  let dim = if geom <= 3: 2 else: 3
  var xyz = newSeqOfCap[float](m.nodes.len * 3)
  for n in m.nodes: xyz.add [n.x, n.y, n.z]
  var conn: seq[int]
  var attr: seq[int]
  for e in m.elements:
    if e.kind != kind:
      raise newException(FemError,
        "mixed element kinds (" & $kind & " and " & $e.kind & "): MFEM stage 0 " &
        "takes one kind per mesh")
    conn.add e.nodes
    attr.add e.region + 2
  fromArrays(dim, xyz, kind, conn, attr)

# --- the validation solve --------------------------------------------------------

proc dofCoords*(m: MfemMesh, order: int): seq[Node] =
  var n: cint
  check api.ndofs(m.h, cint order, addr n), "ndofs"
  var buf = newSeq[cdouble](3 * int n)
  check api.dofCoords(m.h, cint order, addr buf[0], cint buf.len), "dofCoords"
  for i in 0 ..< int n:
    result.add Node(x: buf[3*i], y: buf[3*i+1], z: buf[3*i+2])

proc solveLaplaceDirichlet*(m: MfemMesh, g: array[4, float],
                            order = 1): LaplaceSolution =
  ## `-lap(u) = 0`, `u = g0 + g1*x + g2*y + g3*z` on the whole boundary.
  ## A solution that is linear is reproduced exactly by H1 elements of any
  ## order, so any error is an assembly/translation bug, not discretisation.
  var n: cint
  check api.ndofs(m.h, cint order, addr n), "ndofs"
  result.nodal = newSeq[float](int n)
  var gg = g
  var res: cdouble
  var it: cint
  check api.solveLaplace(m.h, cint order, addr gg[0], addr result.nodal[0],
                         cint n, addr res, addr it), "solveLaplaceDirichlet"
  result.residual = res
  result.iterations = int it

proc solveLaplaceDirichlet*(m: Mesh, g: array[4, float], order = 1): FemResult =
  ## The path `solve()` will take: verax `Mesh` -> `toMfem` -> MFEM -> a
  ## `FemResult`. The field is per-node only for order 1 (higher orders carry
  ## edge/face dofs that are not mesh nodes).
  let mm = toMfem(m)
  let s = solveLaplaceDirichlet(mm, g, order)
  result.problemName = "laplace"
  result.mesh = m
  var f = newField("potential", fkScalarPotential)
  f.unit = "V"
  f.perNode = order == 1
  f.values = s.nodal
  result.fields["potential"] = f
  result.converged = s.residual < 1e-8
  result.iterations = s.iterations
  result.residual = s.residual
