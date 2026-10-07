type
  RouteAxis = enum
    raHoriz, raVert
    ## The axis a route arrived through. A bend is any switch between axes,
    ## never a 180-degree reversal.

  RouteResult = tuple[
    distLen: seq[float],
    distBends: seq[int],
    prev: seq[int]]

  RouteOutcome = object
    ## Routing one signal net. `ok` is false only for the recoverable failure
    ## (no reachable pin state) the feedback loop may fix; path-integrity
    ## failures are `doAssert`s (internal bugs).
    ok: bool
    polys: seq[seq[Point]]
    failPin: int

  ## One endpoint to connect: a placed pin, or a port connection point with
  ## an explicit inward escape. `pinName` is empty for a port; `fallbackFor`
  ## uses it.
  RoutePin = tuple[
    pt: Point,
    partIdx: int,
    esc: Point,
    pinName: string]

proc lexBefore(l1: float, b1: int, l2: float, b2: int): bool {.inline.} =
  ## Strict lexicographic (Manhattan length, bend count): shorter wins, or
  ## equal length with fewer bends.
  l1 < l2 - 1e-9 or (abs(l1 - l2) <= 1e-9 and b1 < b2)

type
  DijkstraEntry = tuple[len: float, bends: int, state: int]
    ## A heap entry, ordered by exact `<`: lengths are sums of grid-quantized
    ## deltas, so equal routes land on equal floats. `state` breaks ties by
    ## lowest id, matching `lexBefore`.

proc `<`(a, b: DijkstraEntry): bool {.inline.} =
  a.len < b.len or (a.len == b.len and
    (a.bends < b.bends or (a.bends == b.bends and a.state < b.state)))

proc dijkstraFromSources(nodes: seq[Point], adj: seq[seq[int]],
                         sources: seq[int], occ, seeds, glyphs: seq[OccSeg],
                         netName: string): RouteResult =
  ## Multi-source bend-aware Dijkstra. State is `(node, incoming axis)`;
  ## cost is lexicographic (length, bends). Sources are seeded in both axis
  ## states at zero cost, so the first edge is free. Edges violating the
  ## occupancy rules are skipped (`edgeAllowed`).
  ##
  ## Deterministic: state id `2*node + axis` breaks ties, and a non-strict
  ## relaxation never replaces a predecessor. The frontier is a binary heap
  ## keyed `(distLen, distBends, state)` with lazy deletion (stale pops are
  ## skipped via `used`).
  let v = nodes.len
  let sv = 2 * v
  result.distLen = newSeq[float](sv)
  result.distBends = newSeq[int](sv)
  result.prev = newSeq[int](sv)
  var used = newSeq[bool](sv)
  for s in 0 ..< sv:
    result.distLen[s] = Inf
    result.prev[s] = -1

  # Only `occ` grows per net, so only it is bucketed; `seeds`/`glyphs` are
  # scanned flat (see `edgeAllowedFast`).
  let occIdx = buildOccIndex(occ)

  var frontier = initHeapQueue[DijkstraEntry]()
  for s in sources:
    if s >= 0 and s < v:
      result.distLen[2 * s] = 0.0
      result.distLen[2 * s + 1] = 0.0
      frontier.push (len: 0.0, bends: 0, state: 2 * s)
      frontier.push (len: 0.0, bends: 0, state: 2 * s + 1)

  while frontier.len > 0:
    let u = frontier.pop().state
    if used[u]: continue
    used[u] = true
    let i = u div 2
    let inAxis = if u mod 2 == 0: raHoriz else: raVert
    for j in adj[i]:
      if sameCoord(nodes[i].x, nodes[j].x) and
         sameCoord(nodes[i].y, nodes[j].y):
        continue
      let edgeAxis =
        if sameCoord(nodes[i].x, nodes[j].x): raVert else: raHoriz
      let t = 2 * j + ord(edgeAxis)
      if used[t]: continue
      if not edgeAllowedFast(nodes[i], nodes[j], netName, occIdx, seeds, glyphs): continue
      let ndLen = result.distLen[u] + manhattan(nodes[i], nodes[j])
      let ndBends = result.distBends[u] + (if inAxis == edgeAxis: 0 else: 1)
      if lexBefore(ndLen, ndBends, result.distLen[t], result.distBends[t]):
        result.distLen[t] = ndLen
        result.distBends[t] = ndBends
        result.prev[t] = u
        frontier.push (len: ndLen, bends: ndBends, state: t)

proc pathToState(prev: seq[int], dstState: int): seq[int] =
  ## The node path from a source state to `dstState`, source first. `prev`
  ## maps state id (`2*node + axis`) to its predecessor.
  if dstState < 0 or dstState >= prev.len: return @[]
  result.add dstState div 2
  var cur = dstState
  while prev[cur] >= 0:
    cur = prev[cur]
    if cur < 0: return @[]
    result.add cur div 2
  result.reverse()

