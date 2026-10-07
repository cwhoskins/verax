const
  grid = 40.0
  pinSpan = 40.0
  routingClearance = 12.0
    ## Minimum distance a signal wire keeps from a component body. Routing
    ## obstacles are component bodies inflated by this amount on every side.
  freeGridMargin = 5
    ## Extra `grid`-step axes the Hanan grid adds outside the outermost
    ## obstacle/terminal on each side, so a route can wrap a part past a
    ## blocking glyph.
  portMinGap = 1.0 * grid
    ## Minimum centre-to-centre gap between two ports in one edge column
    ## (bodies are 24 tall). The spring relaxation never violates it.
  portSpringIters = 96
    ## Fixed sweeps for the port-column spring model (pull, then symmetric
    ## min-gap projection). A hard cap keeping `routeScene` pure and O(ports).
  portSpringRate = 0.4
    ## Fraction of the way a port moves toward its target per sweep; below 1
    ## so a coupled column settles without overshoot.
  portRefineRounds = 2
    ## Rounds of `refinePortPlacement`; a second exists because moving one
    ## net's ports re-routes what the next net is measured against.
  portRefineMaxAttempts = 24
    ## Cap on re-routes `refinePortPlacement` may run.
  portRefineCandidates = 2
    ## Ranked horizontal-run y's tried per net, besides the current y.
  wireMinSeparation = 8.0
    ## Minimum centreline distance between parallel, overlapping segments of
    ## different nets. Different nets may cross perpendicularly but never run
    ## closer than this or touch collinearly (even end-to-end). Within one net
    ## only positive-length collinear overlap is forbidden.
  placementPad = 20.0
    ## Placement inflates each body by this per side, leaving a channel wider
    ## than `routingClearance` between neighbours so a route fits.
  mergeMaxParts = 2
    ## Blocks of at most this many parts fold into the block holding their
    ## nearest power-rail net-mate (a decoupling cap belongs beside its part).
  groupGap = 2.0 * grid
    ## Gutter between shelf-packed block boxes; `>= 2 * placementPad`, so
    ## non-overlap survives the grid snap.
  packAspect = 1.2
    ## Shelf width as a multiple of `sqrt(total block area)`: slightly
    ## landscape.
  labelGap = 6.0
    ## Clearance between a label's text box and the drawn ink it names.
  designatorSize = 12.0
  valueSize = 10.0
  netLabelSize = 12.0
  labelLineGap = 2.0
    ## Vertical gap between a part's designator and value lines.
  glyphAspect = 0.6
    ## Monospace advance width as a fraction of font size.
  fallbackNetName = "\x1f_schematic_fallback"
    ## Sentinel net for sizing a fallback stub: every emitted wire counts as
    ## foreign, so the stub obeys the different-net rules.

type
  Obstacle = object
    ## A forbidden rectangle for signal routing: a body inflated by
    ## `routingClearance`.
    x1, y1, x2, y2: float

  OccSeg = object
    ## One emitted axis-aligned wire segment. Occupancy forbids positive-length
    ## collinear sharing between wires, plus `wireMinSeparation` rules across
    ## nets.
    a, b: Point
    net: string
      ## The segment's net: same-net contacts are allowed except positive-length
      ## collinear overlap.

proc sameCoord(a, b: float): bool {.inline.} = abs(a - b) < 1e-9

proc isGroundHere(net: Net): bool {.inline.} =
  ## `isGround` also fires on a net with any `ptGround` pin (an op-amp's
  ## `V-`), so an explicit `ntPower` kind wins: that net is a rail.
  net != nil and isGround(net) and net.kind != ntPower

proc isRailHere(net: Net): bool {.inline.} =
  net != nil and isRail(net) and not isGroundHere(net)

proc segBlocked(a, b: Point, obstacles: seq[Obstacle]): bool =
  ## True if segment `a`--`b` enters any obstacle's interior; running along
  ## an edge is allowed.
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
  ## True when two axis-aligned segments share a positive-length collinear
  ## portion (a single shared point is fine).
  let av = sameCoord(a.x, b.x)
  let cv = sameCoord(c.x, d.x)
  if av != cv: return false
  if av:
    return sameCoord(a.x, c.x) and positiveOverlap(a.y, b.y, c.y, d.y)
  else:
    return sameCoord(a.y, c.y) and positiveOverlap(a.x, b.x, c.x, d.x)

proc closedIntervalIntersect(a1, a2, b1, b2: float): bool {.inline.} =
  ## Whether `[a1, a2]` and `[b1, b2]` intersect, even at a single point.
  let lo = max(min(a1, a2), min(b1, b2))
  let hi = min(max(a1, a2), max(b1, b2))
  hi >= lo - 1e-9

