## Netlist -> blank `Pcb`: standard layers, a synthesized stack-up, a
## rectangular outline, and every physical part placed on a deterministic
## grid with its real footprint ("update PCB from schematic").
##
## **The hierarchy is not flattened** (`pcb/` must not depend on `spice`):
## this walks instances itself and names a leaf `hierName("X1", "U1")`, as
## `spice/flatten` would.
##
## **Every synthesized figure is an `Assumption`**: a board nobody specified
## must not pass silently into derived PDN/SI numbers.
##
## **Footprint resolution**: the component's `footprint`, then (for a
## multi-channel package) `PackageDef.footprint`, else
## `footprint_unresolved` -- reported, never skipped.

import std/[algorithm, strutils, tables]

import ./units
import ./geometry
import ./types
import ./graph
# The only writer; see `writeBoard`.
import ./footprint
import ./formats/kicad as kicadFormat
import ../netlist/types as nltypes
import ../netlist/graph as nlgraph
import ../netlist/packages
# The `footprint` accessor and `Assumption`.
import ../netlist/annotations
import ../netlist/issue

export issue

type
  AssembleOptions* = object
    copperLayers*: int
      ## 2, 4, 6 ...; less than 2 is clamped to 2.
    boardSize*: tuple[w, h: Nm]
    origin*: Point
    gridPitch*: Nm
      ## `0` derives spacing per placement (courtyard, then body box, then a
      ## fixed pitch; see `gridSpacing`).
    placeOutside*: bool
      ## Default `true`: the grid sits right of the outline, so parts don't
      ## start overlapping the board edge.

const
  DefaultBoardWidth = mm(100.0)
  DefaultBoardHeight = mm(80.0)
  DefaultStackTotal = mm(1.6)
  CopperWeight = um(35.0)
  FallbackPitch = mm(5.0)
  GridGap = mm(1.0)
    ## Clearance between adjacent placements, on top of each half-extent.

proc defaultAssembleOptions*(): AssembleOptions =
  AssembleOptions(copperLayers: 2, boardSize: (DefaultBoardWidth, DefaultBoardHeight),
                  origin: pt(nm(0), nm(0)), gridPitch: nm(0), placeOutside: true)

# ---------------------------------------------------------------- layers

proc addStandardLayers(pcb: Pcb, copperLayers: int) =
  ## Top to bottom (insertion order is stack order): `F.Cu`, inner layers,
  ## `B.Cu`, non-copper layers grouped by kind, then `Edge.Cuts`.
  discard addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  for i in 1 .. copperLayers - 2:
    discard addLayer(pcb, newPcbLayer("In" & $i & ".Cu", lfSignal, lsInner))
  discard addLayer(pcb, newPcbLayer("B.Cu", lfSignal, lsBottom))
  for (suffix, fn) in [("Paste", lfSolderPaste), ("Mask", lfSolderMask),
                       ("SilkS", lfSilkscreen), ("CrtYd", lfCourtyard),
                       ("Fab", lfFabrication)]:
    discard addLayer(pcb, newPcbLayer("F." & suffix, fn, lsTop))
    discard addLayer(pcb, newPcbLayer("B." & suffix, fn, lsBottom))
  discard addLayer(pcb, newPcbLayer("Edge.Cuts", lfBoardOutline, lsNone))

# ---------------------------------------------------------------- stackup

proc buildStackup(pcb: Pcb, copperLayerCount: int): seq[Assumption] =
  ## A plain FR4 profile: 1.6 mm total, 35 um copper per layer, dielectric
  ## split evenly, `epsilonR = 4.5`, `lossTangent = 0.02`. All invented and
  ## recorded; override the `StackEntry`s before comparing against a real
  ## board.
  let cu = copperLayers(pcb)
  let gaps = max(1, cu.len - 1)
  let copperTotal = CopperWeight * cu.len
  let dielectricEach =
    if DefaultStackTotal <= copperTotal: nm(1)
    else: (DefaultStackTotal - copperTotal) div gaps
  let fr4 = newStackMaterial("FR4", epsilonR = 4.5, lossTangent = 0.02)
  for i, l in cu:
    let e = newStackEntry(seCopper, l.name, CopperWeight)
    e.layer = l
    e.copperWeight = 1.0   # 1 oz/ft^2, the ~35 um this entry states
    discard addStackEntry(pcb, e)
    if i < cu.high:
      let d = newStackEntry(seDielectric, "dielectric " & $(i + 1), dielectricEach)
      d.material = fr4
      discard addStackEntry(pcb, d)
  result.add assumption("stackup", "totalThickness", DefaultStackTotal.toMm, "mm",
    annDefaulted, "no stack-up was authored; assumed a plain " & $cu.len &
    "-layer FR4 profile (35 um copper, epsilonR 4.5, loss tangent 0.02)")

# ---------------------------------------------------------------- outline

