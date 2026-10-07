## The passive composite motifs, registered into `compositeKinds` at the
## bottom:
##
## * **parallel stack** (`parallelStackKind`) -- parallel flat two-terminal
##   parts on the same unordered net pair, packed as one unit.
## * **series chain** (`seriesChainKind`) -- flat two-terminal passives
##   joined end to end through private two-pin link nets, drawn as one row.
##   Non-nesting: members are always raw singletons.

proc parallelRecognize(comps: seq[Component], syms: seq[SymbolDef]): seq[seq[int]] =
  ## `recognize` for the parallel stack: the total partition, singletons
  ## included. Topology-only (`syms` unused). The endpoint key is unordered,
  ## so declaration and pin order can't split a group.
  var groupOf = initTable[string, int]()
  for i, c in comps:
    if not isTwoTerminal(c, c.netlist):
      result.add @[i]
      continue
    var nets: seq[string]
    for _, pin in c.pins: nets.add pin.net.name
    nets.sort()
    let key = nets[0] & "\x1f" & nets[1]
    if groupOf.hasKey(key):
      result[groupOf[key]].add i
    else:
      groupOf[key] = result.len
      result.add @[i]

proc parallelInternalLayout(comps: seq[Component], syms: seq[SymbolDef],
                            members: seq[int]): seq[Point] =
  ## Members stacked at body-touching, grid-rounded centres (an 80 x 80
  ## pair is 80 apart).
  var totalH = 0.0
  for i in members: totalH += syms[i].bodyH
  var y = -totalH / 2.0
  for i in members:
    y += syms[i].bodyH / 2.0
    result.add Point(x: 0.0, y: round(y / grid) * grid)
    y += syms[i].bodyH / 2.0

proc parallelExternalPins(comps: seq[Component],
                          members: seq[int]): seq[CompositePort] =
  var names: seq[string]
  for _, pin in comps[members[0]].pins: names.add pin.net.name
  names.sort()
  for netName in names:
    var port = CompositePort(net: netName)
    for i in members:
      for pinName, pin in comps[i].pins:
        if pin.net != nil and pin.net.name == netName:
          port.covered.add (i, pinName)
    # The first member/pin is the deterministic external endpoint.
    port.representative = port.covered[0]
    result.add port

proc parallelPickRepresentative(parts: seq[SchematicPart], footprint: seq[Obstacle],
                                port: CompositePort):
    tuple[partIdx: int, pinName: string] =
  ## Pick a pin whose escape leaves the whole footprint (the first member may
  ## be an interior tap). Keeps the default if none does.
  result = port.representative
  for candidate in port.covered:
    let part = parts[candidate.partIdx]
    var at: Point
    for pin in part.pins:
      if pin.name == candidate.pinName: at = Point(x: pin.x, y: pin.y)
    let exitPt = at + escapeDir(part, at) * routingClearance
    if not insideAny(exitPt, footprint):
      return candidate

proc parallelInternalRoute(parts: seq[SchematicPart],
                          port: CompositePort): seq[SchematicWire] =
  ## Deterministic trunk-and-tap fanout (one trunk plus disjoint taps, so
  ## tap Ls don't overlap). The stacking axis is read from the pins, since
  ## `lsCompositeOrient` may have turned the unit.
  let rep = parts[port.representative.partIdx]
  var root: Point
  for pin in rep.pins:
    if pin.name == port.representative.pinName:
      root = Point(x: pin.x, y: pin.y)
  var taps: seq[Point]
  var minX, minY = Inf
  var maxX, maxY = -Inf
  for covered in port.covered:
    let member = parts[covered.partIdx]
    for pin in member.pins:
      if pin.name == covered.pinName:
        minX = min(minX, pin.x); maxX = max(maxX, pin.x)
        minY = min(minY, pin.y); maxY = max(maxY, pin.y)
        if covered != port.representative:
          taps.add Point(x: pin.x, y: pin.y)
  # Same-net terminals share the cross-axis coordinate, so the wider spread
  # is the trunk axis.
  let vertical = (maxY - minY) >= (maxX - minX)
  proc joinPoint(p: Point): Point =
    if vertical: Point(x: root.x, y: p.y) else: Point(x: p.x, y: root.y)
  if taps.len <= 1:
    for tap in taps:
      var points = @[tap]
      if tap.x != root.x and tap.y != root.y: points.add joinPoint(tap)
      points.add root
      result.add SchematicWire(net: port.net, kind: wkSignal, points: points)
    return
  var trunk = @[root]
  for tap in taps: trunk.add joinPoint(tap)
  trunk.sort(proc(a, b: Point): int =
    (if vertical: cmp(a.y, b.y) else: cmp(a.x, b.x)))
  var unique: seq[Point]
  for point in trunk:
    if unique.len == 0 or point != unique[^1]: unique.add point
  for tap in taps:
    let j = joinPoint(tap)
    if tap != j:
      result.add SchematicWire(net: port.net, kind: wkSignal, points: @[tap, j])
  if unique.len >= 2:
    result.add SchematicWire(net: port.net, kind: wkSignal, points: unique)

