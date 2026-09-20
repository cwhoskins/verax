## Turning a `verax/pcb` board into a `FemProblem`: copper and dielectric
## become extruded `Region`s, the stack-up gives them their z-extents.
##
## This is the one module in `verax/fem` that imports `verax/pcb`, and it
## is why `fem` sits one rank above `pcb` in the dependency order -- the same
## relationship `spice` has to `netlist`.
##
## **The two blockers this module used to state here are both gone.**
## `pcb/formats/kicad.readPcb` exists now, so a board reaches this module
## from a real file, not only hand-built in Nim; and `Zone.fills` (added the
## same stage) carries the *derived* fill geometry -- `extrudeZones` meshes
## it directly instead of refusing unconditionally. It still refuses **per
## zone** when a particular zone's `fills` is empty (an unfilled board, or
## one read before a fill pass ran) -- meshing `Zone.outline` in that case
## would model a plane without its thermal reliefs and clearances, the class
## of wrong answer that looks plausible, and refusing beats guessing is the
## standing rule in `spice/CLAUDE.md`. `extrudeCopper` skips every `ckZone`
## record for the same reason from the other direction: `graph.addZone`
## already pushes one onto each of the zone's layers as the *authored*
## outline, and meshing that too would both get a plane's shape wrong and
## double-count its copper against `extrudeZones`' own regions.
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

import std/[strutils, tables]
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

proc metres(a: Nm): float {.inline.} = toMetres(a)
  ## Was `a.raw.float * 1e-9` open-coded here before `pcb/units.toMetres`
  ## existed to name it once; kept as a local alias so every call site below
  ## stays unchanged.

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
      if cu.kind == ckZone: continue
        # `graph.addZone` pushes a `ckZone` record of the *authored* outline
        # onto every layer the zone covers, and this loop would otherwise
        # mesh that outline as solid copper -- omitting every thermal
        # relief and clearance a real pour has, and doing so silently, since
        # nothing here would say so. The real copper is `extrudeZones`'
        # `ckFill` records (`Zone.fills`, landed on the same layers through
        # `graph.addZoneFill`); meshing both would also double-count a
        # plane's copper on top of getting its shape wrong.
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
  ## One `Region` per filled polygon in `Zone.fills`, refusing **per zone**
  ## rather than for the whole call when a zone has none. `Zone.fills` is
  ## additive (a `formats/kicad` reader populates it from `filled_polygon`;
  ## a board built by hand in Nim, or one read before a fill pass ran, has
  ## none), and meshing `Zone.outline` in its place would model a plane
  ## without its thermal reliefs and clearances -- the class of wrong answer
  ## that *looks* plausible, which is exactly what this module exists to
  ## refuse rather than produce. A board with a mix of filled and unfilled
  ## zones gets `Region`s for the filled ones and one combined refusal
  ## naming every zone that has none, so the caller sees every problem at
  ## once instead of fixing one zone and re-running into the next.
  let bands = zBands(pcb)
  var unfilled: seq[string]
  for z in pcb.zones:
    if z.fills.len == 0:
      unfilled.add(if z.name.len > 0: z.name else: "<unnamed>")
      continue
    for i, cu in z.fills:
      let band = bands.getOrDefault(cu.layer.name, (lo: 0.0, hi: 35e-6))
      result.add Region(
        name: "zone/" & z.name & "/" & $i,
        material: spec.conductor.name,
        net: cu.net,
        layer: cu.layer.name,
        zLow: band.lo, zHigh: band.hi,
        outline: shapeOutline(cu.shape))
  if unfilled.len > 0:
    raise newException(FemError,
      "cannot extrude " & $unfilled.len & " zone(s) with no fill: " &
      unfilled.join(", ") & ". pcb.Zone models only the authored outline in " &
      "`outline`/`areas`; the filled copper (thermal reliefs, clearances, " &
      "priority against other zones) lives in `Zone.fills`, populated by " &
      "`formats/kicad.readPcb` from `(filled_polygon)` or left empty on a " &
      "board built by hand or read before a fill pass ran. Meshing the " &
      "outline as a solid plane in its place would omit every relief and " &
      "clearance the real pour has.")

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
