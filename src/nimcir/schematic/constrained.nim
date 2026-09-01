## Opt-in constrained layered placement for ordinary schematic sheets.
##
## This is deliberately bounded rather than a general graph-drawing solver: it
## derives a stable directed skeleton from output pins, follows two-terminal
## signal paths to their input endpoints, assigns monotonically increasing
## stage blocks, and orders each block from the deterministic seed. The existing
## separator remains the authority for non-overlap.

const
  constrainedMaxParts = 64
  constrainedLayerPitch = 200.0
  # A semantic column can hold a fallback box as well as a two-terminal
  # symbol; leave enough vertical room that legalization need not spill it
  # into a neighbouring column.
  constrainedRowPitch = 240.0
  # A logical layer may use this many adjacent semantic stages. This keeps a
  # passive-heavy layer from becoming an unbounded vertical list while keeping
  # the topology hint deliberately local.
  constrainedMaxStages = 3
  constrainedParallelPitch = 120.0

type
  TraversedPath = object
    parts: seq[int]
    inputs: seq[int]

  ConstrainedTopology = object
    layers: seq[int]
    sameColumn: seq[tuple[src, part: int]]

  # Private, schema-preserving layout composites.  The scene still contains
  # the original parts and pins; this plan only makes their shared external
  # terminals and reserved routing footprint explicit inside the pipeline.
  # Future motif recognisers add another CompositeUnit producer, not scene/API
  # fields or special cases in the router.
  CompositePort = object
    net: string
    representative: tuple[partIdx: int, pinName: string]
    covered: seq[tuple[partIdx: int, pinName: string]]

  CompositeUnit = object
    members: seq[int]
    ## Grid-rounded centres relative to the unit origin.  These are canonical
    ## throughout constrained placement; members are never independently
    ## legalized or repaired.
    offsets: seq[Point]
    ports: seq[CompositePort]
    footprint: Obstacle

  CompositePlan = object
    units: seq[CompositeUnit]

proc isTraversable(c: Component, nl: Netlist): bool =
  ## Semantic path walking is intentionally topology-only. All flat,
  ## two-terminal devices qualify, regardless of their electrical kind.
  if c == nil or c.netlist != nl or c.subNetlist != nil:
    return false
  var connected = 0
  for _, pin in c.pins:
    if pin.net != nil:
      if pin.net.netlist != nl: return false
      inc connected
  connected == 2

proc inputPort(nl: Netlist, net: Net): bool =
  ## Keep port semantics exactly aligned with routing, including its
  ## all-passive/no-driver fallback.
  for _, portNet in nl.ports:
    if portNet == net:
      return portDirection(net) == pdInput
  false

proc pathsFrom(nl: Netlist, start: Net, skip: int,
               idxOf: Table[string, int]): seq[TraversedPath] =
  ## Follow a signal net through eligible two-terminal devices. A component is
  ## not revisited within one walk, making feedback loops bounded and stable.
  var found: seq[TraversedPath]
  proc walk(net: Net, path: seq[int], seen: HashSet[int]) =
    if net == nil or net.netlist != nl or isGround(net) or isRail(net): return
    var ends: seq[int]
    for pin in net.pins:
      let c = pin.component
      if c != nil and c.netlist == nl and idxOf.hasKey(c.designator) and
         pin.kind == ptInput:
        ends.add idxOf[c.designator]
    if ends.len > 0:
      found.add TraversedPath(parts: path, inputs: ends)
      # An input is a semantic endpoint. Continuing through its component
      # would turn an ordinary forward receiver into a spurious self-return.
      return
    for pin in net.pins:
      let c = pin.component
      if not isTraversable(c, nl) or not idxOf.hasKey(c.designator): continue
      let i = idxOf[c.designator]
      if i == skip or i in seen: continue
      var other: Net
      for _, mate in c.pins:
        if mate.net != net:
          other = mate.net
          break
      if other == nil: continue
      var nextSeen = seen
      nextSeen.incl i
      var nextPath = path
      nextPath.add i
      walk(other, nextPath, nextSeen)
  walk(start, @[], initHashSet[int]())
  result = found

