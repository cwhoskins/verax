## The composite arena: kind-agnostic scaffolding for schematic placement
## motifs, and the registry turning registered `CompositeKind`s into one
## `CompositePlan`. Motifs (parallel stack and series chain in `./passive`,
## pi and tee in `./pi`/`./tee`) are included straight after.
##
## Composites are private and schema-preserving: the scene still holds the
## original parts and pins. Adding a motif means registering a kind, never
## adding scene fields or special cases in the router or placement.
type
  CompositePort = object
    net: string
    representative: tuple[partIdx: int, pinName: string]
    covered: seq[tuple[partIdx: int, pinName: string]]

  PlaceableItem = object
    ## One arena entry: a leaf (raw component; `raw` indexes `comps`) or a
    ## composite of earlier entries (`children`, arena indices; may nest).
    raw: int              ## >= 0 for a leaf; -1 for a composite
    kind: int              ## index into compositeKinds; -1 for a leaf
    children: seq[int]     ## arena indices, canonical order; empty for a leaf
    offsets: seq[Point]     ## each child's centre relative to the origin, in
                           ## the canonical frame; `rawOffsets` applies `unitRot`
    ports: seq[CompositePort]
    footprint: seq[Obstacle]
    unitRot: float          ## 0/90/180/270 rigid turn of the whole unit, from
                           ## `lsCompositeOrient`; 0 for leaves and pinned kinds

  CompositeKind = object
    ## The contract a composite type implements: pure hooks over the arrays
    ## `LayoutState` threads. Every field is `{.nimcall.}` (registration order
    ## is precedence is output; see `compositePlan`).
    name: string
    orientable: bool
      ## May `lsCompositeOrient` turn this unit? True for the parallel stack
      ## and series chain (arbitrary canonical frame); false for pi and tee,
      ## whose shunt legs keep ground pointing down.
    recognize: proc(comps: seq[Component], syms: seq[SymbolDef]):
      seq[seq[int]] {.nimcall.}
      ## A *total* partition of `comps`, singletons included (left as leaves).
    internalLayout: proc(comps: seq[Component], syms: seq[SymbolDef],
      members: seq[int]): seq[Point] {.nimcall.}
      ## Canonical, grid-rounded centres relative to the unit origin, one per
      ## `members[i]`.
    externalPins: proc(comps: seq[Component], members: seq[int]):
      seq[CompositePort] {.nimcall.}
      ## Which nets get one reduced external endpoint and which physical pins
      ## each covers.
    pickRepresentative: proc(parts: seq[SchematicPart], footprint: seq[Obstacle],
      port: CompositePort): tuple[partIdx: int, pinName: string] {.nimcall.}
      ## Re-run once positions are final: which covered pin exits the
      ## footprint. Returning `port.representative` keeps the default.
    internalRoute: proc(parts: seq[SchematicPart], port: CompositePort):
      seq[SchematicWire] {.nimcall.}
      ## Wiring from the representative to every other covered pin, emitted
      ## after external routing succeeds.
    rotationCandidates: proc(nl: Netlist, comps: seq[Component],
      syms: seq[SymbolDef], pos: seq[Point], current: seq[float],
      members: seq[int]): seq[seq[float]] {.nimcall.}
      ## Every jointly valid rotation assignment for `members`, each a full
      ## copy of `current`. Empty leaves rotations at `current`.
    footprint: proc(parts: seq[SchematicPart], members: seq[int],
      padding: float): seq[Obstacle] {.nimcall.}
      ## Routing obstacles the composite reserves, once positions are final.
      ## Default `boundingBoxFootprint` (terminals on the box edge); a motif
      ## with interior terminals (the pi) returns padded member bodies so
      ## routes can thread between them. Routing-only: legalization uses its
      ## own bounding box.

  CompositePlan = object
    items: seq[PlaceableItem]
      ## The arena. Leaves occupy `0 ..< comps.len`, indexed like `comps`;
      ## composites follow.
    topLevel: seq[int]
      ## Arena indices placement sees: unclaimed leaves and top-level
      ## composites, in ascending first-raw-member order (observable; see
      ## `compositePlan`).
    ownerOf: seq[int]
      ## rawIdx -> the owning `topLevel` arena index (itself if unclaimed).
    poolOf: seq[int]
      ## rawIdx -> position in `topLevel` (not arena index) -- what semantic
      ## layering uses. The identity permutation when nothing groups.

