## Format-agnostic 2-D geometry for the physical board model.
##
## **Canonical frame: X right, Y up, angles counter-clockwise positive,
## degrees.** ODB++ and Gerber are already Y-up; KiCad is the outlier (Y-down,
## with a rotation that reads counter-clockwise on screen and therefore
## clockwise in a Y-up frame), so a KiCad reader negates Y and angle at its
## boundary. Canonical polygon winding is **islands counter-clockwise, holes
## clockwise** (positive area outward); ODB++ is the reverse and normalises on
## read.
##
## The *curve* (a dimensionless line) is deliberately separate from the
## *shape* (the thing that has area): a track is a stroked path, a pour is a
## filled polygon, and a pad is an interned aperture flashed at a point. Arcs
## are canonically centre + radius + start angle + signed sweep, because both
## source encodings (KiCad's three-point form, ODB++'s endpoints-plus-centre
## form) are awkward for bounding boxes and sampling. `arcFrom3Points` and
## `arcFromEndpointsCenter` convert once, at the reader.

import std/[math, tables]
import ./units

export units

type
  GeometryError* = object of CatchableError
    ## Raised on geometrically impossible input, e.g. a zero-radius arc.

  Point* = object
    x*, y*: Nm

  Box* = object
    ## Axis-aligned bounding box. `lo.x > hi.x` marks the empty box.
    lo*, hi*: Point

  CurveKind* = enum
    cvSeg, cvArc

  Curve* = object
    case kind*: CurveKind
    of cvSeg:
      a*, b*: Point
    of cvArc:
      center*: Point
      radius*: Nm
      startAngle*: Deg
      sweep*: Deg
        ## Signed: positive is counter-clockwise. `abs(sweep) >= 360` is a
        ## full circle.

  Path* = object
    curves*: seq[Curve]
    closed*: bool

  Polygon* = object
    outer*: Path
      ## Counter-clockwise island boundary.
    holes*: seq[Path]
      ## Clockwise hole boundaries, each fully inside `outer`.

  EndCap* = enum
    ecRound, ecSquare, ecButt

  Corner* = enum
    ## Corner selector for rounded/chamfered rectangles, in ascending
    ## counter-clockwise order starting top-right, matching ODB++.
    cnTopRight, cnTopLeft, cnBottomLeft, cnBottomRight

  ApertureKind* = enum
    akCircle, akRect, akRoundRect, akChamferRect, akOval, akTrapezoid,
    akOctagon, akThermal, akPolygon, akCustom

  Aperture* = ref object
    ## A pad/flash shape, interned in `Pcb.apertures` and shared by every pad
    ## that uses it -- mirroring ODB++'s `$n` symbol table and KiCad's shape
    ## tokens. Local coordinates are centred on the aperture origin.
    name*: string
      ## Raw source name, kept verbatim even when parsed: it is what
      ## round-trips, and ODB++ standard-symbol names are the only definition
      ## many shapes have.
    case kind*: ApertureKind
    of akCircle:
      dia*: Nm
    of akRect, akOval:
      w*, h*: Nm
    of akRoundRect, akChamferRect:
      rw*, rh*, corner*: Nm
      corners*: set[Corner]
    of akTrapezoid:
      tw*, th*, deltaX*, deltaY*: Nm
    of akOctagon:
      ow*, oh*, cut*: Nm
    of akThermal:
      outerDia*, innerDia*, gap*: Nm
      spokes*: int
      spokeAngle*: Deg
    of akPolygon, akCustom:
      outline*: Polygon
    attrs*: OrderedTable[string, string]

  ShapeKind* = enum
    shStroke, shFill, shPad, shText

  Shape* = object
    case kind*: ShapeKind
    of shStroke:
      path*: Path
      width*: Nm
      cap*: EndCap
    of shFill:
      poly*: Polygon
    of shPad:
      aperture*: Aperture
      at*: Point
      rot*: Deg
      mirrored*: bool
        ## Mirrored about the local Y axis, applied *after* rotation.
    of shText:
      origin*: Point
      text*: string
      height*, thickness*: Nm
      angle*: Deg

  Transform* = object
    ## Footprint-local to board coordinates. KiCad's rule is
    ## `absolute = fp.at + Rotate(local, +fp.angle)` with **no** extra mirror
    ## term -- a side flip is already baked into the stored local coordinates
    ## and layer names -- so `mirrorX` stays false for KiCad footprints.
    origin*: Point
    rot*: Deg
    mirrorX*: bool

