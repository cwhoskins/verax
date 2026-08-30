## Compatibility facade and pipeline coordinator for schematic layout.
##
## The implementation is split into cohesive internal include files so its
## private geometry and routing types remain internal to this module while the
## established public API remains unchanged.

import std/[algorithm, math, sets, strutils, tables]
import ../netlist/types
import ../netlist/kinds
import ../netlist/annotations
import ./scene
import ./pipeline

include ./geometry
include ./symbols
include ./router
include ./labels
include ./placement
include ./constrained
include ./routing

proc layout*(nl: Netlist, options: LayoutOptions): Schematic

proc layout*(nl: Netlist): Schematic =
  ## Places and routes `nl` with the historical pipeline configuration.
  layout(nl, defaultLayoutOptions())

proc layout*(nl: Netlist, options: LayoutOptions): Schematic =
  ## Places and routes `nl` into a renderer-neutral scene. Read-only with
  ## respect to the netlist; deterministic given the same netlist object.
  ## `options.stages` is filtered from the fixed canonical stage order.
  validateLayoutOptions(options)
  result.title = nl.name

  var comps: seq[Component]
  for _, c in nl.components: comps.add c
  let n = comps.len

  var syms = newSeq[SymbolDef](n)
  for i, c in comps: syms[i] = symbolFor(c)

  # --- placement: golden-angle seed, then Fruchterman-Reingold ------------
  var pos = newSeq[Point](n)
  for i in 0 ..< n:
    let t = float(i) * 2.399963229728653
    let r = 70.0 * sqrt(float(i + 1))
    pos[i] = Point(x: r * cos(t), y: r * sin(t))

  var idxOf = initTable[string, int]()
  for i, c in comps: idxOf[c.designator] = i

  # The historical policy deliberately leaves this golden-angle seed alone.
  # Layer columns are opt-in because changing even this first position changes
  # the established serialized SVG/JSON output.
  if options.policy == lpConstrainedLayered and options.stageEnabled(lsSemanticSeed):
    constrainedSemanticSeed(comps, pos, idxOf)

  # Orientation is co-optimised with placement: the attraction force below acts
  # pin-to-pin, so it needs each part's rotation, and the rotation that
  # minimises a part's wire depends on where its neighbours have been pushed.
  # Each iteration re-picks every rotation from a *snapshot* of the current
  # centres and rotations (fresh-write, snapshot-read), so the result never
  # depends on the order parts are visited. The last stretch of iterations
  # leaves rotation frozen so the centres settle against a fixed orientation,
  # and a final pass after separation gives the definitive assignment.
  var rots = newSeq[float](n)

  let k = 110.0
  let iterations = if options.stageEnabled(lsForcePlacement): 250 else: 0
  let temp0 = 2.0 * k
  for it in 0 ..< iterations:
    let temp = temp0 * (1.0 - float(it) / float(iterations))
    var disp = newSeq[Point](n)

    if it < iterations - 30:
      let pw = pinWorldPositions(comps, syms, pos, rots)
      var newRots = rots
      for i in 0 ..< n:
        newRots[i] = bestRotation(syms[i], comps[i], pos[i], rots[i], pw, grid)
      rots = newRots
    let pinWorld = pinWorldPositions(comps, syms, pos, rots)

    for i in 0 ..< n:
      for j in i + 1 ..< n:
        let dx = pos[i].x - pos[j].x
        let dy = pos[i].y - pos[j].y
        var d = sqrt(dx * dx + dy * dy)
        if d < 0.01: d = 0.01
        let f = k * k / d
        let fx = dx / d * f
        let fy = dy / d * f
        disp[i].x += fx
        disp[i].y += fy
        disp[j].x -= fx
        disp[j].y -= fy

    for _, net in nl.nets:
      if isGround(net): continue
      let w = if isRail(net): 0.35 else: 1.0
      # Pin-to-pin, not centre-to-centre: a net with pins on three parts pulls
      # each pair together, and a parallel pair sharing two nets is pulled by
      # both wires at once -- so its lowest-energy rest is the two parts side
      # by side with both pin pairs short, which centre-to-centre could never
      # express (both nets were the same centre vector, i.e. one doubled tug
      # toward overlap).
      let ps = net.pins
      for a in 0 ..< ps.len:
        for b in a + 1 ..< ps.len:
          let ca = ps[a].component
          let cb = ps[b].component
          if ca == nil or cb == nil or ca.designator == cb.designator: continue
          if ca.netlist != nl or cb.netlist != nl: continue
          if not (idxOf.hasKey(ca.designator) and
                  idxOf.hasKey(cb.designator)): continue
          let i = idxOf[ca.designator]
          let j = idxOf[cb.designator]
          let pa = pinWorld.getOrDefault(pinKey(ca, ps[a].name), pos[i])
          let pb = pinWorld.getOrDefault(pinKey(cb, ps[b].name), pos[j])
          let dx = pa.x - pb.x
          let dy = pa.y - pb.y
          var d = sqrt(dx * dx + dy * dy)
          if d < 0.01: d = 0.01
          let f = d * d / k * w
          let fx = dx / d * f
          let fy = dy / d * f
          disp[i].x -= fx
          disp[i].y -= fy
          disp[j].x += fx
          disp[j].y += fy

    for i in 0 ..< n:
      disp[i].x -= pos[i].x * 0.08
      disp[i].y -= pos[i].y * 0.08

    for i in 0 ..< n:
      let d = sqrt(disp[i].x * disp[i].x + disp[i].y * disp[i].y)
      if d > 0.0:
        let lim = min(d, temp)
        pos[i].x += disp[i].x / d * lim
        pos[i].y += disp[i].y / d * lim

  # Reassert deterministic left-to-right layers before the existing
  # legalization pass. It is policy-gated so lpHistorical remains unchanged.
  if options.policy == lpConstrainedLayered and
     options.stageEnabled(lsConstrainedRefinement):
    constrainedRefine(comps, pos, idxOf)

  # Snap centres to the grid, normalising -0.0 away so hashing stays exact.
  for i in 0 ..< n:
    pos[i].x = round(pos[i].x / grid) * grid
    pos[i].y = round(pos[i].y / grid) * grid
    if abs(pos[i].x) < 1e-9: pos[i].x = 0.0
    if abs(pos[i].y) < 1e-9: pos[i].y = 0.0

  # --- separation: inflated bodies never overlap, channels remain ---------
  # Each component is placed in deterministic order at the nearest grid cell
  # whose inflated body is clear of every already-placed body. Searching an
  # expanding ring outward from the force-layout position keeps the result
  # close to the layout while guaranteeing non-overlap (no best-effort pass).
  var ohw = newSeq[float](n)
  var ohh = newSeq[float](n)
  for i in 0 ..< n:
    ohw[i] = syms[i].bodyW / 2.0 + placementPad
    ohh[i] = syms[i].bodyH / 2.0 + placementPad

  let maxR = max(64, 4 * n)
  var placed: seq[int]
  for i in 0 ..< n:
    let cx = pos[i].x
    let cy = pos[i].y
    var done = false
    for r in 0 .. maxR:
      for dy in -r .. r:
        for dx in -r .. r:
          if max(abs(dx), abs(dy)) != r: continue
          let x = cx + float(dx) * grid
          let y = cy + float(dy) * grid
          if not overlapsAny(i, x, y, pos, ohw, ohh, placed):
            pos[i] = Point(x: x, y: y)
            done = true
            break
        if done: break
      if done: break
    doAssert done,
      "schematic placement could not separate component " & comps[i].designator
    placed.add i

  # --- packing: blocks that share no signal net are pulled back together --
  # The force layout's only long-range counter-force is a weak gravity, so
  # two disconnected sub-circuits drift as far apart as the repulsion carries
  # them. Group the parts by signal-net connectivity and shelf-pack the group
  # bounding boxes with a fixed gutter. A rigid grid-snapped translation per
  # group, so separation and the grid snap both survive it.
  if options.stageEnabled(lsPack):
    let group = groupsOf(nl, comps, pos, idxOf)
    packGroups(pos, ohw, ohh, group)

  # --- orientation: the definitive assignment once the centres are final ---
  # Separation and packing have moved parts since the loop froze rotation, so
  # re-pick every one from the settled centres. One pass, snapshot-read and
  # fresh-write like the loop, and with no hysteresis -- this is the answer,
  # not an increment toward it.
  if options.stageEnabled(lsOrient):
    rots = recomputeRotations(comps, syms, pos, rots)

  # --- leaf cleanup: a one-signal-net part snapped beside its net-mate ----
  # A part with a single non-ground / non-rail net still sits and points
  # wherever its one spring left it. Pull each up against the pin it connects
  # to and turn it to face there, so the router draws a short straight stub
  # rather than a long detour. Last, so it owns both the position and the
  # orientation of the leaves it touches.
  if options.stageEnabled(lsLeafSnap):
    leafSnap(comps, syms, pos, rots, ohw, ohh, idxOf)

  # Reserve complete, unshortened rail/ground glyphs before routing. This
  # bounded pass moves the smallest implicated symbols first; routing still
  # owns the defensive shortening/blocking path for irreducible crowding.
  if options.stageEnabled(lsTerminalRepair):
    repairTerminalClearance(comps, syms, pos, rots, ohw, ohh)

  # `recoverRouting` is the bounded routing-aware repair: candidates are
  # accepted only when they route strictly further. Its dedicated stage is an
  # opt-in alias for constrained policy callers; historical stage semantics
  # remain exactly as before.
  let useRecovery = options.stageEnabled(lsRecoverRouting) or
    (options.policy == lpConstrainedLayered and
     options.stageEnabled(lsRoutingAwareRepair))
  let scene =
    if useRecovery:
      recoverRouting(nl, comps, syms, pos, rots, idxOf, options)
    else:
      # A disabled recovery policy still produces the ordinary typed fallback
      # scene for an unrouteable net rather than raising.
      routeScene(nl, comps, syms, pos, rots, idxOf, withFallbacks = true,
                 constrained = options.policy == lpConstrainedLayered)

  result.parts = scene.parts
  result.ports = scene.ports
  result.wires = scene.wires
  result.junctions = scene.junctions
  result.fallbacks = scene.fallbacks

  var pinPos = scene.pinPos
  var partIdxByDesig = scene.partIdxByDesig
  var portedNets = scene.portedNets
  var railLabelReqs = scene.railLabelReqs

  # These wrappers mirror the ones inside `routeScene`; the label pass needs
  # the same rail/ground reading when it decides which nets get a name label.
  proc ownsPin(p: Pin): bool =
    p.component != nil and p.component.netlist == nl
  proc isGroundHere(net: Net): bool =
    net != nil and isGround(net) and net.kind != ntPower
  proc isRailHere(net: Net): bool =
    net != nil and isRail(net) and not isGroundHere(net)

  # --- label placement --------------------------------------------------------
  # Part designators/values, signal-net names and supply-rail names are all
  # placedBoxes here by a first-fit search against the finished geometry, in that
  # order (a designator adrift from its body reads worse than a net name adrift
  # from its pin), each tested against every label already placedBoxes. `bodyRects`
  # are the *drawn* ink boxes and the port bodies -- not the routing-inflated
  # obstacles: a label may sit in a routing channel, and the wire test already
  # covers the channels a wire actually took. If every candidate collides,
  # candidate 0 is used anyway, so a label is never dropped.
  let allWires = result.wires
  var placedBoxes: seq[Rect]
  var bodyRects: seq[Rect]
  for p in result.parts: bodyRects.add partInk(p)
  for p in result.ports: bodyRects.add portBody(p)
  # The ground/supply glyph `svg` caps each rail/ground stub with reaches
  # ~10 units perpendicular and ~8 along the stub -- decoration, not a wire, so
  # add its footprint here or a label would land across the bars.
  for w in result.wires:
    if w.kind in {wkGround, wkSupply} and w.points.len > 0:
      let e = w.points[^1]
      bodyRects.add (e.x - 13.0, e.y - 13.0, e.x + 13.0, e.y + 13.0)
  var newLabels: seq[SchematicLabel]

  # A symbol draws a short lead from each pin in to its glyph -- the span
  # between the pin (on `bodyW`/`bodyH`) and the ink rect. `svg` strokes those,
  # not `layout`, so they are not in `allWires`; add them here so a label on a
  # crowded part's occupied side is still rejected off them.
  var leadSegs: seq[tuple[a, b: Point]]
  for p in result.parts:
    if p.isBox: continue
    let ik = partInk(p)
    for pin in p.pins:
      let pt = Point(x: pin.x, y: pin.y)
      let d = escapeDir(p, pt)
      let e =
        if d.x != 0.0: Point(x: (if d.x > 0.0: ik.x2 else: ik.x1), y: pt.y)
        elif d.y != 0.0: Point(x: pt.x, y: (if d.y > 0.0: ik.y2 else: ik.y1))
        else: pt
      if abs(e.x - pt.x) > 1e-6 or abs(e.y - pt.y) > 1e-6:
        leadSegs.add (a: pt, b: e)

  # Fallback stubs are drawn by `svg` like wires (dashed, amber), so a label
  # must avoid crossing them exactly as it avoids a real wire -- even though
  # the stub is not connectivity and never appears in `allWires`.
  var fallbackSegs: seq[tuple[a, b: Point]]
  for f in result.fallbacks:
    for k in 0 ..< f.points.high:
      let a = f.points[k]
      let b = f.points[k + 1]
      if abs(a.x - b.x) > 1e-6 or abs(a.y - b.y) > 1e-6:
        fallbackSegs.add (a: a, b: b)

  proc overlapArea(a, b: Rect): float =
    let w = min(a.x2, b.x2) - max(a.x1, b.x1)
    let h = min(a.y2, b.y2) - max(a.y1, b.y1)
    if w > 0.0 and h > 0.0: w * h else: 0.0

  proc penalty(box: Rect, skipBody: int): float =
    ## 0 when the spot is clear; otherwise a cost, so a fully boxed-in label
    ## falls back to the *least bad* spot rather than blindly to candidate 0.
    ## A wire or lead crossing dominates any amount of body/label overlap.
    let ob = @[Obstacle(x1: box.x1, y1: box.y1, x2: box.x2, y2: box.y2)]
    for w in allWires:
      for i in 1 ..< w.points.len:
        if segBlocked(w.points[i - 1], w.points[i], ob): result += 1.0e6
    for s in leadSegs:
      if segBlocked(s.a, s.b, ob): result += 1.0e6
    for s in fallbackSegs:
      if segBlocked(s.a, s.b, ob): result += 1.0e6
    for k in 0 ..< bodyRects.len:
      if k != skipBody: result += overlapArea(box, bodyRects[k])
    for r in placedBoxes:
      result += 2.0 * overlapArea(box, r)

  proc place(lines: seq[LabelLine], ik: Rect, order: seq[Side],
             owner: string, skipBody: int) =
    if lines.len == 0: return
    let h = blockHeight(lines)
    let cands = candidatesAround(ik, h, order)
    var chosen = layoutBlock(lines, cands[0].refX, cands[0].refTop,
                             cands[0].anchor, owner)
    var best = penalty(chosen.box, skipBody)
    if best > 0.0:
      for c in cands:
        let b = layoutBlock(lines, c.refX, c.refTop, c.anchor, owner)
        let p = penalty(b.box, skipBody)
        if p < best - 1e-9:
          best = p
          chosen = b
          if p == 0.0: break
    for lb in chosen.labels: newLabels.add lb
    placedBoxes.add chosen.box

  for idx, p in result.parts:
    # A box draws its own designator/value inside the body (`svg.drawPart`),
    # where `boxSlots` reserved the room -- only symbol parts are labelled here.
    if p.isBox: continue
    var lines: seq[LabelLine]
    if p.designator.len > 0: lines.add (p.designator, designatorSize, lrDesignator)
    if p.value.len > 0: lines.add (p.value, valueSize, lrValue)
    if lines.len == 0: continue
    var occupied: set[Side]
    for pin in p.pins:
      let d = escapeDir(p, Point(x: pin.x, y: pin.y))
      if d.x > 0.5: occupied.incl sRight
      elif d.x < -0.5: occupied.incl sLeft
      elif d.y > 0.5: occupied.incl sBottom
      elif d.y < -0.5: occupied.incl sTop
    var order: seq[Side]
    for s in [sRight, sTop, sLeft, sBottom]:
      if s notin occupied: order.add s
    for s in [sRight, sTop, sLeft, sBottom]:
      if s in occupied: order.add s
    place(lines, partInk(p), order, p.designator, idx)

  # Signal-net names: near the net's leftmost-then-topmost owned pin, as before,
  # but now searched around it -- and the anchor pin's own wire leaves along
  # its escape direction, so that side is tried last. A net drawn as fallbacks
  # is labelled at each fallback pin instead (below), so its name is not
  # duplicated by this pass.
  var fallbackNets = initHashSet[string]()
  for f in result.fallbacks: fallbackNets.incl f.net
  for _, net in nl.nets:
    if isGroundHere(net) or isRailHere(net): continue
    if net.name.len == 0: continue
    if net.name in portedNets: continue
    if net.name in fallbackNets: continue
    var anchor: Point
    var anchorEsc: Point
    var have = false
    for p in net.pins:
      if not ownsPin(p): continue
      let key = pinKey(p.component, p.name)
      if not pinPos.hasKey(key): continue
      if not partIdxByDesig.hasKey(p.component.designator): continue
      let pt = pinPos[key]
      if not have or pt.x < anchor.x - 1e-9 or
         (abs(pt.x - anchor.x) <= 1e-9 and pt.y < anchor.y):
        anchor = pt
        anchorEsc = escapeDir(result.parts[partIdxByDesig[p.component.designator]], pt)
        have = true
    if not have: continue
    let escSide =
      if anchorEsc.x > 0.5: sRight
      elif anchorEsc.x < -0.5: sLeft
      elif anchorEsc.y > 0.5: sBottom
      else: sTop
    var order: seq[Side]
    for s in [sTop, sRight, sLeft, sBottom]:
      if s != escSide: order.add s
    order.add escSide
    let dot: Rect = (anchor.x, anchor.y, anchor.x, anchor.y)
    place(@[(net.name, netLabelSize, lrNet)], dot, order, "", -1)

  # Fallback names: the exact net name at each fallback pin, searched like a
  # net name but with the pin's escape side -- where the dashed stub leaves --
  # tried last. A zero-space fallback has no stub but still gets its name at
  # the pin, so a dangling connection is never anonymous.
  for f in result.fallbacks:
    let escSide =
      if f.ex > 0.5: sRight
      elif f.ex < -0.5: sLeft
      elif f.ey > 0.5: sBottom
      else: sTop
    var order: seq[Side]
    for s in [sTop, sRight, sLeft, sBottom]:
      if s != escSide: order.add s
    order.add escSide
    let dot: Rect = (f.x, f.y, f.x, f.y)
    place(@[(f.net, netLabelSize, lrNet)], dot, order, "", -1)

  # Supply-rail names: at the stub end, biased to sit past the glyph. The dot
  # is inflated to the rail glyph's ~10-unit half-extent so the label clears
  # the bars.
  for req in railLabelReqs:
    const g = 10.0
    let dot: Rect = (req.at.x - g, req.at.y - g, req.at.x + g, req.at.y + g)
    let horiz = abs(req.dir.x) > abs(req.dir.y)
    let order =
      if horiz:
        if req.dir.x >= 0.0: @[sRight, sTop, sBottom, sLeft]
        else: @[sLeft, sTop, sBottom, sRight]
      else:
        @[sRight, sLeft, sTop, sBottom]
    place(@[(req.text, netLabelSize, lrRail)], dot, order, "", -1)

  if options.stageEnabled(lsLabels):
    result.labels.add newLabels

  # --- bounding box -------------------------------------------------------
  var minX, minY, maxX, maxY: float
  var have = false
  proc includePt(x, y: float) =
    if not have:
      minX = x; maxX = x; minY = y; maxY = y; have = true
    else:
      if x < minX: minX = x
      if x > maxX: maxX = x
      if y < minY: minY = y
      if y > maxY: maxY = y
  for p in result.parts:
    includePt(p.x - p.bodyW / 2.0 - 50.0, p.y - p.bodyH / 2.0 - 50.0)
    includePt(p.x + p.bodyW / 2.0 + 50.0, p.y + p.bodyH / 2.0 + 50.0)
    for pin in p.pins: includePt(pin.x, pin.y)
  for w in result.wires:
    for pt in w.points: includePt(pt.x, pt.y)
  for j in result.junctions: includePt(j.x, j.y)
  for f in result.fallbacks:
    includePt(f.x, f.y)
    for pt in f.points: includePt(pt.x, pt.y)
  for lb in result.labels:
    let sz = if lb.size > 0.0: lb.size else: 12.0
    let b = lineBox(lb.x, lb.y, lb.text, lb.anchor, sz)
    includePt(b.x1, b.y1)
    includePt(b.x2, b.y2)
  for p in result.ports:
    includePt(p.x - p.bodyW / 2.0, p.y - p.bodyH / 2.0)
    includePt(p.x + p.bodyW / 2.0, p.y + p.bodyH / 2.0)
  if not have:
    minX = 0.0; minY = 0.0; maxX = 200.0; maxY = 200.0
  const pad = 40.0
  result.minX = minX - pad
  result.minY = minY - pad
  result.maxX = maxX + pad
  result.maxY = maxY + pad
  if not options.stageEnabled(lsBounds):
    result.minX = 0.0; result.minY = 0.0
    result.maxX = 0.0; result.maxY = 0.0


include ./diagnostics