proc onThisSheet(nl: Netlist, net: Net): bool {.inline.} =
  ## Whether this sheet draws `net`: its own nets, plus global nets (a shared
  ## object registered in every child's `nl.nets`), matched by identity. A
  ## sibling instance's private net is rejected.
  net != nil and (net.netlist == nl or nl.nets.getOrDefault(net.name) == net)

proc isTwoTerminal(c: Component, nl: Netlist): bool =
  ## Topology-only: every flat two-terminal device qualifies, whatever its
  ## kind. Composite recognizers must use this, never the widened
  ## `isTraversable`: they assume a unique other net, so a declared 8-pin
  ## switch must not become a pi/tee member.
  if c == nil or c.netlist != nl or c.subNetlist != nil:
    return false
  var connected = 0
  for _, pin in c.pins:
    if pin.net != nil:
      if not onThisSheet(nl, pin.net): return false
      inc connected
  connected == 2

proc twoTermOtherNet(c: Component, netName: string): Net =
  ## The net on `c`'s other terminal, for a flat two-terminal part with a pin
  ## on `netName`; `nil` if none. Used by the pi/tee recognizers.
  for _, pin in c.pins:
    if pin.net != nil and pin.net.name != netName: return pin.net

proc traversalExits(c: Component, nl: Netlist, fromNet: Net): seq[Net] =
  ## Every net conduction reaches from `fromNet` through `c`, by topology
  ## (never `kind`): the declared `traverse:` edges from the pin on
  ## `fromNet`, else `twoTermOtherNet` as one element. Only caller:
  ## `constrained.pathsFrom`.
  if statesTraversal(c):
    let spec = traversal(c)
    case spec.mode
    of tmNone:
      return
    of tmAll:
      for _, pin in c.pins:
        if pin.net != nil and pin.net != fromNet and pin.net notin result:
          result.add pin.net
      return
    of tmDefault:
      discard
    var fromPins: seq[string]
    for pinName, pin in c.pins:
      if pin.net == fromNet: fromPins.add pinName
    for e in spec.edges:
      if not e.conducts: continue
      for fp in fromPins:
        var otherName = ""
        if e.a == fp: otherName = e.b
        elif e.b == fp: otherName = e.a
        else: continue
        if c.pins.hasKey(otherName):
          let otherNet = c.pins[otherName].net
          if otherNet != nil and otherNet != fromNet and otherNet notin result:
            result.add otherNet
    return
  let other = twoTermOtherNet(c, fromNet.name)
  if other != nil: result.add other

proc isTraversable(c: Component, nl: Netlist): bool =
  ## `isTwoTerminal`, widened: a part whose `traverse:` spec has a conducting
  ## edge from a net this sheet draws is traversable at any pin count (e.g.
  ## an 8-pin RF switch). Only `constrained.pathsFrom` calls it.
  if isTwoTerminal(c, nl): return true
  if c == nil or c.netlist != nl or c.subNetlist != nil or not statesTraversal(c):
    return false
  for _, pin in c.pins:
    if pin.net != nil and onThisSheet(nl, pin.net) and
       traversalExits(c, nl, pin.net).len > 0:
      return true
  false

proc twoTermPinOnNet(c: Component, netName: string): string =
  ## The pin name of `c` sitting on `netName` ("" if none).
  for pinName, pin in c.pins:
    if pin.net != nil and pin.net.name == netName: return pinName

proc isPassiveElement(sd: SymbolDef): bool {.inline.} =
  ## A flat two-terminal passive filter element -- not a source, which
  ## would be misdrawn as a filter's shunt leg. Keyed on the `symbols.nim`
  ## family, never `Component.kind` spelling.
  sd.name notin ["voltage_source", "current_source"]