const
  DefaultFlattenTol* = nm(2000)
    ## Chord tolerance used when an arc must be approximated by a polyline
    ## for a containment or distance test. 2 microns.

# ---------------------------------------------------------------- Point

proc pt*(x, y: Nm): Point {.inline.} = Point(x: x, y: y)

proc `==`*(a, b: Point): bool {.inline.} = a.x == b.x and a.y == b.y
proc `+`*(a, b: Point): Point {.inline.} = pt(a.x + b.x, a.y + b.y)
proc `-`*(a, b: Point): Point {.inline.} = pt(a.x - b.x, a.y - b.y)
proc `$`*(p: Point): string = "(" & $p.x & ", " & $p.y & ")"

proc distance*(a, b: Point): float =
  ## Euclidean distance in nanometres.
  let dx = (a.x - b.x).raw.float
  let dy = (a.y - b.y).raw.float
  sqrt(dx * dx + dy * dy)

proc angleOf*(center, p: Point): Deg =
  ## Angle of `p` as seen from `center`, counter-clockwise from +X.
  normalized(fromRadians(arctan2((p.y - center.y).raw.float,
                                 (p.x - center.x).raw.float)))

# ---------------------------------------------------------------- Box

proc emptyBox*(): Box {.inline.} =
  Box(lo: pt(nm(1), nm(1)), hi: pt(nm(0), nm(0)))

proc isEmpty*(b: Box): bool {.inline.} = b.hi.x < b.lo.x or b.hi.y < b.lo.y

proc boxOf*(a, b: Point): Box =
  ## Normalised box spanning two corners.
  Box(lo: pt(min(a.x, b.x), min(a.y, b.y)),
      hi: pt(max(a.x, b.x), max(a.y, b.y)))

proc width*(b: Box): Nm {.inline.} = b.hi.x - b.lo.x
proc height*(b: Box): Nm {.inline.} = b.hi.y - b.lo.y
proc center*(b: Box): Point {.inline.} =
  pt((b.lo.x + b.hi.x) div 2, (b.lo.y + b.hi.y) div 2)

proc union*(a, b: Box): Box =
  if a.isEmpty: return b
  if b.isEmpty: return a
  Box(lo: pt(min(a.lo.x, b.lo.x), min(a.lo.y, b.lo.y)),
      hi: pt(max(a.hi.x, b.hi.x), max(a.hi.y, b.hi.y)))

proc extendTo*(b: var Box, p: Point) =
  if b.isEmpty:
    b = Box(lo: p, hi: p)
  else:
    b.lo = pt(min(b.lo.x, p.x), min(b.lo.y, p.y))
    b.hi = pt(max(b.hi.x, p.x), max(b.hi.y, p.y))

proc expand*(b: Box, d: Nm): Box =
  if b.isEmpty: b
  else: Box(lo: pt(b.lo.x - d, b.lo.y - d), hi: pt(b.hi.x + d, b.hi.y + d))

proc overlaps*(a, b: Box): bool =
  if a.isEmpty or b.isEmpty: return false
  not (a.hi.x < b.lo.x or b.hi.x < a.lo.x or a.hi.y < b.lo.y or b.hi.y < a.lo.y)

proc contains*(b: Box, p: Point): bool =
  if b.isEmpty: return false
  b.lo.x <= p.x and p.x <= b.hi.x and b.lo.y <= p.y and p.y <= b.hi.y

