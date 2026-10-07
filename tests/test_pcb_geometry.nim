import std/[math, unittest]

import verax/pcb/geometry

proc approx(a, b: float, tol = 1.0): bool = abs(a - b) <= tol

test "box normalises corners and tracks emptiness":
  let b = boxOf(pt(mm(2.0), mm(3.0)), pt(mm(0.0), mm(1.0)))
  check b.lo == pt(mm(0.0), mm(1.0))
  check b.hi == pt(mm(2.0), mm(3.0))
  check b.width == mm(2.0)
  check b.height == mm(2.0)
  check b.center == pt(mm(1.0), mm(2.0))
  check emptyBox().isEmpty
  check not b.isEmpty
  check b.contains(pt(mm(1.0), mm(2.0)))
  check not b.contains(pt(mm(5.0), mm(2.0)))
  check b.overlaps(boxOf(pt(mm(1.5), mm(1.5)), pt(mm(9.0), mm(9.0))))
  check not b.overlaps(boxOf(pt(mm(9.0), mm(9.0)), pt(mm(10.0), mm(10.0))))

test "segment bounding box spans its endpoints":
  check box(seg(pt(mm(0.0), mm(0.0)), pt(mm(3.0), mm(-1.0)))) ==
    boxOf(pt(mm(0.0), mm(-1.0)), pt(mm(3.0), mm(0.0)))

test "arc bounding box includes swept axis crossings, not just endpoints":
  # Upper half circle: the top is an extreme neither endpoint touches.
  let a = arc(pt(mm(0.0), mm(0.0)), mm(1.0), deg(0.0), deg(180.0))
  let b = box(a)
  check approx(b.lo.x.raw.float, mm(-1.0).raw.float)
  check approx(b.lo.y.raw.float, 0.0)
  check approx(b.hi.x.raw.float, mm(1.0).raw.float)
  check approx(b.hi.y.raw.float, mm(1.0).raw.float)

  # A first-quadrant quarter arc crosses no extreme: endpoints only.
  let q = arc(pt(mm(0.0), mm(0.0)), mm(1.0), deg(0.0), deg(90.0))
  check approx(box(q).lo.x.raw.float, 0.0)
  check approx(box(q).lo.y.raw.float, 0.0)

  # A full circle bounds symmetrically whatever the start angle.
  let full = circleCurve(pt(mm(5.0), mm(5.0)), mm(2.0))
  check box(full) == boxOf(pt(mm(3.0), mm(3.0)), pt(mm(7.0), mm(7.0)))

test "arcFrom3Points and arcFromEndpointsCenter agree":
  let
    center = pt(mm(0.0), mm(0.0))
    radius = mm(1.0)
    reference = arc(center, radius, deg(0.0), deg(90.0))
    s = startPoint(reference)
    e = endPoint(reference)
    midPt = pointOnArc(reference, deg(45.0))

  let viaThree = arcFrom3Points(s, midPt, e)
  check viaThree.kind == cvArc
  check approx(viaThree.center.x.raw.float, 0.0)
  check approx(viaThree.center.y.raw.float, 0.0)
  check approx(viaThree.radius.raw.float, radius.raw.float)
  check approx(viaThree.sweep.value, 90.0, 0.01)

  let viaCenter = arcFromEndpointsCenter(s, e, center, clockwise = false)
  check approx(viaCenter.sweep.value, 90.0, 0.01)
  check approx(distance(startPoint(viaThree), startPoint(viaCenter)), 0.0, 2.0)
  check approx(distance(endPoint(viaThree), endPoint(viaCenter)), 0.0, 2.0)

  # The clockwise flag picks the other way round the same circle.
  let cw = arcFromEndpointsCenter(s, e, center, clockwise = true)
  check approx(cw.sweep.value, -270.0, 0.01)

test "collinear three-point input degrades to a segment rather than raising":
  let c = arcFrom3Points(pt(mm(0.0), mm(0.0)), pt(mm(1.0), mm(0.0)),
                         pt(mm(2.0), mm(0.0)))
  check c.kind == cvSeg

