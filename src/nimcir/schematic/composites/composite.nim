## The composite arena: kind-agnostic scaffolding for schematic placement
## motifs, plus the registry that turns a plan of registered `CompositeKind`s
## into one `CompositePlan`. The concrete motifs themselves -- the parallel
## stack and the series chain in `./passive`, the pi and tee filter sections
## in `./pi` and `./tee` -- live beside this file, all included straight after
## it.
##
## Private, schema-preserving layout composites.  The scene still contains
## the original parts and pins; the arena below only makes their shared
## external terminals and reserved routing footprint explicit inside the
## pipeline. A composite type is a registered `CompositeKind` (defined
## further down, once its seven hooks' return types exist) -- adding a motif
## means registering another kind, never adding scene/API fields or a
## special case in the router, placement, or `constrainedRecomputeRotations`.
type
  CompositePort = object
    net: string
    representative: tuple[partIdx: int, pinName: string]
    covered: seq[tuple[partIdx: int, pinName: string]]

  PlaceableItem = object
    ## One entry of the placement arena: either a leaf (a raw component) or a
    ## composite built from earlier entries. `raw`/`children` are mutually
    ## exclusive: a leaf's `raw` is its index into `comps`/`syms`/`pos`; a
    ## composite's `children` are arena indices, each of which may itself be a
    ## leaf or a further composite -- the recursion nesting needs, unused
    ## until a second `CompositeKind` exists.
    raw: int              ## >= 0 for a leaf; -1 for a composite
    kind: int              ## index into compositeKinds; -1 until Stage 1.5
    children: seq[int]     ## arena indices, canonical order; empty for a leaf
    offsets: seq[Point]     ## each child's centre relative to this item's origin,
                           ## in the motif's *canonical* frame -- `internalLayout`
                           ## always authors this frame; `rawOffsets` applies
                           ## `unitRot` on the way out
    ports: seq[CompositePort]
    footprint: seq[Obstacle]
    unitRot: float          ## 0/90/180/270: a rigid quarter-turn of the whole
                           ## unit chosen by `lsCompositeOrient` (and revisited
                           ## in the definitive orient pass) for an `orientable`
                           ## kind. 0 for a leaf and for a pinned kind, so the
                           ## historical `unitRot == 0` geometry is exactly the
                           ## default.

  CompositeKind = object
    ## The whole contract a composite type implements: six pure hooks over
    ## the arrays `LayoutState` already threads, so a recognizer needs no
    ## access to placement/routing internals. Every field is `{.nimcall.}` --
    ## a plain function pointer, not a closure -- since `compositeKinds` is
    ## module-level state and registration order *is* recognition precedence
    ## *is* output (see `compositePlan`).
    name: string
    orientable: bool
      ## May `lsCompositeOrient` turn this whole unit through 0/90/180/270?
      ## `true` for the parallel stack and the series chain -- their canonical
      ## horizontal frame is arbitrary, and a rotated unit reads better when
      ## its endpoints sit above and below rather than left and right. `false`
      ## for the pi and the tee: their shunt legs run to ground and
      ## ground-points-down is a real schematic convention, not a wirelength
      ## trade. A pinned kind keeps `unitRot == 0` and its output is unchanged.
    recognize: proc(comps: seq[Component], syms: seq[SymbolDef]):
      seq[seq[int]] {.nimcall.}
      ## The *total* partition of `comps` into groups this kind recognises,
      ## singletons included (`parallelRecognize`'s own contract) -- a group
      ## of one is left as an ordinary leaf.
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
      ## Re-run once positions are final: which covered pin actually exits
      ## the footprint. Returning `port.representative` unchanged is a valid
      ## "keep the default" answer.
    internalRoute: proc(parts: seq[SchematicPart], port: CompositePort):
      seq[SchematicWire] {.nimcall.}
      ## The wiring from the representative out to every other covered pin,
      ## emitted after external routing succeeds.
    rotationCandidates: proc(nl: Netlist, comps: seq[Component],
      syms: seq[SymbolDef], pos: seq[Point], current: seq[float],
      members: seq[int]): seq[seq[float]] {.nimcall.}
      ## Every jointly valid rotation assignment for `members`, each a
      ## full-length copy of `current` with just these members' angles
      ## overwritten. An empty result leaves rotations at `current`.
    footprint: proc(parts: seq[SchematicPart], members: seq[int],
      padding: float): seq[Obstacle] {.nimcall.}
      ## The routing obstacle(s) the composite reserves, once positions are
      ## final. `boundingBoxFootprint` -- one padded box over every member --
      ## is the default and what the parallel stack and the tee use: their
      ## external terminals sit on that box's edge. A motif whose external
      ## terminals are *interior* to the bounding box (the pi: its series
      ## part's pins are boxed in by the wider flanking shunts) returns the
      ## padded member bodies individually instead, so a route can thread the
      ## channels between them. Placement legalization keeps its own
      ## bounding-box `compositeFootprint` regardless -- this hook is
      ## routing-only.

  CompositePlan = object
    items: seq[PlaceableItem]
      ## The arena. Leaves occupy `0 ..< comps.len`, indexed identically to
      ## `comps`/`syms`/`pos`; composites are appended after, in the order
      ## `compositePlan` builds them.
    topLevel: seq[int]
      ## Arena indices placement actually sees -- unclaimed leaves and
      ## top-level composites, interleaved in ascending first-raw-member
      ## order (the same order `parallelRecognize` yields; see the
      ## `constrainedRecomputeRotations` order-dependence note below).
    ownerOf: seq[int]
      ## rawIdx -> the `topLevel` arena index owning it (itself, for an
      ## unclaimed leaf).
    poolOf: seq[int]
      ## rawIdx -> that raw component's *position in* `topLevel` (0 ..<
      ## `topLevel.len`), not the arena index `ownerOf` gives. This is the
      ## number every semantic-layering computation actually wants: "which
      ## pool item is this", not "which arena slot". With no multi-member
      ## group recognized, `topLevel` is the ascending singleton list, so
      ## `poolOf` is the identity permutation -- the fact that makes a
      ## composite-free sheet provably unchanged by pool-indexing the
      ## semantic layer (`constrainedTopology`/`constrainedTargets` below).

