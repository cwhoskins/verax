# Post-route refinement passes. Included by `layout.nim` after `./finish`, so
# every layout type, geometry constant and `routeScene` overload is in scope.

# --- routed-scene scoring ------------------------------------------------------

proc wireBends(poly: seq[Point]): int =
  ## Direction changes along a rectilinear polyline. Collinear interior points
  ## and zero-length segments do not count -- only a real corner does. This is
  ## the library form of `tests/test_schematic.nim`'s `visualBends`, hardened
  ## against the redundant collinear vertices the router sometimes emits.
  var prevDir = -1                       ## 0 horizontal, 1 vertical, -1 none
  for k in 1 ..< poly.len:
    let a = poly[k - 1]
    let b = poly[k]
    let horiz = abs(a.y - b.y) < 1e-9
    let vert = abs(a.x - b.x) < 1e-9
    let dir =
      if horiz and vert: -1              ## zero length
      elif horiz: 0
      else: 1
    if dir < 0: continue
    if prevDir >= 0 and dir != prevDir: inc result
    prevDir = dir

proc wireLength(poly: seq[Point]): float =
  ## Total rectilinear length of a polyline.
  for k in 1 ..< poly.len:
    result += abs(poly[k].x - poly[k - 1].x) + abs(poly[k].y - poly[k - 1].y)

proc sceneScore(rs: RoutingState): tuple[fallbacks, bends: int, length: float] =
  ## Lexicographic route-quality reading of a routed scene: how many nets fell
  ## back, then total corners, then total wire length. `wkChain` recirculation
  ## arcs are fixed annotation polylines, not routed connectivity, so they are
  ## excluded.
  result.fallbacks = rs.fallbacks.len
  for w in rs.wires:
    if w.kind == wkChain: continue
    result.bends += wireBends(w.points)
    result.length += wireLength(w.points)

proc betterThan(a, b: tuple[fallbacks, bends: int, length: float]): bool =
  ## Strict lexicographic improvement: fewer fallbacks, then fewer bends, then
  ## shorter. Length ties inside 1e-6 are not an improvement.
  if a.fallbacks != b.fallbacks: return a.fallbacks < b.fallbacks
  if a.bends != b.bends: return a.bends < b.bends
  b.length - a.length > 1e-6

# --- post-route port placement -----------------------------------------------

proc portTargets(rs: RoutingState): OrderedTable[string, seq[float]] =
  ## For every net that carries an interface port, the y coordinates its routed
  ## wire spends the most horizontal length on -- the tracks tension would pull
  ## the ports onto -- best first, at most `portRefineCandidates` of them, and
  ## never a y a port on that net already sits at. Keyed and ordered by net tag
  ## in `rs.ports` order so the caller is deterministic.
  var portYs = initTable[string, seq[float]]()
  var order: seq[string]
  for p in rs.ports:
    if p.net notin portYs:
      portYs[p.net] = @[]
      order.add p.net
    portYs[p.net].add p.y

  for net in order:
    var runs = initOrderedTable[float, float]()   ## y -> summed |dx|
    for w in rs.wires:
      if w.net != net or w.kind == wkChain: continue
      for k in 1 ..< w.points.len:
        let a = w.points[k - 1]
        let b = w.points[k]
        if abs(a.y - b.y) < 1e-9 and abs(a.x - b.x) > 1e-9:
          runs[a.y] = runs.getOrDefault(a.y) + abs(b.x - a.x)

    var cands: seq[tuple[y, run: float]]
    for y, run in runs:
      var atPort = false
      for py in portYs[net]:
        if abs(py - y) < grid / 2.0: atPort = true
      if not atPort: cands.add (y: y, run: run)
    cands.sort(proc(x, z: tuple[y, run: float]): int =
      result = cmp(z.run, x.run)               ## longer run first
      if result == 0: result = cmp(x.y, z.y))  ## then y ascending

    var picked: seq[float]
    for c in cands:
      if picked.len >= portRefineCandidates: break
      picked.add c.y
    if picked.len > 0: result[net] = picked

proc refinePortPlacement(state: var LayoutState) =
  ## Pull each ported net's ports onto the y its routed wire already runs
  ## along, whenever a full re-route then scores strictly better
  ## (`betterThan`: fallbacks, then bends, then length). A port's column and x
  ## are never touched -- only its y, and only through `state.portY`, which
  ## `routeScene` applies as the column relaxation's spring target so
  ## `portMinGap` still holds. Bounded by `portRefineRounds` sweeps and
  ## `portRefineMaxAttempts` re-routes; a sheet that never improves is left
  ## exactly as routing produced it. Deterministic: fixed budgets, ordered
  ## iteration, no clock or RNG.
  if state.routing.ports.len == 0: return
  # The same raw-size ceiling `recoverRouting` gates its per-candidate re-route
  # cost on -- a post-route pass is the same shape of work.
  if state.comps.len > 4 * state.options.feedbackMaxParts: return

  var best = sceneScore(state.routing)
  var attempts = 0
  for _ in 1 .. portRefineRounds:
    var improved = false
    let targets = portTargets(state.routing)
    for net, ys in targets:
      if attempts >= portRefineMaxAttempts: break
      var names: seq[string]
      for p in state.routing.ports:
        if p.net == net: names.add p.name
      if names.len == 0: continue
      for ty in ys:
        if attempts >= portRefineMaxAttempts: break
        inc attempts
        let saved = state.portY
        for nm in names: state.portY[nm] = ty
        let cand = routeScene(state, withFallbacks = true)
        if betterThan(sceneScore(cand), best):
          state.routing = cand
          best = sceneScore(cand)
          improved = true
          break                       ## first improving y wins for this net
        else:
          state.portY = saved
    if not improved: break

