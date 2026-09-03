## Turning a `nimcir/pcb` board into a `FemProblem`: copper and dielectric
## become extruded `Region`s, the stack-up gives them their z-extents.
##
## This is the one module in `nimcir/fem` that imports `nimcir/pcb`, and it
## is why `fem` sits one rank above `pcb` in the dependency order -- the same
## relationship `spice` has to `netlist`.
##
## **Two things block this subsystem today, and they are stated here rather
## than worked around:**
##
## 1. **There is no `Pcb` reader.** `pcb/formats/` holds only a contract
##    (`readPcb`/`writePcb`) with no implementation, so a board reaches this
##    module only if it was built by hand in Nim. A KiCad or ODB++ reader is
##    the prerequisite for `fem` being useful on a real design.
## 2. **`Zone` carries only its authored outline** -- `Zone.fills` does not
##    exist (`pcb/types.nim`). A plane's real copper, with its thermal
##    reliefs and clearances, is not in the model. So `extrudeZones` refuses
##    rather than meshing a solid slab where the board has a Swiss cheese:
##    that is the class of wrong answer that looks plausible, and refusing
##    beats guessing is the standing rule in `spice/CLAUDE.md`. Adding
##    `Zone.fills` is documented as purely additive and is a separate task.
##
## What *does* work: `extrudeCopper` over tracks, pads and filled areas, and
## `extrudeStackup` for the dielectric between copper layers. A stroked track
## is approximated by its bounding box for now -- offsetting a centre-line to
## a filled polygon is the one geometry primitive `pcb/geometry` does not yet
## provide; `shFill` areas use their real (arc-flattened) outline.
##
## Deliberately not modelled: solder mask and paste as dielectric layers,
## component bodies as thermal masses, via barrels as conductors (a via is a
## `Hole`, not a `Copper`, and bridging the annular rings is future work).

import std/tables
import ../pcb
import ../pcb/geometry as geo
import ./types

export types

type
  ExtrudeSpec* = object
    layers*: seq[string]
      ## Copper layers to include, by name. Empty means every copper layer.
    includeZones*: bool
      ## When true, `problemFromPcb` calls `extrudeZones` -- which currently
      ## raises. Left as a field so the call site reads honestly once
      ## `Zone.fills` lands.
    conductor*: Material
      ## Applied to every copper region. A sensible default is filled by
      ## `defaultExtrudeSpec`.
    dielectric*: Material
      ## Applied to stack-up dielectric regions and, when a stack material
      ## names no permittivity, as the fallback.
    padding*: float
      ## Air-box margin around the board extent, metres. Advisory -- a
      ## backend builds the actual air box.

  ZBand = tuple[lo, hi: float]

proc metres(a: Nm): float {.inline.} = a.raw.float * 1e-9

proc defaultExtrudeSpec*(): ExtrudeSpec =
  ## Copper and FR-4 with textbook constants, so a caller can extrude a board
  ## without first assembling a material table.
  ExtrudeSpec(
    conductor: Material(name: "copper", sigma: 5.8e7, epsR: 1.0, muR: 1.0,
                        kThermal: 385.0, rhoDensity: 8960.0, cpHeat: 385.0),
    dielectric: Material(name: "FR4", epsR: 4.5, muR: 1.0, lossTangent: 0.02,
                         kThermal: 0.3, rhoDensity: 1850.0, cpHeat: 1200.0),
    padding: 5e-3)

proc zBands(pcb: Pcb): Table[string, ZBand] =
  ## Walk the stack-up top to bottom, accumulating thickness, and record the
  ## z-band of every entry that names a layer. Top surface is z = 0, z
  ## increases downward (into the board).
  var z = 0.0
  for e in pcb.stackup.entries:
    let t = metres(e.thickness)
    if e.layer != nil:
      result[e.layer.name] = (lo: z, hi: z + t)
    z += t

