## Deterministic placement and routing: `Netlist` -> `Schematic`.
##
## Pure: it reads the graph through the public API, never mutates it, and
## touches no files, no clock and no simulator. The two passes follow the
## reference visualizer described in `docs/netlist-converter-research.md`: a
## Fruchterman-Reingold force layout seeded on a golden-angle spiral, then
## obstacle- and occupancy-aware orthogonal tree routing. The force layout's
## attraction acts **pin-to-pin**, not centre-to-centre: it needs each part's
## rotation, so orientation is co-optimised inside the loop -- every iteration
## re-picks each part's angle from `rotationChoices` (0/90/180/270) as the one
## minimising its pins' distance to their net-mates (`bestRotation`), read from
## a snapshot so the outcome never depends on part visit order. A parallel pair
## sharing two nets is then pulled by both wires at once and settles side by
## side rather than being tugged toward a single overlapping point. Placement
## ends with a deterministic separation pass so no two *inflated* component
## bodies ever overlap -- the inflation is the routing clearance below plus an
## extra channel -- and routing is obstacle-aware: a signal wire keeps the
## routing clearance from every component body and reaches each pin directly
## through a short outward stub. Between separation and the final rotation pass
## a packing pass groups the parts by signal-net connectivity (ground and rails
## excluded; a block of one or two parts is folded into the block holding its
## nearest power-rail net-mate) and shelf-packs the group bounding boxes -- but
## keeps the result only when it is smaller than what the force layout
## produced, so a design whose blocks were already pulled together by a shared
## rail is left alone. Once the centres are final each eligible two-terminal
## part gets its definitive orientation from the same `bestRotation` test; the
## angle is written into `SchematicPart.rotation` and its pin slots rotated
## with it, so routing, obstacle avoidance and rendering all agree. Only the
## square two-terminal symbols rotate, so a quarter turn never swaps
## `bodyW`/`bodyH` and the obstacle rects stay valid. Every step is
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
  mergeMaxParts = 2
    ## A block of at most this many parts is folded into the block holding its
    ## nearest power-rail net-mate rather than packed on its own -- a
    ## decoupling cap, a pull-up pair or a series termination belongs beside
    ## the part it serves, not on a shelf of its own. Anything larger is a
    ## block in its own right.
  groupGap = 2.0 * grid
    ## The gutter kept between two block bounding boxes when they are
    ## shelf-packed. `2 * grid` is `>= 2 * placementPad`, so a cross-group
    ## part pair still clears `ohw + ohw` on the separating axis and the
    ## non-overlap invariant holds through the grid snap.
  packAspect = 1.2
    ## Shelf width as a multiple of `sqrt(total inflated block area)`: a
    ## slightly landscape sheet, the shape a schematic is printed on.

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

proc overlapsAny(i: int, x, y: float, pos: seq[Point],
                 ohw, ohh: seq[float], against: openArray[int]): bool =
  ## Whether the candidate centre `(x, y)` for part `i` overlaps the inflated
  ## body of any part named in `against` (strict interior; touching is
  ## allowed). `i` itself is skipped if listed. The separation pass passes the
  ## indices it has already placed; taking an explicit list rather than
  ## hard-coding `0 ..< i` keeps the non-overlap check reusable by a later
  ## pass that places parts in a different order.
  for j in against:
    if j == i: continue
    if abs(x - pos[j].x) < ohw[i] + ohw[j] - 1e-9 and
       abs(y - pos[j].y) < ohh[i] + ohh[j] - 1e-9:
      return true
  false

proc rotatedSlot(s: Point, rot: float): Point =
  ## A pin slot after an SVG `rotate(rot)` around the part centre, for `rot` one
  ## of {0, 90, 180, 270}. In the y-down world `svg.nim` uses, `rotate(90)`
  ## sends a +X slot to +Y -- the same transform the body is drawn under, so a
  ## rotated symbol's pins and body cannot disagree. Only the square
  ## two-terminal symbols are ever rotated, so 90/270 swapping `bodyW`/`bodyH`
  ## does not matter (they are equal) and the obstacle rects stay valid.
  if abs(rot - 90.0) < 1e-9: Point(x: -s.y, y: s.x)
  elif abs(rot - 180.0) < 1e-9: Point(x: -s.x, y: -s.y)
  elif abs(rot - 270.0) < 1e-9: Point(x: s.y, y: -s.x)
  else: s