proc collinearClosed(a, b, c, d: Point): bool =
  ## True when two segments are collinear and share any point, including an
  ## end-to-end touch. Used across nets only: a wire ending where another
  ## begins reads as one wire.
  let av = sameCoord(a.x, b.x)
  let cv = sameCoord(c.x, d.x)
  if av != cv: return false
  if av:
    return sameCoord(a.x, c.x) and closedIntervalIntersect(a.y, b.y, c.y, d.y)
  else:
    return sameCoord(a.y, c.y) and closedIntervalIntersect(a.x, b.x, c.x, d.x)

proc parallelTooClose(a, b, c, d: Point): bool =
  ## True when two segments are parallel on distinct lines closer than
  ## `wireMinSeparation` with overlapping projections. Perpendicular
  ## crossings never match.
  let av = sameCoord(a.x, b.x)
  let cv = sameCoord(c.x, d.x)
  if av != cv: return false
  if av:
    if sameCoord(a.x, c.x): return false            # collinear, handled above
    if abs(a.x - c.x) >= wireMinSeparation - 1e-9: return false
    return positiveOverlap(a.y, b.y, c.y, d.y)
  else:
    if sameCoord(a.y, c.y): return false
    if abs(a.y - c.y) >= wireMinSeparation - 1e-9: return false
    return positiveOverlap(a.x, b.x, c.x, d.x)

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

proc segmentsTouch(a, b, c, d: Point): bool =
  ## Whether two segments meet at all, endpoints included. Unlike occupancy,
  ## a perpendicular crossing counts: glyph ink isn't a wire crossing.
  let av = sameCoord(a.x, b.x)
  let cv = sameCoord(c.x, d.x)
  if av == cv:
    return collinearClosed(a, b, c, d)
  if av:
    return a.x >= min(c.x, d.x) - 1e-9 and a.x <= max(c.x, d.x) + 1e-9 and
           c.y >= min(a.y, b.y) - 1e-9 and c.y <= max(a.y, b.y) + 1e-9
  return c.x >= min(a.x, b.x) - 1e-9 and c.x <= max(a.x, b.x) + 1e-9 and
         a.y >= min(c.y, d.y) - 1e-9 and a.y <= max(c.y, d.y) + 1e-9

proc terminalGlyphSegments(w: SchematicWire): seq[OccSeg] =
  ## A terminal glyph's stem plus its bars, as signal routing blockers (a
  ## signal must not cross a terminal bar).
  if w.kind notin {wkGround, wkSupply} or w.points.len < 2: return
  let a = w.points[^2]
  let p = w.points[^1]
  let d = p - a
  let o = if abs(d.x) > abs(d.y):
            Point(x: (if d.x >= 0.0: 1.0 else: -1.0), y: 0.0)
          else:
            Point(x: 0.0, y: (if d.y >= 0.0: 1.0 else: -1.0))
  let q = Point(x: -o.y, y: o.x)
  result.add OccSeg(a: a, b: p, net: w.net)
  result.add OccSeg(a: p - q * 10.0, b: p + q * 10.0, net: w.net)
  if w.kind == wkGround:
    let p4 = p + o * 4.0
    let p8 = p + o * 8.0
    result.add OccSeg(a: p4 - q * 6.0, b: p4 + q * 6.0, net: w.net)
    result.add OccSeg(a: p8 - q * 2.0, b: p8 + q * 2.0, net: w.net)

proc shortenedGlyphStubEnd(p, e: Point, kind: WireKind,
                           netName: string, seeds: seq[OccSeg]): Point =
  ## Shorten a terminal stem whose bars would cover a fixed signal escape.
  let d = e - p
  let span = abs(d.x) + abs(d.y)
  if span < 1e-9: return e
  let dir = Point(x: d.x / span, y: d.y / span)
  for step in countdown(int(floor(span)), 0):
    let candidate = p + dir * float(step)
    let glyphs = terminalGlyphSegments(SchematicWire(net: netName, kind: kind,
                                                       points: @[p, candidate]))
    var clear = true
    for g in glyphs:
      for seed in seeds:
        if seed.net != netName and segmentsTouch(g.a, g.b, seed.a, seed.b):
          clear = false
          break
      if not clear: break
    if clear: return candidate
  p

proc edgeAllowed(a, b: Point, netName: string, occ, seeds,
                 glyphs: seq[OccSeg]): bool =
  ## A candidate edge is usable unless it collides with an emitted segment
  ## (the occupancy rules above) or runs along a positive-length part of an
  ## escape seed. Seeds are prospective stubs, so touching or crossing one
  ## is allowed, whatever its net.
  for s in occ:
    if s.net == netName:
      if collinearOverlap(a, b, s.a, s.b): return false
    else:
      if collinearClosed(a, b, s.a, s.b): return false
      if parallelTooClose(a, b, s.a, s.b): return false
  for s in seeds:
    if collinearOverlap(a, b, s.a, s.b): return false
  for g in glyphs:
    if segmentsTouch(a, b, g.a, g.b): return false
  true

