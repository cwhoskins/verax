proc fullyInternalComposite(physicalPins: seq[RoutePin],
                            composites: CompositePlan): bool =
  ## True when every pin of a signal net is covered by one and the same
  ## composite port -- the net has no endpoint outside the composite, so the
  ## external router has nothing to do and `compositeInternalRoutes` owns its
  ## wiring. An interface-port connection point (empty `pinName`) always
  ## disqualifies it.
  if physicalPins.len < 2: return false
  var key = (-1, -1)
  for p in physicalPins:
    if p.pinName.len == 0: return false
    let cp = compositePort(composites, p.partIdx, p.pinName)
    if not cp.found: return false
    if key[0] < 0: key = (cp.unit, cp.port)
    elif key != (cp.unit, cp.port): return false
  true

proc routeScene(nl: Netlist, comps: seq[Component], syms: seq[SymbolDef],
                pos: seq[Point], rots: seq[float],
                idxOf: Table[string, int],
                withFallbacks = false, constrained = false,
                composites = CompositePlan(),
                bundles = BundlePlan(),
                arrays = ArrayPlan(),
                portY = initTable[string, float](),
                mirrors: seq[bool] = @[]): RoutingState =
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
  ##
  ## `portY` is the post-route override channel (`refinePortPlacement`): an
  ## entry replaces a port's pre-route anchor-pin target in the column
  ## relaxation. It is a spring target, not a hard y -- the min-gap projection
  ## still runs, so two ports pulled to the same target stay `portMinGap`
  ## apart.
  var pinPos = initTable[string, Point]()
  var partIdxByDesig = initTable[string, int]()
  for i, c in comps:
    let sd = syms[i]
    let arrLabel = arrayLabelFor(arrays, c)
    var sp = SchematicPart(designator: c.designator, kind: c.kind,
                           label: (if isPackaged(c): displayDesignator(c)
                                   elif arrLabel.len > 0: arrLabel else: ""),
                           name: c.name, value: c.attrs.getOrDefault("value", ""),
                           symbol: sd.name, isBox: sd.isBox,
                           bodyW: sd.bodyW, bodyH: sd.bodyH,
                           inkW: sd.inkW, inkH: sd.inkH,
                           x: pos[i].x, y: pos[i].y, rotation: rots[i],
                           mirror: (if i < mirrors.len: mirrors[i] else: false))
    if arrays.byRep.hasKey(c.designator):
      let a = arrays.arrays[arrays.byRep[c.designator]]
      sp.count = a.members.len
      sp.members = a.members
    var pi = 0
    var groupPinDone: HashSet[int]
    for pinName, p in c.pins:
      let slot0 =
        if sd.byName.len > 0: sd.byName[pinName]
        else: sd.slots[pi]
      let slot = rotatedSlot(slot0, rots[i])
      let px = pos[i].x + slot.x
      let py = pos[i].y + slot.y
      # `pinPos` receives *every* member key (all -> the merged point), which
      # is what keeps the escape-seed loop, port anchoring, finish's label
      # anchors and diagnostics working with no per-consumer bundle knowledge.
      pinPos[pinKey(c, pinName)] = Point(x: px, y: py)
      let bi = bundles.byPin.getOrDefault(pinKey(c, pinName), -1)
      if bi >= 0:
        # One `SchematicPin` per merged lane: `SchematicPart.pins.len` then
        # differs from `c.pins.len`, which every audited scene consumer
        # (svg box branch, finish, diagnostics, render, json) tolerates.
        if bi notin groupPinDone:
          groupPinDone.incl bi
          let b = bundles.bundles[bi]
          # `laneOf` gives a collapsed bundle `(b.pinName, b.sceneMembers)`
          # unchanged, and a merged net-label group its own `(text, members)`.
          # `net` stays `b.display` -- the group text would make
          # `diagnostics.sceneRouterInputs` re-seed an escape stub under a tag
          # routing never used.
          let lane = laneOf(bundles, bi, c.designator)
          sp.pins.add SchematicPin(name: lane.name, x: px, y: py,
                                   net: b.display, members: lane.members)
      else:
        let ap = arrayPinFor(arrays, c, pinName)
        if ap.found:
          sp.pins.add SchematicPin(name: pinName, x: px, y: py,
            net: (if ap.net.len > 0: ap.net
                  elif p.net != nil: p.net.name else: ""),
            members: ap.members, mark: ap.mark, tag: ap.tag)
        else:
          sp.pins.add SchematicPin(name: pinName, x: px, y: py,
                                   net: (if p.net != nil: p.net.name else: ""))
      inc pi
    partIdxByDesig[c.designator] = result.parts.len
    result.parts.add sp

  # Constrained parallel groups are private composites.  They preserve the
  # public scene schema (all physical parts still appear above) while giving
  # routing one endpoint per shared terminal and a combined footprint.
  let composites =
    if constrained: positionedCompositePlan(composites, result.parts, routingClearance)
    else: CompositePlan()

  # A shared global net (SPICE node "0") accumulates pins from every sibling
  # clone that wired into it, and sibling clones reuse designators, so a pin
  # belongs to this sheet only when its component's owning netlist *is* this
  # one -- identity, not name.
  proc ownsPin(p: Pin): bool =
    p.component != nil and p.component.netlist == nl

  # `isGroundHere` / `isRailHere` are module-level in `geometry.nim` now --
  # `bundlePlan` is the third consumer of that one-liner.

  # Every signal pin -- and every interface port's connection point -- leaves
  # its body through a short fixed-direction stub to the routing grid. Those
  # stubs are seeded here, tagged with their own net, and handed to the two
  # consumers that must respect them: the rail/ground stub shortening test,
  # and the signal route's occupancy check. They are never added to `occ`:
  # `occ` is the emitted-wire set a fallback stub sizes itself against, and a
  # pin's own escape seed must not read as a foreign wire there (it would
  # zero every fallback marker).
  var escapeSeeds: seq[OccSeg]
  var seededBundle: HashSet[string]      ## "<partIdx>\x1f<bundle>" seeded once
  var seededArray: HashSet[string]       ## "<x>,<y>\x1f<display>" seeded once
  for _, net in nl.nets:
    if isGroundHere(net) or isRailHere(net): continue
    if net.name in arrays.suppressed: continue
    for p in net.pins:
      if not ownsPin(p): continue
      let key = pinKey(p.component, p.name)
      if not (pinPos.hasKey(key) and
              partIdxByDesig.hasKey(p.component.designator)): continue
      let partIdx = partIdxByDesig[p.component.designator]
      # Only the composite port is an external escape corridor.  Covered pins
      # belong to the deterministic private fanout and must not become extra
      # router endpoints or foreign-net blockers.
      let cp = compositePort(composites, partIdx, p.name)
      if constrained and cp.found and not cp.representative: continue
      # A collapsed bundle's members share one merged point. Seed it **once**,
      # tagged `b.display` -- three foreign seeds lying along the bundle's own
      # first hop would make `edgeAllowed` forbid it forever, so the bundle
      # could never route. `seededBundle` guards the loop.
      let bi = bundles.byPin.getOrDefault(key, -1)
      var seedNet = net.name
      if bi >= 0:
        seedNet = bundles.bundles[bi].display
        let sk = $partIdx & "\x1f" & seedNet
        if sk in seededBundle: continue
        seededBundle.incl sk
      elif arrays.groupOf.hasKey(net.name):
        # A distributed array group's endpoints sit at *different* points on a
        # foreign part (eight CS pins on an MCU), each needing its own seed --
        # so dedupe on the point, not the part, unlike `seededBundle`.
        let (ai, pj) = arrays.groupOf[net.name]
        seedNet = arrays.arrays[ai].ports[pj].display
        let pt0 = pinPos[key]
        let sk = $pt0.x & "," & $pt0.y & "\x1f" & seedNet
        if sk in seededArray: continue
        seededArray.incl sk
      let pt = pinPos[key]
      let part = result.parts[partIdx]
      addOcc(escapeSeeds, pt, pt + escapeDir(part, pt) * routingClearance,
             seedNet)

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
  # A net may be published under more than one plain port name -- a pass-through
  # strap, `<name>_in` and `<name>_out` bound to one internal net (the daisy
  # chain modules in `designs/lib/`). Every such pennant needs its own
  # connecting wire, so this is a seq, not one point.
  var portConn = initTable[string, seq[tuple[at, inward: Point]]]()
  var strapNets = initCountTable[string]()
  for pn, nt in nl.ports:
    if nt == nil or isGroundHere(nt) or isRailHere(nt): continue
    if bundles.byPort.getOrDefault(pn, -1) >= 0: continue
    if arrays.groupOf.hasKey(nt.name): continue
    strapNets.inc nt.name

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
    members: seq[BundleMember]
  var plans: seq[PortPlan]
  var planForBundle = initTable[int, int]()      ## bundle idx -> plans index
  var bundleAnchorX = initTable[int, float]()
  var planForArray = initTable[string, int]()    ## "<ai>:<pi>" -> plans index
  var arrayAnchorX = initTable[string, float]()
  for portName, net in nl.ports:
    if net == nil or isGroundHere(net) or isRailHere(net): continue
    let bi = bundles.byPort.getOrDefault(portName, -1)
    let ag = (if net != nil: arrays.groupOf.getOrDefault(net.name, (-1, -1))
              else: (-1, -1))
    # A pass-through strap publishes one internal net under two names
    # (`<x>_in`, `<x>_out`). `portDirection` sees one internal pin and calls
    # both inputs; orient them by the `_in` / `_out` suffix so the sheet reads
    # in-then-out, and keep both real port names -- the interface is the two
    # ports, not the net behind them.
    let strap = bi < 0 and ag.a < 0 and strapNets.getOrDefault(net.name) >= 2
    var dir =
      if bi >= 0: bundles.bundles[bi].dir
      elif ag.a >= 0: arrays.arrays[ag.a].ports[ag.p].dir
      else: portDirection(net)
    if strap:
      let ln = portName.toLowerAscii()
      if ln.endsWith("_out") or ln == "out": dir = pdOutput
      elif ln.endsWith("_in") or ln == "in": dir = pdInput
    var toRight = dir in {pdOutput, pdBidir}
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
    if bi >= 0:
      # A bundle's published member ports fold to one pennant -- a collapsed
      # bundle's member ports (all-or-nothing published, by the collapse
      # precondition) or a net-label bundle's published subset alike. Keep
      # the same "better" anchor test across every member's best pin. Named
      # off `portText`/`portSceneMembers` (the *published* subset), not
      # `pinName`/`sceneMembers` (every member) -- a `brNetLabel` bundle can
      # publish fewer than all its members.
      let b = bundles.bundles[bi]
      portedNets.incl net.name
      portedNets.incl b.display
      if planForBundle.hasKey(bi):
        let pidx = planForBundle[bi]
        let prev = bundleAnchorX.getOrDefault(bi, anchorX)
        if (toRight and anchorX > prev + 1e-9) or
           (not toRight and anchorX < prev - 1e-9):
          plans[pidx].prefY = anchorY
          bundleAnchorX[bi] = anchorX
        continue
      planForBundle[bi] = plans.len
      bundleAnchorX[bi] = anchorX
      plans.add PortPlan(name: b.portText, net: b.display, dir: dir,
        toRight: toRight, prefY: anchorY, bodyH: 24.0,
        bodyW: max(60.0, float(b.portText.len) * 8.0 + 28.0),
        members: b.portSceneMembers)
      continue
    if ag.a >= 0:
      # A distributed array group whose member nets are published ports folds
      # to one pennant -- exactly like a collapsed bundle. Without this, a
      # member net whose only on-sheet owner is a hidden instance finds no
      # placed pin and the port silently disappears.
      let ap = arrays.arrays[ag.a].ports[ag.p]
      let akey = $ag.a & ":" & $ag.p
      portedNets.incl net.name
      portedNets.incl ap.display
      var mem: seq[BundleMember]
      for k, d in arrays.arrays[ag.a].members: mem.add BundleMember(name: d, net: ap.nets[k])
      if planForArray.hasKey(akey):
        let pidx = planForArray[akey]
        let prev = arrayAnchorX.getOrDefault(akey, anchorX)
        if (toRight and anchorX > prev + 1e-9) or
           (not toRight and anchorX < prev - 1e-9):
          plans[pidx].prefY = anchorY
          arrayAnchorX[akey] = anchorX
        continue
      planForArray[akey] = plans.len
      arrayAnchorX[akey] = anchorX
      plans.add PortPlan(name: ap.tag, net: ap.display, dir: dir,
        toRight: toRight, prefY: anchorY, bodyH: 24.0,
        bodyW: max(60.0, float(ap.tag.len) * 8.0 + 28.0), members: mem)
      continue
    portedNets.incl net.name
    plans.add PortPlan(name: portName, net: net.name, dir: dir, toRight: toRight,
      prefY: anchorY, bodyH: 24.0,
      bodyW: max(60.0, float(portName.len) * 8.0 + 28.0))

  # Stack each column with a wire-tension relaxation: every port is a bead on
  # its edge column pulled toward its target y like a wire end under tension,
  # and two ports in one column keep `portMinGap` between bodies. The target is
  # the port's net anchor pin, or -- once `refinePortPlacement` has run -- a
  # `portY` override read off the routed wire. Each sweep is a spring pull then
  # a symmetric forward / backward min-gap projection, so a jammed column
  # settles centred on the mean of its targets instead of cascading downward
  # from the topmost pin the way a greedy stack does; a column with room to
  # spare leaves every port on its target. Column order is target y, then name
  # for a tie.
  proc portTarget(pl: PortPlan): float =
    portY.getOrDefault(pl.name, pl.prefY)
  for onRight in [false, true]:
    var col: seq[int]
    for i, pl in plans:
      if pl.toRight == onRight: col.add i
    if col.len == 0: continue
    col.sort(proc(a, b: int): int =
      result = cmp(portTarget(plans[a]), portTarget(plans[b]))
      if result == 0: result = cmp(plans[a].name, plans[b].name))
    var ys = newSeq[float](col.len)
    for k, i in col: ys[k] = portTarget(plans[i])
    for _ in 1 .. portSpringIters:
      for k in 0 ..< col.len:
        ys[k] += portSpringRate * (portTarget(plans[col[k]]) - ys[k])
      for k in 1 ..< col.len:
        let lo = ys[k - 1] + portMinGap
        if ys[k] < lo: ys[k] = lo
      for k in countdown(col.len - 2, 0):
        let hi = ys[k + 1] - portMinGap
        if ys[k] > hi: ys[k] = hi
    var yCursor = NegInf
    for k, i in col:
      let pl = plans[i]
      var y = round(ys[k] / grid) * grid
      if y < yCursor + portMinGap: y = yCursor + portMinGap
      yCursor = y
      let edgeX = (if onRight: rightColX else: leftColX)
      var px = edgeX + (if onRight: pl.bodyW / 2.0 else: -pl.bodyW / 2.0)
      if abs(px) < 1e-9: px = 0.0
      if abs(y) < 1e-9: y = 0.0
      result.ports.add SchematicPort(name: pl.name, net: pl.net, dir: pl.dir,
        x: px, y: y, bodyW: pl.bodyW, bodyH: pl.bodyH,
        rotation: (if onRight: 0.0 else: 180.0), members: pl.members)
      let conn = Point(x: edgeX, y: y)
      let inward = Point(x: (if onRight: -1.0 else: 1.0), y: 0.0)
      portConn.mgetOrPut(pl.net, @[]).add (at: conn, inward: inward)
      # A port's connecting stub is a signal wire like any other pin's, so a
      # foreign net must not thread it either; seed it exactly like a part
      # pin's escape stub above.
      addOcc(escapeSeeds, conn, conn + inward * routingClearance, pl.net)

  var obstacles: seq[Obstacle]
  if constrained:
    var covered = newSeq[bool](result.parts.len)
    for idx in composites.topLevel:
      if composites.items[idx].raw < 0:
        for i in rawMembers(composites, idx): covered[i] = true
    for i, part in result.parts:
      if not covered[i]:
        let hw = part.bodyW / 2.0 + routingClearance
        let hh = part.bodyH / 2.0 + routingClearance
        obstacles.add Obstacle(x1: part.x - hw, y1: part.y - hh,
                               x2: part.x + hw, y2: part.y + hh)
    for idx in composites.topLevel:
      if composites.items[idx].raw < 0:
        obstacles.add composites.items[idx].footprint
  else:
    obstacles = obstaclesFor(result.parts)
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
    if constrained:
      var routePins: seq[tuple[pt: Point, partIdx: int]]
      for pin in pins:
        # Rail/ground glyphs are shared at the canonical composite terminal;
        # the remaining physical terminals are fed by internal taps below.
        var representative = true
        for idx in composites.topLevel:
          if composites.items[idx].raw >= 0: continue
          for port in composites.items[idx].ports:
            if port.net != net.name: continue
            for covered in port.covered:
              if covered.partIdx == pin.partIdx:
                representative = covered == port.representative
        if representative: routePins.add pin
      pins = routePins

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
    if constrained and (isGroundHere(net) or isRailHere(net)):
      # Append the physical composite fanout after its shared glyph. The
      # `internalRoute` hook is shared with genuine signal nets (a pi/tee's
      # private mid node, a parallel stack's real trunk-and-tap) and always
      # emits `wkSignal`; re-tag it `wkPowerLink` so it is neither mistaken
      # for a routed signal (the "ground/rail nets are never routed" reading
      # `wkSignal` would otherwise satisfy) nor for the glyph-owning stub
      # itself (`wkGround`/`wkSupply` would draw a second bar, and reserve a
      # second glyph footprint, at the shared member's bare pin).
      for w in compositeInternalRoutes(composites, result.parts, net.name):
        var w = w
        w.kind = wkPowerLink
        result.wires.add w

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
  var pendingFallbacks: seq[tuple[pin: RoutePin, netName: string,
                                  kind: FallbackKind, bundle: string]]
  for nm in arrays.arrayNets: result.arrayNets.incl nm
  for _, net in nl.nets:
    if isGroundHere(net) or isRailHere(net): continue

    # A collapsed bundle routes once, from its representative member -- one
    # `RoutePin` per part entity at the merged point, plus the merged port
    # point. Every other member `inc sigOrd; continue`s so `sigOrd`'s
    # meaning (one per `nl.nets` entry) and `recoverRouting`'s `failOrd`
    # comparisons are unchanged.
    let bi = bundles.byNet.getOrDefault(net.name, -1)

    # A repeated-subsheet array. A suppressed net (a chain link, or a
    # distributed member after the first) never routes; a distributed group
    # routes once, on its first member, as one bus carrying every foreign
    # endpoint of every member. The chain arc is not an `nl.nets` entry --
    # it is routed in a dedicated pass after this loop.
    let ar = arrayRouteFor(arrays, net.name)
    if ar.skip:
      inc sigOrd
      continue
    if ar.group and not ar.first:
      inc sigOrd
      continue
    let arrGroup = ar.group and ar.first

    # A bundle that failed collapse (3+ endpoints, or non-uniform): no member
    # wires, one `fbNetLabel` tag per `LabelGroup`. Fires **once per bundle**
    # (guarded on the first member, like the collapsed path), never once per
    # member. A *merged* group gets one tag (`lg.text`) at the merged pin;
    # `lg.text` must equal that group's merged `SchematicPin.name` so
    # `fallbackFor` sets `part` and `fallbackEscapeDir` can match. An
    # *unmerged* group keeps one tag per pin under the real member net name --
    # **unless** a collapsed array now owns that pin's port
    # (`arrayOwnsDistributedPin`): the array draws a real wire for it instead
    # (`xbar_rf`'s `rin`/`rout`/`en`), under the bundle's own occupancy tag,
    # so a bare tag here would be a second, contradictory drawing of the same
    # connection. The published members now fold to ONE pennant (`byPort`
    # covers a net-label bundle too) sharing ONE `portConn` entry keyed by
    # `b.display` -- so the port side gets one merged tag, not one per member
    # -- but that marker is likewise skipped once the array's own route
    # already reaches the same port point (`arrGroup`, checked below). It is
    # tagged `b.display`, not `b.portText`: `fallbackEscapeDir` recovers a
    # port-point fallback's escape direction by matching
    # `SchematicPort.net == f.net`, and a port's `net` field is the
    # occupancy tag, never the drawn range/count text.
    if bi >= 0 and bundles.bundles[bi].role == brNetLabel:
      let b = bundles.bundles[bi]
      if net.name != b.members[0]:
        inc sigOrd
        continue
      for m in b.members: result.bundleNets.incl m
      for lg in b.labelGroups:
        if not partIdxByDesig.hasKey(lg.desig): continue
        let pIdx = partIdxByDesig[lg.desig]
        let comp = nl.components[lg.desig]
        if lg.merged:
          # A merged carrier is not itself necessarily an array member (it
          # may be the shared far side of a bus every *other* carrier of
          # which collapsed, e.g. `bundledTerminationBank`'s `U1`) --
          # `arrayOwnsDistributedPin` can't see that from `comp`/`lg.pins[0]`
          # alone, so ask whether an array already routes this group's own
          # underlying net directly.
          if arrays.groupOf.hasKey(lg.members[0].net): continue
          let key = pinKey(comp, lg.pins[0].pin)
          if not pinPos.hasKey(key): continue
          pendingFallbacks.add (
            pin: (pt: pinPos[key], partIdx: pIdx,
                  esc: Point(x: 0.0, y: 0.0), pinName: lg.text),
            netName: lg.text, kind: fbNetLabel, bundle: b.display)
        else:
          for pr in lg.pins:
            if arrayOwnsDistributedPin(arrays, comp, pr.pin): continue
            let key = pinKey(comp, pr.pin)
            if not pinPos.hasKey(key): continue
            # `lg` was built over the pre-collapse netlist, so an unmerged
            # carrier that is now an array representative still tags with
            # its own single bound net ("rin_0") -- the one specific index
            # it happened to sit on before every hidden member's pin
            # vanished into this one box. `arrayBundleLabelFor` substitutes
            # the bus/interface family name ("rin") for exactly that case;
            # "" for every other pin, so its own net name is used unchanged.
            let famText = arrayBundleLabelFor(arrays, comp, pr.pin)
            let labelText = if famText.len > 0: famText else: pr.net
            pendingFallbacks.add (
              pin: (pt: pinPos[key], partIdx: pIdx,
                    esc: Point(x: 0.0, y: 0.0), pinName: pr.pin),
              netName: labelText, kind: fbNetLabel, bundle: b.display)
      if not arrGroup:
        for pc in portConn.getOrDefault(b.display):
          pendingFallbacks.add (
            pin: (pt: pc.at, partIdx: 0, esc: pc.inward, pinName: ""),
            netName: b.display, kind: fbNetLabel, bundle: b.display)
        inc sigOrd
        continue
      # Else: a collapsed array owns this net's route (this is exactly its
      # triggering "first" member -- see `arrayRouteFor`) -- fall through to
      # the ordinary `arrGroup` handling below to draw the real wire, having
      # already drawn whatever net-label tags remain for any carrier the
      # array does not own.

    let coll = bi >= 0 and bundles.bundles[bi].role == brCollapsed
    if coll and net.name != bundles.bundles[bi].members[0]:
      inc sigOrd
      continue
    let routeName =
      if coll: bundles.bundles[bi].display
      elif arrGroup: ar.tag
      else: net.name

    var pins: seq[RoutePin]
    if arrGroup:
      # One bus: every foreign endpoint of every member net, plus the
      # representative's own pin (which sits on the first member net), plus
      # the merged port connection point when the group is published.
      for m in ar.members:
        if not nl.nets.hasKey(m): continue
        for p in nl.nets[m].pins:
          if not ownsPin(p): continue
          let key = pinKey(p.component, p.name)
          if pinPos.hasKey(key) and partIdxByDesig.hasKey(p.component.designator):
            pins.add (pt: pinPos[key],
                      partIdx: partIdxByDesig[p.component.designator],
                      esc: Point(x: 0.0, y: 0.0), pinName: p.name)
      for pc in portConn.getOrDefault(ar.tag):
        pins.add (pt: pc.at, partIdx: 0, esc: pc.inward, pinName: "")
    elif coll:
      let b = bundles.bundles[bi]
      for m in b.members: result.bundleNets.incl m
      result.bundleNets.incl b.display
      for desig in b.parts:
        if not partIdxByDesig.hasKey(desig): continue
        var mpt: Point
        var got = false
        for mp in b.memberPins:
          if mp.desig != desig: continue
          let k = mp.desig & "\x1f" & mp.pin
          if pinPos.hasKey(k):
            mpt = pinPos[k]
            got = true
            break
        if got:
          pins.add (pt: mpt, partIdx: partIdxByDesig[desig],
                    esc: Point(x: 0.0, y: 0.0), pinName: pinNameFor(b, desig))
      if b.ported:
        for pc in portConn.getOrDefault(b.display):
          pins.add (pt: pc.at, partIdx: 0, esc: pc.inward, pinName: "")
    else:
      for p in net.pins:
        if ownsPin(p):
          let key = pinKey(p.component, p.name)
          if pinPos.hasKey(key) and partIdxByDesig.hasKey(p.component.designator):
            pins.add (pt: pinPos[key],
                      partIdx: partIdxByDesig[p.component.designator],
                      esc: Point(x: 0.0, y: 0.0),
                      pinName: p.name)
      # A collapsed array's chain head/tail is re-homed onto the
      # representative box's IN/OUT pin, wherever the member that really holds
      # it sits (possibly a hidden one).
      if arrays.extraPins.hasKey(net.name):
        for ep in arrays.extraPins[net.name]:
          let key = pinKey(nl.components[ep.desig], ep.pin)
          if pinPos.hasKey(key) and partIdxByDesig.hasKey(ep.desig):
            pins.add (pt: pinPos[key], partIdx: partIdxByDesig[ep.desig],
                      esc: Point(x: 0.0, y: 0.0), pinName: ep.pin)
      for pc in portConn.getOrDefault(net.name):
        pins.add (pt: pc.at, partIdx: 0, esc: pc.inward, pinName: "")
    let physicalPins = pins
    if not coll and not arrGroup and constrained and
       fullyInternalComposite(physicalPins, composites):
      # A signal net wholly inside one composite -- a tee filter's mid node,
      # every pin covered by the same composite port and nothing external on
      # it. There is no tree to route; its wiring is the composite's own
      # deterministic fanout, appended like the post-external-route fanout
      # below. Not a dangling pin, so no fallback marker.
      result.wires.add compositeInternalRoutes(composites, result.parts, net.name)
      inc sigOrd
      continue
    if not coll and not arrGroup and constrained:
      pins = compositeExternalPins(pins, composites)
    if pins.len < 2:
      # A net with a single pin is a dangling connection: a dashed stub +
      # marker + label instead of disappearing. The stub is finalised after
      # every real wire is routed, so it never runs along one. This is not a
      # routing failure -- `ok` stays true -- so it is recorded in every
      # route, not only the fallback route.
      if pins.len == 1:
        for pin in physicalPins:
          pendingFallbacks.add (pin: pin, netName: net.name,
                                kind: fbUnrouted, bundle: "")
      inc sigOrd
      continue
    var adj = initTable[Point, HashSet[Point]]()
    let occBefore = occ
    let ro =
      if constrained and not coll and not arrGroup:
        routeConstrainedNet(pins, result.parts, obstacles, free, occ, routeName,
                            escapeSeeds, glyphs)
      else:
        routeNet(pins, result.parts, obstacles, free, occ, routeName,
                 escapeSeeds, glyphs)
    if not ro.ok:
      if coll or arrGroup:
        # A collapsed bundle or an array bus that will not route is not a
        # dashed failure: drop its partial branches and carry every member by
        # name instead.
        occ = occBefore
        let tag = (if coll: bundles.bundles[bi].display else: ar.tag)
        for pin in pins:
          pendingFallbacks.add (pin: pin, netName: tag,
                                kind: fbNetLabel, bundle: tag)
        inc sigOrd
        continue
      if withFallbacks:
        # `routeNet` may have recorded the net's already-connected branches
        # in `occ` before it failed; none of them are emitted, so drop them
        # before the next net routes. The whole net is then drawn as
        # fallbacks -- a marker at each pin, never a real wire.
        occ = occBefore
        # A failed external composite endpoint represents every physical pin,
        # not just its canonical terminal. Ports remain one fallback endpoint.
        # A *published* net that will not route is carried to its port by name
        # (a teal net-label, the bus/interface treatment) rather than flagged
        # as a broken connection -- the port pennant already says where it
        # goes. An unpublished internal net that fails is a real layout problem
        # and keeps the amber marker.
        let fk = if net.name in portedNets: fbNetLabel else: fbUnrouted
        for pin in physicalPins:
          pendingFallbacks.add (pin: pin, netName: net.name,
                                kind: fk, bundle: (if fk == fbNetLabel: net.name else: ""))
        inc sigOrd
        continue
      result.ok = false
      result.failOrd = sigOrd
      result.failNet = routeName
      result.failPin = ro.failPin
      if ro.failPin >= 0 and ro.failPin < pins.len:
        result.failPt = pins[ro.failPin].pt
      return
    for poly in ro.polys:
      if coll:
        let b = bundles.bundles[bi]
        result.wires.add SchematicWire(net: b.display,
          kind: (if b.tag == btInterface: wkInterface else: wkBus),
          members: b.members, points: poly)
      elif arrGroup:
        result.wires.add SchematicWire(net: ar.tag, kind: wkBus,
          members: ar.members, points: poly)
      else:
        result.wires.add SchematicWire(net: net.name,
          kind: wireKindFor(bundles, net.name), points: poly)
      addSegments(adj, poly)
    if coll and not bundles.bundles[bi].ported and pins.len > 0:
      # A non-ported collapsed bundle has no port pennant to read its name, so
      # request one `lrNet` label at the merged pin.
      let b = bundles.bundles[bi]
      result.bundleLabelReqs.add (
        text: pinNameFor(b, result.parts[pins[0].partIdx].designator),
        at: pins[0].pt,
        esc: escapeDir(result.parts[pins[0].partIdx], pins[0].pt))
    if constrained and not coll and not arrGroup:
      # Append fanout only after the external tree succeeds, preserving the
      # net's atomic fallback behavior.
      result.wires.add compositeInternalRoutes(composites, result.parts, net.name)
    for p, nbrs in adj:
      if nbrs.len >= 3:
        result.junctions.add SchematicJunction(net: routeName, x: p.x, y: p.y)
    inc sigOrd

  # --- chain arcs -----------------------------------------------------------
  # Every chained port pair of a collapsed array gets its own **recirculation
  # arc**: a dashed annotation drawn on the box body as a tight rounded loop
  # from the OUT pin across to the lined-up IN pin (both at the same y by
  # construction). It reads as "this port feeds through all N instances", is a
  # fixed polyline, never an `nl.nets` entry (so it never touches `sigOrd` or
  # `result.ok`), added to `occ` so later fallback stubs avoid it and to
  # `arrayNets` so `finish` leaves it unnamed. Because it runs on the box
  # interior between its own two pins it is exempt from the routed-wire
  # collinear / separation invariants. `svg` draws it dashed with an arrowhead
  # into the IN pin; the lead of a parallel-chain group also carries the `xN`
  # link-count badge.
  for a in arrays.arrays:
    if not partIdxByDesig.hasKey(a.rep): continue
    let repIdx = partIdxByDesig[a.rep]
    let repC = nl.components[a.rep]
    let rp = result.parts[repIdx]
    for lead, ap in a.ports:
      if ap.cls != apChained or not ap.isOut: continue
      if ap.partner < 0 or ap.partner >= a.ports.len: continue
      let ko = pinKey(repC, ap.name)
      let ki = pinKey(repC, a.ports[ap.partner].name)
      if not (pinPos.hasKey(ko) and pinPos.hasKey(ki)): continue
      for m in ap.links: result.arrayNets.incl m
      result.arrayNets.incl ap.display
      # A tight staple on the box interior: from the OUT pin a little way in,
      # up by `bulge`, across to above the IN pin, down, into the IN pin. The
      # OUT/IN pins share a y (a chained pair is drawn on one row).
      const bulge = 18.0
      const inset = 8.0
      let oy = pinPos[ko].y
      let ox = rp.x + rp.bodyW / 2.0 - boxStub
      let ix = rp.x - rp.bodyW / 2.0 + boxStub
      let poly = @[
        Point(x: ox, y: oy),
        Point(x: ox - inset, y: oy),
        Point(x: ox - inset, y: oy - bulge),
        Point(x: ix + inset, y: oy - bulge),
        Point(x: ix + inset, y: oy),
        Point(x: ix, y: oy)]
      for k in 0 ..< poly.high:
        addOcc(occ, poly[k], poly[k + 1], ap.display)
      result.wires.add SchematicWire(net: ap.display, kind: wkChain,
        members: (if ap.chainLead == lead: ap.links else: @[]), points: poly)

  # Fallback stubs are sized against the *complete* occupancy set, so a
  # dashed marker never runs along a real wire that routed after the net it
  # belongs to failed.
  for req in pendingFallbacks:
    result.fallbacks.add fallbackFor(req.pin, result.parts, req.netName, occ,
                                     req.kind, req.bundle)

  result.junctions.sort(cmpJunction)
  result.ok = true
  result.pinPos = pinPos
  result.partIdxByDesig = partIdxByDesig
  result.portedNets = portedNets
  result.railLabelReqs = railLabelReqs