const rotationChoices = [0.0, 90.0, 180.0, 270.0]

proc rotatable(sd: SymbolDef): bool {.inline.} =
  ## A symbol is turned only when it is a square two-terminal non-box: a
  ## quarter turn then never changes `bodyW`/`bodyH`, so the separation and
  ## routing obstacle rects stay valid without a width/height swap, and every
  ## one of the four orientations is a distinct, meaningful pin assignment.
  not sd.isBox and sd.slots.len == 2 and abs(sd.bodyW - sd.bodyH) <= 1e-9

proc slotOf(sd: SymbolDef, pinName: string, ordinal: int): Point {.inline.} =
  if sd.byName.len > 0: sd.byName[pinName] else: sd.slots[ordinal]

proc pinWorldPositions(comps: seq[Component], syms: seq[SymbolDef],
                       pos: seq[Point], rots: seq[float]):
    Table[string, Point] =
  ## Every pin's world position given the current centres and rotations. The
  ## pin-level attraction force and the rotation search both read net-mates'
  ## pin positions out of this, rebuilt once per force-layout iteration.
  result = initTable[string, Point]()
  for i, c in comps:
    var ord = 0
    for pinName, _ in c.pins:
      result[pinKey(c, pinName)] =
        pos[i] + rotatedSlot(slotOf(syms[i], pinName, ord), rots[i])
      inc ord

proc rotationScore(sd: SymbolDef, comp: Component, centre: Point, angle: float,
                   pinWorld: Table[string, Point]): float =
  ## Total Manhattan distance from each of this part's pins, placed at `angle`,
  ## to the centroid of the *other* pins on that pin's net. Minimising it over
  ## the four orientations picks both the pin axis and which end each pin takes
  ## -- a flip falls out when it shortens the wires, with no separate rule.
  var ord = 0
  for pinName, p in comp.pins:
    let mine = centre + rotatedSlot(slotOf(sd, pinName, ord), angle)
    inc ord
    if p.net == nil: continue
    var cx, cy = 0.0
    var cnt = 0
    for other in p.net.pins:
      if other.component == nil or
         other.component.designator == comp.designator: continue
      let key = pinKey(other.component, other.name)
      if not pinWorld.hasKey(key): continue
      cx += pinWorld[key].x
      cy += pinWorld[key].y
      inc cnt
    if cnt == 0: continue
    result += abs(mine.x - cx / float(cnt)) + abs(mine.y - cy / float(cnt))

proc bestRotation(sd: SymbolDef, comp: Component, centre: Point, current: float,
                  pinWorld: Table[string, Point], margin: float): float =
  ## The orientation in `rotationChoices` with the lowest `rotationScore`, ties
  ## broken toward the smaller angle. `margin` is hysteresis: the incumbent
  ## `current` is only abandoned when the best alternative beats it by more
  ## than `margin`, so a part cannot flip back and forth between iterations on
  ## a sub-grid difference.
  if not rotatable(sd): return 0.0
  var bestAngle = 0.0
  var bestScore = Inf
  for angle in rotationChoices:
    let s = rotationScore(sd, comp, centre, angle, pinWorld)
    if s < bestScore - 1e-9 or (abs(s - bestScore) <= 1e-9 and angle < bestAngle):
      bestScore = s
      bestAngle = angle
  if abs(bestAngle - current) < 1e-9: return current
  if bestScore <= rotationScore(sd, comp, centre, current, pinWorld) - margin:
    bestAngle
  else:
    current

proc ufFind(parent: var seq[int], x: int): int =
  ## Union-find root with path compression. The root of a class is always its
  ## smallest member index (see `ufUnion`), so a class id is a stable function
  ## of the partition alone -- never of the order the unions happened in.
  var r = x
  while parent[r] != r: r = parent[r]
  var c = x
  while parent[c] != c:
    let nxt = parent[c]
    parent[c] = r
    c = nxt
  r

