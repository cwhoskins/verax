type
  RouteScene = object
    ## Everything between placement and label placement, produced from a
    ## candidate set of centres and rotations: the placed parts and ports, the
    ## routed wires and junctions, and the maps the label pass still needs.
    ## `ok` is false when a signal net could not be routed; `failOrd` is that
    ## net's ordinal among signal nets (a later failure is further progress).
    ok: bool
    failOrd: int
    failNet: string
    failPin: int
    failPt: Point
    parts: seq[SchematicPart]
    ports: seq[SchematicPort]
    wires: seq[SchematicWire]
    junctions: seq[SchematicJunction]
    fallbacks: seq[SchematicFallback]
    pinPos: Table[string, Point]
    partIdxByDesig: Table[string, int]
    portedNets: HashSet[string]
    railLabelReqs: seq[tuple[text: string, at, dir: Point]]

proc routeScene(nl: Netlist, comps: seq[Component], syms: seq[SymbolDef],
                pos: seq[Point], rots: seq[float],
                idxOf: Table[string, int],
                withFallbacks = false): RouteScene =
  ## Build the routed scene for the given centres/rotations. Pure and
  ## deterministic. `ok` is false only when `routeNet` reports an unreachable
  ## pin and `withFallbacks` is false -- the one recoverable routing failure,
  ## which the placement-routing feedback loop may move out of. With
  ## `withFallbacks` true a net that cannot be routed is not a failure: every
  ## pin of it is recorded as a `SchematicFallback` and the remaining nets are
  ## still routed normally, so an impossible route degrades to a dashed marker
  ## instead of raising. Attempt zero (`layout`'s first call) passes through
  ## this proc unchanged, so a netlist that already routes produces exactly
  ## the scene it did before the feedback loop existed.
  var pinPos = initTable[string, Point]()
  var partIdxByDesig = initTable[string, int]()
  for i, c in comps:
    let sd = syms[i]
    var sp = SchematicPart(designator: c.designator, kind: c.kind,
                           name: c.name, value: c.attrs.getOrDefault("value", ""),
                           symbol: sd.name, isBox: sd.isBox,
                           bodyW: sd.bodyW, bodyH: sd.bodyH,
                           inkW: sd.inkW, inkH: sd.inkH,
                           x: pos[i].x, y: pos[i].y, rotation: rots[i])
    var pi = 0
    for pinName, p in c.pins:
      let slot0 =
        if sd.byName.len > 0: sd.byName[pinName]
        else: sd.slots[pi]
      let slot = rotatedSlot(slot0, rots[i])
      let px = pos[i].x + slot.x
      let py = pos[i].y + slot.y
      sp.pins.add SchematicPin(name: pinName, x: px, y: py,
                               net: (if p.net != nil: p.net.name else: ""))
      pinPos[pinKey(c, pinName)] = Point(x: px, y: py)
      inc pi
    partIdxByDesig[c.designator] = result.parts.len
    result.parts.add sp

  # A shared global net (SPICE node "0") accumulates pins from every sibling
  # clone that wired into it, and sibling clones reuse designators, so a pin
  # belongs to this sheet only when its component's owning netlist *is* this
  # one -- identity, not name.
  proc ownsPin(p: Pin): bool =
    p.component != nil and p.component.netlist == nl

  # `isGround` also fires on a net that merely has a `ptGround`-kinded pin --
  # an op-amp's `V-` supply pin, say -- so an explicitly `ntPower` net would
  # be drawn with a ground glyph instead of its rail stub. An explicit net
  # kind wins here: a `ptGround` pin on a power net makes it a rail, not
  # ground.
  proc isGroundHere(net: Net): bool =
    net != nil and isGround(net) and net.kind != ntPower
  proc isRailHere(net: Net): bool =
    net != nil and isRail(net) and not isGroundHere(net)

  # Every signal pin -- and every interface port's connection point -- leaves
  # its body through a short fixed-direction stub to the routing grid. Those
  # stubs are seeded here, tagged with their own net, and handed to the two
  # consumers that must respect them: the rail/ground stub shortening test,
  # and the signal route's occupancy check. They are never added to `occ`:
  # `occ` is the emitted-wire set a fallback stub sizes itself against, and a
  # pin's own escape seed must not read as a foreign wire there (it would
  # zero every fallback marker).
  var escapeSeeds: seq[OccSeg]
  for _, net in nl.nets:
    if isGroundHere(net) or isRailHere(net): continue
    for p in net.pins:
      if not ownsPin(p): continue
      let key = pinKey(p.component, p.name)
      if not (pinPos.hasKey(key) and
              partIdxByDesig.hasKey(p.component.designator)): continue
      let pt = pinPos[key]
      let part = result.parts[partIdxByDesig[p.component.designator]]
      addOcc(escapeSeeds, pt, pt + escapeDir(part, pt) * routingClearance,
             net.name)

  # --- interface ports: a fixed column per direction ------------------
  # Each entry of `nl.ports` (declared order -- an `OrderedTable`, iterated
  # like `nl.nets` everywhere else here) whose net carries a real signal
  # gets an Altium-style port symbol in a column just outside the parts: the
  # left edge for an input or an unspecified port, the right edge for an
  # output or a bidirectional one, so signal reads left to right. Rails and
  # ground are skipped -- they draw their own glyph. Layout fixes the column
  # x; a port's y follows its net-mate pin, pushed down only to clear a port
  # already placed in that column. The connecting wire is routed like any
  # other net branch, so it never crosses a body.
  var portedNets = initHashSet[string]()
  var portConn = initTable[string, tuple[at: Point, inward: Point]]()

  var pMinX, pMaxX = 0.0
  var havePExt = false
  for sp in result.parts:
    let l = sp.x - sp.bodyW / 2.0
    let r = sp.x + sp.bodyW / 2.0
    if not havePExt: pMinX = l; pMaxX = r; havePExt = true
    else:
      if l < pMinX: pMinX = l
      if r > pMaxX: pMaxX = r
  if not havePExt: (pMinX, pMaxX) = (0.0, 0.0)
  let leftColX = round((pMinX - 2.0 * grid) / grid) * grid
  let rightColX = round((pMaxX + 2.0 * grid) / grid) * grid

  type PortPlan = object
    name, net: string
    dir: PortDirection
    toRight: bool
    prefY, bodyW, bodyH: float
  var plans: seq[PortPlan]
  for portName, net in nl.ports:
    if net == nil or isGroundHere(net) or isRailHere(net): continue
    let dir = portDirection(net)
    let toRight = dir in {pdOutput, pdBidir}
    var anchorX, anchorY = 0.0
    var have = false
    for p in net.pins:
      if not ownsPin(p): continue
      let key = pinKey(p.component, p.name)
      if not pinPos.hasKey(key): continue
      let pt = pinPos[key]
      let better =
        if not have: true
        elif toRight: pt.x > anchorX + 1e-9
        else: pt.x < anchorX - 1e-9
      if better:
        anchorX = pt.x
        anchorY = pt.y
        have = true
    if not have: continue
    portedNets.incl net.name
    plans.add PortPlan(name: portName, net: net.name, dir: dir, toRight: toRight,
      prefY: anchorY, bodyH: 24.0,
      bodyW: max(60.0, float(portName.len) * 8.0 + 28.0))

  # Stack each column: preferred y first (name breaks a tie), then a fixed
  # gap so two ports never overlap.
  for onRight in [false, true]:
    var col: seq[int]
    for i, pl in plans:
      if pl.toRight == onRight: col.add i
    col.sort(proc(a, b: int): int =
      result = cmp(plans[a].prefY, plans[b].prefY)
      if result == 0: result = cmp(plans[a].name, plans[b].name))
    var yCursor = NegInf
    for i in col:
      let pl = plans[i]
      var y = round(pl.prefY / grid) * grid
      if y < yCursor + 3.0 * grid: y = yCursor + 3.0 * grid
      yCursor = y
      let edgeX = (if onRight: rightColX else: leftColX)
      var px = edgeX + (if onRight: pl.bodyW / 2.0 else: -pl.bodyW / 2.0)
      if abs(px) < 1e-9: px = 0.0
      if abs(y) < 1e-9: y = 0.0
      result.ports.add SchematicPort(name: pl.name, net: pl.net, dir: pl.dir,
        x: px, y: y, bodyW: pl.bodyW, bodyH: pl.bodyH,
        rotation: (if onRight: 0.0 else: 180.0))
      let conn = Point(x: edgeX, y: y)
      let inward = Point(x: (if onRight: -1.0 else: 1.0), y: 0.0)
      portConn[pl.net] = (at: conn, inward: inward)
      # A port's connecting stub is a signal wire like any other pin's, so a
      # foreign net must not thread it either; seed it exactly like a part
      # pin's escape stub above.
      addOcc(escapeSeeds, conn, conn + inward * routingClearance, pl.net)

  var obstacles = obstaclesFor(result.parts)
  for p in result.ports:
    let hw = p.bodyW / 2.0 + routingClearance
    let hh = p.bodyH / 2.0 + routingClearance
    obstacles.add Obstacle(x1: p.x - hw, y1: p.y - hh,
                           x2: p.x + hw, y2: p.y + hh)
  var escapeTerminals: seq[Point]
  for seed in escapeSeeds: escapeTerminals.add seed.b
  var free = buildFreeGrid(obstacles, escapeTerminals)

  # --- routing ------------------------------------------------------------
  # Rail stubs are emitted first so their segments are occupied before any
  # signal route is planned; signal routes then avoid running along them.
  # Within each stub pass and signal pass the same deterministic order (net
  # iteration order, then pin order) drives occupancy, so the whole scene is
  # reproducible.
  var occ: seq[OccSeg]
  var railLabelReqs: seq[tuple[text: string, at, dir: Point]]

  for _, net in nl.nets:
    var pins: seq[tuple[pt: Point, partIdx: int]]
    for p in net.pins:
      if ownsPin(p):
        let key = pinKey(p.component, p.name)
        if pinPos.hasKey(key) and partIdxByDesig.hasKey(p.component.designator):
          pins.add (pt: pinPos[key],
                    partIdx: partIdxByDesig[p.component.designator])
    if pins.len == 0: continue

    if isGroundHere(net):
      for pin in pins:
        let dir = escapeDir(result.parts[pin.partIdx], pin.pt)
        let e0 = shortenedStubEnd(pin.pt, dir, pinSpan, net.name, occ & escapeSeeds)
        let e = shortenedGlyphStubEnd(pin.pt, e0, wkGround, net.name, escapeSeeds)
        result.wires.add SchematicWire(net: net.name, kind: wkGround,
                                       points: @[pin.pt, e])
        addOcc(occ, pin.pt, e, net.name)
    elif isRailHere(net):
      for pin in pins:
        let dir = escapeDir(result.parts[pin.partIdx], pin.pt)
        let e0 = shortenedStubEnd(pin.pt, dir, pinSpan, net.name, occ & escapeSeeds)
        let e = shortenedGlyphStubEnd(pin.pt, e0, wkSupply, net.name, escapeSeeds)
        result.wires.add SchematicWire(net: net.name, kind: wkSupply,
                                       points: @[pin.pt, e])
        addOcc(occ, pin.pt, e, net.name)
        if net.name.len > 0:
          railLabelReqs.add (text: net.name, at: e, dir: dir)

  # A rail/ground terminal is more than its wire stem: SVG caps it with one
  # supply bar or three ground bars. Signals may cross ordinary wires, but not
  # this terminal ink, so give every glyph endpoint a Hanan axis and pass its
  # complete geometry to the signal router as a crossing blocker.
  var glyphs: seq[OccSeg]
  for w in result.wires:
    for g in terminalGlyphSegments(w):
      glyphs.add g
      escapeTerminals.add g.a
      escapeTerminals.add g.b
  free = buildFreeGrid(obstacles, escapeTerminals)

  var sigOrd = 0
  var pendingFallbacks: seq[tuple[pin: RoutePin, netName: string]]
  for _, net in nl.nets:
    if isGroundHere(net) or isRailHere(net): continue
    var pins: seq[RoutePin]
    for p in net.pins:
      if ownsPin(p):
        let key = pinKey(p.component, p.name)
        if pinPos.hasKey(key) and partIdxByDesig.hasKey(p.component.designator):
          pins.add (pt: pinPos[key],
                    partIdx: partIdxByDesig[p.component.designator],
                    esc: Point(x: 0.0, y: 0.0),
                    pinName: p.name)
    if portConn.hasKey(net.name):
      let pc = portConn[net.name]
      pins.add (pt: pc.at, partIdx: 0, esc: pc.inward, pinName: "")
    if pins.len < 2:
      # A net with a single pin is a dangling connection: a dashed stub +
      # marker + label instead of disappearing. The stub is finalised after
      # every real wire is routed, so it never runs along one. This is not a
      # routing failure -- `ok` stays true -- so it is recorded in every
      # route, not only the fallback route.
      if pins.len == 1:
        pendingFallbacks.add (pin: pins[0], netName: net.name)
      inc sigOrd
      continue
    var adj = initTable[Point, HashSet[Point]]()
    let occBefore = occ
    let ro = routeNet(pins, result.parts, obstacles, free, occ, net.name,
                      escapeSeeds, glyphs)
    if not ro.ok:
      if withFallbacks:
        # `routeNet` may have recorded the net's already-connected branches
        # in `occ` before it failed; none of them are emitted, so drop them
        # before the next net routes. The whole net is then drawn as
        # fallbacks -- a marker at each pin, never a real wire.
        occ = occBefore
        for pin in pins:
          pendingFallbacks.add (pin: pin, netName: net.name)
        inc sigOrd
        continue
      result.ok = false
      result.failOrd = sigOrd
      result.failNet = net.name
      result.failPin = ro.failPin
      if ro.failPin >= 0 and ro.failPin < pins.len:
        result.failPt = pins[ro.failPin].pt
      return
    for poly in ro.polys:
      result.wires.add SchematicWire(net: net.name, kind: wkSignal,
                                     points: poly)
      addSegments(adj, poly)
    for p, nbrs in adj:
      if nbrs.len >= 3:
        result.junctions.add SchematicJunction(net: net.name, x: p.x, y: p.y)
    inc sigOrd

  # Fallback stubs are sized against the *complete* occupancy set, so a
  # dashed marker never runs along a real wire that routed after the net it
  # belongs to failed.
  for req in pendingFallbacks:
    result.fallbacks.add fallbackFor(req.pin, result.parts, req.netName, occ)

  result.junctions.sort(cmpJunction)
  result.ok = true
  result.pinPos = pinPos
  result.partIdxByDesig = partIdxByDesig
  result.portedNets = portedNets
  result.railLabelReqs = railLabelReqs