proc parallelRotationCandidates(nl: Netlist, comps: seq[Component],
                                syms: seq[SymbolDef], pos: seq[Point],
                                current: seq[float],
                                members: seq[int]): seq[seq[float]] =
  ## `angle` defines the canonical side via the reference member; others
  ## derive their rotation from their native terminal.
  var nets: seq[string]
  for _, p in comps[members[0]].pins: nets.add p.net.name
  nets.sort()
  let reference = slotForNet(syms[members[0]], comps[members[0]], nets[0])
  if not reference.found: return
  for angle in rotationChoices:
    let canonicalSide = axisUnit(rotatedSlot(reference.slot, angle))
    if canonicalSide.y != 0.0: continue
    var cand = current
    var valid = true
    for i in members:
      let mapped = angleForCanonicalSide(syms[i], comps[i], nets[0], canonicalSide)
      if not mapped.ok or not validCompositeAxes(syms[i], comps[i], nets,
                                                 mapped.angle, canonicalSide):
        valid = false
        break
      cand[i] = mapped.angle
    if valid: result.add cand

proc parallelStackKind(): CompositeKind =
  CompositeKind(name: "parallel-stack",
    orientable: true,
    recognize: parallelRecognize,
    internalLayout: parallelInternalLayout,
    externalPins: parallelExternalPins,
    pickRepresentative: parallelPickRepresentative,
    internalRoute: parallelInternalRoute,
    rotationCandidates: parallelRotationCandidates,
    footprint: boundingBoxFootprint)

# --- the series chain ------------------------------------------------------
# Members chain through a *link net*: exactly two pins, both on distinct
# usable members, not ground/rail/port. That gives degree <= 2, so links
# form paths and cycles; cycles are declined. Topology-only.

proc seriesSharedNet(a, b: Component): string =
  ## The net `a` and `b` both touch ("" if none).
  for _, pa in a.pins:
    if pa.net == nil: continue
    for _, pb in b.pins:
      if pb.net != nil and pb.net.name == pa.net.name: return pa.net.name

proc seriesRecognize(comps: seq[Component], syms: seq[SymbolDef]): seq[seq[int]] =
  var groups: seq[seq[int]]
  if comps.len > 0:
    let nl = comps[0].netlist
    var portNets = initHashSet[string]()
    for _, pn in nl.ports:
      if pn != nil: portNets.incl pn.name

    var usable = newSeq[bool](comps.len)
    var pinCount = initTable[string, int]()
    var pinsOn = initTable[string, seq[int]]()   # net name -> usable member idxs
    var netByName = initTable[string, Net]()
    for i, c in comps:
      # Must draw as a flat two-terminal passive symbol: `isTwoTerminal`, not
      # `isTraversable` (which also passes boxes and declared switches).
      usable[i] = isTwoTerminal(c, nl) and isPassiveElement(syms[i]) and
                  not syms[i].isBox
      for _, pin in c.pins:
        if pin.net == nil: continue
        pinCount.mgetOrPut(pin.net.name, 0).inc
        netByName[pin.net.name] = pin.net
        if usable[i]: pinsOn.mgetOrPut(pin.net.name, @[]).add i

    proc isLinkNet(netName: string): bool =
      ## A private two-pin net joining two distinct usable members.
      if netName in portNets: return false
      if pinCount.getOrDefault(netName) != 2: return false
      if not pinsOn.hasKey(netName) or pinsOn[netName].len != 2: return false
      if pinsOn[netName][0] == pinsOn[netName][1]: return false   # a self-loop
      let net = netByName.getOrDefault(netName)
      if net == nil or isGround(net) or isRail(net): return false
      true

    # Adjacency over link nets (<= 2 neighbours, pin order). Iterates in
    # insertion order and only looks tables up, for determinism.
    var adj = newSeq[seq[int]](comps.len)
    for i, c in comps:
      if not usable[i]: continue
      for _, pin in c.pins:
        if pin.net == nil or not isLinkNet(pin.net.name): continue
        let pair = pinsOn[pin.net.name]
        adj[i].add (if pair[0] == i: pair[1] else: pair[0])

    var visited = newSeq[bool](comps.len)
    # Walk each path from a degree-<=1 endpoint, lowest index first.
    for start in 0 ..< comps.len:
      if not usable[start] or visited[start] or adj[start].len > 1: continue
      if adj[start].len == 0: continue            # a lone part is not a chain
      var path: seq[int]
      var cur = start
      var prev = -1
      while cur >= 0 and not visited[cur]:
        visited[cur] = true
        path.add cur
        var nxt = -1
        for n in adj[cur]:
          if n != prev: nxt = n
        prev = cur
        cur = nxt
      if path.len < 2: continue
      # Head is the end with the earlier-sorting free net (else the lower
      # index).
      let headFree = twoTermOtherNet(comps[path[0]], seriesSharedNet(
        comps[path[0]], comps[path[1]]))
      let tailFree = twoTermOtherNet(comps[path[^1]], seriesSharedNet(
        comps[path[^1]], comps[path[^2]]))
      let hn = if headFree != nil: headFree.name else: ""
      let tn = if tailFree != nil: tailFree.name else: ""
      if tn < hn or (tn == hn and path[^1] < path[0]):
        var rev: seq[int]
        for k in countdown(path.high, 0): rev.add path[k]
        path = rev
      groups.add path
  totalPartition(comps.len, groups)

