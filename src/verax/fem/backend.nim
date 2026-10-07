## Shared contract for finite-element solver backends, analogous to
## `verax/spice/backend`: every backend implements the same procs over
## `verax/fem` types, so several can be imported and module-qualified.
##
## .. code-block:: nim
##   proc writeCase*(p: FemProblem, m: Mesh, path: string)
##   proc solve*(p: FemProblem, m: Mesh, opts = SolveOptions()): FemResult
##   proc available*(): bool
##
## `available()` keeps the "is the toolchain here?" check in one place.
##
## The intended first backend is MFEM (not yet written), opt-in per import.
##
## **`Field` is a variant over real/complex** (static/thermal vs
## full-wave); `[]`/`cplx`/`mag`/`db` mirror `spice/backend`.

import std/[complex, math, tables]
import ./types
import ./mesh

export types, mesh

type
  FemSolveError* = object of CatchableError
    ## Raised when a solve fails (process failure, non-convergence,
    ## unparseable output) or a `Field` is read as the wrong kind.

  FieldKind* = enum
    fkScalarPotential   ## V
    fkTemperature       ## K
    fkEField            ## V/m
    fkHField            ## A/m
    fkCurrentDensity    ## A/m^2
    fkHeatFlux          ## W/m^2
    fkPower             ## W/m^3 loss density

  Field* = object
    name*: string
    kind*: FieldKind
    unit*: string
      ## Human-readable unit for reports; not parsed.
    perNode*: bool
      ## true: one value per mesh node. false: one per element.
    case complexValued*: bool
    of true:
      cvalues*: seq[Complex64]
    of false:
      values*: seq[float]

  FemResult* = object
    problemName*: string
    mesh*: Mesh
    fields*: OrderedTable[string, Field]
    scalars*: OrderedTable[string, float]
      ## Extracted figures (`r_dc`, `l_11`, `c_11`, `z0`, `t_max`,
      ## `theta_ja`) -- what an analysis evaluator would read.
    frequencies*: seq[float]
      ## Populated for a full-wave sweep; one entry otherwise.
    converged*: bool
    iterations*: int
    residual*: float

  SolveOptions* = object
    order*: int
      ## Polynomial order of the elements; 1 or 2 for most problems.
    maxIterations*: int
    tolerance*: float
    workDir*: string
      ## Where the backend may write intermediate files; a temp dir if empty.
    keepFiles*: bool
      ## Leave `workDir` in place after the solve, for inspection.

proc newField*(name: string, kind: FieldKind, complexValued = false): Field =
  if complexValued: Field(kind: kind, name: name, complexValued: true)
  else: Field(kind: kind, name: name, complexValued: false)

proc len*(f: Field): int =
  if f.complexValued: f.cvalues.len else: f.values.len

proc names*(r: FemResult): seq[string] =
  for _, f in r.fields: result.add f.name

proc wrongKind(name: string, gotComplex: bool): ref FemSolveError =
  if gotComplex:
    newException(FemSolveError,
      "field '" & name & "' is complex (full-wave): read it with cplx(), " &
      "mag() or db(), not []")
  else:
    newException(FemSolveError,
      "field '" & name & "' is real: read it with [], not cplx()")

proc `[]`*(r: FemResult, name: string): seq[float] =
  ## A real field's values by name. Raises `KeyError` if absent,
  ## `FemSolveError` if the field is complex.
  if r.fields[name].complexValued:
    raise wrongKind(name, true)
  r.fields[name].values

proc cplx*(r: FemResult, name: string): seq[Complex64] =
  ## The complex counterpart of `[]`. Raises `FemSolveError` on a real field.
  if not r.fields[name].complexValued:
    raise wrongKind(name, false)
  r.fields[name].cvalues

proc mag*(r: FemResult, name: string): seq[float] =
  ## Magnitude per point, for either kind.
  let f = r.fields[name]
  if f.complexValued:
    for c in f.cvalues: result.add abs(c)
  else:
    for x in f.values: result.add abs(x)

proc db*(r: FemResult, name: string): seq[float] =
  ## `20*log10(|x|)`; a zero magnitude gives `-Inf`.
  for m in mag(r, name):
    result.add(if m <= 0.0: -Inf else: 20.0 * log10(m))
