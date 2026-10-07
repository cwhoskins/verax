## The pi motif: a flat two-terminal *series* part with a *shunt-to-ground*
## part at each terminal. Drawn with the series part horizontal and each
## shunt hanging down to ground.
##
## Topology-only recognition (`isGround` on a shunt's far net; rails and
## ground rejected on the series nets), using `isTwoTerminal`. Registered
## after `parallelStackKind`, so a parallel bank stays a stack.

proc piRecognize(comps: seq[Component], syms: seq[SymbolDef]): seq[seq[int]] =
  var groups: seq[seq[int]]
  if comps.len > 0:
    let nl = comps[0].netlist
    var portNets = initHashSet[string]()
    for _, pn in nl.ports:
      if pn != nil: portNets.incl pn.name
    # Net -> traversable components on it, and pin count per net (lookups
    # only).
    var traversableOn = initTable[string, seq[int]]()
    var pinCount = initTable[string, int]()
    for i, c in comps:
      let usable = isTwoTerminal(c, nl) and isPassiveElement(syms[i])
      for _, pin in c.pins:
        if pin.net == nil: continue
        pinCount.mgetOrPut(pin.net.name, 0).inc
        if usable: traversableOn.mgetOrPut(pin.net.name, @[]).add i

    proc external(netName: string): bool =
      ## A pi port must reach beyond the composite (more than the two pins, or
      ## a declared port). A two-pin net is a private junction -- a tee's mid
      ## node, which must not read as a pi.
      netName in portNets or pinCount.getOrDefault(netName) > 2

    proc groundShunt(netName: string, exclude: int): int =
      ## The unique traversable part with one pin on `netName` and the other on
      ## a ground net; -1 unless there is exactly one.
      result = -1
      if not traversableOn.hasKey(netName): return -1
      var count = 0
      for j in traversableOn[netName]:
        if j == exclude: continue
        let other = twoTermOtherNet(comps[j], netName)
        if other != nil and isGround(other):
          inc count
          result = j
      if count != 1: result = -1

    var claimed = newSeq[bool](comps.len)
    for i, c in comps:
      if claimed[i] or not isTwoTerminal(c, nl) or not isPassiveElement(syms[i]):
        continue
      var nets: seq[string]
      var fixed = false
      for _, pin in c.pins:
        if pin.net == nil: continue
        nets.add pin.net.name
        if isGround(pin.net) or isRail(pin.net): fixed = true
      if fixed or nets.len != 2 or nets[0] == nets[1]: continue
      nets.sort()
      if not (external(nets[0]) and external(nets[1])): continue
      let sa = groundShunt(nets[0], i)
      let sb = groundShunt(nets[1], i)
      if sa < 0 or sb < 0 or sa == sb: continue
      if claimed[sa] or claimed[sb]: continue
      claimed[i] = true
      claimed[sa] = true
      claimed[sb] = true
      groups.add @[sa, i, sb]   # [shuntA, series, shuntB], shuntA on nets[0]
  totalPartition(comps.len, groups)

proc piNets(comps: seq[Component], members: seq[int]):
    tuple[a, b: string] =
  ## The two external nets: `a` shared with `shuntA` (`members[0]`), `b`
  ## with `shuntB` (`members[2]`).
  let series = members[1]
  proc shared(shunt: int): string =
    for _, ps in comps[series].pins:
      if ps.net == nil: continue
      for _, ph in comps[shunt].pins:
        if ph.net != nil and ph.net.name == ps.net.name: return ps.net.name
  (a: shared(members[0]), b: shared(members[2]))

proc piInternalLayout(comps: seq[Component], syms: seq[SymbolDef],
                      members: seq[int]): seq[Point] =
  ## Series at the origin, horizontal; each shunt one pitch below its end
  ## pin, vertical, ground down.
  @[Point(x: -pinSpan, y: 2.0 * pinSpan),   # shuntA, under the -x end
    Point(x: 0.0, y: 0.0),                   # series
    Point(x: pinSpan, y: 2.0 * pinSpan)]     # shuntB, under the +x end

proc piExternalPins(comps: seq[Component], members: seq[int]): seq[CompositePort] =
  let series = members[1]
  let nets = piNets(comps, members)
  for (netName, shunt) in [(nets.a, members[0]), (nets.b, members[2])]:
    var port = CompositePort(net: netName)
    port.covered.add (series, twoTermPinOnNet(comps[series], netName))
    port.covered.add (shunt, twoTermPinOnNet(comps[shunt], netName))
    port.representative = port.covered[0]   # the series pin: it exits sideways
    result.add port

proc piPickRepresentative(parts: seq[SchematicPart], footprint: seq[Obstacle],
                          port: CompositePort):
    tuple[partIdx: int, pinName: string] =
  ## The series pin (covered[0]) exits sideways and clears the footprint.
  result = port.representative
  for candidate in port.covered:
    let part = parts[candidate.partIdx]
    var at: Point
    for pin in part.pins:
      if pin.name == candidate.pinName: at = Point(x: pin.x, y: pin.y)
    if not insideAny(at + escapeDir(part, at) * routingClearance, footprint):
      return candidate

proc piInternalRoute(parts: seq[SchematicPart],
                     port: CompositePort): seq[SchematicWire] =
  ## One L (or straight) from the series pin down to the shunt's top pin.
  let rep = parts[port.representative.partIdx]
  var root: Point
  for pin in rep.pins:
    if pin.name == port.representative.pinName: root = Point(x: pin.x, y: pin.y)
  for covered in port.covered:
    if covered == port.representative: continue
    let member = parts[covered.partIdx]
    var tap: Point
    for pin in member.pins:
      if pin.name == covered.pinName: tap = Point(x: pin.x, y: pin.y)
    var points = @[root]
    if root.x != tap.x and root.y != tap.y:
      points.add Point(x: tap.x, y: root.y)
    points.add tap
    result.add SchematicWire(net: port.net, kind: wkSignal, points: points)

proc piRotationCandidates(nl: Netlist, comps: seq[Component],
                          syms: seq[SymbolDef], pos: seq[Point],
                          current: seq[float],
                          members: seq[int]): seq[seq[float]] =
  ## One assignment: series horizontal with `a` on -x (by `shuntA`), shunts
  ## vertical with ground down.
  let nets = piNets(comps, members)
  let left = Point(x: -1.0, y: 0.0)
  let up = Point(x: 0.0, y: -1.0)
  let s = angleForCanonicalSide(syms[members[1]], comps[members[1]], nets.a, left)
  let a = angleForCanonicalSide(syms[members[0]], comps[members[0]], nets.a, up)
  let b = angleForCanonicalSide(syms[members[2]], comps[members[2]], nets.b, up)
  if not (s.ok and a.ok and b.ok): return
  var cand = current
  cand[members[0]] = a.angle
  cand[members[1]] = s.angle
  cand[members[2]] = b.angle
  result.add cand

proc piKind(): CompositeKind =
  CompositeKind(name: "pi",
    orientable: false,   ## shunt legs run to ground; the frame is pinned
    recognize: piRecognize,
    internalLayout: piInternalLayout,
    externalPins: piExternalPins,
    pickRepresentative: piPickRepresentative,
    internalRoute: piInternalRoute,
    rotationCandidates: piRotationCandidates,
    footprint: memberBodiesFootprint)