proc recomputeRotations(comps: seq[Component], syms: seq[SymbolDef],
                        pos: seq[Point], rots: seq[float]): seq[float] =
  ## The same definitive rotation pass `layout` runs after separation: one
  ## snapshot-read, fresh-write sweep with no hysteresis. Used after a
  ## feedback move so a moved part's neighbours may re-orient; `leafSnap` is
  ## deliberately not rerun.
  let pw = pinWorldPositions(comps, syms, pos, rots)
  result = rots
  for i in 0 ..< comps.len:
    result[i] = bestRotation(syms[i], comps[i], pos[i], rots[i], pw, 0.0)

proc feedbackCandidateParts(comps: seq[Component]): seq[int] =
  ## Parts the feedback loop may move, in insertion order: only parts with at
  ## least two non-ground / non-rail nets. A leaf (one signal net) has already
  ## been snapped by `leafSnap`, and a rail-only part has no tree route to
  ## unblock; moving either would not be followed by `leafSnap`, so the loop
  ## leaves both alone.
  for i, c in comps:
    var signal = 0
    for _, p in c.pins:
      if p.net != nil and not isGround(p.net) and not isRail(p.net):
        inc signal
        if signal >= 2: break
    if signal >= 2: result.add i

const
  feedbackAcceptedBudget = 4
    ## Most moves the placement-routing feedback loop may keep.
  feedbackAttemptBudget = 65
    ## Most candidate moves the feedback loop may try in total.
  feedbackMaxRadius = 4
    ## Furthest grid step a candidate move may take a part from its current
    ## centre; each part's rings are searched nearest-first.
  feedbackMaxParts = 24
    ## Feedback is only attempted on sheets of at most this many components.
    ## Every candidate move re-runs the whole route, which is O(parts^4) in
    ## the worst case; on a crowded large sheet that cost buys nothing, so a
    ## failure there is drawn as fallbacks immediately after attempt zero.