proc onThisSheet(nl: Netlist, net: Net): bool {.inline.} =
  ## Whether `net` is one this sheet draws. Its own nets qualify; so does a
  ## **global** net (SPICE node "0", any `global = true` rail) -- `clone`
  ## leaves that a single shared object whose `.netlist` stays the root, but
  ## registers it in every child's `nl.nets` under its name, so identity
  ## against that entry is the test. A sibling instance's *private* net is
  ## the thing this must still reject: it is not in this sheet's `nl.nets`.
  net != nil and (net.netlist == nl or nl.nets.getOrDefault(net.name) == net)

proc isTraversable(c: Component, nl: Netlist): bool =
  ## Semantic path walking is intentionally topology-only. All flat,
  ## two-terminal devices qualify, regardless of their electrical kind. Used
  ## both by a `recognize` hook (`parallelRecognize`) and by the constrained
  ## placement's own semantic walk (`pathsFrom`).
  if c == nil or c.netlist != nl or c.subNetlist != nil:
    return false
  var connected = 0
  for _, pin in c.pins:
    if pin.net != nil:
      if not onThisSheet(nl, pin.net): return false
      inc connected
  connected == 2

proc twoTermOtherNet(c: Component, netName: string): Net =
  ## The net on `c`'s *other* terminal, for a flat two-terminal part with one
  ## pin on `netName`. `nil` if it has no such other pin. Topology-only, used
  ## by the pi/tee recognizers.
  for _, pin in c.pins:
    if pin.net != nil and pin.net.name != netName: return pin.net

proc twoTermPinOnNet(c: Component, netName: string): string =
  ## The pin name of `c` sitting on `netName` ("" if none).
  for pinName, pin in c.pins:
    if pin.net != nil and pin.net.name == netName: return pinName

proc isPassiveElement(sd: SymbolDef): bool {.inline.} =
  ## A flat two-terminal part drawn as a passive filter element -- not a
  ## source. The pi/tee motifs are *passive* sections: a source sitting on a
  ## filter node is topologically a leg to ground but is not a shunt element,
  ## and drawing it as one of a filter's flanking legs would misrepresent it.
  ## Keyed on the symbol family `symbols.nim` already assigns (which folds
  ## `battery`/`iswitch` in with their sources), never on `Component.kind`
  ## spelling.
  sd.name notin ["voltage_source", "current_source"]