proc contains*(outer, inner: Box): bool =
  if outer.isEmpty or inner.isEmpty: return false
  outer.lo.x <= inner.lo.x and inner.hi.x <= outer.hi.x and
    outer.lo.y <= inner.lo.y and inner.hi.y <= outer.hi.y

# ---------------------------------------------------------------- Curve

proc seg*(a, b: Point): Curve {.inline.} = Curve(kind: cvSeg, a: a, b: b)

proc arc*(center: Point, radius: Nm, startAngle, sweep: Deg): Curve {.inline.} =
  Curve(kind: cvArc, center: center, radius: radius,
        startAngle: startAngle, sweep: sweep)

proc circleCurve*(center: Point, radius: Nm): Curve {.inline.} =
  ## A full circle as a single 360-degree arc.
  arc(center, radius, deg(0.0), deg(360.0))

proc pointOnArc*(c: Curve, at: Deg): Point =
  ## Point on `c`'s circle at absolute angle `at`.
  let r = c.radius.raw.float
  let a = at.toRadians
  pt(c.center.x + nm(int64(round(r * cos(a)))),
     c.center.y + nm(int64(round(r * sin(a)))))

proc startPoint*(c: Curve): Point =
  case c.kind
  of cvSeg: c.a
  of cvArc: pointOnArc(c, c.startAngle)

proc endPoint*(c: Curve): Point =
  case c.kind
  of cvSeg: c.b
  of cvArc: pointOnArc(c, c.startAngle + c.sweep)

proc sweepContains(c: Curve, at: Deg): bool =
  ## Is absolute angle `at` inside this arc's swept range?
  let s = c.sweep.value
  if abs(s) >= 360.0 - 1e-9: return true
  let start = c.startAngle.normalized.value
  let a = at.normalized.value
  if s >= 0:
    var d = a - start
    if d < 0: d += 360.0
    d <= s + 1e-9
  else:
    var d = start - a
    if d < 0: d += 360.0
    d <= -s + 1e-9

proc box*(c: Curve): Box =
  case c.kind
  of cvSeg:
    result = boxOf(c.a, c.b)
  of cvArc:
    result = boxOf(startPoint(c), endPoint(c))
    # An arc's extremes are its endpoints plus whichever axis crossings it sweeps through.
    for q in 0 .. 3:
      let a = deg(q.float * 90.0)
      if sweepContains(c, a):
        result.extendTo(pointOnArc(c, a))

proc arcFrom3Points*(a, mid, b: Point): Curve =
  ## KiCad's `(start ...) (mid ...) (end ...)` form. Collinear input degrades
  ## to a straight segment rather than raising, matching how
  ## `netlist/formats/spice` falls back instead of erroring on input it cannot
  ## classify.
  let
    ax = a.x.raw.float
    ay = a.y.raw.float
    bx = mid.x.raw.float
    by = mid.y.raw.float
    cx = b.x.raw.float
    cy = b.y.raw.float
    d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
  if abs(d) < 1e-6:
    return seg(a, b)
  let
    a2 = ax * ax + ay * ay
    b2 = bx * bx + by * by
    c2 = cx * cx + cy * cy
    ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
    uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
    center = pt(nm(int64(round(ux))), nm(int64(round(uy))))
    radius = nm(int64(round(distance(center, a))))
    startA = angleOf(center, a)
    endA = angleOf(center, b)
    midA = angleOf(center, mid)
  var ccwSweep = endA.value - startA.value
  if ccwSweep <= 0: ccwSweep += 360.0
  var midDelta = midA.value - startA.value
  if midDelta < 0: midDelta += 360.0
  if midDelta <= ccwSweep:
    arc(center, radius, startA, deg(ccwSweep))
  else:
    arc(center, radius, startA, deg(ccwSweep - 360.0))

