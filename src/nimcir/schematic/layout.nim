## Deterministic placement and routing: `Netlist` -> `Schematic`.
##
## Pure: it reads the graph through the public API, never mutates it, and
## touches no files, no clock and no simulator. The two passes follow the
## reference visualizer described in `docs/netlist-converter-research.md`: a
## Fruchterman-Reingold force layout seeded on a golden-angle spiral, then
## obstacle- and occupancy-aware orthogonal tree routing. Placement ends with a
## deterministic separation pass so no two *inflated* component bodies ever
## overlap -- the inflation is the routing clearance below plus an extra
## channel -- and routing is obstacle-aware: a signal wire keeps the routing
## clearance from every component body and reaches each pin directly through
## a short outward stub. After the centres are final, each eligible
## two-terminal part is turned 0 or 90 degrees so its pin axis follows the
## dominant direction of its neighbours (see `rotationFor`); the rotation is
## written into `SchematicPart.rotation` and its pin slots are rotated with
## it, so routing, obstacle avoidance and rendering all agree. Every step is
## deterministic -- same netlist, same scene, every time -- which is what
## makes the scene testable and the archive reproducible.
##
## Rail decisions come from `netlist/kinds.isGround`/`isRail`, never from a
## name guess: a ground or supply net is not wired as a tree but drawn as a
## local stub at each pin. Symbol/kind selection is a small registry keyed by
## `Component.kind`, with a fallback box for anything unrecognised -- the
## same "refuse to guess, draw a box" stance the rest of the library takes
## toward parts it cannot model.
##
## The routing invariant is **no shared collinear runs**: two distinct
## `SchematicWire` objects may meet at a vertex and may cross perpendicularly,
## but they never overlap along a positive-length segment. Routing is
## occupancy-aware -- every emitted signal segment and every ground/supply
## stub is recorded, and later routes (and later stubs) are shortened or
## steered so they only touch that geometry, never run along it. Signal nets
## grow as a tree from the first pin, attaching each next pin to the closest
## point already wired, so the per-net polylines partition the tree's segments
## exactly once.

import std/[algorithm, math, sets, strutils, tables]
import ../netlist/types
import ../netlist/kinds
import ./scene

const
  grid = 40.0
  pinSpan = 40.0
  routingClearance = 12.0
    ## Minimum distance a signal wire keeps from a component body. Routing
    ## obstacles are component bodies inflated by this amount on every side.
  placementPad = 20.0
    ## Placement inflates each body by this much per side. Two bodies placed
    ## at least `2 * placementPad` apart therefore leave their
    ## `routingClearance`-inflated obstacles `2 * placementPad - 2 *
    ## routingClearance` = 16 apart -- a channel wider than the clearance, so
    ## a route fits between them.

type
  SymbolDef = object
    name: string
    isBox: bool
    bodyW, bodyH: float
    slots: seq[Point]
      ## Positional pin slots: `slots[i]` is the slot of the `i`-th pin in
      ## `Component.pins` order.
    byName: Table[string, Point]
      ## When non-empty, pin slots are keyed by pin name instead of position
      ## (the controlled-source symbol, whose input and output pins sit on
      ## opposite edges regardless of declaration order).

  Obstacle = object
    ## An axis-aligned forbidden rectangle for signal routing: a component
    ## body inflated by `routingClearance`.
    x1, y1, x2, y2: float

  OccSeg = object
    ## One already-emitted axis-aligned wire segment. Occupancy is what stops
    ## two distinct `SchematicWire` objects from ever sharing a positive-length
    ## collinear segment: a new route may cross an occupied segment
    ## perpendicularly and may share either of its endpoints, but may not run
    ## along it.
    a, b: Point

proc boxSlots(n: int): tuple[slots: seq[Point], halfW, halfH: float] =
  ## Deterministic fallback-box pin placement: the left edge top to bottom,
  ## then the right edge top to bottom. `halfW`/`halfH` are the half-extents
  ## the body rectangle is drawn with.
  let vSpacing = 34.0
  let halfW = 70.0
  let left = (n + 1) div 2
  let right = n - left
  let rows = max(left, right)
  let halfH = max(24.0, float(rows) * vSpacing / 2.0)
  for i in 0 ..< left:
    let y = (float(i) - float(left - 1) / 2.0) * vSpacing
    result.slots.add Point(x: -halfW, y: y)
  for i in 0 ..< right:
    let y = (float(i) - float(right - 1) / 2.0) * vSpacing
    result.slots.add Point(x: halfW, y: y)
  result.halfW = halfW
  result.halfH = halfH

