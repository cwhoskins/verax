## Mutation API for the PCB data model.
##
## Every proc here keeps the back-references on `PcbLayer`, `Copper`, `Hole`,
## `Zone` and `Placement` consistent, and keeps the two lookup indexes --
## `Pcb.netCopper` (by net name) and `Pcb.index` (by location) -- in step with
## the graph. Code outside this module should never hand-set `.pcb`, `.layer`,
## `.net`, `.pin`, `.hole`, `.pads`, `.lands`, `.box`, `.index` or
## `.sourceIndex` directly, exactly as `netlist/graph` requires for the
## electrical model.
##
## The electrical side is *not* duplicated here: a reader builds nets,
## components and pins with `netlist/graph`'s `addNet`/`addComponent`/
## `addPin`/`connect`, precisely as `netlist/formats/spice` does, then links
## geometry to the objects that call produced.

import std/tables
import ./units
import ./geometry
import ./types
import ../netlist/types as nltypes
import ../netlist/packages

export types

proc touch*(pcb: Pcb) {.inline.} =
  ## Records that the board changed: bumps `pcb.rev` and marks the spatial
  ## index dirty. **Exported**, on the same reasoning as `index.dirty` being
  ## a public field -- a caller that writes an entity's field directly
  ## (`p.rot = deg(90)`) has bypassed every mutator in this module and must
  ## say so explicitly by calling this, or the change is invisible to both
  ## the index and (new in this stage) to `formats/kicad.writePcb`, which
  ## decides whether anything needs regenerating purely from `pcb.rev`.
  if pcb == nil: return
  inc pcb.rev
  if pcb.index != nil: pcb.index.dirty = true

proc touch*(pcb: Pcb, e: Copper | Zone | Hole | Placement | PcbLayer | Stackup | Outline) {.inline.} =
  ## `touch(pcb)` plus stamping the *same* new revision into `e.rev`. One
  ## global counter shared by every entity, rather than a per-entity counter
  ## each starting at zero, is what makes "which of these two changed more
  ## recently" answerable by a plain `>` with no possibility of two entities
  ## disagreeing about it after being touched in the same mutation.
  touch(pcb)
  if e != nil: e.rev = pcb.rev

# ---------------------------------------------------------------- layers

proc addLayer*(pcb: Pcb, l: PcbLayer): PcbLayer {.discardable.} =
  ## Registers `l` under `pcb.layers[l.name]` and assigns its stack position.
  ## Insertion order *is* physical stack order, so readers must add layers
  ## top-to-bottom.
  if pcb.layers.hasKey(l.name):
    raise newException(PcbError, "duplicate layer name: " & l.name)
  l.pcb = pcb
  l.index = pcb.layers.len
  if l.isCopper:
    var n = 0
    for _, other in pcb.layers:
      if other.isCopper: inc n
    l.copperIndex = n
  else:
    l.copperIndex = -1
  pcb.layers[l.name] = l
  touch(pcb)   ## `(layers)` is a whole-board-scoped refusal in the KiCad
               ## writer (see `formats/kicad.nim`), not a per-layer one, so
               ## there is nothing to gain from stamping `l.rev` here --
               ## `pcb.rev` alone is what the writer checks before refusing.
  result = l

proc addShape*(l: PcbLayer, s: Shape) =
  ## Appends `s` to `l.shapes` and touches the layer. `PcbLayer.shapes` used
  ## to be mutated by direct `seq` access before this stage, which cannot be
  ## dirty-tracked -- a `Shape` is a plain `object` with no field a reader
  ## could stamp `attrs["kicad.node"]` onto, and giving it one is untenable
  ## at 326,626 `fp_line` nodes on the largest demo board (one extra
  ## `Table` entry per line would dwarf the arena itself). So graphics are
  ## dirty-tracked at `l.rev` alone: enough to know *something* changed,
  ## never *what*. Since `formats/kicad.writePcb` does not regenerate
  ## graphics at all this stage, any detected change here is exactly what
  ## turns into a named refusal rather than a silently stale write.
  l.shapes.add(s)
  touch(l.pcb, l)