proc escapeDir(part: SchematicPart, pt: Point): Point =
  ## A pin's outward unit direction: the normal of the body edge it sits on.
  ## Keyed on body half-extents, so a left-edge pin near a tall box's top
  ## still leaves left.
  let dx = pt.x - part.x
  let dy = pt.y - part.y
  let hw = part.bodyW / 2.0
  let hh = part.bodyH / 2.0
  if abs(abs(dx) - hw) < abs(abs(dy) - hh):
    Point(x: (if dx >= 0.0: 1.0 else: -1.0), y: 0.0)
  else:
    Point(x: 0.0, y: (if dy >= 0.0: 1.0 else: -1.0))

proc fallbackStub(p: Point, dir: Point, span: float, occ: seq[OccSeg]):
    seq[Point] =
  ## A fallback pin's dashed stub, shortened against emitted wires as a
  ## foreign net. Empty means no room: marker and label only.
  let e = shortenedStubEnd(p, dir, span, fallbackNetName, occ)
  if sameCoord(e.x, p.x) and sameCoord(e.y, p.y): return @[]
  @[p, e]

proc fallbackFor(pin: RoutePin, parts: seq[SchematicPart], netName: string,
                 occ: seq[OccSeg], kind = fbUnrouted,
                 bundle = ""): SchematicFallback =
  ## The record for one unroutable pin (`fbUnrouted`) or one member pin of a
  ## bundle carried by name (`fbNetLabel`). The stub leaves the way a real
  ## wire would.
  let dir =
    if pin.esc.x != 0.0 or pin.esc.y != 0.0: pin.esc
    else: escapeDir(parts[pin.partIdx], pin.pt)
  result = SchematicFallback(kind: kind, bundle: bundle, net: netName,
    part: (if pin.pinName.len > 0: parts[pin.partIdx].designator else: ""),
    pin: pin.pinName, x: pin.pt.x, y: pin.pt.y, ex: dir.x, ey: dir.y,
    points: fallbackStub(pin.pt, dir, routingClearance, occ))

proc fallbackEscapeDir*(parts: seq[SchematicPart], ports: seq[SchematicPort],
                        f: SchematicFallback): Point =
  ## A fallback's `ex`/`ey`, recomputed from the scene: a part pin's
  ## `escapeDir`, or a port point's inward escape from the port's rotation.
  ## Used by the JSON reader for legacy archives. `(0, 0)` when the owner
  ## can't be found.
  if f.part.len > 0:
    for p in parts:
      if p.designator != f.part: continue
      for pin in p.pins:
        if pin.name == f.pin:
          return escapeDir(p, Point(x: pin.x, y: pin.y))
    return Point(x: 0.0, y: 0.0)
  # A port point: rotation 0 puts the body right (escape -x), 180 left
  # (escape +x).
  for p in ports:
    if p.net != f.net: continue
    let hw = p.bodyW / 2.0
    let onRight = abs(p.rotation) < 1e-9
    let cx = if onRight: p.x - hw else: p.x + hw
    if abs(cx - f.x) < 1e-6 and abs(p.y - f.y) < 1e-6:
      return Point(x: (if onRight: -1.0 else: 1.0), y: 0.0)
  Point(x: 0.0, y: 0.0)

