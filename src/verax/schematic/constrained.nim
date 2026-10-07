## Opt-in constrained layered placement. Deliberately bounded: derive a
## directed skeleton from output pins, follow two-terminal signal paths to
## input endpoints, assign increasing stage blocks, order each block from the
## deterministic seed. The separator remains the authority for non-overlap.
## The composite arena lives under `./composites/`, included just before.

const
  constrainedMaxParts = 64
  # The pool gate alone doesn't bound raw part count, but arc discovery and
  # `constrainedRouteScore` are still raw-sized. 4x lets a sheet of all
  # two-member parallel pairs through.
  constrainedMaxRawParts = 4 * constrainedMaxParts
  constrainedLayerPitch = 200.0
  # Room for a fallback box, so legalization doesn't spill into a
  # neighbouring column.
  constrainedRowPitch = 240.0
  # Stages a logical layer may span, keeping passive-heavy layers bounded.
  constrainedMaxStages = 3
  # `lsCompositeOrient` turns a signal-path composite off its canonical frame
  # only when it shortens external wirelength by more than this: the
  # estimate is pre-separation and a marginal turn can break a route. Pure
  # rail-to-rail units are exempt.
  compositeFrameHysteresis = 2.0 * grid

type
  TraversedPath = object
    parts: seq[int]
    inputs: seq[int]

  ConstrainedTopology = object
    layers: seq[int]
    sameColumn: seq[tuple[src, part: int]]

proc constrainedEligible(comps: seq[Component], plan: CompositePlan): bool =
  ## Pool count bounds the relaxation and route score; the raw ceiling
  ## guards the still raw-sized per-arc work.
  comps.len > 0 and plan.topLevel.len <= constrainedMaxParts and
    comps.len <= constrainedMaxRawParts

proc inputPort(nl: Netlist, net: Net): bool =
  ## Port semantics exactly as routing sees them, including the no-driver
  ## fallback.
  for _, portNet in nl.ports:
    if portNet == net:
      return portDirection(net) == pdInput
  false