proc feedbackCandidateParts(comps: seq[Component]): seq[int] =
  ## Parts the feedback loop may move, in insertion order: only parts with at
  ## least two non-ground / non-rail nets. A rail-only part, or a leaf with a
  ## single signal net, has no tree route a move would unblock, so the loop
  ## leaves both alone.
  for i, c in comps:
    var signal = 0
    for _, p in c.pins:
      if p.net != nil and not isGround(p.net) and not isRail(p.net):
        inc signal
        if signal >= 2: break
    if signal >= 2: result.add i

const
  feedbackMaxRadius = 4
    ## Furthest grid step a candidate move may take a part from its current
    ## centre; each part's rings are searched nearest-first.

proc recoverRouting(nl: Netlist, comps: seq[Component], syms: seq[SymbolDef],
                    pos: seq[Point], rots: seq[float],
                    idxOf: Table[string, int], options: LayoutOptions,
                    composites: CompositePlan,
                    bundles = BundlePlan(),
                    arrays = ArrayPlan(),
                    portY = initTable[string, float](),
                    ov = LayoutOverridePlan(),
                    sides: seq[LayoutSide] = @[],
                    leftSplit = NegInf, rightSplit = Inf,
                    isPower: seq[bool] = @[], powerSplit = Inf,
                    mirrors: seq[bool] = @[]): RoutingState =
  ## The placement-routing feedback loop. When `routeScene` cannot route a
  ## signal net it tries deterministic single-part moves and keeps any move
  ## that routes strictly further than the best layout so far, up to
  ## `feedbackAcceptedBudget` accepted moves and `feedbackAttemptBudget`
  ## candidates. Movable parts are `feedbackCandidateParts` (two or more
  ## signal nets), in insertion order; each is tried on the rings of grid
  ## cells around its current centre, nearest first, up to
  ## `feedbackMaxRadius`. A candidate cell is rejected when it would overlap
  ## another part's *raw* body, or when its final recomputed rotations leave
  ## exact terminal pins on distinct nets coincident. The placement separation
  ## clearance is allowed to relax during recovery, but symbols never overlap.
  ## When no move fixes the sheet -- or the sheet is too large for the loop to
  ## be attempted -- the best positions are re-routed with fallbacks enabled:
  ## an unrouteable net becomes a dashed marker per pin instead of an
  ## assertion.
  let constrained = options.policy == lpConstrainedLayered
  var best = routeScene(nl, comps, syms, pos, rots, idxOf,
                        constrained = constrained, composites = composites,
                        bundles = bundles, arrays = arrays, portY = portY,
                        mirrors = mirrors)
  if best.ok: return best

  # Pool length, not raw count, is what should gate the recovery loop: its
  # candidate-move search already iterates `units` built from the arena
  # (composites moved as one rigid body, below), so the search *space* is
  # already pool-sized. What is not yet pool-sized is the *cost of evaluating*
  # each candidate -- `constrainedRecomputeRotations` still rebuilds
  # `pinWorldPositions` from every singleton raw component, and
  # `constrainedRouteScore` inside it is still O(raw pins * raw comps) per
  # candidate rotation -- so a sheet that pools down to a small `poolLen` but
  # carries a very large raw part count would still pay that raw-sized cost on
  # every attempt. The `4 * feedbackMaxParts` raw ceiling is the guard for
  # exactly that (four two-member parallel pairs collapse to one pool item).
  let poolLen = composites.topLevel.len
  if poolLen > options.feedbackMaxParts or
     comps.len > 4 * options.feedbackMaxParts:
    return routeScene(nl, comps, syms, pos, rots, idxOf,
                      withFallbacks = true, constrained = constrained,
                      composites = composites, bundles = bundles, portY = portY,
                      mirrors = mirrors)

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

  var order = feedbackCandidateParts(comps)
  var units: seq[seq[int]]
  # Recovery moves a composite as one rigid body. Singleton candidates keep
  # `order`'s insertion order; a parallel unit is represented once at its
  # first member.
  block:
    var grouped = newSeq[bool](comps.len)
    for idx in composites.topLevel:
      if composites.items[idx].raw >= 0: continue
      let members = rawMembers(composites, idx)
      for i in members: grouped[i] = true
      if members[0] in order: units.add members
    for i in order:
      if not grouped[i]: units.add @[i]

  while accepted < options.feedbackAcceptedBudget and
        attempts < options.feedbackAttemptBudget and not best.ok:
    var improved = false
    for unit in units:
      for r in 1 .. feedbackMaxRadius:
        for dy in -r .. r:
          for dx in -r .. r:
            if max(abs(dx), abs(dy)) != r: continue
            if attempts >= options.feedbackAttemptBudget: break
            inc attempts
            var inUnit = newSeq[bool](comps.len)
            for i in unit: inUnit[i] = true
            var clear = true
            for i in unit:
              let nx = bestPos[i].x + float(dx) * grid
              let ny = bestPos[i].y + float(dy) * grid
              if sides.len == comps.len and
                 not sideBandAllows(sides[i], nx, rawW[i], leftSplit, rightSplit):
                clear = false
              if isPower.len == comps.len and
                 not powerBandAllows(isPower[i], ny, rawH[i], powerSplit):
                clear = false
              for j in allParts:
                if inUnit[j]: continue
                if abs(nx - bestPos[j].x) < rawW[i] + rawW[j] - 1e-9 and
                   abs(ny - bestPos[j].y) < rawH[i] + rawH[j] - 1e-9:
                  clear = false
            if not clear: continue
            var candPos = bestPos
            for i in unit:
              candPos[i] = Point(x: bestPos[i].x + float(dx) * grid,
                                 y: bestPos[i].y + float(dy) * grid)
            let candRots = constrainedRecomputeRotations(nl, comps, syms,
              candPos, bestRots,
              constrainedAnchors(comps, bestPos, idxOf, composites, arrays, ov),
              composites)
            if terminalClearance(comps, syms, candPos, candRots).coincidences > 0:
              continue
            let cand = routeScene(nl, comps, syms, candPos, candRots, idxOf,
                                  constrained = constrained, composites = composites,
                                  bundles = bundles, arrays = arrays, portY = portY,
                                  mirrors = mirrors)
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
                      withFallbacks = true, constrained = constrained,
                      composites = composites, bundles = bundles,
                      arrays = arrays, portY = portY, mirrors = mirrors)
  best

