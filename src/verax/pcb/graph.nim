## Mutation API for the PCB data model. Keeps back-references on
## `PcbLayer`, `Copper`, `Hole`, `Zone` and `Placement` consistent, and keeps
## `Pcb.netCopper` and `Pcb.index` in step. Nothing else may set `.pcb`,
## `.layer`, `.net`, `.pin`, `.hole`, `.pads`, `.lands`, `.box`, `.index` or
## `.sourceIndex`. Electrical objects are built with `netlist/graph`, then
## geometry is linked to them.

import std/tables
import ./units
import ./geometry
import ./types
import ../netlist/types as nltypes
import ../netlist/packages

export types

proc touch*(pcb: Pcb) {.inline.} =
  ## Records a board change: bumps `pcb.rev` and dirties the spatial index.
  ## Exported: a direct field write (`p.rot = deg(90)`) must call it, or the
  ## change is invisible to the index and to `writePcb`.
  if pcb == nil: return
  inc pcb.rev
  if pcb.index != nil: pcb.index.dirty = true

proc touch*(pcb: Pcb, e: Copper | Zone | Hole | Placement | PcbLayer | Stackup | Outline) {.inline.} =
  ## `touch(pcb)` plus stamping the same revision into `e.rev`. One global
  ## counter makes "changed since T" a plain `>`.
  touch(pcb)
  if e != nil: e.rev = pcb.rev

# ---------------------------------------------------------------- layers

proc addLayer*(pcb: Pcb, l: PcbLayer): PcbLayer {.discardable.} =
  ## Registers `l` and assigns its stack position. Insertion order is stack
  ## order: add layers top to bottom.
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
  touch(pcb)   ## board-level only: the KiCad writer refuses layer-stack
               ## edits by checking `pcb.rev`
  result = l

proc addShape*(l: PcbLayer, s: Shape) =
  ## Appends `s` to `l.shapes` and touches the layer. Graphics are tracked
  ## at `l.rev` only (a `Shape` has no node to stamp, and adding one per
  ## `fp_line` would be too costly) -- enough for the KiCad writer to refuse
  ## rather than write stale graphics.
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
  ## `nil` when absent.
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
  ## Appends `c` to `l.copper`, caches its box, records its source ordinal,
  ## and registers it under its net name if it has one.
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
  ## Detaches `c` from its layer, net index and hole.
  ##
  ## .. warning:: Renumbers `sourceIndex` on every later feature, breaking
  ##   ODB++ `FID` ordinals; resolve positions first.
  var found = -1
  for i in 0 ..< l.copper.len:
    if l.copper[i] == c:
      found = i
      break
  if found < 0:
    raise newException(PcbError, "copper feature not on layer " & l.name)
  unregisterNet(l.pcb, c)
  l.copper.delete(found)
  touch(l.pcb)   ## global bump only, not `l.rev`: `l.rev` means a graphics
                  ## edit (which the KiCad writer refuses), and copper
                  ## deletion is a supported edit
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
  ## Every copper feature on the named net, optionally on one layer.
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
  ## Returns the shared instance for `a.name`, storing `a` if new. Board-level
  ## `touch` only (interned data, never regenerated on its own).
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
  ## Sets the inclusive copper span and derives the via class: touching
  ## neither outer layer is buried, one is blind, both is through.
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
  ## Every copper layer the hole passes through, inclusive; unset spans the
  ## full board.
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
  ## Registers the zone and adds a `ckZone` record of the authored outline on
  ## each layer.
  ##
  ## .. warning:: `ckZone` is not real copper: copper walks must skip it and
  ##   use `Zone.fills`, or a plane is counted twice.
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
  ## Registers one derived fill polygon of `z` on `l`: a `ckFill` on the
  ## zone's net via `addCopper` (so it's indexed like any copper), appended
  ## to `z.fills`. `poly` is taken as given (e.g. KiCad's `filled_polygon`).
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
  ## Links a placement to its netlist component by designator. For a
  ## multi-channel package section (joined via `package.ref`), records it in
  ## `p.sections` and leaves `p.component` nil.
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

proc bindComponent*(p: Placement, c: Component, path: string) =
  ## Binds `p` to `c` by hierarchical path (`"X1.U1"`), for a leaf whose own
  ## designator is local. Raises if `path != p.designator`: a mismatch would
  ## silently join the wrong copper to the wrong pins.
  if c == nil: return
  if p.designator != path:
    raise newException(PcbError,
      "bindComponent: path '" & path & "' does not match placement '" &
      p.designator & "'")
  p.component = c
  touch(p.pcb, p)

proc placementOf*(pcb: Pcb, c: Component): Placement =
  ## The placement for a netlist component, or `nil`. Falls back to scanning
  ## `p.sections` and `p.component`, which finds multi-channel sections and
  ## hierarchical binds (keyed by path, not `c.designator`).
  if c == nil: return nil
  result = pcb.placements.getOrDefault(c.designator)
  if result != nil and result.component == c: return
  if result != nil and result.component == nil and result.sections.len == 0:
    return   # an unbound footprint that shares the designator, as before
  for _, p in pcb.placements:
    if p.component == c: return p
    for _, sc in p.sections:
      if sc == c: return p
  result = nil

proc addLand*(p: Placement, pinName: string, c: Copper) =
  ## Records `c` as copper for pin `pinName`, pointing it at the netlist pin
  ## when the placement is bound.
  c.kind = ckLand
  if p.component != nil and p.component.pins.hasKey(pinName):
    let pin = p.component.pins[pinName]
    c.pin = pin
    if c.net == nil and pin.net != nil:
      setNet(c, pin.net)
  elif p.component == nil and p.sections.len > 0:
    # Multi-channel package: `pinName` is a pad id, resolved through the
    # definition to `(section, logical)`. An undeclared pad binds nothing.
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
  ## The dielectric entries between two copper layers.
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