proc totalPartition(n: int, groups: seq[seq[int]]): seq[seq[int]] =
  ## The `CompositeKind.recognize` contract is a *total* partition of `0 ..< n`.
  ## A recognizer that only computes its multi-member groups gets the rest
  ## filled in here: each group emitted at its lowest member's position, a
  ## singleton everywhere else, so the result is in ascending first-member
  ## order. `groups` must be disjoint and each a subset of `0 ..< n`.
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
  ## Every raw component under arena entry `item`, depth-first. A single
  ## `@[it.raw]` at depth 1 (every child today is a leaf); the recursion is
  ## for a future kind whose children are themselves composites.
  let it = plan.items[item]
  if it.raw >= 0: return @[it.raw]
  for c in it.children: result.add rawMembers(plan, c)

proc canonicalOffsets(plan: CompositePlan, item: int): seq[Point] =
  ## `rawOffsets` without the `unitRot` turn: each raw member's centre relative
  ## to `item`'s own origin in the motif's canonical frame, composed down the
  ## tree. Identical to `items[item].offsets` at depth 1. `lsCompositeOrient`
  ## reads this to score a trial frame before committing `unitRot`.
  let it = plan.items[item]
  if it.raw >= 0: return @[Point()]
  for ci, c in it.children:
    let base = it.offsets[ci]
    if plan.items[c].raw >= 0:
      result.add base
    else:
      for off in canonicalOffsets(plan, c): result.add base + off

proc rawOffsets(plan: CompositePlan, item: int): seq[Point] =
  ## Parallel to `rawMembers(plan, item)`: each raw member's centre relative
  ## to `item`'s own origin, in the *placed* frame -- the canonical offset
  ## turned by this unit's `unitRot`. `rotatedSlot(off, 0.0)` is `off`, so a
  ## leaf and a pinned/unrotated composite are exactly `canonicalOffsets`.
  ## Depth-1 today; a genuine nesting kind would also need to turn each child
  ## cluster by its parent's `unitRot`, not only the top offsets.
  let it = plan.items[item]
  for off in canonicalOffsets(plan, item):
    result.add rotatedSlot(off, it.unitRot)

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

proc compositeMembers(plan: CompositePlan, n: int): seq[bool] =
  result = newSeq[bool](n)
  for idx in plan.topLevel:
    if plan.items[idx].raw < 0:
      for i in rawMembers(plan, idx): result[i] = true

proc restoreCompositeOffsets(plan: CompositePlan, pos: var seq[Point]) =
  ## Reapply the canonical member offsets after every stage that can translate
  ## a unit. The origin is the mean of the current implied origins, so a force
  ## or pack translation is retained while any attempted member split vanishes.
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
  ## `CompositeKind.footprint` for a motif with interior external terminals:
  ## each member's padded body on its own, so a route can pass through the
  ## channels the bounding box would have sealed.
  for i in members: result.add memberBox(parts[i], padding)

proc compositeFootprint(plan: CompositePlan, itemIdx: int,
                        syms: seq[SymbolDef], pos: seq[Point],
                        padding: float): seq[Obstacle] =
  ## `itemIdx` is an arena index (`CompositePlan.items`), not a position in
  ## the flat composite-only list -- see `state.composites.ownerOf`.
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
  ## `unit` is the arena index (`CompositePlan.items`) of the owning
  ## composite -- unused by any current caller, kept for parity with the
  ## historical `(found, representative, unit, port)` shape.
  for idx in plan.topLevel:
    if plan.items[idx].raw >= 0: continue
    for p, port in plan.items[idx].ports:
      for covered in port.covered:
        if covered.partIdx == partIdx and covered.pinName == pinName:
          return (true, covered == port.representative, idx, p)

proc compositeExternalPins(pins: seq[RoutePin], plan: CompositePlan): seq[RoutePin] =
  ## External routing sees one endpoint per composite port.  Non-composite
  ## pins (including interface ports) remain in their original order.
  for pin in pins:
    if pin.pinName.len == 0:
      result.add pin
      continue
    let cp = compositePort(plan, pin.partIdx, pin.pinName)
    if not cp.found or cp.representative: result.add pin

# --- the registry -----------------------------------------------------------
# `parallelStackKind` is defined in `./passive`, included straight after this
# file. Forward-declaring it here is the whole cost of keeping the contract
# and its one implementation in separate files: `include` is a textual
# splice, so this is an ordinary forward declaration within one module, and
# the `let` initializer below runs in module-init code, after every proc body
# -- from either file -- has been emitted.
proc parallelStackKind(): CompositeKind
proc piKind(): CompositeKind
proc teeKind(): CompositeKind
proc seriesChainKind(): CompositeKind