proc symbolFor(c: Component): SymbolDef =
  ## The symbol for `c.kind`, with pin slots relative to the part centre.
  ##
  ## A part is a fallback box when its kind has no registered symbol, when it
  ## instantiates hierarchy (its pins are the child's ports, best drawn as a
  ## box), or when its pin count does not match the symbol's slots.
  let n = c.pins.len
  proc box(): SymbolDef =
    let b = boxSlots(n)
    SymbolDef(name: "box", isBox: true, bodyW: b.halfW * 2.0,
              bodyH: b.halfH * 2.0, slots: b.slots)

  if c.subNetlist != nil:
    return box()

  let h = 2.0 * pinSpan
  let horiz = @[Point(x: -pinSpan, y: 0.0), Point(x: pinSpan, y: 0.0)]
  let vert = @[Point(x: 0.0, y: -pinSpan), Point(x: 0.0, y: pinSpan)]

  case c.kind.toLowerAscii()
  of "resistor":
    result = SymbolDef(name: "resistor", bodyW: h, bodyH: h, slots: horiz)
  of "capacitor":
    result = SymbolDef(name: "capacitor", bodyW: h, bodyH: h, slots: horiz)
  of "inductor":
    result = SymbolDef(name: "inductor", bodyW: h, bodyH: h, slots: horiz)
  of "diode", "led", "zener":
    result = SymbolDef(name: "diode", bodyW: h, bodyH: h, slots: horiz)
  of "fuse", "ferrite_bead", "wire", "jumper", "crystal", "potentiometer",
     "thermistor", "varistor", "switch", "relay", "load_switch", "antenna",
     "speaker", "test_point":
    result = SymbolDef(name: "passive", bodyW: h, bodyH: h, slots: horiz)
  of "voltage_source", "battery":
    result = SymbolDef(name: "voltage_source", bodyW: h, bodyH: h, slots: vert)
  of "current_source", "iswitch":
    result = SymbolDef(name: "current_source", bodyW: h, bodyH: h, slots: vert)
  of "vcvs", "vccs", "cccs", "ccvs":
    # A rectangular buffer/controlled source: OUT+/OUT- on the right edge,
    # IN+/IN- on the left edge. Slots are keyed by pin name so declaration
    # order never decides which side a pin lands on.
    if n != 4: return box()
    let bodyW = 2.0 * pinSpan
    let bodyH = 60.0
    var byName = initTable[string, Point]()
    byName["OUT+"] = Point(x: bodyW / 2.0, y: -20.0)
    byName["OUT-"] = Point(x: bodyW / 2.0, y: 20.0)
    byName["IN+"] = Point(x: -bodyW / 2.0, y: -20.0)
    byName["IN-"] = Point(x: -bodyW / 2.0, y: 20.0)
    for pinName, _ in c.pins:
      if not byName.hasKey(pinName): return box()
    return SymbolDef(name: "source4", bodyW: bodyW, bodyH: bodyH, byName: byName)
  of "bjt", "mosfet", "jfet", "transistor":
    result = SymbolDef(name: "transistor", bodyW: h, bodyH: h,
      slots: @[Point(x: 0.0, y: -pinSpan), Point(x: -pinSpan, y: 0.0),
               Point(x: 0.0, y: pinSpan)])
  else:
    return box()

  if result.slots.len != n:
    return box()

proc sameCoord(a, b: float): bool {.inline.} = abs(a - b) < 1e-9

