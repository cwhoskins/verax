const
  grid = 40.0
  pinSpan = 40.0
  routingClearance = 12.0
    ## Minimum distance a signal wire keeps from a component body. Routing
    ## obstacles are component bodies inflated by this amount on every side.
  freeGridMargin = 5
    ## How many `grid`-step axes the Hanan free grid (`buildFreeGrid`) adds
    ## outside the extreme obstacle/terminal coordinates on each side. The bare
    ## grid stops at the outermost obstacle edge or rail/ground glyph bar, so a
    ## route that must wrap a part -- a pass-through strap wired to ports on
    ## both sides -- has no track to turn on past the glyph blocking the
    ## centreline. Five steps clears any single glyph plus a detour lane.
  portMinGap = 1.0 * grid
    ## Minimum vertical centre-to-centre distance between two interface-port
    ## bodies stacked in one edge column. A port body is `bodyH` (24) tall, so
    ## one `grid` step leaves a clear gap. This is the collision distance the
    ## port spring relaxation (`routeScene`) may never violate.
  portSpringIters = 96
    ## Fixed relaxation sweeps for the port-column spring model: each sweep is
    ## a spring pull toward the target y followed by a symmetric forward /
    ## backward min-gap projection. A hard cap that keeps `routeScene` pure and
    ## O(ports); a handful of ports converge in far fewer.
  portSpringRate = 0.4
    ## Fraction of the way each port moves toward its target y per relaxation
    ## sweep. Below 1 so a column of ports coupled by the min-gap settles
    ## together rather than one port overshooting and bouncing.
  portRefineRounds = 2
    ## Measure/move sweeps the post-route port pass (`refinePortPlacement`)
    ## makes over the sheet. A second round exists because moving one net's
    ## ports re-routes the sheet the next net is then measured against.
  portRefineMaxAttempts = 24
    ## Hard cap on the `routeScene` re-routes `refinePortPlacement` may run,
    ## the post-route analogue of `feedbackAttemptBudget`.
  portRefineCandidates = 2
    ## Ranked horizontal-run y's tried per net by `refinePortPlacement`,
    ## besides the port's current y.
  wireMinSeparation = 8.0
    ## Minimum centreline distance between two parallel, projection-overlapping
    ## segments of *different* nets. Two different nets may still cross
    ## perpendicularly, but may never run side by side closer than this and may
    ## never touch collinearly (not even end-to-end). Within one net only a
    ## positive-length collinear overlap is forbidden, so the tree's own
    ## branches may attach at, and continue straight through, a shared vertex.
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
  labelGap = 6.0
    ## Clearance between a label's text box and the drawn ink it names.
  designatorSize = 12.0
  valueSize = 10.0
  netLabelSize = 12.0
  labelLineGap = 2.0
    ## Vertical space between the designator and value lines of one part's
    ## stacked label block.
  glyphAspect = 0.6
    ## Monospace advance width as a fraction of font size -- matches the
    ## per-character estimates already used for box pin names (`sideChars *
    ## 6.0` at size 9) and port bodies (`portName.len * 8.0` at size 10).
  fallbackNetName = "\x1f_schematic_fallback"
    ## A sentinel net name passed to `shortenedStubEnd` when sizing a
    ## fallback stub. A fallback is not connectivity, so every already-emitted
    ## wire is treated as a *foreign* net: the stub must never touch one
    ## collinearly and must keep `wireMinSeparation` from parallel runs,
    ## exactly like a real route across two nets.

type
  Obstacle = object
    ## An axis-aligned forbidden rectangle for signal routing: a component
    ## body inflated by `routingClearance`.
    x1, y1, x2, y2: float

  OccSeg = object
    ## One already-emitted axis-aligned wire segment. Occupancy is what stops
    ## two distinct `SchematicWire` objects from ever sharing a positive-length
    ## collinear segment, and across different nets it enforces the stronger
    ## `wireMinSeparation` rule: a new route may cross an occupied segment
    ## perpendicularly, but if it runs parallel to one it must stay at least
    ## `wireMinSeparation` away wherever their projections overlap, and two
    ## different nets may never touch collinearly -- not even end-to-end.
    a, b: Point
    net: string
      ## The net this segment belongs to. Same-net contacts are allowed except
      ## for a positive-length collinear overlap; different-net contacts are
      ## held to the stronger rules above.

proc sameCoord(a, b: float): bool {.inline.} = abs(a - b) < 1e-9