proc arcFromEndpointsCenter*(s, e, center: Point, clockwise: bool): Curve =
  ## ODB++'s `A <xs> <ys> <xe> <ye> <xc> <yc> ... <cw>` form. Coincident
  ## endpoints mean a full circle.
  let radius = nm(int64(round(distance(center, s))))
  if radius == nm(0):
    raise newException(GeometryError, "arc with zero radius at " & $center)
  let startA = angleOf(center, s)
  if s == e:
    return arc(center, radius, startA, deg(if clockwise: -360.0 else: 360.0))
  let endA = angleOf(center, e)
  if clockwise:
    var d = startA.value - endA.value
    if d <= 0: d += 360.0
    arc(center, radius, startA, deg(-d))
  else:
    var d = endA.value - startA.value
    if d <= 0: d += 360.0
    arc(center, radius, startA, deg(d))

proc flatten*(c: Curve, tol = DefaultFlattenTol): seq[Point] =
  ## Polyline approximation, inclusive of both endpoints.
  case c.kind
  of cvSeg:
    result = @[c.a, c.b]
  of cvArc:
    let
      r = c.radius.raw.float
      t = max(tol.raw.float, 1.0)
      # Max angular step holding the chord sagitta within `tol`.
      stepRad = if r <= t: PI / 2.0 else: 2.0 * arccos(1.0 - t / r)
      total = abs(c.sweep.value)
      steps = max(2, int(ceil(total / max(stepRad * 180.0 / PI, 1e-6))))
    result = newSeqOfCap[Point](steps + 1)
    for i in 0 .. steps:
      let f = i.float / steps.float
      result.add(pointOnArc(c, c.startAngle + c.sweep * f))

proc distanceTo*(c: Curve, p: Point): float =
  ## Shortest distance from `p` to the curve, in nanometres.
  case c.kind
  of cvSeg:
    let
      ax = c.a.x.raw.float
      ay = c.a.y.raw.float
      vx = (c.b.x - c.a.x).raw.float
      vy = (c.b.y - c.a.y).raw.float
      len2 = vx * vx + vy * vy
      px = p.x.raw.float - ax
      py = p.y.raw.float - ay
    if len2 < 1e-9:
      return sqrt(px * px + py * py)
    var t = (px * vx + py * vy) / len2
    t = clamp(t, 0.0, 1.0)
    let dx = px - t * vx
    let dy = py - t * vy
    sqrt(dx * dx + dy * dy)
  of cvArc:
    let a = angleOf(c.center, p)
    if sweepContains(c, a):
      abs(distance(c.center, p) - c.radius.raw.float)
    else:
      min(distance(startPoint(c), p), distance(endPoint(c), p))

# ---------------------------------------------------------------- Path / Polygon

proc path*(curves: seq[Curve], closed = false): Path =
  Path(curves: curves, closed: closed)

proc polyline*(pts: openArray[Point], closed = false): Path =
  ## Convenience for the common all-straight case.
  result.closed = closed
  for i in 0 ..< pts.len - 1:
    result.curves.add(seg(pts[i], pts[i + 1]))
  if closed and pts.len > 2 and pts[^1] != pts[0]:
    result.curves.add(seg(pts[^1], pts[0]))

proc box*(p: Path): Box =
  result = emptyBox()
  for c in p.curves:
    result = union(result, box(c))

proc flatten*(p: Path, tol = DefaultFlattenTol): seq[Point] =
  for i, c in p.curves:
    let pts = flatten(c, tol)
    if i == 0:
      result.add(pts)
    else:
      result.add(pts[1 .. ^1])

proc signedArea*(p: Path, tol = DefaultFlattenTol): float =
  ## Shoelace area of the flattened ring. Positive is counter-clockwise.
  let pts = flatten(p, tol)
  if pts.len < 3: return 0.0
  var acc = 0.0
  for i in 0 ..< pts.len:
    let a = pts[i]
    let b = pts[(i + 1) mod pts.len]
    acc += a.x.raw.float * b.y.raw.float - b.x.raw.float * a.y.raw.float
  acc / 2.0

