## Opt-in constrained layered placement for ordinary schematic sheets.
##
## This is deliberately bounded rather than a general graph-drawing solver: it
## derives a stable directed skeleton from output pins, follows two-terminal
## signal paths to their input endpoints, assigns monotonically increasing
## stage blocks, and orders each block from the deterministic seed. The existing
## separator remains the authority for non-overlap.
##
## The composite arena this file pools over -- `CompositeKind`, `PlaceableItem`,
## `CompositePlan`, the `compositeKinds` registry, and the registered motifs --
## lives under `./composites/` (`composite.nim` for the kind-agnostic
## scaffolding, `passive.nim` for the parallel-stack motif), included just
## before this file.

const
  constrainedMaxParts = 64
  # A raw sheet is admitted once its composite-collapsed *pool* clears
  # `constrainedMaxParts`, so the pool gate alone no longer bounds the raw
  # part count at all -- pooling looking favorable on paper must not admit an
  # unboundedly large raw sheet into an O(pool * arcs) topology relaxation
  # whose per-arc discovery (`pathsFrom`, the output-pin scan) is still
  # raw-sized, nor into `recoverRouting`'s per-candidate O(raw pins * raw
  # comps) `constrainedRouteScore`. 4x is slack above the pre-2.5 all-raw
  # ceiling (`constrainedMaxParts` itself, when every part was its own pool
  # item): four two-member parallel pairs collapse to one pool item, so a
  # sheet that is *all* parallel pairs can go up to 4x its former raw limit
  # and still be a 1x pool problem.
  constrainedMaxRawParts = 4 * constrainedMaxParts
  constrainedLayerPitch = 200.0
  # A semantic column can hold a fallback box as well as a two-terminal
  # symbol; leave enough vertical room that legalization need not spill it
  # into a neighbouring column.
  constrainedRowPitch = 240.0
  # A logical layer may use this many adjacent semantic stages. This keeps a
  # passive-heavy layer from becoming an unbounded vertical list while keeping
  # the topology hint deliberately local.
  constrainedMaxStages = 3

type
  TraversedPath = object
    parts: seq[int]
    inputs: seq[int]

  ConstrainedTopology = object
    layers: seq[int]
    sameColumn: seq[tuple[src, part: int]]

proc constrainedEligible(comps: seq[Component], plan: CompositePlan): bool =
  ## Pool count, not raw count, is what bounds the topology relaxation and the
  ## per-candidate route score after pool-indexing `constrainedTargets`. The
  ## raw ceiling is the guard the loosened pool gate needs: pooling looking
  ## favorable on paper must not admit an unboundedly large raw sheet into an
  ## O(pool * arcs) relaxation whose per-arc work is still raw-sized.
  comps.len > 0 and plan.topLevel.len <= constrainedMaxParts and
    comps.len <= constrainedMaxRawParts

proc inputPort(nl: Netlist, net: Net): bool =
  ## Keep port semantics exactly aligned with routing, including its
  ## all-passive/no-driver fallback.
  for _, portNet in nl.ports:
    if portNet == net:
      return portDirection(net) == pdInput
  false

proc pathsFrom(nl: Netlist, start: Net, skip: int,
               idxOf: Table[string, int], plan: CompositePlan): seq[TraversedPath] =
  ## Follow a signal net through eligible two-terminal devices. A traversal
  ## step is `(pool item, exit net)`, not just `(pool item)`: a composite is
  ## one *placement unit* but its members are still distinct edges in the
  ## signal graph, and a step key that stopped at the pool item let a walk
  ## enter a composite and never leave -- a pi's grounded shunt would consume
  ## the pool position and its series member could never be traversed, so no
  ## arc ordering the composite against the rest of the sheet was ever
  ## discovered (`RIAA_CHANNEL`'s `RL`--`CIN`--`RB` pi landing right of the
  ## op-amp it feeds).
  ##
  ## `visitedHere` keyed on `(poolOf[i], exit net)` still collapses the 2^N
  ## blow-up the pooling was for: both members of a recognized parallel pair
  ## share *both* their nets, so from either net they yield the identical
  ## `(pool, exit)` step and dedup to one -- while a pi's shunt
  ## (`exit == ground`) and its series part (`exit == signal`), and a tee's
  ## two series legs, stay distinct. `seen`/`skip` are raw component indices:
  ## one raw part per path bounds path length by `comps.len` exactly, and it
  ## is not what was collapsing paths. `TraversedPath` carries raw indices --
  ## `constrainedTopology` maps every arc through `plan.poolOf` once, for
  ## every arc kind at once.
  var found: seq[TraversedPath]
  proc walk(net: Net, path: seq[int], seen: HashSet[int]) =
    if net == nil or not onThisSheet(nl, net) or isGround(net) or isRail(net):
      return
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
    var visitedHere: HashSet[tuple[pool: int; exit: string]]
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
      let step = (pool: plan.poolOf[i], exit: other.name)
      if step in visitedHere: continue
      visitedHere.incl step
      var nextSeen = seen
      nextSeen.incl i
      var nextPath = path
      nextPath.add i
      walk(other, nextPath, nextSeen)
  walk(start, @[], initHashSet[int]())
  result = found

