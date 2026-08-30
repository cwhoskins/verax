type
  RouteAxis = enum
    raHoriz, raVert
    ## The axis of the edge a route arrived through. Only the axis matters for
    ## charging a bend: a turn is any switch between the two axes, never a 180
    ## degree reversal along the same axis.

  RouteResult = tuple[
    distLen: seq[float],
    distBends: seq[int],
    prev: seq[int]]

  RouteOutcome = object
    ## The result of routing one signal net. `ok` is false only for the one
    ## recoverable failure -- no pin state reachable on the free grid -- which
    ## the placement-routing feedback loop may move out of. Every
    ## path-integrity failure inside `routeNet` is still an immediate
    ## `doAssert`, because those are internal bugs, never placement problems.
    ok: bool
    polys: seq[seq[Point]]
    failPin: int

  ## One endpoint a signal net must connect: a placed part pin, or a port's
  ## connection point with an explicit inward escape. `pinName` is empty for a
  ## port point; `fallbackFor` uses it to record *which* pin a fallback
  ## belongs to.
  RoutePin = tuple[
    pt: Point,
    partIdx: int,
    esc: Point,
    pinName: string]

proc lexBefore(l1: float, b1: int, l2: float, b2: int): bool {.inline.} =
  ## Strict lexicographic order on (Manhattan length, bend count): a route is
  ## better only when it is shorter, or exactly as short with fewer bends.
  l1 < l2 - 1e-9 or (abs(l1 - l2) <= 1e-9 and b1 < b2)

proc dijkstraFromSources(nodes: seq[Point], adj: seq[seq[int]],
                         sources: seq[int], occ, seeds, glyphs: seq[OccSeg],
                         netName: string): RouteResult =
  ## Multi-source bend-aware Dijkstra over the routing graph. The state is
  ## `(node, incoming axis)`, so the cost of leaving a node depends on the
  ## axis the route arrived through; the cost of a route is the lexicographic
  ## pair (Manhattan length, bend count), so among all shortest routes the
  ## fewest-bend one wins. Every source is seeded in *both* axis states at
  ## zero cost, which makes the first graph edge free: a route may leave a
  ## source in either axis without charging a bend. Edges that would violate
  ## the net-aware occupancy rules are skipped (see `edgeAllowed`).
  ##
  ## Determinism is restated on states. A state id is `2*node + axis`
  ## (`raHoriz` first), so equal (length, bends) distances are settled by the
  ## lowest node index, then the horizontal state; and a relaxation that is
  ## not strictly better never replaces a predecessor, so the first
  ## (lowest-id) predecessor wins.
  let v = nodes.len
  let sv = 2 * v
  result.distLen = newSeq[float](sv)
  result.distBends = newSeq[int](sv)
  result.prev = newSeq[int](sv)
  var used = newSeq[bool](sv)
  for s in 0 ..< sv:
    result.distLen[s] = Inf
    result.prev[s] = -1
  for s in sources:
    if s >= 0 and s < v:
      result.distLen[2 * s] = 0.0
      result.distLen[2 * s + 1] = 0.0

  for _ in 0 ..< sv:
    var u = -1
    for s in 0 ..< sv:
      if used[s] or result.distLen[s] == Inf: continue
      if u < 0 or
         lexBefore(result.distLen[s], result.distBends[s],
                   result.distLen[u], result.distBends[u]) or
         (abs(result.distLen[s] - result.distLen[u]) <= 1e-9 and
          result.distBends[s] == result.distBends[u] and s < u):
        u = s
    if u < 0: break
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
      if not edgeAllowed(nodes[i], nodes[j], netName, occ, seeds, glyphs): continue
      let ndLen = result.distLen[u] + manhattan(nodes[i], nodes[j])
      let ndBends = result.distBends[u] + (if inAxis == edgeAxis: 0 else: 1)
      if lexBefore(ndLen, ndBends, result.distLen[t], result.distBends[t]):
        result.distLen[t] = ndLen
        result.distBends[t] = ndBends
        result.prev[t] = u

proc pathToState(prev: seq[int], dstState: int): seq[int] =
  ## The node-index path from a Dijkstra source state to `dstState`, source
  ## first. `prev` maps a state id (`2*node + axis`) to its predecessor state.
  if dstState < 0 or dstState >= prev.len: return @[]
  result.add dstState div 2
  var cur = dstState
  while prev[cur] >= 0:
    cur = prev[cur]
    if cur < 0: return @[]
    result.add cur div 2
  result.reverse()