proc segBlocked(a, b: Point, obstacles: seq[Obstacle]): bool =
  ## True if the axis-aligned segment `a`--`b` enters the interior of any
  ## obstacle. Touching a boundary is allowed, which is how a route may run
  ## along a body edge exactly at the clearance distance.
  const eps = 1e-9
  if sameCoord(a.x, b.x):
    let y1 = min(a.y, b.y)
    let y2 = max(a.y, b.y)
    for o in obstacles:
      if a.x > o.x1 + eps and a.x < o.x2 - eps and
         y2 > o.y1 + eps and y1 < o.y2 - eps:
        return true
  else:
    let x1 = min(a.x, b.x)
    let x2 = max(a.x, b.x)
    for o in obstacles:
      if a.y > o.y1 + eps and a.y < o.y2 - eps and
         x2 > o.x1 + eps and x1 < o.x2 - eps:
        return true
  false

proc manhattan(a, b: Point): float {.inline.} =
  abs(a.x - b.x) + abs(a.y - b.y)

proc positiveOverlap(a1, a2, b1, b2: float): bool {.inline.} =
  ## Whether the intervals `[a1, a2]` and `[b1, b2]` share more than a point.
  let lo = max(min(a1, a2), min(b1, b2))
  let hi = min(max(a1, a2), max(b1, b2))
  hi - lo > 1e-9

proc collinearOverlap(a, b, c, d: Point): bool =
  ## True when the axis-aligned segments `a`-`b` and `c`-`d` share any
  ## positive-length collinear portion. Touching at a single point is not an
  ## overlap, which is what lets two wires meet at a vertex.
  let av = sameCoord(a.x, b.x)
  let cv = sameCoord(c.x, d.x)
  if av != cv: return false
  if av:
    return sameCoord(a.x, c.x) and positiveOverlap(a.y, b.y, c.y, d.y)
  else:
    return sameCoord(a.y, c.y) and positiveOverlap(a.x, b.x, c.x, d.x)

proc pointOnSegment(p, a, b: Point): bool =
  ## True when `p` lies on the closed axis-aligned segment `a`-`b`.
  if sameCoord(a.x, b.x):
    if not sameCoord(p.x, a.x): return false
    let lo = min(a.y, b.y)
    let hi = max(a.y, b.y)
    return p.y >= lo - 1e-9 and p.y <= hi + 1e-9
  else:
    if not sameCoord(p.y, a.y): return false
    let lo = min(a.x, b.x)
    let hi = max(a.x, b.x)
    return p.x >= lo - 1e-9 and p.x <= hi + 1e-9

proc edgeAllowed(a, b: Point, occ: seq[OccSeg]): bool =
  ## A candidate routing edge is usable unless it runs along an already
  ## emitted segment. Perpendicular crossings stay allowed.
  for s in occ:
    if collinearOverlap(a, b, s.a, s.b): return false
  true

proc addOcc(occ: var seq[OccSeg], a, b: Point) {.inline.} =
  if sameCoord(a.x, b.x) and sameCoord(a.y, b.y): return
  occ.add OccSeg(a: a, b: b)

proc shortenedStubEnd(p: Point, dy: float, occ: seq[OccSeg]): Point =
  ## The end of a vertical rail stub from `p` toward `p.y + dy`, shortened
  ## just enough that it shares no positive-length collinear portion with an
  ## occupied segment. Perpendicular occupied segments are ignored (a crossing
  ## is allowed); only a vertical segment on the same x shortens the stub.
  let dir = if dy > 0.0: 1.0 else: -1.0
  var limit = p.y + dy
  for s in occ:
    if not sameCoord(s.a.x, s.b.x): continue
    if not sameCoord(s.a.x, p.x): continue
    let o1 = min(s.a.y, s.b.y)
    let o2 = max(s.a.y, s.b.y)
    if dir > 0.0:
      if o2 <= p.y + 1e-9: continue
      if o1 >= p.y + dy - 1e-9: continue
      limit = min(limit, if o1 <= p.y + 1e-9: p.y else: o1)
    else:
      if o1 >= p.y - 1e-9: continue
      if o2 <= p.y + dy + 1e-9: continue
      limit = max(limit, if o2 >= p.y - 1e-9: p.y else: o2)
  Point(x: p.x, y: limit)