proc totalPartition(n: int, groups: seq[seq[int]]): seq[seq[int]] =
  ## Fills a recognizer's multi-member `groups` out to the total partition:
  ## each group at its lowest member, singletons elsewhere, ascending.
  ## `groups` must be disjoint subsets of `0 ..< n`.
  var atMin = initTable[int, int]()
  var inGroup = newSeq[bool](n)
  for gi, g in groups:
    var m = g[0]
    for x in g:
      m = min(m, x)
      inGroup[x] = true
    atMin[m] = gi
  for i in 0 ..< n:
    if atMin.hasKey(i): result.add groups[atMin[i]]
    elif not inGroup[i]: result.add @[i]

proc rawMembers(plan: CompositePlan, item: int): seq[int] =
  ## Every raw component under arena entry `item`, depth-first.
  let it = plan.items[item]
  if it.raw >= 0: return @[it.raw]
  for c in it.children: result.add rawMembers(plan, c)

proc canonicalOffsets(plan: CompositePlan, item: int): seq[Point] =
  ## `rawOffsets` without the `unitRot` turn (canonical frame), so
  ## `lsCompositeOrient` can score a trial frame.
  let it = plan.items[item]
  if it.raw >= 0: return @[Point()]
  for ci, c in it.children:
    let base = it.offsets[ci]
    if plan.items[c].raw >= 0:
      result.add base
    else:
      for off in canonicalOffsets(plan, c): result.add base + off

proc rawOffsets(plan: CompositePlan, item: int): seq[Point] =
  ## Parallel to `rawMembers`: each member's centre relative to `item`'s
  ## origin in the placed frame (canonical turned by `unitRot`). A nesting
  ## kind would also need to turn child clusters.
  let it = plan.items[item]
  for off in canonicalOffsets(plan, item):
    result.add rotatedSlot(off, it.unitRot)

proc slotForNet(sd: SymbolDef, c: Component, netName: string):
    tuple[found: bool, slot: Point] =
  ## Declaration order isn't a terminal direction (sources are
  ## native-vertical, passives horizontal); find the member's actual slot.
  var ordinal = 0
  for pinName, pin in c.pins:
    if pin.net != nil and pin.net.name == netName:
      return (true, slotOf(sd, pinName, ordinal))
    inc ordinal

proc angleForCanonicalSide(sd: SymbolDef, c: Component, netName: string,
                           side: Point): tuple[ok: bool, angle: float] =
  ## Rotate a member's own native slot onto `side`, so a horizontal resistor
  ## and a vertical source can share a composite.
  let native = slotForNet(sd, c, netName)
  if not native.found: return
  for angle in rotationChoices:
    if axisUnit(rotatedSlot(native.slot, angle)) == side:
      return (true, angle)

proc validCompositeAxes(sd: SymbolDef, c: Component, sortedNets: seq[string],
                        angle: float, canonicalSide: Point): bool =
  ## Every member must put the two canonical nets on opposite horizontal
  ## sides.
  if sortedNets.len != 2 or sortedNets[0] == sortedNets[1]: return false
  let first = slotForNet(sd, c, sortedNets[0])
  let second = slotForNet(sd, c, sortedNets[1])
  if not first.found or not second.found: return false
  let a = axisUnit(rotatedSlot(first.slot, angle))
  let b = axisUnit(rotatedSlot(second.slot, angle))
  a == canonicalSide and b == Point(x: -canonicalSide.x, y: -canonicalSide.y) and
    a.y == 0.0 and b.y == 0.0

proc compositeMembers(plan: CompositePlan, n: int): seq[bool] =
  result = newSeq[bool](n)
  for idx in plan.topLevel:
    if plan.items[idx].raw < 0:
      for i in rawMembers(plan, idx): result[i] = true