test "polygon winding normalises to CCW outer, CW holes":
  # Authored clockwise, as ODB++ gives an island.
  var poly = Polygon(
    outer: polyline([pt(mm(0.0), mm(0.0)), pt(mm(0.0), mm(4.0)),
                     pt(mm(4.0), mm(4.0)), pt(mm(4.0), mm(0.0))], closed = true),
    holes: @[polyline([pt(mm(1.0), mm(1.0)), pt(mm(2.0), mm(1.0)),
                       pt(mm(2.0), mm(2.0)), pt(mm(1.0), mm(2.0))], closed = true)])
  check signedArea(poly.outer) < 0
  check signedArea(poly.holes[0]) > 0
  poly.normalize()
  check signedArea(poly.outer) > 0
  check signedArea(poly.holes[0]) < 0

test "polygon containment respects holes":
  var poly = Polygon(
    outer: polyline([pt(mm(0.0), mm(0.0)), pt(mm(4.0), mm(0.0)),
                     pt(mm(4.0), mm(4.0)), pt(mm(0.0), mm(4.0))], closed = true),
    holes: @[polyline([pt(mm(1.0), mm(1.0)), pt(mm(1.0), mm(3.0)),
                       pt(mm(3.0), mm(3.0)), pt(mm(3.0), mm(1.0))], closed = true)])
  poly.normalize()
  check poly.contains(pt(mm(0.5), mm(0.5)))
  check not poly.contains(pt(mm(2.0), mm(2.0)))
  check not poly.contains(pt(mm(5.0), mm(2.0)))

test "stroked track bounds and hit-tests around its centreline":
  let s = stroke(polyline([pt(mm(0.0), mm(0.0)), pt(mm(10.0), mm(0.0))]), mm(0.2))
  check box(s) == boxOf(pt(mm(-0.1), mm(-0.1)), pt(mm(10.1), mm(0.1)))
  check s.contains(pt(mm(5.0), mm(0.05)))
  check not s.contains(pt(mm(5.0), mm(0.5)))
  check approx(distanceTo(s, pt(mm(5.0), mm(0.5))), mm(0.4).raw.float, 2.0)
  check distanceTo(s, pt(mm(5.0), mm(0.0))) == 0.0

test "aperture hit tests cover the common pad shapes":
  let circ = Aperture(name: "r500", kind: akCircle, dia: mm(0.5))
  check circ.containsLocal(pt(mm(0.2), mm(0.0)))
  check not circ.containsLocal(pt(mm(0.3), mm(0.0)))
  check box(circ) == boxOf(pt(mm(-0.25), mm(-0.25)), pt(mm(0.25), mm(0.25)))

  let rect = Aperture(name: "rect1x2", kind: akRect, w: mm(1.0), h: mm(2.0))
  check rect.containsLocal(pt(mm(0.49), mm(0.99)))
  check not rect.containsLocal(pt(mm(0.51), mm(0.0)))

  let oval = Aperture(name: "oval2x1", kind: akOval, w: mm(2.0), h: mm(1.0))
  check oval.containsLocal(pt(mm(0.9), mm(0.0)))
  check not oval.containsLocal(pt(mm(0.9), mm(0.4)))

  let rr = Aperture(name: "rr", kind: akRoundRect, rw: mm(2.0), rh: mm(2.0),
                    corner: mm(0.5), corners: {cnTopRight, cnTopLeft,
                                               cnBottomLeft, cnBottomRight})
  check rr.containsLocal(pt(mm(0.0), mm(0.0)))
  check rr.containsLocal(pt(mm(0.9), mm(0.0)))
  check not rr.containsLocal(pt(mm(0.99), mm(0.99)))  # clipped corner

test "pad transform rotates the flash and its box":
  let a = Aperture(name: "rect2x1", kind: akRect, w: mm(2.0), h: mm(1.0))
  let flat = pad(a, pt(mm(10.0), mm(10.0)))
  check flat.contains(pt(mm(10.9), mm(10.0)))
  check not flat.contains(pt(mm(10.0), mm(10.9)))

  let turned = pad(a, pt(mm(10.0), mm(10.0)), rot = deg(90.0))
  check not turned.contains(pt(mm(10.9), mm(10.0)))
  check turned.contains(pt(mm(10.0), mm(10.9)))
  let tb = box(turned)
  check approx(tb.width.raw.float, mm(1.0).raw.float, 2.0)
  check approx(tb.height.raw.float, mm(2.0).raw.float, 2.0)