proc constrainedTopology(comps: seq[Component],
                         idxOf: Table[string, int]): ConstrainedTopology =
  ## Longest-path relaxation on semantic output arcs. Insertion order breaks
  ## ordinary reverse arcs. A path returning to its own source stays in the
  ## source layer and may use an adjacent stage; a path returning to an earlier
  ## component is feedback, whose passive path remains to the right of the
  ## output that drives it.
  result.layers = newSeq[int](comps.len)
  var arcs: seq[tuple[src, dst: int]]
  var feedback: seq[tuple[src, part: int]]

  proc addPathArcs(src: int, path: seq[int], dst: int) =
    var previous = src
    for part in path:
      if previous < part: arcs.add (previous, part)
      previous = part
    if previous < dst: arcs.add (previous, dst)

  for i, c in comps:
    for _, pin in c.pins:
      if pin.kind != ptOutput or pin.net == nil or isGround(pin.net) or isRail(pin.net):
        continue
      # Preserve the direct output-pin skeleton as well as the longer
      # two-terminal semantic paths below. A final unannotated sink still
      # belongs after the output that drives its net.
      for mate in pin.net.pins:
        if mate.component == nil or mate.component.netlist != c.netlist or
           mate.component.designator == c.designator or
           not idxOf.hasKey(mate.component.designator): continue
        let dst = idxOf[mate.component.designator]
        if i < dst: arcs.add (i, dst)
      for path in pathsFrom(c.netlist, pin.net, i, idxOf):
        for dst in path.inputs:
          if dst == i:
            for part in path.parts: result.sameColumn.add (i, part)
          elif i < dst:
            addPathArcs(i, path.parts, dst)
          else:
            # This is the insertion-order-broken feedback direction. Do not
            # pull it left toward the receiving input: feedback passives read
            # as an output-side path.
            for part in path.parts: feedback.add (i, part)

  # An input interface is a virtual layer-zero source. `portDirection` is the
  # shared implementation used by routing, so explicit pin direction and its
  # no-driver fallback have exactly the same meaning here.
  for _, net in comps[0].netlist.ports:
    if not inputPort(comps[0].netlist, net): continue
    for path in pathsFrom(comps[0].netlist, net, -1, idxOf):
      for dst in path.inputs:
        if path.parts.len > 0:
          var previous = path.parts[0]
          for at in 1 ..< path.parts.len:
            if previous < path.parts[at]: arcs.add (previous, path.parts[at])
            previous = path.parts[at]
          if previous < dst: arcs.add (previous, dst)

  # The insertion-order cycle break makes these arcs a DAG, so n-1 longest-
  # path passes are a strict bound.
  for _ in 1 ..< comps.len:
    var next = result.layers
    for a in arcs:
      if result.layers[a.src] + 1 > next[a.dst]:
        next[a.dst] = result.layers[a.src] + 1
    if next == result.layers: break
    result.layers = next

  for f in feedback:
    result.layers[f.part] = max(result.layers[f.part], result.layers[f.src] + 1)
  for s in result.sameColumn:
    result.layers[s.part] = result.layers[s.src]

proc parallelGroups(comps: seq[Component]): seq[seq[int]] =
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