proc reversed*(p: Path): Path =
  result.closed = p.closed
  for i in countdown(p.curves.high, 0):
    let c = p.curves[i]
    case c.kind
    of cvSeg:
      result.curves.add(seg(c.b, c.a))
    of cvArc:
      result.curves.add(arc(c.center, c.radius, c.startAngle + c.sweep, -c.sweep))

proc box*(poly: Polygon): Box =
  ## Holes lie inside the outer ring, so the outer ring alone bounds it.
  box(poly.outer)

proc normalize*(poly: var Polygon) =
  ## Forces canonical winding: outer counter-clockwise, holes clockwise.
  if signedArea(poly.outer) < 0:
    poly.outer = reversed(poly.outer)
  for i in 0 ..< poly.holes.len:
    if signedArea(poly.holes[i]) > 0:
      poly.holes[i] = reversed(poly.holes[i])

proc normalized*(poly: Polygon): Polygon =
  result = poly
  result.normalize()

proc pointInRing(pts: seq[Point], p: Point): bool =
  ## Ray-casting, counting crossings of a +X ray from `p`.
  if pts.len < 3: return false
  let px = p.x.raw.float
  let py = p.y.raw.float
  var inside = false
  var j = pts.high
  for i in 0 ..< pts.len:
    let
      xi = pts[i].x.raw.float
      yi = pts[i].y.raw.float
      xj = pts[j].x.raw.float
      yj = pts[j].y.raw.float
    if (yi > py) != (yj > py):
      let xInt = xi + (py - yi) / (yj - yi) * (xj - xi)
      if px < xInt: inside = not inside
    j = i
  inside

proc contains*(poly: Polygon, p: Point, tol = DefaultFlattenTol): bool =
  ## Inside the outer ring and outside every hole.
  if not pointInRing(flatten(poly.outer, tol), p): return false
  for h in poly.holes:
    if pointInRing(flatten(h, tol), p): return false
  true

proc distanceTo*(p: Path, q: Point): float =
  result = Inf
  for c in p.curves:
    result = min(result, distanceTo(c, q))

# ---------------------------------------------------------------- Aperture

proc rectPolygon*(w, h: Nm, at = pt(nm(0), nm(0))): Polygon =
  let
    hw = w div 2
    hh = h div 2
  Polygon(outer: polyline([pt(at.x - hw, at.y - hh), pt(at.x + hw, at.y - hh),
                           pt(at.x + hw, at.y + hh), pt(at.x - hw, at.y + hh)],
                          closed = true))

proc box*(a: Aperture): Box =
  ## Bounding box in the aperture's own local frame, centred on its origin.
  if a == nil: return emptyBox()
  template sym(w, h: Nm): Box =
    Box(lo: pt(-(w div 2), -(h div 2)), hi: pt(w div 2, h div 2))
  case a.kind
  of akCircle: sym(a.dia, a.dia)
  of akRect, akOval: sym(a.w, a.h)
  of akRoundRect, akChamferRect: sym(a.rw, a.rh)
  of akTrapezoid: sym(a.tw + abs(a.deltaX), a.th + abs(a.deltaY))
  of akOctagon: sym(a.ow, a.oh)
  of akThermal: sym(a.outerDia, a.outerDia)
  of akPolygon, akCustom: box(a.outline)

