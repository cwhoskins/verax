## Netlist -> blank `Pcb`: layers, a synthesized stack-up, a rectangular
## outline, and every physical part placed in a deterministic grid with its
## real footprint -- what KiCad calls "update PCB from schematic" and what a
## checked design is missing to become a board file at all
## (`pcb/CLAUDE.md`'s four gaps).
##
## **The hierarchy is not flattened.** `spice/flatten.nim` could do this job
## -- it imports nothing from `spice` -- but its own doc comment draws the
## line this module inherits: flattening destroys the hierarchy the designer
## wrote, which is a *simulation-only* concession, and `pcb/` must not gain
## an edge to `spice` to borrow it regardless. So this module walks the
## netlist itself and spells a leaf inside instance `X1` with the same
## `hierName("X1", "U1")` = `"X1.U1"` `spice/flatten` uses for deck
## designators -- unique by construction, and for a flat design (most of
## `designs/`) indistinguishable from the component's own designator.
##
## **Every synthesized number is an `Assumption`, never a silent default.**
## A layer stack, a stack-up and a board outline are all real facts about a
## physical board that no netlist states, so inventing one without saying so
## would let a derived PDN or SI number rest on a board nobody actually
## specified while reading as if it had been. This is the same discipline
## `spice/models` and `pcb/tline.characterize` already follow for an invented
## input.
##
## **Resolution order for a part's footprint**: the component's own
## `footprint` annotation, then (for a multi-channel package)
## `PackageDef.footprint`, then unresolved -- reported as `footprint_unresolved`
## rather than skipped, because a placement with no land pattern is not a
## smaller board, it is a board missing a part.

import std/[algorithm, strutils, tables]

import ./units
import ./geometry
import ./types
import ./graph
# The only writer today -- see `writeBoard`'s own doc comment for why this
# module, alone among the non-`formats/` pieces of `pcb/`, imports a format
# module directly rather than leaving that opt-in to the caller.
import ./footprint
import ./formats/kicad as kicadFormat
import ../netlist/types as nltypes
import ../netlist/graph as nlgraph
import ../netlist/packages
# Brings in the `footprint(c: Component): AnnValue[string]` accessor this
# module reads, and `Assumption`/`assumption` for the stack-up's own
# invented figures.
import ../netlist/annotations
import ../netlist/issue

export issue

type
  AssembleOptions* = object
    copperLayers*: int
      ## 2, 4, 6 ... clamped up to 2 if given less: a board with one copper
      ## layer is not a board this library can route anything on.
    boardSize*: tuple[w, h: Nm]
    origin*: Point
    gridPitch*: Nm
      ## `0` (the default) derives spacing per placement from its
      ## footprint's own courtyard extent, falling back to `bodyBox`, then a
      ## fixed pitch -- see `gridSpacing`.
    placeOutside*: bool
      ## Default `true`: the grid sits to the right of the outline rather
      ## than inside it, so a synthesized board is never handed back with
      ## parts already overlapping the edge they still need routing room
      ## inside of.

const
  DefaultBoardWidth = mm(100.0)
  DefaultBoardHeight = mm(80.0)
  DefaultStackTotal = mm(1.6)
  CopperWeight = um(35.0)
  FallbackPitch = mm(5.0)
  GridGap = mm(1.0)
    ## Clearance between adjacent placements' courtyards/body boxes in the
    ## grid, on top of each one's own half-extent.

proc defaultAssembleOptions*(): AssembleOptions =
  AssembleOptions(copperLayers: 2, boardSize: (DefaultBoardWidth, DefaultBoardHeight),
                  origin: pt(nm(0), nm(0)), gridPitch: nm(0), placeOutside: true)

# ---------------------------------------------------------------- layers

