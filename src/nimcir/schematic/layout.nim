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
## `bodyW`/`bodyH` and the obstacle rects stay valid. Finally a **leaf-snap**
## pass pulls each square two-terminal part that has just one non-ground /
## non-rail net up against the pin it connects to and turns it so that pin
## faces there -- a single spring otherwise leaves such a part adrift with its
## pin pointing away. Every step is
## deterministic -- same netlist, same scene, every time -- which is what
## makes the scene testable and the archive reproducible.
##
## Rail decisions come from `netlist/kinds.isGround`/`isRail`, never from a
## name guess: a ground or supply net is not wired as a tree but drawn as a
## local stub at each pin, leaving along that pin's outward escape direction
## so it always juts *away* from the body -- a negative supply on a box's
## bottom edge stubs down, not up through the body. Symbol/kind selection is a small registry keyed by
## `Component.kind`, with a fallback box for anything unrecognised -- the
## same "refuse to guess, draw a box" stance the rest of the library takes
## toward parts it cannot model.
##
## The routing invariant is **no shared collinear runs within one net, and
## stronger across nets**: two wires of the same net may meet at a vertex and
## may continue straight through one, but never overlap along a positive-length
## segment; two wires of different nets may cross perpendicularly, but never
## touch collinearly (not even end-to-end) and keep at least
## `wireMinSeparation` (8 world units) of centreline separation wherever they
## run parallel and their projections overlap. Routing is occupancy-aware --
## every emitted signal segment and every ground/supply stub is recorded with
## its net, and later routes (and later stubs) are shortened or steered so
## they only touch that geometry, never run along it or crowd it. Signal nets
## grow as a tree from the first pin, attaching each next pin to the closest
## point already wired, so the per-net polylines partition the tree's segments
## exactly once. The path search is **bend-aware**: its state is
## `(node, incoming axis)` and its cost is the lexicographic pair (Manhattan
## length, bend count), so among all shortest obstacle-avoiding paths it
## picks the one with the fewest bends (ties by lowest node index, then
## axis). Sources are seeded in both axis states, making the first graph edge
## free; the short pin stubs at either endpoint are outside the graph and so
## never charged as bends. A pin with no valid path under those rules is an
## internal invariant failure: `routeNet` raises `doAssert` (`AssertionDefect`)
## instead of falling back to an unchecked straight line.

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

type
  SymbolDef = object
    name: string
    isBox: bool
    bodyW, bodyH: float
    inkW, inkH: float
      ## The bounding box of what `svg.drawPart` actually strokes for this
      ## symbol, at rotation 0 -- which for the horizontal two-terminal
      ## symbols is far shorter than the `bodyW`/`bodyH` pin span. `layout`
      ## and `svg` are the two files that must agree on drawn geometry: a
      ## change to a symbol's drawing in `svg.nim` needs the matching extent
      ## updated here (see `inkExtent`). Used only to place labels.
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

const boxStub* = 20.0
  ## How far a fallback-box pin sits outside the *drawn* rectangle. `boxSlots`
  ## puts the pin (and hence its routing escape point) on the `bodyW`/`bodyH`
  ## extent so routing stays grid-aligned; `svg` insets the visible rectangle
  ## by this much and draws a stub from that edge out to the pin.

proc boxSlots(c: Component): tuple[slots: seq[Point], halfW, halfH: float] =
  ## Deterministic fallback-box pin placement, keyed on pin type: declared
  ## power pins leave the top edge, ground pins the bottom, inputs the left and
  ## outputs the right; every other pin fills the left edge then the right.
  ## Within an edge the pins are spread symmetrically about the body centre.
  ## `halfW`/`halfH` are the pin extent -- pins sit on this rectangle so their
  ## escape points land on the routing grid, and `svg` draws the body itself
  ## `boxStub` smaller so each pin visibly juts out with its name just inside.
  const
    pitch = 40.0       ## row spacing on the left/right edges
    endPitch = 80.0     ## column spacing on the top/bottom edges -- wider so a
                        ## rail stub's net-name label clears the next pin
  var names: seq[string]
  var top, bot, left, right: seq[int]
  var i = 0
  for name, p in c.pins:
    names.add name
    case p.kind
    of ptPower: top.add i
    of ptGround: bot.add i
    of ptInput: left.add i
    of ptOutput: right.add i
    elif left.len <= right.len: left.add i
    else: right.add i
    inc i
  let n = i
  let rows = max(left.len, right.len)
  let cols = max(top.len, bot.len)
  var sideChars = 0
  for idx in left & right: sideChars = max(sideChars, names[idx].len)
  # Inner (drawn) half-extents: room for the pin rows/columns plus a margin, a
  # floor that keeps room for the centred designator/value text, and width for
  # the longest side-pin name printed inside. The pin extent adds `boxStub`.
  let innerW = max(max(float(cols) * endPitch / 2.0 + 16.0, 46.0),
                   float(sideChars) * 6.0 + 14.0)
  let innerH = max(float(rows) * pitch / 2.0 + 16.0, 30.0)
  let halfW = innerW + boxStub
  let halfH = innerH + boxStub
  proc spread(count, k: int, step: float): float =
    (float(k) - float(count - 1) / 2.0) * step
  result.slots.setLen(n)
  for k, idx in left:
    result.slots[idx] = Point(x: -halfW, y: spread(left.len, k, pitch))
  for k, idx in right:
    result.slots[idx] = Point(x: halfW, y: spread(right.len, k, pitch))
  for k, idx in top:
    result.slots[idx] = Point(x: spread(top.len, k, endPitch), y: -halfH)
  for k, idx in bot:
    result.slots[idx] = Point(x: spread(bot.len, k, endPitch), y: halfH)
  result.halfW = halfW
  result.halfH = halfH