proc recoverRouting(nl: Netlist, comps: seq[Component], syms: seq[SymbolDef],
                    pos: seq[Point], rots: seq[float],
                    idxOf: Table[string, int]): RouteScene =
  ## The placement-routing feedback loop. When `routeScene` cannot route a
  ## signal net it tries deterministic single-part moves and keeps any move
  ## that routes strictly further than the best layout so far, up to
  ## `feedbackAcceptedBudget` accepted moves and `feedbackAttemptBudget`
  ## candidates. Movable parts are `feedbackCandidateParts` (two or more
  ## signal nets), in insertion order; each is tried on the rings of grid
  ## cells around its current centre, nearest first, up to
  ## `feedbackMaxRadius`. A candidate cell is rejected only when it would
  ## overlap another part's *raw* body -- the placement separation clearance
  ## is allowed to relax during recovery, but symbols never overlap. After a
  ## move the eligible rotations are recomputed (`recomputeRotations`);
  ## `leafSnap` is not rerun. When no move fixes the sheet -- or the sheet is
  ## too large for the loop to be attempted -- the best positions are re-routed
  ## with fallbacks enabled: an unrouteable net becomes a dashed marker per
  ## pin instead of an assertion.
  var best = routeScene(nl, comps, syms, pos, rots, idxOf)
  if best.ok: return best

  if comps.len > feedbackMaxParts:
    return routeScene(nl, comps, syms, pos, rots, idxOf, withFallbacks = true)

  var bestPos = pos
  var bestRots = rots
  var accepted = 0
  var attempts = 0
  var allParts = newSeq[int](comps.len)
  for i in 0 ..< comps.len: allParts[i] = i
  var rawW = newSeq[float](comps.len)
  var rawH = newSeq[float](comps.len)
  for i in 0 ..< comps.len:
    rawW[i] = syms[i].bodyW / 2.0
    rawH[i] = syms[i].bodyH / 2.0

  let order = feedbackCandidateParts(comps)

  while accepted < feedbackAcceptedBudget and attempts < feedbackAttemptBudget and
        not best.ok:
    var improved = false
    for partIdx in order:
      for r in 1 .. feedbackMaxRadius:
        for dy in -r .. r:
          for dx in -r .. r:
            if max(abs(dx), abs(dy)) != r: continue
            if attempts >= feedbackAttemptBudget: break
            inc attempts
            let x = bestPos[partIdx].x + float(dx) * grid
            let y = bestPos[partIdx].y + float(dy) * grid
            if overlapsAny(partIdx, x, y, bestPos, rawW, rawH, allParts): continue
            var candPos = bestPos
            candPos[partIdx] = Point(x: x, y: y)
            let candRots = recomputeRotations(comps, syms, candPos, bestRots)
            let cand = routeScene(nl, comps, syms, candPos, candRots, idxOf)
            if cand.ok or cand.failOrd > best.failOrd:
              best = cand
              bestPos = candPos
              bestRots = candRots
              inc accepted
              improved = true
              break
          if improved: break
        if improved: break
      if improved: break
    if not improved: break

  if not best.ok:
    return routeScene(nl, comps, syms, bestPos, bestRots, idxOf,
                      withFallbacks = true)
  best