proc dijkstraFromSources(nodes: seq[Point], adj: seq[seq[int]],
                         sources: seq[int], occ: seq[OccSeg]):
    tuple[dist: seq[float], prev: seq[int]] =
  ## Multi-source Dijkstra over the routing graph with deterministic
  ## tie-breaking: the lowest node index wins equal distances, and an
  ## equal-length relaxation never replaces a predecessor. Edges that would
  ## run along an occupied segment are skipped.
  let v = nodes.len
  result.dist = newSeq[float](v)
  result.prev = newSeq[int](v)
  var used = newSeq[bool](v)
  for i in 0 ..< v:
    result.dist[i] = Inf
    result.prev[i] = -1
  for s in sources:
    if s >= 0 and s < v: result.dist[s] = 0.0
  for _ in 0 ..< v:
    var u = -1
    for i in 0 ..< v:
      if not used[i] and (u < 0 or result.dist[i] < result.dist[u] - 1e-9):
        u = i
    if u < 0 or result.dist[u] == Inf: break
    used[u] = true
    for w in adj[u]:
      if used[w]: continue
      if not edgeAllowed(nodes[u], nodes[w], occ): continue
      let nd = result.dist[u] + manhattan(nodes[u], nodes[w])
      if nd < result.dist[w] - 1e-9:
        result.dist[w] = nd
        result.prev[w] = u

proc pathTo(prev: seq[int], dst: int): seq[int] =
  ## The node-index path from a Dijkstra source to `dst`, source first.
  if dst < 0 or dst >= prev.len: return @[]
  result.add dst
  var cur = dst
  while prev[cur] >= 0:
    cur = prev[cur]
    if cur < 0: return @[]
    result.add cur
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

proc obstaclesFor(parts: seq[SchematicPart]): seq[Obstacle] =
  for p in parts:
    let hw = p.bodyW / 2.0 + routingClearance
    let hh = p.bodyH / 2.0 + routingClearance
    result.add Obstacle(x1: p.x - hw, y1: p.y - hh, x2: p.x + hw, y2: p.y + hh)

proc insideAny(p: Point, obstacles: seq[Obstacle]): bool =
  ## Strict interior of any obstacle. Boundary points are allowed.
  const eps = 1e-9
  for o in obstacles:
    if p.x > o.x1 + eps and p.x < o.x2 - eps and
       p.y > o.y1 + eps and p.y < o.y2 - eps:
      return true
  false

proc buildFreeGrid(obstacles: seq[Obstacle]):
    tuple[nodes: seq[Point], adj: seq[seq[int]]] =
  ## The Hanan grid: every obstacle boundary x against every boundary y, with
  ## points inside an obstacle dropped. Two co-linear, mutually visible points
  ## are joined. This is the shared free-space graph every net's escape points
  ## hook into; because it contains every obstacle corner and every projection
  ## between them, it is complete for orthogonal paths among these rectangles.
  var xs: seq[float]
  var ys: seq[float]
  for o in obstacles:
    xs.add o.x1; xs.add o.x2
    ys.add o.y1; ys.add o.y2
  xs.sort()
  ys.sort()
  var uxs: seq[float]
  var uys: seq[float]
  for x in xs:
    if uxs.len == 0 or not sameCoord(uxs[^1], x): uxs.add x
  for y in ys:
    if uys.len == 0 or not sameCoord(uys[^1], y): uys.add y

  for x in uxs:
    for y in uys:
      let p = Point(x: x, y: y)
      if not insideAny(p, obstacles): result.nodes.add p

  let v = result.nodes.len
  result.adj = newSeq[seq[int]](v)
  for i in 0 ..< v:
    for j in i + 1 ..< v:
      if sameCoord(result.nodes[i].x, result.nodes[j].x) or
         sameCoord(result.nodes[i].y, result.nodes[j].y):
        if not segBlocked(result.nodes[i], result.nodes[j], obstacles):
          result.adj[i].add j
          result.adj[j].add i