proc setShape*(l: PcbLayer, i: int, s: Shape) =
  l.shapes[i] = s
  touch(l.pcb, l)

proc removeShape*(l: PcbLayer, i: int) =
  l.shapes.delete(i)
  touch(l.pcb, l)

proc copperLayers*(pcb: Pcb): seq[PcbLayer] =
  ## Copper layers in stack order, top first.
  for _, l in pcb.layers:
    if l.isCopper: result.add(l)

proc layer*(pcb: Pcb, name: string): PcbLayer =
  ## `nil` when absent, matching the `getOrDefault` idiom used for the
  ## name-keyed tables in `netlist/formats/spice`.
  pcb.layers.getOrDefault(name)

# ---------------------------------------------------------------- copper

proc registerNet(pcb: Pcb, c: Copper) =
  if pcb == nil or c.net == nil: return
  if not pcb.netCopper.hasKey(c.net.name):
    pcb.netCopper[c.net.name] = @[]
  pcb.netCopper[c.net.name].add(c)

proc unregisterNet(pcb: Pcb, c: Copper) =
  if pcb == nil or c.net == nil: return
  if not pcb.netCopper.hasKey(c.net.name): return
  var s = pcb.netCopper[c.net.name]
  for i in 0 ..< s.len:
    if s[i] == c:
      s.delete(i)
      break
  pcb.netCopper[c.net.name] = s

proc addCopper*(l: PcbLayer, c: Copper): Copper {.discardable.} =
  ## Appends `c` to `l.copper`, caches its bounding box, records its source
  ## ordinal, and registers it under its net name if it already has one.
  if l == nil:
    raise newException(PcbError, "cannot add copper to a nil layer")
  c.layer = l
  c.box = box(c.shape)
  c.sourceIndex = l.copper.len
  l.copper.add(c)
  registerNet(l.pcb, c)
  touch(l.pcb, c)
  result = c

proc setNet*(c: Copper, n: Net) =
  ## Re-points `c` at net `n` (or `nil`), keeping `Pcb.netCopper` correct.
  if c.net == n: return
  let pcb = if c.layer != nil: c.layer.pcb else: nil
  unregisterNet(pcb, c)
  c.net = n
  registerNet(pcb, c)
  touch(pcb, c)

proc setShape*(c: Copper, s: Shape) =
  ## Replaces the geometry and refreshes the cached bounding box.
  c.shape = s
  c.box = box(s)
  if c.layer != nil: touch(c.layer.pcb, c)

proc removeCopper*(l: PcbLayer, c: Copper) =
  ## Detaches `c` from its layer, its net index and any hole it belonged to.
  ##
  ## .. warning:: This renumbers `sourceIndex` on every later feature of the
  ##   layer, breaking ODB++ `FID` ordinals. Source ordinals are only valid
  ##   immediately after a load; do any positional resolution first.
  var found = -1
  for i in 0 ..< l.copper.len:
    if l.copper[i] == c:
      found = i
      break
  if found < 0:
    raise newException(PcbError, "copper feature not on layer " & l.name)
  unregisterNet(l.pcb, c)
  l.copper.delete(found)
  touch(l.pcb)   ## Global bump only -- **not** `touch(l.pcb, l)`. `l.rev` is
                  ## reserved exclusively for `PcbLayer.shapes` graphics edits
                  ## (`addShape`/`setShape`/`removeShape`, below), because
                  ## `formats/kicad.writePcb` refuses outright the moment a
                  ## layer's `rev` moves past its read-time snapshot -- it has
                  ## no regenerator for graphics at all. Copper deletion is a
                  ## *supported* edit (segments/vias/pads are a regenerable
                  ## class with their own delete sweep), so stamping `l.rev`
                  ## here would make an ordinary "rip up this track" trip the
                  ## same refusal meant for "I hand-edited the silkscreen".
  for i in found ..< l.copper.len:
    l.copper[i].sourceIndex = i
  if c.hole != nil:
    for i in 0 ..< c.hole.pads.len:
      if c.hole.pads[i] == c:
        c.hole.pads.delete(i)
        break
    c.hole = nil
  c.layer = nil