proc constrainedTargets(comps: seq[Component], pos: seq[Point],
                        idxOf: Table[string, int]): seq[Point] =
  ## Stable, bounded stage placement. Parallel two-terminal parts share a
  ## unit; units fill at most three adjacent stages before adding another row.
  ## The incoming seed resolves all ties, preserving deterministic ordering.
  if comps.len > constrainedMaxParts: return pos
  var topology = constrainedTopology(comps, idxOf)
  let groups = parallelGroups(comps)
  var groupLayers = newSeq[int](groups.len)
  var groupOfPart = newSeq[int](comps.len)
  for g, members in groups:
    for i in members:
      groupOfPart[i] = g
      groupLayers[g] = max(groupLayers[g], topology.layers[i])
  # A local return is allowed one semantic stage either side of its source;
  # reserve a second stage even for the minimal source-plus-feedback case.
  var localReturn = newSeq[bool](comps.len)
  var returnSource = newSeq[int](groups.len)
  for g in 0 ..< returnSource.len: returnSource[g] = -1
  for s in topology.sameColumn:
    localReturn[topology.layers[s.src]] = true
    returnSource[groupOfPart[s.part]] = groupOfPart[s.src]

  result = newSeq[Point](comps.len)
  var xStage = 0
  var maxY = 0.0
  for layer in 0 ..< comps.len:
    var units: seq[int]
    for g in 0 ..< groups.len:
      if groupLayers[g] == layer: units.add g
    if units.len == 0: continue
    units.sort(proc(a, b: int): int =
      let ay = min(pos[groups[a][0]].y, pos[groups[a][^1]].y)
      let by = min(pos[groups[b][0]].y, pos[groups[b][^1]].y)
      result = cmp(ay, by)
      if result == 0: result = cmp(groups[a][0], groups[b][0]))
    var stages = min(constrainedMaxStages, (units.len + 2) div 3)
    if localReturn[layer]: stages = max(stages, min(2, constrainedMaxStages))
    # For the minimal local loop, put the return beside its source. The
    # deterministic seed chooses which side, so this is not output-side-only.
    if units.len >= 2 and units.len <= stages:
      for returnGroup, sourceGroup in returnSource:
        if sourceGroup < 0 or groupLayers[returnGroup] != layer: continue
        var returnAt = -1
        var sourceAt = -1
        for at, g in units:
          if g == returnGroup: returnAt = at
          if g == sourceGroup: sourceAt = at
        if returnAt < 0 or sourceAt < 0: continue
        let returnLeft = pos[groups[returnGroup][0]].x <=
          pos[groups[sourceGroup][0]].x
        let desiredReturn = if returnLeft: 0 else: 1
        let desiredSource = 1 - desiredReturn
        swap(units[returnAt], units[desiredReturn])
        if sourceAt == desiredReturn: sourceAt = returnAt
        swap(units[sourceAt], units[desiredSource])
    for slot, g in units:
      let stage = slot mod stages
      let row = slot div stages
      for member, i in groups[g]:
        let y = float(row) * constrainedRowPitch +
          float(member) * constrainedParallelPitch
        result[i] = Point(x: float(xStage + stage) * constrainedLayerPitch,
                          y: y)
        maxY = max(maxY, y)
    xStage += stages
  # Centre the sheet about the origin, retaining exact grid coordinates.
  let xShift = float(xStage - 1) * constrainedLayerPitch / 2.0
  let yShift = maxY / 2.0
  for p in mitems(result):
    p.x -= xShift
    p.y -= yShift

proc constrainedSemanticSeed(comps: seq[Component], pos: var seq[Point],
                             idxOf: Table[string, int]) =
  if comps.len <= constrainedMaxParts and comps.len > 0:
    pos = constrainedTargets(comps, pos, idxOf)

proc constrainedAnchors(comps: seq[Component], seed: seq[Point],
                        idxOf: Table[string, int]): seq[Point] =
  ## Semantic columns are deliberately *soft* anchors.  The constrained policy
  ## must retain the topology hint without overwriting the force solution (and
  ## without turning a feedback sheet into a rigid template).
  if comps.len <= constrainedMaxParts and comps.len > 0:
    constrainedTargets(comps, seed, idxOf)
  else:
    seed

proc constrainedRefine(comps: seq[Component], pos: var seq[Point],
                       idxOf: Table[string, int]) =
  ## Kept as the stage hook for archive compatibility.  Refinement is now done
  ## by the bounded soft-anchor force and group search, never by a hard snap.
  discard