proc inkExtent(name: string, bodyW, bodyH: float): tuple[w, h: float] =
  ## The bounding box of what `svg.drawPart` strokes for symbol `name`, at
  ## rotation 0. These literals mirror `svg.nim`'s drawing code -- the resistor
  ## zigzag is +/-10 tall (`svg.zigzag`), the source circle is r=16, the
  ## transistor has leads on three sides -- and the two files must be kept in
  ## step. Only labels read this; it never feeds an obstacle rect.
  case name
  of "resistor", "diode": (bodyW, 20.0)
  of "capacitor", "passive": (bodyW, 24.0)
  of "inductor": (bodyW, 16.0)
  of "voltage_source", "current_source": (32.0, bodyH)
  of "transistor": (bodyH, bodyH)
  else: (bodyW, bodyH)          # source4, box: the drawn shape is the body

proc symbolFor(c: Component): SymbolDef =
  ## The symbol for `c.kind`, with pin slots relative to the part centre.
  ##
  ## A part is a fallback box when its kind has no registered symbol, when it
  ## instantiates hierarchy (its pins are the child's ports, best drawn as a
  ## box), or when its pin count does not match the symbol's slots.
  let n = c.pins.len
  proc box(): SymbolDef =
    let b = boxSlots(c)
    SymbolDef(name: "box", isBox: true, bodyW: b.halfW * 2.0,
              bodyH: b.halfH * 2.0,
              inkW: b.halfW * 2.0 - 2.0 * boxStub,
              inkH: b.halfH * 2.0 - 2.0 * boxStub, slots: b.slots)

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
    return SymbolDef(name: "source4", bodyW: bodyW, bodyH: bodyH,
                     inkW: bodyW, inkH: bodyH, byName: byName)
  of "bjt", "mosfet", "jfet", "transistor":
    result = SymbolDef(name: "transistor", bodyW: h, bodyH: h,
      slots: @[Point(x: 0.0, y: -pinSpan), Point(x: -pinSpan, y: 0.0),
               Point(x: 0.0, y: pinSpan)])
  else:
    return box()

  if result.slots.len != n:
    return box()
  (result.inkW, result.inkH) = inkExtent(result.name, result.bodyW, result.bodyH)

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

proc edgeAllowed(a, b: Point, netName: string, occ: seq[OccSeg]): bool =
  ## A candidate routing edge is usable unless it collides with an already
  ## emitted segment. Within one net only a positive-length collinear overlap
  ## is forbidden (a new branch may attach at, and continue straight through,
  ## a shared vertex). Across different nets the rule is stronger: a
  ## perpendicular crossing stays allowed, but a collinear touch -- even
  ## end-to-end -- is forbidden, and a parallel segment must keep at least
  ## `wireMinSeparation` of centreline separation wherever its projection
  ## overlaps an occupied segment's.
  for s in occ:
    if s.net == netName:
      if collinearOverlap(a, b, s.a, s.b): return false
    else:
      if collinearClosed(a, b, s.a, s.b): return false
      if parallelTooClose(a, b, s.a, s.b): return false
  true

proc addOcc(occ: var seq[OccSeg], a, b: Point, net: string) {.inline.} =
  if sameCoord(a.x, b.x) and sameCoord(a.y, b.y): return
  occ.add OccSeg(a: a, b: b, net: net)

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

proc lexBefore(l1: float, b1: int, l2: float, b2: int): bool {.inline.} =
  ## Strict lexicographic order on (Manhattan length, bend count): a route is
  ## better only when it is shorter, or exactly as short with fewer bends.
  l1 < l2 - 1e-9 or (abs(l1 - l2) <= 1e-9 and b1 < b2)