proc copperOn*(pcb: Pcb, netName: string, layerName = ""): seq[Copper] =
  ## Every copper feature on the named net, optionally restricted to one
  ## layer. This is the by-name lookup the model exists to make cheap.
  if not pcb.netCopper.hasKey(netName): return
  if layerName.len == 0:
    return pcb.netCopper[netName]
  for c in pcb.netCopper[netName]:
    if c.layer != nil and c.layer.name == layerName:
      result.add(c)

proc copperOn*(pcb: Pcb, net: Net, layerName = ""): seq[Copper] =
  if net == nil: return
  copperOn(pcb, net.name, layerName)

# ---------------------------------------------------------------- apertures

proc internAperture*(pcb: Pcb, a: Aperture): Aperture =
  ## Returns the shared instance for `a.name`, storing `a` if it is new. One
  ## `Aperture` object then backs every pad that uses that shape.
  ##
  ## `touch(pcb)` only, no entity form: `Aperture` is not one of the seven
  ## types `rev` was added to (it is shared, interned data, not a per-board
  ## placed feature the KiCad writer ever regenerates on its own), so there
  ## is nothing to stamp beyond the board-level counter.
  if a == nil: return nil
  if pcb.apertures.hasKey(a.name):
    return pcb.apertures[a.name]
  pcb.apertures[a.name] = a
  touch(pcb)
  result = a

# ---------------------------------------------------------------- holes

proc addHole*(pcb: Pcb, h: Hole): Hole {.discardable.} =
  pcb.holes.add(h)
  touch(pcb, h)
  result = h

proc attachPad*(h: Hole, c: Copper) =
  ## Ties an annular ring or land to the hole that drills it.
  if h == nil or c == nil: return
  if c.hole == h: return
  c.hole = h
  h.pads.add(c)
  if h.net != nil and c.net == nil:
    setNet(c, h.net)
  touch((if c.layer != nil: c.layer.pcb else: nil), h)

proc setSpan*(h: Hole, fromLayer, toLayer: PcbLayer) =
  ## Sets the inclusive copper span and derives the via classification from
  ## it: a span touching neither outer layer is buried, one touching exactly
  ## one is blind, both is through.
  h.fromLayer = fromLayer
  h.toLayer = toLayer
  let pcb = if fromLayer != nil: fromLayer.pcb elif toLayer != nil: toLayer.pcb else: nil
  touch(pcb, h)
  if h.kind != hkVia or fromLayer == nil or toLayer == nil: return
  if h.viaKind == vkMicro: return
  let touchesTop = fromLayer.side == lsTop or toLayer.side == lsTop
  let touchesBottom = fromLayer.side == lsBottom or toLayer.side == lsBottom
  h.viaKind =
    if touchesTop and touchesBottom: vkThrough
    elif touchesTop or touchesBottom: vkBlind
    else: vkBuried

proc spanLayers*(pcb: Pcb, h: Hole): seq[PcbLayer] =
  ## Every copper layer the hole passes through, inclusive of its endpoints.
  ## An unset span means the full board.
  let cu = copperLayers(pcb)
  if cu.len == 0: return
  let
    a = if h.fromLayer == nil: 0 else: h.fromLayer.copperIndex
    b = if h.toLayer == nil: cu.high else: h.toLayer.copperIndex
  if a < 0 or b < 0: return cu
  for i in min(a, b) .. max(a, b):
    result.add(cu[i])

# ---------------------------------------------------------------- zones