proc slotForNet(sd: SymbolDef, c: Component, netName: string):
    tuple[found: bool, slot: Point] =
  ## The declaration order is not a terminal direction: voltage sources, for
  ## example, are native-vertical while passives are native-horizontal. Find
  ## this member's actual native slot for the canonical endpoint instead.
  var ordinal = 0
  for pinName, pin in c.pins:
    if pin.net != nil and pin.net.name == netName:
      return (true, slotOf(sd, pinName, ordinal))
    inc ordinal

proc angleForCanonicalSide(sd: SymbolDef, c: Component, netName: string,
                           side: Point): tuple[ok: bool, angle: float] =
  ## Rotate a member's own native slot onto `side`, rather than applying the
  ## reference member's numeric angle to every member. This is what lets a
  ## horizontal resistor and a native-vertical source share one composite.
  let native = slotForNet(sd, c, netName)
  if not native.found: return
  for angle in rotationChoices:
    if axisUnit(rotatedSlot(native.slot, angle)) == side:
      return (true, angle)

proc validCompositeAxes(sd: SymbolDef, c: Component, sortedNets: seq[string],
                        angle: float, canonicalSide: Point): bool =
  ## Every member must put the two canonical nets on opposite horizontal
  ## sides. Never accept an orientation merely because the first member fit.
  if sortedNets.len != 2 or sortedNets[0] == sortedNets[1]: return false
  let first = slotForNet(sd, c, sortedNets[0])
  let second = slotForNet(sd, c, sortedNets[1])
  if not first.found or not second.found: return false
  let a = axisUnit(rotatedSlot(first.slot, angle))
  let b = axisUnit(rotatedSlot(second.slot, angle))
  a == canonicalSide and b == Point(x: -canonicalSide.x, y: -canonicalSide.y) and
    a.y == 0.0 and b.y == 0.0

proc portTarget(nl: Netlist, comps: seq[Component], net: Net, pos: seq[Point], syms: seq[SymbolDef]):
    tuple[has: bool, p: Point] =
  ## A declared interface participates before ports are materialised.  This is
  ## candidate geometry, not a post-route cosmetic pull: it breaks the otherwise
  ## symmetric all-passive sheet at the same point as ordinary pin attraction.
  var declared = false
  for _, portNet in nl.ports:
    if portNet == net: declared = true; break
  if not declared: return
  var minX = Inf
  var maxX = -Inf
  var y = 0.0
  var count = 0
  for i in 0 ..< pos.len:
    minX = min(minX, pos[i].x - syms[i].bodyW / 2.0)
    maxX = max(maxX, pos[i].x + syms[i].bodyW / 2.0)
  for pin in net.pins:
    if pin.component == nil or pin.component.netlist != nl: continue
    for i, c in comps:
      if c == pin.component:
        y += pos[i].y
        inc count
        break
  if count == 0: return
  let d = portDirection(net)
  if d == pdInput or d == pdUnspecified:
    result = (true, Point(x: minX - constrainedLayerPitch, y: y / float(count)))
  else:
    result = (true, Point(x: maxX + constrainedLayerPitch, y: y / float(count)))

