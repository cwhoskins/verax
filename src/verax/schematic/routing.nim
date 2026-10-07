proc fullyInternalComposite(physicalPins: seq[RoutePin],
                            composites: CompositePlan): bool =
  ## True when every pin of a signal net is covered by one composite port:
  ## `compositeInternalRoutes` owns its wiring. An interface-port connection
  ## point always disqualifies it.
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
  ## deterministic. `ok` is false only when a pin is unreachable and
  ## `withFallbacks` is false (the recoverable failure the feedback loop
  ## works on). With `withFallbacks`, an unroutable net becomes a
  ## `SchematicFallback` per pin and the rest still route.
  ##
  ## `portY` (from `refinePortPlacement`) replaces a port's anchor target in
  ## the column relaxation -- a spring target; `portMinGap` still applies.
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
      # Every member key maps to the merged point, so downstream consumers
      # need no bundle knowledge.
      pinPos[pinKey(c, pinName)] = Point(x: px, y: py)
      let bi = bundles.byPin.getOrDefault(pinKey(c, pinName), -1)
      if bi >= 0:
        # One `SchematicPin` per merged lane, so `pins.len` may differ from
        # `c.pins.len`; scene consumers tolerate that.
        if bi notin groupPinDone:
          groupPinDone.incl bi
          let b = bundles.bundles[bi]
          # `net` stays `b.display`: the group text would make
          # `diagnostics.sceneRouterInputs` seed a stub under an unused tag.
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

  # Constrained parallel groups are private composites: the scene schema is
  # unchanged, but routing gets one endpoint per shared terminal.
  let composites =
    if constrained: positionedCompositePlan(composites, result.parts, routingClearance)
    else: CompositePlan()

  # A global net collects pins from sibling clones that reuse designators,
  # so ownership is by netlist identity, not name.
  proc ownsPin(p: Pin): bool =
    p.component != nil and p.component.netlist == nl

  # Every signal pin and port connection point leaves its body through a
  # short stub, seeded here under its own net for the rail-stub shortening
  # test and signal occupancy. Never added to `occ` (the emitted-wire set
  # fallback stubs size against), or every fallback marker would be zero.
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
      # Only the composite port is an external escape; covered pins belong to
      # the private fanout.
      let cp = compositePort(composites, partIdx, p.name)
      if constrained and cp.found and not cp.representative: continue
      # A collapsed bundle's members share one point: seed it **once** under
      # `b.display`, or foreign seeds on its first hop block it forever.
      let bi = bundles.byPin.getOrDefault(key, -1)
      var seedNet = net.name
      if bi >= 0:
        seedNet = bundles.bundles[bi].display
        let sk = $partIdx & "\x1f" & seedNet
        if sk in seededBundle: continue
        seededBundle.incl sk
      elif arrays.groupOf.hasKey(net.name):
        # An array group's endpoints are at different points on a foreign
        # part, so dedupe on the point, not the part.
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
  # Each signal-carrying `nl.ports` entry gets a port symbol in a column
  # outside the parts: left for input/unspecified, right for
  # output/bidirectional. Rails and ground are skipped (own glyph). A port's
  # y follows its net-mate pin; its wire routes like any other branch.
  var portedNets = initHashSet[string]()
  # A net may be published under several port names (a pass-through strap,
  # `<name>_in`/`<name>_out`); each pennant needs its own wire.
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
    # A strap's two port names see one internal pin; orient them by `_in`/
    # `_out` suffix and keep both names.
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
      # A bundle's published member ports fold to one pennant, using the
      # published subset (`portText`/`portSceneMembers`) -- a `brNetLabel`
      # bundle may publish fewer than all members.
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
      # A published array group folds to one pennant too; otherwise a member
      # owned only by a hidden instance finds no pin and the port vanishes.
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

  # Stack each column by wire-tension relaxation: each port is pulled
  # toward its target y (anchor pin, or the `portY` override), then a
  # symmetric min-gap projection, so a jammed column centres on its targets
  # instead of cascading down. Order: target y, then name.
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
      # A port's stub is a signal wire; seed it like a pin's escape stub.
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
  # Rail stubs first, so signal routes avoid them. Deterministic order (net,
  # then pin) drives occupancy throughout.
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
        # Rail/ground glyphs sit at the canonical composite terminal; other
        # terminals are fed by internal taps.
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
      # Append the composite fanout, re-tagged `wkPowerLink`: `wkSignal` would
      # read as a routed rail, and `wkGround`/`wkSupply` would draw a second
      # glyph at the member's bare pin.
      for w in compositeInternalRoutes(composites, result.parts, net.name):
        var w = w
        w.kind = wkPowerLink
        result.wires.add w

  # Signals may cross wires but not supply/ground glyph ink, so each glyph
  # endpoint gets a Hanan axis and its geometry is a crossing blocker.
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

    # A collapsed bundle routes once, from its representative member; other
    # members `inc sigOrd; continue` so `sigOrd` stays one per net.
    let bi = bundles.byNet.getOrDefault(net.name, -1)

    # An array: suppressed nets never route; a distributed group routes once
    # on its surviving member as one bus. Chain arcs are a later pass.
    let ar = arrayRouteFor(arrays, net.name)
    if ar.skip:
      inc sigOrd
      continue
    if ar.group and not ar.first:
      inc sigOrd
      continue
    let arrGroup = ar.group and ar.first

    # A bundle that failed collapse: no member wires, one `fbNetLabel` tag
    # per `LabelGroup`, emitted once per bundle. A merged group gets one tag
    # (`lg.text`, equal to its merged `SchematicPin.name` so `fallbackFor`
    # matches). An unmerged group gets one tag per pin, unless an array owns
    # the pin's port (`arrayOwnsDistributedPin`) and draws a real wire. The
    # port side gets one merged tag keyed by `b.display` (a port's `net` is
    # the occupancy tag, which `fallbackEscapeDir` matches), skipped if the
    # array's route already reaches it.
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
          # A merged carrier may not itself be an array member, so ask
          # whether an array already routes this group's net.
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
            # An unmerged carrier that is now an array representative would
            # still tag "rin_0"; use the bus family name ("rin") instead.
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
      # Else an array owns this net's route: fall through to `arrGroup`.

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
      # One bus: every member's foreign endpoints, the representative's pin,
      # and the merged port point if published.
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
      # A chain head/tail is re-homed onto the representative's IN/OUT pin.
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
      # A net wholly inside one composite: its wiring is the composite's own
      # fanout. Not dangling, so no fallback marker.
      result.wires.add compositeInternalRoutes(composites, result.parts, net.name)
      inc sigOrd
      continue
    if not coll and not arrGroup and constrained:
      pins = compositeExternalPins(pins, composites)
    if pins.len < 2:
      # A single-pin net is dangling: a dashed stub + marker + label,
      # finalised after all real wires. Not a routing failure.
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
        # A collapsed bundle or array bus that won't route: drop its partial
        # branches and carry members by name.
        occ = occBefore
        let tag = (if coll: bundles.bundles[bi].display else: ar.tag)
        for pin in pins:
          pendingFallbacks.add (pin: pin, netName: tag,
                                kind: fbNetLabel, bundle: tag)
        inc sigOrd
        continue
      if withFallbacks:
        # Drop branches `routeNet` recorded before failing; the net is drawn
        # as fallbacks only.
        occ = occBefore
        # A failed composite endpoint stands for every physical pin. A
        # published net that won't route gets a net-label (its pennant says
        # where it goes); an unpublished one keeps the amber marker.
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
        # `ar.tag` is the bundle's own display when bundle-owned, so colour
        # follows the bundle; a plain array group is `wkBus`.
        let arKind = if bi >= 0 and bundles.bundles[bi].tag == btInterface: wkInterface else: wkBus
        result.wires.add SchematicWire(net: ar.tag, kind: arKind,
          members: ar.members, points: poly)
      else:
        result.wires.add SchematicWire(net: net.name,
          kind: wireKindFor(bundles, net.name), points: poly)
      addSegments(adj, poly)
    if coll and not bundles.bundles[bi].ported and pins.len > 0:
      # A non-ported collapsed bundle gets one `lrNet` label at the merged pin.
      let b = bundles.bundles[bi]
      result.bundleLabelReqs.add (
        text: pinNameFor(b, result.parts[pins[0].partIdx].designator),
        at: pins[0].pt,
        esc: escapeDir(result.parts[pins[0].partIdx], pins[0].pt))
    if constrained and not coll and not arrGroup:
      # Fanout only after the external tree succeeds (atomic fallback).
      result.wires.add compositeInternalRoutes(composites, result.parts, net.name)
    for p, nbrs in adj:
      if nbrs.len >= 3:
        result.junctions.add SchematicJunction(net: routeName, x: p.x, y: p.y)
    inc sigOrd

  # --- chain arcs -----------------------------------------------------------
  # Each chained port pair gets a dashed recirculation arc on the box body
  # from OUT to IN ("feeds through all N"). A fixed polyline, not an
  # `nl.nets` entry; added to `occ` and `arrayNets`; exempt from routed-wire
  # invariants. The lead of a parallel-chain group carries the `xN` badge.
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
      # A staple on the box interior: in from OUT, up by `bulge`, across,
      # down into IN (same y).
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

  # Fallback stubs are sized against the complete occupancy set.
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
  ## Parts the feedback loop may move, in insertion order: those with at
  ## least two non-rail nets (others have no tree route a move would fix).
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
  ## The placement-routing feedback loop. On an unroutable signal net, tries
  ## deterministic single-part moves (`feedbackCandidateParts`, nearest grid
  ## rings first, up to `feedbackMaxRadius`), keeping any that route strictly
  ## further, within the accepted/attempt budgets. A move is rejected if it
  ## overlaps a raw body or makes distinct-net terminal pins coincide. If
  ## nothing fixes it (or the sheet is too large), the best positions are
  ## re-routed with fallbacks.
  let constrained = options.policy == lpConstrainedLayered
  var best = routeScene(nl, comps, syms, pos, rots, idxOf,
                        constrained = constrained, composites = composites,
                        bundles = bundles, arrays = arrays, portY = portY,
                        mirrors = mirrors)
  if best.ok: return best

  # Gate on pool length (the search space), plus a `4 * feedbackMaxParts`
  # raw ceiling: evaluating each candidate is still raw-sized.
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
  # Composites move as one rigid body, represented at their first member.
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
  # `activeOverrides`, as in `state.nim`'s `repairTerminalClearance`.
  let ov = activeOverrides(state)
  let isPower = rawPowerFlags(state.power, state.composites, state.comps.len)
  recoverRouting(state.nl, state.comps, state.syms, state.pos, state.rots,
    state.idxOf, state.options, state.composites, state.bundles, state.arrays,
    portY = state.portY, ov = ov, sides = ov.side, leftSplit = state.leftSplit,
    rightSplit = state.rightSplit, isPower = isPower, powerSplit = state.powerSplit,
    mirrors = state.mirrors)