proc constrainedTopology(comps: seq[Component], idxOf: Table[string, int],
                         plan: CompositePlan): ConstrainedTopology =
  ## Longest-path relaxation on semantic output arcs, run over the
  ## composite-collapsed *pool* -- `layers` and `sameColumn` are indexed by
  ## pool position (0 ..< `plan.topLevel.len`), not raw component index, so a
  ## composite shares one layer by construction instead of the post-hoc `max`
  ## `constrainedTargets` used before pooling existed. Insertion order breaks
  ## ordinary reverse arcs. A path returning to its own source stays in the
  ## source layer and may use an adjacent stage; a path returning to an earlier
  ## component is feedback, whose passive path remains to the right of the
  ## output that drives it.
  ##
  ## Arc *discovery* below still walks raw indices -- `pathsFrom` and the
  ## direct output-pin scan need real pins and real nets -- and only the
  ## discovered arcs are mapped through `plan.poolOf` afterward, once, for
  ## every arc kind (ordinary, feedback, same-column) alike. Contracting a DAG
  ## can reintroduce a cycle (two raw arcs between different members of the
  ## same two composites can point opposite ways once both ends collapse to
  ## one pool position each), so the pool-level `src < dst` check is the same
  ## deterministic cycle break one level up, not a restatement of the raw one.
  let poolLen = plan.topLevel.len
  result.layers = newSeq[int](poolLen)
  var rawArcs: seq[tuple[src, dst: int]]
  var feedback: seq[tuple[src, part: int]]
  var sameColumnRaw: seq[tuple[src, part: int]]

  proc addPathArcs(src: int, path: seq[int], dst: int) =
    var previous = src
    for part in path:
      if previous < part: rawArcs.add (previous, part)
      previous = part
    if previous < dst: rawArcs.add (previous, dst)

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
        if i < dst: rawArcs.add (i, dst)
      for path in pathsFrom(c.netlist, pin.net, i, idxOf, plan):
        for dst in path.inputs:
          if dst == i:
            for part in path.parts: sameColumnRaw.add (i, part)
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
    for path in pathsFrom(comps[0].netlist, net, -1, idxOf, plan):
      for dst in path.inputs:
        if path.parts.len > 0:
          var previous = path.parts[0]
          for at in 1 ..< path.parts.len:
            if previous < path.parts[at]: rawArcs.add (previous, path.parts[at])
            previous = path.parts[at]
          if previous < dst: rawArcs.add (previous, dst)

  # Map every arc through `poolOf`; a HashSet used for membership only (never
  # iterated, per this submodule's determinism rule) dedups arcs that two
  # different raw pairs contracted onto, keeping first-seen order in `arcs`.
  var arcs: seq[tuple[src, dst: int]]
  var arcSeen: HashSet[tuple[src, dst: int]]
  for a in rawArcs:
    let src = plan.poolOf[a.src]
    let dst = plan.poolOf[a.dst]
    if src >= dst: continue
    if (src, dst) in arcSeen: continue
    arcSeen.incl (src, dst)
    arcs.add (src, dst)

  # The insertion-order cycle break makes these arcs a DAG, so poolLen-1
  # longest-path passes are a strict bound.
  for _ in 1 ..< poolLen:
    var next = result.layers
    for a in arcs:
      if result.layers[a.src] + 1 > next[a.dst]:
        next[a.dst] = result.layers[a.src] + 1
    if next == result.layers: break
    result.layers = next

  for f in feedback:
    let src = plan.poolOf[f.src]
    let part = plan.poolOf[f.part]
    if src == part: continue # both ends already share a layer by construction
    result.layers[part] = max(result.layers[part], result.layers[src] + 1)
  for s in sameColumnRaw:
    let src = plan.poolOf[s.src]
    let part = plan.poolOf[s.part]
    if src == part: continue
    result.layers[part] = result.layers[src]
    result.sameColumn.add (src, part)

