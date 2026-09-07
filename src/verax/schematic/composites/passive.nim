## The passive composite motifs. Two live here:
##
## * **parallel stack** (`parallelStackKind`) -- a group of parallel flat
##   two-terminal parts sharing the same unordered net pair, recognized and
##   packed as one placement unit. Ported verbatim from the pre-registry inline
##   code -- each hook body below is the corresponding fragment of the old
##   `compositePlan` / `positionedCompositePlan` / `compositeInternalRoutes` /
##   `constrainedRecomputeRotations`, unchanged in substance.
## * **series chain** (`seriesChainKind`) -- flat two-terminal passive parts
##   wired end to end through *private* two-pin link nets and nothing else, drawn
##   as one horizontal row (`docs/composites.md` idea 1). The complementary case
##   to the parallel stack: chained, not paralleled. Non-nesting -- members are
##   always raw singletons, so a chain never contains a parallel bank and a
##   parallel bank never contains a chain (`docs/composite_placement_stage2.md`
##   §2.6).
##
## Both are registered into `compositeKinds` (`./composite`) at the bottom.

proc parallelRecognize(comps: seq[Component], syms: seq[SymbolDef]): seq[seq[int]] =
  ## `CompositeKind.recognize` for the parallel stack: the *total* partition
  ## of `comps` into groups this kind recognises, singletons included. `syms`
  ## is unused -- recognition here is topology-only -- but is part of the
  ## hook signature every `recognize` proc shares.
  ##
  ## Parallel flat two-terminal parts are one placement unit.  Their endpoint
  ## key is unordered, so declaration and pin order cannot split the group.
  var groupOf = initTable[string, int]()
  for i, c in comps:
    if not isTraversable(c, c.netlist):
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
  ## Members are stacked at raw-body-touching, grid-rounded centres: an
  ## 80 x 80 passive pair is exactly 80 units apart.
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
    # The first member/pin is the deterministic shared external endpoint.
    port.representative = port.covered[0]
    result.add port

proc parallelPickRepresentative(parts: seq[SchematicPart], footprint: seq[Obstacle],
                                port: CompositePort):
    tuple[partIdx: int, pinName: string] =
  ## Pick a physical pin whose normal escape leaves the full composite
  ## footprint. The canonical first member can be an interior tap when the
  ## group is vertically stacked; using an exposed member keeps the one
  ## external endpoint routable while all ordering remains deterministic.
  ## `port.representative` (the deterministic default) stands when no
  ## covered pin actually clears the footprint.
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
  ## Deterministic trunk-and-tap fanout. For three or more members, use one
  ## trunk plus disjoint taps: independent tap-to-root Ls would overlap along
  ## the shared same-net trunk. The stacking axis is read from the covered
  ## pins rather than assumed vertical -- `lsCompositeOrient` may turn the
  ## whole unit, and after a 90/270 turn the members stack in x with the
  ## trunk running horizontal and the taps vertical.
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
  # The canonical-side mapping makes same-net terminals share the cross-axis
  # coordinate; the wider covered-pin spread is therefore the trunk axis.
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
  ## `angle` only defines the canonical side through the reference member.
  ## Every other member derives its own rotation from its native terminal.
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
# Flat two-terminal passive parts wired end to end. Two members are chained
# when they share a *link net*: a net with exactly two pins in total, both on
# distinct usable members, that is neither ground, nor a rail, nor a declared
# interface port. Link nets give every usable part degree <= 2, so the link
# graph is a disjoint set of paths and cycles; a cycle cannot be a horizontal
# row, so it is declined rather than cut. Recognition is topology-only, never a
# `Component.kind` string or a pin name -- the discipline `isTraversable`
# documents.

proc seriesSharedNet(a, b: Component): string =
  ## The net name both `a` and `b` have a pin on ("" if none). Both are flat
  ## two-terminal, so at most one such net exists for a chain pair.
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
      # A chain member must draw as an actual flat two-terminal passive symbol.
      # `isTraversable` alone also passes a fallback *box* -- an unrecognized
      # kind, or a many-pin part (an MCU with only two nets wired) that the
      # semantic walker still traverses but that has no business being
      # rigidified into a horizontal passive row.
      usable[i] = isTraversable(c, nl) and isPassiveElement(syms[i]) and
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

    # adjacency over link nets: for each usable member, its <= 2 neighbours, in
    # pin declaration order. Iterates `comps`/`c.pins` (both insertion order)
    # and only *looks up* the tables -- the determinism rule schematic keeps.
    var adj = newSeq[seq[int]](comps.len)
    for i, c in comps:
      if not usable[i]: continue
      for _, pin in c.pins:
        if pin.net == nil or not isLinkNet(pin.net.name): continue
        let pair = pinsOn[pin.net.name]
        adj[i].add (if pair[0] == i: pair[1] else: pair[0])

    var visited = newSeq[bool](comps.len)
    # Walk each path from a degree-<=1 usable endpoint, lowest index first.
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
      # Canonical direction: head is the end with the earlier-sorting free net,
      # falling back to the lower member index when the two free nets match.
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
  ## The `members.len + 1` net names along the chain: free-head, each link net
  ## in order, free-tail.
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
  ## Members left to right, bodies separated by a `2 * grid` gutter so every
  ## internal link is a real positive-length wire and every centre lands on the
  ## grid (an 80-wide passive at a `2 * grid` gutter is a 160 pitch -- an even
  ## number of grid steps, so the midpoints round symmetrically, which a single
  ## `grid` gutter's odd pitch would not). Centred about the origin, mirroring
  ## `parallelInternalLayout` along the other axis.
  var totalW = 2.0 * grid * float(members.len - 1)
  for i in members: totalW += syms[i].bodyW
  var x = -totalW / 2.0
  for i in members:
    x += syms[i].bodyW / 2.0
    result.add Point(x: round(x / grid) * grid, y: 0.0)
    x += syms[i].bodyW / 2.0 + 2.0 * grid

proc seriesExternalPins(comps: seq[Component],
                        members: seq[int]): seq[CompositePort] =
  ## One port per *link* net -- covering the two adjacent members' pins on it.
  ## The two free end nets get no port: each has a single pin inside the
  ## composite, so `compositeExternalPins` passes it through unchanged and a
  ## ground/rail end still draws its own glyph.
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
  ## A link net never reaches the external router (`fullyInternalComposite`),
  ## so the deterministic default stands.
  port.representative

proc seriesInternalRoute(parts: seq[SchematicPart],
                         port: CompositePort): seq[SchematicWire] =
  ## One straight (or L, should a future layout break the row) segment from the
  ## representative pin to the other covered pin.
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
  ## One canonical assignment: every member horizontal with its head-side net
  ## (`seriesNodes[k]`) on the -x side, so the chain reads left to right.
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