proc containsLocal*(a: Aperture, p: Point, tol = DefaultFlattenTol): bool =
  ## Hit test in the aperture's own local frame.
  ##
  ## `akChamferRect` is tested as its bounding rectangle and `akThermal` as a
  ## plain annulus (spokes ignored) -- both are deliberate approximations that
  ## over-report slightly; a reader needing exactness should supply an
  ## `akCustom` outline instead.
  if a == nil: return false
  let
    x = p.x.raw.float
    y = p.y.raw.float
  case a.kind
  of akCircle:
    let r = a.dia.raw.float / 2.0
    x * x + y * y <= r * r
  of akRect, akChamferRect:
    let b = box(a)
    b.contains(p)
  of akOval:
    let
      rw = a.w.raw.float / 2.0
      rh = a.h.raw.float / 2.0
    if rw <= 0 or rh <= 0: false
    else: (x / rw) * (x / rw) + (y / rh) * (y / rh) <= 1.0
  of akRoundRect:
    let
      hw = a.rw.raw.float / 2.0
      hh = a.rh.raw.float / 2.0
      r = min(a.corner.raw.float, min(hw, hh))
      ax = abs(x)
      ay = abs(y)
    if ax > hw or ay > hh: false
    elif ax <= hw - r or ay <= hh - r: true
    else:
      let dx = ax - (hw - r)
      let dy = ay - (hh - r)
      dx * dx + dy * dy <= r * r
  of akOctagon:
    # Rectangle intersected with a diagonal-cut diamond.
    let
      hw = a.ow.raw.float / 2.0
      hh = a.oh.raw.float / 2.0
      c = a.cut.raw.float
    if abs(x) > hw or abs(y) > hh: false
    elif c <= 0: true
    else: abs(x) + abs(y) <= hw + hh - c
  of akThermal:
    let
      d = sqrt(x * x + y * y)
      ri = a.innerDia.raw.float / 2.0
      ro = a.outerDia.raw.float / 2.0
    d >= ri and d <= ro
  of akTrapezoid:
    let
      hw = a.tw.raw.float / 2.0
      hh = a.th.raw.float / 2.0
      dx = a.deltaX.raw.float / 2.0
    if abs(y) > hh: false
    else:
      # Width tapers linearly from bottom to top by deltaX.
      let f = if hh <= 0: 0.0 else: y / hh
      abs(x) <= hw + dx * f
  of akPolygon, akCustom:
    contains(a.outline, p, tol)

# ---------------------------------------------------------------- Transform

proc apply*(t: Transform, p: Point): Point =
  ## Local to board coordinates: rotate by `t.rot` (counter-clockwise), then
  ## mirror about the local Y axis if asked, then translate by `t.origin`.
  let
    a = t.rot.toRadians
    ca = cos(a)
    sa = sin(a)
    x = p.x.raw.float
    y = p.y.raw.float
  var
    rx = x * ca - y * sa
    ry = x * sa + y * ca
  if t.mirrorX: rx = -rx
  pt(t.origin.x + nm(int64(round(rx))), t.origin.y + nm(int64(round(ry))))

proc apply*(t: Transform, c: Curve): Curve =
  case c.kind
  of cvSeg:
    seg(apply(t, c.a), apply(t, c.b))
  of cvArc:
    # Mirroring reverses the sweep direction and reflects the start angle.
    let newCenter = apply(t, c.center)
    if t.mirrorX:
      arc(newCenter, c.radius, deg(180.0) - (c.startAngle + t.rot), -c.sweep)
    else:
      arc(newCenter, c.radius, c.startAngle + t.rot, c.sweep)

proc apply*(t: Transform, p: Path): Path =
  result.closed = p.closed
  for c in p.curves:
    result.curves.add(apply(t, c))
  if t.mirrorX:
    result = reversed(result)

proc apply*(t: Transform, poly: Polygon): Polygon =
  result.outer = apply(t, poly.outer)
  for h in poly.holes:
    result.holes.add(apply(t, h))

proc apply*(t: Transform, s: Shape): Shape =
  case s.kind
  of shStroke:
    Shape(kind: shStroke, path: apply(t, s.path), width: s.width, cap: s.cap)
  of shFill:
    Shape(kind: shFill, poly: apply(t, s.poly))
  of shPad:
    Shape(kind: shPad, aperture: s.aperture, at: apply(t, s.at),
          rot: (if t.mirrorX: deg(180.0) - (s.rot + t.rot) else: s.rot + t.rot),
          mirrored: s.mirrored xor t.mirrorX)
  of shText:
    Shape(kind: shText, origin: apply(t, s.origin), text: s.text,
          height: s.height, thickness: s.thickness,
          angle: (if t.mirrorX: deg(180.0) - (s.angle + t.rot) else: s.angle + t.rot))