proc dijkstraFromSources(nodes: seq[Point], adj: seq[seq[int]],
                         sources: seq[int], occ: seq[OccSeg],
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
      if not edgeAllowed(nodes[i], nodes[j], netName, occ): continue
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

# --- label placement --------------------------------------------------------
# Designator/value text (and net + rail names) is placed here, against the
# finished wire and body geometry, rather than at fixed offsets in `svg.nim`.
# The search is a first-fit over a small ordered set of candidate spots around
# the thing being named; if every candidate collides, candidate 0 is used
# anyway, so the pass is total and a label is never dropped.

type
  Rect = tuple[x1, y1, x2, y2: float]

  LabelLine = tuple[text: string, size: float, role: LabelRole]

  Side = enum
    sRight, sTop, sLeft, sBottom

proc rectsOverlap(a, b: Rect): bool {.inline.} =
  a.x1 < b.x2 - 1e-9 and b.x1 < a.x2 - 1e-9 and
  a.y1 < b.y2 - 1e-9 and b.y1 < a.y2 - 1e-9

proc partInk(p: SchematicPart): Rect =
  ## The drawn-symbol box in world coords. A 90/270 rotation swaps the ink
  ## extents: only square-bodied two-terminal symbols rotate, so their pins
  ## still land, but a resistor's zigzag becomes tall and thin -- which is
  ## exactly why the label then wants the (short) side, not the (long) end.
  var w = p.inkW
  var h = p.inkH
  if abs(p.rotation - 90.0) < 1e-9 or abs(p.rotation - 270.0) < 1e-9:
    swap(w, h)
  (p.x - w / 2.0, p.y - h / 2.0, p.x + w / 2.0, p.y + h / 2.0)

proc portBody(p: SchematicPort): Rect {.inline.} =
  (p.x - p.bodyW / 2.0, p.y - p.bodyH / 2.0,
   p.x + p.bodyW / 2.0, p.y + p.bodyH / 2.0)

proc textWidth(s: string, size: float): float {.inline.} =
  float(s.len) * glyphAspect * size

proc lineBox(originX, baseline: float, s: string, anchor: TextAnchor,
             size: float): Rect =
  ## The ink box of one rendered line. SVG `y` is the baseline; monospace
  ## glyphs rise ~0.8*size above it and drop ~0.2*size below.
  let w = textWidth(s, size)
  let x1 = case anchor
           of taStart: originX
           of taMiddle: originX - w / 2.0
           of taEnd: originX - w
  (x1, baseline - 0.8 * size, x1 + w, baseline + 0.2 * size)

proc blockHeight(lines: seq[LabelLine]): float =
  for i, ln in lines:
    result += ln.size
    if i > 0: result += labelLineGap

proc layoutBlock(lines: seq[LabelLine], refX, refTop: float,
                 anchor: TextAnchor, owner: string):
    tuple[labels: seq[SchematicLabel], box: Rect] =
  ## Stack `lines` downward from `refTop`, each line's origin at `refX` read
  ## per `anchor`. Returns the labels and the union of their ink boxes.
  var y = refTop
  result.box = (Inf, Inf, -Inf, -Inf)
  for ln in lines:
    let baseline = y + 0.8 * ln.size
    let lb = lineBox(refX, baseline, ln.text, anchor, ln.size)
    result.labels.add SchematicLabel(text: ln.text, x: refX, y: baseline,
      anchor: anchor, size: ln.size, role: ln.role, owner: owner)
    result.box = (min(result.box.x1, lb.x1), min(result.box.y1, lb.y1),
                  max(result.box.x2, lb.x2), max(result.box.y2, lb.y2))
    y = baseline + 0.2 * ln.size + labelLineGap

proc candidatesAround(ik: Rect, h: float, order: seq[Side]):
    seq[tuple[refX, refTop: float, anchor: TextAnchor]] =
  ## Candidate top-left anchors for a block of height `h` around ink rect `ik`,
  ## the four sides in `order` first, then the four corners.
  let cx = (ik.x1 + ik.x2) / 2.0
  for s in order:
    case s
    of sRight:  result.add (ik.x2 + labelGap, (ik.y1 + ik.y2) / 2.0 - h / 2.0, taStart)
    of sLeft:   result.add (ik.x1 - labelGap, (ik.y1 + ik.y2) / 2.0 - h / 2.0, taEnd)
    of sTop:    result.add (cx, ik.y1 - labelGap - h, taMiddle)
    of sBottom: result.add (cx, ik.y2 + labelGap, taMiddle)
  result.add (ik.x2 + labelGap, ik.y1 - labelGap - h, taStart)   # top-right
  result.add (ik.x2 + labelGap, ik.y2 + labelGap, taStart)       # bottom-right
  result.add (ik.x1 - labelGap, ik.y1 - labelGap - h, taEnd)     # top-left
  result.add (ik.x1 - labelGap, ik.y2 + labelGap, taEnd)         # bottom-left

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

proc routeNet(pins: seq[tuple[pt: Point, partIdx: int, esc: Point]],
              parts: seq[SchematicPart], obstacles: seq[Obstacle],
              free: tuple[nodes: seq[Point], adj: seq[seq[int]]],
              occ: var seq[OccSeg], netName: string): seq[seq[Point]] =
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
  ## A pin that cannot be reached on the free grid under those rules is an
  ## internal invariant failure -- the free grid is complete for orthogonal
  ## obstacle-avoiding paths, so `layout` asserts rather than drawing an
  ## unchecked straight fallback that would cross bodies or other nets.
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

    let rr = dijkstraFromSources(nodes, adj, sources, occ, netName)

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

    doAssert bestState >= 0,
      "schematic route: net \"" & netName &
      "\" has no reachable pin state on the free grid"
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
      doAssert edgeAllowed(nodes[pathIdx[k]], nodes[pathIdx[k + 1]], netName, occ),
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
    result.add deduped

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
      if other.component.netlist != comp.netlist: continue
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

proc slotEscape(slot: Point, bw, bh: float): Point =
  ## The outward axis direction of a pin at `slot` relative to its part centre,
  ## by the same body-half-extent test `escapeDir` runs on a placed part.
  if abs(abs(slot.x) - bw / 2.0) < abs(abs(slot.y) - bh / 2.0):
    Point(x: (if slot.x >= 0.0: 1.0 else: -1.0), y: 0.0)
  else:
    Point(x: 0.0, y: (if slot.y >= 0.0: 1.0 else: -1.0))

proc axisUnit(p: Point): Point {.inline.} =
  ## The dominant axis of `p` as a unit vector (ties to x). `(0,0)` stays.
  if abs(p.x) >= abs(p.y) and p.x != 0.0:
    Point(x: (if p.x > 0.0: 1.0 else: -1.0), y: 0.0)
  elif p.y != 0.0:
    Point(x: 0.0, y: (if p.y > 0.0: 1.0 else: -1.0))
  else:
    Point(x: 0.0, y: 0.0)

proc leafSnap(comps: seq[Component], syms: seq[SymbolDef], pos: var seq[Point],
              rots: var seq[float], ohw, ohh: seq[float],
              idxOf: Table[string, int]) =
  ## A square two-terminal part with exactly one non-ground / non-rail net has a
  ## single attraction spring: the force layout fixes its distance from that one
  ## net-mate but neither the direction nor the alignment, so it drifts off with
  ## its connected pin facing away. Move each such leaf to the nearest free grid
  ## cell out along its net-mate pin's escape axis -- so the wire between them is
  ## a short straight stub -- and turn it so its connected pin faces back at that
  ## mate. Position is only ever moved *closer* to the mate pin than it already
  ## was, so the pass can only help.
  ##
  ## Runs after the definitive rotation pass, and owns a leaf's orientation
  ## outright: for a part with one real connection "point the pin at it" beats
  ## any wirelength score, and the score's four-way ties (a shunt element sits
  ## symmetrically between its neighbours) were being broken by nothing better
  ## than the smaller angle.
  ##
  ## Deterministic: parts visited in insertion order, each placed and turned
  ## against the others' current centres/rotations, the mate chosen as the
  ## nearest pin with a `pinKey` tie-break.
  let n = comps.len
  var against = newSeq[int](n)
  for i in 0 ..< n: against[i] = i
  for i in 0 ..< n:
    if not rotatable(syms[i]): continue
    var theNet: Net = nil
    var myPin = ""
    var myOrd = 0
    var multi = false
    block:
      var ord = 0
      for pinName, p in comps[i].pins:
        if p.net != nil and not isGround(p.net) and not isRail(p.net):
          if theNet == nil:
            theNet = p.net; myPin = pinName; myOrd = ord
          elif p.net != theNet: multi = true
        inc ord
    if multi or theNet == nil: continue

    let pw = pinWorldPositions(comps, syms, pos, rots)
    var mate: Pin = nil
    var mateKey = ""
    var mateD = Inf
    for other in theNet.pins:
      if other.component == nil or
         other.component.designator == comps[i].designator: continue
      if other.component.netlist != comps[i].netlist: continue
      if not idxOf.hasKey(other.component.designator): continue
      let key = pinKey(other.component, other.name)
      if not pw.hasKey(key): continue
      let d = manhattan(pw[key], pos[i])
      if d < mateD - 1e-9 or
         (abs(d - mateD) <= 1e-9 and (mate == nil or key < mateKey)):
        mateD = d
        mate = other
        mateKey = key
    if mate == nil: continue

    let j = idxOf[mate.component.designator]
    var ord = 0
    var mslot = Point()
    for pinName, _ in comps[j].pins:
      if pinName == mate.name:
        mslot = rotatedSlot(slotOf(syms[j], pinName, ord), rots[j])
        break
      inc ord
    let m = pos[j] + mslot
    let dir = slotEscape(mslot, syms[j].bodyW, syms[j].bodyH)
    let reach = ohw[i] + ohw[j]
    let target = Point(x: round((m.x + dir.x * reach) / grid) * grid,
                       y: round((m.y + dir.y * reach) / grid) * grid)

    var best = pos[i]
    var bestD = manhattan(pos[i], m)
    var found = false
    for r in 0 .. 6:
      for dy in -r .. r:
        for dx in -r .. r:
          if max(abs(dx), abs(dy)) != r: continue
          let x = target.x + float(dx) * grid
          let y = target.y + float(dy) * grid
          if overlapsAny(i, x, y, pos, ohw, ohh, against): continue
          let d = manhattan(Point(x: x, y: y), m)
          if d < bestD - 1e-9:
            bestD = d
            best = Point(x: x, y: y)
            found = true
      if found: break
    if not found: continue
    pos[i] = best

    # Turn the leaf so its connected pin points back at the mate (along -dir).
    let wantSlot = Point(x: -dir.x, y: -dir.y)
    let baseSlot = slotOf(syms[i], myPin, myOrd)
    for angle in rotationChoices:
      if axisUnit(rotatedSlot(baseSlot, angle)) == wantSlot:
        rots[i] = angle
        break

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

proc portDrives(c: Component): bool =
  ## Whether a component sitting on a port net can source a signal onto it: a
  ## real or synthesized source, a hierarchical block, or any part
  ## `classifyConductivity` cannot rule out (an IC, a transistor, an
  ## unrecognised kind -- assumed capable rather than guessed harmless).
  if c == nil: return false
  if c.subNetlist != nil: return true
  let k = c.kind.toLowerAscii()
  if k in ["voltage_source", "current_source", "battery"]: return true
  if k in behaviouralKinds: return true
  classifyConductivity(c) == condAmbiguous

proc portDirection(n: Net): PortDirection =
  ## Which way a port net flows. An explicit `Pin.kind` wins -- `ptOutput`,
  ## then `ptInOut`, then `ptInput` -- because that is the authored answer.
  ## With nothing stated, a driver test decides: a net nothing on the sheet
  ## drives is an input; a net something drives makes no directional claim
  ## (`pdUnspecified`, a neutral symbol).
  var sawInput = false
  for p in n.pins:
    case p.kind
    of ptOutput: return pdOutput
    of ptInOut: return pdBidir
    of ptInput: sawInput = true
    else: discard
  if sawInput: return pdInput
  for p in n.pins:
    if portDrives(p.component): return pdUnspecified
  pdInput

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
          if ca.netlist != nl or cb.netlist != nl: continue
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

  # --- leaf cleanup: a one-signal-net part snapped beside its net-mate ----
  # A part with a single non-ground / non-rail net still sits and points
  # wherever its one spring left it. Pull each up against the pin it connects
  # to and turn it to face there, so the router draws a short straight stub
  # rather than a long detour. Last, so it owns both the position and the
  # orientation of the leaves it touches.
  leafSnap(comps, syms, pos, rots, ohw, ohh, idxOf)

  # --- parts, with absolute pin positions --------------------------------
  var pinPos = initTable[string, Point]()
  var partIdxByDesig = initTable[string, int]()
  for i, c in comps:
    let sd = syms[i]
    var sp = SchematicPart(designator: c.designator, kind: c.kind,
                           name: c.name, value: c.attrs.getOrDefault("value", ""),
                           symbol: sd.name, isBox: sd.isBox,
                           bodyW: sd.bodyW, bodyH: sd.bodyH,
                           inkW: sd.inkW, inkH: sd.inkH,
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

  # A shared global net (SPICE node "0") accumulates pins from every sibling
  # clone that wired into it, and sibling clones reuse designators, so a pin
  # belongs to this sheet only when its component's owning netlist *is* this
  # one -- identity, not name.
  proc ownsPin(p: Pin): bool =
    p.component != nil and p.component.netlist == nl

  # `isGround` also fires on a net that merely has a `ptGround`-kinded pin --
  # an op-amp's `V-` supply pin, say -- so an explicitly `ntPower` net would
  # be drawn with a ground glyph instead of its rail stub. An explicit net
  # kind wins here: a `ptGround` pin on a power net makes it a rail, not
  # ground.
  proc isGroundHere(net: Net): bool =
    net != nil and isGround(net) and net.kind != ntPower
  proc isRailHere(net: Net): bool =
    net != nil and isRail(net) and not isGroundHere(net)

  # Every signal pin leaves its body through a short stub in a fixed
  # direction; a ground or supply stub must not run along one of those, or two
  # different nets share a collinear segment. Seed the shortening test with
  # them (they are not added to `occ` -- the signal route re-adds its own).
  var escapeSeeds: seq[OccSeg]
  for _, net in nl.nets:
    if isGroundHere(net) or isRailHere(net): continue
    for p in net.pins:
      if not ownsPin(p): continue
      let key = pinKey(p.component, p.name)
      if not (pinPos.hasKey(key) and
              partIdxByDesig.hasKey(p.component.designator)): continue
      let pt = pinPos[key]
      let part = result.parts[partIdxByDesig[p.component.designator]]
      addOcc(escapeSeeds, pt, pt + escapeDir(part, pt) * routingClearance,
             net.name)

  # --- interface ports: a fixed column per direction ------------------
  # Each entry of `nl.ports` (declared order -- an `OrderedTable`, iterated
  # like `nl.nets` everywhere else here) whose net carries a real signal
  # gets an Altium-style port symbol in a column just outside the parts: the
  # left edge for an input or an unspecified port, the right edge for an
  # output or a bidirectional one, so signal reads left to right. Rails and
  # ground are skipped -- they draw their own glyph. Layout fixes the column
  # x; a port's y follows its net-mate pin, pushed down only to clear a port
  # already placed in that column. The connecting wire is routed like any
  # other net branch, so it never crosses a body.
  var portedNets = initHashSet[string]()
  var portConn = initTable[string, tuple[at: Point, inward: Point]]()

  var pMinX, pMaxX = 0.0
  var havePExt = false
  for sp in result.parts:
    let l = sp.x - sp.bodyW / 2.0
    let r = sp.x + sp.bodyW / 2.0
    if not havePExt: pMinX = l; pMaxX = r; havePExt = true
    else:
      if l < pMinX: pMinX = l
      if r > pMaxX: pMaxX = r
  if not havePExt: (pMinX, pMaxX) = (0.0, 0.0)
  let leftColX = round((pMinX - 2.0 * grid) / grid) * grid
  let rightColX = round((pMaxX + 2.0 * grid) / grid) * grid

  type PortPlan = object
    name, net: string
    dir: PortDirection
    toRight: bool
    prefY, bodyW, bodyH: float
  var plans: seq[PortPlan]
  for portName, net in nl.ports:
    if net == nil or isGroundHere(net) or isRailHere(net): continue
    let dir = portDirection(net)
    let toRight = dir in {pdOutput, pdBidir}
    var anchorX, anchorY = 0.0
    var have = false
    for p in net.pins:
      if not ownsPin(p): continue
      let key = pinKey(p.component, p.name)
      if not pinPos.hasKey(key): continue
      let pt = pinPos[key]
      let better =
        if not have: true
        elif toRight: pt.x > anchorX + 1e-9
        else: pt.x < anchorX - 1e-9
      if better:
        anchorX = pt.x
        anchorY = pt.y
        have = true
    if not have: continue
    portedNets.incl net.name
    plans.add PortPlan(name: portName, net: net.name, dir: dir, toRight: toRight,
      prefY: anchorY, bodyH: 24.0,
      bodyW: max(60.0, float(portName.len) * 8.0 + 28.0))

  # Stack each column: preferred y first (name breaks a tie), then a fixed
  # gap so two ports never overlap.
  for onRight in [false, true]:
    var col: seq[int]
    for i, pl in plans:
      if pl.toRight == onRight: col.add i
    col.sort(proc(a, b: int): int =
      result = cmp(plans[a].prefY, plans[b].prefY)
      if result == 0: result = cmp(plans[a].name, plans[b].name))
    var yCursor = NegInf
    for i in col:
      let pl = plans[i]
      var y = round(pl.prefY / grid) * grid
      if y < yCursor + 3.0 * grid: y = yCursor + 3.0 * grid
      yCursor = y
      let edgeX = (if onRight: rightColX else: leftColX)
      var px = edgeX + (if onRight: pl.bodyW / 2.0 else: -pl.bodyW / 2.0)
      if abs(px) < 1e-9: px = 0.0
      if abs(y) < 1e-9: y = 0.0
      result.ports.add SchematicPort(name: pl.name, net: pl.net, dir: pl.dir,
        x: px, y: y, bodyW: pl.bodyW, bodyH: pl.bodyH,
        rotation: (if onRight: 0.0 else: 180.0))
      portConn[pl.net] = (at: Point(x: edgeX, y: y),
                          inward: Point(x: (if onRight: -1.0 else: 1.0), y: 0.0))

  var obstacles = obstaclesFor(result.parts)
  for p in result.ports:
    let hw = p.bodyW / 2.0 + routingClearance
    let hh = p.bodyH / 2.0 + routingClearance
    obstacles.add Obstacle(x1: p.x - hw, y1: p.y - hh,
                           x2: p.x + hw, y2: p.y + hh)
  let free = buildFreeGrid(obstacles)

  # --- routing ------------------------------------------------------------
  # Rail stubs are emitted first so their segments are occupied before any
  # signal route is planned; signal routes then avoid running along them.
  # Within each stub pass and signal pass the same deterministic order (net
  # iteration order, then pin order) drives occupancy, so the whole scene is
  # reproducible.
  var occ: seq[OccSeg]
  var railLabelReqs: seq[tuple[text: string, at, dir: Point]]

  for _, net in nl.nets:
    var pins: seq[tuple[pt: Point, partIdx: int]]
    for p in net.pins:
      if ownsPin(p):
        let key = pinKey(p.component, p.name)
        if pinPos.hasKey(key) and partIdxByDesig.hasKey(p.component.designator):
          pins.add (pt: pinPos[key],
                    partIdx: partIdxByDesig[p.component.designator])
    if pins.len == 0: continue

    if isGroundHere(net):
      for pin in pins:
        let dir = escapeDir(result.parts[pin.partIdx], pin.pt)
        let e = shortenedStubEnd(pin.pt, dir, pinSpan, net.name, occ & escapeSeeds)
        result.wires.add SchematicWire(net: net.name, kind: wkGround,
                                       points: @[pin.pt, e])
        addOcc(occ, pin.pt, e, net.name)
    elif isRailHere(net):
      for pin in pins:
        let dir = escapeDir(result.parts[pin.partIdx], pin.pt)
        let e = shortenedStubEnd(pin.pt, dir, pinSpan, net.name, occ & escapeSeeds)
        result.wires.add SchematicWire(net: net.name, kind: wkSupply,
                                       points: @[pin.pt, e])
        addOcc(occ, pin.pt, e, net.name)
        if net.name.len > 0:
          railLabelReqs.add (text: net.name, at: e, dir: dir)

  for _, net in nl.nets:
    if isGroundHere(net) or isRailHere(net): continue
    var pins: seq[tuple[pt: Point, partIdx: int, esc: Point]]
    for p in net.pins:
      if ownsPin(p):
        let key = pinKey(p.component, p.name)
        if pinPos.hasKey(key) and partIdxByDesig.hasKey(p.component.designator):
          pins.add (pt: pinPos[key],
                    partIdx: partIdxByDesig[p.component.designator],
                    esc: Point(x: 0.0, y: 0.0))
    if portConn.hasKey(net.name):
      let pc = portConn[net.name]
      pins.add (pt: pc.at, partIdx: 0, esc: pc.inward)
    if pins.len < 2: continue
    var adj = initTable[Point, HashSet[Point]]()
    for poly in routeNet(pins, result.parts, obstacles, free, occ, net.name):
      result.wires.add SchematicWire(net: net.name, kind: wkSignal,
                                     points: poly)
      addSegments(adj, poly)
    for p, nbrs in adj:
      if nbrs.len >= 3:
        result.junctions.add SchematicJunction(net: net.name, x: p.x, y: p.y)

  result.junctions.sort(cmpJunction)

  # --- label placement --------------------------------------------------------
  # Part designators/values, signal-net names and supply-rail names are all
  # placedBoxes here by a first-fit search against the finished geometry, in that
  # order (a designator adrift from its body reads worse than a net name adrift
  # from its pin), each tested against every label already placedBoxes. `bodyRects`
  # are the *drawn* ink boxes and the port bodies -- not the routing-inflated
  # obstacles: a label may sit in a routing channel, and the wire test already
  # covers the channels a wire actually took. If every candidate collides,
  # candidate 0 is used anyway, so a label is never dropped.
  let allWires = result.wires
  var placedBoxes: seq[Rect]
  var bodyRects: seq[Rect]
  for p in result.parts: bodyRects.add partInk(p)
  for p in result.ports: bodyRects.add portBody(p)
  # The ground/supply glyph `svg` caps each rail/ground stub with reaches
  # ~10 units perpendicular and ~8 along the stub -- decoration, not a wire, so
  # add its footprint here or a label would land across the bars.
  for w in result.wires:
    if w.kind in {wkGround, wkSupply} and w.points.len > 0:
      let e = w.points[^1]
      bodyRects.add (e.x - 13.0, e.y - 13.0, e.x + 13.0, e.y + 13.0)
  var newLabels: seq[SchematicLabel]

  # A symbol draws a short lead from each pin in to its glyph -- the span
  # between the pin (on `bodyW`/`bodyH`) and the ink rect. `svg` strokes those,
  # not `layout`, so they are not in `allWires`; add them here so a label on a
  # crowded part's occupied side is still rejected off them.
  var leadSegs: seq[tuple[a, b: Point]]
  for p in result.parts:
    if p.isBox: continue
    let ik = partInk(p)
    for pin in p.pins:
      let pt = Point(x: pin.x, y: pin.y)
      let d = escapeDir(p, pt)
      let e =
        if d.x != 0.0: Point(x: (if d.x > 0.0: ik.x2 else: ik.x1), y: pt.y)
        elif d.y != 0.0: Point(x: pt.x, y: (if d.y > 0.0: ik.y2 else: ik.y1))
        else: pt
      if abs(e.x - pt.x) > 1e-6 or abs(e.y - pt.y) > 1e-6:
        leadSegs.add (a: pt, b: e)

  proc overlapArea(a, b: Rect): float =
    let w = min(a.x2, b.x2) - max(a.x1, b.x1)
    let h = min(a.y2, b.y2) - max(a.y1, b.y1)
    if w > 0.0 and h > 0.0: w * h else: 0.0

  proc penalty(box: Rect, skipBody: int): float =
    ## 0 when the spot is clear; otherwise a cost, so a fully boxed-in label
    ## falls back to the *least bad* spot rather than blindly to candidate 0.
    ## A wire or lead crossing dominates any amount of body/label overlap.
    let ob = @[Obstacle(x1: box.x1, y1: box.y1, x2: box.x2, y2: box.y2)]
    for w in allWires:
      for i in 1 ..< w.points.len:
        if segBlocked(w.points[i - 1], w.points[i], ob): result += 1.0e6
    for s in leadSegs:
      if segBlocked(s.a, s.b, ob): result += 1.0e6
    for k in 0 ..< bodyRects.len:
      if k != skipBody: result += overlapArea(box, bodyRects[k])
    for r in placedBoxes:
      result += 2.0 * overlapArea(box, r)

  proc place(lines: seq[LabelLine], ik: Rect, order: seq[Side],
             owner: string, skipBody: int) =
    if lines.len == 0: return
    let h = blockHeight(lines)
    let cands = candidatesAround(ik, h, order)
    var chosen = layoutBlock(lines, cands[0].refX, cands[0].refTop,
                             cands[0].anchor, owner)
    var best = penalty(chosen.box, skipBody)
    if best > 0.0:
      for c in cands:
        let b = layoutBlock(lines, c.refX, c.refTop, c.anchor, owner)
        let p = penalty(b.box, skipBody)
        if p < best - 1e-9:
          best = p
          chosen = b
          if p == 0.0: break
    for lb in chosen.labels: newLabels.add lb
    placedBoxes.add chosen.box

  for idx, p in result.parts:
    # A box draws its own designator/value inside the body (`svg.drawPart`),
    # where `boxSlots` reserved the room -- only symbol parts are labelled here.
    if p.isBox: continue
    var lines: seq[LabelLine]
    if p.designator.len > 0: lines.add (p.designator, designatorSize, lrDesignator)
    if p.value.len > 0: lines.add (p.value, valueSize, lrValue)
    if lines.len == 0: continue
    var occupied: set[Side]
    for pin in p.pins:
      let d = escapeDir(p, Point(x: pin.x, y: pin.y))
      if d.x > 0.5: occupied.incl sRight
      elif d.x < -0.5: occupied.incl sLeft
      elif d.y > 0.5: occupied.incl sBottom
      elif d.y < -0.5: occupied.incl sTop
    var order: seq[Side]
    for s in [sRight, sTop, sLeft, sBottom]:
      if s notin occupied: order.add s
    for s in [sRight, sTop, sLeft, sBottom]:
      if s in occupied: order.add s
    place(lines, partInk(p), order, p.designator, idx)

  # Signal-net names: near the net's leftmost-then-topmost owned pin, as before,
  # but now searched around it -- and the anchor pin's own wire leaves along
  # its escape direction, so that side is tried last.
  for _, net in nl.nets:
    if isGroundHere(net) or isRailHere(net): continue
    if net.name.len == 0: continue
    if net.name in portedNets: continue
    var anchor: Point
    var anchorEsc: Point
    var have = false
    for p in net.pins:
      if not ownsPin(p): continue
      let key = pinKey(p.component, p.name)
      if not pinPos.hasKey(key): continue
      if not partIdxByDesig.hasKey(p.component.designator): continue
      let pt = pinPos[key]
      if not have or pt.x < anchor.x - 1e-9 or
         (abs(pt.x - anchor.x) <= 1e-9 and pt.y < anchor.y):
        anchor = pt
        anchorEsc = escapeDir(result.parts[partIdxByDesig[p.component.designator]], pt)
        have = true
    if not have: continue
    let escSide =
      if anchorEsc.x > 0.5: sRight
      elif anchorEsc.x < -0.5: sLeft
      elif anchorEsc.y > 0.5: sBottom
      else: sTop
    var order: seq[Side]
    for s in [sTop, sRight, sLeft, sBottom]:
      if s != escSide: order.add s
    order.add escSide
    let dot: Rect = (anchor.x, anchor.y, anchor.x, anchor.y)
    place(@[(net.name, netLabelSize, lrNet)], dot, order, "", -1)

  # Supply-rail names: at the stub end, biased to sit past the glyph. The dot
  # is inflated to the rail glyph's ~10-unit half-extent so the label clears
  # the bars.
  for req in railLabelReqs:
    const g = 10.0
    let dot: Rect = (req.at.x - g, req.at.y - g, req.at.x + g, req.at.y + g)
    let horiz = abs(req.dir.x) > abs(req.dir.y)
    let order =
      if horiz:
        if req.dir.x >= 0.0: @[sRight, sTop, sBottom, sLeft]
        else: @[sLeft, sTop, sBottom, sRight]
      else:
        @[sRight, sLeft, sTop, sBottom]
    place(@[(req.text, netLabelSize, lrRail)], dot, order, "", -1)

  result.labels.add newLabels

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
  for lb in result.labels:
    let sz = if lb.size > 0.0: lb.size else: 12.0
    let b = lineBox(lb.x, lb.y, lb.text, lb.anchor, sz)
    includePt(b.x1, b.y1)
    includePt(b.x2, b.y2)
  for p in result.ports:
    includePt(p.x - p.bodyW / 2.0, p.y - p.bodyH / 2.0)
    includePt(p.x + p.bodyW / 2.0, p.y + p.bodyH / 2.0)
  if not have:
    minX = 0.0; minY = 0.0; maxX = 200.0; maxY = 200.0
  const pad = 40.0
  result.minX = minX - pad
  result.minY = minY - pad
  result.maxX = maxX + pad
  result.maxY = maxY + pad