proc routeNet(pins: seq[tuple[pt: Point, partIdx: int]],
              parts: seq[SchematicPart], obstacles: seq[Obstacle],
              free: tuple[nodes: seq[Point], adj: seq[seq[int]]],
              occ: var seq[OccSeg]): seq[seq[Point]] =
  ## Routes one signal net as an occupancy-aware tree. The first connected pin
  ## is pin 0; every later pin is connected to the closest point already in
  ## the tree by a shortest path that keeps body clearance and never runs
  ## along an occupied segment. Each returned polyline is one `SchematicWire`:
  ## it starts at the attachment point (a pin on the first connection, a tree
  ## node afterwards) and ends at the pin it connects, so the union of the
  ## polylines covers the tree exactly once and two wires of the net share at
  ## most a vertex.
  var nodes: seq[Point]
  var pinNode: seq[int]
  for pin in pins:
    let part = parts[pin.partIdx]
    let d = escapeDir(part, pin.pt)
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

  if pins.len < 2: return @[]

  var connected = newSeq[bool](pins.len)
  connected[0] = true
  var inTree = newSeq[bool](v)
  inTree[pinNode[0]] = true
  var first = true

  while true:
    var un = -1
    for i in 0 ..< pins.len:
      if not connected[i]: un = i; break
    if un < 0: break

    var sources: seq[int]
    for i in 0 ..< v:
      if inTree[i]: sources.add i

    let (dist, prev) = dijkstraFromSources(nodes, adj, sources, occ)

    var bestPin = -1
    var bestDist = Inf
    for i in 0 ..< pins.len:
      if connected[i]: continue
      let d = dist[pinNode[i]]
      if bestPin < 0 or d < bestDist - 1e-9 or
         (abs(d - bestDist) <= 1e-9 and i < bestPin):
        bestPin = i
        bestDist = d

    var pathIdx = pathTo(prev, pinNode[bestPin])
    if pathIdx.len == 0:
      # The free grid should always connect an escape point, but keep the old
      # fallback: route directly from the lowest-index tree node.
      pathIdx = @[sources[0], pinNode[bestPin]]

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
    result.add deduped

    for idx in pathIdx: inTree[idx] = true
    for k in 0 ..< deduped.len - 1:
      let a = deduped[k]
      let b = deduped[k + 1]
      addOcc(occ, a, b)
      # Every graph node that this new wire runs through is now part of the
      # net's tree, so a later wire may attach to any point along it (shared
      # vertex) instead of being forced to run along the same segment.
      for t in 0 ..< v:
        if not inTree[t] and pointOnSegment(nodes[t], a, b):
          inTree[t] = true
    connected[bestPin] = true

proc addSegments(adj: var Table[Point, HashSet[Point]], poly: seq[Point]) =
  for i in 0 ..< poly.len - 1:
    let p = poly[i]
    let q = poly[i + 1]
    if p == q: continue
    adj.mgetOrPut(p, initHashSet[Point]()).incl q
    adj.mgetOrPut(q, initHashSet[Point]()).incl p

proc cmpJunction(a, b: SchematicJunction): int =
  result = cmp(a.net, b.net)
  if result == 0: result = cmp(a.x, b.x)
  if result == 0: result = cmp(a.y, b.y)

proc pinKey(c: Component, pinName: string): string =
  ## A composite lookup key for a pin position, since ref objects are not
  ## hashable table keys. A designator is unique within a netlist and a pin
  ## name within a component, so the pair is unique.
  c.designator & "\x1f" & pinName

proc overlapsPlaced(i: int, x, y: float, pos: seq[Point],
                    ohw, ohh: seq[float]): bool =
  ## Whether the candidate centre `(x, y)` overlaps any already-placed
  ## component's inflated body (strict interior; touching is allowed).
  for j in 0 ..< i:
    if abs(x - pos[j].x) < ohw[i] + ohw[j] - 1e-9 and
       abs(y - pos[j].y) < ohh[i] + ohh[j] - 1e-9:
      return true
  false

proc rotatedSlot(s: Point, rot: float): Point =
  ## A pin slot after an SVG `rotate(rot)` around the part centre. `layout`
  ## only ever produces 0 or 90 here; 90 maps a +X slot to +Y (down, in the
  ## y-down world `svg.nim` uses), which is the same transform the body is
  ## drawn under, so a rotated symbol's pins and body cannot disagree.
  if abs(rot - 90.0) < 1e-9:
    Point(x: -s.y, y: s.x)
  else:
    s

