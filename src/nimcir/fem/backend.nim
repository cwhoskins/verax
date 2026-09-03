## Shared contract for finite-element solver backends.
##
## The direct analogue of `nimcir/spice/backend`: every backend module
## implements the same proc names over `nimcir/fem`'s problem, mesh and
## result types, so a caller needing more than one imports both and
## disambiguates with module-qualified calls.
##
## .. code-block:: nim
##   proc writeCase*(p: FemProblem, m: Mesh, path: string)
##   proc solve*(p: FemProblem, m: Mesh, opts = SolveOptions()): FemResult
##   proc available*(): bool
##
## `available()` has no counterpart in `spice/backend`, and that is
## deliberate. The ngspice backend never probes for its binary -- it just
## runs it -- which pushed the "is the toolchain here?" decision into 22
## separate test files, each re-implementing `findExe("ngspice")`. One proc
## on the contract keeps that in one place.
##
## **The intended first backend is MFEM** (`nimcir/fem/mfem`, not yet
## written): a C++ finite-element library, driven here through a small
## solver executable and its mesh/grid-function file formats. As with
## `nimcir/spice/ngspice`, a concrete backend will be opt-in per import --
## nothing in this hub pulls one in.
##
## **Real vs complex results.** A static or thermal solve produces real
## fields; a full-wave solve produces complex ones. `Field` is an object
## variant over that split, not a real vector with an "is it complex?" flag
## -- reading a magnetostatic result as complex is not merely wrong, the
## branch has no `cvalues`. `[]` / `cplx` / `mag` / `db` mirror
## `spice/backend` so a reader who knows one knows the other.

import std/[complex, math, tables]
import ./types
import ./mesh

export types, mesh

type
  FemSolveError* = object of CatchableError
    ## Raised when a solve fails to produce usable output -- the backend
    ## process failed, did not converge to a usable state, or wrote a result
    ## that could not be parsed -- and when a `Field` is read at the wrong
    ## kind.

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
      ## Extracted figures a caller actually asked for: `r_dc`, `l_11`,
      ## `c_11`, `z0`, `t_max`, `theta_ja`. This is the part an
      ## `nimcir/analysis` evaluator would read.
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
  ## Magnitude per point, defined for both kinds so an extraction reader
  ## needn't branch on the problem type.
  let f = r.fields[name]
  if f.complexValued:
    for c in f.cvalues: result.add abs(c)
  else:
    for x in f.values: result.add abs(x)

proc db*(r: FemResult, name: string): seq[float] =
  ## `20*log10(|x|)`. A zero magnitude yields `-Inf` rather than raising -- a
  ## null in a field is a real result.
  for m in mag(r, name):
    result.add(if m <= 0.0: -Inf else: 20.0 * log10(m))