proc addZone*(pcb: Pcb, z: Zone): Zone {.discardable.} =
  ## Registers the zone and, for each of its layers, creates and adds the
  ## matching `ckZone` copper record for the authored outline.
  ##
  ## .. warning:: That `ckZone` record is the *authored* outline, not real
  ##   copper -- `fem/extrude.extrudeCopper` must skip it (`cu.kind == ckZone`)
  ##   and mesh `Zone.fills` instead, or a plane gets meshed twice: once here
  ##   as a solid slab with no clearances, once again (correctly) from
  ##   `extrudeZones`. See `Zone.fills`'s own doc comment.
  pcb.zones.add(z)
  z.outline.normalize()
  for l in z.layers:
    let c = newCopper(ckZone, fill(z.outline))
    c.net = z.net
    discard addCopper(l, c)
    z.areas.add(c)
  touch(pcb, z)
  result = z

proc addZoneLayer*(pcb: Pcb, z: Zone, l: PcbLayer) =
  ## Extends an already-added zone onto another layer.
  z.layers.add(l)
  let c = newCopper(ckZone, fill(z.outline))
  c.net = z.net
  discard addCopper(l, c)
  z.areas.add(c)
  touch(pcb, z)

proc addZoneFill*(pcb: Pcb, z: Zone, l: PcbLayer, poly: Polygon): Copper {.discardable.} =
  ## Registers one derived fill polygon of `z` on layer `l`: a `ckFill`
  ## record on the zone's net, added through `addCopper` so it lands in
  ## `Pcb.netCopper` and the spatial index like any other copper feature, and
  ## appended to `z.fills`.
  ##
  ## `poly` is taken as given, not re-derived from `z.outline` -- the whole
  ## point of a fill is that it is *not* the authored outline (clearances,
  ## thermal reliefs, priority against other zones all reshape it), so this
  ## proc has no opinion on where `poly` came from. A KiCad reader passes the
  ## `(filled_polygon)` points directly; nothing here could reconstruct that
  ## shape from `z.outline` alone even if it wanted to.
  let c = newCopper(ckFill, fill(poly))
  c.net = z.net
  discard addCopper(l, c)
  z.fills.add(c)
  touch(pcb, z)
  result = c

# ---------------------------------------------------------------- placements

proc addPlacement*(pcb: Pcb, p: Placement): Placement {.discardable.} =
  if pcb.placements.hasKey(p.designator):
    raise newException(PcbError, "duplicate reference designator: " & p.designator)
  p.pcb = pcb
  pcb.placements[p.designator] = p
  touch(pcb, p)
  result = p

proc bindComponent*(p: Placement, c: Component) =
  ## Links a placement to its `verax/netlist` component.
  ##
  ## The designators normally agree -- they are the join key in both file
  ## formats. The one exception is a multi-channel package: `c` may be one
  ## *section* of the part, whose own designator is arbitrary, joined to the
  ## placement through `package.ref`. Then the section is recorded in
  ## `p.sections` and `p.component` is left nil, because there is no single
  ## netlist component this placement *is*.
  if c == nil: return
  if p.designator == c.designator:
    p.component = c
    touch(p.pcb, p)
    return
  let r = packageRef(c)
  if r.has and r.value == p.designator:
    let s = packageSection(c)
    p.sections[(if s.has: s.value else: "")] = c
    touch(p.pcb, p)
    return
  raise newException(PcbError,
    "designator mismatch binding placement '" & p.designator &
    "' to component '" & c.designator & "'" &
    (if r.has: " (its package.ref is '" & r.value & "')"
     else: "; a placement and a component join on the reference designator, " &
           "or on the component's package.ref for a multi-channel part"))

proc placementOf*(pcb: Pcb, c: Component): Placement =
  ## The placement for a netlist component, or `nil` if it was never placed.
  ## For a section of a multi-channel package the placement is keyed by the
  ## package's board designator, not the section's own, so fall back to a
  ## scan of `Placement.sections`.
  if c == nil: return nil
  result = pcb.placements.getOrDefault(c.designator)
  if result != nil and result.component == c: return
  if result != nil and result.component == nil and result.sections.len == 0:
    return   # an unbound footprint that shares the designator, as before
  for _, p in pcb.placements:
    for _, sc in p.sections:
      if sc == c: return p
  result = nil

