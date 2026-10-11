## A field problem statement: geometry, materials, boundary conditions and
## excitations. Solver-neutral, no results; hand it to a
## `verax/fem/backend`, get a `FemResult`.
##
## **EM and thermal share one contract**: `Material` carries both physics'
## constants, since one copper pour is a conductor in one and a heat
## spreader in the other.
##
## Not modelled: anisotropic or dispersive materials, temperature-dependent
## conductivity, radiation view factors, coupled multiphysics (that's two
## solves with a caller between).

import std/[tables, sequtils]
import ../netlist/types as nltypes
import ../stated as statedmod

export nltypes.Net, statedmod

type
  FemError* = object of CatchableError
    ## Raised on an inconsistent problem a builder can catch (unknown
    ## material, condition naming a missing region). `validate` reports softer
    ## cases.

  ProblemKind* = enum
    pkElectrostatic   ## Laplace/Poisson for potential; capacitance extraction
    pkMagnetostatic   ## curl-curl for the static H field; inductance extraction
    pkFullWave        ## frequency-domain Maxwell; S-parameters, resonances
    pkThermalSteady   ## steady-state heat conduction
    pkThermalTransient ## time-domain heat conduction

  Material* = object
    name*: string
    epsR*, muR*: Stated[float]
      ## Relative permittivity / permeability.
    sigma*: Stated[float]
      ## Electrical conductivity, S/m. **`stated(0.0)` is an insulator**,
      ## unstated is "nobody said" -- the reason these are `Stated` and not
      ## zero-means-unknown floats.
    kThermal*: Stated[float]
      ## Thermal conductivity, W/(m*K).
    rhoDensity*: Stated[float]
      ## Mass density, kg/m^3 -- transient thermal only.
    cpHeat*: Stated[float]
      ## Specific heat capacity, J/(kg*K) -- transient thermal only.
    lossTangent*: Stated[float]
      ## Each constant carries its source: a textbook default
      ## (`annDefaulted`) is an assumption a result rests on.
    attrs*: OrderedTable[string, string]

  Region* = object
    ## One homogeneous solid: a simple closed polygon in the board frame
    ## (X right, Y up, metres) extruded between `zLow` and `zHigh`.
    name*: string
    material*: string
      ## Key into `FemProblem.materials`.
    net*: Net
      ## The net this region carries, or `nil` (forward reference only).
    layer*: string
      ## Source layer name, for reporting and for grouping regions.
    zLow*, zHigh*: float
      ## Metres. `zHigh > zLow`.
    outline*: seq[tuple[x, y: float]]
      ## Metres, board frame. Empty is legal for a primitive a backend reads
      ## from `attrs`.
    attrs*: OrderedTable[string, string]

  BcKind* = enum
    bcDirichlet     ## fixed potential / fixed temperature
    bcNeumann       ## fixed normal derivative / fixed heat flux
    bcRobin         ## mixed, a*u + b*du/dn = c
    bcPec           ## perfect electric conductor
    bcPort          ## wave port (full-wave)
    bcConvection    ## thermal: h*(u - u_ambient)
    bcRadiation     ## thermal: emissivity to ambient

  BoundaryCondition* = object
    kind*: BcKind
    name*: string
    value*: float
      ## Volts, kelvin, W/m^2, or W/(m^2*K) depending on `kind`.
    coefficientA*, coefficientB*: float
      ## Robin/convection/radiation coefficients; unused otherwise.
    regions*: seq[string]
      ## Regions whose exposed faces this applies to; empty means the whole
      ## domain's outer boundary.

  Excitation* = object
    ## A driven port (EM) or a heat source (thermal).
    name*: string
    regions*: seq[string]
    magnitude*: float
      ## Volts or amps (EM), watts (thermal).
    frequency*: float
      ## Hz; 0 for a DC/static or thermal source.
    impedance*: float
      ## Reference impedance of a port, ohms; 0 when not a port.

  FemProblem* = object
    name*: string
    kind*: ProblemKind
    regions*: seq[Region]
    materials*: OrderedTable[string, Material]
    boundaries*: seq[BoundaryCondition]
    excitations*: seq[Excitation]
    frequencies*: seq[float]
      ## Full-wave sweep points, Hz. Empty for a static or thermal problem.
    ambient*: float
      ## Reference temperature, K -- thermal problems only.
    attrs*: OrderedTable[string, string]

proc newFemProblem*(name: string, kind: ProblemKind): FemProblem =
  FemProblem(name: name, kind: kind, ambient: 293.15)

proc addMaterial*(p: var FemProblem, m: Material) =
  ## Register a material. A duplicate name with different properties raises;
  ## an identical re-add is ignored.
  if p.materials.hasKey(m.name) and p.materials[m.name] != m:
    raise newException(FemError, "material '" & m.name & "' redefined")
  p.materials[m.name] = m

proc addRegion*(p: var FemProblem, r: Region) =
  ## Append a region; raises on an unregistered material or degenerate z.
  if r.material.len > 0 and not p.materials.hasKey(r.material):
    raise newException(FemError,
      "region '" & r.name & "' uses unregistered material '" & r.material & "'")
  if r.zHigh <= r.zLow:
    raise newException(FemError,
      "region '" & r.name & "' has zHigh <= zLow")
  p.regions.add r

proc isThermal*(k: ProblemKind): bool {.inline.} =
  k in {pkThermalSteady, pkThermalTransient}

proc isElectromagnetic*(k: ProblemKind): bool {.inline.} =
  k in {pkElectrostatic, pkMagnetostatic, pkFullWave}

proc validate*(p: FemProblem): seq[string] =
  ## Warnings, not refusals: full-wave with no frequencies, thermal with no
  ## source, a condition naming an unknown region, a material leaving the
  ## relevant constant at zero. A silent pass isn't proof of a well-posed
  ## problem.
  var regionNames: Table[string, bool]
  for r in p.regions: regionNames[r.name] = true

  if p.kind == pkFullWave and p.frequencies.len == 0:
    result.add "full-wave problem has no frequency points"
  if p.kind.isThermal and p.excitations.len == 0 and
     not p.boundaries.anyIt(it.kind in {bcDirichlet, bcConvection}):
    result.add "thermal problem has neither a heat source nor a fixed-temperature boundary"
  if p.regions.len == 0:
    result.add "problem has no regions to mesh"

  for b in p.boundaries:
    for rn in b.regions:
      if rn notin regionNames:
        result.add "boundary '" & b.name & "' names unknown region '" & rn & "'"
  for e in p.excitations:
    for rn in e.regions:
      if rn notin regionNames:
        result.add "excitation '" & e.name & "' names unknown region '" & rn & "'"

  for r in p.regions:
    if r.material.len == 0: continue
    let m = p.materials[r.material]
    if p.kind.isThermal and not m.kThermal.has:
      result.add "region '" & r.name & "' material '" & m.name &
        "' states no thermal conductivity"
    if p.kind.isElectromagnetic and not m.epsR.has and not m.sigma.has:
      result.add "region '" & r.name & "' material '" & m.name &
        "' states neither permittivity nor conductivity"

proc assumedConstants*(m: Material): seq[string] =
  ## The constants of `m` taken from a defaults table rather than stated,
  ## for a report's assumptions.
  for name, v in m.fieldPairs:
    when v is Stated[float]:
      if v.source == annDefaulted: result.add name & " = " & $v.value