proc buildOutline(pcb: Pcb, opts: AssembleOptions) =
  let w = opts.boardSize.w
  let h = opts.boardSize.h
  let o = opts.origin
  let corners = [o, pt(o.x + w, o.y), pt(o.x + w, o.y + h), pt(o.x, o.y + h)]
  pcb.outline.boundary = Polygon(outer: polyline(corners, closed = true))
  let edge = pcb.layer("Edge.Cuts")
  for i in 0 ..< 4:
    addShape(edge, stroke(path(@[seg(corners[i], corners[(i + 1) mod 4])]), mm(0.1)))
  touch(pcb, pcb.outline)

# ---------------------------------------------------------------- part collection

type
  PhysicalPart = object
    designator: string
      ## Board designator: `hierName(path)`, or the shared `package.ref` for a
      ## multi-channel package.
    members: seq[Component]
      ## One component, except a multi-channel package's sections.
    packaged: bool
    defName: string

proc collectLeaves(nl: Netlist, prefix: string,
                   res: var seq[tuple[c: Component, path: string]]) =
  ## Every leaf component under `nl`, walking instances rather than
  ## flattening (a private copy of the walk, to avoid a dependency).
  for _, c in nl.components:
    let p = nlgraph.hierName(prefix, c.designator)
    if c.subNetlist != nil:
      collectLeaves(c.subNetlist, p, res)
    else:
      res.add (c, p)

proc buildPhysicalParts(nl: Netlist): seq[PhysicalPart] =
  var leaves: seq[tuple[c: Component, path: string]]
  collectLeaves(nl, "", leaves)
  var byPkg: OrderedTable[string, int]
  for (c, path) in leaves:
    let r = packageRef(c)
    if r.has:
      if not byPkg.hasKey(r.value):
        byPkg[r.value] = result.len
        result.add PhysicalPart(designator: r.value, packaged: true)
      let i = byPkg[r.value]
      result[i].members.add c
      let dn = packageDefName(c)
      if dn.has: result[i].defName = dn.value
    else:
      result.add PhysicalPart(designator: path, members: @[c], packaged: false)

proc footprintSpecFor(pp: PhysicalPart): string =
  ## The component's own `footprint` (any member of a package), then the
  ## package definition's.
  for m in pp.members:
    let f = footprint(m)
    if f.has: return f.value
  if pp.packaged and pp.defName.len > 0 and isPackageRegistered(pp.defName):
    return packageDef(pp.defName).footprint
  ""

# ---------------------------------------------------------------- footprint -> Pcb

proc resolvePadLayers(pcb: Pcb, tokens: seq[string]): seq[PcbLayer] =
  ## Expands raw KiCad pad layer tokens (`*.Cu`, `*.<suffix>`, bare names,
  ## deduped) against the board -- the same grammar as
  ## `kicadgeom.expandPadLayers`, but over a plain `seq[string]`.
  var seen: seq[string]
  for tok in tokens:
    if tok == "*.Cu":
      for l in copperLayers(pcb):
        if l.name notin seen: (seen.add l.name; result.add l)
    elif tok.startsWith("*."):
      let suffix = tok[1 .. ^1]
      for _, l in pcb.layers:
        if l.name.endsWith(suffix) and l.name notin seen:
          seen.add l.name; result.add l
    else:
      let l = pcb.layer(tok)
      if l != nil and l.name notin seen:
        seen.add l.name; result.add l

proc placeFootprint(pcb: Pcb, p: Placement, fp: Footprint,
                    issues: var seq[Issue]) =
  p.mount = fp.mount
  p.courtyard = fp.courtyard
  p.bodyBox = fp.bodyBox
  p.height = fp.height
  let t = Transform(origin: p.at, rot: p.rot, mirrorX: false)
  for pad in fp.pads:
    let ap = internAperture(pcb, pad.aperture)
    let layersHere = resolvePadLayers(pcb, pad.layers)
    var produced = false
    for l in layersHere:
      if not l.isCopper: continue
      var c = newCopper(ckLand, geometry.pad(ap, apply(t, pad.at), pad.rot + p.rot))
      discard addCopper(l, c)
      addLand(p, pad.id, c)
      produced = true
    if pad.padType in {ptThruHole, ptNpThruHole} and pad.drillDia > nm(0):
      var h = newHole((if pad.padType == ptNpThruHole: hkNonPlated else: hkPlated),
                      apply(t, pad.at), pad.drillDia)
      addPlacementHole(p, h)
      if p.lands.hasKey(pad.id):
        for c in p.lands[pad.id]: attachPad(h, c)
      produced = true
    if not produced:
      issues.add newIssue("footprint_pad_unmatched", sevWarning,
        p.designator & ": footprint pad '" & pad.id & "' produced no copper " &
        "(none of its layers " & pad.layers.join(", ") & " exist on this board)",
        components = (if p.component != nil: @[p.component] else: @[]))
  for (layerName, shape) in fp.graphics:
    let l = pcb.layer(layerName)
    if l != nil: addShape(l, apply(t, shape))
  # Pin <-> pad correspondence, both directions.
  if p.component != nil:
    for pinName, _ in p.component.pins:
      if not p.lands.hasKey(pinName):
        issues.add newIssue("footprint_pad_unmatched", sevWarning,
          p.designator & ": pin '" & pinName & "' has no matching footprint pad",
          components = @[p.component])
  for pad in fp.pads:
    var boundToAnything = false
    if p.lands.hasKey(pad.id):
      for c in p.lands[pad.id]:
        if c.pin != nil: boundToAnything = true
    if not boundToAnything and (p.component != nil or p.sections.len > 0):
      issues.add newIssue("footprint_pad_unmatched", sevWarning,
        p.designator & ": footprint pad '" & pad.id & "' matches no component pin",
        components = (if p.component != nil: @[p.component] else: @[]))