proc constrainedTargets(comps: seq[Component], pos: seq[Point],
                        idxOf: Table[string, int],
                        plan: CompositePlan): seq[Point] =
  ## Stable, bounded stage placement over the composite-collapsed pool. A pool
  ## item -- a raw singleton or a whole recognized composite -- is one
  ## placement unit; units fill at most three adjacent stages before adding
  ## another row. The incoming seed resolves all ties, preserving
  ## deterministic ordering.
  ##
  ## A composite is placed as one packed body: its origin goes at the stage
  ## slot and each member sits at `origin + rawOffsets(plan, idx)[at]` --
  ## the same canonical raw-body-touching offsets `restoreCompositeOffsets`
  ## re-rigidifies around afterward. Before pooling this stacked members
  ## `constrainedParallelPitch` (120) apart here and let the later
  ## re-rigidify pass collapse that to the real 80-unit body-touching gap
  ## around the mean of the *implied* origins -- two correct but different
  ## numbers computed in sequence. Placing the canonical offsets directly
  ## is the same final geometry by one step instead of two, and it is why a
  ## composite-bearing sheet's semantic seed (and therefore the force
  ## placement it feeds) moves under this change even though every downstream
  ## invariant (`restoreCompositeOffsets`'s own idempotent offsets, the shared
  ## column, the routing rules) is unaffected: a different starting point for
  ## the same iterative force solve settles at a different, still-valid,
  ## equilibrium. A composite-free sheet has every offset at `Point()`, so
  ## this reduces to the pre-pooling stacking exactly, one unit apart -- the
  ## identity case that is provably unchanged.
  if not constrainedEligible(comps, plan): return pos
  var topology = constrainedTopology(comps, idxOf, plan)
  let poolLen = plan.topLevel.len
  # A local return is allowed one semantic stage either side of its source;
  # reserve a second stage even for the minimal source-plus-feedback case.
  var localReturn = newSeq[bool](poolLen)
  var returnSource = newSeq[int](poolLen)
  for g in 0 ..< returnSource.len: returnSource[g] = -1
  for s in topology.sameColumn:
    localReturn[topology.layers[s.src]] = true
    returnSource[s.part] = s.src

  result = newSeq[Point](comps.len)
  var xStage = 0
  var minY = 0.0
  var maxY = 0.0
  for layer in 0 ..< poolLen:
    var units: seq[int]
    for g in 0 ..< poolLen:
      if topology.layers[g] == layer: units.add g
    if units.len == 0: continue
    units.sort(proc(a, b: int): int =
      let membersA = rawMembers(plan, plan.topLevel[a])
      let membersB = rawMembers(plan, plan.topLevel[b])
      let ay = min(pos[membersA[0]].y, pos[membersA[^1]].y)
      let by = min(pos[membersB[0]].y, pos[membersB[^1]].y)
      result = cmp(ay, by)
      if result == 0: result = cmp(membersA[0], membersB[0]))
    var stages = min(constrainedMaxStages, (units.len + 2) div 3)
    if localReturn[layer]: stages = max(stages, min(2, constrainedMaxStages))
    # For the minimal local loop, put the return beside its source. The
    # deterministic seed chooses which side, so this is not output-side-only.
    if units.len >= 2 and units.len <= stages:
      for returnGroup, sourceGroup in returnSource:
        if sourceGroup < 0 or topology.layers[returnGroup] != layer: continue
        var returnAt = -1
        var sourceAt = -1
        for at, g in units:
          if g == returnGroup: returnAt = at
          if g == sourceGroup: sourceAt = at
        if returnAt < 0 or sourceAt < 0: continue
        let returnFirst = rawMembers(plan, plan.topLevel[returnGroup])[0]
        let sourceFirst = rawMembers(plan, plan.topLevel[sourceGroup])[0]
        let returnLeft = pos[returnFirst].x <= pos[sourceFirst].x
        let desiredReturn = if returnLeft: 0 else: 1
        let desiredSource = 1 - desiredReturn
        swap(units[returnAt], units[desiredReturn])
        if sourceAt == desiredReturn: sourceAt = returnAt
        swap(units[sourceAt], units[desiredSource])
    for slot, g in units:
      let stage = slot mod stages
      let row = slot div stages
      let idx = plan.topLevel[g]
      let members = rawMembers(plan, idx)
      let offsets = rawOffsets(plan, idx)
      let origin = Point(x: float(xStage + stage) * constrainedLayerPitch,
                         y: float(row) * constrainedRowPitch)
      for at, i in members:
        result[i] = origin + offsets[at]
        minY = min(minY, result[i].y)
        maxY = max(maxY, result[i].y)
    xStage += stages
  # Centre the sheet about the origin, retaining exact grid coordinates.
  # `minY` matters once member offsets are signed (a composite's members sit
  # on both sides of its origin); for an all-singleton sheet every offset is
  # zero, so `minY` is exactly 0 and this is the historical `maxY / 2` shift.
  let xShift = float(xStage - 1) * constrainedLayerPitch / 2.0
  let yShift = (minY + maxY) / 2.0
  for p in mitems(result):
    p.x -= xShift
    p.y -= yShift

