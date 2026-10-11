## Turning a `verax/pcb` board into a `FemProblem`: copper and dielectric
## become extruded `Region`s with z-extents from the stack-up. The one `fem`
## module that imports `pcb`.
##
## `extrudeZones` meshes `Zone.fills` and refuses **per zone** when a zone
## has none: meshing the outline would model a plane without its reliefs and
## clearances. `extrudeCopper` skips `ckZone` records (the authored outline)
## for the same reason, and to avoid double-counting.
##
## `extrudeCopper` covers tracks, pads and filled areas; `extrudeStackup`
## the dielectric. A stroked track is approximated by its bounding box (no
## stroke-offset primitive yet); `shFill` uses its real outline.
##
## Not modelled: mask/paste dielectrics, component bodies, via barrels.

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
      ## When true, `problemFromPcb` also calls `extrudeZones`.
    conductor*: Material
      ## Applied to every copper region; `defaultExtrudeSpec` fills it.
    dielectric*: Material
      ## For stack-up dielectric regions, and the fallback when a stack
      ## material names no permittivity.
    padding*: float
      ## Air-box margin around the board, metres. Advisory; the backend builds
      ## the air box.

  ZBand = tuple[lo, hi: float]

proc metres(a: Nm): float {.inline.} = toMetres(a)
  ## Local alias for `pcb/units.toMetres`.

proc tb(x: float): Stated[float] = stated(x, annDefaulted)
  ## A textbook constant: a default, so `assumedConstants` reports it.

proc defaultExtrudeSpec*(): ExtrudeSpec =
  ## Copper and FR-4 with textbook constants.
  ExtrudeSpec(
    conductor: Material(name: "copper", sigma: tb(5.8e7), epsR: tb(1.0),
                        muR: tb(1.0), kThermal: tb(385.0),
                        rhoDensity: tb(8960.0), cpHeat: tb(385.0)),
    dielectric: Material(name: "FR4", epsR: tb(4.5), muR: tb(1.0),
                         lossTangent: tb(0.02), kThermal: tb(0.3),
                         rhoDensity: tb(1850.0), cpHeat: tb(1200.0)),
    padding: 5e-3)

proc zBands(pcb: Pcb): Table[string, ZBand] =
  ## The z-band of every stack-up entry naming a layer, top to bottom. Top
  ## surface is z = 0; z increases into the board.
  var z = 0.0
  for e in pcb.stackup.entries:
    let t = metres(e.thickness)
    if e.layer != nil:
      result[e.layer.name] = (lo: z, hi: z + t)
    z += t

proc shapeOutline(s: Shape): seq[tuple[x, y: float]] =
  ## A copper feature's footprint as a closed polygon in metres: `shFill`'s
  ## true outline, else its bounding box.
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
  ## One `Region` per copper feature on the selected layers, extruded to its
  ## layer's z-band (35 micron at z = 0 if the stack-up is silent), each
  ## referencing its `Net`.
  let bands = zBands(pcb)
  for layer in pcb.copperLayers():
    if not wanted(spec, layer.name): continue
    let band = bands.getOrDefault(layer.name, (lo: 0.0, hi: 35e-6))
    for i, cu in layer.copper:
      if cu.kind == ckZone: continue
        # Skip `ckZone` (the authored outline, without reliefs or clearances);
        # the real copper is `extrudeZones`' `ckFill` records.
      result.add Region(
        name: layer.name & "/" & $i,
        material: spec.conductor.name,
        net: cu.net,
        layer: layer.name,
        zLow: band.lo, zHigh: band.hi,
        outline: shapeOutline(cu.shape))

proc extrudeStackup*(pcb: Pcb, spec = defaultExtrudeSpec()): seq[Region] =
  ## One `Region` per dielectric entry, spanning the board's box. Skipped
  ## with no copper to bound it.
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
  ## One `Region` per polygon in `Zone.fills`. A zone with no fills is
  ## refused (meshing its outline would look plausible and be wrong); filled
  ## zones still produce regions, and one combined refusal names every
  ## unfilled zone.
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
  ## Assemble a `FemProblem` from a board: copper and dielectric regions and
  ## their materials. Boundary conditions and excitations are the caller's.
  result = newFemProblem(pcb.name, kind)
  result.addMaterial(spec.conductor)
  result.addMaterial(spec.dielectric)
  for r in extrudeStackup(pcb, spec): result.addRegion(r)
  for r in extrudeCopper(pcb, spec): result.addRegion(r)
  if spec.includeZones:
    for r in extrudeZones(pcb, spec): result.addRegion(r)