proc restoreCompositeOffsets(plan: CompositePlan, pos: var seq[Point]) =
  ## Reapply canonical offsets after any stage that translates a unit. The
  ## origin is the mean implied origin, keeping the translation and undoing
  ## any member split.
  for idx in plan.topLevel:
    if plan.items[idx].raw >= 0: continue
    let members = rawMembers(plan, idx)
    let offsets = rawOffsets(plan, idx)
    var origin: Point
    for at, i in members: origin += pos[i] - offsets[at]
    origin = origin * (1.0 / float(members.len))
    origin.x = round(origin.x / grid) * grid
    origin.y = round(origin.y / grid) * grid
    for at, i in members: pos[i] = origin + offsets[at]

proc memberBox(p: SchematicPart, padding: float): Obstacle {.inline.} =
  Obstacle(x1: p.x - p.bodyW / 2.0 - padding, y1: p.y - p.bodyH / 2.0 - padding,
           x2: p.x + p.bodyW / 2.0 + padding, y2: p.y + p.bodyH / 2.0 + padding)

proc boundingBoxFootprint(parts: seq[SchematicPart], members: seq[int],
                          padding: float): seq[Obstacle] =
  ## `CompositeKind.footprint` default: one padded box over every member.
  var box: Obstacle
  for at, i in members:
    let b = memberBox(parts[i], padding)
    if at == 0: box = b
    else:
      box.x1 = min(box.x1, b.x1); box.y1 = min(box.y1, b.y1)
      box.x2 = max(box.x2, b.x2); box.y2 = max(box.y2, b.y2)
  @[box]

proc memberBodiesFootprint(parts: seq[SchematicPart], members: seq[int],
                           padding: float): seq[Obstacle] =
  ## `CompositeKind.footprint` for interior terminals: each member's padded
  ## body, so routes can pass between them.
  for i in members: result.add memberBox(parts[i], padding)

proc compositeFootprint(plan: CompositePlan, itemIdx: int,
                        syms: seq[SymbolDef], pos: seq[Point],
                        padding: float): seq[Obstacle] =
  ## `itemIdx` is an arena index (see `ownerOf`).
  var box: Obstacle
  var first = true
  for i in rawMembers(plan, itemIdx):
    let x1 = pos[i].x - syms[i].bodyW / 2.0 - padding
    let y1 = pos[i].y - syms[i].bodyH / 2.0 - padding
    let x2 = pos[i].x + syms[i].bodyW / 2.0 + padding
    let y2 = pos[i].y + syms[i].bodyH / 2.0 + padding
    if first:
      box = Obstacle(x1: x1, y1: y1, x2: x2, y2: y2)
      first = false
    else:
      box.x1 = min(box.x1, x1); box.y1 = min(box.y1, y1)
      box.x2 = max(box.x2, x2); box.y2 = max(box.y2, y2)
  @[box]

proc compositePort(plan: CompositePlan, partIdx: int, pinName: string):
    tuple[found, representative: bool, unit, port: int] =
  ## `unit` is the owning composite's arena index (currently unused by
  ## callers).
  for idx in plan.topLevel:
    if plan.items[idx].raw >= 0: continue
    for p, port in plan.items[idx].ports:
      for covered in port.covered:
        if covered.partIdx == partIdx and covered.pinName == pinName:
          return (true, covered == port.representative, idx, p)

proc compositeExternalPins(pins: seq[RoutePin], plan: CompositePlan): seq[RoutePin] =
  ## External routing sees one endpoint per composite port; other pins keep
  ## their order.
  for pin in pins:
    if pin.pinName.len == 0:
      result.add pin
      continue
    let cp = compositePort(plan, pin.partIdx, pin.pinName)
    if not cp.found or cp.representative: result.add pin

# --- the registry -----------------------------------------------------------
# `parallelStackKind` is defined in `./passive`; `include` is a textual
# splice, so this is an ordinary forward declaration and the `let` below
# initializes after every proc body exists.
proc parallelStackKind(): CompositeKind
proc piKind(): CompositeKind
proc teeKind(): CompositeKind
proc seriesChainKind(): CompositeKind

let compositeKinds: seq[CompositeKind] =
  @[parallelStackKind(), piKind(), teeKind(), seriesChainKind()]
  ## Registration order is recognition precedence is output. `let`, so it
  ## can't change at runtime. Parallel stack first (a shunt that's really a
  ## bank stays a stack, declining the pi/tee); series chain last (a pi/tee
  ## leg that also reads as a chain link draws as the filter section).

