# Post-route refinement passes. Included by `layout.nim` after `./finish`, so
# every layout type, geometry constant and `routeScene` overload is in scope.

# --- routed-scene scoring ------------------------------------------------------

proc wireBends(poly: seq[Point]): int =
  ## Direction changes along a rectilinear polyline; collinear points and
  ## zero-length segments don't count.
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
  ## Lexicographic route quality: fallbacks, then corners, then length.
  ## `wkChain` arcs are annotations, so excluded.
  result.fallbacks = rs.fallbacks.len
  for w in rs.wires:
    if w.kind == wkChain: continue
    result.bends += wireBends(w.points)
    result.length += wireLength(w.points)

proc betterThan(a, b: tuple[fallbacks, bends: int, length: float]): bool =
  ## Strict lexicographic improvement; length ties within 1e-6 don't count.
  if a.fallbacks != b.fallbacks: return a.fallbacks < b.fallbacks
  if a.bends != b.bends: return a.bends < b.bends
  b.length - a.length > 1e-6

# --- post-route port placement -----------------------------------------------

proc portTargets(rs: RoutingState): OrderedTable[string, seq[float]] =
  ## For each ported net, the y's where its routed wire runs longest
  ## horizontally, best first, at most `portRefineCandidates`, excluding
  ## y's a port already sits at. In `rs.ports` order.
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
  ## Pull each ported net's ports onto the y its wire already runs along,
  ## when a full re-route scores strictly better. Only `state.portY` changes
  ## (a spring target, so `portMinGap` holds). Bounded by
  ## `portRefineRounds` and `portRefineMaxAttempts`; deterministic.
  if state.routing.ports.len == 0: return
  # Same raw-size ceiling as `recoverRouting`.
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
  ## True when `part`'s inflated body overlaps no other part or port in
  ## `state.routing` (its own designator excluded). For validating a manual
  ## move.
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
  ## True when a candidate re-routed polyline enters no part/port body,
  ## threads no glyph ink, and obeys the cross-net rules against other nets'
  ## wires (same-net wires excluded). For validating a manual re-route.
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
  ## Moves part `designator` by (`dx`, `dy`) via `state.pos` and re-routes
  ## the sheet (wires, rail stubs, fallback markers). Commits only if routing
  ## completes and the moved body clears every part and port
  ## (`verifyPartPlacement`); otherwise everything is restored and it returns
  ## false. Composite members are refused (they must move as a unit).
  if designator notin state.idxOf: return false
  let idx = state.idxOf[designator]
  if state.composites.ownerOf[idx] != idx:
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
