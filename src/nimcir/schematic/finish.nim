## Scene-native finishing stages.  They consume the completed scene and the
## private routing metadata retained in `LayoutState`; no transient data leaks
## into `Schematic`.

proc finishLabels(nl: Netlist, scene: var Schematic, routing: RoutingState,
                  enabled: bool) =
  # `routing` is a large object -- Nim passes it by hidden reference, no copy.
  # The four aliases below are read-only lookups, so `{.cursor.}` keeps each a
  # borrowed view rather than duplicating the table/seq/set; the scene payload
  # (parts/wires/...) that `routing` also carries is never touched here.
  let pinPos {.cursor.} = routing.pinPos
  let partIdxByDesig {.cursor.} = routing.partIdxByDesig
  let portedNets {.cursor.} = routing.portedNets
  let railLabelReqs {.cursor.} = routing.railLabelReqs

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
  let allWires = scene.wires
  var placedBoxes: seq[Rect]
  var bodyRects: seq[Rect]
  for p in scene.parts: bodyRects.add partInk(p)
  for p in scene.ports: bodyRects.add portBody(p)
  # The ground/supply glyph `svg` caps each rail/ground stub with reaches
  # ~10 units perpendicular and ~8 along the stub -- decoration, not a wire, so
  # add its footprint here or a label would land across the bars.
  for w in scene.wires:
    if w.kind in {wkGround, wkSupply} and w.points.len > 0:
      let e = w.points[^1]
      bodyRects.add (e.x - 13.0, e.y - 13.0, e.x + 13.0, e.y + 13.0)
  var newLabels: seq[SchematicLabel]

  # A symbol draws a short lead from each pin in to its glyph -- the span
  # between the pin (on `bodyW`/`bodyH`) and the ink rect. `svg` strokes those,
  # not `layout`, so they are not in `allWires`; add them here so a label on a
  # crowded part's occupied side is still rejected off them.
  var leadSegs: seq[tuple[a, b: Point]]
  for p in scene.parts:
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
  for f in scene.fallbacks:
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

  for idx, p in scene.parts:
    # A box draws its own designator/value inside the body (`svg.drawPart`),
    # where `boxSlots` reserved the room -- only symbol parts are labelled here.
    if p.isBox: continue
    var lines: seq[LabelLine]
    let shownDesig = if p.label.len > 0: p.label else: p.designator
    if shownDesig.len > 0: lines.add (shownDesig, designatorSize, lrDesignator)
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
  for f in scene.fallbacks: fallbackNets.incl f.net
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
        anchorEsc = escapeDir(scene.parts[partIdxByDesig[p.component.designator]], pt)
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
  for f in scene.fallbacks:
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

  if enabled:
    scene.labels.add newLabels

proc finishLabels(state: LayoutState, scene: var Schematic) =
  finishLabels(state.nl, scene, state.routing,
    state.options.stageEnabled(lsLabels))

proc finishBounds(scene: var Schematic, enabled: bool) =
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
  for p in scene.parts:
    includePt(p.x - p.bodyW / 2.0 - 50.0, p.y - p.bodyH / 2.0 - 50.0)
    includePt(p.x + p.bodyW / 2.0 + 50.0, p.y + p.bodyH / 2.0 + 50.0)
    for pin in p.pins: includePt(pin.x, pin.y)
  for w in scene.wires:
    for pt in w.points: includePt(pt.x, pt.y)
  for j in scene.junctions: includePt(j.x, j.y)
  for f in scene.fallbacks:
    includePt(f.x, f.y)
    for pt in f.points: includePt(pt.x, pt.y)
  for lb in scene.labels:
    let sz = if lb.size > 0.0: lb.size else: 12.0
    let b = lineBox(lb.x, lb.y, lb.text, lb.anchor, sz)
    includePt(b.x1, b.y1)
    includePt(b.x2, b.y2)
  for p in scene.ports:
    includePt(p.x - p.bodyW / 2.0, p.y - p.bodyH / 2.0)
    includePt(p.x + p.bodyW / 2.0, p.y + p.bodyH / 2.0)
  if not have:
    minX = 0.0; minY = 0.0; maxX = 200.0; maxY = 200.0
  const pad = 40.0
  scene.minX = minX - pad
  scene.minY = minY - pad
  scene.maxX = maxX + pad
  scene.maxY = maxY + pad
  if not enabled:
    scene.minX = 0.0; scene.minY = 0.0
    scene.maxX = 0.0; scene.maxY = 0.0