proc addLand*(p: Placement, pinName: string, c: Copper) =
  ## Records `c` as copper belonging to pin `pinName` of this placement, and
  ## points it at the matching `verax/netlist` pin when the placement is
  ## bound to a component.
  c.kind = ckLand
  if p.component != nil and p.component.pins.hasKey(pinName):
    let pin = p.component.pins[pinName]
    c.pin = pin
    if c.net == nil and pin.net != nil:
      setNet(c, pin.net)
  elif p.component == nil and p.sections.len > 0:
    # A multi-channel package: `pinName` is a package pad id. Resolve it
    # through the definition to `(section, logical)` and bind from that
    # section's own pin. A pad the definition does not declare leaves
    # `c.pin` nil rather than guessing.
    var defName = ""
    for _, sc in p.sections:
      let dn = packageDefName(sc)
      if dn.has: defName = dn.value
      break
    if defName.len > 0 and isPackageRegistered(defName):
      let def = packageDef(defName)
      if def.pins.hasKey(pinName):
        let pp = def.pins[pinName]
        if pp.section.len > 0 and p.sections.hasKey(pp.section) and
           p.sections[pp.section].pins.hasKey(pp.logical):
          let pin = p.sections[pp.section].pins[pp.logical]
          c.pin = pin
          if c.net == nil and pin.net != nil:
            setNet(c, pin.net)
        elif pp.section.len == 0:
          # a global pin: bind from whichever section carries it
          for _, sc in p.sections:
            if sc.pins.hasKey(pp.logical):
              let pin = sc.pins[pp.logical]
              c.pin = pin
              if c.net == nil and pin.net != nil:
                setNet(c, pin.net)
              break
  if not p.lands.hasKey(pinName):
    p.lands[pinName] = @[]
  p.lands[pinName].add(c)
  touch(p.pcb, p)

proc addPlacementHole*(p: Placement, h: Hole) =
  p.holes.add(h)
  if p.pcb != nil:
    discard addHole(p.pcb, h)
  touch(p.pcb, p)

proc landsOn*(p: Placement, layerName: string): seq[Copper] =
  for _, cs in p.lands:
    for c in cs:
      if c.layer != nil and c.layer.name == layerName:
        result.add(c)

# ---------------------------------------------------------------- stackup

proc addStackEntry*(pcb: Pcb, e: StackEntry): StackEntry {.discardable.} =
  ## Appends to the build-up. Entries are added top to bottom.
  if pcb.stackup == nil: pcb.stackup = newStackup()
  pcb.stackup.entries.add(e)
  pcb.stackup.totalThickness = pcb.stackup.totalThickness + e.thickness
  touch(pcb, pcb.stackup)
  result = e

proc stackEntryFor*(pcb: Pcb, l: PcbLayer): StackEntry =
  if pcb.stackup == nil or l == nil: return nil
  for e in pcb.stackup.entries:
    if e.layer == l: return e
  nil

proc dielectricBetween*(pcb: Pcb, a, b: PcbLayer): seq[StackEntry] =
  ## The dielectric entries physically between two copper layers -- the
  ## substrate a via passes through, or the material separating a trace from
  ## its reference plane.
  if pcb.stackup == nil or a == nil or b == nil: return
  var ia, ib = -1
  for i, e in pcb.stackup.entries:
    if e.layer == a: ia = i
    if e.layer == b: ib = i
  if ia < 0 or ib < 0: return
  for i in min(ia, ib) + 1 ..< max(ia, ib):
    if pcb.stackup.entries[i].kind == seDielectric:
      result.add(pcb.stackup.entries[i])

# ---------------------------------------------------------------- whole board

proc boardBox*(pcb: Pcb): Box =
  ## Extent of the board outline if there is one, else of all copper.
  if pcb.outline != nil and pcb.outline.boundary.outer.curves.len > 0:
    return box(pcb.outline.boundary)
  result = emptyBox()
  for _, l in pcb.layers:
    for c in l.copper:
      result = union(result, c.box)