proc addOcc(occ: var seq[OccSeg], a, b: Point, net: string) {.inline.} =
  if sameCoord(a.x, b.x) and sameCoord(a.y, b.y): return
  occ.add OccSeg(a: a, b: b, net: net)

type
  OccIndex = object
    ## `occ` bucketed by axis and fixed coordinate, for `dijkstraFromSources`,
    ## where a linear scan made routing O(nets^2). `seeds` and `glyphs` stay
    ## unindexed: they don't grow per net, and glyphs need the
    ## perpendicular-cross case this bucketing doesn't cover.
    byX: Table[int, seq[OccSeg]]
      ## Vertical segments (`sameCoord(a.x, b.x)`), bucketed on `bucketOf(x)`.
    byY: Table[int, seq[OccSeg]]
      ## Horizontal segments, bucketed on `bucketOf(y)`.

proc bucketOf(v: float): int {.inline.} =
  floor(v / wireMinSeparation).int

proc addToIndex(idx: var OccIndex, s: OccSeg) =
  if sameCoord(s.a.x, s.b.x):
    idx.byX.mgetOrPut(bucketOf(s.a.x), @[]).add s
  else:
    idx.byY.mgetOrPut(bucketOf(s.a.y), @[]).add s

proc buildOccIndex(occ: seq[OccSeg]): OccIndex =
  for s in occ: addToIndex(result, s)

proc edgeAllowedFast(a, b: Point, netName: string, occIdx: OccIndex,
                     seeds, glyphs: seq[OccSeg]): bool =
  ## `edgeAllowed` with `occ` read from `occIdx`. Every check needs a shared
  ## axis and a fixed coordinate within `wireMinSeparation`, so checking
  ## `bucket-1 .. bucket+1` is exactly as complete as a full scan.
  let vert = sameCoord(a.x, b.x)
  let coord = if vert: a.x else: a.y
  let tbl = if vert: occIdx.byX else: occIdx.byY
  let b0 = bucketOf(coord)
  for bk in b0 - 1 .. b0 + 1:
    let bucket = tbl.getOrDefault(bk)
    for s in bucket:
      if s.net == netName:
        if collinearOverlap(a, b, s.a, s.b): return false
      else:
        if collinearClosed(a, b, s.a, s.b): return false
        if parallelTooClose(a, b, s.a, s.b): return false
  for s in seeds:
    if collinearOverlap(a, b, s.a, s.b): return false
  for g in glyphs:
    if segmentsTouch(a, b, g.a, g.b): return false
  true

proc shortenedStubEnd(p, dir: Point, span: float, netName: string,
                      occ: seq[OccSeg]): Point =
  ## The end of a rail/ground stub from `p` along `dir` (the pin's outward
  ## escape, ±x/±y) for `span`, shortened just enough to obey the occupancy
  ## rules. Perpendicular segments are ignored.
  let vertical = abs(dir.y) > abs(dir.x)
  # 1-D coordinate `t` along `dir`: pin at 0, unshortened end at `span`.
  proc along(q: Point): float =
    if vertical: (q.y - p.y) * (if dir.y >= 0.0: 1.0 else: -1.0)
    else: (q.x - p.x) * (if dir.x >= 0.0: 1.0 else: -1.0)
  var limit = span
  for s in occ:
    let sVertical = sameCoord(s.a.x, s.b.x)
    let parallel = if vertical: sVertical else: not sVertical
    if not parallel: continue
    let collinear =
      if vertical: sameCoord(s.a.x, p.x)
      else: sameCoord(s.a.y, p.y)
    let ta = along(s.a)
    let tb = along(s.b)
    let o1 = min(ta, tb)
    let o2 = max(ta, tb)
    if s.net == netName:
      # Same net: only a positive-length collinear overlap is forbidden.
      if not collinear: continue
      if o2 <= 1e-9: continue               # entirely behind the pin
      if o1 >= span - 1e-9: continue        # entirely past the stub end
      limit = min(limit, max(0.0, o1))
    else:
      # Different net: no collinear touch; parallel runs keep
      # `wireMinSeparation`.
      if collinear:
        if o2 <= 1e-9: continue             # entirely behind the pin
        if o1 <= 1e-9:
          limit = 0.0                       # occupied reaches the pin itself
        else:
          limit = min(limit, max(0.0, o1 - 1e-6))
      else:
        if vertical:
          if abs(s.a.x - p.x) >= wireMinSeparation - 1e-9: continue
        else:
          if abs(s.a.y - p.y) >= wireMinSeparation - 1e-9: continue
        if o2 <= 1e-9: continue             # entirely behind the pin
        if o1 <= 1e-9:
          limit = 0.0                       # overlap starts at the pin
        else:
          limit = min(limit, max(0.0, o1))
  if vertical:
    Point(x: p.x, y: p.y + limit * (if dir.y >= 0.0: 1.0 else: -1.0))
  else:
    Point(x: p.x + limit * (if dir.x >= 0.0: 1.0 else: -1.0), y: p.y)

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