proc addStandardLayers(pcb: Pcb, copperLayers: int) =
  ## Top to bottom, since `Pcb.layers` insertion order *is* physical stack
  ## order (`pcb/CLAUDE.md`): `F.Cu`, `In1.Cu` .. `In(n-2).Cu`, `B.Cu`, then
  ## the non-copper layer families grouped by kind (`F.Paste`/`B.Paste`,
  ## `F.Mask`/`B.Mask`, ...), then `Edge.Cuts` last -- the board outline is
  ## not part of the copper/non-copper stack at all.
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
  ## A plain FR4 profile: `DefaultStackTotal` (1.6 mm) overall, 35 um copper
  ## on every copper layer, the remaining dielectric budget split evenly
  ## across the gaps between them, `epsilonR = 4.5`, `lossTangent = 0.02` --
  ## the same figures `spice/models`' package defaults and
  ## `pcb/tline.characterize`'s `roughness`/`rho` defaults use the identical
  ## "record it, don't just use it" discipline for. No board file, catalogue
  ## or datasheet backs any of these five numbers; a caller comparing a
  ## derived impedance or PDN figure against a *real* board's own stack-up
  ## should override every `StackEntry` this leaves behind before trusting
  ## the comparison.
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
      ## Board designator: `hierName(path)` for an ordinary leaf, the shared
      ## `package.ref` value for a multi-channel package (flat by
      ## construction -- see `pcb/graph.bindComponent`'s existing exception).
    members: seq[Component]
      ## Exactly one, except for a multi-channel package's sections.
    packaged: bool
    defName: string

proc collectLeaves(nl: Netlist, prefix: string,
                   res: var seq[tuple[c: Component, path: string]]) =
  ## Every non-hierarchical component under `nl`, walking `subNetlist`
  ## instances rather than flattening them -- the private `walkComponents`
  ## shape `netlist/packages.nim`/`netlist/pinmux.nim` each already keep
  ## their own copy of, for the same reason a third one belongs here rather
  ## than in either: none of the three may depend on another for one
  ## six-line iterator.
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
  ## Resolution order: the component's own `footprint` annotation (any
  ## member, for a packaged part -- they name the same physical land
  ## pattern), then the shared package definition's footprint, matching the
  ## order this module's own doc comment states.
  for m in pp.members:
    let f = footprint(m)
    if f.has: return f.value
  if pp.packaged and pp.defName.len > 0 and isPackageRegistered(pp.defName):
    return packageDef(pp.defName).footprint
  ""

# ---------------------------------------------------------------- footprint -> Pcb

proc resolvePadLayers(pcb: Pcb, tokens: seq[string]): seq[PcbLayer] =
  ## `FootprintPad.layers` is raw, un-expanded KiCad layer tokens (see
  ## `pcb/footprint.nim`'s doc comment on why) -- this is the board-side half
  ## of the same wildcard grammar `formats/kicadgeom.expandPadLayers`
  ## expands against a `SexpDoc`. Not a call to that proc: it needs a live
  ## board's parsed pad node to walk, and here there is a plain
  ## `seq[string]` and no `SexpDoc` at all -- a different input shape for
  ## the identical four-case grammar (`*.Cu`, `*.<suffix>`, a bare name, and
  ## de-duplication), not a second copy of the same proc.
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
  # Pin <-> pad correspondence, both directions -- the check
  # `docs/findings.md` §540 asked for and nothing before this stage could
  # run, since it needs a real footprint's pad list beside the netlist's pin
  # list, and no reader produced one.
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
  ## Courtyard first, then body box, then a fixed pitch -- the fallback
  ## ladder `pcb/CLAUDE.md`'s grid-spacing bullet states.
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

  # Resolve + place first (position `nm(0)` -- fixed up by the grid pass
  # below), so a caller inspecting `issues` alone never needs the grid to
  # have run.
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
    ## `0` (falsy as a limit -- never reached) when placing outside: the grid
    ## then grows in one column-free direction only, since there is no
    ## outline edge on that side to wrap against.
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
  ## `assemble` a board and write it to `path`. The only writer today is
  ## KiCad's (`formats/kicad.writePcb`'s synthesis branch, `pcb.source ==
  ## nil`), so this module imports it directly rather than exposing a second
  ## dispatch layer with one entry -- see `pcb/CLAUDE.md` for why that is a
  ## narrower exception to "formats stay opt-in per import" than it looks:
  ## `import verax/pcb` still does not expose `readPcb`/`writePcb`/`KicadDoc`
  ## (this module never `export`s them), only compiles them in, which a
  ## caller wanting to write a board at all cannot avoid regardless of which
  ## module does the importing.
  let (pcb, issues, _) = assemble(nl, opts)
  result = issues
  kicadFormat.writePcb(pcb, path)