proc constrainedRouteScore(nl: Netlist, comps: seq[Component],
                           syms: seq[SymbolDef], pos: seq[Point], rots: seq[float],
                           anchors: seq[Point]): tuple[hits, bends: int, length, drift: float] =
  ## Cheap obstacle-aware rectilinear estimate used only to rank the bounded
  ## candidate orientations.  It intentionally does not replace the router:
  ## obstacle hits, bends and length are a stable preview; routing remains the
  ## authority for the final path.
  let pw = pinWorldPositions(comps, syms, pos, rots)
  for i, c in comps:
    for pinName, pin in c.pins:
      if pin.net == nil or isGround(pin.net) or isRail(pin.net): continue
      let mine = pw[pinKey(c, pinName)]
      var target = Point()
      var count = 0
      for other in pin.net.pins:
        if other.component == nil or other.component == c or
           other.component.netlist != nl: continue
        let key = pinKey(other.component, other.name)
        if pw.hasKey(key): target += pw[key]; inc count
      let pt = portTarget(nl, comps, pin.net, pos, syms)
      if pt.has: target += pt.p; inc count
      if count == 0: continue
      target = target * (1.0 / float(count))
      result.length += manhattan(mine, target)
      if mine.x != target.x and mine.y != target.y: inc result.bends
      # Both deterministic L choices are inspected; a hit means neither clean
      # candidate is available.  This is enough to reject a facing-across
      # parallel layout when its direct exits run through a neighbour.
      var clearHV = true
      var clearVH = true
      for j in 0 ..< comps.len:
        if j == i: continue
        let r = Obstacle(x1: pos[j].x - syms[j].bodyW / 2.0 - routingClearance,
          y1: pos[j].y - syms[j].bodyH / 2.0 - routingClearance,
          x2: pos[j].x + syms[j].bodyW / 2.0 + routingClearance,
          y2: pos[j].y + syms[j].bodyH / 2.0 + routingClearance)
        if segBlocked(mine, Point(x: target.x, y: mine.y), @[r]) or
           segBlocked(Point(x: target.x, y: mine.y), target, @[r]): clearHV = false
        if segBlocked(mine, Point(x: mine.x, y: target.y), @[r]) or
           segBlocked(Point(x: mine.x, y: target.y), target, @[r]): clearVH = false
      if not clearHV and not clearVH: inc result.hits
  for i in 0 ..< pos.len: result.drift += manhattan(pos[i], anchors[i])

proc compositePlan(comps: seq[Component], syms: seq[SymbolDef]): CompositePlan =
  ## Build the constrained placement units before the first seed. Members are
  ## stacked at raw-body-touching, grid-rounded centres: an 80 x 80 passive
  ## pair is exactly 80 units apart. External clearance belongs to the one
  ## unified footprint, never between private members.
  for members in parallelGroups(comps):
    if members.len < 2: continue
    var unit = CompositeUnit(members: members)
    var totalH = 0.0
    for i in members: totalH += syms[i].bodyH
    var y = -totalH / 2.0
    for i in members:
      y += syms[i].bodyH / 2.0
      unit.offsets.add Point(x: 0.0, y: round(y / grid) * grid)
      y += syms[i].bodyH / 2.0
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
      unit.ports.add port
    result.units.add unit

proc compositeMembers(plan: CompositePlan, n: int): seq[bool] =
  result = newSeq[bool](n)
  for unit in plan.units:
    for i in unit.members: result[i] = true

proc restoreCompositeOffsets(plan: CompositePlan, pos: var seq[Point]) =
  ## Reapply the canonical member offsets after every stage that can translate
  ## a unit. The origin is the mean of the current implied origins, so a force
  ## or pack translation is retained while any attempted member split vanishes.
  for unit in plan.units:
    var origin: Point
    for at, i in unit.members: origin += pos[i] - unit.offsets[at]
    origin = origin * (1.0 / float(unit.members.len))
    origin.x = round(origin.x / grid) * grid
    origin.y = round(origin.y / grid) * grid
    for at, i in unit.members: pos[i] = origin + unit.offsets[at]

proc compositeFootprint(plan: CompositePlan, unitIndex: int,
                        syms: seq[SymbolDef], pos: seq[Point],
                        padding: float): Obstacle =
  var first = true
  for i in plan.units[unitIndex].members:
    let x1 = pos[i].x - syms[i].bodyW / 2.0 - padding
    let y1 = pos[i].y - syms[i].bodyH / 2.0 - padding
    let x2 = pos[i].x + syms[i].bodyW / 2.0 + padding
    let y2 = pos[i].y + syms[i].bodyH / 2.0 + padding
    if first:
      result = Obstacle(x1: x1, y1: y1, x2: x2, y2: y2)
      first = false
    else:
      result.x1 = min(result.x1, x1); result.y1 = min(result.y1, y1)
      result.x2 = max(result.x2, x2); result.y2 = max(result.y2, y2)