let compositeKinds: seq[CompositeKind] =
  @[parallelStackKind(), piKind(), teeKind(), seriesChainKind()]
  ## Registration order is recognition precedence is output (Trap A). `let`,
  ## not `var`: nothing outside this included module can register a kind, and
  ## the order must never change silently at runtime. The parallel stack goes
  ## first so a shunt that is really a parallel bank stays a parallel stack and
  ## the pi/tee that would have claimed it is declined (`compositePlan`'s
  ## claim check). The series chain goes *last*: a parallel pair's shared nets
  ## carry four pins so they are never a chain's link net (the two kinds can
  ## never both claim a part), but a pi/tee series leg *can* also read as a
  ## chain link, and there the canonical filter-section drawing should win --
  ## `compositePlan`'s all-or-nothing claim check then drops the overlapping
  ## chain group. Trimming a partially-claimed group would change the fold for
  ## every kind and belongs with the §2.6 nesting work, not here.

proc compositePlan(comps: seq[Component], syms: seq[SymbolDef]): CompositePlan =
  ## Build the constrained placement arena before the first seed, by asking
  ## each registered `CompositeKind` in turn to partition `comps`, then
  ## delegating every accepted multi-member group's internal geometry and
  ## external ports to that kind's own hooks. External clearance belongs to
  ## the one unified footprint (filled in later by `positionedCompositePlan`),
  ## never between private members.
  ##
  ## Each `recognize` yields a *total* partition; `compositePlan` keeps only
  ## the multi-member groups, in registration order, dropping any whose
  ## members an earlier kind already claimed. The surviving groups plus the
  ## unclaimed singletons are then laid into `topLevel` in ascending
  ## first-raw-member order -- the order `parallelRecognize` alone used to
  ## yield and the order `constrainedRecomputeRotations` visits group by
  ## group, its per-group rotation search reading the partially updated result
  ## of earlier groups, so the visit order is observable, not cosmetic.
  result.items = newSeq[PlaceableItem](comps.len)
  for i in 0 ..< comps.len: result.items[i] = PlaceableItem(raw: i, kind: -1)
  result.ownerOf = newSeq[int](comps.len)
  result.poolOf = newSeq[int](comps.len)

  # Each registered kind is asked to recognize, in registration order (==
  # precedence). A kind's multi-member group is accepted only if none of its
  # members were already claimed by an earlier kind -- the non-nesting subset
  # of Stage 2.6's fold. It is enough for pi/tee, whose members are always raw
  # flat two-terminal singletons, never another kind's composite; a later kind
  # that genuinely needs to *consume* an earlier composite (the op-amp example
  # in `composite_placement_stage2.md` §2.6) still needs the arena-index fold
  # this does not do.
  var claimed = newSeq[bool](comps.len)
  var groups: seq[tuple[first, kind: int, members: seq[int]]]
  for kindIdx, kind in compositeKinds:
    for members in kind.recognize(comps, syms):
      if members.len < 2: continue
      var free = true
      var first = members[0]
      for m in members:
        if claimed[m]: free = false
        first = min(first, m)
      if not free: continue
      for m in members: claimed[m] = true
      groups.add (first: first, kind: kindIdx, members: members)

  # `topLevel` interleaves singletons and composites in ascending
  # first-raw-member order -- the order `parallelRecognize` alone used to
  # yield, and the order `constrainedRecomputeRotations` observes group by
  # group. Each group's first member is distinct (the groups are disjoint), so
  # a first-member -> group map drives one ascending pass.
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
  ## The same early plan, with its one external footprint materialised for the
  ## current centres, and each port's representative re-picked against it via
  ## the owning kind's `pickRepresentative` hook. Routing and legalization
  ## choose their own padding. Writes through the arena directly
  ## (`result.items[idx]`), not the `units()` compatibility view -- that view
  ## is read-only, rebuilt fresh on every call, so a write through it would
  ## not observably change `result`.
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
  ## Deterministic internal fanout, delegated to the owning kind's
  ## `internalRoute` hook (trunk-and-tap for `parallelStackKind`). Emitted
  ## after external routing: these are internal composite conductors, not
  ## additional external router endpoints or occupancy obstacles.
  for idx in plan.topLevel:
    if plan.items[idx].raw >= 0: continue
    let hook = compositeKinds[plan.items[idx].kind].internalRoute
    for port in plan.items[idx].ports:
      if port.net != netName: continue
      result.add hook(parts, port)