proc shapeOutline(s: Shape): seq[tuple[x, y: float]] =
  ## A copper feature's footprint as a closed polygon in metres, board
  ## frame. `shFill` gets its true outline; everything else its bounding box
  ## (see the module note on stroke offsetting).
  case s.kind
  of shFill:
    for p in geo.flatten(s.poly.outer):
      result.add (x: metres(p.x), y: metres(p.y))
  else:
    let b = geo.box(s)
    result = @[
      (x: metres(b.lo.x), y: metres(b.lo.y)),
      (x: metres(b.hi.x), y: metres(b.lo.y)),
      (x: metres(b.hi.x), y: metres(b.hi.y)),
      (x: metres(b.lo.x), y: metres(b.hi.y)),
    ]

proc wanted(spec: ExtrudeSpec, layerName: string): bool =
  spec.layers.len == 0 or layerName in spec.layers

proc extrudeCopper*(pcb: Pcb, spec = defaultExtrudeSpec()): seq[Region] =
  ## One `Region` per copper feature on the selected layers, extruded to that
  ## layer's stack-up z-band (or a 35 micron band at z = 0 when the stack-up
  ## is silent). Each region forward-references the feature's `Net`.
  let bands = zBands(pcb)
  for layer in pcb.copperLayers():
    if not wanted(spec, layer.name): continue
    let band = bands.getOrDefault(layer.name, (lo: 0.0, hi: 35e-6))
    for i, cu in layer.copper:
      result.add Region(
        name: layer.name & "/" & $i,
        material: spec.conductor.name,
        net: cu.net,
        layer: layer.name,
        zLow: band.lo, zHigh: band.hi,
        outline: shapeOutline(cu.shape))

proc extrudeStackup*(pcb: Pcb, spec = defaultExtrudeSpec()): seq[Region] =
  ## One `Region` per dielectric stack-up entry, spanning the board's
  ## bounding box. Needs a non-empty outline, so it is skipped when the board
  ## has no copper to bound it.
  let bb = pcb.boardBox()
  if bb.lo.x > bb.hi.x: return
  let rect = @[
    (x: metres(bb.lo.x), y: metres(bb.lo.y)),
    (x: metres(bb.hi.x), y: metres(bb.lo.y)),
    (x: metres(bb.hi.x), y: metres(bb.hi.y)),
    (x: metres(bb.lo.x), y: metres(bb.hi.y)),
  ]
  var z = 0.0
  var n = 0
  for e in pcb.stackup.entries:
    let t = metres(e.thickness)
    if e.kind == seDielectric and t > 0.0:
      inc n
      result.add Region(
        name: "dielectric/" & $n,
        material: spec.dielectric.name,
        layer: e.name,
        zLow: z, zHigh: z + t,
        outline: rect)
    z += t

proc extrudeZones*(pcb: Pcb, spec = defaultExtrudeSpec()): seq[Region] =
  ## **Refuses.** `Zone` holds only its authored outline; meshing that as
  ## solid copper models a plane without its reliefs and clearances. Blocked
  ## until `Zone.fills` exists -- see the module note.
  if pcb.zones.len == 0: return
  raise newException(FemError,
    "cannot extrude " & $pcb.zones.len & " zone(s): pcb.Zone models only the " &
    "authored outline, not the filled copper (needs Zone.fills). Meshing the " &
    "outline as a solid plane would omit every thermal relief and clearance.")

proc problemFromPcb*(pcb: Pcb, kind: ProblemKind,
                     spec = defaultExtrudeSpec()): FemProblem =
  ## Assemble a `FemProblem` from a board: copper + dielectric regions and
  ## their two materials. Boundary conditions and excitations are the
  ## caller's to add -- this does not know what question is being asked.
  result = newFemProblem(pcb.name, kind)
  result.addMaterial(spec.conductor)
  result.addMaterial(spec.dielectric)
  for r in extrudeStackup(pcb, spec): result.addRegion(r)
  for r in extrudeCopper(pcb, spec): result.addRegion(r)
  if spec.includeZones:
    for r in extrudeZones(pcb, spec): result.addRegion(r)