proc isGroundHere(net: Net): bool {.inline.} =
  ## `isGround` also fires on a net that merely has a `ptGround`-kinded pin --
  ## an op-amp's `V-` supply pin, say -- so an explicitly `ntPower` net would
  ## be drawn with a ground glyph instead of its rail stub. An explicit net
  ## kind wins here: a `ptGround` pin on a power net makes it a rail, not
  ## ground.
  ##
  ## Hoisted here from what were verbatim-duplicate local closures in
  ## `routing.nim` and `finish.nim`: `bundles.nim` is the third consumer (a
  ## rail member declines a whole bundle), and three copies of a one-liner is
  ## the trigger `schematic/CLAUDE.md` already flags.
  net != nil and isGround(net) and net.kind != ntPower

proc isRailHere(net: Net): bool {.inline.} =
  net != nil and isRail(net) and not isGroundHere(net)

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
  ## overlap, which is what lets two wires of the *same* net meet at a vertex.
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
  ## True when the axis-aligned segments `a`-`b` and `c`-`d` lie on the same
  ## line and their intervals share any point -- a positive-length overlap *or*
  ## an end-to-end touch. The stronger form of `collinearOverlap`, used only
  ## across different nets: two different nets may not touch collinearly at
  ## all, because a wire ending where another begins reads as one continuous
  ## wire.
  let av = sameCoord(a.x, b.x)
  let cv = sameCoord(c.x, d.x)
  if av != cv: return false
  if av:
    return sameCoord(a.x, c.x) and closedIntervalIntersect(a.y, b.y, c.y, d.y)
  else:
    return sameCoord(a.y, c.y) and closedIntervalIntersect(a.x, b.x, c.x, d.x)

proc parallelTooClose(a, b, c, d: Point): bool =
  ## True when the two axis-aligned segments are parallel (same axis) on
  ## distinct lines whose centreline separation is below `wireMinSeparation`,
  ## and their projections along that axis overlap by more than a point.
  ## Perpendicular segments never match (the axes differ), so a perpendicular
  ## crossing stays allowed.
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
  ## Whether two non-zero axis-aligned segments meet at all, including at an
  ## endpoint. Unlike wire occupancy, this deliberately treats a perpendicular
  ## crossing as contact: terminal glyph ink is not a wire crossing.
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
  ## The complete visible terminal glyph: its stem plus the bar(s) SVG draws
  ## at the stem's far end. These are routing blockers for signals, rather
  ## than ordinary occupancy, because a signal must not cross a terminal bar.
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
  ## Shorten a terminal stem when its bars would cover a fixed signal escape.
  ## Signal escapes are emitted unchanged, so the terminal yields instead.
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
  ## A candidate routing edge is usable unless it collides with an already
  ## emitted segment or threads a fixed escape seed. Within one net only a
  ## positive-length collinear overlap is forbidden (a new branch may attach
  ## at, and continue straight through, a shared vertex). Across different
  ## nets the rule is stronger: a perpendicular crossing stays allowed, but a
  ## collinear touch -- even end-to-end -- is forbidden, and a parallel
  ## segment must keep at least `wireMinSeparation` of centreline separation
  ## wherever its projection overlaps an occupied segment's.
  ##
  ## Escape seeds are *prospective* stubs, not emitted wires, so the stronger
  ## different-net rule does not apply to them: a route may touch a foreign
  ## seed at an endpoint and may cross it perpendicularly, but may not run
  ## along any positive-length part of it -- the seed's open interior must
  ## stay clear for the net that owns it. Same-net seeds obey the same
  ## positive-length-only rule, so the net tag is irrelevant here (it still
  ## matters for the rail/ground stub shortening test).
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
    ## `occ` bucketed by axis and fixed coordinate, for the one hot caller --
    ## `dijkstraFromSources`, which calls `edgeAllowed` once per candidate
    ## graph edge and, unlike `seeds`/`glyphs`, sees `occ` grow by one segment
    ## per already-routed net. A linear scan of `occ` there made routing a
    ## sheet's Nth net cost O(N) more than its first, and the whole net list
    ## O(nets^2) net-to-net.
    ##
    ## Only `occ` is indexed: `seeds` and `glyphs` are rebuilt once per
    ## `routeScene` call from the sheet's pins and already-drawn rail glyphs,
    ## so neither grows with the net being routed and a flat scan of either
    ## stays cheap. `glyphs` also needs `segmentsTouch`'s perpendicular-cross
    ## case (a horizontal glyph can block a vertical query edge that shares
    ## none of its coordinates), which this bucketing -- keyed on the query
    ## edge's own axis -- does not cover; leaving it unindexed keeps that
    ## case correct without needing a second, differently-shaped index.
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
  ## Same test as `edgeAllowed`, `occ` read from `occIdx` instead of a flat
  ## seq. Every check below (`collinearOverlap`, `collinearClosed`,
  ## `parallelTooClose`) requires the two segments to share an axis, and
  ## either an exact fixed coordinate or one within `wireMinSeparation` of
  ## it -- so a candidate can only ever be a same-net, same-bucket entry two
  ## buckets away in either direction: any pair of coordinates closer than a
  ## bucket's width lands at most one bucket apart (a one-line pigeonhole
  ## argument on `bucketOf`), and a `sameCoord` pair that straddles a bucket
  ## boundary is the same case. Checking `bucket-1 .. bucket+1` is therefore
  ## exactly as complete as scanning every entry, at a fraction of the cost
  ## once `occ` is long.
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
  ## The end of a rail/ground stub leaving `p` along axis unit vector `dir`
  ## (one of ±x / ±y) for `span`, shortened just enough that it violates no
  ## occupancy rule. A perpendicular occupied segment is ignored (a crossing
  ## is allowed). Against a segment of the *same* net only a positive-length
  ## collinear overlap shortens the stub; against a segment of a *different*
  ## net a collinear touch -- even end-to-end -- shortens it, and a parallel
  ## segment closer than `wireMinSeparation` shortens it to just before the
  ## two projections overlap.
  ##
  ## `dir` is the pin's outward escape direction, so the stub always juts away
  ## from the body -- a negative-supply pin on a box's bottom edge stubs
  ## *down*, not up through the body.
  let vertical = abs(dir.y) > abs(dir.x)
  # Work in a 1-D coordinate `t` along `dir`: the pin is at t = 0, the
  # unshortened end at t = span, and an obstacle interval [o1, o2].
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
      # Different net: no collinear touch, and parallel projections must keep
      # `wireMinSeparation` of centreline separation.
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
  ## Strict-interior overlap: touching edges are not a conflict, only a
  ## positive-area intersection is. The same predicate `separate` legalizes
  ## placement against.
  a.x1 < b.x2 - 1e-9 and a.x2 > b.x1 + 1e-9 and
  a.y1 < b.y2 - 1e-9 and a.y2 > b.y1 + 1e-9