proc rotationFor(partIdx: int, sd: SymbolDef, comp: Component,
                 comps: seq[Component], pos: seq[Point],
                 idxOf: Table[string, int]): float =
  ## 0 or 90 for a two-terminal, non-box symbol: the angle that puts its pin
  ## axis along the dominant direction of the parts around it. The dominant
  ## direction is the sum of the vectors to the *nearest* other part on each
  ## pin's net (Manhattan, ties broken toward the lowest component index), so
  ## a resistor in a chain follows the chain and never guesses from net names.
  ## A tie or a part with no neighbours keeps its default orientation.
  ##
  ## Only the square two-terminal symbols are eligible, so a 90-degree turn
  ## never changes `bodyW`/`bodyH` -- the separation and routing obstacle
  ## rects stay valid without a width/height swap.
  if sd.isBox or sd.slots.len != 2 or abs(sd.bodyW - sd.bodyH) > 1e-9:
    return 0.0
  let a = sd.slots[0]
  let b = sd.slots[1]
  let defaultAxisX = abs(a.x - b.x) >= abs(a.y - b.y)
  var fx, fy = 0.0
  var have = false
  for _, pin in comp.pins:
    if pin.net == nil: continue
    var best = Inf
    var bestJ = -1
    var bx, by = 0.0
    for other in pin.net.pins:
      if other.component == nil or
         other.component.designator == comp.designator:
        continue
      let j = idxOf.getOrDefault(other.component.designator, -1)
      if j < 0: continue
      let d = abs(pos[partIdx].x - pos[j].x) + abs(pos[partIdx].y - pos[j].y)
      if bestJ < 0 or d < best - 1e-9 or
         (abs(d - best) <= 1e-9 and j < bestJ):
        bestJ = j
        best = d
        bx = pos[j].x - pos[partIdx].x
        by = pos[j].y - pos[partIdx].y
    if bestJ >= 0:
      fx += bx
      fy += by
      have = true
  if not have: return 0.0
  let ax = abs(fx)
  let ay = abs(fy)
  if abs(ax - ay) <= 1e-9: return 0.0
  let flowAxisX = ax > ay
  if defaultAxisX != flowAxisX: 90.0 else: 0.0