proc pathsFrom(nl: Netlist, start: Net, skip: int,
               idxOf: Table[string, int], plan: CompositePlan): seq[TraversedPath] =
  ## Follow a signal net through eligible two-terminal devices. A step is
  ## `(pool item, exit net)`: keyed on the pool item alone, a walk could
  ## enter a composite (e.g. a pi's shunt) and never traverse its series
  ## member. Parallel-pair members share both nets, so they still dedup to
  ## one step; a pi's shunt and series part stay distinct. `seen`/`skip` are
  ## raw indices; arcs are mapped through `plan.poolOf` by
  ## `constrainedTopology`.
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
      # An input is an endpoint; continuing would fake a self-return.
      return
    var visitedHere: HashSet[tuple[pool: int; exit: string]]
    for pin in net.pins:
      let c = pin.component
      if not isTraversable(c, nl) or not idxOf.hasKey(c.designator): continue
      let i = idxOf[c.designator]
      if i == skip or i in seen: continue
      # One exit for a two-terminal part; several for a declared multi-throw
      # switch (one per pin its `traverse:` spec says conducts).
      for other in traversalExits(c, nl, net):
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
                         plan: CompositePlan, arrays: ArrayPlan,
                         ov = LayoutOverridePlan()): ConstrainedTopology =
  ## Longest-path relaxation on semantic output arcs over the composite pool
  ## (`layers`/`sameColumn` are pool-indexed, so a composite shares one
  ## layer). Insertion order breaks reverse arcs. A path back to its own
  ## source stays in the source layer; one back to an earlier component is
  ## feedback, kept right of the output that drives it.
  ##
  ## Arcs are discovered on raw indices, then mapped through `poolOf`.
  ## Contraction can create a cycle, so `src < dst` is re-checked at pool
  ## level.
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
      # Keep direct output-pin arcs too: a final sink belongs after the
      # output driving its net.
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
            # Feedback direction: don't pull it left toward the input.
            for part in path.parts: feedback.add (i, part)

  # A chain's tail output sits on a hidden array member, invisible to the
  # scan above; `arrays.extraPins` re-homes it onto the representative.
  # Instance pins are `ptUnknown`, so `outward` identifies the tail; the head
  # entry is skipped (the representative already owns it).
  let nl = comps[0].netlist
  for netName, homes in arrays.extraPins:
    if not nl.nets.hasKey(netName): continue
    let net = nl.nets[netName]
    for home in homes:
      if not home.outward or not idxOf.hasKey(home.desig): continue
      let i = idxOf[home.desig]
      for mate in net.pins:
        if mate.component == nil or mate.component.netlist != nl or
           mate.component.designator == home.desig or
           not idxOf.hasKey(mate.component.designator): continue
        let dst = idxOf[mate.component.designator]
        if i < dst: rawArcs.add (i, dst)
      for path in pathsFrom(nl, net, i, idxOf, plan):
        for dst in path.inputs:
          if dst == i:
            for part in path.parts: sameColumnRaw.add (i, part)
          elif i < dst:
            addPathArcs(i, path.parts, dst)
          else:
            for part in path.parts: feedback.add (i, part)

  # An input interface is a virtual layer-zero source, per `portDirection`.
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

  # Map arcs through `poolOf`, deduping via a membership-only HashSet.
  var arcs: seq[tuple[src, dst: int]]
  var arcSeen: HashSet[tuple[src, dst: int]]
  for a in rawArcs:
    let src = plan.poolOf[a.src]
    let dst = plan.poolOf[a.dst]
    if src >= dst: continue
    if (src, dst) in arcSeen: continue
    arcSeen.incl (src, dst)
    arcs.add (src, dst)

  # The arcs form a DAG, so poolLen-1 passes suffice.
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

  # `layout.side` is only a seed hint here (`enforceLayoutSides` is the
  # guarantee): pull left units to layer 0 and right units past all others,
  # then renumber densely so the `0 ..< poolLen` loop visits every unit.
  if ov.any:
    var leftUnits, rightUnits: seq[int]
    for pos in 0 ..< poolLen:
      case poolSide(plan, ov, plan.topLevel[pos])
      of sideLeft: leftUnits.add pos
      of sideRight: rightUnits.add pos
      of sideAuto: discard
    if leftUnits.len > 0 or rightUnits.len > 0:
      let leftSet = leftUnits.toHashSet()
      let rightSet = rightUnits.toHashSet()
      if leftUnits.len > 0:
        for pos in 0 ..< poolLen:
          if pos notin leftSet: result.layers[pos] = result.layers[pos] + 1
        for pos in leftUnits: result.layers[pos] = 0
      if rightUnits.len > 0:
        var maxOther = 0
        for pos in 0 ..< poolLen:
          if pos notin rightSet: maxOther = max(maxOther, result.layers[pos])
        for pos in rightUnits: result.layers[pos] = maxOther + 1
      var distinctLayers: seq[int]
      for pos in 0 ..< poolLen:
        if result.layers[pos] notin distinctLayers:
          distinctLayers.add result.layers[pos]
      distinctLayers.sort()
      var remap = initTable[int, int]()
      for at, v in distinctLayers: remap[v] = at
      for pos in 0 ..< poolLen: result.layers[pos] = remap[result.layers[pos]]

proc constrainedTargets(comps: seq[Component], pos: seq[Point],
                        idxOf: Table[string, int],
                        plan: CompositePlan, arrays: ArrayPlan,
                        ov = LayoutOverridePlan()): seq[Point] =
  ## Stable, bounded stage placement over the pool: each pool item is one
  ## unit, at most three adjacent stages per row, ties resolved by the seed.
  ## A composite's members are placed at `origin + rawOffsets(...)`, its
  ## canonical rigid offsets. A composite-free sheet has zero offsets.
  if not constrainedEligible(comps, plan): return pos
  var topology = constrainedTopology(comps, idxOf, plan, arrays, ov)
  let poolLen = plan.topLevel.len
  # A local return may use one stage either side of its source; reserve a
  # second stage even for the minimal case.
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
    # Minimal local loop: return beside its source; the seed picks the side.
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
  # Centre the sheet about the origin on exact grid coordinates (`minY`
  # handles signed composite offsets).
  let xShift = float(xStage - 1) * constrainedLayerPitch / 2.0
  let yShift = (minY + maxY) / 2.0
  for p in mitems(result):
    p.x -= xShift
    p.y -= yShift

