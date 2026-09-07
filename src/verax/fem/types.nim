## Stating a field problem over a region of space: the geometry to be
## meshed, the material in each part of it, the conditions on its boundary,
## and what drives it.
##
## This is the *problem statement* only -- solver-neutral, and carrying no
## result. One `FemProblem` is enough to hand to any backend
## (`verax/fem/backend`); what comes back is a `FemResult`.
##
## **Electromagnetic and thermal share one contract.** `ProblemKind`
## discriminates, but `Material` carries the constants for *both* physics in
## one object rather than a variant, because the same copper pour is a
## conductor in an EM problem and a heat-spreader in a thermal one, and
## splitting it into two material types is precisely how the two drift out of
## agreement about the same region.
##
## Deliberately not modelled here: anisotropic or frequency-dispersive
## materials (one `epsR`, not a tensor or a Debye model), nonlinear
## temperature-dependent conductivity, radiation view factors, and coupled
## multiphysics in a single solve (an EM loss field feeding a thermal run is
## two `solve` calls and a caller in between, not one problem).

import std/[tables, sequtils]
import ../netlist/types as nltypes

export nltypes.Net

type
  FemError* = object of CatchableError
    ## Raised on an inconsistent problem statement that a builder can catch
    ## before a solve -- an unknown material name on a region, a boundary
    ## condition naming a region that does not exist. `validate` reports the
    ## softer cases without raising.

  ProblemKind* = enum
    pkElectrostatic   ## Laplace/Poisson for potential; capacitance extraction
    pkMagnetostatic   ## curl-curl for the static H field; inductance extraction
    pkFullWave        ## frequency-domain Maxwell; S-parameters, resonances
    pkThermalSteady   ## steady-state heat conduction
    pkThermalTransient ## time-domain heat conduction

  Material* = object
    name*: string
    epsR*, muR*: float
      ## Relative permittivity / permeability. Default 0 means "unset"; a
      ## builder from a `Pcb` fills vacuum (1.0) where a stackup is silent.
    sigma*: float
      ## Electrical conductivity, S/m.
    kThermal*: float
      ## Thermal conductivity, W/(m*K).
    rhoDensity*: float
      ## Mass density, kg/m^3 -- transient thermal only.
    cpHeat*: float
      ## Specific heat capacity, J/(kg*K) -- transient thermal only.
    lossTangent*: float
    attrs*: OrderedTable[string, string]

  Region* = object
    ## One homogeneous solid to be meshed. `outline` is a simple closed
    ## polygon in the board frame (X right, Y up, metres, matching
    ## `verax/pcb`'s canonical frame) extruded between `zLow` and `zHigh`.
    name*: string
    material*: string
      ## Key into `FemProblem.materials`.
    net*: Net
      ## The electrical net this region carries, or `nil`. Forward reference
      ## only -- `fem` never mutates a netlist.
    layer*: string
      ## Source layer name, for reporting and for grouping regions.
    zLow*, zHigh*: float
      ## Metres. `zHigh > zLow`.
    outline*: seq[tuple[x, y: float]]
      ## Metres, board frame. Empty is legal for a region defined only by an
      ## analytic primitive a backend understands via `attrs`.
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
      ## Region names whose exposed faces this condition applies to. Empty
      ## means the outer boundary of the whole domain.

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
  ## Register a material by name. Raises `FemError` on a duplicate name with
  ## different properties; a byte-identical re-add is ignored.
  if p.materials.hasKey(m.name) and p.materials[m.name] != m:
    raise newException(FemError, "material '" & m.name & "' redefined")
  p.materials[m.name] = m

proc addRegion*(p: var FemProblem, r: Region) =
  ## Append a region. Raises `FemError` if its material name is not
  ## registered or its z-extent is degenerate.
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
  ## Report problems that are worth flagging but not worth refusing to
  ## solve: a full-wave problem with no frequencies, a thermal problem with
  ## no source, a boundary condition naming an unknown region, a region
  ## whose material leaves the relevant constant at zero.
  ##
  ## Returns warnings rather than raising, following
  ## `verax/spice/xspice/build.checkAbi` -- it cannot see everything, so a
  ## silent pass must not be read as proof the problem is well posed.
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
    if p.kind.isThermal and m.kThermal == 0.0:
      result.add "region '" & r.name & "' material '" & m.name &
        "' has no thermal conductivity"
    if p.kind.isElectromagnetic and m.epsR == 0.0 and m.sigma == 0.0:
      result.add "region '" & r.name & "' material '" & m.name &
        "' has neither permittivity nor conductivity"