# ---------------------------------------------------------------- Shape

proc padTransform*(s: Shape): Transform =
  ## The local-to-board transform of a `shPad`.
  Transform(origin: s.at, rot: s.rot, mirrorX: s.mirrored)

proc box*(s: Shape): Box =
  case s.kind
  of shStroke:
    let half = s.width div 2
    let b = box(s.path)
    result = if b.isEmpty: b else: b.expand(half)
  of shFill:
    result = box(s.poly)
  of shPad:
    if s.aperture == nil: return emptyBox()
    # Rotate the local box corners rather than the shape, which is exact for
    # circles and a safe over-estimate for everything else.
    let
      lb = box(s.aperture)
      t = padTransform(s)
    if lb.isEmpty: return lb
    result = emptyBox()
    for c in [lb.lo, pt(lb.hi.x, lb.lo.y), lb.hi, pt(lb.lo.x, lb.hi.y)]:
      result.extendTo(apply(t, c))
  of shText:
    # Text metrics are font-dependent; approximate from the cell height and
    # a nominal 0.7 aspect per character.
    let
      w = nm(int64(round(s.height.raw.float * 0.7 * s.text.len.float)))
      h = s.height
      t = Transform(origin: s.origin, rot: s.angle, mirrorX: false)
    result = emptyBox()
    for c in [pt(nm(0), nm(0)), pt(w, nm(0)), pt(w, h), pt(nm(0), h)]:
      result.extendTo(apply(t, c))

proc contains*(s: Shape, p: Point, tol = DefaultFlattenTol): bool =
  ## Exact hit test, except where noted: `shStroke` treats every end cap as
  ## round, and `shText` tests its approximate bounding box.
  case s.kind
  of shStroke:
    distanceTo(s.path, p) <= s.width.raw.float / 2.0
  of shFill:
    contains(s.poly, p, tol)
  of shPad:
    if s.aperture == nil: return false
    # Invert the pad transform, then test in aperture-local space.
    let
      d = p - s.at
      a = -s.rot.toRadians
      ca = cos(a)
      sa = sin(a)
    var x = d.x.raw.float
    let y = d.y.raw.float
    if s.mirrored: x = -x
    let local = pt(nm(int64(round(x * ca - y * sa))),
                   nm(int64(round(x * sa + y * ca))))
    containsLocal(s.aperture, local, tol)
  of shText:
    box(s).contains(p)

proc distanceTo*(s: Shape, p: Point, tol = DefaultFlattenTol): float =
  ## Distance from `p` to the shape's edge, `0.0` when `p` is inside it.
  if contains(s, p, tol): return 0.0
  case s.kind
  of shStroke:
    max(0.0, distanceTo(s.path, p) - s.width.raw.float / 2.0)
  of shFill:
    var d = distanceTo(s.poly.outer, p)
    for h in s.poly.holes:
      d = min(d, distanceTo(h, p))
    d
  of shPad, shText:
    # Conservative: distance to the bounding box.
    let b = box(s)
    if b.isEmpty: return Inf
    let
      dx = max(max((b.lo.x - p.x).raw.float, 0.0), (p.x - b.hi.x).raw.float)
      dy = max(max((b.lo.y - p.y).raw.float, 0.0), (p.y - b.hi.y).raw.float)
    sqrt(dx * dx + dy * dy)

proc stroke*(p: Path, width: Nm, cap = ecRound): Shape =
  Shape(kind: shStroke, path: p, width: width, cap: cap)

proc fill*(poly: Polygon): Shape =
  Shape(kind: shFill, poly: poly)

proc pad*(a: Aperture, at: Point, rot = deg(0.0), mirrored = false): Shape =
  Shape(kind: shPad, aperture: a, at: at, rot: rot, mirrored: mirrored)