proc constrainedSemanticSeed(comps: seq[Component], pos: var seq[Point],
                             idxOf: Table[string, int], plan: CompositePlan,
                             arrays: ArrayPlan, ov = LayoutOverridePlan()) =
  if constrainedEligible(comps, plan):
    pos = constrainedTargets(comps, pos, idxOf, plan, arrays, ov)

proc constrainedAnchors(comps: seq[Component], seed: seq[Point],
                        idxOf: Table[string, int],
                        plan: CompositePlan, arrays: ArrayPlan,
                        ov = LayoutOverridePlan()): seq[Point] =
  ## Semantic columns are soft anchors: they guide the force solution without
  ## overwriting it.
  if constrainedEligible(comps, plan):
    constrainedTargets(comps, seed, idxOf, plan, arrays, ov)
  else:
    seed

proc constrainedRefine(comps: seq[Component], pos: var seq[Point],
                       idxOf: Table[string, int]) =
  ## Kept as a stage hook for archive compatibility; refinement is done by
  ## the soft-anchor force and group search.
  discard

proc portTarget(nl: Netlist, comps: seq[Component], net: Net, pos: seq[Point], syms: seq[SymbolDef]):
    tuple[has: bool, p: Point] =
  ## A declared interface participates before ports are materialised, as
  ## candidate geometry: it breaks the symmetry of an all-passive sheet.
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
  ## Cheap obstacle-aware rectilinear estimate, only for ranking candidate
  ## orientations; the router remains the authority.
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
      # Both L shapes are checked; a hit on both means no clean candidate.
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
  ## Deterministic group-aware four-way search, ranked by power direction,
  ## estimated routing quality, then drift. Visits `plan.topLevel` in order;
  ## that order is observable because each search reads the partially
  ## updated `result`.
  result = rots
  for idx in plan.topLevel:
    let it = plan.items[idx]
    if it.raw >= 0:
      let i = it.raw
      let pw = pinWorldPositions(comps, syms, pos, result)
      result[i] = bestRotation(syms[i], comps[i], pos[i], result[i], pw, 0.0)
      continue
    let members = rawMembers(plan, idx)
    var candidates =
      compositeKinds[it.kind].rotationCandidates(nl, comps, syms, pos, result, members)
    # Compose the unit's committed quarter-turn onto every member's angle
    # (`unitRot` is 0 for pinned kinds).
    if it.unitRot != 0.0:
      for c in mitems(candidates):
        for i in members: c[i] = addRot(c[i], it.unitRot)
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

proc compositeUnitOrigin(plan: CompositePlan, idx: int, pos: seq[Point],
                         canon: seq[Point], members: seq[int]): Point =
  ## The grid-snapped origin a rigid composite's members sit around (as in
  ## `restoreCompositeOffsets`), so a trial frame can be scored without
  ## committing it.
  let rot = plan.items[idx].unitRot
  for at, m in members: result += pos[m] - rotatedSlot(canon[at], rot)
  result = result * (1.0 / float(members.len))
  result.x = round(result.x / grid) * grid
  result.y = round(result.y / grid) * grid

proc unitExternallyPurePower(comps: seq[Component], members: seq[int]): bool =
  ## Every external net is a rail or ground (a rail-to-rail divider, a
  ## decoupling bank), so `powerRank` should lead its frame choice. Any
  ## signal net leads via wirelength instead.
  var inUnit: HashSet[string]
  for m in members: inUnit.incl comps[m].designator
  let nl = comps[members[0]].netlist
  for m in members:
    for _, pin in comps[m].pins:
      let net = pin.net
      if net == nil or isGround(net) or isRail(net): continue
      for other in net.pins:
        if other.component != nil and other.component.netlist == nl and
           other.component.designator notin inUnit:
          return false
  true