proc ufUnion(parent: var seq[int], a, b: int) =
  let ra = ufFind(parent, a)
  let rb = ufFind(parent, b)
  if ra == rb: return
  if ra < rb: parent[rb] = ra else: parent[ra] = rb

proc groupsOf(nl: Netlist, comps: seq[Component], pos: seq[Point],
              idxOf: Table[string, int]): seq[int] =
  ## A group id per part. Parts joined by a *signal* net (ground and rails
  ## excluded -- neither is routed as a tree) are one group; then every group
  ## of at most `mergeMaxParts` parts is folded into the group holding its
  ## nearest power-rail net-mate, so a decoupling cap or a pull-up is not
  ## stranded away from the IC it serves. Ids are renumbered by ascending
  ## lowest-member index. Fully deterministic: union-find over a fixed edge
  ## set, merge decisions taken against a snapshot of the pre-merge partition.
  let n = comps.len
  var parent = newSeq[int](n)
  for i in 0 ..< n: parent[i] = i

  proc members(net: Net): seq[int] =
    for p in net.pins:
      if p.component != nil and idxOf.hasKey(p.component.designator):
        let i = idxOf[p.component.designator]
        if result.len == 0 or i notin result: result.add i

  for _, net in nl.nets:
    if isGround(net) or isRail(net): continue
    let m = members(net)
    for a in 1 ..< m.len: ufUnion(parent, m[0], m[a])

  # Fold small groups into the group of their nearest power-rail net-mate.
  # Every decision is computed against the current (pre-merge) partition and
  # only applied afterwards, so the outcome cannot depend on merge order.
  var size = newSeq[int](n)
  for i in 0 ..< n: inc size[ufFind(parent, i)]
  var mergeTo = newSeq[int](n)
  for i in 0 ..< n: mergeTo[i] = -1
  for root in 0 ..< n:
    if ufFind(parent, root) != root: continue
    if size[root] == 0 or size[root] > mergeMaxParts: continue
    var cx, cy = 0.0
    for j in 0 ..< n:
      if ufFind(parent, j) == root:
        cx += pos[j].x
        cy += pos[j].y
    cx /= float(size[root])
    cy /= float(size[root])
    var bestQ = -1
    var bestD = Inf
    for _, net in nl.nets:
      if not isRail(net) or isGround(net): continue
      let m = members(net)
      var touchesRoot = false
      for q in m:
        if ufFind(parent, q) == root: touchesRoot = true
      if not touchesRoot: continue
      for q in m:
        if ufFind(parent, q) == root: continue
        let d = abs(pos[q].x - cx) + abs(pos[q].y - cy)
        if bestQ < 0 or d < bestD - 1e-9 or
           (abs(d - bestD) <= 1e-9 and q < bestQ):
          bestQ = q
          bestD = d
    mergeTo[root] = bestQ
  for root in 0 ..< n:
    if mergeTo[root] >= 0: ufUnion(parent, root, mergeTo[root])

  # Renumber: roots are minimal member indices, so scanning 0 ..< n meets them
  # in ascending order and the first-seen order is the id order.
  var gid = initTable[int, int]()
  result = newSeq[int](n)
  for i in 0 ..< n:
    let r = ufFind(parent, i)
    if not gid.hasKey(r): gid[r] = gid.len
  for i in 0 ..< n:
    result[i] = gid[ufFind(parent, i)]