# --- manual-move validators (used by tests and future passes) ----------------

proc portObstacle(p: SchematicPort): Obstacle =
  let hw = p.bodyW / 2.0 + routingClearance
  let hh = p.bodyH / 2.0 + routingClearance
  Obstacle(x1: p.x - hw, y1: p.y - hh, x2: p.x + hw, y2: p.y + hh)

proc verifyPartPlacement(part: SchematicPart, state: LayoutState): bool =
  ## True when `part`'s `routingClearance`-inflated body -- the same
  ## inflation `separate` legalizes placement against and the router builds
  ## its obstacle set from -- does not overlap any other part or port already
  ## in `state.routing`. A part sharing `part`'s own designator is excluded
  ## from the comparison, so passing back the part's own (moved) copy checks
  ## it against everything *else* on the sheet. Intended to be called after a
  ## manual part move, to confirm the new position is still legal before it
  ## is accepted.
  let hw = part.bodyW / 2.0 + routingClearance
  let hh = part.bodyH / 2.0 + routingClearance
  let here = Obstacle(x1: part.x - hw, y1: part.y - hh,
                      x2: part.x + hw, y2: part.y + hh)
  var others: seq[SchematicPart]
  for p in state.routing.parts:
    if p.designator != part.designator: others.add p
  for other in obstaclesFor(others):
    if obstaclesOverlap(here, other): return false
  for p in state.routing.ports:
    if obstaclesOverlap(here, portObstacle(p)): return false
  true

proc verifyWireRouting(wire: SchematicWire, state: LayoutState): bool =
  ## True when `wire` -- a candidate manually re-routed net polyline, in
  ## scene coordinates -- conflicts with no other visual component in
  ## `state.routing`: none of its segments enters the interior of any part's
  ## or port's inflated body, threads a rail/ground terminal's drawn glyph
  ## ink, or touches another net's wire under the router's hard cross-net
  ## rule (no collinear touch, not even end-to-end, and at least
  ## `wireMinSeparation` of centreline separation wherever a parallel run's
  ## projections overlap). Other wires of `wire.net` are excluded: they are
  ## `wire`'s own branches, not another visual component, and the within-net
  ## no-positive-overlap invariant is the router's own concern when it grows
  ## a net's tree, not this check's. Intended to be called after a wire is
  ## manually re-routed, to confirm the new path is still legal before it is
  ## accepted.
  var obstacles = obstaclesFor(state.routing.parts)
  for p in state.routing.ports: obstacles.add portObstacle(p)
  var glyphs: seq[OccSeg]
  for w in state.routing.wires:
    for g in terminalGlyphSegments(w):
      glyphs.add g
  for k in 0 ..< wire.points.high:
    let a = wire.points[k]
    let b = wire.points[k + 1]
    if segBlocked(a, b, obstacles): return false
    for g in glyphs:
      if segmentsTouch(a, b, g.a, g.b): return false
    for other in state.routing.wires:
      if other.net == wire.net: continue
      for j in 0 ..< other.points.high:
        if collinearClosed(a, b, other.points[j], other.points[j + 1]): return false
        if parallelTooClose(a, b, other.points[j], other.points[j + 1]): return false
  true

proc translateRoutedComponent(state: var LayoutState, designator: string,
                              dx, dy: float): bool =
  ## Moves the already-placed-and-routed part `designator` by (`dx`, `dy`)
  ## and rebuilds the sheet's routing against the new position: every signal
  ## wire, every rail/ground stub ("power port"), and every fallback
  ## marker -- the anchor `finishLabels` later hangs a net-name label off of,
  ## since `LayoutState` itself carries no realized `SchematicLabel`s to move.
  ## `state.pos` is what `routeScene` reads for a part's centre;
  ## `state.routing.parts[i].x`/`y` is only a routed *snapshot* of it, so
  ## this writes the move there rather than into the routed copy directly.
  ##
  ## The move commits only when the fresh routing both completes in full
  ## (`RoutingState.ok`) and the moved part's new, `routingClearance`-inflated
  ## body clears every other part and port (`verifyPartPlacement`). A
  ## complete route does not by itself rule that out -- routing legality is
  ## about wires, never about a body sitting on top of another one -- so it is
  ## checked separately; `verifyWireRouting` is not, since a wire the router
  ## just emitted has already satisfied it by construction (the router's own
  ## obstacle/occupancy rules are the same primitives that proc checks). On
  ## either failure `state.pos` and `state.routing` are restored to exactly
  ## what they were and the move is refused, so a caller never has to tell
  ## "rejected" apart from "applied, then undone".
  ##
  ## Moves one part at a time: a member of a constrained-layout composite unit
  ## moved alone would leave its partner behind rather than translating as one
  ## rigid body, so a composite member is refused outright rather than
  ## silently breaking `restoreCompositeOffsets`' canonical-offset invariant.
  ## Moving a whole composite is outside this proc's scope.
  if designator notin state.idxOf: return false
  let idx = state.idxOf[designator]
  if state.options.policy == lpConstrainedLayered and
     state.composites.ownerOf[idx] != idx:
    return false
  let savedPos = state.pos[idx]
  let savedRouting = state.routing

  state.pos[idx] = Point(x: savedPos.x + dx, y: savedPos.y + dy)
  let rerouted = routeScene(state, withFallbacks = true)
  state.routing = rerouted

  var moved: SchematicPart
  var found = false
  for p in rerouted.parts:
    if p.designator == designator:
      moved = p
      found = true
      break

  if rerouted.ok and found and verifyPartPlacement(moved, state):
    return true

  state.pos[idx] = savedPos
  state.routing = savedRouting
  false