proc chooseCompositeOrientation(nl: Netlist, comps: seq[Component],
                                syms: seq[SymbolDef], pos: var seq[Point],
                                rots: seq[float], plan: var CompositePlan) =
  ## `lsCompositeOrient`: pick each orientable composite's quarter-turn
  ## before separation. A pure-power unit ranks by `powerRank`, then
  ## `rotationScore`, then smaller angle; a unit with an external signal net
  ## ranks by `rotationScore` alone, so it turns only to shorten a real
  ## connection. Rigid turns leave internal distances unchanged, so a
  ## self-contained unit keeps angle 0. Snapshot-read, so visit order doesn't
  ## matter. Skipped when `constrainedEligible` declined the sheet.
  if not constrainedEligible(comps, plan): return
  var hasOrientable = false
  for idx in plan.topLevel:
    let it = plan.items[idx]
    if it.raw < 0 and compositeKinds[it.kind].orientable: hasOrientable = true
  if not hasOrientable: return

  var chosen = newSeq[float](plan.items.len)          # 0 for every non-target
  for idx in plan.topLevel:
    let it = plan.items[idx]
    if it.raw >= 0 or not compositeKinds[it.kind].orientable: continue
    let members = rawMembers(plan, idx)
    let canon = canonicalOffsets(plan, idx)
    let origin = compositeUnitOrigin(plan, idx, pos, canon, members)
    let cands = compositeKinds[it.kind].rotationCandidates(
      nl, comps, syms, pos, rots, members)
    if cands.len == 0: continue
    let usePower = unitExternallyPurePower(comps, members)
    var bestTheta = 0.0
    var bestRank: array[4, int]
    var bestScore = Inf
    var score0 = Inf                    # the canonical frame's own score
    var first = true
    for theta in rotationChoices:
      # Best canonical candidate (a parallel stack offers 0/180) at this
      # frame.
      var thRank: array[4, int]
      var thScore = Inf
      var thFirst = true
      for cand in cands:
        var tPos = pos
        var tRots = rots
        for at, m in members:
          tPos[m] = origin + rotatedSlot(canon[at], theta)
          tRots[m] = addRot(cand[m], theta)
        let tpw = pinWorldPositions(comps, syms, tPos, tRots)
        var rank: array[4, int]
        var score = 0.0
        for at, m in members:
          if usePower:
            let r = powerRank(syms[m], comps[m], tRots[m])
            for k in 0 ..< 4: rank[k] += r[k]
          score += rotationScore(syms[m], comps[m], tPos[m], tRots[m], tpw)
        if thFirst or rankLess(rank, thRank) or
           (rankEqual(rank, thRank) and score < thScore - 1e-9):
          thFirst = false; thRank = rank; thScore = score
      if theta == 0.0: score0 = thScore
      if first or rankLess(thRank, bestRank) or
         (rankEqual(thRank, bestRank) and thScore < bestScore - 1e-9):
        first = false; bestRank = thRank; bestScore = thScore; bestTheta = theta
    # Signal-path units turn only for a clear wirelength win.
    if not usePower and bestTheta != 0.0 and bestScore > score0 - compositeFrameHysteresis:
      bestTheta = 0.0
    chosen[idx] = bestTheta

  var changed = false
  for idx in plan.topLevel:
    if plan.items[idx].raw < 0 and chosen[idx] != plan.items[idx].unitRot:
      plan.items[idx].unitRot = chosen[idx]
      changed = true
  # Re-rigidify only if a frame moved; it recentres on the grid.
  if changed: restoreCompositeOffsets(plan, pos)