proc routeScene(state: LayoutState, withFallbacks = false): RoutingState =
  routeScene(state.nl, state.comps, state.syms, state.pos, state.rots,
    state.idxOf, withFallbacks = withFallbacks,
    constrained = state.options.policy == lpConstrainedLayered,
    composites = state.composites, bundles = state.bundles,
    arrays = state.arrays, portY = state.portY, mirrors = state.mirrors)

proc recoverRouting(state: LayoutState): RoutingState =
  # `activeOverrides`, not `state.overrides` directly -- see the identical
  # comment on `state.nim`'s `repairTerminalClearance` wrapper: with
  # `lsLayoutOverrides` disabled, `leftSplit`/`rightSplit` stay `-Inf`/`Inf`,
  # and a non-empty `sides` against those would reject every candidate for an
  # overridden part instead of the intended no-op.
  let ov = activeOverrides(state)
  let isPower = rawPowerFlags(state.power, state.composites, state.comps.len)
  recoverRouting(state.nl, state.comps, state.syms, state.pos, state.rots,
    state.idxOf, state.options, state.composites, state.bundles, state.arrays,
    portY = state.portY, ov = ov, sides = ov.side, leftSplit = state.leftSplit,
    rightSplit = state.rightSplit, isPower = isPower, powerSplit = state.powerSplit,
    mirrors = state.mirrors)