# ---------------------------------------------------------------- grid placement

proc footprintExtent(fp: Footprint): tuple[w, h: Nm] =
  ## Courtyard first, then body box, then a fixed pitch.
  if fp.courtyard.outer.curves.len > 0:
    let b = box(fp.courtyard)
    if not b.isEmpty: return (width(b), height(b))
  if not fp.bodyBox.isEmpty:
    return (width(fp.bodyBox), height(fp.bodyBox))
  (FallbackPitch, FallbackPitch)

# ---------------------------------------------------------------- assemble

proc assemble*(nl: Netlist, opts = defaultAssembleOptions()):
    tuple[pcb: Pcb, issues: seq[Issue], assumptions: seq[Assumption]] =
  var pcb = newPcb(nl.name, nl)
  var issues: seq[Issue]
  var assumptions: seq[Assumption]

  let copperN = max(2, opts.copperLayers)
  addStandardLayers(pcb, copperN)
  assumptions.add buildStackup(pcb, copperN)
  buildOutline(pcb, opts)

  let parts = buildPhysicalParts(nl)

  # Resolve and place first (at origin; the grid pass moves them), so
  # `issues` doesn't depend on the grid.
  var placed: seq[tuple[p: Placement, extent: tuple[w, h: Nm]]]
  for pp in parts:
    let spec = footprintSpecFor(pp)
    let fp = if spec.len > 0: findFootprint(spec) else: nil
    if fp == nil:
      let tried = footprintSources()
      issues.add newIssue("footprint_unresolved", sevError,
        pp.designator & ": " &
        (if spec.len == 0: "states no footprint (component `footprint` " &
                            "annotation, then the package definition's, " &
                            "resolved to nothing)"
         else: "footprint '" & spec & "' was not resolved") &
        (if tried.len == 0: " -- no footprint source is registered; " &
                            "`import verax/pcb/formats/kicadmod` for the " &
                            "KiCad library search path " &
                            "($VERAX_FOOTPRINT_PATH, $KICAD10_FOOTPRINT_DIR, " &
                            "$KICAD9_FOOTPRINT_DIR, /usr/share/kicad/footprints)"
         else: " -- tried: " & tried.join(", ")),
        components = pp.members)
      continue
    var place = newPlacement(pp.designator, fp.name)
    discard addPlacement(pcb, place)
    if pp.packaged:
      for m in pp.members: bindComponent(place, m)
    else:
      bindComponent(place, pp.members[0], pp.designator)
      place.attrs["assembly.path"] = pp.designator
    placeFootprint(pcb, place, fp, issues)
    placed.add (place, footprintExtent(fp))

  # Grid: row-major, sorted by designator so a re-run is byte-identical.
  placed.sort(proc (a, b: tuple[p: Placement, extent: tuple[w, h: Nm]]): int =
    cmp(a.p.designator, b.p.designator))

  let boardW = opts.boardSize.w
  let startX =
    if opts.placeOutside: opts.origin.x + boardW + GridGap
    else: opts.origin.x
  var cursorX = startX
  var cursorY = opts.origin.y
  var rowH = nm(0)
  let rowLimit = if opts.placeOutside: nm(0) else: opts.origin.x + boardW
    ## `0` when placing outside: the grid grows one way with no edge to
    ## wrap against.
  for (place, extent) in placed:
    let pitchW = if opts.gridPitch > nm(0): opts.gridPitch else: extent.w + GridGap
    let pitchH = if opts.gridPitch > nm(0): opts.gridPitch else: extent.h + GridGap
    if not opts.placeOutside and cursorX + pitchW > rowLimit and cursorX > startX:
      cursorX = startX
      cursorY = cursorY + rowH + GridGap
      rowH = nm(0)
    place.at = pt(cursorX + pitchW div 2, cursorY + pitchH div 2)
    touch(pcb, place)
    cursorX = cursorX + pitchW
    if pitchH > rowH: rowH = pitchH

  (pcb, issues, assumptions)

proc writeBoard*(nl: Netlist, path: string, opts = defaultAssembleOptions()): seq[Issue] =
  ## `assemble` a board and write it to `path`. Imports the KiCad writer
  ## directly (the only writer); `import verax/pcb` still doesn't export
  ## `readPcb`/`writePcb`/`KicadDoc`.
  let (pcb, issues, _) = assemble(nl, opts)
  result = issues
  kicadFormat.writePcb(pcb, path)