proc layout*(nl: Netlist): Schematic =
  ## Places and routes `nl` into a renderer-neutral scene. Read-only with
  ## respect to the netlist; deterministic given the same netlist object.
  result.title = nl.name

  var comps: seq[Component]
  for _, c in nl.components: comps.add c
  let n = comps.len

  var syms = newSeq[SymbolDef](n)
  for i, c in comps: syms[i] = symbolFor(c)

  # --- placement: golden-angle seed, then Fruchterman-Reingold ------------
  var pos = newSeq[Point](n)
  for i in 0 ..< n:
    let t = float(i) * 2.399963229728653
    let r = 70.0 * sqrt(float(i + 1))
    pos[i] = Point(x: r * cos(t), y: r * sin(t))

  var idxOf = initTable[string, int]()
  for i, c in comps: idxOf[c.designator] = i

  let k = 110.0
  let iterations = 250
  let temp0 = 2.0 * k
  for it in 0 ..< iterations:
    let temp = temp0 * (1.0 - float(it) / float(iterations))
    var disp = newSeq[Point](n)

    for i in 0 ..< n:
      for j in i + 1 ..< n:
        let dx = pos[i].x - pos[j].x
        let dy = pos[i].y - pos[j].y
        var d = sqrt(dx * dx + dy * dy)
        if d < 0.01: d = 0.01
        let f = k * k / d
        let fx = dx / d * f
        let fy = dy / d * f
        disp[i].x += fx
        disp[i].y += fy
        disp[j].x -= fx
        disp[j].y -= fy

    for _, net in nl.nets:
      var idxs: seq[int]
      for p in net.pins:
        if p.component != nil and idxOf.hasKey(p.component.designator):
          let i = idxOf[p.component.designator]
          if idxs.len == 0 or idxs[^1] != i: idxs.add i
      if idxs.len < 2 or isGround(net): continue
      let w = if isRail(net): 0.35 else: 1.0
      for a in 0 ..< idxs.len:
        for b in a + 1 ..< idxs.len:
          let i = idxs[a]
          let j = idxs[b]
          let dx = pos[i].x - pos[j].x
          let dy = pos[i].y - pos[j].y
          var d = sqrt(dx * dx + dy * dy)
          if d < 0.01: d = 0.01
          let f = d * d / k * w
          let fx = dx / d * f
          let fy = dy / d * f
          disp[i].x -= fx
          disp[i].y -= fy
          disp[j].x += fx
          disp[j].y += fy

    for i in 0 ..< n:
      disp[i].x -= pos[i].x * 0.08
      disp[i].y -= pos[i].y * 0.08

    for i in 0 ..< n:
      let d = sqrt(disp[i].x * disp[i].x + disp[i].y * disp[i].y)
      if d > 0.0:
        let lim = min(d, temp)
        pos[i].x += disp[i].x / d * lim
        pos[i].y += disp[i].y / d * lim

  # Snap centres to the grid, normalising -0.0 away so hashing stays exact.
  for i in 0 ..< n:
    pos[i].x = round(pos[i].x / grid) * grid
    pos[i].y = round(pos[i].y / grid) * grid
    if abs(pos[i].x) < 1e-9: pos[i].x = 0.0
    if abs(pos[i].y) < 1e-9: pos[i].y = 0.0

  # --- separation: inflated bodies never overlap, channels remain ---------
  # Each component is placed in deterministic order at the nearest grid cell
  # whose inflated body is clear of every already-placed body. Searching an
  # expanding ring outward from the force-layout position keeps the result
  # close to the layout while guaranteeing non-overlap (no best-effort pass).
  var ohw = newSeq[float](n)
  var ohh = newSeq[float](n)
  for i in 0 ..< n:
    ohw[i] = syms[i].bodyW / 2.0 + placementPad
    ohh[i] = syms[i].bodyH / 2.0 + placementPad

  let maxR = max(64, 4 * n)
  for i in 0 ..< n:
    let cx = pos[i].x
    let cy = pos[i].y
    var done = false
    for r in 0 .. maxR:
      for dy in -r .. r:
        for dx in -r .. r:
          if max(abs(dx), abs(dy)) != r: continue
          let x = cx + float(dx) * grid
          let y = cy + float(dy) * grid
          if not overlapsPlaced(i, x, y, pos, ohw, ohh):
            pos[i] = Point(x: x, y: y)
            done = true
            break
        if done: break
      if done: break
    doAssert done,
      "schematic placement could not separate component " & comps[i].designator

  # --- orientation: two-terminal parts follow their neighbours ------------
  # Decided once the centres are final and before any pin position exists, so
  # the rule reads only placed centres -- never another part's already-chosen
  # rotation, which would make the result depend on part iteration order.
  var rots = newSeq[float](n)
  for i in 0 ..< n:
    rots[i] = rotationFor(i, syms[i], comps[i], comps, pos, idxOf)

  # --- parts, with absolute pin positions --------------------------------
  var pinPos = initTable[string, Point]()
  var partIdxByDesig = initTable[string, int]()
  for i, c in comps:
    let sd = syms[i]
    var sp = SchematicPart(designator: c.designator, kind: c.kind,
                           name: c.name, value: c.attrs.getOrDefault("value", ""),
                           symbol: sd.name, isBox: sd.isBox,
                           bodyW: sd.bodyW, bodyH: sd.bodyH,
                           x: pos[i].x, y: pos[i].y, rotation: rots[i])
    var pi = 0
    for pinName, p in c.pins:
      let slot0 =
        if sd.byName.len > 0: sd.byName[pinName]
        else: sd.slots[pi]
      let slot = rotatedSlot(slot0, rots[i])
      let px = pos[i].x + slot.x
      let py = pos[i].y + slot.y
      sp.pins.add SchematicPin(name: pinName, x: px, y: py,
                               net: (if p.net != nil: p.net.name else: ""))
      pinPos[pinKey(c, pinName)] = Point(x: px, y: py)
      inc pi
    partIdxByDesig[c.designator] = result.parts.len
    result.parts.add sp

  let obstacles = obstaclesFor(result.parts)
  let free = buildFreeGrid(obstacles)

  # --- routing ------------------------------------------------------------
  # Rail stubs are emitted first so their segments are occupied before any
  # signal route is planned; signal routes then avoid running along them.
  # Within each stub pass and signal pass the same deterministic order (net
  # iteration order, then pin order) drives occupancy, so the whole scene is
  # reproducible.
  var occ: seq[OccSeg]

  for _, net in nl.nets:
    var pins: seq[tuple[pt: Point, partIdx: int]]
    for p in net.pins:
      if p.component != nil:
        let key = pinKey(p.component, p.name)
        if pinPos.hasKey(key) and partIdxByDesig.hasKey(p.component.designator):
          pins.add (pt: pinPos[key],
                    partIdx: partIdxByDesig[p.component.designator])
    if pins.len == 0: continue

    if isGround(net):
      for pin in pins:
        let e = shortenedStubEnd(pin.pt, pinSpan, occ)
        result.wires.add SchematicWire(net: net.name, kind: wkGround,
                                       points: @[pin.pt, e])
        addOcc(occ, pin.pt, e)
    elif isRail(net):
      for pin in pins:
        let e = shortenedStubEnd(pin.pt, -pinSpan, occ)
        result.wires.add SchematicWire(net: net.name, kind: wkSupply,
                                       points: @[pin.pt, e])
        addOcc(occ, pin.pt, e)

  for _, net in nl.nets:
    if isGround(net) or isRail(net): continue
    var pins: seq[tuple[pt: Point, partIdx: int]]
    for p in net.pins:
      if p.component != nil:
        let key = pinKey(p.component, p.name)
        if pinPos.hasKey(key) and partIdxByDesig.hasKey(p.component.designator):
          pins.add (pt: pinPos[key],
                    partIdx: partIdxByDesig[p.component.designator])
    if pins.len < 2: continue
    var adj = initTable[Point, HashSet[Point]]()
    for poly in routeNet(pins, result.parts, obstacles, free, occ):
      result.wires.add SchematicWire(net: net.name, kind: wkSignal,
                                     points: poly)
      addSegments(adj, poly)
    for p, nbrs in adj:
      if nbrs.len >= 3:
        result.junctions.add SchematicJunction(net: net.name, x: p.x, y: p.y)

  result.junctions.sort(cmpJunction)

  # --- net labels (signal nets only; rails are labelled at their stub) ----
  for _, net in nl.nets:
    if isGround(net) or isRail(net): continue
    if net.name.len == 0: continue
    var anchor: Point
    var have = false
    for p in net.pins:
      let key = pinKey(p.component, p.name)
      if not pinPos.hasKey(key): continue
      let pt = pinPos[key]
      if not have or pt.x < anchor.x - 1e-9 or
         (abs(pt.x - anchor.x) <= 1e-9 and pt.y < anchor.y):
        anchor = pt
        have = true
    if have:
      result.labels.add SchematicLabel(text: net.name, x: anchor.x,
                                       y: anchor.y - 10.0)

  # --- bounding box -------------------------------------------------------
  var minX, minY, maxX, maxY: float
  var have = false
  proc includePt(x, y: float) =
    if not have:
      minX = x; maxX = x; minY = y; maxY = y; have = true
    else:
      if x < minX: minX = x
      if x > maxX: maxX = x
      if y < minY: minY = y
      if y > maxY: maxY = y
  for p in result.parts:
    includePt(p.x - p.bodyW / 2.0 - 50.0, p.y - p.bodyH / 2.0 - 50.0)
    includePt(p.x + p.bodyW / 2.0 + 50.0, p.y + p.bodyH / 2.0 + 50.0)
    for pin in p.pins: includePt(pin.x, pin.y)
  for w in result.wires:
    for pt in w.points: includePt(pt.x, pt.y)
  for j in result.junctions: includePt(j.x, j.y)
  for lb in result.labels: includePt(lb.x, lb.y)
  if not have:
    minX = 0.0; minY = 0.0; maxX = 200.0; maxY = 200.0
  const pad = 40.0
  result.minX = minX - pad
  result.minY = minY - pad
  result.maxX = maxX + pad
  result.maxY = maxY + pad
