## The passive composite motifs -- today, one: a group of parallel flat
## two-terminal parts sharing the same unordered net pair, recognized and
## packed as one placement unit. Ported verbatim from the pre-registry inline
## code -- each hook body below is the corresponding fragment of the old
## `compositePlan` / `positionedCompositePlan` / `compositeInternalRoutes` /
## `constrainedRecomputeRotations`, unchanged in substance. Registered into
## `compositeKinds` (`./composite`) at the bottom.

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
  ## the shared same-net trunk.
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
      result.add SchematicWire(net: port.net, kind: wkSignal, points: points)
    return
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
      result.add SchematicWire(net: port.net, kind: wkSignal, points: @[tap, join])
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
    recognize: parallelRecognize,
    internalLayout: parallelInternalLayout,
    externalPins: parallelExternalPins,
    pickRepresentative: parallelPickRepresentative,
    internalRoute: parallelInternalRoute,
    rotationCandidates: parallelRotationCandidates,
    footprint: boundingBoxFootprint)
