## The composite arena: kind-agnostic scaffolding for schematic placement
## motifs, plus the registry that turns a plan of registered `CompositeKind`s
## into one `CompositePlan`. The concrete motifs themselves (today just the
## parallel stack) live in `./passive`, included straight after this file.
##
## Private, schema-preserving layout composites.  The scene still contains
## the original parts and pins; the arena below only makes their shared
## external terminals and reserved routing footprint explicit inside the
## pipeline. A composite type is a registered `CompositeKind` (defined
## further down, once its six hooks' return types exist) -- adding a motif
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
    offsets: seq[Point]     ## each child's centre relative to this item's origin
    ports: seq[CompositePort]
    footprint: seq[Obstacle]

  CompositeKind = object
    ## The whole contract a composite type implements: six pure hooks over
    ## the arrays `LayoutState` already threads, so a recognizer needs no
    ## access to placement/routing internals. Every field is `{.nimcall.}` --
    ## a plain function pointer, not a closure -- since `compositeKinds` is
    ## module-level state and registration order *is* recognition precedence
    ## *is* output (see `compositePlan`).
    name: string
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
      if pin.net.netlist != nl: return false
      inc connected
  connected == 2

proc rawMembers(plan: CompositePlan, item: int): seq[int] =
  ## Every raw component under arena entry `item`, depth-first. A single
  ## `@[it.raw]` at depth 1 (every child today is a leaf); the recursion is
  ## for a future kind whose children are themselves composites.
  let it = plan.items[item]
  if it.raw >= 0: return @[it.raw]
  for c in it.children: result.add rawMembers(plan, c)

proc rawOffsets(plan: CompositePlan, item: int): seq[Point] =
  ## Parallel to `rawMembers(plan, item)`: each raw member's centre relative
  ## to `item`'s own origin, composed down the tree. Identical to
  ## `items[item].offsets` at depth 1, since every child is then a leaf and
  ## contributes its own offset unchanged.
  let it = plan.items[item]
  if it.raw >= 0: return @[Point()]
  for ci, c in it.children:
    let base = it.offsets[ci]
    if plan.items[c].raw >= 0:
      result.add base
    else:
      for off in rawOffsets(plan, c): result.add base + off

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

let compositeKinds: seq[CompositeKind] = @[parallelStackKind()]
  ## Registration order is recognition precedence is output (Trap A). `let`,
  ## not `var`: nothing outside this included module can register a kind, and
  ## the order must never change silently at runtime.

proc compositePlan(comps: seq[Component], syms: seq[SymbolDef]): CompositePlan =
  ## Build the constrained placement arena before the first seed, by asking
  ## the one registered `CompositeKind` to partition `comps`, then delegating
  ## each multi-member group's internal geometry and external ports to that
  ## kind's own hooks. External clearance belongs to the one unified
  ## footprint (filled in later by `positionedCompositePlan`), never between
  ## private members.
  ##
  ## `recognize` yields the *total* partition -- singletons and multi-member
  ## groups interleaved in ascending first-member index -- and that
  ## interleave is preserved in `topLevel` verbatim: it is what
  ## `constrainedRecomputeRotations` visits group-by-group, and its per-group
  ## rotation search reads the partially updated result of earlier groups, so
  ## the visit order is observable, not cosmetic.
  result.items = newSeq[PlaceableItem](comps.len)
  for i in 0 ..< comps.len: result.items[i] = PlaceableItem(raw: i, kind: -1)
  result.ownerOf = newSeq[int](comps.len)
  result.poolOf = newSeq[int](comps.len)

  # A second registered kind needs recognition to fold over the pool
  # `topLevel` already leaves behind (so a later, more general kind may
  # consume an earlier kind's composite as one of its own members) --
  # deliberately not built until there is a second kind to prove it against
  # (Stage 2.6).
  doAssert compositeKinds.len == 1,
    "compositePlan: only a single registered CompositeKind is supported so far"
  let kind = compositeKinds[0]
  for members in kind.recognize(comps, syms):
    let poolPos = result.topLevel.len
    if members.len < 2:
      let i = members[0]
      result.topLevel.add i
      result.ownerOf[i] = i
      result.poolOf[i] = poolPos
      continue
    var item = PlaceableItem(raw: -1, kind: 0, children: members,
                             offsets: kind.internalLayout(comps, syms, members),
                             ports: kind.externalPins(comps, members))
    let idx = result.items.len
    result.items.add item
    result.topLevel.add idx
    for i in members:
      result.ownerOf[i] = idx
      result.poolOf[i] = poolPos

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
    var box: Obstacle
    var first = true
    for i in rawMembers(result, idx):
      let p = parts[i]
      let x1 = p.x - p.bodyW / 2.0 - padding
      let y1 = p.y - p.bodyH / 2.0 - padding
      let x2 = p.x + p.bodyW / 2.0 + padding
      let y2 = p.y + p.bodyH / 2.0 + padding
      if first:
        box = Obstacle(x1: x1, y1: y1, x2: x2, y2: y2)
        first = false
      else:
        box.x1 = min(box.x1, x1); box.y1 = min(box.y1, y1)
        box.x2 = max(box.x2, x2); box.y2 = max(box.y2, y2)
    result.items[idx].footprint = @[box]
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