test "Transform maps footprint-local coordinates onto the board":
  # CCW-positive in Y-up: +X rotated 90 lands on +Y, then translates.
  let t = Transform(origin: pt(mm(100.0), mm(50.0)), rot: deg(90.0))
  let p = t.apply(pt(mm(1.0), mm(0.0)))
  check approx(p.x.raw.float, mm(100.0).raw.float, 2.0)
  check approx(p.y.raw.float, mm(51.0).raw.float, 2.0)

  # Identity is a pure translation.
  let id = Transform(origin: pt(mm(5.0), mm(5.0)), rot: deg(0.0))
  check id.apply(pt(mm(1.0), mm(2.0))) == pt(mm(6.0), mm(7.0))

  # Mirroring flips X after rotation and reverses an arc's sweep.
  let m = Transform(origin: pt(mm(0.0), mm(0.0)), rot: deg(0.0), mirrorX: true)
  check m.apply(pt(mm(1.0), mm(2.0))) == pt(mm(-1.0), mm(2.0))
  let turned = m.apply(arc(pt(mm(0.0), mm(0.0)), mm(1.0), deg(0.0), deg(90.0)))
  check turned.sweep.value == -90.0

test "flattening an arc stays within the chord tolerance":
  let a = arc(pt(mm(0.0), mm(0.0)), mm(10.0), deg(0.0), deg(360.0))
  let pts = flatten(a, um(1.0))
  check pts.len > 8
  for p in pts:
    check approx(distance(pt(mm(0.0), mm(0.0)), p), mm(10.0).raw.float, 10.0)

test "a quarter-circle arc measures pi*r/2, exactly, not through flatten":
  # An arc's `length` must be exact; a chord always undershoots, biasing net
  # totals.
  let r = mm(5.0)
  let quarter = arc(pt(mm(0.0), mm(0.0)), r, deg(0.0), deg(90.0))
  let want = PI * r.toMm / 2.0 / 1000.0    # metres
  check approx(length(quarter), want, 1e-9)

  # Sweep direction doesn't change magnitude.
  let full = arc(pt(mm(0.0), mm(0.0)), r, deg(0.0), deg(360.0))
  check approx(length(full), 2.0 * PI * r.toMm / 1000.0, 1e-9)
  let reverse = arc(pt(mm(0.0), mm(0.0)), r, deg(90.0), deg(-90.0))
  check approx(length(reverse), want, 1e-9)

test "a segment's length is its endpoint distance, in metres":
  let s = seg(pt(mm(0.0), mm(0.0)), pt(mm(3.0), mm(4.0)))
  check approx(length(s), 0.005, 1e-9)    # 3-4-5 triangle, 5mm = 0.005m

test "a path's length sums its curves":
  let p = path(@[seg(pt(mm(0.0), mm(0.0)), pt(mm(3.0), mm(0.0))),
                seg(pt(mm(3.0), mm(0.0)), pt(mm(3.0), mm(4.0)))])
  check approx(length(p), 0.007, 1e-9)

test "an arc's exact length differs from its flattened polyline, by less than the chord tolerance":
  let r = mm(10.0)
  let a = arc(pt(mm(0.0), mm(0.0)), r, deg(0.0), deg(180.0))
  let exact = length(a)
  var polyLen = 0.0
  let pts = flatten(a, DefaultFlattenTol)
  for i in 0 ..< pts.len - 1:
    polyLen += distance(pts[i], pts[i + 1]) * 1e-9
  # The polyline is shorter, but by less than the scaled sagitta tolerance.
  check polyLen < exact
  check exact - polyLen < DefaultFlattenTol.toMetres * pts.len.float

test "endpoints reads a stroked shape's ends and raises on anything else":
  let s = stroke(polyline([pt(mm(0.0), mm(0.0)), pt(mm(5.0), mm(0.0)),
                           pt(mm(5.0), mm(5.0))]), mm(0.2))
  let (a, b) = endpoints(s)
  check a == pt(mm(0.0), mm(0.0))
  check b == pt(mm(5.0), mm(5.0))

  let filled = fill(rectPolygon(mm(1.0), mm(1.0)))
  expect(GeometryError):
    discard endpoints(filled)