proc obstaclesOverlap(a, b: Obstacle): bool {.inline.} =
  ## Strict-interior overlap (touching edges are fine); the predicate
  ## `separate` legalizes against.
  a.x1 < b.x2 - 1e-9 and a.x2 > b.x1 + 1e-9 and
  a.y1 < b.y2 - 1e-9 and a.y2 > b.y1 + 1e-9

proc anyOverlap(a, b: seq[Obstacle]): bool =
  ## Multi-rect `obstaclesOverlap`, for a composite's footprint.
  for x in a:
    for y in b:
      if obstaclesOverlap(x, y): return true
  false

proc sideBandAllows(side: LayoutSide, x, halfWidth, leftSplit, rightSplit: float):
    bool =
  ## Whether a body centred at `x` respects the `layout.side` bands
  ## (`-Inf`/`Inf` when unused, so vacuous with no override). Used by the two
  ## movers that run after `enforceLayoutSides`.
  const eps = 1e-6
  case side
  of sideLeft: x + halfWidth <= leftSplit + eps
  of sideRight: x - halfWidth >= rightSplit - eps
  of sideAuto: x - halfWidth >= leftSplit - eps and x + halfWidth <= rightSplit + eps

proc powerBandAllows(isPower: bool, y, halfHeight, powerSplit: float): bool =
  ## Whether a body centred at `y` respects the power band (`powerSplit` is
  ## `Inf` when inactive). Takes a bare `bool` because this is spliced
  ## before `power.nim` defines `PowerClass`. Used by the two movers that
  ## run after `enforcePowerBand`.
  const eps = 1e-6
  if isPower: y - halfHeight >= powerSplit - eps
  else: y + halfHeight <= powerSplit + eps

proc buildFreeGrid(obstacles: seq[Obstacle], terminals: openArray[Point]):
    tuple[nodes: seq[Point], adj: seq[seq[int]]] =
  ## The Hanan grid: every inflated-obstacle boundary and terminal escape
  ## coordinate supplies an axis; points inside obstacles are dropped.
  ## Terminal axes let an off-centre pin turn after its stub. Adjacent
  ## visible nodes per axis suffice. A `freeGridMargin` ring of extra axes
  ## lets a route wrap around the outermost part.
  var xs: seq[float]
  var ys: seq[float]
  for o in obstacles:
    xs.add o.x1; xs.add o.x2
    ys.add o.y1; ys.add o.y2
  for terminal in terminals:
    xs.add terminal.x
    ys.add terminal.y
  xs.sort()
  ys.sort()
  var uxs: seq[float]
  var uys: seq[float]
  for x in xs:
    if uxs.len == 0 or not sameCoord(uxs[^1], x): uxs.add x
  for y in ys:
    if uys.len == 0 or not sameCoord(uys[^1], y): uys.add y

  # Add the margin ring; prepend/append keeps the axes sorted.
  if uxs.len > 0:
    var lo, hi: seq[float]
    for k in countdown(freeGridMargin, 1): lo.add uxs[0] - float(k) * grid
    for k in 1 .. freeGridMargin: hi.add uxs[^1] + float(k) * grid
    uxs = lo & uxs & hi
  if uys.len > 0:
    var lo, hi: seq[float]
    for k in countdown(freeGridMargin, 1): lo.add uys[0] - float(k) * grid
    for k in 1 .. freeGridMargin: hi.add uys[^1] + float(k) * grid
    uys = lo & uys & hi

  for x in uxs:
    for y in uys:
      let p = Point(x: x, y: y)
      if not insideAny(p, obstacles): result.nodes.add p

  let v = result.nodes.len
  result.adj = newSeq[seq[int]](v)
  var nodeAt = initTable[Point, int]()
  for i, p in result.nodes: nodeAt[p] = i

  # Linking only adjacent pairs: intervening collinear nodes add no length
  # or bends, and all-pairs is quadratic.
  template linkAdjacent(a, b: int) =
    if a >= 0 and b >= 0 and
       not segBlocked(result.nodes[a], result.nodes[b], obstacles):
      result.adj[a].add b
      result.adj[b].add a

  for x in uxs:
    var prev = -1
    for y in uys:
      let here = nodeAt.getOrDefault(Point(x: x, y: y), -1)
      if here >= 0:
        linkAdjacent(prev, here)
        prev = here
  for y in uys:
    var prev = -1
    for x in uxs:
      let here = nodeAt.getOrDefault(Point(x: x, y: y), -1)
      if here >= 0:
        linkAdjacent(prev, here)
        prev = here

