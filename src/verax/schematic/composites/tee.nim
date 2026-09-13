## The tee motif: two flat two-terminal *series* parts meeting at a private
## mid node that also carries one flat two-terminal *shunt-to-ground* part and
## nothing else -- `docs/composites.md` idea 1 (series chain) plus idea 2
## (midpoint tap), tapped to ground. Canonical drawing: the two series parts
## in a horizontal row, the shunt hanging straight down to ground from the
## junction between them.
##
## Recognition is topology-only: the mid net has exactly three pins, all on
## flat two-terminal parts, is neither an interface port nor ground/rail, and
## exactly one of its three legs goes to ground. The mid net is wholly
## internal -- `teeInternalRoute` draws its T-junction and `routing.nim` skips
## external routing for it (a fully-internal composite net). Members are raw
## singletons; registered after `parallelStackKind` and `piKind`.

proc teeRecognize(comps: seq[Component], syms: seq[SymbolDef]): seq[seq[int]] =
  var groups: seq[seq[int]]
  if comps.len > 0:
    let nl = comps[0].netlist
    var portNets = initHashSet[string]()
    for _, pn in nl.ports:
      if pn != nil: portNets.incl pn.name

    var pinCount = initTable[string, int]()
    var traversableOn = initTable[string, seq[int]]()
    var seen = initHashSet[string]()
    var candidates: seq[Net]
    for i, c in comps:
      let trav = isTwoTerminal(c, nl) and isPassiveElement(syms[i])
      for _, pin in c.pins:
        if pin.net == nil: continue
        pinCount.mgetOrPut(pin.net.name, 0).inc
        if trav: traversableOn.mgetOrPut(pin.net.name, @[]).add i
        if pin.net.name notin seen:
          seen.incl pin.net.name
          candidates.add pin.net

    var claimed = newSeq[bool](comps.len)
    for m in candidates:
      let mName = m.name
      if mName in portNets or isGround(m) or isRail(m): continue
      if pinCount.getOrDefault(mName) != 3: continue
      if not traversableOn.hasKey(mName) or traversableOn[mName].len != 3: continue
      var shunt = -1
      var series: seq[int]
      var seriesNets: seq[string]
      var ok = true
      for j in traversableOn[mName]:
        let other = twoTermOtherNet(comps[j], mName)
        if other == nil or other.name == mName: ok = false; break
        if isGround(other):
          if shunt >= 0: ok = false; break     # two ground legs: not a tee
          shunt = j
        elif isRail(other):
          ok = false; break
        else:
          series.add j
          seriesNets.add other.name
      if not ok or shunt < 0 or series.len != 2: continue
      if seriesNets[0] == seriesNets[1]: continue
      if claimed[shunt] or claimed[series[0]] or claimed[series[1]]: continue
      var sA = series[0]
      var sB = series[1]
      if seriesNets[1] < seriesNets[0]: swap(sA, sB)   # sA on the earlier net
      claimed[shunt] = true
      claimed[sA] = true
      claimed[sB] = true
      groups.add @[sA, shunt, sB]
  totalPartition(comps.len, groups)

proc teeMidNet(comps: seq[Component], members: seq[int]): string =
  ## The private mid net: the non-ground net of the shunt (`members[1]`).
  for _, pin in comps[members[1]].pins:
    if pin.net != nil and not isGround(pin.net): return pin.net.name

proc teeInternalLayout(comps: seq[Component], syms: seq[SymbolDef],
                       members: seq[int]): seq[Point] =
  ## series A and B in a horizontal row two grid pitches either side of the
  ## origin; the shunt one pitch below, vertical, ground pin down.
  @[Point(x: -2.0 * pinSpan, y: 0.0),   # seriesA
    Point(x: 0.0, y: 2.0 * pinSpan),     # shunt
    Point(x: 2.0 * pinSpan, y: 0.0)]     # seriesB

proc teeExternalPins(comps: seq[Component], members: seq[int]): seq[CompositePort] =
  ## Only the mid net -- fully internal. `covered` is parallel to `members`
  ## ([seriesA, shunt, seriesB]) so `teeInternalRoute` can tell them apart.
  let mid = teeMidNet(comps, members)
  var port = CompositePort(net: mid)
  for mem in members:
    port.covered.add (mem, twoTermPinOnNet(comps[mem], mid))
  port.representative = port.covered[0]
  result = @[port]

proc teePickRepresentative(parts: seq[SchematicPart], footprint: seq[Obstacle],
                           port: CompositePort):
    tuple[partIdx: int, pinName: string] =
  ## The mid net never reaches the external router, so the deterministic
  ## default stands.
  port.representative

proc teeInternalRoute(parts: seq[SchematicPart],
                      port: CompositePort): seq[SchematicWire] =
  ## The T-junction: seriesA -- seriesB straight through, the shunt tapping
  ## down to the point on that line under its own pin. Two wires meeting at
  ## one vertex, never a shared collinear run.
  proc at(c: tuple[partIdx: int, pinName: string]): Point =
    for pin in parts[c.partIdx].pins:
      if pin.name == c.pinName: return Point(x: pin.x, y: pin.y)
  let a = at(port.covered[0])
  let s = at(port.covered[1])
  let b = at(port.covered[2])
  result.add SchematicWire(net: port.net, kind: wkSignal, points: @[a, b])
  let knee = Point(x: s.x, y: a.y)
  if s != knee:
    result.add SchematicWire(net: port.net, kind: wkSignal, points: @[s, knee])

proc teeRotationCandidates(nl: Netlist, comps: seq[Component],
                           syms: seq[SymbolDef], pos: seq[Point],
                           current: seq[float],
                           members: seq[int]): seq[seq[float]] =
  ## One canonical assignment: series parts horizontal with their mid pins
  ## facing the junction, the shunt vertical with its mid pin up (ground down).
  let mid = teeMidNet(comps, members)
  let right = Point(x: 1.0, y: 0.0)
  let left = Point(x: -1.0, y: 0.0)
  let up = Point(x: 0.0, y: -1.0)
  let a = angleForCanonicalSide(syms[members[0]], comps[members[0]], mid, right)
  let s = angleForCanonicalSide(syms[members[1]], comps[members[1]], mid, up)
  let b = angleForCanonicalSide(syms[members[2]], comps[members[2]], mid, left)
  if not (a.ok and s.ok and b.ok): return
  var cand = current
  cand[members[0]] = a.angle
  cand[members[1]] = s.angle
  cand[members[2]] = b.angle
  result.add cand

proc teeKind(): CompositeKind =
  CompositeKind(name: "tee",
    orientable: false,   ## grounded shunt at the mid node; the frame is pinned
    recognize: teeRecognize,
    internalLayout: teeInternalLayout,
    externalPins: teeExternalPins,
    pickRepresentative: teePickRepresentative,
    internalRoute: teeInternalRoute,
    rotationCandidates: teeRotationCandidates,
    footprint: boundingBoxFootprint)