proc seriesNodes(comps: seq[Component], members: seq[int]): seq[string] =
  ## The `members.len + 1` nets along the chain: free head, links, free
  ## tail.
  let headLink = seriesSharedNet(comps[members[0]], comps[members[1]])
  let headFree = twoTermOtherNet(comps[members[0]], headLink)
  result.add (if headFree != nil: headFree.name else: "")
  for k in 0 ..< members.len - 1:
    result.add seriesSharedNet(comps[members[k]], comps[members[k + 1]])
  let tailLink = seriesSharedNet(comps[members[^1]], comps[members[^2]])
  let tailFree = twoTermOtherNet(comps[members[^1]], tailLink)
  result.add (if tailFree != nil: tailFree.name else: "")

proc seriesInternalLayout(comps: seq[Component], syms: seq[SymbolDef],
                          members: seq[int]): seq[Point] =
  ## Members left to right with a `2 * grid` gutter (a positive-length link
  ## wire, and an even pitch so centres stay on the grid), centred on the
  ## origin.
  var totalW = 2.0 * grid * float(members.len - 1)
  for i in members: totalW += syms[i].bodyW
  var x = -totalW / 2.0
  for i in members:
    x += syms[i].bodyW / 2.0
    result.add Point(x: round(x / grid) * grid, y: 0.0)
    x += syms[i].bodyW / 2.0 + 2.0 * grid

proc seriesExternalPins(comps: seq[Component],
                        members: seq[int]): seq[CompositePort] =
  ## One port per link net, covering both adjacent pins. Free end nets get
  ## none: each has one pin inside, passes through, and a rail end keeps its
  ## glyph.
  let nodes = seriesNodes(comps, members)
  for k in 0 ..< members.len - 1:
    let netName = nodes[k + 1]
    var port = CompositePort(net: netName)
    port.covered.add (members[k], twoTermPinOnNet(comps[members[k]], netName))
    port.covered.add (members[k + 1],
                      twoTermPinOnNet(comps[members[k + 1]], netName))
    port.representative = port.covered[0]
    result.add port

proc seriesPickRepresentative(parts: seq[SchematicPart], footprint: seq[Obstacle],
                              port: CompositePort):
    tuple[partIdx: int, pinName: string] =
  ## Link nets never reach the external router; the default stands.
  port.representative

proc seriesInternalRoute(parts: seq[SchematicPart],
                         port: CompositePort): seq[SchematicWire] =
  ## A straight (or L) segment from the representative to the other pin.
  proc at(c: tuple[partIdx: int, pinName: string]): Point =
    for pin in parts[c.partIdx].pins:
      if pin.name == c.pinName: return Point(x: pin.x, y: pin.y)
  let root = at(port.representative)
  for covered in port.covered:
    if covered == port.representative: continue
    let tap = at(covered)
    if tap == root: continue
    var points = @[root]
    if root.x != tap.x and root.y != tap.y:
      points.add Point(x: tap.x, y: root.y)
    points.add tap
    result.add SchematicWire(net: port.net, kind: wkSignal, points: points)

proc seriesRotationCandidates(nl: Netlist, comps: seq[Component],
                              syms: seq[SymbolDef], pos: seq[Point],
                              current: seq[float],
                              members: seq[int]): seq[seq[float]] =
  ## One assignment: every member horizontal, head-side net on -x, reading
  ## left to right.
  let nodes = seriesNodes(comps, members)
  let left = Point(x: -1.0, y: 0.0)
  var cand = current
  for k, m in members:
    let a = angleForCanonicalSide(syms[m], comps[m], nodes[k], left)
    if not a.ok: return
    cand[m] = a.angle
  result.add cand

proc seriesChainKind(): CompositeKind =
  CompositeKind(name: "series-chain",
    orientable: true,
    recognize: seriesRecognize,
    internalLayout: seriesInternalLayout,
    externalPins: seriesExternalPins,
    pickRepresentative: seriesPickRepresentative,
    internalRoute: seriesInternalRoute,
    rotationCandidates: seriesRotationCandidates,
    footprint: boundingBoxFootprint)