proc escapeDir(part: SchematicPart, pt: Point): Point =
  ## The outward unit direction of a pin: away from the part along the normal
  ## of the body edge the pin sits on. Pins are placed on the boundary, so
  ## this is the direction a wire leaves the pin without crossing the body.
  ##
  ## Keyed on the body half-extents rather than the dominant offset axis: a
  ## left-edge pin near the top of a tall box still leaves to the left, not
  ## upward.
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
  ## The dashed stub for a fallback pin: a short outward segment, shortened
  ## against every already-emitted wire as if it were a foreign net. An empty
  ## result means the pin has no room in its escape direction -- a zero-space
  ## fallback with no wire, only the marker and label at the pin.
  let e = shortenedStubEnd(p, dir, span, fallbackNetName, occ)
  if sameCoord(e.x, p.x) and sameCoord(e.y, p.y): return @[]
  @[p, e]

proc fallbackFor(pin: RoutePin, parts: seq[SchematicPart], netName: string,
                 occ: seq[OccSeg]): SchematicFallback =
  ## The public record for one unrouteable pin. The stub direction is the
  ## pin's normal outward escape (or a port point's inward escape), so the
  ## dashed marker leaves the body the way a real wire would have.
  let dir =
    if pin.esc.x != 0.0 or pin.esc.y != 0.0: pin.esc
    else: escapeDir(parts[pin.partIdx], pin.pt)
  result = SchematicFallback(net: netName,
    part: (if pin.pinName.len > 0: parts[pin.partIdx].designator else: ""),
    pin: pin.pinName, x: pin.pt.x, y: pin.pt.y, ex: dir.x, ey: dir.y,
    points: fallbackStub(pin.pt, dir, routingClearance, occ))

proc fallbackEscapeDir*(parts: seq[SchematicPart], ports: seq[SchematicPort],
                        f: SchematicFallback): Point =
  ## The outward escape direction a fallback's `ex`/`ey` records, recomputed
  ## from the scene it belongs to. A part pin's fallback leaves along that
  ## pin's body-edge outward normal (`escapeDir`); a port connection point's
  ## fallback leaves along the port's inward escape (toward the sheet
  ## centre), read from the port's rotation. Used by the JSON reader to fill
  ## the `ex`/`ey` a legacy unversioned archive never stored.
  ##
  ## Returns `(0, 0)` when the scene cannot identify the owning pin or port:
  ## the honest answer for a record whose owner is missing, never an invented
  ## direction.
  if f.part.len > 0:
    for p in parts:
      if p.designator != f.part: continue
      for pin in p.pins:
        if pin.name == f.pin:
          return escapeDir(p, Point(x: pin.x, y: pin.y))
    return Point(x: 0.0, y: 0.0)
  # A port connection point: `f.x`/`f.y` is the point where the port's stub
  # meets its body edge. `rotation` 0 puts the body to the right of that
  # point (inward escape -x); 180 puts it to the left (inward escape +x).
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
  ## Routes one signal net as an occupancy-aware tree. The first connected pin
  ## is pin 0; every later pin is connected to the closest point already in
  ## the tree by a shortest path -- lexicographically (Manhattan length, then
  ## bends), so an equal-length route with fewer bends wins -- that keeps body
  ## clearance, never runs along an occupied segment, and upholds the
  ## stronger different-net rule: no collinear touch (even end-to-end) and at
  ## least `wireMinSeparation` between parallel, projection-overlapping
  ## segments. Each returned polyline is one `SchematicWire`: it starts at the
  ## attachment point (a pin on the first connection, a tree node afterwards)
  ## and ends at the pin it connects, so the union of the polylines covers the
  ## tree exactly once and two wires of the net share at most a vertex.
  ##
  ## `seeds` are the fixed escape stubs of every signal pin and port
  ## connection point, read-only. A route may touch a seed at an endpoint and
  ## may cross it perpendicularly, but may not run along any positive-length
  ## part of it -- the seed's open interior stays clear for the net that owns
  ## it. They are never added to `occ`, which stays the emitted-wire set a
  ## fallback stub sizes itself against -- a pin's own seed must not read as
  ## a foreign wire there.
  ##
  ## A pin that cannot be reached on the free grid under those rules is the
  ## one *recoverable* failure: the outcome is `ok = false` with `failPin` set
  ## to the first unconnected pin, and the placement-routing feedback loop may
  ## move parts and try again. Every path-integrity failure below is still an
  ## immediate `doAssert` -- those are internal bugs, never a case to paper
  ## over with an unchecked straight fallback that would cross bodies or other
  ## nets.
  var nodes: seq[Point]
  var pinNode: seq[int]
  for pin in pins:
    # A pin with an explicit escape (a port's connection point in its edge
    # column) uses it; a real part pin derives it from the body edge it sits
    # on.
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
      # Every graph node that this new wire runs through is now part of the
      # net's tree, so a later wire may attach to any point along it (shared
      # vertex) instead of being forced to run along the same segment.
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
  ## A trunk-and-tap attempt is atomic: its growing tree is useful only if all
  ## taps reach it. On failure restore occupancy before the next net is tried,
  ## so the caller can emit marker-only fallbacks for the complete net.
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