proc positionedCompositePlan(plan: CompositePlan, parts: seq[SchematicPart],
                             padding: float): CompositePlan =
  ## The same early plan, with its one external footprint materialised for the
  ## current centres. Routing and legalization choose their own padding.
  result = plan
  for u in 0 ..< result.units.len:
    var first = true
    for i in result.units[u].members:
      let p = parts[i]
      let x1 = p.x - p.bodyW / 2.0 - padding
      let y1 = p.y - p.bodyH / 2.0 - padding
      let x2 = p.x + p.bodyW / 2.0 + padding
      let y2 = p.y + p.bodyH / 2.0 + padding
      if first:
        result.units[u].footprint = Obstacle(x1: x1, y1: y1, x2: x2, y2: y2)
        first = false
      else:
        result.units[u].footprint.x1 = min(result.units[u].footprint.x1, x1)
        result.units[u].footprint.y1 = min(result.units[u].footprint.y1, y1)
        result.units[u].footprint.x2 = max(result.units[u].footprint.x2, x2)
        result.units[u].footprint.y2 = max(result.units[u].footprint.y2, y2)
    # Pick a physical pin whose normal escape leaves the full composite
    # footprint.  The canonical first member can be an interior tap when the
    # group is vertically stacked; using an exposed member keeps the one
    # external endpoint routable while all ordering remains deterministic.
    for p in 0 ..< result.units[u].ports.len:
      for candidate in result.units[u].ports[p].covered:
        let part = parts[candidate.partIdx]
        var at: Point
        for pin in part.pins:
          if pin.name == candidate.pinName: at = Point(x: pin.x, y: pin.y)
        let exitPt = at + escapeDir(part, at) * routingClearance
        if not (exitPt.x > result.units[u].footprint.x1 + 1e-9 and exitPt.x < result.units[u].footprint.x2 - 1e-9 and
                exitPt.y > result.units[u].footprint.y1 + 1e-9 and exitPt.y < result.units[u].footprint.y2 - 1e-9):
          result.units[u].ports[p].representative = candidate
          break

proc compositePort(plan: CompositePlan, partIdx: int, pinName: string):
    tuple[found, representative: bool, unit, port: int] =
  for u, unit in plan.units:
    for p, port in unit.ports:
      for covered in port.covered:
        if covered.partIdx == partIdx and covered.pinName == pinName:
          return (true, covered == port.representative, u, p)

proc compositeExternalPins(pins: seq[RoutePin], plan: CompositePlan): seq[RoutePin] =
  ## External routing sees one endpoint per composite port.  Non-composite
  ## pins (including interface ports) remain in their original order.
  for pin in pins:
    if pin.pinName.len == 0:
      result.add pin
      continue
    let cp = compositePort(plan, pin.partIdx, pin.pinName)
    if not cp.found or cp.representative: result.add pin