proc routeNet(pins: seq[RoutePin],
              parts: seq[SchematicPart], obstacles: seq[Obstacle],
              free: tuple[nodes: seq[Point], adj: seq[seq[int]]],
              occ: var seq[OccSeg], netName: string,
              seeds, glyphs: seq[OccSeg]): RouteOutcome =
  ## Routes one signal net as an occupancy-aware tree: pin 0 first, then each
  ## later pin joins the nearest tree point by the lexicographically best
  ## path that keeps clearance and obeys the occupancy rules. Each polyline
  ## is one `SchematicWire` from attachment point to pin, so wires of a net
  ## share at most a vertex.
  ##
  ## `seeds` (fixed escape stubs) may be touched or crossed but not run
  ## along; they never enter `occ`.
  ##
  ## An unreachable pin is the one recoverable failure (`ok = false`,
  ## `failPin` set) for the feedback loop. Path-integrity failures are
  ## `doAssert`s, never papered over with a straight fallback.
  var nodes: seq[Point]
  var pinNode: seq[int]
  for pin in pins:
    # A port point uses its explicit escape; a part pin derives it from its
    # body edge.
    let d =
      if pin.esc.x != 0.0 or pin.esc.y != 0.0: pin.esc
      else: escapeDir(parts[pin.partIdx], pin.pt)
    pinNode.add nodes.len
    nodes.add pin.pt + d * routingClearance
  let base = nodes.len
  for p in free.nodes: nodes.add p

  let v = nodes.len
  var adj = newSeq[seq[int]](v)
  # Escape points may see each other or a grid node directly.
  for i in 0 ..< base:
    for j in i + 1 ..< v:
      if sameCoord(nodes[i].x, nodes[j].x) or sameCoord(nodes[i].y, nodes[j].y):
        if not segBlocked(nodes[i], nodes[j], obstacles):
          adj[i].add j
          adj[j].add i
  # Shared grid edges, offset past the escape points.
  for i, nbrs in free.adj:
    for j in nbrs:
      adj[base + i].add base + j

  if pins.len < 2: return RouteOutcome(ok: true)

  var connected = newSeq[bool](pins.len)
  connected[0] = true
  var inTree = newSeq[bool](v)
  inTree[pinNode[0]] = true
  var first = true
  var polys: seq[seq[Point]]

  while true:
    var un = -1
    for i in 0 ..< pins.len:
      if not connected[i]: un = i; break
    if un < 0: break

    var sources: seq[int]
    for i in 0 ..< v:
      if inTree[i]: sources.add i

    let rr = dijkstraFromSources(nodes, adj, sources, occ, seeds, glyphs, netName)

    var bestPin = -1
    var bestLen = Inf
    var bestBends = 0
    var bestState = -1
    for i in 0 ..< pins.len:
      if connected[i]: continue
      let n0 = pinNode[i]
      var s = -1
      var sl = Inf
      var sb = 0
      for ax in [raHoriz, raVert]:
        let sid = 2 * n0 + ord(ax)
        if rr.distLen[sid] < sl - 1e-9 or
           (abs(rr.distLen[sid] - sl) <= 1e-9 and
            (s < 0 or rr.distBends[sid] < sb)):
          s = sid
          sl = rr.distLen[sid]
          sb = rr.distBends[sid]
      if bestPin < 0 or
         sl < bestLen - 1e-9 or
         (abs(sl - bestLen) <= 1e-9 and
          (sb < bestBends or (sb == bestBends and i < bestPin))):
        bestPin = i
        bestLen = sl
        bestBends = sb
        bestState = s

    if bestState < 0:
      return RouteOutcome(ok: false, failPin: un)
    let pathIdx = pathToState(rr.prev, bestState)
    doAssert pathIdx.len > 0,
      "schematic route: empty path for net \"" & netName & "\""
    doAssert pathIdx[^1] == pinNode[bestPin],
      "schematic route: path for net \"" & netName &
      "\" does not end at its target pin"
    doAssert inTree[pathIdx[0]],
      "schematic route: path for net \"" & netName &
      "\" does not start at the routed tree"
    for k in 0 ..< pathIdx.high:
      doAssert edgeAllowed(nodes[pathIdx[k]], nodes[pathIdx[k + 1]], netName,
                           occ, seeds, glyphs),
        "schematic route: path edge for net \"" & netName &
        "\" violates occupancy"

    var poly: seq[Point]
    if first:
      poly.add pins[0].pt
      first = false
    for idx in pathIdx:
      poly.add nodes[idx]
    poly.add pins[bestPin].pt

    var deduped: seq[Point]
    for p in poly:
      if deduped.len == 0 or
         not (sameCoord(deduped[^1].x, p.x) and sameCoord(deduped[^1].y, p.y)):
        deduped.add p
    doAssert deduped.len >= 2,
      "schematic route: degenerate polyline for net \"" & netName & "\""
    for k in 0 ..< deduped.len - 1:
      doAssert sameCoord(deduped[k].x, deduped[k + 1].x) or
                sameCoord(deduped[k].y, deduped[k + 1].y),
        "schematic route: non-axis-aligned segment for net \"" & netName & "\""
    polys.add deduped

    for idx in pathIdx: inTree[idx] = true
    for k in 0 ..< deduped.len - 1:
      let a = deduped[k]
      let b = deduped[k + 1]
      addOcc(occ, a, b, netName)
      # Every node this wire passes is now on the tree, so later wires may
      # attach anywhere along it.
      for t in 0 ..< v:
        if not inTree[t] and pointOnSegment(nodes[t], a, b):
          inTree[t] = true
    connected[bestPin] = true

  RouteOutcome(ok: true, polys: polys)

proc routeConstrainedNet(pins: seq[RoutePin], parts: seq[SchematicPart],
                         obstacles: seq[Obstacle],
                         free: tuple[nodes: seq[Point], adj: seq[seq[int]]],
                         occ: var seq[OccSeg], netName: string,
                         seeds, glyphs: seq[OccSeg]): RouteOutcome =
  ## A trunk-and-tap attempt is atomic: on failure, occupancy is restored so
  ## the caller can emit marker-only fallbacks for the whole net.
  let before = occ
  result = routeNet(pins, parts, obstacles, free, occ, netName, seeds, glyphs)
  if not result.ok: occ = before

proc addSegments(adj: var Table[Point, HashSet[Point]], poly: seq[Point]) =
  for i in 0 ..< poly.len - 1:
    let p = poly[i]
    let q = poly[i + 1]
    if p == q: continue
    adj.mgetOrPut(p, initHashSet[Point]()).incl q
    adj.mgetOrPut(q, initHashSet[Point]()).incl p