proc frameRouteScore(nl: Netlist, comps: seq[Component], syms: seq[SymbolDef],
                     pos: seq[Point], rots: seq[float], anchors: seq[Point],
                     plan: CompositePlan, idx: int, members: seq[int],
                     canon: seq[Point], origin: Point,
                     theta: float): tuple[hits, bends: int, length, drift: float] =
  ## Score composite `idx` in frame `theta`: turn only its members and hand
  ## the sheet to `constrainedRouteScore`.
  var trialPos = pos
  var trialRots = rots
  let cands = compositeKinds[plan.items[idx].kind].rotationCandidates(
    nl, comps, syms, pos, rots, members)
  var best = if cands.len > 0: cands[0] else: rots
  if cands.len > 1:
    var bestRank: array[4, int]
    var firstC = true
    for cand in cands:
      var rank: array[4, int]
      for m in members:
        let pr = powerRank(syms[m], comps[m], addRot(cand[m], theta))
        for k in 0 ..< 4: rank[k] += pr[k]
      if firstC or rankLess(rank, bestRank):
        firstC = false; bestRank = rank; best = cand
  for at, m in members:
    trialPos[m] = origin + rotatedSlot(canon[at], theta)
    trialRots[m] = addRot(best[m], theta)
  constrainedRouteScore(nl, comps, syms, trialPos, trialRots, anchors)

proc revisitCompositeFrames(nl: Netlist, comps: seq[Component],
                            syms: seq[SymbolDef], pos: var seq[Point],
                            rots: seq[float], anchors: seq[Point],
                            plan: var CompositePlan) =
  ## The definitive-pass counterpart of `chooseCompositeOrientation`: with
  ## centres settled, retry all four frames per composite, scored by
  ## `constrainedRouteScore` (hits, bends, length; no drift). A frame whose
  ## turned member would overlap a foreign raw body is rejected. Sequential
  ## in `topLevel` order; skipped when `constrainedEligible` declined.
  if not constrainedEligible(comps, plan): return
  var hasOrientable = false
  for idx in plan.topLevel:
    let it = plan.items[idx]
    if it.raw < 0 and compositeKinds[it.kind].orientable: hasOrientable = true
  if not hasOrientable: return

  var half = newSeq[Point](comps.len)
  for i in 0 ..< comps.len:
    half[i] = Point(x: syms[i].bodyW / 2.0, y: syms[i].bodyH / 2.0)

  for idx in plan.topLevel:
    let it = plan.items[idx]
    if it.raw >= 0 or not compositeKinds[it.kind].orientable: continue
    let members = rawMembers(plan, idx)
    let canon = canonicalOffsets(plan, idx)
    let origin = compositeUnitOrigin(plan, idx, pos, canon, members)
    let current = it.unitRot
    var inUnit = newSeq[bool](comps.len)
    for m in members: inUnit[m] = true

    # Incumbent frame first: it is already legalized, so it always scores.
    var bestScore = frameRouteScore(nl, comps, syms, pos, rots, anchors, plan,
                                    idx, members, canon, origin, current)
    var bestTheta = current
    for theta in rotationChoices:
      if theta == current: continue
      var overlap = false
      for at, m in members:
        let c = origin + rotatedSlot(canon[at], theta)
        for j in 0 ..< comps.len:
          if inUnit[j]: continue
          if abs(c.x - pos[j].x) < half[m].x + half[j].x - 1e-9 and
             abs(c.y - pos[j].y) < half[m].y + half[j].y - 1e-9:
            overlap = true
      if overlap: continue
      let sc = frameRouteScore(nl, comps, syms, pos, rots, anchors, plan,
                               idx, members, canon, origin, theta)
      # Fewer hits or bends wins outright; a shorter length alone must clear
      # the hysteresis.
      var better = false
      if sc.hits != bestScore.hits: better = sc.hits < bestScore.hits
      elif sc.bends != bestScore.bends: better = sc.bends < bestScore.bends
      else: better = sc.length < bestScore.length - compositeFrameHysteresis
      if better: bestScore = sc; bestTheta = theta

    # Only disturb geometry when the frame changed.
    if bestTheta != current:
      plan.items[idx].unitRot = bestTheta
      for at, m in members: pos[m] = origin + rotatedSlot(canon[at], bestTheta)