proc packGroups(pos: var seq[Point], ohw, ohh: seq[float], group: seq[int]) =
  ## Shelf-packs the per-group inflated bounding boxes with a `groupGap`
  ## gutter, translating each group by a grid-snapped delta -- but only if the
  ## packed arrangement is *smaller* than what the force layout produced.
  ##
  ## The force layout keeps disconnected blocks apart by repulsion alone (the
  ## only counter-force is a weak gravity), so on a design with genuinely
  ## independent sub-circuits it leaves a page of empty space between them;
  ## re-packing collapses that. But when the blocks are already close --
  ## pulled together by a shared rail -- re-packing would scatter a sensible
  ## arrangement, so the total-area guard reverts to the force layout in that
  ## case. Deterministic: the guard is a pure comparison of two bounding-box
  ## areas.
  ##
  ## Each translation is rigid, so intra-group geometry -- and the separation
  ## invariant it satisfies -- is untouched; the shelves make boxes x-disjoint
  ## within a row and y-disjoint across rows with `groupGap` between, so any
  ## cross-group part pair clears `ohw[i] + ohw[j]` on the separating axis.
  let n = pos.len
  var ng = 0
  for g in group: ng = max(ng, g + 1)
  if ng <= 1: return

  var minX = newSeq[float](ng)
  var minY = newSeq[float](ng)
  var maxX = newSeq[float](ng)
  var maxY = newSeq[float](ng)
  for g in 0 ..< ng:
    minX[g] = Inf; minY[g] = Inf; maxX[g] = -Inf; maxY[g] = -Inf
  for i in 0 ..< n:
    let g = group[i]
    minX[g] = min(minX[g], pos[i].x - ohw[i])
    minY[g] = min(minY[g], pos[i].y - ohh[i])
    maxX[g] = max(maxX[g], pos[i].x + ohw[i])
    maxY[g] = max(maxY[g], pos[i].y + ohh[i])

  proc spanArea(): float =
    var x1 = Inf
    var y1 = Inf
    var x2 = -Inf
    var y2 = -Inf
    for g in 0 ..< ng:
      x1 = min(x1, minX[g]); y1 = min(y1, minY[g])
      x2 = max(x2, maxX[g]); y2 = max(y2, maxY[g])
    (x2 - x1) * (y2 - y1)
  let beforeArea = spanArea()

  var totalArea, widest = 0.0
  for g in 0 ..< ng:
    let w = maxX[g] - minX[g]
    totalArea += w * (maxY[g] - minY[g])
    widest = max(widest, w)
  let shelfWidth = max(widest, ceil(packAspect * sqrt(totalArea) / grid) * grid)

  var order = newSeq[int](ng)
  for g in 0 ..< ng: order[g] = g
  order.sort(proc (a, b: int): int =
    result = cmp(maxY[b] - minY[b], maxY[a] - minY[a])
    if result == 0: result = cmp(a, b))

  var dx = newSeq[float](ng)
  var dy = newSeq[float](ng)
  var curX, curY, rowH = 0.0
  for g in order:
    let w = maxX[g] - minX[g]
    let h = maxY[g] - minY[g]
    if curX > 1e-9 and curX + w > shelfWidth:
      curY += rowH + groupGap
      curX = 0.0
      rowH = 0.0
    dx[g] = round((curX - minX[g]) / grid) * grid
    dy[g] = round((curY - minY[g]) / grid) * grid
    curX += w + groupGap
    rowH = max(rowH, h)

  block:
    var x1 = Inf
    var y1 = Inf
    var x2 = -Inf
    var y2 = -Inf
    for g in 0 ..< ng:
      x1 = min(x1, minX[g] + dx[g]); y1 = min(y1, minY[g] + dy[g])
      x2 = max(x2, maxX[g] + dx[g]); y2 = max(y2, maxY[g] + dy[g])
    if (x2 - x1) * (y2 - y1) >= beforeArea - 1e-6: return

  for i in 0 ..< n:
    let g = group[i]
    pos[i].x += dx[g]
    pos[i].y += dy[g]
    if abs(pos[i].x) < 1e-9: pos[i].x = 0.0
    if abs(pos[i].y) < 1e-9: pos[i].y = 0.0

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

  # Orientation is co-optimised with placement: the attraction force below acts
  # pin-to-pin, so it needs each part's rotation, and the rotation that
  # minimises a part's wire depends on where its neighbours have been pushed.
  # Each iteration re-picks every rotation from a *snapshot* of the current
  # centres and rotations (fresh-write, snapshot-read), so the result never
  # depends on the order parts are visited. The last stretch of iterations
  # leaves rotation frozen so the centres settle against a fixed orientation,
  # and a final pass after separation gives the definitive assignment.
  var rots = newSeq[float](n)

  let k = 110.0
  let iterations = 250
  let temp0 = 2.0 * k
  for it in 0 ..< iterations:
    let temp = temp0 * (1.0 - float(it) / float(iterations))
    var disp = newSeq[Point](n)

    if it < iterations - 30:
      let pw = pinWorldPositions(comps, syms, pos, rots)
      var newRots = rots
      for i in 0 ..< n:
        newRots[i] = bestRotation(syms[i], comps[i], pos[i], rots[i], pw, grid)
      rots = newRots
    let pinWorld = pinWorldPositions(comps, syms, pos, rots)

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
      if isGround(net): continue
      let w = if isRail(net): 0.35 else: 1.0
      # Pin-to-pin, not centre-to-centre: a net with pins on three parts pulls
      # each pair together, and a parallel pair sharing two nets is pulled by
      # both wires at once -- so its lowest-energy rest is the two parts side
      # by side with both pin pairs short, which centre-to-centre could never
      # express (both nets were the same centre vector, i.e. one doubled tug
      # toward overlap).
      let ps = net.pins
      for a in 0 ..< ps.len:
        for b in a + 1 ..< ps.len:
          let ca = ps[a].component
          let cb = ps[b].component
          if ca == nil or cb == nil or ca.designator == cb.designator: continue
          if not (idxOf.hasKey(ca.designator) and
                  idxOf.hasKey(cb.designator)): continue
          let i = idxOf[ca.designator]
          let j = idxOf[cb.designator]
          let pa = pinWorld.getOrDefault(pinKey(ca, ps[a].name), pos[i])
          let pb = pinWorld.getOrDefault(pinKey(cb, ps[b].name), pos[j])
          let dx = pa.x - pb.x
          let dy = pa.y - pb.y
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
  var placed: seq[int]
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
          if not overlapsAny(i, x, y, pos, ohw, ohh, placed):
            pos[i] = Point(x: x, y: y)
            done = true
            break
        if done: break
      if done: break
    doAssert done,
      "schematic placement could not separate component " & comps[i].designator
    placed.add i

  # --- packing: blocks that share no signal net are pulled back together --
  # The force layout's only long-range counter-force is a weak gravity, so
  # two disconnected sub-circuits drift as far apart as the repulsion carries
  # them. Group the parts by signal-net connectivity and shelf-pack the group
  # bounding boxes with a fixed gutter. A rigid grid-snapped translation per
  # group, so separation and the grid snap both survive it.
  let group = groupsOf(nl, comps, pos, idxOf)
  packGroups(pos, ohw, ohh, group)

  # --- orientation: the definitive assignment once the centres are final ---
  # Separation and packing have moved parts since the loop froze rotation, so
  # re-pick every one from the settled centres. One pass, snapshot-read and
  # fresh-write like the loop, and with no hysteresis -- this is the answer,
  # not an increment toward it.
  block:
    let pw = pinWorldPositions(comps, syms, pos, rots)
    var newRots = rots
    for i in 0 ..< n:
      newRots[i] = bestRotation(syms[i], comps[i], pos[i], rots[i], pw, 0.0)
    rots = newRots

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

  # Every signal pin leaves its body through a short stub in a fixed
  # direction; a ground or supply stub must not run along one of those, or two
  # different nets share a collinear segment. Seed the shortening test with
  # them (they are not added to `occ` -- the signal route re-adds its own).
  var escapeSeeds: seq[OccSeg]
  for _, net in nl.nets:
    if isGround(net) or isRail(net): continue
    for p in net.pins:
      if p.component == nil: continue
      let key = pinKey(p.component, p.name)
      if not (pinPos.hasKey(key) and
              partIdxByDesig.hasKey(p.component.designator)): continue
      let pt = pinPos[key]
      let part = result.parts[partIdxByDesig[p.component.designator]]
      addOcc(escapeSeeds, pt, pt + escapeDir(part, pt) * routingClearance)

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
        let e = shortenedStubEnd(pin.pt, pinSpan, occ & escapeSeeds)
        result.wires.add SchematicWire(net: net.name, kind: wkGround,
                                       points: @[pin.pt, e])
        addOcc(occ, pin.pt, e)
    elif isRail(net):
      for pin in pins:
        let e = shortenedStubEnd(pin.pt, -pinSpan, occ & escapeSeeds)
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