proc anyOverlap(a, b: seq[Obstacle]): bool =
  ## Whether any rect of `a` has a strict-interior overlap with any rect of
  ## `b` -- the multi-rect generalization of `obstaclesOverlap`, for a
  ## composite unit's footprint (`seq[Obstacle]` since a future non-rectangular
  ## reservation may need more than one rect).
  for x in a:
    for y in b:
      if obstaclesOverlap(x, y): return true
  false

proc sideBandAllows(side: LayoutSide, x, halfWidth, leftSplit, rightSplit: float):
    bool =
  ## Whether an inflated body centred at `x` with the given `halfWidth`
  ## respects the `layout.side` band `enforceLayoutSides` established --
  ## `leftSplit`/`rightSplit` default to `-Inf`/`Inf` when the corresponding
  ## side is unused, so this is vacuously true on every sheet with no
  ## override. `LayoutSide` is a real top-level import
  ## (`netlist/layouthints`), not something `include`d, so this is callable
  ## from every included unit regardless of splice order. Shared by
  ## `repairTerminalClearance` and `recoverRouting`'s candidate-cell filters,
  ## the two movers that run after `enforceLayoutSides` and could otherwise
  ## undo its guarantee.
  const eps = 1e-6
  case side
  of sideLeft: x + halfWidth <= leftSplit + eps
  of sideRight: x - halfWidth >= rightSplit - eps
  of sideAuto: x - halfWidth >= leftSplit - eps and x + halfWidth <= rightSplit + eps

proc buildFreeGrid(obstacles: seq[Obstacle], terminals: openArray[Point]):
    tuple[nodes: seq[Point], adj: seq[seq[int]]] =
  ## The Hanan grid: every inflated-obstacle boundary and signal-terminal
  ## escape coordinate supplies an x or y axis; points inside an obstacle are
  ## dropped. Including terminal axes lets an off-centre side pin turn after
  ## its outward stub instead of requiring its tangential coordinate to happen
  ## to coincide with an obstacle boundary. This shared free-space graph
  ## contains every obstacle corner and terminal projection needed for
  ## orthogonal paths among these rectangles. Adjacent visible nodes on an
  ## axis are enough: an intervening collinear node has the same length and
  ## introduces no bend.
  ##
  ## A `freeGridMargin`-step ring of extra axes is added just outside the
  ## extreme obstacle/terminal coordinates on every side. Without it the grid
  ## stops exactly at the outermost obstacle edge or rail/ground glyph bar, so
  ## a wire that must route *around* a part (a pass-through strap reaching ports
  ## on both sides, say) has no track to turn on beyond the glyph that blocks
  ## the centreline -- and the net needlessly falls back.
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

  # Extend both axes with a ring of margin tracks so a route can escape past
  # the outermost obstacle/glyph and turn back. Prepend/append keeps each
  # sequence sorted, which the adjacency sweeps below rely on.
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

  # Linking every visible pair is geometrically redundant (the intervening
  # collinear nodes preserve both Manhattan length and bend count) and becomes
  # prohibitively quadratic once terminal axes are present.
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