proc compositePlan(comps: seq[Component], syms: seq[SymbolDef],
                   bundled: HashSet[string] = initHashSet[string]()): CompositePlan =
  ## Build the placement arena: each registered kind partitions `comps` in
  ## turn; multi-member groups whose members no earlier kind claimed are
  ## accepted and their geometry and ports come from the kind's hooks.
  ## Survivors plus unclaimed singletons go into `topLevel` in ascending
  ## first-raw-member order -- observable, since
  ## `constrainedRecomputeRotations` reads partial results in that order.
  result.items = newSeq[PlaceableItem](comps.len)
  for i in 0 ..< comps.len: result.items[i] = PlaceableItem(raw: i, kind: -1)
  result.ownerOf = newSeq[int](comps.len)
  result.poolOf = newSeq[int](comps.len)

  # All-or-nothing claim per group, in precedence order. No nesting: a kind
  # that must consume an earlier composite would need an arena-index fold.
  var claimed = newSeq[bool](comps.len)
  var groups: seq[tuple[first, kind: int, members: seq[int]]]
  for kindIdx, kind in compositeKinds:
    for members in kind.recognize(comps, syms):
      if members.len < 2: continue
      var free = true
      var first = members[0]
      for m in members:
        if claimed[m]: free = false
        # Can't happen (carriers are boxes), but excluded explicitly: a
        # merged slot would give two member nets the same point.
        if comps[m].designator in bundled: free = false
        first = min(first, m)
      if not free: continue
      for m in members: claimed[m] = true
      groups.add (first: first, kind: kindIdx, members: members)

  # Groups are disjoint, so a first-member -> group map drives one ascending
  # pass.
  var atFirst = initTable[int, int]()
  for gi, g in groups: atFirst[g.first] = gi
  for raw in 0 ..< comps.len:
    if atFirst.hasKey(raw):
      let g = groups[atFirst[raw]]
      let poolPos = result.topLevel.len
      let idx = result.items.len
      result.items.add PlaceableItem(raw: -1, kind: g.kind, children: g.members,
        offsets: compositeKinds[g.kind].internalLayout(comps, syms, g.members),
        ports: compositeKinds[g.kind].externalPins(comps, g.members))
      result.topLevel.add idx
      for m in g.members:
        result.ownerOf[m] = idx
        result.poolOf[m] = poolPos
    elif not claimed[raw]:
      let poolPos = result.topLevel.len
      result.topLevel.add raw
      result.ownerOf[raw] = raw
      result.poolOf[raw] = poolPos

proc positionedCompositePlan(plan: CompositePlan, parts: seq[SchematicPart],
                             padding: float): CompositePlan =
  ## The plan with its footprint materialised for the current centres, and
  ## each port's representative re-picked via `pickRepresentative`. Writes
  ## the arena directly (the `units()` view is a read-only copy).
  result = plan
  for idx in result.topLevel:
    if result.items[idx].raw >= 0: continue
    result.items[idx].footprint =
      compositeKinds[result.items[idx].kind].footprint(
        parts, rawMembers(result, idx), padding)
    let hook = compositeKinds[result.items[idx].kind].pickRepresentative
    for p in 0 ..< result.items[idx].ports.len:
      result.items[idx].ports[p].representative =
        hook(parts, result.items[idx].footprint, result.items[idx].ports[p])

proc compositeInternalRoutes(plan: CompositePlan, parts: seq[SchematicPart],
                             netName: string): seq[SchematicWire] =
  ## Deterministic internal fanout via each kind's `internalRoute`, emitted
  ## after external routing (internal conductors, not router endpoints).
  for idx in plan.topLevel:
    if plan.items[idx].raw >= 0: continue
    let hook = compositeKinds[plan.items[idx].kind].internalRoute
    for port in plan.items[idx].ports:
      if port.net != netName: continue
      result.add hook(parts, port)