proc constrainedSemanticSeed(comps: seq[Component], pos: var seq[Point],
                             idxOf: Table[string, int], plan: CompositePlan) =
  if constrainedEligible(comps, plan):
    pos = constrainedTargets(comps, pos, idxOf, plan)

proc constrainedAnchors(comps: seq[Component], seed: seq[Point],
                        idxOf: Table[string, int],
                        plan: CompositePlan): seq[Point] =
  ## Semantic columns are deliberately *soft* anchors.  The constrained policy
  ## must retain the topology hint without overwriting the force solution (and
  ## without turning a feedback sheet into a rigid template).
  if constrainedEligible(comps, plan):
    constrainedTargets(comps, seed, idxOf, plan)
  else:
    seed

proc constrainedRefine(comps: seq[Component], pos: var seq[Point],
                       idxOf: Table[string, int]) =
  ## Kept as the stage hook for archive compatibility.  Refinement is now done
  ## by the bounded soft-anchor force and group search, never by a hard snap.
  discard

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

proc constrainedRecomputeRotations(nl: Netlist, comps: seq[Component],
                                   syms: seq[SymbolDef], pos: seq[Point], rots: seq[float],
                                   anchors: seq[Point],
                                   plan: CompositePlan): seq[float] =
  ## Deterministic group-aware four-way search.  Its ordering is deliberately
  ## lexicographic: existing power direction, estimated routing quality, then
  ## semantic/seed drift.  Parallel members are evaluated as one candidate.
  ##
  ## Visits `plan.topLevel` -- the exact interleave of singletons and
  ## composites `parallelRecognize` produced when `plan` was built -- rather
  ## than recomputing groups here: a singleton's rotation search reads
  ## `pinWorldPositions` off the *partially updated* `result` of every group
  ## already visited, so the order is observable, not cosmetic, and a second
  ## registered kind's own recognition must land in that same one sequence.
  result = rots
  for idx in plan.topLevel:
    let it = plan.items[idx]
    if it.raw >= 0:
      let i = it.raw
      let pw = pinWorldPositions(comps, syms, pos, result)
      result[i] = bestRotation(syms[i], comps[i], pos[i], result[i], pw, 0.0)
      continue
    let members = rawMembers(plan, idx)
    let candidates =
      compositeKinds[it.kind].rotationCandidates(nl, comps, syms, pos, result, members)
    var best = result
    var bestRank: array[4, int]
    var bestScore: tuple[hits, bends: int, length, drift: float]
    var first = true
    for cand in candidates:
      var rank: array[4, int]
      for i in members:
        let r = powerRank(syms[i], comps[i], cand[i])
        for k in 0 ..< rank.len: rank[k] += r[k]
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