proc compositeInternalRoutes(plan: CompositePlan, parts: seq[SchematicPart],
                             netName: string): seq[SchematicWire] =
  ## Deterministic trunk-and-tap fanout.  It is emitted after external routing:
  ## these are internal composite conductors, not additional external router
  ## endpoints or occupancy obstacles. For three or more members, use one
  ## trunk plus disjoint taps: independent tap-to-root Ls would overlap along
  ## the shared same-net trunk.
  for unit in plan.units:
    for port in unit.ports:
      if port.net != netName: continue
      let rep = parts[port.representative.partIdx]
      var root: Point
      for pin in rep.pins:
        if pin.name == port.representative.pinName:
          root = Point(x: pin.x, y: pin.y)
      var taps: seq[Point]
      for covered in port.covered:
        if covered == port.representative: continue
        let member = parts[covered.partIdx]
        for pin in member.pins:
          if pin.name == covered.pinName:
            taps.add Point(x: pin.x, y: pin.y)
      if taps.len <= 1:
        for tap in taps:
          var points = @[tap]
          if tap.x != root.x and tap.y != root.y:
            points.add Point(x: root.x, y: tap.y)
          points.add root
          result.add SchematicWire(net: netName, kind: wkSignal, points: points)
        continue
      # Composite members are vertically stacked. The canonical-side mapping
      # makes each same-net terminal share an x coordinate; retaining the
      # horizontal taps also keeps this total for future unequal pin spans.
      var trunk = @[root]
      for tap in taps: trunk.add Point(x: root.x, y: tap.y)
      trunk.sort(proc(a, b: Point): int = cmp(a.y, b.y))
      var unique: seq[Point]
      for point in trunk:
        if unique.len == 0 or point != unique[^1]: unique.add point
      for tap in taps:
        let join = Point(x: root.x, y: tap.y)
        if tap != join:
          result.add SchematicWire(net: netName, kind: wkSignal,
                                   points: @[tap, join])
      if unique.len >= 2:
        result.add SchematicWire(net: netName, kind: wkSignal, points: unique)

proc constrainedRecomputeRotations(nl: Netlist, comps: seq[Component],
                                   syms: seq[SymbolDef], pos: seq[Point], rots: seq[float],
                                   anchors: seq[Point]): seq[float] =
  ## Deterministic group-aware four-way search.  Its ordering is deliberately
  ## lexicographic: existing power direction, estimated routing quality, then
  ## semantic/seed drift.  Parallel members are evaluated as one candidate.
  result = rots
  let groups = parallelGroups(comps)
  for members in groups:
    if members.len == 1:
      let i = members[0]
      let pw = pinWorldPositions(comps, syms, pos, result)
      result[i] = bestRotation(syms[i], comps[i], pos[i], result[i], pw, 0.0)
      continue
    var nets: seq[string]
    for _, p in comps[members[0]].pins: nets.add p.net.name
    nets.sort()
    var best = result
    var bestRank: array[4, int]
    var bestScore: tuple[hits, bends: int, length, drift: float]
    var first = true
    let reference = slotForNet(syms[members[0]], comps[members[0]], nets[0])
    if not reference.found: continue
    for angle in rotationChoices:
      # `angle` only defines the canonical side through the reference member.
      # Every other member derives its own rotation from its native terminal.
      let canonicalSide = axisUnit(rotatedSlot(reference.slot, angle))
      if canonicalSide.y != 0.0: continue
      var cand = result
      var rank: array[4, int]
      var valid = true
      for i in members:
        let mapped = angleForCanonicalSide(syms[i], comps[i], nets[0], canonicalSide)
        if not mapped.ok or not validCompositeAxes(syms[i], comps[i], nets,
                                                   mapped.angle, canonicalSide):
          valid = false
          break
        let a = mapped.angle
        cand[i] = a
        let r = powerRank(syms[i], comps[i], a)
        for k in 0 ..< rank.len: rank[k] += r[k]
      if not valid: continue
      let score = constrainedRouteScore(nl, comps, syms, pos, cand, anchors)
      var better = first or rankLess(rank, bestRank)
      if not better and rankEqual(rank, bestRank):
        if score.hits != bestScore.hits:
          better = score.hits < bestScore.hits
        elif score.bends != bestScore.bends:
          better = score.bends < bestScore.bends
        elif abs(score.length - bestScore.length) > 1e-9:
          better = score.length < bestScore.length
        else:
          better = score.drift < bestScore.drift - 1e-9
      if better:
        first = false; best = cand; bestRank = rank; bestScore = score
    result = best
