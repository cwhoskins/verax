## The schematic pipeline: layout/routing, SVG, the JSON API, and the
## run-archive SVG.
##
## What's pinned is not aesthetic: the same netlist renders the same scene;
## placement never mutates the graph; rails are detected by annotation, not
## name; unknown kinds and hierarchical instances fall back to a box; and the
## archive SVG is a pure function of the netlist.

import std/[algorithm, json, math, os, sets, streams, strutils, tables, tempfiles, unittest]

import verax/netlist
import verax/netlist/formats/spice
import verax/schematic
import verax/spice/ngspice

import designs/lib/riaa

let haveNgspice = findExe("ngspice").len > 0

proc divider(): Netlist =
  ## A divider with an output cap and an unmodelled MCU (its VDD pin makes
  ## `vin` a rail; its kind has no symbol).
  result = newNetlist("rc_divider")
  let vin = addNet(result, newNet("vin"))
  let vout = addNet(result, newNet("vout"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "DC 10 AC 1"

  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", vout, ptPassive)
  r1.attrs["value"] = "1k"

  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", vout, ptPassive)
  discard connect(r2, "2", gnd, ptPassive)
  r2.attrs["value"] = "1k"

  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vout, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)
  c1.attrs["value"] = "100n"

  let u1 = addComponent(result, newComponent("U1", kind = "mcu"))
  discard connect(u1, "VDD", vin, ptPower)
  discard connect(u1, "GND", gnd, ptGround)
  discard connect(u1, "SDA", vout, ptInOut)
  discard connect(u1, "SCL", vout, ptInOut)

proc plainDivider(): Netlist =
  ## A simulatable RC divider, for the archive test.
  result = newNetlist("rc_divider")
  let vin = addNet(result, newNet("vin"))
  let vout = addNet(result, newNet("vout"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "DC 10 AC 1"

  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", vout, ptPassive)
  r1.attrs["value"] = "1k"

  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", vout, ptPassive)
  discard connect(r2, "2", gnd, ptPassive)
  r2.attrs["value"] = "1k"

  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vout, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)
  c1.attrs["value"] = "100n"

proc fullRiaaTop(): Netlist =
  ## A top sheet of two `riaaChannel()` instances plus supplies. Each of the
  ## four signal nets touches only the channel box's port, so each must be
  ## drawn as a fallback marker.
  result = newNetlist("riaa_top")
  let gnd = addNet(result, newNet("0", ntGround))
  let vp = addNet(result, newNet("vp", ntPower))
  let vn = addNet(result, newNet("vn", ntPower))
  let inL = addNet(result, newNet("inL"))
  let outL = addNet(result, newNet("outL"))
  let inR = addNet(result, newNet("inR"))
  let outR = addNet(result, newNet("outR"))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vp, ptPower)
  discard connect(v1, "-", gnd, ptGround)
  v1.attrs["value"] = "DC 15"
  let v2 = addComponent(result, newComponent("V2", kind = "voltage_source"))
  discard connect(v2, "+", vn, ptPower)
  discard connect(v2, "-", gnd, ptGround)
  v2.attrs["value"] = "DC -15"
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vp, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)
  c1.attrs["value"] = "220u"
  let c2 = addComponent(result, newComponent("C2", kind = "capacitor"))
  discard connect(c2, "1", vn, ptPassive)
  discard connect(c2, "2", gnd, ptPassive)
  c2.attrs["value"] = "220u"

  var globals = initOrderedTable[string, Net]()
  globals["0"] = gnd
  discard instantiate(result, "XL", riaaChannel(), @[inL, outL, vp, vn, gnd],
                      globals)
  discard instantiate(result, "XR", riaaChannel(), @[inR, outR, vp, vn, gnd],
                      globals)

proc partOf(s: Schematic, desig: string): SchematicPart =
  for p in s.parts:
    if p.designator == desig: return p
  doAssert false, "no part named " & desig

proc coStacked(a, b: SchematicPart, pitch = 80.0): bool =
  ## An orientable composite may turn through 0/90/180/270, so its two members
  ## share one axis coordinate and sit `pitch` apart on the other.
  ((abs(a.x - b.x) < 1e-6 and abs(abs(a.y - b.y) - pitch) < 1e-6) or
   (abs(a.y - b.y) < 1e-6 and abs(abs(a.x - b.x) - pitch) < 1e-6))

proc unitVertical(members: openArray[SchematicPart]): bool =
  ## Whether a rigid composite unit runs along y. Ties -> vertical.
  var minX, minY = Inf
  var maxX, maxY = -Inf
  for m in members:
    minX = min(minX, m.x); maxX = max(maxX, m.x)
    minY = min(minY, m.y); maxY = max(maxY, m.y)
  (maxY - minY) >= (maxX - minX)

proc sceneBBox(s: Schematic): tuple[x1, y1, x2, y2: float] =
  result = (x1: Inf, y1: Inf, x2: -Inf, y2: -Inf)
  for p in s.parts:
    result.x1 = min(result.x1, p.x - p.bodyW / 2.0)
    result.y1 = min(result.y1, p.y - p.bodyH / 2.0)
    result.x2 = max(result.x2, p.x + p.bodyW / 2.0)
    result.y2 = max(result.y2, p.y + p.bodyH / 2.0)

proc wirePoints(s: Schematic, net: string): seq[Point] =
  for w in s.wires:
    if w.net == net:
      for p in w.points: result.add p

proc pinPoints(s: Schematic, desig, net: string): seq[Point] =
  for pin in partOf(s, desig).pins:
    if pin.net == net: result.add Point(x: pin.x, y: pin.y)

proc visualBends(poly: seq[Point]): int =
  ## Direction changes along a polyline, counting every interior vertex.
  for k in 1 ..< poly.len - 1:
    let a = poly[k - 1]
    let b = poly[k]
    let c = poly[k + 1]
    let abHoriz = abs(a.y - b.y) < 1e-9
    let bcHoriz = abs(b.y - c.y) < 1e-9
    if abHoriz != bcHoriz: inc result

proc routeBends(poly: seq[Point]): int =
  ## Direction changes along a signal wire's routed portion; the first and
  ## last segments are free pin stubs.
  for k in 2 ..< poly.len - 2:
    let a = poly[k - 1]
    let b = poly[k]
    let c = poly[k + 1]
    let abHoriz = abs(a.y - b.y) < 1e-9
    let bcHoriz = abs(b.y - c.y) < 1e-9
    if abHoriz != bcHoriz: inc result

proc segCrossesRect(a, b: Point, r: tuple[x1, y1, x2, y2: float]): bool =
  ## Strict-interior crossing of an axis-aligned segment and a rectangle.
  const eps = 1e-9
  if abs(a.x - b.x) < eps:            # vertical
    if a.x <= r.x1 + eps or a.x >= r.x2 - eps: return false
    let lo = min(a.y, b.y)
    let hi = max(a.y, b.y)
    return hi > r.y1 + eps and lo < r.y2 - eps
  elif abs(a.y - b.y) < eps:          # horizontal
    if a.y <= r.y1 + eps or a.y >= r.y2 - eps: return false
    let lo = min(a.x, b.x)
    let hi = max(a.x, b.x)
    return hi > r.x1 + eps and lo < r.x2 - eps
  false

proc inflatedRect(p: SchematicPart): tuple[x1, y1, x2, y2: float] =
  ## The part body inflated by the fixed routing clearance (12 world units).
  let hw = p.bodyW / 2.0 + 12.0
  let hh = p.bodyH / 2.0 + 12.0
  (x1: p.x - hw, y1: p.y - hh, x2: p.x + hw, y2: p.y + hh)

proc pinPartIndex(s: Schematic): Table[Point, int] =
  ## Pin point -> index of the part it belongs to.
  for i, p in s.parts:
    for pin in p.pins:
      result[Point(x: pin.x, y: pin.y)] = i

proc positiveOverlapT(a1, a2, b1, b2: float): bool =
  let lo = max(min(a1, a2), min(b1, b2))
  let hi = min(max(a1, a2), max(b1, b2))
  hi - lo > 1e-9

proc collinearOverlapT(a, b, c, d: Point): bool =
  ## Whether segments a-b and c-d share a positive-length collinear run.
  let av = abs(a.x - b.x) < 1e-9
  let cv = abs(c.x - d.x) < 1e-9
  if av != cv: return false
  if av:
    return abs(a.x - c.x) < 1e-9 and positiveOverlapT(a.y, b.y, c.y, d.y)
  else:
    return abs(a.y - c.y) < 1e-9 and positiveOverlapT(a.x, b.x, c.x, d.x)

proc distinctWiresNeverShareCollinearRuns(s: Schematic): bool =
  ## Distinct wires of one net may meet at a vertex or cross, but never share
  ## a collinear run. `wkChain` arcs are annotations and exempt.
  for i in 0 ..< s.wires.len:
    if s.wires[i].kind == wkChain: continue
    for k in 0 ..< s.wires[i].points.high:
      let a = s.wires[i].points[k]
      let b = s.wires[i].points[k + 1]
      if abs(a.x - b.x) < 1e-9 and abs(a.y - b.y) < 1e-9: continue
      for j in 0 ..< i:
        if s.wires[j].kind == wkChain: continue
        for m in 0 ..< s.wires[j].points.high:
          if collinearOverlapT(a, b, s.wires[j].points[m],
                               s.wires[j].points[m + 1]):
            return false
  true

proc closedIntervalIntersectT(a1, a2, b1, b2: float): bool =
  let lo = max(min(a1, a2), min(b1, b2))
  let hi = min(max(a1, a2), max(b1, b2))
  hi >= lo - 1e-9

proc collinearTouchT(a, b, c, d: Point): bool =
  ## Whether segments a-b and c-d are collinear and share any point
  ## (overlap or end-to-end touch).
  let av = abs(a.x - b.x) < 1e-9
  let cv = abs(c.x - d.x) < 1e-9
  if av != cv: return false
  if av:
    return abs(a.x - c.x) < 1e-9 and
           closedIntervalIntersectT(a.y, b.y, c.y, d.y)
  else:
    return abs(a.y - c.y) < 1e-9 and
           closedIntervalIntersectT(a.x, b.x, c.x, d.x)

proc parallelTooCloseT(a, b, c, d: Point): bool =
  ## Whether segments are parallel on distinct lines < 8 units apart with
  ## projections overlapping by more than a point.
  const sep = 8.0
  let av = abs(a.x - b.x) < 1e-9
  let cv = abs(c.x - d.x) < 1e-9
  if av != cv: return false
  if av:
    if abs(a.x - c.x) < 1e-9: return false
    if abs(a.x - c.x) >= sep - 1e-9: return false
    return positiveOverlapT(a.y, b.y, c.y, d.y)
  else:
    if abs(a.y - c.y) < 1e-9: return false
    if abs(a.y - c.y) >= sep - 1e-9: return false
    return positiveOverlapT(a.x, b.x, c.x, d.x)

proc differentNetsRespectSeparation(s: Schematic): bool =
  ## Wires of different nets never touch collinearly (even end-to-end) and
  ## keep 8 units of separation where they run parallel and overlap.
  var segs: seq[tuple[net: string, a, b: Point]]
  for w in s.wires:
    if w.kind == wkChain: continue      # a dashed annotation, not a routed net
    for k in 0 ..< w.points.high:
      let a = w.points[k]
      let b = w.points[k + 1]
      if abs(a.x - b.x) < 1e-9 and abs(a.y - b.y) < 1e-9: continue
      segs.add (w.net, a, b)
  for i in 0 ..< segs.len:
    for j in 0 ..< i:
      if segs[i].net == segs[j].net: continue
      if collinearTouchT(segs[i].a, segs[i].b, segs[j].a, segs[j].b): return false
      if parallelTooCloseT(segs[i].a, segs[i].b, segs[j].a, segs[j].b): return false
  true

proc fallbacksClearOfWires(s: Schematic): bool =
  ## A fallback stub is a marker, not connectivity: it obeys the cross-net
  ## rule against real wires. Perpendicular crossings are allowed.
  for f in s.fallbacks:
    for k in 0 ..< f.points.high:
      let a = f.points[k]
      let b = f.points[k + 1]
      if abs(a.x - b.x) < 1e-9 and abs(a.y - b.y) < 1e-9: continue
      for w in s.wires:
        for m in 0 ..< w.points.high:
          let c = w.points[m]
          let d = w.points[m + 1]
          if collinearTouchT(a, b, c, d): return false
          if parallelTooCloseT(a, b, c, d): return false
  true

proc escapeDirT(p: SchematicPart, pt: Point): Point =
  ## A placed pin's outward unit direction, by `layout.escapeDir`'s test.
  let dx = pt.x - p.x
  let dy = pt.y - p.y
  let hw = p.bodyW / 2.0
  let hh = p.bodyH / 2.0
  if abs(abs(dx) - hw) < abs(abs(dy) - hh):
    Point(x: (if dx >= 0.0: 1.0 else: -1.0), y: 0.0)
  else:
    Point(x: 0.0, y: (if dy >= 0.0: 1.0 else: -1.0))

proc escapeSeedsT(s: Schematic): seq[tuple[net: string, a, b: Point]] =
  ## The escape stubs `layout` protects: one per signal pin, one per interface
  ## port. Rail and ground nets have none.
  const clear = 12.0
  var railNets = initHashSet[string]()
  for w in s.wires:
    if w.kind in {wkGround, wkSupply}: railNets.incl w.net
  for p in s.parts:
    for pin in p.pins:
      if pin.net.len == 0 or pin.net in railNets: continue
      let pt = Point(x: pin.x, y: pin.y)
      let d = escapeDirT(p, pt)
      result.add (pin.net, pt, pt + d * clear)
  for port in s.ports:
    let inward = if abs(port.rotation) < 1e-9: Point(x: -1.0, y: 0.0)
                 else: Point(x: 1.0, y: 0.0)
    let conn = if abs(port.rotation) < 1e-9:
                 Point(x: port.x - port.bodyW / 2.0, y: port.y)
               else:
                 Point(x: port.x + port.bodyW / 2.0, y: port.y)
    result.add (port.net, conn, conn + inward * clear)

proc terminalGlyphSegmentsT(w: SchematicWire): seq[tuple[a, b: Point]] =
  ## The stem and bars `svg.renderSvg` draws for a rail terminal.
  if w.kind notin {wkGround, wkSupply} or w.points.len < 2: return
  let a = w.points[^2]
  let p = w.points[^1]
  let d = p - a
  let o = if abs(d.x) > abs(d.y):
            Point(x: (if d.x >= 0.0: 1.0 else: -1.0), y: 0.0)
          else:
            Point(x: 0.0, y: (if d.y >= 0.0: 1.0 else: -1.0))
  let q = Point(x: -o.y, y: o.x)
  result.add (a, p)
  result.add (p - q * 10.0, p + q * 10.0)
  if w.kind == wkGround:
    result.add (p + o * 4.0 - q * 6.0, p + o * 4.0 + q * 6.0)
    result.add (p + o * 8.0 - q * 2.0, p + o * 8.0 + q * 2.0)

proc segmentsTouchT(a, b, c, d: Point): bool =
  let av = abs(a.x - b.x) < 1e-9
  let cv = abs(c.x - d.x) < 1e-9
  if av == cv: return collinearTouchT(a, b, c, d)
  if av:
    return a.x >= min(c.x, d.x) - 1e-9 and a.x <= max(c.x, d.x) + 1e-9 and
           c.y >= min(a.y, b.y) - 1e-9 and c.y <= max(a.y, b.y) + 1e-9
  c.x >= min(a.x, b.x) - 1e-9 and c.x <= max(a.x, b.x) + 1e-9 and
    a.y >= min(c.y, d.y) - 1e-9 and a.y <= max(c.y, d.y) + 1e-9

proc signalWiresClearTerminalGlyphs(s: Schematic): bool =
  ## Signal geometry must clear both terminal stems and their visible bars.
  for w in s.wires:
    if w.kind != wkSignal: continue
    for k in 0 ..< w.points.high:
      for terminal in s.wires:
        if terminal.kind notin {wkGround, wkSupply}: continue
        for glyph in terminalGlyphSegmentsT(terminal):
          if segmentsTouchT(w.points[k], w.points[k + 1], glyph.a, glyph.b):
            return false
  true

proc fullTerminalGlyphsClearPlacementReservations(s: Schematic): bool =
  ## Judged against the prospective 40-unit glyph, not the possibly shortened
  ## emitted terminal: it must clear foreign signal corridors, inflated
  ## foreign bodies, and other nets' terminal ink.
  type Planned = object
    owner: int
    net: string
    glyphs: seq[tuple[a, b: Point]]
  let owners = pinPartIndex(s)
  let seeds = escapeSeedsT(s)
  var planned: seq[Planned]
  for w in s.wires:
    if w.kind notin {wkGround, wkSupply} or w.points.len < 1: continue
    let pt = w.points[0]
    let owner = owners.getOrDefault(pt, -1)
    if owner < 0: continue
    let endPt = pt + escapeDirT(s.parts[owner], pt) * 40.0
    planned.add Planned(owner: owner, net: w.net,
      glyphs: terminalGlyphSegmentsT(SchematicWire(net: w.net, kind: w.kind,
                                                    points: @[pt, endPt])))
  for ti, t in planned:
    for g in t.glyphs:
      for i, p in s.parts:
        if i != t.owner and segCrossesRect(g.a, g.b, inflatedRect(p)):
          return false
      for seed in seeds:
        if seed.net != t.net and segmentsTouchT(g.a, g.b, seed.a, seed.b):
          return false
    for ui, u in planned:
      if ui == ti or u.net == t.net: continue
      for g in t.glyphs:
        for h in u.glyphs:
          if segmentsTouchT(g.a, g.b, h.a, h.b): return false
  true

proc signalWiresRespectForeignSeeds(s: Schematic): bool =
  ## A signal wire may touch or cross a foreign-net escape seed but never run
  ## along it. Same-net seeds are excluded.
  let seeds = escapeSeedsT(s)
  for w in s.wires:
    if w.kind != wkSignal: continue
    for k in 0 ..< w.points.high:
      let a = w.points[k]
      let b = w.points[k + 1]
      if abs(a.x - b.x) < 1e-9 and abs(a.y - b.y) < 1e-9: continue
      for sd in seeds:
        if sd.net == w.net: continue
        if collinearOverlapT(a, b, sd.a, sd.b): return false
  true

proc labelBoxT(lb: SchematicLabel): tuple[x1, y1, x2, y2: float] =
  ## A label's ink box, by `layout`'s monospace estimate.
  let sz = if lb.size > 0.0: lb.size else: 12.0
  let w = float(lb.text.len) * 0.6 * sz
  let x1 = case lb.anchor
           of taStart: lb.x
           of taMiddle: lb.x - w / 2.0
           of taEnd: lb.x - w
  (x1, lb.y - 0.8 * sz, x1 + w, lb.y + 0.2 * sz)

proc partInkRectT(p: SchematicPart): tuple[x1, y1, x2, y2: float] =
  var w = p.inkW
  var h = p.inkH
  if abs(p.rotation - 90.0) < 1e-9 or abs(p.rotation - 270.0) < 1e-9:
    swap(w, h)
  (p.x - w / 2.0, p.y - h / 2.0, p.x + w / 2.0, p.y + h / 2.0)

proc rectsOverlapT(a, b: tuple[x1, y1, x2, y2: float]): bool =
  a.x1 < b.x2 - 1e-9 and b.x1 < a.x2 - 1e-9 and
  a.y1 < b.y2 - 1e-9 and b.y1 < a.y2 - 1e-9

proc labelsClearOfGeometry(s: Schematic): bool =
  ## No label crosses a wire, overlaps drawn part ink or a port body, or
  ## overlaps another label.
  for i, lb in s.labels:
    let box = labelBoxT(lb)
    for w in s.wires:
      for k in 0 ..< w.points.high:
        if segCrossesRect(w.points[k], w.points[k + 1], box): return false
    for p in s.parts:
      if rectsOverlapT(box, partInkRectT(p)): return false
    for p in s.ports:
      if rectsOverlapT(box, (p.x - p.bodyW / 2.0, p.y - p.bodyH / 2.0,
                             p.x + p.bodyW / 2.0, p.y + p.bodyH / 2.0)):
        return false
    for j in 0 ..< i:
      if rectsOverlapT(box, labelBoxT(s.labels[j])): return false
  true

proc axisGapToInk(box, ink: tuple[x1, y1, x2, y2: float]): float =
  ## The larger per-axis gap between two rects; 0 if they touch or overlap.
  let gx = max(0.0, max(box.x1 - ink.x2, ink.x1 - box.x2))
  let gy = max(0.0, max(box.y1 - ink.y2, ink.y1 - box.y2))
  max(gx, gy)

proc starNet(): Netlist =
  ## Three resistors whose pin 1 meet on one net, so it routes as a tree. Each
  ## pin 2 has its own net, so `parallelRecognize` can't collapse them into a
  ## composite and the ordinary router is exercised.
  result = newNetlist("star")
  let star = addNet(result, newNet("star"))
  for i in 1 .. 3:
    let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
    discard connect(r, "1", star, ptPassive)
    discard connect(r, "2", addNet(result, newNet("tail" & $i)), ptPassive)

proc resistorChain(n: int): Netlist =
  ## `n` resistors in series -- a crowded sheet for the separation pass.
  result = newNetlist("chain")
  var prev = addNet(result, newNet("n0"))
  for i in 1 .. n:
    let net = addNet(result, newNet("n" & $i))
    let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
    discard connect(r, "1", prev, ptPassive)
    discard connect(r, "2", net, ptPassive)
    prev = net

proc twoBlocks(): Netlist =
  ## Two RC pairs sharing no net.
  result = newNetlist("two_blocks")
  for b in 1 .. 2:
    let a = addNet(result, newNet("a" & $b))
    let m = addNet(result, newNet("m" & $b))
    let z = addNet(result, newNet("z" & $b))
    let r = addComponent(result, newComponent("R" & $b, kind = "resistor"))
    discard connect(r, "1", a, ptPassive)
    discard connect(r, "2", m, ptPassive)
    let c = addComponent(result, newComponent("C" & $b, kind = "capacitor"))
    discard connect(c, "1", m, ptPassive)
    discard connect(c, "2", z, ptPassive)

proc decoupledMcu(): Netlist =
  ## An MCU with a decoupling cap on its rail pair, plus an unrelated divider.
  ## The cap shares only VDD/GND with the MCU but must stay in its group.
  result = newNetlist("decoupled_mcu")
  let vdd = addNet(result, newNet("vdd", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))
  let io = addNet(result, newNet("io"))
  let u1 = addComponent(result, newComponent("U1", kind = "mcu"))
  discard connect(u1, "VDD", vdd, ptPower)
  discard connect(u1, "GND", gnd, ptGround)
  discard connect(u1, "IO", io, ptInOut)
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vdd, ptPower)
  discard connect(c1, "2", gnd, ptGround)
  let din = addNet(result, newNet("din"))
  let mid = addNet(result, newNet("mid"))
  let dout = addNet(result, newNet("dout"))
  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", din, ptPassive)
  discard connect(r1, "2", mid, ptPassive)
  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", mid, ptPassive)
  discard connect(r2, "2", dout, ptPassive)

proc parallelPairChain(n: int): Netlist =
  ## `n` parallel R||C pairs in series, driven by an `mcu` output and read by
  ## an `mcu` input. Each pair collapses to one placement unit: `2n + 2` raw
  ## parts but `n + 2` pool items. At `n = 33` that's 68 raw (over
  ## `constrainedMaxParts`) but 35 pooled (under it), so it must still get
  ## the constrained treatment.
  result = newNetlist("parallel_pair_chain")
  let first = addNet(result, newNet("n0"))
  let driver = addComponent(result, newComponent("U1", kind = "mcu"))
  discard connect(driver, "OUT", first, ptOutput)
  var prev = first
  for i in 1 .. n:
    let net = addNet(result, newNet("n" & $i))
    let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
    discard connect(r, "1", prev, ptPassive)
    discard connect(r, "2", net, ptPassive)
    let c = addComponent(result, newComponent("C" & $i, kind = "capacitor"))
    discard connect(c, "1", prev, ptPassive)
    discard connect(c, "2", net, ptPassive)
    prev = net
  let sink = addComponent(result, newComponent("U2", kind = "mcu"))
  discard connect(sink, "IN", prev, ptInput)

template withEnv(key, value: string, body: untyped) =
  let had = existsEnv(key)
  let old = getEnv(key)
  putEnv(key, value)
  try:
    body
  finally:
    if had: putEnv(key, old) else: delEnv(key)

# --- the scene, which needs no simulator --------------------------------

# `layout()` is slow (a 37-resistor chain ~16s), so tests that only read a
# scene share one module-level layout. Determinism tests re-run it on purpose.
let chain37 = layout(resistorChain(37))
let riaaChannelScene = layout(riaaChannel())
let riaaTopScene = layout(fullRiaaTop())

test "layout is deterministic":
  let nl = divider()
  let a = renderSvg(nl)
  let b = renderSvg(nl)
  check a == b
  check sceneToJsonString(nl) == sceneToJsonString(nl)

test "constrained layered policy keeps the hard invariants":
  # Opting in to `lpConstrainedLayered` still upholds the collinear-run and
  # cross-net separation rules.
  let nl = divider()
  let historical = layout(nl)
  var defaulted = defaultLayoutOptions()
  defaulted.policy = lpConstrainedLayered
  let constrained = layout(nl, defaulted)
  check constrained.parts.len == historical.parts.len
  check distinctWiresNeverShareCollinearRuns(constrained)
  check differentNetsRespectSeparation(constrained)

test "constrained layered policy places output flow in increasing columns":
  let nl = newNetlist("layered")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("b"))
  let c = addNet(nl, newNet("c"))
  let u1 = addComponent(nl, newComponent("U1", kind = "mcu"))
  discard connect(u1, "OUT", a, ptOutput)
  let u2 = addComponent(nl, newComponent("U2", kind = "mcu"))
  discard connect(u2, "IN", a, ptInput)
  discard connect(u2, "OUT", b, ptOutput)
  let u3 = addComponent(nl, newComponent("U3", kind = "mcu"))
  discard connect(u3, "IN", b, ptInput)
  discard connect(u3, "OUT", c, ptOutput)
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", c, ptPassive)
  discard connect(r1, "2", addNet(nl, newNet("d")), ptPassive)
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(nl, options)
  check partOf(s, "U1").x < partOf(s, "U2").x
  check partOf(s, "U2").x < partOf(s, "U3").x
  # The final sink has no declared output; it never reverses the flow.
  check partOf(s, "U3").x <= partOf(s, "R1").x

test "constrained layering follows input ports and feedback paths semantically":
  # The input port has no pin direction, so it uses portDirection's no-driver
  # fallback. The feedback case uses an unrecognised two-terminal kind, so
  # the walk is not passive-gated.
  block:
    let nl = newNetlist("port_input_layer")
    let inn = addNet(nl, newNet("IN"))
    let mid = addNet(nl, newNet("mid"))
    let link = addComponent(nl, newComponent("LINK", kind = "resistor"))
    discard connect(link, "1", inn, ptPassive)
    discard connect(link, "2", mid, ptPassive)
    let sink = addComponent(nl, newComponent("UIN", kind = "mcu"))
    discard connect(sink, "IN", mid, ptInput)
    addPort(nl, "IN", inn)
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    options.stages.excl lsRecoverRouting
    options.stages.excl lsRoutingAwareRepair
    let s = layout(nl, options)
    check partOf(s, "LINK").x < partOf(s, "UIN").x

  # The walk passes through a composite, not stopping at its first member: a
  # pi section between an input port and a sink must land left of the sink.
  # All three members share one pool item.
  block:
    let nl = newNetlist("pi_input_layer")
    let inn = addNet(nl, newNet("IN"))
    let mid = addNet(nl, newNet("mid"))
    let gnd = addNet(nl, newNet("0", ntGround))
    let rl = addComponent(nl, newComponent("RL", kind = "resistor"))
    discard connect(rl, "1", inn, ptPassive)
    discard connect(rl, "2", gnd, ptGround)
    let cin = addComponent(nl, newComponent("CIN", kind = "capacitor"))
    discard connect(cin, "1", inn, ptPassive)
    discard connect(cin, "2", mid, ptPassive)
    let rb = addComponent(nl, newComponent("RB", kind = "resistor"))
    discard connect(rb, "1", mid, ptPassive)
    discard connect(rb, "2", gnd, ptGround)
    let sink = addComponent(nl, newComponent("UIN", kind = "mcu"))
    discard connect(sink, "IN", mid, ptInput)
    discard connect(sink, "OUT", addNet(nl, newNet("out")), ptOutput)
    addPort(nl, "IN", inn)
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    options.stages.excl lsRecoverRouting
    options.stages.excl lsRoutingAwareRepair
    let s = layout(nl, options)
    check partOf(s, "CIN").x < partOf(s, "UIN").x
    check partOf(s, "RL").x < partOf(s, "UIN").x
    check partOf(s, "RB").x < partOf(s, "UIN").x

  # Likewise a tee: both series legs and the shunt land left of the sink.
  block:
    let nl = newNetlist("tee_input_layer")
    let inn = addNet(nl, newNet("IN"))
    let mid = addNet(nl, newNet("mid"))
    let outn = addNet(nl, newNet("sig"))
    let gnd = addNet(nl, newNet("0", ntGround))
    let l1 = addComponent(nl, newComponent("L1", kind = "inductor"))
    discard connect(l1, "1", inn, ptPassive)
    discard connect(l1, "2", mid, ptPassive)
    let l2 = addComponent(nl, newComponent("L2", kind = "inductor"))
    discard connect(l2, "1", mid, ptPassive)
    discard connect(l2, "2", outn, ptPassive)
    let cs = addComponent(nl, newComponent("CS", kind = "capacitor"))
    discard connect(cs, "1", mid, ptPassive)
    discard connect(cs, "2", gnd, ptGround)
    let sink = addComponent(nl, newComponent("UIN", kind = "mcu"))
    discard connect(sink, "IN", outn, ptInput)
    discard connect(sink, "OUT", addNet(nl, newNet("out")), ptOutput)
    addPort(nl, "IN", inn)
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    options.stages.excl lsRecoverRouting
    options.stages.excl lsRoutingAwareRepair
    let s = layout(nl, options)
    check partOf(s, "L1").x < partOf(s, "UIN").x
    check partOf(s, "L2").x < partOf(s, "UIN").x
    check partOf(s, "CS").x < partOf(s, "UIN").x

  # A feedback chain back to the same component is a local loop: the device
  # stays in the source's column.
  block:
    let nl = newNetlist("local_feedback")
    let outn = addNet(nl, newNet("out"))
    let fbn = addNet(nl, newNet("fb"))
    let amp = addComponent(nl, newComponent("U1", kind = "opamp"))
    discard connect(amp, "OUT", outn, ptOutput)
    discard connect(amp, "IN-", fbn, ptInput)
    let link = addComponent(nl, newComponent("RFB", kind = "mystery"))
    discard connect(link, "1", outn, ptPassive)
    discard connect(link, "2", fbn, ptPassive)
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    options.stages.excl lsRecoverRouting
    options.stages.excl lsRoutingAwareRepair
    let s = layout(nl, options)
    # A local return may stay co-column with its source.
    check abs(partOf(s, "RFB").x - partOf(s, "U1").x) <= 200.0

  # A return to an earlier component keeps the passive right of the output
  # that drives it.
  block:
    let nl = newNetlist("feedback_right")
    let out1 = addNet(nl, newNet("out1"))
    let out2 = addNet(nl, newNet("out2"))
    let fb = addNet(nl, newNet("fb"))
    let ctrl = addNet(nl, newNet("ctrl"))
    let link = addComponent(nl, newComponent("RFB", kind = "mystery"))
    discard connect(link, "1", out2, ptPassive)
    discard connect(link, "2", fb, ptPassive)
    let first = addComponent(nl, newComponent("U1", kind = "mcu"))
    discard connect(first, "OUT", out1, ptOutput)
    discard connect(first, "IN", fb, ptInput)
    let second = addComponent(nl, newComponent("U2", kind = "mcu"))
    discard connect(second, "IN", out1, ptInput)
    discard connect(second, "OUT", out2, ptOutput)
    # A third connected terminal stops the two-terminal walker.
    discard connect(second, "CTRL", ctrl, ptInOut)
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    options.stages.excl lsRecoverRouting
    options.stages.excl lsRoutingAwareRepair
    let s = layout(nl, options)
    check partOf(s, "U1").x < partOf(s, "U2").x
    check partOf(s, "U2").x < partOf(s, "RFB").x

test "constrained stages group parallel passives and bound RIAA aspect ratio":
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(riaaChannel(), options)
  # R7 || C5 and R8 || C6 are each one placement unit: adjacent and
  # co-stacked on one axis.
  check coStacked(partOf(s, "R7"), partOf(s, "C5"))
  check coStacked(partOf(s, "R8"), partOf(s, "C6"))
  # RL (shunt) -- CIN (series) -- RB (shunt) is a pi section: series
  # horizontal, a shunt one grid pitch below each pin (pi is not orientable).
  block:
    let cin = partOf(s, "CIN")
    let rl = partOf(s, "RL")
    let rb = partOf(s, "RB")
    check abs(cin.pins[0].y - cin.pins[1].y) < 1e-6
    check abs(rl.x - cin.x) == 40.0 and rl.y - cin.y == 80.0
    check abs(rb.x - cin.x) == 40.0 and rb.y - cin.y == 80.0
    check rl.x != rb.x
  let box = sceneBBox(s)
  let width = box.x2 - box.x1
  let height = box.y2 - box.y1
  check height <= 1.5 * width
  # Fallback count is placement-dependent; the constrained-chain case below
  # covers atomic fallbacks.
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(riaaChannel(), options) == s

test "a composite whose leg lands on a global net still packs on a child sheet":
  # `keepFullSchematic` draws each instance's cloned child, where ground "0"
  # is owned by the root. `onThisSheet` accepts that shared global so the
  # child's pi still packs.
  var top = newNetlist("riaa_top_pack")
  let gnd = addNet(top, newNet("0", ntGround))
  let vp = addNet(top, newNet("vp", ntPower))
  let vn = addNet(top, newNet("vn", ntPower))
  let inL = addNet(top, newNet("inL"))
  let outL = addNet(top, newNet("outL"))
  var globals = initOrderedTable[string, Net]()
  globals["0"] = gnd
  let xl = instantiate(top, "XL", riaaChannel(), @[inL, outL, vp, vn, gnd],
                       globals)
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(xl.subNetlist, options)
  let cin = partOf(s, "CIN")
  let rl = partOf(s, "RL")
  let rb = partOf(s, "RB")
  check abs(cin.pins[0].y - cin.pins[1].y) < 1e-6      # series horizontal
  check abs(rl.x - cin.x) == 40.0 and rl.y - cin.y == 80.0
  check abs(rb.x - cin.x) == 40.0 and rb.y - cin.y == 80.0
  check rl.x != rb.x
  check s.fallbacks.len == 0
  check layout(xl.subNetlist, options) == s

test "constrained layering admits a raw-over-gate sheet whose pool clears it":
  # 33 R||C pairs: 68 raw parts (over `constrainedMaxParts`) but 35 pool
  # items, so semantic layering must still run. The routing-feedback stages
  # are excluded so this measures placement (~1.9s debug).
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  options.stages.excl lsRecoverRouting
  options.stages.excl lsRoutingAwareRepair
  let nl = parallelPairChain(33)
  let s = layout(nl, options)
  check s.parts.len == 68
  check partOf(s, "U1").x < partOf(s, "U2").x
  for i in 1 .. 33:
    # Each R||C pair is one unit: adjacent and co-stacked.
    check coStacked(partOf(s, "R" & $i), partOf(s, "C" & $i))
  let box = sceneBBox(s)
  # Layering produces a wide, short sheet; the golden-spiral seed doesn't.
  check box.x2 - box.x1 > box.y2 - box.y1
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(nl, options) == s

test "constrained layering falls back cleanly once the pool itself exceeds the gate":
  # 63 pairs pool to 65, over `constrainedMaxParts`: `constrainedEligible`
  # refuses and `layout` must still produce a complete, valid scene from the
  # plain pipeline. A smoke test, not a quality test; the expensive stages
  # are excluded (~10s vs ~19s debug).
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  options.stages.excl lsRecoverRouting
  options.stages.excl lsRoutingAwareRepair
  options.stages.excl lsForcePlacement
  options.stages.excl lsPack
  options.stages.excl lsTerminalRepair
  let nl = parallelPairChain(63)
  let s = layout(nl, options)
  check s.parts.len == 128

test "layout produces one part per component, wired to the right nets":
  let s = layout(divider())
  check s.parts.len == 5
  check partOf(s, "R1").pins[0].net == "vin"
  check partOf(s, "R1").pins[1].net == "vout"
  check partOf(s, "C1").pins[1].net == "0"
  check partOf(s, "V1").pins[0].net == "vin"

test "symbol selection is keyed by kind":
  let s = layout(divider())
  check partOf(s, "R1").symbol == "resistor"
  check partOf(s, "C1").symbol == "capacitor"
  check partOf(s, "V1").symbol == "voltage_source"
  check not partOf(s, "R1").isBox

test "a fallback box places pins by type: power up, ground down, the rest split":
  let s = layout(divider())
  let u1 = partOf(s, "U1")
  check u1.isBox
  check u1.symbol == "box"
  check u1.pins.len == 4
  check u1.rotation == 0.0
  proc pin(n: string): SchematicPin =
    for p in u1.pins:
      if p.name == n: return p
    doAssert false, "no pin " & n
  # VDD is ptPower -> top edge, GND is ptGround -> bottom edge, both centred on x
  check pin("VDD").y < u1.y - 1e-6 and abs(pin("VDD").x - u1.x) < 1e-6
  check pin("GND").y > u1.y + 1e-6 and abs(pin("GND").x - u1.x) < 1e-6
  # SDA and SCL are the remaining pins, one to each side
  check (pin("SDA").x < u1.x) != (pin("SCL").x < u1.x)
  check abs(pin("SDA").y - u1.y) < 1e-6 and abs(pin("SCL").y - u1.y) < 1e-6
  # every pin sits on the body extent, `boxStub` outside the drawn body
  for p in u1.pins:
    let onSide = abs(abs(p.x - u1.x) - u1.bodyW / 2.0) < 1e-6
    let onEnd = abs(abs(p.y - u1.y) - u1.bodyH / 2.0) < 1e-6
    check onSide or onEnd

test "a hierarchical instance draws as a box":
  let nl = readNetlist(newStringStream("""Hier Box
.SUBCKT BUF IN OUT
R1 IN OUT 100
.ENDS BUF
X1 net1 net2 BUF
R2 net2 0 1k
.END
"""))
  let s = layout(nl)
  let x1 = partOf(s, "X1")
  check x1.isBox
  check x1.symbol == "box"
  check x1.pins.len == 2
  check x1.rotation == 0.0

test "ground nets are stubbed, never routed":
  let s = layout(divider())
  for w in s.wires:
    if w.net == "0":
      # A ground stub, or `wkPowerLink` for a parallel composite's fanout to
      # its shared glyph -- never `wkSignal`, never more than 2 points.
      check w.kind in {wkGround, wkPowerLink}
      check w.points.len == 2
  var routed = false
  for w in s.wires:
    if w.net == "0" and w.kind == wkSignal: routed = true
  check not routed

test "a power rail is stubbed and labelled":
  let nl = newNetlist("rail")
  let vcc = addNet(nl, newNet("vcc", ntPower))
  let gnd = addNet(nl, newNet("0", ntGround))
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vcc, ptPower)
  discard connect(r1, "2", gnd, ptPassive)
  let s = layout(nl)
  var sawSupply = false
  for w in s.wires:
    if w.net == "vcc":
      check w.kind == wkSupply
      sawSupply = true
  check sawSupply

test "a rail stub juts away from the body, not back through it":
  # An op-amp box: V+ on top, V- (ptGround but on an ntPower net) on the
  # bottom. Both stub outward, so the bottom one goes down.
  let nl = newNetlist("negrail")
  let vp = addNet(nl, newNet("VP", ntPower))
  let vn = addNet(nl, newNet("VN", ntPower))
  let sig = addNet(nl, newNet("sig"))
  let u1 = addComponent(nl, newComponent("U1", kind = "opamp"))
  discard connect(u1, "OUT", sig, ptOutput)
  discard connect(u1, "V+", vp, ptPower)
  discard connect(u1, "V-", vn, ptGround)
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", sig, ptPassive)
  discard connect(r1, "2", addNet(nl, newNet("0", ntGround)), ptPassive)
  let s = layout(nl)
  let box = partOf(s, "U1")
  proc pin(n: string): SchematicPin =
    for p in box.pins:
      if p.name == n: return p
    doAssert false, "no pin " & n
  proc stub(net: string): SchematicWire =
    for w in s.wires:
      if w.net == net: return w
    doAssert false, "no wire " & net
  check pin("V+").y < box.y and pin("V-").y > box.y      # top / bottom edges
  let up = stub("VP")
  let dn = stub("VN")
  check up.kind == wkSupply and dn.kind == wkSupply
  # each stub starts at its pin and ends further from the body centre
  check up.points[0] == Point(x: pin("V+").x, y: pin("V+").y)
  check dn.points[0] == Point(x: pin("V-").x, y: pin("V-").y)
  check up.points[^1].y < up.points[0].y                 # V+ stub goes up
  check dn.points[^1].y > dn.points[0].y                 # V- stub goes down

test "routing connects every pin of a signal net":
  let s = layout(divider())
  let pts = wirePoints(s, "vout")
  for desig in ["R1", "R2", "C1", "U1"]:
    for p in pinPoints(s, desig, "vout"):
      check p in pts

test "a controlled source is a rectangular source4 with inputs left, outputs right":
  let nl = newNetlist("buf")
  let inp = addNet(nl, newNet("inp"))
  let inn = addNet(nl, newNet("inn"))
  let outp = addNet(nl, newNet("outp"))
  let outn = addNet(nl, newNet("outn"))
  let e1 = addComponent(nl, newComponent("E1", kind = "vcvs"))
  # Pins declared out of order: placement keys on pin name.
  discard connect(e1, "IN-", inn)
  discard connect(e1, "OUT+", outp)
  discard connect(e1, "IN+", inp)
  discard connect(e1, "OUT-", outn)
  let s = layout(nl)
  let p = partOf(s, "E1")
  check p.symbol == "source4"
  check not p.isBox
  check p.bodyW > p.bodyH
  var byName = initTable[string, Point]()
  for pin in p.pins: byName[pin.name] = Point(x: pin.x, y: pin.y)
  check byName["OUT+"].x > p.x
  check byName["OUT-"].x > p.x
  check byName["IN+"].x < p.x
  check byName["IN-"].x < p.x
  check byName["OUT+"].y < byName["OUT-"].y
  check byName["IN+"].y < byName["IN-"].y
  check p.rotation == 0.0
  # The public JSON identifier stays "source4".
  let node = parseJson(sceneToJsonString(s))
  check node["parts"][0]["symbol"].getStr == "source4"

test "the source4 symbol renders as a labelled rectangle, not a diamond":
  let nl = newNetlist("buf")
  let inp = addNet(nl, newNet("inp"))
  let inn = addNet(nl, newNet("inn"))
  let outp = addNet(nl, newNet("outp"))
  let outn = addNet(nl, newNet("outn"))
  let g1 = addComponent(nl, newComponent("G1", kind = "vccs"))
  discard connect(g1, "IN+", inp)
  discard connect(g1, "IN-", inn)
  discard connect(g1, "OUT+", outp)
  discard connect(g1, "OUT-", outn)
  let text = renderSvg(nl)
  check "<rect" in text
  check ">IN+</text>" in text
  check ">IN-</text>" in text
  check ">OUT+</text>" in text
  check ">OUT-</text>" in text
  check "<polygon" notin text

test "signal corners shared by independent wires are each chamfered":
  var s = Schematic(title: "shared corners")
  s.wires.add SchematicWire(net: "a", kind: wkSignal, points: @[
    Point(x: 0.0, y: 0.0), Point(x: 40.0, y: 0.0), Point(x: 40.0, y: 40.0)])
  s.wires.add SchematicWire(net: "b", kind: wkSignal, points: @[
    Point(x: 40.0, y: -4.0), Point(x: 40.0, y: 0.0), Point(x: 80.0, y: 0.0)])
  let text = renderSvg(s)
  check "points=\"0,0 36,0 40,4 40,40\"" in text
  # A shared coordinate is not a junction; each wire caps its own cut.
  check "points=\"40,-4 40,-2 42,0 80,0\"" in text

test "an isolated signal bend has a four-unit 45-degree chamfer":
  var s = Schematic(title: "isolated corner")
  s.wires.add SchematicWire(net: "sig", kind: wkSignal, points: @[
    Point(x: 0.0, y: 0.0), Point(x: 40.0, y: 0.0), Point(x: 40.0, y: 40.0)])
  let text = renderSvg(s)
  check "points=\"0,0 36,0 40,4 40,40\"" in text
  check "points=\"0,0 40,0 40,40\"" notin text

test "a same-net junction retains its square signal bend":
  var s = Schematic(title: "junction corner")
  s.wires.add SchematicWire(net: "sig", kind: wkSignal, points: @[
    Point(x: 0.0, y: 0.0), Point(x: 40.0, y: 0.0), Point(x: 40.0, y: 40.0)])
  s.junctions.add SchematicJunction(net: "sig", x: 40.0, y: 0.0)
  let text = renderSvg(s)
  check "points=\"0,0 40,0 40,40\"" in text
  check "points=\"0,0 36,0 40,4 40,40\"" notin text

test "straight and two-point wires remain unchanged":
  var s = Schematic(title: "unchanged wires")
  s.wires.add SchematicWire(net: "straight", kind: wkSignal, points: @[
    Point(x: 0.0, y: 0.0), Point(x: 20.0, y: 0.0), Point(x: 40.0, y: 0.0)])
  s.wires.add SchematicWire(net: "two", kind: wkSupply, points: @[
    Point(x: 0.0, y: 10.0), Point(x: 40.0, y: 10.0)])
  let text = renderSvg(s)
  check "points=\"0,0 20,0 40,0\"" in text
  check "points=\"0,10 40,10\"" in text

test "supply and ground bends are chamfered without changing glyph direction":
  var s = Schematic(title: "terminal corners")
  s.wires.add SchematicWire(net: "VCC", kind: wkSupply, points: @[
    Point(x: 0.0, y: 0.0), Point(x: 40.0, y: 0.0), Point(x: 40.0, y: 40.0)])
  s.wires.add SchematicWire(net: "0", kind: wkGround, points: @[
    Point(x: 0.0, y: 80.0), Point(x: 40.0, y: 80.0), Point(x: 40.0, y: 120.0)])
  let text = renderSvg(s)
  check "points=\"0,0 36,0 40,4 40,40\"" in text
  check "points=\"0,80 36,80 40,84 40,120\"" in text
  # Glyphs orient from the original stubs, not the chamfered polylines.
  check "<line x1=\"50\" y1=\"40\" x2=\"30\" y2=\"40\"" in text
  check "<line x1=\"50\" y1=\"120\" x2=\"30\" y2=\"120\"" in text
  check "<line x1=\"46\" y1=\"124\" x2=\"34\" y2=\"124\"" in text
  check "<line x1=\"42\" y1=\"128\" x2=\"38\" y2=\"128\"" in text

test "same-net junctions retain square supply and ground bends":
  var s = Schematic(title: "terminal junction corners")
  s.wires.add SchematicWire(net: "VCC", kind: wkSupply, points: @[
    Point(x: 0.0, y: 0.0), Point(x: 40.0, y: 0.0), Point(x: 40.0, y: 40.0)])
  s.wires.add SchematicWire(net: "0", kind: wkGround, points: @[
    Point(x: 0.0, y: 80.0), Point(x: 40.0, y: 80.0), Point(x: 40.0, y: 120.0)])
  s.junctions.add SchematicJunction(net: "VCC", x: 40.0, y: 0.0)
  s.junctions.add SchematicJunction(net: "0", x: 40.0, y: 80.0)
  let text = renderSvg(s)
  check "points=\"0,0 40,0 40,40\"" in text
  check "points=\"0,80 40,80 40,120\"" in text
  check "points=\"0,0 36,0 40,4 40,40\"" notin text
  check "points=\"0,80 36,80 40,84 40,120\"" notin text

test "short signal segments cap the corner cut at half their length":
  var s = Schematic(title: "short corner")
  s.wires.add SchematicWire(net: "sig", kind: wkSignal, points: @[
    Point(x: 0.0, y: 0.0), Point(x: 2.0, y: 0.0), Point(x: 2.0, y: 2.0)])
  let text = renderSvg(s)
  check "points=\"0,0 1,0 2,1 2,2\"" in text

test "wire corner rendering does not mutate the scene or JSON":
  var s = Schematic(title: "pure renderer")
  for (net, kind, y) in [("sig", wkSignal, 0.0), ("VCC", wkSupply, 80.0),
                         ("0", wkGround, 160.0)]:
    s.wires.add SchematicWire(net: net, kind: kind, points: @[
      Point(x: 0.0, y: y), Point(x: 40.0, y: y), Point(x: 40.0, y: y + 40.0)])
  let before = sceneToJsonString(s)
  discard renderSvg(s)
  check sceneToJsonString(s) == before
  for i, y in [0.0, 80.0, 160.0]:
    check s.wires[i].points == @[
      Point(x: 0.0, y: y), Point(x: 40.0, y: y), Point(x: 40.0, y: y + 40.0)]

test "junction dots are painted under part symbols":
  # Painter order: junction dots over wires, under symbol fills.
  var s = Schematic(title: "ord")
  s.parts.add SchematicPart(designator: "U1", kind: "mcu", name: "", value: "",
                            symbol: "box", isBox: true,
                            bodyW: 120.0, bodyH: 80.0, inkW: 80.0, inkH: 40.0,
                            x: 0.0, y: 0.0, rotation: 0.0)
  s.junctions.add SchematicJunction(net: "a", x: -60.0, y: 0.0)
  let text = renderSvg(s)
  let dot = text.find("r=\"3\"")
  let body = text.find("fill=\"#fdfdfd\"")
  check dot >= 0
  check body >= 0
  check dot < body

proc blockBBox(s: Schematic, desigs: openArray[string]):
    tuple[x1, y1, x2, y2: float] =
  result = (x1: Inf, y1: Inf, x2: -Inf, y2: -Inf)
  for d in desigs:
    let p = partOf(s, d)
    result.x1 = min(result.x1, p.x - p.bodyW / 2.0)
    result.y1 = min(result.y1, p.y - p.bodyH / 2.0)
    result.x2 = max(result.x2, p.x + p.bodyW / 2.0)
    result.y2 = max(result.y2, p.y + p.bodyH / 2.0)

test "every part centre stays on the 40-unit grid":
  for s in [layout(divider()), layout(resistorChain(16)), layout(starNet()),
            layout(twoBlocks()), layout(decoupledMcu())]:
    for p in s.parts:
      check abs(p.x / 40.0 - round(p.x / 40.0)) < 1e-9
      check abs(p.y / 40.0 - round(p.y / 40.0)) < 1e-9

test "blocks sharing no net are packed close, not flung apart":
  let s = layout(twoBlocks())
  let g1 = blockBBox(s, ["R1", "C1"])
  let g2 = blockBBox(s, ["R2", "C2"])
  # the blocks clear each other on one axis by a few grid cells
  let gapX = max(g2.x1 - g1.x2, g1.x1 - g2.x2)
  let gapY = max(g2.y1 - g1.y2, g1.y1 - g2.y2)
  check max(gapX, gapY) <= 5.0 * 40.0

test "a decoupling cap is packed with the part it decouples":
  # C1 shares only VDD/GND with U1 but joins U1's block: one separation from
  # U1, a full block gutter from the divider.
  let s = layout(decoupledMcu())
  let c1 = partOf(s, "C1")
  proc clearance(a, b: SchematicPart): float =
    max(abs(a.x - b.x) - (a.bodyW + b.bodyW) / 2.0,
        abs(a.y - b.y) - (a.bodyH + b.bodyH) / 2.0)
  let toU1 = clearance(c1, partOf(s, "U1"))
  check toU1 < clearance(c1, partOf(s, "R1"))
  check toU1 < clearance(c1, partOf(s, "R2"))

test "placement never overlaps inflated component bodies":
  for s in [layout(divider()), layout(resistorChain(16)), layout(twoBlocks()),
            layout(decoupledMcu())]:
    for i in 0 ..< s.parts.len:
      for j in i + 1 ..< s.parts.len:
        let a = s.parts[i]
        let b = s.parts[j]
        let dx = abs(a.x - b.x)
        let dy = abs(a.y - b.y)
        const clear = 12.0
        # Margin past raw-body touching on the binding axis: 0 for composite
        # members at their canonical offset, >= 2*placementPad for
        # independently separated parts, never between.
        let marginX = dx - (a.bodyW + b.bodyW) / 2.0
        let marginY = dy - (a.bodyH + b.bodyH) / 2.0
        let margin = max(marginX, marginY)
        let touching = margin < 1.0
        # raw bodies never overlap
        check margin >= -1e-6
        # inflated bodies never overlap, except a composite's touching
        # members (wired directly, not through the router)
        check touching or margin >= 2.0 * clear - 1e-6
        # and independent parts leave room for a route between them
        check touching or margin >= 3.0 * clear - 1e-6

test "signal wires keep the routing clearance except at their own pins":
  let s = layout(divider())
  let pinPart = pinPartIndex(s)
  for w in s.wires:
    if w.kind != wkSignal: continue
    check w.points.len >= 2
    # every signal wire ends at a pin (the first also starts at one; later
    # wires start at a tree vertex)
    check w.points[^1] in pinPart
    for k in 0 ..< w.points.high:
      let a = w.points[k]
      let b = w.points[k + 1]
      for pi, p in s.parts:
        let r = inflatedRect(p)
        # a pin's outward stub is the only wire allowed inside its body
        if pinPart.getOrDefault(a, -1) == pi or pinPart.getOrDefault(b, -1) == pi:
          continue
        check not segCrossesRect(a, b, r)

test "a tall box pin escapes through its own edge, not the dominant axis":
  let nl = newNetlist("tall")
  let a = addNet(nl, newNet("a"))
  let u1 = addComponent(nl, newComponent("U1", kind = "mcu"))
  # 12 pins -> a 6-row box; the top-left pin (y = -85, x = -70) would be
  # misread as vertical by a dominant-axis rule.
  discard connect(u1, "P0", a, ptPassive)
  for i in 1 ..< 12:
    discard connect(u1, "P" & $i, addNet(nl, newNet("d" & $i)), ptPassive)
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", a, ptPassive)
  discard connect(r1, "2", addNet(nl, newNet("b")), ptPassive)
  let s = layout(nl)
  let p0 = partOf(s, "U1").pins[0]
  var wire: seq[Point]
  for w in s.wires:
    if w.net == "a" and w.kind == wkSignal:
      wire = w.points
  check wire.len >= 2
  check abs(wire[0].x - p0.x) < 1e-6 and abs(wire[0].y - p0.y) < 1e-6
  # the first hop leaves horizontally to the terminal escape coordinate
  check wire[1] == Point(x: p0.x - 12.0, y: p0.y)

test "layout rotates an eligible two-terminal part and rotates its pin slots":
  # A T-junction: whichever resistors placement turns 90/270 must turn their
  # pin slots too. The three can't all take the same axis.
  var nl = newNetlist("tee")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("b"))
  let c = addNet(nl, newNet("c"))
  let d = addNet(nl, newNet("d"))
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", a, ptPassive); discard connect(r1, "2", b, ptPassive)
  let r2 = addComponent(nl, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", b, ptPassive); discard connect(r2, "2", c, ptPassive)
  let r3 = addComponent(nl, newComponent("R3", kind = "resistor"))
  discard connect(r3, "1", b, ptPassive); discard connect(r3, "2", d, ptPassive)
  let s = layout(nl)
  var sawVertical = false
  var sawHorizontal = false
  for desig in ["R1", "R2", "R3"]:
    let p = partOf(s, desig)
    check p.pins.len == 2
    if p.rotation == 90.0 or p.rotation == 270.0:
      sawVertical = true
      # Pins on a vertical line through the centre, 80 units apart.
      check abs(p.pins[0].x - p.pins[1].x) < 1e-6
      check abs(p.pins[0].x - p.x) < 1e-6
      check abs(abs(p.pins[0].y - p.pins[1].y) - 80.0) < 1e-6
      check (p.pins[0].y - p.y) * (p.pins[1].y - p.y) < 0.0
    else:
      check p.rotation == 0.0 or p.rotation == 180.0
      sawHorizontal = true
      check abs(p.pins[0].y - p.pins[1].y) < 1e-6
      check abs(abs(p.pins[0].x - p.pins[1].x) - 80.0) < 1e-6
  check sawVertical and sawHorizontal

test "a vertical-default source and a fallback box are not turned":
  let s = layout(divider())
  # A vertical-default source is already vertical, so it is not turned.
  let v1 = partOf(s, "V1")
  check v1.rotation == 0.0
  check abs(v1.pins[0].x - v1.pins[1].x) < 1e-6
  # A fallback box never rotates.
  check partOf(s, "U1").rotation == 0.0

test "rotation assigns each pin to the end facing its neighbour, flipping 180 if need be":
  # R2 is declared with its pins swapped; its n1 pin must still face R1 and
  # n2 face R3 -- a 180 turn chosen purely by shorter wire.
  var nl = newNetlist("chain")
  var ns: seq[Net]
  for i in 0 .. 4: ns.add addNet(nl, newNet("n" & $i))
  for i in 0 ..< 4:
    let r = addComponent(nl, newComponent("R" & $(i + 1), kind = "resistor"))
    if i == 1:
      discard connect(r, "1", ns[i + 1], ptPassive)
      discard connect(r, "2", ns[i], ptPassive)
    else:
      discard connect(r, "1", ns[i], ptPassive)
      discard connect(r, "2", ns[i + 1], ptPassive)
    r.attrs["value"] = "1k"
  let s = layout(nl)
  let r2 = partOf(s, "R2")
  check r2.rotation == 180.0
  let toR1 = pinPoints(s, "R2", "n1")[0]
  let toR3 = pinPoints(s, "R2", "n2")[0]
  check toR1.x < r2.x          # n1 pin faces R1, to R2's left
  check toR3.x > r2.x          # n2 pin faces R3, to R2's right
  check partOf(s, "R1").x < r2.x and partOf(s, "R3").x > r2.x

test "a parallel pair ends up adjacent and co-oriented, not scattered":
  # RP and CP both bridge nets a and b, so pin-to-pin attraction settles them
  # side by side in one orientation.
  var nl = newNetlist("par")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("b"))
  let g = addNet(nl, newNet("0", ntGround))
  let v1 = addComponent(nl, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", a); discard connect(v1, "-", g)
  v1.attrs["value"] = "DC 5"
  let rin = addComponent(nl, newComponent("RIN", kind = "resistor"))
  discard connect(rin, "1", a, ptPassive); discard connect(rin, "2", b, ptPassive)
  rin.attrs["value"] = "1k"
  let rl = addComponent(nl, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", b, ptPassive); discard connect(rl, "2", g, ptPassive)
  rl.attrs["value"] = "1k"
  let rp = addComponent(nl, newComponent("RP", kind = "resistor"))
  discard connect(rp, "1", a, ptPassive); discard connect(rp, "2", b, ptPassive)
  rp.attrs["value"] = "10k"
  let cp = addComponent(nl, newComponent("CP", kind = "capacitor"))
  discard connect(cp, "1", a, ptPassive); discard connect(cp, "2", b, ptPassive)
  cp.attrs["value"] = "1n"
  let s = layout(nl)
  let p = partOf(s, "RP")
  let q = partOf(s, "CP")
  check p.rotation == q.rotation
  check abs(p.x - q.x) + abs(p.y - q.y) <= 160.0
  for net in ["a", "b"]:
    let dp = pinPoints(s, "RP", net)[0]
    let dq = pinPoints(s, "CP", net)[0]
    check abs(dp.x - dq.x) + abs(dp.y - dq.y) <= 160.0

proc groundedLegsPlusBridge(reverseBridge = false): Netlist =
  ## Two grounded legs joined by a parallel bridge, whose declarations may be
  ## independently reversed.
  result = newNetlist("grounded_legs_bridge")
  let left = addNet(result, newNet("left"))
  let right = addNet(result, newNet("right"))
  let gnd = addNet(result, newNet("0", ntGround))
  let rl = addComponent(result, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", left, ptPassive)
  discard connect(rl, "2", gnd, ptGround)
  let rr = addComponent(result, newComponent("RR", kind = "resistor"))
  discard connect(rr, "1", right, ptPassive)
  discard connect(rr, "2", gnd, ptGround)
  let rb = addComponent(result, newComponent("RB", kind = "resistor"))
  let cb = addComponent(result, newComponent("CB", kind = "capacitor"))
  if reverseBridge:
    discard connect(rb, "1", right, ptPassive); discard connect(rb, "2", left, ptPassive)
    discard connect(cb, "1", left, ptPassive); discard connect(cb, "2", right, ptPassive)
  else:
    discard connect(rb, "1", left, ptPassive); discard connect(rb, "2", right, ptPassive)
    discard connect(cb, "1", left, ptPassive); discard connect(cb, "2", right, ptPassive)
  addPort(result, "IN", left)
  addPort(result, "OUT", right)

test "constrained parallel bridge keeps same-net pins adjacent despite reversed declarations":
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let a = layout(groundedLegsPlusBridge(), options)
  let b = layout(groundedLegsPlusBridge(true), options)
  for s in [a, b]:
    let rb = partOf(s, "RB")
    let cb = partOf(s, "CB")
    # Parallel 80 x 80 passives are a raw-body-touching composite, co-stacked.
    check coStacked(rb, cb)
    for net in ["left", "right"]:
      let p = pinPoints(s, "RB", net)[0]
      let q = pinPoints(s, "CB", net)[0]
      check abs(p.x - q.x) + abs(p.y - q.y) <= 160.0
    # A crowded candidate may need a marker, but routing stays valid.
    check distinctWiresNeverShareCollinearRuns(s)
  # Reversed declaration changes only the member's flip, deterministically.
  check layout(groundedLegsPlusBridge(true), options) == b

proc mixedNativeBridge(): Netlist =
  ## Three parallel members mixing horizontal passives with a vertical
  ## source: the composite maps terminal slots, not one member's rotation.
  result = newNetlist("mixed_native_bridge")
  let left = addNet(result, newNet("left"))
  let right = addNet(result, newNet("right"))
  let gnd = addNet(result, newNet("0", ntGround))
  for (designator, compKind) in [("RB", "resistor"), ("VB", "voltage_source"),
                                  ("CB", "capacitor")]:
    let c = addComponent(result, newComponent(designator, kind = compKind))
    let first = if compKind == "voltage_source": "+" else: "1"
    let second = if compKind == "voltage_source": "-" else: "2"
    discard connect(c, first, left, ptPassive)
    discard connect(c, second, right, ptPassive)
  let rl = addComponent(result, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", left, ptPassive); discard connect(rl, "2", gnd, ptGround)
  let rr = addComponent(result, newComponent("RR", kind = "resistor"))
  discard connect(rr, "1", right, ptPassive); discard connect(rr, "2", gnd, ptGround)
  addPort(result, "IN", left)
  addPort(result, "OUT", right)

test "constrained composite maps mixed native terminal axes and normalizes fanout":
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(mixedNativeBridge(), options)
  let rb = partOf(s, "RB")
  let vb = partOf(s, "VB")
  let cb = partOf(s, "CB")
  # One locked, raw-body-touching unit, stacked 80 apart.
  let vert = unitVertical([rb, vb, cb])
  if vert:
    check rb.x == vb.x and vb.x == cb.x
    check abs(rb.y - vb.y) == 80.0 and abs(vb.y - cb.y) == 80.0
  else:
    check rb.y == vb.y and vb.y == cb.y
    check abs(rb.x - vb.x) == 80.0 and abs(vb.x - cb.x) == 80.0
  for part in [rb, vb, cb]:
    # Every member, the vertical source included, has its pins on the unit's
    # cross-axis, 80 apart.
    if vert:
      check abs(part.pins[0].y - part.pins[1].y) < 1e-6
      check abs(abs(part.pins[0].x - part.pins[1].x) - 80.0) < 1e-6
    else:
      check abs(part.pins[0].x - part.pins[1].x) < 1e-6
      check abs(abs(part.pins[0].y - part.pins[1].y) - 80.0) < 1e-6
  for net in ["left", "right"]:
    let points = @[pinPoints(s, "RB", net)[0], pinPoints(s, "VB", net)[0],
                   pinPoints(s, "CB", net)[0]]
    if vert: check points[0].x == points[1].x and points[1].x == points[2].x
    else: check points[0].y == points[1].y and points[1].y == points[2].y
  # Three members exercise the one-trunk fanout; no collinear root runs.
  check distinctWiresNeverShareCollinearRuns(s)
  check layout(mixedNativeBridge(), options) == s

test "constrained parallel rail group emits one glyph per shared terminal":
  let nl = newNetlist("parallel_rail")
  let vdd = addNet(nl, newNet("VDD", ntPower))
  let gnd = addNet(nl, newNet("0", ntGround))
  for d in ["C1", "C2"]:
    let c = addComponent(nl, newComponent(d, kind = "capacitor"))
    discard connect(c, "1", vdd, ptPassive)
    discard connect(c, "2", gnd, ptPassive)
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(nl, options)
  var supply = 0
  var ground = 0
  for w in s.wires:
    if w.net == "VDD" and w.kind == wkSupply: inc supply
    if w.net == "0" and w.kind == wkGround: inc ground
  check supply == 1
  check ground == 1
  check s.parts.len == 2                 # no public composite schema
  check layout(nl, options) == s

proc piFilter(): Netlist =
  ## A pi section (L1 series, a grounded shunt cap at each end), driven and
  ## loaded so both external nets reach beyond the composite.
  result = newNetlist("pi_filter")
  let src = addNet(result, newNet("src"))
  let fin = addNet(result, newNet("fin"))
  let mid = addNet(result, newNet("mid"))
  let fout = addNet(result, newNet("fout"))
  let gnd = addNet(result, newNet("0", ntGround))
  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", src); discard connect(v1, "-", gnd)
  let rs = addComponent(result, newComponent("RS", kind = "resistor"))
  discard connect(rs, "1", src, ptPassive); discard connect(rs, "2", fin, ptPassive)
  let l1 = addComponent(result, newComponent("L1", kind = "inductor"))
  discard connect(l1, "1", fin, ptPassive); discard connect(l1, "2", mid, ptPassive)
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", fin, ptPassive); discard connect(c1, "2", gnd, ptPassive)
  let c2 = addComponent(result, newComponent("C2", kind = "capacitor"))
  discard connect(c2, "1", mid, ptPassive); discard connect(c2, "2", gnd, ptPassive)
  let rl = addComponent(result, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", mid, ptPassive); discard connect(rl, "2", fout, ptPassive)
  let rt = addComponent(result, newComponent("RT", kind = "resistor"))
  discard connect(rt, "1", fout, ptPassive); discard connect(rt, "2", gnd, ptPassive)

test "constrained pi composite: series flat, shunts flank it to ground, routed":
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(piFilter(), options)
  let l1 = partOf(s, "L1")
  let c1 = partOf(s, "C1")
  let c2 = partOf(s, "C2")
  # One locked unit: series horizontal, a shunt one pitch below each pin.
  check abs(l1.pins[0].y - l1.pins[1].y) < 1e-6         # series horizontal
  check c1.rotation in [90.0, 270.0]                     # shunts vertical
  check c2.rotation in [90.0, 270.0]
  check c1.y == c2.y and c1.y > l1.y                     # both shunts below
  check abs((c1.x - l1.x) + (c2.x - l1.x)) < 1e-6        # symmetric about series
  # ground pin of each shunt points down (larger y)
  for sh in [c1, c2]:
    check sh.pins[1].net == "0"
    check sh.pins[1].y > sh.pins[0].y
  check s.fallbacks.len == 0
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(piFilter(), options) == s

proc teeFilter(): Netlist =
  ## A tee section: L1 and L2 in series through a private `mid` with a shunt
  ## cap to ground.
  result = newNetlist("tee_filter")
  let src = addNet(result, newNet("src"))
  let fin = addNet(result, newNet("fin"))
  let mid = addNet(result, newNet("mid"))
  let fout = addNet(result, newNet("fout"))
  let gnd = addNet(result, newNet("0", ntGround))
  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", src); discard connect(v1, "-", gnd)
  let rs = addComponent(result, newComponent("RS", kind = "resistor"))
  discard connect(rs, "1", src, ptPassive); discard connect(rs, "2", fin, ptPassive)
  let l1 = addComponent(result, newComponent("L1", kind = "inductor"))
  discard connect(l1, "1", fin, ptPassive); discard connect(l1, "2", mid, ptPassive)
  let l2 = addComponent(result, newComponent("L2", kind = "inductor"))
  discard connect(l2, "1", mid, ptPassive); discard connect(l2, "2", fout, ptPassive)
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", mid, ptPassive); discard connect(c1, "2", gnd, ptPassive)
  let rl = addComponent(result, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", fout, ptPassive); discard connect(rl, "2", gnd, ptPassive)

test "constrained tee composite: two series parts, a grounded shunt at the private mid":
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(teeFilter(), options)
  let l1 = partOf(s, "L1")
  let l2 = partOf(s, "L2")
  let c1 = partOf(s, "C1")
  # Series parts in one row, the shunt one pitch below their midline.
  check l1.y == l2.y
  check abs(l1.pins[0].y - l1.pins[1].y) < 1e-6
  check abs(l2.pins[0].y - l2.pins[1].y) < 1e-6
  check c1.rotation in [90.0, 270.0]
  check abs(c1.x - (l1.x + l2.x) / 2.0) < 1e-6
  check c1.y > l1.y
  check c1.pins[1].net == "0" and c1.pins[1].y > c1.pins[0].y
  # The internal mid net is real wires, not a fallback.
  check s.fallbacks.len == 0
  check wirePoints(s, "mid").len > 0
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(teeFilter(), options) == s

proc seriesChainFilter(portOnLink = false): Netlist =
  ## A series chain RS-a-R1-m1-C1-m2-L1 ending at port `b`, with no grounded
  ## shunt (so no pi/tee). `a`, `m1`, `m2` are private links. With
  ## `portOnLink`, `m1` is also a port, splitting the chain into RS-R1 and
  ## C1-L1.
  result = newNetlist("series_chain_filter")
  let src = addNet(result, newNet("src"))
  let a = addNet(result, newNet("a"))
  let m1 = addNet(result, newNet("m1"))
  let m2 = addNet(result, newNet("m2"))
  let b = addNet(result, newNet("b"))
  let gnd = addNet(result, newNet("0", ntGround))
  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", src); discard connect(v1, "-", gnd)
  let rs = addComponent(result, newComponent("RS", kind = "resistor"))
  discard connect(rs, "1", src, ptPassive); discard connect(rs, "2", a, ptPassive)
  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", a, ptPassive); discard connect(r1, "2", m1, ptPassive)
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", m1, ptPassive); discard connect(c1, "2", m2, ptPassive)
  let l1 = addComponent(result, newComponent("L1", kind = "inductor"))
  discard connect(l1, "1", m2, ptPassive); discard connect(l1, "2", b, ptPassive)
  addPort(result, "B", b)
  if portOnLink: addPort(result, "M1", m1)

test "constrained series chain: passives in one row, links routed":
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(seriesChainFilter(), options)
  var members: seq[SchematicPart]
  for d in ["RS", "R1", "C1", "L1"]: members.add partOf(s, d)
  # One rigid unit: every member and pin on the unit's cross-axis.
  let vert = unitVertical(members)
  let along = proc(m: SchematicPart): float = (if vert: m.y else: m.x)
  let across = proc(m: SchematicPart): float = (if vert: m.x else: m.y)
  let base = across(members[0])
  for m in members:
    check across(m) == base
    if vert: check abs(m.pins[0].x - m.pins[1].x) < 1e-6
    else: check abs(m.pins[0].y - m.pins[1].y) < 1e-6
  # Evenly spaced on a 160 pitch, grid-aligned.
  var minD = along(members[0])
  for m in members: minD = min(minD, along(m))
  var slots: array[4, bool]
  for m in members:
    let k = int(round((along(m) - minD) / 160.0))
    check k in 0 .. 3
    check abs((along(m) - minD) - float(k) * 160.0) < 1e-6
    check not slots[k]
    slots[k] = true
  # The internal link nets are real wires, not fallbacks.
  for net in ["a", "m1", "m2"]:
    check wirePoints(s, net).len > 0
  check s.fallbacks.len == 0
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(seriesChainFilter(), options) == s

test "a declared port on a link net is not absorbed into the chain":
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(seriesChainFilter(portOnLink = true), options)
  # `m1` is a routed external net, so R1 and C1 are not one chain unit.
  let r1 = partOf(s, "R1")
  let c1 = partOf(s, "C1")
  check not coStacked(r1, c1, 160.0)
  check "M1" in (block:
    var names: seq[string]
    for p in s.ports: names.add p.name
    names)
  check s.fallbacks.len == 0
  check layout(seriesChainFilter(portOnLink = true), options) == s

proc railToGroundChain(): Netlist =
  ## R1-R2-R3 in series from VCC to ground: `powerRank` alone stands it into
  ## a vertical column.
  result = newNetlist("rail_chain")
  let vcc = addNet(result, newNet("VCC", ntPower))
  let m1 = addNet(result, newNet("m1"))
  let m2 = addNet(result, newNet("m2"))
  let gnd = addNet(result, newNet("0", ntGround))
  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vcc, ptPower); discard connect(v1, "-", gnd, ptGround)
  v1.attrs["value"] = "DC 5"
  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vcc, ptPassive); discard connect(r1, "2", m1, ptPassive)
  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", m1, ptPassive); discard connect(r2, "2", m2, ptPassive)
  let r3 = addComponent(result, newComponent("R3", kind = "resistor"))
  discard connect(r3, "1", m2, ptPassive); discard connect(r3, "2", gnd, ptPassive)

test "lsCompositeOrient stands a rail-to-ground series chain into a vertical column":
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(railToGroundChain(), options)
  var members: seq[SchematicPart]
  for d in ["R1", "R2", "R3"]: members.add partOf(s, d)
  check unitVertical(members)                       # turned out of the row
  check members[0].x == members[1].x and members[1].x == members[2].x
  for m in members:                                 # each body vertical too
    check abs(m.pins[0].x - m.pins[1].x) < 1e-6
  # VCC end up, ground end down.
  check pinPoints(s, "R1", "VCC")[0].y < pinPoints(s, "R3", "0")[0].y
  check s.fallbacks.len == 0
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(railToGroundChain(), options) == s

test "a rail decoupling bank turns its caps upright, side by side":
  # C1||C2 across VDD/0: each cap vertical, so the stack runs horizontal.
  let nl = newNetlist("decouple_bank")
  let vdd = addNet(nl, newNet("VDD", ntPower))
  let gnd = addNet(nl, newNet("0", ntGround))
  let v1 = addComponent(nl, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vdd, ptPower); discard connect(v1, "-", gnd, ptGround)
  for d in ["C1", "C2"]:
    let c = addComponent(nl, newComponent(d, kind = "capacitor"))
    discard connect(c, "1", vdd, ptPassive)
    discard connect(c, "2", gnd, ptPassive)
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let s = layout(nl, options)
  let c1 = partOf(s, "C1")
  let c2 = partOf(s, "C2")
  check c1.y == c2.y and abs(c1.x - c2.x) == 80.0    # side by side
  for c in [c1, c2]:
    check c.rotation in [90.0, 270.0]                 # upright
    check pinPoints(s, c.designator, "0")[0].y > pinPoints(s, c.designator, "VDD")[0].y
  check layout(nl, options) == s

test "lsCompositeOrient leaves pi and tee pinned":
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  # pi/tee are not orientable: their scenes are identical with
  # lsCompositeOrient dropped.
  for mk in [piFilter, teeFilter]:
    let withStage = layout(mk(), options)
    var without = options
    without.stages.excl lsCompositeOrient
    check layout(mk(), without) == withStage

test "a parallel pair is still a parallel stack, not a series chain":
  # RP||CP share nets that carry four pins, so neither is a chain link.
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  var nl = newNetlist("par_not_chain")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("b"))
  let g = addNet(nl, newNet("0", ntGround))
  let v1 = addComponent(nl, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", a); discard connect(v1, "-", g)
  let rp = addComponent(nl, newComponent("RP", kind = "resistor"))
  discard connect(rp, "1", a, ptPassive); discard connect(rp, "2", b, ptPassive)
  let cp = addComponent(nl, newComponent("CP", kind = "capacitor"))
  discard connect(cp, "1", a, ptPassive); discard connect(cp, "2", b, ptPassive)
  let rl = addComponent(nl, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", b, ptPassive); discard connect(rl, "2", g, ptPassive)
  let s = layout(nl, options)
  let p = partOf(s, "RP")
  let q = partOf(s, "CP")
  check p.rotation == q.rotation            # co-oriented parallel stack
  for net in ["a", "b"]:
    let dp = pinPoints(s, "RP", net)[0]
    let dq = pinPoints(s, "CP", net)[0]
    check abs(dp.x - dq.x) + abs(dp.y - dq.y) <= 160.0
  check s.fallbacks.len == 0
  check layout(nl, options) == s

test "a powered one-net leaf keeps its ground pin down":
  # CSH hangs off the mid node to ground; power direction outranks
  # wirelength, so its ground pin stays down.
  var nl = newNetlist("leaf")
  let inn = addNet(nl, newNet("in"))
  let mid = addNet(nl, newNet("mid"))
  let outn = addNet(nl, newNet("out"))
  let g = addNet(nl, newNet("0", ntGround))
  let vs = addComponent(nl, newComponent("VS", kind = "voltage_source"))
  discard connect(vs, "+", inn); discard connect(vs, "-", g)
  vs.attrs["value"] = "DC 5"
  let rs = addComponent(nl, newComponent("RS", kind = "resistor"))
  discard connect(rs, "1", inn, ptPassive); discard connect(rs, "2", mid, ptPassive)
  rs.attrs["value"] = "1k"
  let ro = addComponent(nl, newComponent("RO", kind = "resistor"))
  discard connect(ro, "1", mid, ptPassive); discard connect(ro, "2", outn, ptPassive)
  ro.attrs["value"] = "1k"
  let rl = addComponent(nl, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", outn, ptPassive); discard connect(rl, "2", g, ptPassive)
  rl.attrs["value"] = "1k"
  let csh = addComponent(nl, newComponent("CSH", kind = "capacitor"))
  discard connect(csh, "1", mid, ptPassive); discard connect(csh, "2", g, ptPassive)
  csh.attrs["value"] = "1n"
  let s = layout(nl)
  let cshPart = partOf(s, "CSH")
  let groundPin = pinPoints(s, "CSH", "0")[0]
  check groundPin.y > cshPart.y

test "a powered one-net leaf snaps straight to its signal mate when clear":
  # The power-directed cap settles beside V1 and stays ground-down, near,
  # aligned, and repeatable.
  let nl = newNetlist("powered_leaf_snap")
  let mid = addNet(nl, newNet("mid"))
  let gnd = addNet(nl, newNet("0", ntGround))
  let csh = addComponent(nl, newComponent("CSH", kind = "capacitor"))
  discard connect(csh, "1", mid, ptPassive)
  discard connect(csh, "2", gnd, ptGround)
  let v1 = addComponent(nl, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", gnd, ptGround)
  discard connect(v1, "-", mid, ptPassive)

  let s = layout(nl)
  let cshPart = partOf(s, "CSH")
  let signalPin = pinPoints(s, "CSH", "mid")[0]
  let matePin = pinPoints(s, "V1", "mid")[0]
  check pinPoints(s, "CSH", "0")[0].y > cshPart.y
  check abs(signalPin.x - matePin.x) < 1e-6 or
        abs(signalPin.y - matePin.y) < 1e-6
  check abs(signalPin.x - matePin.x) + abs(signalPin.y - matePin.y) <= 3.0 * 40.0
  var midWire: SchematicWire
  for wire in s.wires:
    if wire.net == "mid": midWire = wire
  check signalPin in midWire.points and matePin in midWire.points
  let again = layout(nl)
  check partOf(again, "CSH").x == cshPart.x
  check partOf(again, "CSH").y == cshPart.y
  check pinPoints(again, "CSH", "mid")[0] == signalPin

test "power-aware rotation puts ground and rail pins in their semantic directions":
  # Direction outranks wire length: ground and non-positive rails point down,
  # positive and unannotated up. An explicit ntPower kind beats ptGround.
  let nl = newNetlist("power_rotation")
  let gnd = addNet(nl, newNet("0", ntGround))
  let vp = addNet(nl, newNet("VP", ntPower))
  vp.attrs["voltage"] = "5"
  let vn = addNet(nl, newNet("VN", ntPower))
  vn.attrs["voltage"] = "-5"
  let vu = addNet(nl, newNet("VU", ntPower))
  let sig = addNet(nl, newNet("sig"))

  let cpos = addComponent(nl, newComponent("CP", kind = "capacitor"))
  discard connect(cpos, "1", vp, ptPower)
  discard connect(cpos, "2", gnd, ptGround)
  let cneg = addComponent(nl, newComponent("CN", kind = "capacitor"))
  discard connect(cneg, "1", vn, ptGround) # V- convention, but ntPower wins
  discard connect(cneg, "2", vu, ptPower)
  let rleaf = addComponent(nl, newComponent("RL", kind = "resistor"))
  discard connect(rleaf, "1", sig, ptPassive)
  discard connect(rleaf, "2", gnd, ptGround)
  let mate = addComponent(nl, newComponent("RM", kind = "resistor"))
  discard connect(mate, "1", sig, ptPassive)
  discard connect(mate, "2", addNet(nl, newNet("other")), ptPassive)

  let s = layout(nl)
  proc pinY(desig, name: string): float =
    let p = partOf(s, desig)
    for pin in p.pins:
      if pin.name == name: return pin.y - p.y
    doAssert false, "no pin " & desig & "." & name
  check pinY("CP", "1") < 0.0       # +5 V up
  check pinY("CP", "2") > 0.0       # ground down
  check pinY("CN", "1") > 0.0       # annotated -5 V rail down despite ptGround
  check pinY("CN", "2") < 0.0       # unannotated rail up
  check pinY("RL", "2") > 0.0       # leafSnap preserves ground-down

test "a three-terminal transistor never rotates":
  let nl = newNetlist("elig")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("b"))
  let c = addNet(nl, newNet("c"))
  let q1 = addComponent(nl, newComponent("Q1", kind = "transistor"))
  discard connect(q1, "C", a)
  discard connect(q1, "B", b)
  discard connect(q1, "E", c)
  let s = layout(nl)
  check partOf(s, "Q1").rotation == 0.0

test "a rotated part draws its body in a rotate group, its labels kept outside it":
  var s = Schematic(title: "rot")
  var p = SchematicPart(designator: "R1", kind: "resistor", name: "",
                        value: "1k", symbol: "resistor", isBox: false,
                        bodyW: 80.0, bodyH: 80.0, inkW: 80.0, inkH: 20.0,
                        x: 100.0, y: 100.0, rotation: 90.0)
  p.pins.add SchematicPin(name: "1", x: 100.0, y: 60.0, net: "a")
  p.pins.add SchematicPin(name: "2", x: 100.0, y: 140.0, net: "b")
  s.parts.add p
  # A hand-built scene supplies its own labels.
  s.labels.add SchematicLabel(text: "R1", x: 120.0, y: 96.0, anchor: taStart,
                              size: 12.0, role: lrDesignator, owner: "R1")
  s.labels.add SchematicLabel(text: "1k", x: 120.0, y: 110.0, anchor: taStart,
                              size: 10.0, role: lrValue, owner: "R1")
  let text = renderSvg(s)
  let g = text.find("<g transform=\"rotate(90 100 100)\">")
  check g >= 0
  let gc = text.find("</g>", g)
  check gc > g
  check "<text" notin text[g ..< gc]        # no label inside the rotated group
  check text.find(">R1</text>") > gc        # both labels emitted after it closes
  check text.find(">1k</text>") > gc
  let node = sceneToJson(s)
  check node["parts"][0]["rotation"].getFloat == 90.0
  check node["parts"][0]["inkH"].getFloat == 20.0

test "the svg is self-contained and names its parts":
  let text = renderSvg(divider())
  check text.startsWith("<?xml")
  check "<svg xmlns=\"http://www.w3.org/2000/svg\"" in text
  check ">R1</text>" in text
  check ">V1</text>" in text
  check "#" in text
  check "class=" notin text
  check text.endsWith("</svg>\n")

test "the public json api round-trips the scene":
  let node = parseJson(sceneToJsonString(divider()))
  check node["title"].getStr == "rc_divider"
  check node["parts"].len == 5
  check node.hasKey("wires")
  check node.hasKey("junctions")
  check node.hasKey("labels")
  check node["parts"][0].hasKey("designator")
  check node["parts"][0].hasKey("pins")
  check node["parts"][0]["pins"][0].hasKey("net")

test "the public json writer emits schemaVersion 1 with complete scene fields":
  let node = parseJson(sceneToJsonString(divider()))
  check node["schemaVersion"].getInt == sceneSchemaVersion
  # Parts carry body and ink extents; fallbacks their escape direction.
  check node["parts"][0].hasKey("bodyW")
  check node["parts"][0].hasKey("bodyH")
  check node["parts"][0].hasKey("inkW")
  check node["parts"][0].hasKey("inkH")
  let withFb = parseJson(sceneToJsonString(riaaTopScene))
  check withFb["fallbacks"].len == 4
  check withFb["fallbacks"][0].hasKey("ex")
  check withFb["fallbacks"][0].hasKey("ey")

  # Rotation is one of {0,90,180,270}: divider R1/R2 turn 90, U1's box never
  # turns.
  var rotOf = initTable[string, float]()
  for part in node["parts"]:
    check part.hasKey("rotation")
    let rot = part["rotation"].getFloat
    check rot in [0.0, 90.0, 180.0, 270.0]
    rotOf[part["designator"].getStr] = rot
  check rotOf["R1"] == 90.0
  check rotOf["R2"] == 90.0
  check rotOf["U1"] == 0.0

test "the strict json reader is the exact inverse of the writer":
  for s in [layout(divider()), riaaChannelScene, riaaTopScene, chain37]:
    check jsonToScene(sceneToJsonString(s)) == s

test "the strict json reader rejects unknown versions and malformed fields":
  let good = parseJson(sceneToJsonString(divider()))
  var badVersion = good
  badVersion["schemaVersion"] = %2
  expect SceneJsonError:
    discard jsonToScene(badVersion)
  var fractionalVersion = good
  fractionalVersion["schemaVersion"] = %1.0
  expect SceneJsonError:
    discard jsonToScene(fractionalVersion)
  var missing = good
  missing.delete("parts")
  expect SceneJsonError:
    discard jsonToScene(missing)
  var wrongType = good
  wrongType["title"] = %42
  expect SceneJsonError:
    discard jsonToScene(wrongType)
  var badEnum = good
  badEnum["wires"][0]["kind"] = %"not-a-wire-kind"
  expect SceneJsonError:
    discard jsonToScene(badEnum)

test "the reader accepts legacy unversioned archives and rebuilds fallback escapes":
  # A pre-schemaVersion scene has no `schemaVersion` and no fallback
  # `ex`/`ey`; both are reconstructed from part/port geometry.
  let s = riaaTopScene
  var node = parseJson(sceneToJsonString(s))
  node.delete("schemaVersion")
  for f in node["fallbacks"]:
    f.delete("ex")
    f.delete("ey")
  let back = jsonToScene(node)
  check back.parts == s.parts
  check back.wires == s.wires
  check back.ports == s.ports
  check back.fallbacks.len == s.fallbacks.len
  for i in 0 ..< back.fallbacks.len:
    check back.fallbacks[i].ex == s.fallbacks[i].ex
    check back.fallbacks[i].ey == s.fallbacks[i].ey
  # An unowned fallback keeps its geometry with no invented escape direction.
  var unknown = node["fallbacks"][0]
  unknown["part"] = %"missing"
  unknown["pin"] = %"missing"
  node["fallbacks"].add unknown
  let withUnknown = jsonToScene(node)
  check withUnknown.fallbacks[^1].ex == 0.0
  check withUnknown.fallbacks[^1].ey == 0.0

test "fallbackEscapeDir rebuilds an escape from part or port geometry":
  var s = Schematic(title: "esc")
  var p = SchematicPart(designator: "R1", kind: "resistor", name: "",
                        value: "", symbol: "resistor", isBox: false,
                        bodyW: 80.0, bodyH: 80.0, inkW: 80.0, inkH: 20.0,
                        x: 0.0, y: 0.0, rotation: 0.0)
  p.pins.add SchematicPin(name: "1", x: -40.0, y: 0.0, net: "a")
  p.pins.add SchematicPin(name: "2", x: 40.0, y: 0.0, net: "b")
  s.parts.add p
  s.ports.add SchematicPort(name: "OUT", net: "b", dir: pdOutput,
                            x: 140.0, y: 40.0, bodyW: 60.0, bodyH: 24.0,
                            rotation: 0.0)
  s.ports.add SchematicPort(name: "IN", net: "a", dir: pdInput,
                            x: -140.0, y: 40.0, bodyW: 60.0, bodyH: 24.0,
                            rotation: 180.0)
  # A part pin leaves along its body-edge outward normal.
  check fallbackEscapeDir(s.parts, s.ports,
    SchematicFallback(net: "a", part: "R1", pin: "1", x: -40.0, y: 0.0)) ==
    Point(x: -1.0, y: 0.0)
  # A rotation-0 port sits right of its connection point -> inward -x.
  check fallbackEscapeDir(s.parts, s.ports,
    SchematicFallback(net: "b", part: "", pin: "", x: 110.0, y: 40.0)) ==
    Point(x: -1.0, y: 0.0)
  # A rotation-180 port sits to the left -> inward +x.
  check fallbackEscapeDir(s.parts, s.ports,
    SchematicFallback(net: "a", part: "", pin: "", x: -110.0, y: 40.0)) ==
    Point(x: 1.0, y: 0.0)
  # An owner the scene can't identify yields (0, 0).
  check fallbackEscapeDir(s.parts, s.ports,
    SchematicFallback(net: "b", part: "R9", pin: "9", x: 0.0, y: 0.0)) ==
    Point(x: 0.0, y: 0.0)

test "an empty netlist still renders a valid document":
  let text = renderSvg(newNetlist("empty"))
  check "<svg" in text
  check text.endsWith("</svg>\n")

test "distinct wires never share a positive-length collinear run":
  for nl in [divider(), resistorChain(16), starNet()]:
    let s = layout(nl)
    check distinctWiresNeverShareCollinearRuns(s)

test "different nets never touch collinearly nor crowd in parallel":
  # Different nets may cross perpendicularly but never touch collinearly and
  # keep 8 units of separation where parallel and overlapping.
  for nl in [divider(), resistorChain(16), starNet(), twoBlocks(),
             decoupledMcu()]:
    let s = layout(nl)
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)

test "signal wires clear complete ground and supply terminal glyphs":
  # A terminal's stem and bars are forbidden to signal routing.
  check signalWiresClearTerminalGlyphs(layout(divider()))
  check signalWiresClearTerminalGlyphs(layout(decoupledMcu()))

  # Dense rails, ground terminals, fallback markers and boxes.
  check signalWiresClearTerminalGlyphs(riaaChannelScene)
  check signalWiresClearTerminalGlyphs(riaaTopScene)

  # Ordinary signal crossings stay governed by the separation rule.
  for nl in [resistorChain(16), starNet(), twoBlocks()]:
    check differentNetsRespectSeparation(layout(nl))

test "placement reserves full terminal glyphs before routing":
  # The divider is the minimal mixed signal/terminal case.
  check fullTerminalGlyphsClearPlacementReservations(layout(divider()))
  # The RIAA channel is a known open exception: `RL`'s prospective ground
  # glyph crosses `CG`, since a composite member can't move alone. Routing's
  # stem-shortening resolves it; the test above checks the routed result.

test "a signal wire never threads a foreign-net escape seed":
  # A signal route may touch or cross a foreign-net escape stub but never run
  # along it. Covers both component-pin and interface-port stubs.
  for s in [layout(divider()), riaaChannelScene]:
    check signalWiresRespectForeignSeeds(s)
  let riaa = riaaChannelScene
  let seeds = escapeSeedsT(riaa)
  check riaa.ports.len == 2
  for port in riaa.ports:
    var seeded = false
    for sd in seeds:
      if sd.net == port.net: seeded = true
    check seeded

test "the real RIAA channel routes through the placement-routing feedback":
  # The RIAA channel's `fb` net is boxed in until a feedback move frees it.
  # The recovered scene must uphold the routing invariants with no raw
  # bodies overlapping.
  let s = riaaChannelScene
  check s.parts.len == 12
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  for i in 0 ..< s.parts.len:
    for j in i + 1 ..< s.parts.len:
      let a = s.parts[i]
      let b = s.parts[j]
      let dx = abs(a.x - b.x)
      let dy = abs(a.y - b.y)
      check dx >= (a.bodyW + b.bodyW) / 2.0 - 1e-6 or
            dy >= (a.bodyH + b.bodyH) / 2.0 - 1e-6

test "the placement-routing feedback is deterministic":
  let a = riaaChannelScene           # the shared scene must equal a fresh one
  let b = layout(riaaChannel())
  check a.parts.len == b.parts.len
  for i in 0 ..< a.parts.len:
    check a.parts[i].x == b.parts[i].x
    check a.parts[i].y == b.parts[i].y
    check a.parts[i].rotation == b.parts[i].rotation
  check a.wires.len == b.wires.len
  for i in 0 ..< a.wires.len:
    check a.wires[i].net == b.wires[i].net
    check a.wires[i].points.len == b.wires[i].points.len
    for k in 0 ..< a.wires[i].points.len:
      check a.wires[i].points[k] == b.wires[i].points[k]

test "the RIAA top sheet's dangling channel ports become fallback markers":
  # The four channel ports each have one pin on the top sheet, so each is a
  # fallback stub; the child channel sheet routes with none.
  let s = riaaTopScene
  check s.fallbacks.len == 4
  for f in s.fallbacks:
    check f.net in ["inL", "inR", "outL", "outR"]
    check f.part in ["XL", "XR"]
    check f.pin in ["IN", "OUT"]
    check f.points.len == 2
  check fallbacksClearOfWires(s)
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)

  let child = riaaChannelScene
  check child.fallbacks.len == 0

  # The top sheet's SVG has the amber markers; the child's doesn't.
  let topSvg = renderSvg(s)
  check "stroke-dasharray=\"6 4\"" in topSvg
  check "stroke=\"#e67e22\"" in topSvg
  let childSvg = renderSvg(child)
  check "stroke-dasharray=\"6 4\"" notin childSvg

  # The public JSON API exposes the same fallback records.
  let node = sceneToJson(s)
  check node["fallbacks"].len == 4
  check node["fallbacks"][0]["net"].getStr in ["inL", "inR", "outL", "outR"]

test "an impossible route falls back to dashed markers, never an assertion":
  # A long chain crowds the lanes until a net can't keep 8-unit separation.
  # `layout` degrades it to fallback markers instead of raising; remaining
  # wires uphold the invariants and markers never join them.
  let s = chain37
  check s.fallbacks.len > 0
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check fallbacksClearOfWires(s)
  for f in s.fallbacks:
    check f.net.len > 0
    check f.part.len > 0
    check f.pin.len > 0
    check f.points.len == 2
    check f.points[0] == Point(x: f.x, y: f.y)

test "constrained trunk-and-tap fallback is atomic":
  # A failed tree leaves no partial branches, only per-pin markers.
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  let nl = resistorChain(37)
  let s = layout(nl, options)
  var fallbackNets = initHashSet[string]()
  for f in s.fallbacks: fallbackNets.incl f.net
  check fallbackNets.len > 0
  for netName in fallbackNets:
    var expected = 0
    for _, net in nl.nets:
      if net.name == netName: expected = net.pins.len
    var actual = 0
    for f in s.fallbacks:
      if f.net == netName: inc actual
    # The external endpoint represents every covered physical pin.
    check actual == expected
  for w in s.wires:
    if w.kind == wkSignal:
      check w.net notin fallbackNets
  check fallbacksClearOfWires(s)

test "fallback diagnostics route through exact terminal Hanan axes":
  # Both pins escape left off-centre; the one-bend route needs
  # terminal-aware Hanan axes.
  var s = Schematic(title: "terminal_axes")
  var a = SchematicPart(designator: "A", kind: "box", name: "", value: "",
                        symbol: "box", isBox: true,
                        bodyW: 100.0, bodyH: 100.0, inkW: 60.0, inkH: 60.0,
                        x: 0.0, y: 0.0, rotation: 0.0)
  a.pins.add SchematicPin(name: "P", x: -50.0, y: 20.0, net: "sig")
  var b = SchematicPart(designator: "B", kind: "box", name: "", value: "",
                        symbol: "box", isBox: true,
                        bodyW: 100.0, bodyH: 100.0, inkW: 60.0, inkH: 60.0,
                        x: 240.0, y: 160.0, rotation: 0.0)
  b.pins.add SchematicPin(name: "P", x: 190.0, y: 140.0, net: "sig")
  s.parts = @[a, b]
  let d = diagnoseFallbackNet(s, "sig")
  check d.routed
  check d.polys.len == 1
  check d.polys[0][0] == Point(x: -50.0, y: 20.0)
  check d.polys[0][1] == Point(x: -62.0, y: 20.0) # leftward escape
  check d.polys[0][^2] == Point(x: 178.0, y: 140.0)
  check d.polys[0][^1] == Point(x: 190.0, y: 140.0)
  check routeBends(d.polys[0]) == 1

  # JSON preserves the same diagnostic.
  check diagnoseFallbackNet(jsonToScene(sceneToJsonString(s)), "sig") == d

test "the fallback reroute diagnostic reads a finished scene, not the netlist":
  # `diagnoseAllFallbacks` re-routes against the scene's own geometry, so it
  # works on an archived scene with no netlist.
  let s = riaaTopScene
  let original = s
  let diags = diagnoseAllFallbacks(s)
  let archivedDiags = diagnoseAllFallbacks(jsonToScene(sceneToJsonString(s)))
  check diags == archivedDiags
  check s == original                 # diagnostics never mutate the scene
  check diags.len == 4
  for d in diags:
    check d.pins == 1
    check d.routed
    check d.blockDetail == "single dangling pin; not a routing failure"

  # Names are deduplicated in first-appearance order; an absent net may be
  # asked about explicitly.
  var duplicated = s
  duplicated.fallbacks.add duplicated.fallbacks[0]
  let ordered = diagnoseAllFallbacks(duplicated)
  check ordered.len == 4
  for i, net in ["inL", "outL", "inR", "outR"]:
    check ordered[i].net == net
  let absent = diagnoseFallbackNet(s, "absent")
  check absent.routed and absent.pins == 0
  check absent.blockDetail == "no endpoints in this scene"

test "terminal axes let the crowded chain diagnose only dangling endpoints":
  let s = chain37
  check s.fallbacks.len > 0
  var byNet = initTable[string, FallbackReroute]()
  for d in diagnoseAllFallbacks(s): byNet[d.net] = d
  # Only the two one-pin endpoints remain fallbacks.
  check byNet.len == 2
  check byNet.hasKey("n0") and byNet["n0"].pins == 1 and byNet["n0"].routed
  check byNet.hasKey("n37") and byNet["n37"].pins == 1 and byNet["n37"].routed
  check not byNet.hasKey("n28")

test "a scene that already routes has nothing to diagnose":
  check diagnoseAllFallbacks(riaaChannelScene).len == 0

test "a single dangling pin is a dashed stub with its exact net name":
  var nl = newNetlist("dangling")
  let a = addNet(nl, newNet("a"))
  let gnd = addNet(nl, newNet("0", ntGround))
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", a, ptPassive)
  discard connect(r1, "2", gnd, ptPassive)
  let s = layout(nl)
  check s.fallbacks.len == 1
  let f = s.fallbacks[0]
  check f.net == "a"
  check f.part == "R1"
  check f.pin == "1"
  check f.points.len == 2
  check f.points[0] == pinPoints(s, "R1", "a")[0]
  # No signal wire for the dangling net, only the marker.
  var routed = false
  for w in s.wires:
    if w.net == "a" and w.kind == wkSignal: routed = true
  check not routed
  check fallbacksClearOfWires(s)
  # The net name is still labelled at the pin.
  var saw = false
  for lb in s.labels:
    if lb.role == lrNet and lb.text == "a": saw = true
  check saw

test "a zero-space fallback keeps a public record, marker and label but no wire":
  var s = Schematic(title: "zero")
  s.fallbacks.add SchematicFallback(net: "dang", part: "R1", pin: "1",
                                    x: 40.0, y: 40.0, ex: -1.0, ey: 0.0)
  s.minX = 0.0; s.minY = 0.0; s.maxX = 100.0; s.maxY = 100.0
  s.labels.add SchematicLabel(text: "dang", x: 40.0, y: 36.0, anchor: taMiddle,
                              size: 12.0, role: lrNet, owner: "")
  let svg = renderSvg(s)
  check "stroke-dasharray=\"6 4\"" notin svg      # no wire
  check "stroke=\"#e67e22\"" in svg                # the marker is amber
  check "<circle" in svg
  let node = sceneToJson(s)
  check node["fallbacks"].len == 1
  check node["fallbacks"][0]["net"].getStr == "dang"
  check node["fallbacks"][0]["points"].len == 0

test "the stronger separation helpers distinguish crowding from crossing":
  # Perpendicular crossing stays allowed.
  check not parallelTooCloseT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                              Point(x: 5.0, y: -5.0), Point(x: 5.0, y: 5.0))
  # Parallel, 4 apart, projections overlap -> too close.
  check parallelTooCloseT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                          Point(x: 0.0, y: 4.0), Point(x: 10.0, y: 4.0))
  # Parallel, exactly 8 apart -> allowed.
  check not parallelTooCloseT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                              Point(x: 0.0, y: 8.0), Point(x: 10.0, y: 8.0))
  # Close but projections meet only at a point -> allowed.
  check not parallelTooCloseT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                              Point(x: 10.0, y: 4.0), Point(x: 20.0, y: 4.0))
  # Collinear end-to-end contact is a touch.
  check collinearTouchT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                        Point(x: 10.0, y: 0.0), Point(x: 20.0, y: 0.0))
  # Collinear with a gap is not a touch.
  check not collinearTouchT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                            Point(x: 11.0, y: 0.0), Point(x: 20.0, y: 0.0))

# --- label placement -------------------------------------------------------

test "no label lands on a wire, a body or another label":
  for nl in [divider(), starNet(), twoBlocks(), decoupledMcu(),
             resistorChain(6)]:
    check labelsClearOfGeometry(layout(nl))

test "every part label hugs its part rather than drifting off":
  # Designator/value labels sit within about a line-height of the part ink.
  let s = layout(divider())
  for lb in s.labels:
    if lb.role notin {lrDesignator, lrValue}: continue
    let p = partOf(s, lb.owner)
    check axisGapToInk(labelBoxT(lb), partInkRectT(p)) <= 40.0

test "a vertical-pin part keeps its labels off the pin wires":
  # V1's pins leave top and bottom, so its labels go to a side.
  let s = layout(divider())
  let v1 = partOf(s, "V1")
  for lb in s.labels:
    if lb.owner != "V1": continue
    check abs(lb.x - v1.x) >= v1.inkW / 2.0 - 1e-6

test "a rotated part's labels follow the short axis of its ink":
  # Whichever tee resistor turns vertical gets its labels left or right,
  # clear of its pin wires.
  var nl = newNetlist("tee")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("b"))
  let c = addNet(nl, newNet("c"))
  let d = addNet(nl, newNet("d"))
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", a, ptPassive); discard connect(r1, "2", b, ptPassive)
  r1.attrs["value"] = "1k"
  let r2 = addComponent(nl, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", b, ptPassive); discard connect(r2, "2", c, ptPassive)
  let r3 = addComponent(nl, newComponent("R3", kind = "resistor"))
  discard connect(r3, "1", b, ptPassive); discard connect(r3, "2", d, ptPassive)
  let s = layout(nl)
  var vertDesig = ""
  for desig in ["R1", "R2", "R3"]:
    if partOf(s, desig).rotation in [90.0, 270.0]: vertDesig = desig
  check vertDesig.len > 0
  let vertPart = partOf(s, vertDesig)
  check labelsClearOfGeometry(s)
  for lb in s.labels:
    if lb.owner != vertDesig: continue
    check abs(lb.x - vertPart.x) >= 8.0     # offset sideways, not stacked on the wire

test "the bounding box contains every label's text box":
  for nl in [divider(), starNet(), decoupledMcu()]:
    let s = layout(nl)
    for lb in s.labels:
      let box = labelBoxT(lb)
      check box.x1 >= s.minX - 1e-6
      check box.y1 >= s.minY - 1e-6
      check box.x2 <= s.maxX + 1e-6
      check box.y2 <= s.maxY + 1e-6

test "part designator and value are emitted as scene labels, not by the writer":
  let s = layout(divider())
  var haveR1des, haveR1val = false
  for lb in s.labels:
    if lb.role == lrDesignator and lb.text == "R1": haveR1des = true
    if lb.role == lrValue and lb.owner == "R1" and lb.text == "1k": haveR1val = true
  check haveR1des
  check haveR1val

test "a branched signal net partitions its tree without overlapping wires":
  let s = layout(starNet())
  var starWires = 0
  for w in s.wires:
    if w.net == "star" and w.kind == wkSignal:
      inc starWires
      check w.points.len >= 2
  # Three pins on one net -> two wires.
  check starWires == 2
  # Every pin of the net appears on some emitted wire.
  let pts = wirePoints(s, "star")
  for desig in ["R1", "R2", "R3"]:
    for p in pinPoints(s, desig, "star"):
      check p in pts

proc bendTee(): Netlist =
  ## A T-junction on net `b`: R1's pin is 96 units from R2's and R3's escape
  ## points, but R3 is one bend away and R2 two.
  result = newNetlist("tee")
  let a = addNet(result, newNet("a"))
  let b = addNet(result, newNet("b"))
  let c = addNet(result, newNet("c"))
  let d = addNet(result, newNet("d"))
  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", a, ptPassive); discard connect(r1, "2", b, ptPassive)
  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", b, ptPassive); discard connect(r2, "2", c, ptPassive)
  let r3 = addComponent(result, newComponent("R3", kind = "resistor"))
  discard connect(r3, "1", b, ptPassive); discard connect(r3, "2", d, ptPassive)

proc transistorAndBox(): Netlist =
  ## A net between a vertical-escape pin and a box's left-edge pin, one grid
  ## corner apart.
  result = newNetlist("tb")
  let sig = addNet(result, newNet("sig"))
  let gnd = addNet(result, newNet("0", ntGround))
  let q1 = addComponent(result, newComponent("Q1", kind = "transistor"))
  discard connect(q1, "B", sig, ptPassive)      # first pin -> top slot, escapes up
  discard connect(q1, "C", addNet(result, newNet("c")), ptPassive)
  discard connect(q1, "E", addNet(result, newNet("e")), ptPassive)
  let u1 = addComponent(result, newComponent("U1", kind = "mcu"))
  discard connect(u1, "IO", sig, ptInOut)       # left edge, escapes left
  discard connect(u1, "GND", gnd, ptGround)


test "pin escape stubs are free, not charged as route bends":
  let s = layout(transistorAndBox())
  var wire: seq[Point]
  for w in s.wires:
    if w.net == "sig" and w.kind == wkSignal:
      wire = w.points
      break
  check wire.len == 5
  if wire.len == 5:
    let qPin = pinPoints(s, "Q1", "sig")[0]
    let uPin = pinPoints(s, "U1", "sig")[0]
    check (wire[0] == qPin and wire[^1] == uPin) or
          (wire[0] == uPin and wire[^1] == qPin)
    # The end segments are 12-unit stubs; aligning them with the L removes
    # visual corners but never adds a charged bend.
    check visualBends(wire) <= 3
    check routeBends(wire) == 1

test "the overlap helper allows crossings and shared vertices, not collinear runs":
  # Perpendicular crossing.
  check not collinearOverlapT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                              Point(x: 5.0, y: -5.0), Point(x: 5.0, y: 5.0))
  # Meeting at one endpoint.
  check not collinearOverlapT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                              Point(x: 10.0, y: 0.0), Point(x: 20.0, y: 0.0))
  # Positive-length overlap.
  check collinearOverlapT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                          Point(x: 5.0, y: 0.0), Point(x: 15.0, y: 0.0))
  # Identical collinear segments.
  check collinearOverlapT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                          Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0))

# --- interface ports ---------------------------------------------------

proc portedSubckt(): Netlist =
  ## A subckt with an all-passive input, an op-amp output, a power rail, a
  ## rail known only from a `ptGround` supply pin, ground, a bidirectional
  ## bus port, an unspecified port a bare IC drives, and a pinless port.
  result = newNetlist("PORTED")
  let inn = addNet(result, newNet("IN"))
  let amp = addNet(result, newNet("amp"))
  let fb = addNet(result, newNet("fb"))
  let outn = addNet(result, newNet("OUT"))
  let vp = addNet(result, newNet("VP", ntPower))
  let vn = addNet(result, newNet("VN", ntPower))
  let bus = addNet(result, newNet("BUS"))
  let drv = addNet(result, newNet("DRV"))
  let nc = addNet(result, newNet("NC"))
  let gnd = addNet(result, newNet("0", ntGround))

  let rl = addComponent(result, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", inn, ptPassive)
  discard connect(rl, "2", gnd, ptPassive)
  let cin = addComponent(result, newComponent("CIN", kind = "capacitor"))
  discard connect(cin, "1", inn, ptPassive)
  discard connect(cin, "2", amp, ptPassive)

  let u1 = addComponent(result, newComponent("U1", kind = "opamp"))
  discard connect(u1, "IN+", amp, ptInput)
  discard connect(u1, "IN-", fb, ptInput)
  discard connect(u1, "OUT", outn, ptOutput)
  discard connect(u1, "V+", vp, ptPower)
  discard connect(u1, "V-", vn, ptGround)

  let rf = addComponent(result, newComponent("RF", kind = "resistor"))
  discard connect(rf, "1", outn, ptPassive)
  discard connect(rf, "2", fb, ptPassive)
  let rg = addComponent(result, newComponent("RG", kind = "resistor"))
  discard connect(rg, "1", fb, ptPassive)
  discard connect(rg, "2", gnd, ptPassive)

  let u2 = addComponent(result, newComponent("U2", kind = "mcu"))
  discard connect(u2, "IO", bus, ptInOut)
  discard connect(u2, "DRV", drv, ptPassive)
  let rd = addComponent(result, newComponent("RD", kind = "resistor"))
  discard connect(rd, "1", drv, ptPassive)
  discard connect(rd, "2", gnd, ptPassive)
  let rb = addComponent(result, newComponent("RB", kind = "resistor"))
  discard connect(rb, "1", bus, ptPassive)
  discard connect(rb, "2", gnd, ptPassive)

  for (name, n) in [("IN", inn), ("OUT", outn), ("VP", vp), ("VN", vn),
                    ("BUS", bus), ("DRV", drv), ("NC", nc), ("GND", gnd)]:
    addPort(result, name, n)

test "ports and bend-tested topologies also respect the separation":
  for nl in [portedSubckt(), bendTee(), transistorAndBox()]:
    let s = layout(nl)
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)

proc portOf(s: Schematic, name: string): SchematicPort =
  for p in s.ports:
    if p.name == name: return p
  doAssert false, "no port named " & name

proc hasPort(s: Schematic, name: string): bool =
  for p in s.ports:
    if p.name == name: return true
  false

test "a port net's direction: pin kind first, then a driver test":
  let s = layout(portedSubckt())
  # IN is all-passive and undriven -> input.
  check portOf(s, "IN").dir == pdInput
  # OUT carries a ptOutput pin.
  check portOf(s, "OUT").dir == pdOutput
  # BUS carries a ptInOut pin.
  check portOf(s, "BUS").dir == pdBidir
  # DRV is passive-pinned but a bare IC sits on it.
  check portOf(s, "DRV").dir == pdUnspecified

test "rail, ground and pinless ports draw no port symbol":
  let s = layout(portedSubckt())
  check not hasPort(s, "VP")
  check not hasPort(s, "VN")
  check not hasPort(s, "GND")
  check not hasPort(s, "NC")
  check s.ports.len == 4

test "a ptGround supply pin does not turn an ntPower net into ground":
  let s = layout(portedSubckt())
  var vnSupply = false
  for w in s.wires:
    if w.net == "VN":
      check w.kind == wkSupply
      vnSupply = true
    if w.net == "VN": check w.kind != wkGround
  check vnSupply

test "input ports sit left of every part, output ports right of every part":
  let s = layout(portedSubckt())
  let inp = portOf(s, "IN")
  let outp = portOf(s, "OUT")
  for p in s.parts:
    check inp.x + inp.bodyW / 2.0 <= p.x - p.bodyW / 2.0 + 1e-9
    check outp.x - outp.bodyW / 2.0 >= p.x + p.bodyW / 2.0 - 1e-9

test "a ported net carries no duplicate text label":
  let s = layout(portedSubckt())
  for lb in s.labels:
    check lb.text notin ["IN", "OUT", "BUS", "DRV"]

test "ports do not overlap part bodies, and wires still never overlap":
  let s = layout(portedSubckt())
  check distinctWiresNeverShareCollinearRuns(s)
  for pt in s.ports:
    let pr = (x1: pt.x - pt.bodyW / 2.0, y1: pt.y - pt.bodyH / 2.0,
              x2: pt.x + pt.bodyW / 2.0, y2: pt.y + pt.bodyH / 2.0)
    for p in s.parts:
      let hw = p.bodyW / 2.0
      let hh = p.bodyH / 2.0
      check pr.x2 <= p.x - hw + 1e-9 or pr.x1 >= p.x + hw - 1e-9 or
            pr.y2 <= p.y - hh + 1e-9 or pr.y1 >= p.y + hh - 1e-9

test "the bounding box contains every port body":
  let s = layout(portedSubckt())
  for pt in s.ports:
    check pt.x - pt.bodyW / 2.0 >= s.minX - 1e-9
    check pt.x + pt.bodyW / 2.0 <= s.maxX + 1e-9
    check pt.y - pt.bodyH / 2.0 >= s.minY - 1e-9
    check pt.y + pt.bodyH / 2.0 <= s.maxY + 1e-9

test "the public json api exposes ports additively, each with its direction":
  let node = parseJson(sceneToJsonString(portedSubckt()))
  # Adding ports leaves the other top-level keys intact.
  for key in ["parts", "wires", "labels", "ports"]:
    check node.hasKey(key)
  check node["ports"].len == 4
  var dirs: seq[string]
  for p in node["ports"]: dirs.add p["dir"].getStr
  for d in ["input", "output", "bidir", "unspecified"]:
    check d in dirs

test "renderSvg draws one polygon per port, each named":
  let s = layout(portedSubckt())
  let text = renderSvg(s)
  var polys = 0
  var i = 0
  while true:
    let n = text.find("<polygon", i)
    if n < 0: break
    inc polys
    i = n + 1
  # One polygon per drawn port, plus U1's opamp body.
  check polys == s.ports.len + 1
  check ">IN</text>" in text
  check ">OUT</text>" in text
  check ">BUS</text>" in text
  check ">DRV</text>" in text

test "the default pipeline and its reserved no-op stages are byte-stable":
  let nl = divider()
  let baseline = layout(nl)
  let baselineJson = sceneToJsonString(baseline)
  let baselineSvg = renderSvg(baseline)

  # An explicit default LayoutOptions is the same as none at all.
  check sceneToJsonString(layout(nl, defaultLayoutOptions())) == baselineJson
  check allLayoutStages == {lsPrepare..lsBounds}
  check defaultLayoutOptions().stageSpecs.len == ord(StageId.high) + 1

  # Reserved stages are no-ops here: dropping any one changes nothing.
  # `lsConstrainedRefinement` must stay inert until finished; the divider has
  # no orientable composite or interface port. `lsSemanticSeed` does real
  # work, so it's excluded.
  for stage in [lsBundles, lsArrays, lsPartArrays, lsConstrainedRefinement,
                lsCompositeOrient, lsRoutingAwareRepair, lsPortRefine]:
    var options = defaultLayoutOptions()
    options.stages.excl stage
    let scene = layout(nl, options)
    check sceneToJsonString(scene) == baselineJson
    check renderSvg(scene) == baselineSvg

test "layout options can suppress labels and bounds":
  var options = defaultLayoutOptions()
  options.stages.excl lsLabels
  options.stages.excl lsBounds
  let s = layout(divider(), options)
  check s.labels.len == 0
  check s.minX == 0.0
  check s.minY == 0.0
  check s.maxX == 0.0
  check s.maxY == 0.0

test "layout options reject missing routing prerequisites":
  var options = defaultLayoutOptions()
  options.stages.excl lsPrepareRouting
  expect ValueError:
    discard layout(divider(), options)

# --- the archive, which needs the simulator -----------------------------

suite "run archive svg":
  if not haveNgspice:
    echo "  [skipped: ngspice not found on PATH]"
  else:
    test "an svg and its json scene land beside the deck, rawfile and log":
      let dir = createTempDir("verax_svgtests_", "")
      defer: removeDir(dir)
      withEnv("VERAX_KEEP_RUNS", dir):
        discard run(plainDivider(), ".op")

      check fileExists(dir / "run000.svg")
      let svg = readFile(dir / "run000.svg")
      check svg.startsWith("<?xml")
      check ">R1</text>" in svg
      check ">C1</text>" in svg
      check ">V1</text>" in svg

      # The JSON is byte-for-byte a fresh layout of the same fragment.
      check fileExists(dir / "run000.json")
      check readFile(dir / "run000.json") == sceneToJsonString(plainDivider())

    test "a failed run still keeps its svg and json, like its deck and log":
      # The picture is drawn before ngspice runs, so a convergence failure
      # still leaves it.
      let dir = createTempDir("verax_svgtests_", "")
      defer: removeDir(dir)
      withEnv("VERAX_KEEP_RUNS", dir):
        expect(SpiceSimError):
          discard run(divider(), ".op")

      check fileExists(dir / "run000.svg")
      check fileExists(dir / "run000.json")
      check ">U1</text>" in readFile(dir / "run000.svg")

# --- layout.side overrides --------------------------------------------

import verax/netlist/layouthints

suite "layout side overrides":
  proc rightEdge(p: SchematicPart): float = p.x + p.bodyW / 2.0
  proc leftEdge(p: SchematicPart): float = p.x - p.bodyW / 2.0

  proc layeredChain(): Netlist =
    ## U1 -> U2 -> U3 -> R1, an output-pin chain layered left to right.
    result = newNetlist("layered_ov")
    let a = addNet(result, newNet("a"))
    let b = addNet(result, newNet("b"))
    let c = addNet(result, newNet("c"))
    let u1 = addComponent(result, newComponent("U1", kind = "mcu"))
    discard connect(u1, "OUT", a, ptOutput)
    let u2 = addComponent(result, newComponent("U2", kind = "mcu"))
    discard connect(u2, "IN", a, ptInput)
    discard connect(u2, "OUT", b, ptOutput)
    let u3 = addComponent(result, newComponent("U3", kind = "mcu"))
    discard connect(u3, "IN", b, ptInput)
    discard connect(u3, "OUT", c, ptOutput)
    let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
    discard connect(r1, "1", c, ptPassive)
    discard connect(r1, "2", addNet(result, newNet("d")), ptPassive)

  test "a left-overridden component lands strictly left of everything else":
    let nl = layeredChain()
    setLayoutSide(findComponent(nl, "R1"), sideLeft) # naturally rightmost
    let s = layout(nl)
    let r1 = partOf(s, "R1")
    for desig in ["U1", "U2", "U3"]:
      check rightEdge(r1) < leftEdge(partOf(s, desig))
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)

  test "a right-overridden component lands strictly right of everything else":
    let nl = layeredChain()
    setLayoutSide(findComponent(nl, "U1"), sideRight) # naturally leftmost
    let s = layout(nl)
    let u1 = partOf(s, "U1")
    for desig in ["U2", "U3", "R1"]:
      check leftEdge(u1) > rightEdge(partOf(s, desig))
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)

  test "ports stay outside an overridden component's dedicated column":
    let nl = newNetlist("ported_ov")
    let ip = addNet(nl, newNet("in1"))
    let op = addNet(nl, newNet("out1"))
    let u1 = addComponent(nl, newComponent("U1", kind = "mcu"))
    discard connect(u1, "IN", ip, ptInput)
    discard connect(u1, "OUT", op, ptOutput)
    let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
    discard connect(r1, "1", op, ptPassive)
    discard connect(r1, "2", addNet(nl, newNet("tail")), ptPassive)
    addPort(nl, "IN", ip)
    addPort(nl, "OUT", op)
    setLayoutSide(findComponent(nl, "R1"), sideLeft)
    let s = layout(nl)
    let r1p = partOf(s, "R1")
    var checkedAny = false
    for port in s.ports:
      if port.dir in {pdInput, pdUnspecified}:
        checkedAny = true
        check port.x + port.bodyW / 2.0 < leftEdge(r1p)
    check checkedAny

  test "an overridden sheet lays out deterministically":
    let nl = layeredChain()
    setLayoutSide(findComponent(nl, "R1"), sideLeft)
    check sceneToJsonString(layout(nl)) == sceneToJsonString(layout(nl))

  test "no override is byte-identical with lsLayoutOverrides in or out of stages":
    let a = layeredChain()
    let b = layeredChain()
    var withStage = defaultLayoutOptions()
    var withoutStage = defaultLayoutOptions()
    withoutStage.stages.excl lsLayoutOverrides
    check sceneToJsonString(layout(a, withStage)) ==
          sceneToJsonString(layout(b, withoutStage))

  test "disabling lsLayoutOverrides drops an override to the pre-feature scene":
    let overridden = layeredChain()
    setLayoutSide(findComponent(overridden, "R1"), sideLeft)
    var withoutStage = defaultLayoutOptions()
    withoutStage.stages.excl lsLayoutOverrides
    let plain = layeredChain()
    check sceneToJsonString(layout(overridden, withoutStage)) ==
          sceneToJsonString(layout(plain))

  proc manyIsolatedResistors(n: int): Netlist =
    ## `n` unconnected resistors: the pool is exactly `n` parts.
    result = newNetlist("isolated_many")
    for i in 1 .. n:
      let a = addNet(result, newNet("a" & $i))
      let b = addNet(result, newNet("b" & $i))
      let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
      discard connect(r, "1", a, ptPassive)
      discard connect(r, "2", b, ptPassive)

  test "the side guarantee holds on a sheet too large for constrained layering":
    # 65 pool items is over `constrainedMaxParts`, so the semantic seed never
    # runs and this exercises `enforceLayoutSides` alone.
    let nl = manyIsolatedResistors(65)
    setLayoutSide(findComponent(nl, "R1"), sideLeft)
    let s = layout(nl)
    let r1 = partOf(s, "R1")
    for i in 2 .. 65:
      check rightEdge(r1) < leftEdge(partOf(s, "R" & $i))

  proc parallelPair(): Netlist =
    ## R1 || C1: one placement unit.
    result = newNetlist("pair_ov")
    let a = addNet(result, newNet("a"))
    let b = addNet(result, newNet("b"))
    let r = addComponent(result, newComponent("R1", kind = "resistor"))
    discard connect(r, "1", a, ptPassive)
    discard connect(r, "2", b, ptPassive)
    let c = addComponent(result, newComponent("C1", kind = "capacitor"))
    discard connect(c, "1", a, ptPassive)
    discard connect(c, "2", b, ptPassive)

  test "a composite whose members disagree on side resolves first-wins, reported as a conflict":
    let nl = parallelPair()
    setLayoutSide(findComponent(nl, "R1"), sideLeft)
    setLayoutSide(findComponent(nl, "C1"), sideRight)
    let rep = layoutOverrideReport(nl)
    check "R1=left" in rep
    var sawConflict = false
    for line in rep:
      if line.startsWith("C1=right") and "conflict" in line: sawConflict = true
    check sawConflict

  test "a composite carrying a side override moves as one unit":
    let nl = parallelPair()
    setLayoutSide(findComponent(nl, "R1"), sideLeft)
    let r2 = addComponent(nl, newComponent("R2", kind = "resistor"))
    discard connect(r2, "1", addNet(nl, newNet("x")), ptPassive)
    discard connect(r2, "2", addNet(nl, newNet("y")), ptPassive)
    let s = layout(nl)
    let r1p = partOf(s, "R1")
    let c1p = partOf(s, "C1")
    let r2p = partOf(s, "R2")
    check max(rightEdge(r1p), rightEdge(c1p)) < leftEdge(r2p)

  test "layoutOverrideReport is empty for a netlist with no override":
    check layoutOverrideReport(layeredChain()).len == 0

# --- multi-channel package labels -----------------------------------

import verax/netlist/dsl as nldsl
import verax/netlist/packages

suite "packaged part labels":
  proc packagedPair(): Netlist =
    let dual = newPackageDef("SCH_DUAL", [
      (id: "1", section: "A", logical: "OUT"),
      (id: "2", section: "B", logical: "OUT")], partNumber = "SCH_DUAL")
    try: registerPackage(dual)
    except CatchableError: discard
    let u5 = packageInstance("SCH_DUAL", "U5")
    result = nldsl.netlist("pp"):
      net gnd, kind = ntGround, name = "0"
      net a, kind = ntSignal
      net b, kind = ntSignal
      component IC1, kind = "opamp":
        pin "OUT", a
        pin "IN", gnd
      component IC2, kind = "opamp":
        pin "OUT", b
        pin "IN", gnd
    u5.assign(result, "A", "IC1")
    u5.assign(result, "B", "IC2")

  test "label is the display designator for a packaged part, empty otherwise":
    let s = layout(packagedPair())
    var byDesig: Table[string, SchematicPart]
    for p in s.parts: byDesig[p.designator] = p
    check byDesig["IC1"].label == "U5A"   # ref U5 + section A
    check byDesig["IC2"].label == "U5B"
    check byDesig["IC1"].designator == "IC1"   # join key untouched

  test "label round-trips through the scene JSON":
    let s = layout(packagedPair())
    let back = jsonToScene(parseJson(sceneToJsonString(s)))
    var a, b: SchematicPart
    for p in back.parts:
      if p.designator == "IC1": a = p
      if p.designator == "IC2": b = p
    check a.label == "U5A"
    check b.label == "U5B"

  test "an unpackaged part carries an empty label":
    let nl = nldsl.netlist("plain"):
      net gnd, kind = ntGround, name = "0"
      net a, kind = ntSignal
      component R1, kind = "resistor", value = "1k":
        pin "1", a
        pin "2", gnd
    for p in layout(nl).parts:
      check p.label == ""

# --- bus- and interface-aware rendering -----------------------------------

import verax/netlist/interfaces
import verax/netlist/interfaces/std as nlstd

suite "bundle plan (bus/interface grouping)":
  let spiMemLink = block:
    let d = nldsl.interfaceDef("spi_memory_link"):
      signal sclk
      signal mosi
      signal miso, shared = true
      modport peripheral:
        sclk = ptInput
        mosi = ptInput
        miso = ptInOut
    d

  proc spiPeripheralSheet(): Netlist =
    ## A memory box with its SPI link as a peripheral modport port, plus two
    ## straps to a rail.
    nldsl.subckt("SPI_MEMORY", [vdd, gnd, spi.peripheral, cs]):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      iface spi, spiMemLink
      net cs, kind = ntSignal
      component U1, kind = "memory":
        pin "VCC", vdd, kind = ptPower
        pin "VSS", gnd, kind = ptGround
        port spi, peripheral, pins = {"sclk": "SCK", "mosi": "SI", "miso": "SO"}
        pin "CS", cs, kind = ptInput
        pin "HOLD", vdd, kind = ptInput
        pin "WP", vdd, kind = ptInput

  proc spiSharedBusSheet(): Netlist =
    ## An MCU sharing one SPI bus between two peripheral boxes, plus a MISO
    ## pull-down. Portless.
    nldsl.netlist("spi_shared"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      iface spi1, nlstd.spiInterface(2)
      component U1, kind = "mcu":
        pin "VDD", vdd, kind = ptPower
        pin "VSS", gnd, kind = ptGround
        port spi1, controller, pins = {"sclk": "SCK", "mosi": "MOSI",
          "miso": "MISO", "cs_0": "NSS0", "cs_1": "NSS1"}
      component R1, kind = "resistor", value = "100k":
        pin "1", spi1["miso"], kind = ptPassive
        pin "2", gnd, kind = ptGround
      component U2, kind = "memory":
        pin "SCK", spi1["sclk"], kind = ptInput
        pin "SI", spi1["mosi"], kind = ptInput
        pin "SO", spi1["miso"], kind = ptInOut
        pin "CS", spi1.bus("cs")[0], kind = ptInput
        pin "VSS", gnd, kind = ptGround
      component U3, kind = "memory":
        pin "SCK", spi1["sclk"], kind = ptInput
        pin "SI", spi1["mosi"], kind = ptInput
        pin "SO", spi1["miso"], kind = ptInOut
        pin "CS", spi1.bus("cs")[1], kind = ptInput
        pin "VSS", gnd, kind = ptGround

  proc i2cUnpublishedSheet(): Netlist =
    ## An interface across four parts, never published -- flat, no port.
    nldsl.netlist("i2c_flat"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      iface i2c, nlstd.i2cInterface()
      component U1, kind = "mcu":
        pin "VDD", vdd, kind = ptPower
        pin "VSS", gnd, kind = ptGround
        port i2c, controller
      component R1, kind = "resistor", value = "1.5k":
        pin "1", vdd, kind = ptPassive
        pin "2", i2c["sda"], kind = ptPassive
      component R2, kind = "resistor", value = "1.5k":
        pin "1", vdd, kind = ptPassive
        pin "2", i2c["scl"], kind = ptPassive
      component U2, kind = "eeprom":
        pin "SDA", i2c["sda"], kind = ptInOut
        pin "SCL", i2c["scl"], kind = ptInput
        pin "VSS", gnd, kind = ptGround

  test "a published peripheral interface on one box collapses":
    let rep = bundleReport(spiPeripheralSheet())
    check rep.len == 1
    check rep[0].display == "spi"
    check rep[0].kind == "interface"
    check rep[0].role == "collapsed"
    check rep[0].members == @["spi_sclk", "spi_mosi", "spi_miso"]
    check rep[0].entities == @["U1"]

  test "a shared bus across three-plus endpoints degrades to grouped net labels":
    let rep = bundleReport(spiSharedBusSheet())
    # 4 component entities -> one net-label bundle over every member net, no
    # per-signal sub-bundle.
    check rep.len == 1
    check rep[0].display == "spi1"
    check rep[0].kind == "interface"
    check rep[0].role == "netlabel"
    check rep[0].members == @["spi1_sclk", "spi1_mosi", "spi1_miso",
                              "spi1_cs_0", "spi1_cs_1"]
    check rep[0].entities == @["R1", "U1", "U2", "U3"]

  test "an unpublished interface across 3+ entities also degrades to net labels":
    let rep = bundleReport(i2cUnpublishedSheet())
    check rep.len == 1
    check rep[0].kind == "interface"
    check rep[0].role == "netlabel"
    check rep[0].members == @["i2c_scl", "i2c_sda"]
    check rep[0].entities == @["R1", "R2", "U1", "U2"]

  test "a bus-free netlist yields an empty report":
    check bundleReport(divider()).len == 0

  proc discardedBusSheet(): Netlist =
    ## A width-1 bus between three parts: below the two-member floor, so it
    ## routes as a scalar, only recoloured.
    nldsl.netlist("discarded_bus"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      bus b, width = 1
      component U1, kind = "mcu":
        pin "VDD", vdd, kind = ptPower
        pin "G", gnd, kind = ptGround
        pin "D", b[0], kind = ptOutput
      component U2, kind = "mem":
        pin "G", gnd, kind = ptGround
        pin "Q", b[0], kind = ptInput
      component R1, kind = "resistor", value = "10k":
        pin "1", b[0], kind = ptPassive
        pin "2", gnd, kind = ptGround

  test "membership colour recolours a wire without moving it":
    let nl = discardedBusSheet()
    check bundleReport(nl).len == 0            # discarded, no bundle
    var opts = defaultLayoutOptions()
    let coloured = layout(nl, opts)
    opts.stages.excl lsBundles
    let plain = layout(nl, opts)
    # Only the wire kind differs.
    check coloured.wires.len == plain.wires.len
    var recoloured = 0
    for i in 0 ..< coloured.wires.len:
      check coloured.wires[i].points == plain.wires[i].points
      check coloured.wires[i].net == plain.wires[i].net
      if coloured.wires[i].kind != plain.wires[i].kind:
        check plain.wires[i].kind == wkSignal
        check coloured.wires[i].kind == wkBus
        check coloured.wires[i].members.len == 0   # colour only, not collapsed
        inc recoloured
    check recoloured > 0
    check "#1f6feb" in renderSvg(coloured)

  proc scalarBusSheet(): Netlist =
    ## A non-uniform, non-ported 2-net bus over two entities: below the
    ## net-label threshold, so `brScalar` -- recoloured wires.
    nldsl.netlist("scalar_bus"):
      net gnd, kind = ntGround, name = "0"
      bus b, width = 2
      component U1, kind = "mcu":
        pin "G", gnd, kind = ptGround
        pin "D0", b[0], kind = ptOutput
      component U2, kind = "mem":
        pin "G", gnd, kind = ptGround
        pin "Q0", b[0], kind = ptInput
        pin "Q1", b[1], kind = ptInput
        pin "Q1B", b[1], kind = ptInput

  test "a 2-entity non-uniform bus stays a recoloured scalar":
    let rep = bundleReport(scalarBusSheet())
    check rep.len == 1
    check rep[0].kind == "bus"
    check rep[0].role == "scalar"
    check rep[0].members == @["b_0", "b_1"]
    check rep[0].entities == @["U1", "U2"]
    let s = layout(scalarBusSheet())
    var recoloured = 0
    for w in s.wires:
      if w.kind == wkBus:
        check w.members.len == 0
        inc recoloured
    check recoloured > 0

  proc twoBoxBundleSheet(): Netlist =
    ## A bus between two boxes, not ported: collapses to one thick wire.
    nldsl.netlist("two_box_bus"):
      net gnd, kind = ntGround, name = "0"
      bus db, width = 4
      component U1, kind = "mcu":
        pin "G", gnd, kind = ptGround
        pin "D0", db[0], kind = ptOutput
        pin "D1", db[1], kind = ptOutput
        pin "D2", db[2], kind = ptOutput
        pin "D3", db[3], kind = ptOutput
      component U2, kind = "mem":
        pin "G", gnd, kind = ptGround
        pin "Q0", db[0], kind = ptInput
        pin "Q1", db[1], kind = ptInput
        pin "Q2", db[2], kind = ptInput
        pin "Q3", db[3], kind = ptInput

  test "a published peripheral interface collapses to one merged pin and wire":
    let nl = spiPeripheralSheet()
    let s = layout(nl)
    var u1: SchematicPart
    for p in s.parts:
      if p.designator == "U1": u1 = p
    let c = nl.findComponent("U1")
    check u1.pins.len == c.pins.len - 2          # SCK/SI/SO -> one "spi[3]"
    var merged: SchematicPin
    var mergedCount = 0
    for pin in u1.pins:
      if pin.name == "spi[3]":
        merged = pin
        inc mergedCount
    check mergedCount == 1
    check merged.net == "spi"
    check merged.members.len == 3
    check merged.members[0] == BundleMember(name: "sclk", net: "spi_sclk")
    # One merged bidirectional port (mixed member directions).
    var ports: seq[SchematicPort]
    for pt in s.ports:
      if pt.name == "spi[3]": ports.add pt
    check ports.len == 1
    check ports[0].dir == pdBidir
    check ports[0].net == "spi"
    check ports[0].members.len == 3
    # One thick interface wire carrying all three member nets, no fallbacks.
    var busWires: seq[SchematicWire]
    for w in s.wires:
      if w.kind == wkInterface: busWires.add w
    check busWires.len == 1
    check busWires[0].net == "spi"
    check busWires[0].members.len == 3
    check s.fallbacks.len == 0
    # The 4-unit stroke doesn't leak into the router.
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)
    check signalWiresRespectForeignSeeds(s)
    let svg = renderSvg(s)
    check "#8250df" in svg
    check "stroke-width=\"4\"" in svg

  test "lsBundles off restores the pre-feature scene":
    let nl = spiPeripheralSheet()
    var opts = defaultLayoutOptions()
    opts.stages.excl lsBundles
    let s = layout(nl, opts)
    var u1: SchematicPart
    for p in s.parts:
      if p.designator == "U1": u1 = p
    check u1.pins.len == nl.findComponent("U1").pins.len
    var spiPorts, spiWires = 0
    for pt in s.ports:
      if pt.name.startsWith("spi_"): inc spiPorts
    for w in s.wires:
      if w.net.startsWith("spi_") and w.kind == wkSignal: inc spiWires
    check spiPorts == 3
    check spiWires == 3
    for w in s.wires:
      check w.kind != wkInterface
      check w.kind != wkBus

  test "a bus between two boxes with no port collapses to one thick wire":
    let rep = bundleReport(twoBoxBundleSheet())
    check rep.len == 1
    check rep[0].role == "collapsed"
    check rep[0].entities == @["U1", "U2"]
    check rep[0].port == ""       # nothing published -- no pennant to name
    let s = layout(twoBoxBundleSheet())
    var thick = 0
    for w in s.wires:
      if w.kind == wkBus and w.members.len > 1: inc thick
    check thick == 1
    check s.ports.len == 0
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)

  proc uniformThreeBoxBusSheet(): Netlist =
    ## A bus wired identically to three boxes: collapse has no entity cap, so
    ## this is one bus tree, not net labels.
    nldsl.netlist("three_box_bus"):
      net gnd, kind = ntGround, name = "0"
      bus db, width = 4
      for nm in ["U1", "U2", "U3"]:
        component U, designator = nm, kind = "mcu":
          pin "G", gnd, kind = ptGround
          pin "D0", db[0], kind = ptPassive
          pin "D1", db[1], kind = ptPassive
          pin "D2", db[2], kind = ptPassive
          pin "D3", db[3], kind = ptPassive

  test "a uniform bus across three boxes collapses to one bus tree, no entity cap":
    let rep = bundleReport(uniformThreeBoxBusSheet())
    check rep.len == 1
    check rep[0].role == "collapsed"
    check rep[0].entities == @["U1", "U2", "U3"]
    let s = layout(uniformThreeBoxBusSheet())
    check s.fallbacks.len == 0
    var busWires = 0
    var mergedPins = 0
    for w in s.wires:
      if w.kind == wkBus and w.members.len > 1: inc busWires
    for p in s.parts:
      for pin in p.pins:
        if pin.members.len > 1: inc mergedPins
    check busWires > 0
    check mergedPins == 3        # one merged pin per box
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)
    check signalWiresRespectForeignSeeds(s)
    check labelsClearOfGeometry(s)

  proc wideEnableBusSheet(published: openArray[int]): Netlist =
    ## An 8-wide bus, one member per box: not uniform -> `brNetLabel`.
    ## `published` names the members reaching the sheet boundary.
    result = nldsl.netlist("wide_en_bus"):
      net gnd, kind = ntGround, name = "0"
      bus en, width = 8
      for i in 0 ..< 8:
        component U, designator = "U" & $i, kind = "mcu":
          pin "G", gnd, kind = ptGround
          pin "EN", en[i], kind = ptInput
    for i in published:
      addPort(result, "en_" & $i, findNet(result, "en_" & $i))

  test "a fully published bus renders Verilog-style":
    let rep = bundleReport(wideEnableBusSheet([0, 1, 2, 3, 4, 5, 6, 7]))
    check rep.len == 1
    check rep[0].role == "netlabel"
    check rep[0].port == "en[7:0]"
    # An interface's merged tag keeps the count form (`spi[3]`, below): its
    # members are named signals, not bus bits.

  test "a partially published bus renders its published subset compactly":
    check bundleReport(wideEnableBusSheet([7, 6, 5, 2]))[0].port == "en[7:5,2]"
    check bundleReport(wideEnableBusSheet([3]))[0].port == "en[3]"

  test "a fully published wide bus lays out as one pennant carrying every member":
    let s = layout(wideEnableBusSheet([0, 1, 2, 3, 4, 5, 6, 7]))
    check s.ports.len == 1
    check s.ports[0].name == "en[7:0]"
    check s.ports[0].members.len == 8
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)
    check signalWiresRespectForeignSeeds(s)

  test "a bundled sheet still upholds the occupancy invariants":
    for nl in [spiPeripheralSheet(), twoBoxBundleSheet(),
               spiSharedBusSheet(), i2cUnpublishedSheet()]:
      let s = layout(nl)
      check distinctWiresNeverShareCollinearRuns(s)
      check differentNetsRespectSeparation(s)
      check signalWiresRespectForeignSeeds(s)

  test "stripping every bus/iface attr restores the pre-feature scene byte-for-byte":
    ## A netlist with no `bus.*`/`iface.*` net attr lays out identically with
    ## `lsBundles` on or off.
    proc bussed(): Netlist =
      nldsl.netlist("i2c_bus"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        iface i2c, nlstd.i2cInterface()
        component U1, kind = "mcu":
          pin "VDD", vdd, kind = ptPower
          pin "VSS", gnd, kind = ptGround
          pin "SDA", i2c["sda"], kind = ptInOut
          pin "SCL", i2c["scl"], kind = ptOutput
        component R1, kind = "resistor", value = "1.5k":
          pin "1", vdd, kind = ptPassive
          pin "2", i2c["sda"], kind = ptPassive
        component R2, kind = "resistor", value = "1.5k":
          pin "1", vdd, kind = ptPassive
          pin "2", i2c["scl"], kind = ptPassive
        component U2, kind = "eeprom":
          pin "SDA", i2c["sda"], kind = ptInOut
          pin "SCL", i2c["scl"], kind = ptInput
          pin "VSS", gnd, kind = ptGround
    # As authored (i2c across 4 entities) it's a net-label bundle.
    check bundleReport(bussed()).len == 1
    let nl = bussed()
    for _, net in nl.nets:
      var kill: seq[string]
      for k in net.attrs.keys:
        if k.startsWith("bus.") or k.startsWith("iface."): kill.add k
      for k in kill: net.attrs.del k
    check bundleReport(nl).len == 0
    var opts = defaultLayoutOptions()
    let on = sceneToJsonString(layout(nl, opts))
    opts.stages.excl lsBundles
    let off = sceneToJsonString(layout(nl, opts))
    check on == off

  test "the i2c shared-bus shape: merged tags on the boxes, one x2 pull-up array":
    let nl = i2cUnpublishedSheet()
    let rep = bundleReport(nl)
    check rep.len == 1
    check rep[0].role == "netlabel"
    check rep[0].labels.sorted == @["R1=", "R2=", "U1=i2c", "U2=i2c"]
    let s = layout(nl)
    # The two boxes carry one merged "i2c" pin each.
    var mergedBoxes = 0
    for p in s.parts:
      if p.designator notin ["U1", "U2"]: continue
      for pin in p.pins:
        if pin.name == "i2c":
          check pin.members.len == 2
          inc mergedBoxes
    check mergedBoxes == 2
    # R1/R2 are identical pull-ups whose only varying pin is a member of a
    # bus merged elsewhere: they collapse to one x2 box.
    var pullupArray = false
    for p in s.parts:
      if p.designator == "R1" and p.count == 2 and p.members == @["R1", "R2"]:
        pullupArray = true
    check pullupArray
    var tags = initCountTable[string]()
    for f in s.fallbacks:
      check f.kind == fbNetLabel
      tags.inc f.net
    # U1, U2 and the R1/R2 array each carry one "i2c" tag; no bare member
    # tags.
    check tags["i2c"] == 3
    check "i2c_sda" notin tags
    check "i2c_scl" notin tags
    # No member-net wires.
    for w in s.wires:
      check w.net notin ["i2c_sda", "i2c_scl", "i2c"]

  test "a rail bus declines the whole bundle":
    proc railBus(): Netlist =
      nldsl.netlist("rail_bus"):
        net gnd, kind = ntGround, name = "0"
        bus pwr, width = 2
        component U1, kind = "mcu":
          pin "G", gnd, kind = ptGround
          pin "P0", pwr[0], kind = ptPower
          pin "P1", pwr[1], kind = ptPower
        component U2, kind = "mem":
          pin "G", gnd, kind = ptGround
          pin "P0", pwr[0], kind = ptPower
          pin "P1", pwr[1], kind = ptPower
    check bundleReport(railBus()).len == 0
    let s = layout(railBus())
    var supply = 0
    for w in s.wires:
      if w.kind == wkSupply: inc supply
    check supply == 4

  proc brokenOutInterfaceSheet(): Netlist =
    ## A subckt wiring every interface signal into two parts -> three
    ## entities -> brNetLabel: name tags, no wires.
    nldsl.subckt("SPI_FANOUT", [vdd, gnd, spi.peripheral]):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      iface spi, spiMemLink
      component U1, kind = "memory":
        pin "VCC", vdd, kind = ptPower
        pin "VSS", gnd, kind = ptGround
        port spi, peripheral, pins = {"sclk": "SCK", "mosi": "SI", "miso": "SO"}
      component U2, kind = "memory":
        pin "VCC", vdd, kind = ptPower
        pin "VSS", gnd, kind = ptGround
        port spi, peripheral, pins = {"sclk": "SCK", "mosi": "SI", "miso": "SO"}

  test "a uniform ported interface broken out across three entities collapses to one bus":
    ## Both boxes carry all three signals, so the entity set is uniform and
    ## collapses.
    let nl = brokenOutInterfaceSheet()
    let rep = bundleReport(nl)
    check rep.len == 1
    check rep[0].role == "collapsed"
    check rep[0].entities == @["U1", "U2"]
    check rep[0].port == "spi[3]"                    # interface -> count form
    let s = layout(nl)
    # The three published members fold to one pennant.
    check s.ports.len == 1
    check s.ports[0].name == "spi[3]"
    check s.ports[0].net == rep[0].display
    check s.ports[0].dir == pdBidir     # sclk/mosi in, miso inout -> mixed
    check s.ports[0].members.len == 3
    check s.fallbacks.len == 0          # a real routed bus, no deliberate tags
    var busWires = 0
    for w in s.wires:
      if w.kind == wkInterface:
        check w.net == rep[0].display
        check w.members.len == 3
        inc busWires
    check busWires > 0
    # U1 and U2 each merge their three member pins.
    var merged = 0
    for p in s.parts:
      if p.designator notin ["U1", "U2"]: continue
      for pin in p.pins:
        if pin.name == "spi[3]":
          check pin.members.len == 3
          check pin.net == rep[0].display
          inc merged
    check merged == 2
    # The interface wire, not the net-label chevron.
    let svg = renderSvg(s)
    check "#8250df" in svg
    check "#0f7b6c" notin svg

  test "diagnostics refuses a deliberate net label and skips it in the sweep":
    let s = layout(spiSharedBusSheet())
    # U1's group tag (the bundle is non-uniform, so `brNetLabel`).
    let one = diagnoseFallbackNet(s, "spi1")
    check one.deliberate
    check one.routed
    check one.failPin == -1
    check diagnoseAllFallbacks(s).len == 0

  test "a net-label member name is drawn once per tag, not doubled by the net-name pass":
    let s = layout(spiSharedBusSheet())
    var labelCount = initCountTable[string]()
    for lb in s.labels:
      if lb.role == lrNet: labelCount.inc lb.text
    var fbCount = initCountTable[string]()
    for f in s.fallbacks:
      if f.kind == fbNetLabel: fbCount.inc f.net
    # Four distinct tags, each drawn once.
    for tag in ["spi1", "spi1(cs0)", "spi1(cs1)", "spi1_miso"]:
      check fbCount[tag] == 1
      check labelCount[tag] == 1
    # Names folded into a merged tag are never drawn as free text.
    for name in ["spi1_sclk", "spi1_mosi", "spi1_cs_0", "spi1_cs_1"]:
      check fbCount[name] == 0
      check labelCount[name] == 0

  test "the strict json reader round-trips a collapsed and a net-label scene":
    for s in [layout(spiPeripheralSheet()), layout(twoBoxBundleSheet()),
              layout(brokenOutInterfaceSheet()), layout(spiSharedBusSheet()),
              layout(i2cUnpublishedSheet())]:
      check jsonToScene(sceneToJsonString(s)) == s

  test "a merged slice tag survives diagnostics, the SVG and a round-trip":
    let s = layout(spiSharedBusSheet())
    # U2 owns cs_0, U3 owns cs_1 -> slice tags.
    var sliceTags: seq[string]
    for f in s.fallbacks:
      if f.kind == fbNetLabel and f.net.startsWith("spi1("):
        if f.net notin sliceTags: sliceTags.add f.net
    check sliceTags.sorted == @["spi1(cs0)", "spi1(cs1)"]
    let d = diagnoseFallbackNet(s, "spi1(cs0)")
    check d.deliberate
    check d.routed
    check diagnoseAllFallbacks(s).len == 0     # every tag skipped
    check "spi1(cs0)" in renderSvg(s)

  test "a scene doc with members/kind stripped reads back as scalar and unrouted":
    let s = layout(spiPeripheralSheet())
    var node = parseJson(sceneToJsonString(s))
    for w in node["wires"]:
      if w.hasKey("members"): w.delete("members")
    for p in node["parts"]:
      for pin in p["pins"]:
        if pin.hasKey("members"): pin.delete("members")
    for pt in node["ports"]:
      if pt.hasKey("members"): pt.delete("members")
    for f in node["fallbacks"]:
      if f.hasKey("kind"): f.delete("kind")
      if f.hasKey("bundle"): f.delete("bundle")
    let back = jsonToScene(node)
    for w in back.wires: check w.members.len == 0
    for p in back.parts:
      for pin in p.pins: check pin.members.len == 0
    for pt in back.ports: check pt.members.len == 0
    for f in back.fallbacks: check f.kind == fbUnrouted

  test "runFULL.html makes a merged bundle pin click-to-expand":
    let nl = spiPeripheralSheet()
    let sh = explorerSheet(nl, layout(nl), "SPI_MEMORY")
    let html = renderExplorerHtml(@[sh])
    check "rect.bundle" in html                 # the new CSS class
    check "showPinProps" in html
    check "src=" notin html                     # still self-contained
    # The merged pin's members reach the explorer model.
    var sawMerged = false
    for p in sh.parts:
      for pin in p["pins"]:
        if pin["members"].len == 3 and pin["name"].getStr == "spi[3]":
          sawMerged = true
          check pin.hasKey("x")
          check pin.hasKey("y")
    check sawMerged
    # `const MODEL = ...;` stays one line.
    let ms = html.find("const MODEL = ")
    check html.find(";\n", ms) > ms

# --- repeated-subsheet array collapse ------------------------------------

suite "subsheet arrays":
  proc cellSubckt(): Netlist =
    ## A buffer sheet: power, a series in/out pair, a tap, and an enable.
    nldsl.subckt("CELL", [vdd, sin, sout, tap, en]):
      net vdd, kind = ntPower
      net gnd, kind = ntGround
      net sin, kind = ntSignal
      net sout, kind = ntSignal
      net tap, kind = ntSignal
      net en, kind = ntSignal
      component U1, kind = "buffer":
        pin "V", vdd, kind = ptPower
        pin "G", gnd, kind = ptGround
        pin "A", sin, kind = ptInput
        pin "Y", sout, kind = ptOutput
        pin "T", tap, kind = ptOutput
        pin "E", en, kind = ptInput

  proc chainSheet(): Netlist =
    ## Four CELLs: `vdd` a common rail, `sin`/`sout` a daisy chain, `tap`
    ## distributed, `en` irregular, and `sel` a common signal port (a rail
    ## never gets `pmBusBar`, so `sel` covers it).
    ##
    ## Termination resistors get different values so they don't form a
    ## component array of their own.
    let CELL = nldsl.subckt("CELL", [vdd, sin, sout, tap, en, sel]):
      net vdd, kind = ntPower
      net gnd, kind = ntGround
      net sin, kind = ntSignal
      net sout, kind = ntSignal
      net tap, kind = ntSignal
      net en, kind = ntSignal
      net sel, kind = ntSignal
      component U1, kind = "buffer":
        pin "V", vdd, kind = ptPower
        pin "G", gnd, kind = ptGround
        pin "A", sin, kind = ptInput
        pin "Y", sout, kind = ptOutput
        pin "T", tap, kind = ptOutput
        pin "E", en, kind = ptInput
        pin "S", sel, kind = ptInput
    nldsl.netlist("array_demo"):
      net vdd, kind = ntPower
      net cin, kind = ntSignal
      net l1, kind = ntSignal
      net l2, kind = ntSignal
      net l3, kind = ntSignal
      net cout, kind = ntSignal
      net t1, kind = ntSignal
      net t2, kind = ntSignal
      net t3, kind = ntSignal
      net t4, kind = ntSignal
      net ea, kind = ntSignal
      net eb, kind = ntSignal
      net ec, kind = ntSignal
      net sel, kind = ntSignal
      instance X1, CELL, [vdd, cin, l1, t1, ea, sel]
      instance X2, CELL, [vdd, l1, l2, t2, ea, sel]
      instance X3, CELL, [vdd, l2, l3, t3, eb, sel]
      instance X4, CELL, [vdd, l3, cout, t4, ec, sel]
      component RT1, kind = "resistor", value = "1k":
        pin "1", t1
        pin "2", vdd
      component RT2, kind = "resistor", value = "2k":
        pin "1", t2
        pin "2", vdd
      component RT3, kind = "resistor", value = "3k":
        pin "1", t3
        pin "2", vdd
      component RT4, kind = "resistor", value = "4k":
        pin "1", t4
        pin "2", vdd

  proc twoInstanceSheet(): Netlist =
    let CELL = cellSubckt()
    nldsl.netlist("two_demo"):
      net vdd, kind = ntPower
      net a, kind = ntSignal
      net b, kind = ntSignal
      net c, kind = ntSignal
      net t1, kind = ntSignal
      net t2, kind = ntSignal
      net e, kind = ntSignal
      instance X1, CELL, [vdd, a, b, t1, e]
      instance X2, CELL, [vdd, b, c, t2, e]

  proc subGroupSheet(): Netlist =
    ## Six CELLs whose `en` splits them into two groups of three.
    let CELL = cellSubckt()
    nldsl.netlist("subgroup_demo"):
      net vdd, kind = ntPower
      net s1, kind = ntSignal
      net s2, kind = ntSignal
      net s3, kind = ntSignal
      net s4, kind = ntSignal
      net s5, kind = ntSignal
      net s6, kind = ntSignal
      net s7, kind = ntSignal
      net ta, kind = ntSignal
      net tb, kind = ntSignal
      net tc, kind = ntSignal
      net td, kind = ntSignal
      net te, kind = ntSignal
      net tf, kind = ntSignal
      net ga, kind = ntSignal
      net gb, kind = ntSignal
      instance X1, CELL, [vdd, s1, s2, ta, ga]
      instance X2, CELL, [vdd, s2, s3, tb, ga]
      instance X3, CELL, [vdd, s3, s4, tc, ga]
      instance X4, CELL, [vdd, s4, s5, td, gb]
      instance X5, CELL, [vdd, s5, s6, te, gb]
      instance X6, CELL, [vdd, s6, s7, tf, gb]

  proc disagreeSheet(): Netlist =
    ## Two splitting ports whose partitions don't align: nothing collapses.
    let CELL = cellSubckt()
    nldsl.netlist("disagree_demo"):
      net vdd, kind = ntPower
      net s1, kind = ntSignal
      net s2, kind = ntSignal
      net s3, kind = ntSignal
      net s4, kind = ntSignal
      net s5, kind = ntSignal
      net p1, kind = ntSignal
      net p2, kind = ntSignal
      net q1, kind = ntSignal
      net q2, kind = ntSignal
      # tap pairs {1,2}/{3,4}; en pairs {1,3}/{2,4}
      instance X1, CELL, [vdd, s1, s2, p1, q1]
      instance X2, CELL, [vdd, s2, s3, p1, q2]
      instance X3, CELL, [vdd, s3, s4, p2, q1]
      instance X4, CELL, [vdd, s4, s5, p2, q2]

  test "arrayReport classifies each port of a collapsed array":
    let rep = arrayReport(chainSheet())
    check rep.len == 1
    check rep[0].source == "CELL"
    check rep[0].origin == "subsheet"
    check rep[0].label == "X1..X4"
    check rep[0].rep == "X1"
    check rep[0].count == 4
    check rep[0].members == @["X1", "X2", "X3", "X4"]
    check rep[0].ports == @["vdd=common", "sin=chained(in)",
      "sout=chained(out,x3)", "tap=distributed[1:4]", "en=irregular(3*4)",
      "sel=common"]

  test "two instances of a subsheet do not collapse":
    check arrayReport(twoInstanceSheet()).len == 0

  test "a splitting port sub-groups an array into collapsible halves":
    let rep = arrayReport(subGroupSheet())
    check rep.len == 2
    check rep[0].count == 3
    check rep[1].count == 3
    check rep[0].members == @["X1", "X2", "X3"]
    check rep[1].members == @["X4", "X5", "X6"]

  test "misaligned splitting ports collapse nothing":
    check arrayReport(disagreeSheet()).len == 0

  test "a netlist with no repeated subsheet reports no arrays":
    check arrayReport(divider()).len == 0
    check arrayReport(plainDivider()).len == 0

  proc busCellSubckt(): Netlist =
    nldsl.subckt("BCELL", [vdd, io]):
      net vdd, kind = ntPower
      net gnd, kind = ntGround
      bus io, width = 2
      component U1, kind = "buffer":
        pin "V", vdd, kind = ptPower
        pin "G", gnd, kind = ptGround
        pin "A", io[0], kind = ptInput
        pin "B", io[1], kind = ptOutput

  test "a member carrying a collapsed bundle vetoes the array":
    ## Each BCELL shares a private bus with one widget box, so each bus
    ## collapses and the array is declined.
    let BCELL = busCellSubckt()
    let nl = nldsl.netlist("collapsed_array"):
      net vdd, kind = ntPower
      bus a, width = 2
      bus b, width = 2
      bus c, width = 2
      instance X1, BCELL, [vdd, a]
      instance X2, BCELL, [vdd, b]
      instance X3, BCELL, [vdd, c]
      component W1, kind = "widget":
        pin "1", a[0]
        pin "2", a[1]
      component W2, kind = "widget":
        pin "1", b[0]
        pin "2", b[1]
      component W3, kind = "widget":
        pin "1", c[0]
        pin "2", c[1]
    check bundleReport(nl).len == 3            # three collapsed buses
    check arrayReport(nl).len == 0             # ... so the array declines

  test "a brNetLabel bundle does not veto the array":
    # One bus across four entities -> brNetLabel, so the array still
    # collapses; the io port reads bundled.
    let BCELL = busCellSubckt()
    let nl = nldsl.netlist("netlabel_array"):
      net vdd, kind = ntPower
      bus shared, width = 2
      component U9, kind = "mcu":
        pin "A", shared[0], kind = ptOutput
        pin "B", shared[1], kind = ptInput
      instance X1, BCELL, [vdd, shared]
      instance X2, BCELL, [vdd, shared]
      instance X3, BCELL, [vdd, shared]
    let rep = arrayReport(nl)
    check rep.len == 1
    check rep[0].count == 3
    check "io_0=common(bundled)" in rep[0].ports
    check "io_1=common(bundled)" in rep[0].ports

  test "the scene JSON round-trips wkChain, PinMark, count and members":
    var s = Schematic(title: "t", minX: 0, minY: 0, maxX: 10, maxY: 10)
    s.parts.add SchematicPart(designator: "X1", label: "X1..X4", kind: "sub",
      symbol: "box", isBox: true, bodyW: 40, bodyH: 40, count: 4,
      members: @["X1", "X2", "X3", "X4"],
      pins: @[SchematicPin(name: "vdd", x: 0, y: 0, net: "vdd", mark: pmBusBar),
              SchematicPin(name: "tap", x: 0, y: 10, net: "tap_arr",
                mark: pmBusSlash, tag: "tap[1:4]",
                members: @[BundleMember(name: "X1", net: "t1")])])
    s.wires.add SchematicWire(net: "sout_chain", kind: wkChain,
      members: @["l1", "l2", "l3"],
      points: @[Point(x: 0, y: 0), Point(x: 5, y: 0)])
    let back = jsonToScene(sceneToJsonString(s))
    check back.parts[0].count == 4
    check back.parts[0].members == @["X1", "X2", "X3", "X4"]
    check back.parts[0].pins[0].mark == pmBusBar
    check back.parts[0].pins[1].mark == pmBusSlash
    check back.parts[0].pins[1].tag == "tap[1:4]"
    check back.wires[0].kind == wkChain
    check back.wires[0].members == @["l1", "l2", "l3"]
    check sceneToJsonString(back) == sceneToJsonString(s)

  test "an array-free scene's JSON carries none of the new keys":
    let node = sceneToJson(layout(divider()))
    for p in node["parts"]:
      check not p.hasKey("count")
      for pin in p["pins"]:
        check not pin.hasKey("mark")
        check not pin.hasKey("tag")
  test "the collapsed scene has one box per array with the arc and bus wires":
    let s = layout(chainSheet())
    var rep: SchematicPart
    var haveRep = false
    for p in s.parts:
      if p.designator == "X1": rep = p; haveRep = true
      check p.designator notin ["X2", "X3", "X4"]   # hidden members not drawn
    check haveRep
    check rep.count == 4
    check rep.label == "X1..X4"
    check rep.members == @["X1", "X2", "X3", "X4"]
    check rep.isBox
    # one wkChain wire carrying the link nets
    var chainWires = 0
    for w in s.wires:
      if w.kind == wkChain:
        inc chainWires
        check w.members == @["l1", "l2", "l3"]
    check chainWires == 1
    # one wkBus wire for `tap`
    var busWires = 0
    for w in s.wires:
      if w.kind == wkBus and w.members.len == 4: inc busWires
    check busWires >= 1
    # the marks landed
    var marks: HashSet[PinMark]
    for p in s.parts:
      for pin in p.pins: marks.incl pin.mark
    check pmBusBar in marks      # sel (rail-bound common ports never get it)
    check pmBusSlash in marks    # tap
    check pmForkCap in marks     # en

  test "lsArrays off restores the pre-feature scene byte for byte":
    let nl = chainSheet()
    var opts = defaultLayoutOptions()
    opts.stages.excl lsArrays
    let off = layout(nl, opts)
    check off.parts.len == nl.components.len       # every instance drawn
    for w in off.wires: check w.kind != wkChain
    for p in off.parts:
      check p.count == 0
      for pin in p.pins: check pin.mark == pmNone
    # an array-free netlist is identical with the stage on or off
    let d = divider()
    check sceneToJsonString(layout(d, opts)) == sceneToJsonString(layout(d))

  test "the collapsed scene keeps the three router invariants":
    for nl in [chainSheet(), subGroupSheet()]:
      let s = layout(nl)
      check distinctWiresNeverShareCollinearRuns(s)
      check differentNetsRespectSeparation(s)
      check signalWiresRespectForeignSeeds(s)

  test "a published distributed member net still gets one merged pennant":
    let CELL = cellSubckt()
    let nl = nldsl.subckt("BOARD", [o1, o2, o3, o4]):
      net vdd, kind = ntPower
      net cin, kind = ntSignal
      net l1, kind = ntSignal
      net l2, kind = ntSignal
      net l3, kind = ntSignal
      net cout, kind = ntSignal
      net e, kind = ntSignal
      net o1, kind = ntSignal
      net o2, kind = ntSignal
      net o3, kind = ntSignal
      net o4, kind = ntSignal
      instance X1, CELL, [vdd, cin, l1, o1, e]
      instance X2, CELL, [vdd, l1, l2, o2, e]
      instance X3, CELL, [vdd, l2, l3, o3, e]
      instance X4, CELL, [vdd, l3, cout, o4, e]
    let s = layout(nl)
    var slashPorts = 0
    for pt in s.ports:
      if pt.members.len == 4: inc slashPorts
    check slashPorts == 1                       # exactly one, never zero
  test "a pass-through strap keeps both port names, oriented by suffix":
    # An internal net published twice as `clk_in`/`clk_out`: the suffix
    # orients them, and both keep their port names.
    let sd = nldsl.subckt("STRAP_DEV", [vin, vout]):
      net clk, kind = ntSignal
      net vin, kind = ntSignal
      net vout, kind = ntSignal
      component U1, kind = "buffer":
        pin "CLK", clk, kind = ptInput
        pin "A", vin, kind = ptInput
        pin "Y", vout, kind = ptOutput
    addPort(sd, "clk_in", sd.nets["clk"])
    addPort(sd, "clk_out", sd.nets["clk"])
    let s = layout(sd)
    var byName: Table[string, SchematicPort]
    for pt in s.ports: byName[pt.name] = pt
    check "clk_in" in byName and "clk_out" in byName
    check byName["clk_in"].dir == pdInput
    check byName["clk_out"].dir == pdOutput
    # an unroutable published net degrades to a by-name label, not a marker
    for fb in s.fallbacks:
      if fb.net in ["clk", "vin", "vout"]: check fb.kind == fbNetLabel

  test "the collapsed scene SVG carries the array glyphs":
    let svg = renderSvg(layout(chainSheet()))
    check ">X1..X4</text>" in svg           # the box label
    check ">x4</text>" in svg                # the count badge
    check "#6e7781" in svg                   # the chain arc stroke
    check "stroke=\"#1f6feb\" stroke-width=\"4\"" in svg   # the bus-bar tick

  test "an irregular pin with an open member draws the amber dashed prong":
    let CELL = cellSubckt()
    let nl = nldsl.netlist("open_demo"):
      net vdd, kind = ntPower
      net a, kind = ntSignal
      net b, kind = ntSignal
      net c, kind = ntSignal
      net d, kind = ntSignal
      net t1, kind = ntSignal
      net t2, kind = ntSignal
      net t3, kind = ntSignal
      net t4, kind = ntSignal
      net e1, kind = ntSignal
      net e2, kind = ntSignal
      net e3, kind = ntSignal
      # `en` gets three distinct nets and one nil -> irregular, open
      instance X1, CELL, [vdd, a, b, t1, e1]
      instance X2, CELL, [vdd, b, c, t2, e2]
      instance X3, CELL, [vdd, c, d, t3, e3]
      instance X4, CELL, {"vdd": vdd, "sin": d, "sout": a, "tap": t4, "en": open}
    let svg = renderSvg(layout(nl))
    check "stroke-dasharray=\"4 3\"" in svg
  test "the explorer makes a collapsed array box click-to-expand":
    let nl = chainSheet()
    let s = layout(nl)
    let sh = explorerSheet(nl, s, "@root")
    let html = renderExplorerHtml(@[sh])
    check "src=" notin html
    let ms = html.find("const MODEL = ")
    check html.find(";\n", ms) > ms
    # the representative carries its instance list and count
    var sawRep = false
    for p in sh.parts:
      if p["designator"].getStr == "X1":
        sawRep = true
        check p["count"].getInt == 4
        check p["arrayMembers"].len == 4
        check p["arrayMembers"][0]["designator"].getStr == "X1"
    check sawRep
    check "arrayMembers" in html

# --- repeated-component array collapse ------------------------------------

suite "component arrays":
  proc terminationBank(n: int): Netlist =
    ## `n` identical 50-ohm terminations: per-channel nets on "1", shared
    ## ground on "2".
    result = newNetlist("termination_bank")
    let gnd = addNet(result, newNet("0", ntGround))
    for i in 1 .. n:
      let ch = addNet(result, newNet("ch" & $i))
      let r = addComponent(result, newComponent("RT" & $i, kind = "resistor"))
      r.attrs["value"] = "50"
      discard connect(r, "1", ch, ptPassive)
      discard connect(r, "2", gnd, ptPassive)

  test "classification: an 8x termination bank reports as one component array":
    let rep = arrayReport(terminationBank(8))
    check rep.len == 1
    check rep[0].origin == "component"
    check rep[0].source == "resistor"
    check rep[0].count == 8
    check rep[0].ports == @["1=distributed[1:8]", "2=common"]

  test "the N<3 floor and zero-value inertness":
    # N < 3 never collapses.
    let nl2 = newNetlist("two_only")
    let gnd2 = addNet(nl2, newNet("0", ntGround))
    for i in 1 .. 2:
      let n = addNet(nl2, newNet("t" & $i))
      let r = addComponent(nl2, newComponent("R" & $i, kind = "resistor"))
      r.attrs["value"] = "1k"
      discard connect(r, "1", n, ptPassive)
      discard connect(r, "2", gnd2, ptPassive)
    check arrayReport(nl2).len == 0
    let s2 = layout(nl2)
    check s2.parts.len == 2
    for p in s2.parts: check p.count == 0

    # An array-free scene is identical with `lsPartArrays` on or off.
    var opts = defaultLayoutOptions()
    opts.stages.excl lsPartArrays
    let d = divider()
    check sceneToJsonString(layout(d, opts)) == sceneToJsonString(layout(d))

  test "lsPartArrays off restores the pre-feature scene byte for byte":
    let nl = terminationBank(8)
    var opts = defaultLayoutOptions()
    opts.stages.excl lsPartArrays          # lsArrays (irrelevant here) stays on
    let off = layout(nl, opts)
    check off.parts.len == nl.components.len     # every termination drawn
    for p in off.parts:
      check p.count == 0
      for pin in p.pins: check pin.mark == pmNone

  proc railBank(n: int): Netlist =
    ## `n` decoupling caps across one rail pair: a genuine rail/ground bank
    ## collapses to one badged symbol.
    result = newNetlist("rail_bank")
    let vdd = addNet(result, newNet("VDD", ntPower))
    let gnd = addNet(result, newNet("0", ntGround))
    let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
    discard connect(v1, "+", vdd, ptPower)
    discard connect(v1, "-", gnd, ptGround)
    for i in 1 .. n:
      let c = addComponent(result, newComponent("C" & $i, kind = "capacitor"))
      c.attrs["value"] = "100n"
      discard connect(c, "1", vdd, ptPassive)
      discard connect(c, "2", gnd, ptPassive)

  proc signalBank(n: int): Netlist =
    ## `n` resistors in parallel across a signal net pair: declined, since
    ## `parallelStackKind` already draws a visible stack.
    result = newNetlist("signal_bank")
    let a = addNet(result, newNet("a"))
    let b = addNet(result, newNet("b"))
    for i in 1 .. n:
      let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
      r.attrs["value"] = "1k"
      discard connect(r, "1", a, ptPassive)
      discard connect(r, "2", b, ptPassive)

  test "a rail/ground bank collapses to one badged symbol, even at two members":
    for n in [2, 8]:
      let nl = railBank(n)
      let rep = arrayReport(nl)
      check rep.len == 1
      check rep[0].origin == "component"
      check rep[0].source == "capacitor"
      check rep[0].count == n
      check rep[0].ports == @["1=common", "2=common"]
      let s = layout(nl)
      check s.parts.len == 2             # V1 + one collapsed "C1..Cn" symbol
      let c1 = partOf(s, "C1")
      check c1.count == n
      check c1.members == (block:
        var m: seq[string]
        for i in 1 .. n: m.add "C" & $i
        m)

  test "the all-common decline still keeps a signal-net bank a visible stack, not xN":
    let nl = signalBank(8)
    check arrayReport(nl).len == 0     # both ports apCommon, neither a rail
    let s = layout(nl)
    check s.parts.len == 8             # all eight visible, none hidden
    for p in s.parts: check p.count == 0
    # still one `parallelStackKind` composite: one shared coordinate, evenly
    # spaced on the other axis.
    var xs, ys: HashSet[float]
    for i in 1 .. 8:
      xs.incl partOf(s, "R" & $i).x
      ys.incl partOf(s, "R" & $i).y
    check xs.len == 1 or ys.len == 1

  proc diffLegBank(): Netlist =
    ## Two resistors, each with a private-net pin and a pin on a declared
    ## two-member bus that a third box `S` merges. The declared-pair floor
    ## collapses this at two members.
    result = newNetlist("diff_leg_bank")
    let a = addNet(result, newNet("a"))
    let b = addNet(result, newNet("b"))
    let p = addNet(result, newNet("p"))
    let n = addNet(result, newNet("n"))
    p.attrs["bus.name"] = "pair"
    n.attrs["bus.name"] = "pair"
    let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
    r1.attrs["value"] = "22"
    discard connect(r1, "1", a, ptPassive)
    discard connect(r1, "2", p, ptPassive)
    let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
    r2.attrs["value"] = "22"
    discard connect(r2, "1", b, ptPassive)
    discard connect(r2, "2", n, ptPassive)
    let s = addComponent(result, newComponent("S", kind = "ic"))
    discard connect(s, "P", p, ptInOut)
    discard connect(s, "N", n, ptInOut)

  test "a declared-pair port collapses two members with no rail/ground bank":
    let nl = diffLegBank()
    let rep = arrayReport(nl)
    check rep.len == 1
    check rep[0].origin == "component"
    check rep[0].source == "resistor"
    check rep[0].count == 2
    check rep[0].ports == @["1=distributed[1:2]", "2=distributed[1:2](bundled)"]
    let s = layout(nl)
    check s.parts.len == 2               # S + one collapsed "R1..R2" symbol
    let r1 = partOf(s, "R1")
    check r1.count == 2
    check r1.members == @["R1", "R2"]

  proc filterBank(n: int): Netlist =
    ## `n` RC low-pass channels: every `mid_i` sits on the R array's "2" and
    ## the C array's "1" (both ends distributed).
    result = newNetlist("filter_bank")
    discard addNet(result, newNet("0", ntGround))
    for i in 1 .. n:
      let inNet = addNet(result, newNet("in" & $i))
      let mid = addNet(result, newNet("mid" & $i))
      let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
      r.attrs["value"] = "1k"
      discard connect(r, "1", inNet, ptPassive)
      discard connect(r, "2", mid, ptPassive)
      let c = addComponent(result, newComponent("C" & $i, kind = "capacitor"))
      c.attrs["value"] = "100n"
      discard connect(c, "1", mid, ptPassive)
      discard connect(c, "2", result.nets["0"], ptPassive)

  test "both-ends-distributed: an 8x(R+C) filter bank suppresses a consistent subset":
    let nl = filterBank(8)
    let rep = arrayReport(nl)
    check rep.len == 2
    for r in rep:
      check r.origin == "component"
      check r.count == 8
    let s = layout(nl)
    var drawn: seq[string]
    for p in s.parts: drawn.add p.designator
    check drawn.len == 2                 # only the two representatives
    check "R1" in drawn
    check "C1" in drawn                  # R1.2 == C1.1 == mid1, nl.nets-first
    var busWires = 0
    for w in s.wires:
      if w.kind == wkBus and w.members.len == 8: inc busWires
    check busWires == 1                  # one bus, not zero, not two partial ones
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)
    check signalWiresRespectForeignSeeds(s)
    check labelsClearOfGeometry(s)

  proc splitByValueBank(): Netlist =
    ## Four 10k and four 2k resistors: `value` keeps them separate groups.
    result = newNetlist("split_by_value")
    let gnd = addNet(result, newNet("0", ntGround))
    for i in 1 .. 4:
      let n = addNet(result, newNet("a" & $i))
      let r = addComponent(result, newComponent("RA" & $i, kind = "resistor"))
      r.attrs["value"] = "10k"
      discard connect(r, "1", n, ptPassive)
      discard connect(r, "2", gnd, ptPassive)
    for i in 1 .. 4:
      let n = addNet(result, newNet("b" & $i))
      let r = addComponent(result, newComponent("RB" & $i, kind = "resistor"))
      r.attrs["value"] = "2k"
      discard connect(r, "1", n, ptPassive)
      discard connect(r, "2", gnd, ptPassive)

  test "value splits the group: four 10k and four 2k resistors give two arrays":
    let rep = arrayReport(splitByValueBank())
    check rep.len == 2
    var counts: seq[int]
    for r in rep: counts.add r.count
    counts.sort()
    check counts == @[4, 4]

  proc packagedTriple(): Netlist =
    ## Three sections of one package: `isPackaged` excludes them, or their
    ## own labels would fight the array label.
    let tri = newPackageDef("SCH_TRIPLE", [
      (id: "1", section: "A", logical: "OUT"),
      (id: "2", section: "B", logical: "OUT"),
      (id: "3", section: "C", logical: "OUT")], partNumber = "SCH_TRIPLE")
    try: registerPackage(tri)
    except CatchableError: discard
    let u9 = packageInstance("SCH_TRIPLE", "U9")
    result = nldsl.netlist("packaged_triple"):
      net gnd, kind = ntGround, name = "0"
      net a, kind = ntSignal
      net b, kind = ntSignal
      net c, kind = ntSignal
      component IC1, kind = "opamp", value = "TL074":
        pin "OUT", a
        pin "IN", gnd
      component IC2, kind = "opamp", value = "TL074":
        pin "OUT", b
        pin "IN", gnd
      component IC3, kind = "opamp", value = "TL074":
        pin "OUT", c
        pin "IN", gnd
    u9.assign(result, "A", "IC1")
    u9.assign(result, "B", "IC2")
    u9.assign(result, "C", "IC3")

  test "isPackaged exclusion: three sections of one package keep their own labels":
    let nl = packagedTriple()
    check arrayReport(nl).len == 0
    let s = layout(nl)
    var byDesig: Table[string, SchematicPart]
    for p in s.parts: byDesig[p.designator] = p
    check byDesig["IC1"].label == "U9A"
    check byDesig["IC2"].label == "U9B"
    check byDesig["IC3"].label == "U9C"

  proc resistorLadder(n: int): Netlist =
    ## `n` resistors in series: a resistor has no box interior for a chain
    ## arc, so it degrades to distributed.
    result = newNetlist("resistor_ladder")
    var prev = addNet(result, newNet("n0"))
    for i in 1 .. n:
      let net = addNet(result, newNet("n" & $i))
      let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
      r.attrs["value"] = "1k"
      discard connect(r, "1", prev, ptPassive)
      discard connect(r, "2", net, ptPassive)
      prev = net

  test "chain pairing is skipped for a non-box representative: a ladder degrades to distributed":
    let nl = resistorLadder(4)
    let rep = arrayReport(nl)
    check rep.len == 1
    check rep[0].origin == "component"
    for p in rep[0].ports:
      check "chained" notin p
      check "distributed" in p
    let s = layout(nl)
    for w in s.wires: check w.kind != wkChain

  test "the collapsed-symbol invariants and labels hold on every new fixture":
    for nl in [terminationBank(8), filterBank(8), splitByValueBank(),
               resistorLadder(4), railBank(8)]:
      let s = layout(nl)
      check distinctWiresNeverShareCollinearRuns(s)
      check differentNetsRespectSeparation(s)
      check signalWiresRespectForeignSeeds(s)
      check labelsClearOfGeometry(s)

  test "a collapsed symbol scene round-trips through JSON and the SVG carries its glyphs":
    let nl = terminationBank(8)
    let s = layout(nl)
    let back = jsonToScene(sceneToJsonString(s))
    check sceneToJsonString(back) == sceneToJsonString(s)
    var rep: SchematicPart
    var have = false
    for p in back.parts:
      if p.count >= 2: rep = p; have = true
    check have
    check rep.count == 8
    check not rep.isBox
    let svgText = renderSvg(s)
    check ">x8</text>" in svgText                                # the badge
    check "stroke=\"#1f6feb\" stroke-width=\"3\"" in svgText     # the slash

  proc bundledTerminationBank(): Netlist =
    ## Three resistors on their own nets plus a reading MCU: a `brNetLabel`
    ## bundle, which doesn't veto the array (only `brCollapsed` does).
    result = newNetlist("bundled_bank")
    let gnd = addNet(result, newNet("0", ntGround))
    let u1 = addComponent(result, newComponent("U1", kind = "mcu"))
    for i in 1 .. 3:
      let a = addNet(result, newNet("a" & $i))
      a.attrs["bus.name"] = "grp"
      a.attrs["bus.index"] = $(i - 1)
      a.attrs["bus.width"] = "3"
      discard connect(u1, "P" & $i, a, ptInput)
      let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
      r.attrs["value"] = "1k"
      discard connect(r, "1", a, ptPassive)
      discard connect(r, "2", gnd, ptPassive)

  test "a brNetLabel bundle does not veto a component array; that port reads bundled":
    let nl = bundledTerminationBank()
    check bundleReport(nl).len == 1
    let rep = arrayReport(nl)
    check rep.len == 1
    check rep[0].origin == "component"
    check rep[0].count == 3
    check "1=distributed[1:3](bundled)" in rep[0].ports

  test "a bundled distributed array pin draws the bus name, not one member's net":
    # `U1` merges all three bus members onto one pin, so this is a mixed
    # bundle. The array defers to the bundle's drawing wholesale and
    # suppresses its own mark, but the representative's raw binding ("a1")
    # must not leak: once collapsed its identity is the bus.
    let nl = bundledTerminationBank()
    let s = layout(nl)
    let rep = partOf(s, "R1")
    var found = false
    for pin in rep.pins:
      if pin.name == "1":
        found = true
        check pin.net == "grp"
        check pin.mark == pmNone           # bundle wins the mark too
    check found
    # The representative's one remaining tag reads the bus name, not "a1".
    var sawFallback = false
    for f in s.fallbacks:
      if f.part == "R1" and f.pin == "1":
        sawFallback = true
        check f.net == "grp"
    check sawFallback

  proc twoBusBank(): Netlist =
    ## Eight resistors on their own nets, four in `bus fam1` and four in
    ## `bus fam2`: the members share no net, but declared bus membership
    ## splits them into two families. Each half is also a `brNetLabel`
    ## bundle.
    result = newNetlist("two_bus_bank")
    let gnd = addNet(result, newNet("0", ntGround))
    for i in 1 .. 8:
      let busName = if i <= 4: "fam1" else: "fam2"
      let idx = if i <= 4: i - 1 else: i - 5
      let n = addNet(result, newNet("m" & $i))
      n.attrs["bus.name"] = busName
      n.attrs["bus.index"] = $idx
      n.attrs["bus.width"] = "4"
      let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
      r.attrs["value"] = "50"
      discard connect(r, "1", n, ptPassive)
      discard connect(r, "2", gnd, ptPassive)

  test "a distributed port with no shared net still splits by declared bus family":
    let rep = arrayReport(twoBusBank())
    check rep.len == 2
    var counts: seq[int]
    for a in rep:
      counts.add a.count
      check a.origin == "component"
      check "1=distributed[1:4](bundled)" in a.ports
    counts.sort()
    check counts == @[4, 4]

  proc twoSidedDistributedBusBank(): Netlist =
    ## Channel `i` wired `Ji.RF -- b[i] -- Ui.IN`: the bus is non-uniform
    ## (`brNetLabel`), but each end is a 4-member component array, so one
    ## real bus wire joins the two boxes.
    result = newNetlist("two_sided_bus")
    let gnd = addNet(result, newNet("0", ntGround))
    for i in 1 .. 4:
      let n = addNet(result, newNet("b" & $i))
      n.attrs["bus.name"] = "b"
      n.attrs["bus.index"] = $(i - 1)
      n.attrs["bus.width"] = "4"
      let j = addComponent(result, newComponent("J" & $i, kind = "connector",
                                                partNumber = "CONN"))
      discard connect(j, "RF", n, ptPassive)
      discard connect(j, "GND", gnd, ptGround)
      let u = addComponent(result, newComponent("U" & $i, kind = "switch",
                                                partNumber = "SW"))
      discard connect(u, "IN", n, ptPassive)
      discard connect(u, "GND", gnd, ptGround)

  test "a bus distributed across two separate arrays routes as one bus between them":
    let nl = twoSidedDistributedBusBank()
    let rep = bundleReport(nl)
    check rep.len == 1
    check rep[0].role == "netlabel"       # 8 entities, non-uniform
    let arr = arrayReport(nl)
    check arr.len == 2
    for a in arr:
      check a.count == 4
      check "RF=distributed[1:4](bundled)" in a.ports or
            "IN=distributed[1:4](bundled)" in a.ports
    let s = layout(nl)
    check s.fallbacks.len == 0
    var busWires = 0
    for w in s.wires:
      if w.kind == wkBus and w.net == rep[0].display:
        check w.members.len == 4
        inc busWires
    check busWires > 0
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)
    check signalWiresRespectForeignSeeds(s)

  proc collapsedBundleVetoBank(): Netlist =
    ## Three gadgets, each with a private bus to its own widget
    ## (`brCollapsed`): the one decline the array respects.
    result = newNetlist("veto_bank")
    let gnd = addNet(result, newNet("0", ntGround))
    for i in 1 .. 3:
      let sel = addNet(result, newNet("s" & $i))
      let g = addComponent(result, newComponent("G" & $i, kind = "gadget"))
      g.attrs["value"] = "v1"
      discard connect(g, "sel", sel, ptInput)
      discard connect(g, "gnd", gnd, ptGround)
      let b0 = addNet(result, newNet("g" & $i & "_b0"))
      let b1 = addNet(result, newNet("g" & $i & "_b1"))
      b0.attrs["bus.name"] = "priv" & $i
      b0.attrs["bus.index"] = "0"
      b0.attrs["bus.width"] = "2"
      b1.attrs["bus.name"] = "priv" & $i
      b1.attrs["bus.index"] = "1"
      b1.attrs["bus.width"] = "2"
      discard connect(g, "b0", b0, ptPassive)
      discard connect(g, "b1", b1, ptPassive)
      let w = addComponent(result, newComponent("W" & $i, kind = "widget"))
      discard connect(w, "0", b0, ptPassive)
      discard connect(w, "1", b1, ptPassive)

  test "a brCollapsed bundle declines the component array":
    let nl = collapsedBundleVetoBank()
    check bundleReport(nl).len == 3      # three private point-to-point buses
    check arrayReport(nl).len == 0       # ... so the component array declines

  proc survivingCollapsedBundleBank(): Netlist =
    ## Five gadgets on one uniform `brCollapsed` bus. G1..G3 share a
    ## signature; G4/G5 don't. Hiding G2/G3 leaves three entities on the
    ## bundle, so the array still collapses (`survivesCollapsedBundles`).
    result = newNetlist("surviving_bank")
    let gnd = addNet(result, newNet("0", ntGround))
    let b0 = addNet(result, newNet("b0"))
    let b1 = addNet(result, newNet("b1"))
    b0.attrs["bus.name"] = "shared"
    b0.attrs["bus.index"] = "0"
    b0.attrs["bus.width"] = "2"
    b1.attrs["bus.name"] = "shared"
    b1.attrs["bus.index"] = "1"
    b1.attrs["bus.width"] = "2"
    for i in 1 .. 5:
      let value = if i <= 3: "v1" else: "v2"
      let g = addComponent(result, newComponent("G" & $i, kind = "gadget"))
      g.attrs["value"] = value
      let sel = addNet(result, newNet("s" & $i))
      discard connect(g, "sel", sel, ptInput)
      discard connect(g, "gnd", gnd, ptGround)
      discard connect(g, "b0", b0, ptPassive)
      discard connect(g, "b1", b1, ptPassive)

  test "a brCollapsed bundle with enough surviving entities does not veto the array":
    let nl = survivingCollapsedBundleBank()
    let rep = bundleReport(nl)
    check rep.len == 1
    check rep[0].role == "collapsed"
    check rep[0].entities == @["G1", "G2", "G3", "G4", "G5"]
    let arr = arrayReport(nl)
    check arr.len == 1
    check arr[0].count == 3
    check arr[0].rep == "G1"

import verax/netlist/traversal

proc wouldBePi(thirdPin, declareSpec: bool): Netlist =
  ## `piFilter`'s shape, except `L1` may have a third pin and may declare a
  ## `traverse:` edge. `piRecognize` checks `isTwoTerminal`, not
  ## `isTraversable`: a third pin declines the pi whatever `L1` declares, and
  ## a bare declaration on a 2-pin part changes nothing.
  result = newNetlist("would_be_pi")
  let src = addNet(result, newNet("src"))
  let fin = addNet(result, newNet("fin"))
  let mid = addNet(result, newNet("mid"))
  let fout = addNet(result, newNet("fout"))
  let gnd = addNet(result, newNet("0", ntGround))
  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", src); discard connect(v1, "-", gnd)
  let rs = addComponent(result, newComponent("RS", kind = "resistor"))
  discard connect(rs, "1", src, ptPassive); discard connect(rs, "2", fin, ptPassive)
  let l1 = addComponent(result, newComponent("L1", kind = "rf_switch"))
  discard connect(l1, "1", fin, ptPassive)
  discard connect(l1, "2", mid, ptPassive)
  if thirdPin:
    let extra = addNet(result, newNet("extra"))
    discard connect(l1, "3", extra, ptPassive)
  if declareSpec:
    addTraversalEdge(l1, "1", "2")
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", fin, ptPassive); discard connect(c1, "2", gnd, ptPassive)
  let c2 = addComponent(result, newComponent("C2", kind = "capacitor"))
  discard connect(c2, "1", mid, ptPassive); discard connect(c2, "2", gnd, ptPassive)
  let rl = addComponent(result, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", mid, ptPassive); discard connect(rl, "2", fout, ptPassive)
  let rt = addComponent(result, newComponent("RT", kind = "resistor"))
  discard connect(rt, "1", fout, ptPassive); discard connect(rt, "2", gnd, ptPassive)

proc pinLocked(s: Schematic): bool =
  ## `piInternalLayout`'s canonical signature (series horizontal, each shunt
  ## `2 * grid` below and `grid` to either side), which force placement
  ## never produces by chance.
  let l1 = partOf(s, "L1")
  let c1 = partOf(s, "C1")
  let c2 = partOf(s, "C2")
  abs(l1.pins[0].y - l1.pins[1].y) < 1e-6 and
    c1.rotation in [90.0, 270.0] and c2.rotation in [90.0, 270.0] and
    c1.y == c2.y and c1.y > l1.y and
    abs((c1.x - l1.x) + (c2.x - l1.x)) < 1e-6 and
    abs(abs(c1.x - l1.x) - abs(c2.x - l1.x)) < 1e-6 and
    abs(c1.x - l1.x) > 1e-6

suite "traverse: block and the schematic's widened isTraversable":
  test "the sheet is unchanged when nothing declares a traverse: spec":
    # Baseline: an ordinary 2-pin `L1` still forms the pi.
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    let s = layout(wouldBePi(thirdPin = false, declareSpec = false), options)
    check pinLocked(s)
    check s.fallbacks.len == 0
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)

  test "an ordinary 2-pin part declaring its own conduction still forms the pi":
    # A `traverse:` declaration restating two-terminal changes nothing.
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    let s = layout(wouldBePi(thirdPin = false, declareSpec = true), options)
    check pinLocked(s)

  test "a declared multi-exit part is still declined by the pi recognizer":
    # An 8-pin RF switch declaring its own conduction is never taken by a
    # two-terminal composite recognizer.
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    let s = layout(wouldBePi(thirdPin = true, declareSpec = true), options)
    check partOf(s, "L1").pins.len == 3
    check not pinLocked(s)
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)

  test "the same undeclared multi-pin part is declined too, as it always was":
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    let s = layout(wouldBePi(thirdPin = true, declareSpec = false), options)
    check not pinLocked(s)

suite "traversal-driven box pin sides":
  proc adg904Shape(declareSpec: bool): Netlist =
    ## An ADG904-like pin table: `RFC`/`RF1..4` passive, `A0`/`A1`/`EN`
    ## inputs, `VDD`/`GND`. No symbol -> a fallback box.
    result = newNetlist("adg904_shape")
    let rfc = addNet(result, newNet("rfc"))
    let rf1 = addNet(result, newNet("rf1"))
    let rf2 = addNet(result, newNet("rf2"))
    let rf3 = addNet(result, newNet("rf3"))
    let rf4 = addNet(result, newNet("rf4"))
    let a0 = addNet(result, newNet("a0"))
    let a1 = addNet(result, newNet("a1"))
    let en = addNet(result, newNet("en"))
    let vdd = addNet(result, newNet("v3v3", ntPower))
    let gnd = addNet(result, newNet("0", ntGround))
    let u = addComponent(result, newComponent("U1", kind = "rf_switch"))
    discard connect(u, "RFC", rfc, ptPassive)
    discard connect(u, "RF1", rf1, ptPassive)
    discard connect(u, "RF2", rf2, ptPassive)
    discard connect(u, "RF3", rf3, ptPassive)
    discard connect(u, "RF4", rf4, ptPassive)
    discard connect(u, "A0", a0, ptInput)
    discard connect(u, "A1", a1, ptInput)
    discard connect(u, "EN", en, ptInput)
    discard connect(u, "VDD", vdd, ptPower)
    discard connect(u, "GND", gnd, ptGround)
    if declareSpec:
      addTraversalEdge(u, "RFC", "RF1")
      addTraversalEdge(u, "RFC", "RF2")
      addTraversalEdge(u, "RFC", "RF3")
      addTraversalEdge(u, "RFC", "RF4")

  proc sideOf(u1: SchematicPart, pinName: string): int =
    ## -1 left, 0 top/bottom, 1 right.
    for p in u1.pins:
      if p.name == pinName:
        if abs(abs(p.x - u1.x) - u1.bodyW / 2.0) < 1e-6:
          return (if p.x < u1.x: -1 else: 1)
        return 0
    doAssert false, "no pin " & pinName

  test "a declared RFC<->RF1..4 through-path puts RFC opposite RF1..4":
    let s = layout(adg904Shape(declareSpec = true))
    let u1 = partOf(s, "U1")
    check u1.isBox
    let rfcSide = sideOf(u1, "RFC")
    check rfcSide != 0
    for rf in ["RF1", "RF2", "RF3", "RF4"]:
      check sideOf(u1, rf) == -rfcSide
    # The input select/enable pins stay left.
    for pinName in ["A0", "A1", "EN"]:
      check sideOf(u1, pinName) == -1

  test "no traverse: spec produces the identical historical alternation":
    let s = layout(adg904Shape(declareSpec = false))
    let u1 = partOf(s, "U1")
    # With no traversal opinion, pins alternate in declared order.
    check sideOf(u1, "RFC") == -1
    check sideOf(u1, "RF1") == 1
    check sideOf(u1, "RF2") == -1
    check sideOf(u1, "RF3") == 1
    check sideOf(u1, "RF4") == -1
    for pinName in ["A0", "A1", "EN"]:
      check sideOf(u1, pinName) == -1

  proc oddCycleShape(): Netlist =
    ## Three passive pins in a triangle of declared edges: an odd cycle, not
    ## two-colourable.
    result = newNetlist("odd_cycle")
    let na = addNet(result, newNet("na"))
    let nb = addNet(result, newNet("nb"))
    let nc = addNet(result, newNet("nc"))
    let u = addComponent(result, newComponent("U1", kind = "triangle_part"))
    discard connect(u, "A", na, ptPassive)
    discard connect(u, "B", nb, ptPassive)
    discard connect(u, "C", nc, ptPassive)
    addTraversalEdge(u, "A", "B")
    addTraversalEdge(u, "B", "C")
    addTraversalEdge(u, "C", "A")

  test "a non-bipartite spec falls back to the historical alternation":
    let s = layout(oddCycleShape())
    let u1 = partOf(s, "U1")
    check u1.isBox
    # Unaffected by the triangle: A left, B right, C left.
    check sideOf(u1, "A") == -1
    check sideOf(u1, "B") == 1
    check sideOf(u1, "C") == -1

  proc allModeShape(): Netlist =
    result = newNetlist("all_mode")
    let na = addNet(result, newNet("na"))
    let nb = addNet(result, newNet("nb"))
    let nc = addNet(result, newNet("nc"))
    let u = addComponent(result, newComponent("U1", kind = "jumper_part"))
    discard connect(u, "A", na, ptPassive)
    discard connect(u, "B", nb, ptPassive)
    discard connect(u, "C", nc, ptPassive)
    setTraversalMode(u, tmAll)

  test "traverse: all with no declared edges is inert here too":
    let s = layout(allModeShape())
    let u1 = partOf(s, "U1")
    check sideOf(u1, "A") == -1
    check sideOf(u1, "B") == 1
    check sideOf(u1, "C") == -1

  proc seededShape(midIsOutput: bool): Netlist =
    ## A path `P0 <-> MID <-> P2`. A `ptOutput` MID seeds its component to the
    ## right, flipping P0 and P2 from the default left.
    result = newNetlist("seeded")
    let n0 = addNet(result, newNet("n0"))
    let n1 = addNet(result, newNet("n1"))
    let n2 = addNet(result, newNet("n2"))
    let u = addComponent(result, newComponent("U1", kind = "seeded_part"))
    discard connect(u, "P0", n0, ptPassive)
    discard connect(u, "MID", n1, (if midIsOutput: ptOutput else: ptPassive))
    discard connect(u, "P2", n2, ptPassive)
    addTraversalEdge(u, "P0", "MID")
    addTraversalEdge(u, "MID", "P2")

  test "an unseeded path alternates left/right/left from the default seed":
    let s = layout(seededShape(midIsOutput = false))
    let u1 = partOf(s, "U1")
    check sideOf(u1, "P0") == -1
    check sideOf(u1, "MID") == 1
    check sideOf(u1, "P2") == -1

  test "a ptOutput pin in the graph seeds its component, flipping the ends":
    let s = layout(seededShape(midIsOutput = true))
    let u1 = partOf(s, "U1")
    check sideOf(u1, "P0") == 1
    check sideOf(u1, "MID") == 1        # ptOutput's own kind still wins here
    check sideOf(u1, "P2") == 1

  proc adg904Bundled(): Netlist =
    ## Two switches sharing a 4-wide bus `m`, each with `RFC <-> RF1..4`
    ## through-paths. Uniform touching collapses `RF1..4` to one merged pin
    ## per switch (`brCollapsed`); the merged lane must take the traversal
    ## side opposite `RFC`, not `portDirection`'s input fallback.
    result = newNetlist("adg904_bundled")
    let rfc = addNet(result, newNet("rfc"))
    let u = addComponent(result, newComponent("U1", kind = "rf_switch"))
    discard connect(u, "RFC", rfc, ptPassive)
    let rfc2 = addNet(result, newNet("rfc2"))
    let u2 = addComponent(result, newComponent("U2", kind = "rf_switch"))
    discard connect(u2, "RFC", rfc2, ptPassive)
    for i in 1 .. 4:
      let n = addNet(result, newNet("m" & $i))
      n.attrs["bus.name"] = "m"
      n.attrs["bus.index"] = $(i - 1)
      n.attrs["bus.width"] = "4"
      discard connect(u, "RF" & $i, n, ptPassive)
      discard connect(u2, "RF" & $i, n, ptPassive)
    addTraversalEdge(u, "RFC", "RF1")
    addTraversalEdge(u, "RFC", "RF2")
    addTraversalEdge(u, "RFC", "RF3")
    addTraversalEdge(u, "RFC", "RF4")
    addTraversalEdge(u2, "RFC", "RF1")
    addTraversalEdge(u2, "RFC", "RF2")
    addTraversalEdge(u2, "RFC", "RF3")
    addTraversalEdge(u2, "RFC", "RF4")

  test "a through-path split survives even when its far end is a declared bus":
    let s = layout(adg904Bundled())
    let u1 = partOf(s, "U1")
    check u1.isBox
    var mLane: SchematicPin
    var found = false
    for p in u1.pins:
      if p.name != "RFC":
        mLane = p
        found = true
    check found
    let rfcSide = sideOf(u1, "RFC")
    check rfcSide != 0
    let mSide = (if abs(abs(mLane.x - u1.x) - u1.bodyW / 2.0) < 1e-6:
                   (if mLane.x < u1.x: -1 else: 1)
                 else: 0)
    check mSide == -rfcSide

suite "layout.mirror":
  proc crossedMirrorShape(): tuple[nl: Netlist, ra, rb: string] =
    ## `U1` is a 2-pin box with `P0` left, `P1` right by default. `P0`'s net
    ## goes to `RA` (forced right), `P1`'s to `RB` (forced left), so mirroring
    ## `U1` shortens both wires.
    let nl = newNetlist("crossed")
    let p0 = addNet(nl, newNet("p0"))
    let p1 = addNet(nl, newNet("p1"))
    let gnd = addNet(nl, newNet("0", ntGround))
    let u = addComponent(nl, newComponent("U1", kind = "odd_ic"))
    discard connect(u, "P0", p0, ptPassive)
    discard connect(u, "P1", p1, ptPassive)
    let ra = addComponent(nl, newComponent("RA", kind = "resistor"))
    discard connect(ra, "1", p0, ptPassive)
    discard connect(ra, "2", gnd, ptPassive)
    setLayoutSide(ra, sideRight)
    let rb = addComponent(nl, newComponent("RB", kind = "resistor"))
    discard connect(rb, "1", p1, ptPassive)
    discard connect(rb, "2", gnd, ptPassive)
    setLayoutSide(rb, sideLeft)
    (nl, "RA", "RB")

  test "chooseMirrors flips a box when mirroring shortens its wires":
    let (nl, _, _) = crossedMirrorShape()
    let s = layout(nl)
    check partOf(s, "U1").mirror

  test "a stated layout.mirror = false overrides what the heuristic would pick":
    let (nl, _, _) = crossedMirrorShape()
    setLayoutMirror(findComponent(nl, "U1"), mirrorOff)
    let s = layout(nl)
    check not partOf(s, "U1").mirror

  test "a stated layout.mirror = true is honoured even with no wirelength reason":
    let nl = newNetlist("plain_mirror")
    let a = addNet(nl, newNet("a"))
    let gnd = addNet(nl, newNet("0", ntGround))
    let u = addComponent(nl, newComponent("U1", kind = "plain_ic"))
    discard connect(u, "P0", a, ptPassive)
    discard connect(u, "P1", gnd, ptPassive)
    setLayoutMirror(u, mirrorOn)
    let s = layout(nl)
    check partOf(s, "U1").mirror

  test "a mirrored box's pins are the unmirrored ones reflected about its centre":
    let nlMirrored = newNetlist("m")
    block:
      let a = addNet(nlMirrored, newNet("a"))
      let b = addNet(nlMirrored, newNet("b"))
      let u = addComponent(nlMirrored, newComponent("U1", kind = "plain_ic"))
      discard connect(u, "P0", a, ptPassive)
      discard connect(u, "P1", b, ptPassive)
      setLayoutMirror(u, mirrorOn)
    let nlPlain = newNetlist("m")
    block:
      let a = addNet(nlPlain, newNet("a"))
      let b = addNet(nlPlain, newNet("b"))
      discard addComponent(nlPlain, newComponent("U1", kind = "plain_ic"))
      discard connect(nlPlain.components["U1"], "P0", a, ptPassive)
      discard connect(nlPlain.components["U1"], "P1", b, ptPassive)
    var noMirrorStage = defaultLayoutOptions()
    noMirrorStage.stages.excl lsMirror
    let mirrored = partOf(layout(nlMirrored), "U1")
    let plain = partOf(layout(nlPlain, noMirrorStage), "U1")
    check mirrored.x == plain.x and mirrored.y == plain.y
    check mirrored.bodyW == plain.bodyW and mirrored.bodyH == plain.bodyH
    for pp in plain.pins:
      var found = false
      for mp in mirrored.pins:
        if mp.name == pp.name:
          found = true
          check abs(mp.x - (2.0 * plain.x - pp.x)) < 1e-6
          check abs(mp.y - pp.y) < 1e-6
      check found

  test "a composite member box is never mirrored, even under the same bias":
    let (nl, _, _) = crossedMirrorShape()
    # A second box on `U1`'s two nets forms a parallel composite;
    # `chooseMirrors` skips both.
    let u1 = findComponent(nl, "U1")
    var p0Net, p1Net: Net
    for name, pin in u1.pins:
      if name == "P0": p0Net = pin.net
      if name == "P1": p1Net = pin.net
    let u2 = addComponent(nl, newComponent("XB2", kind = "odd_ic"))
    discard connect(u2, "P0", p0Net, ptPassive)
    discard connect(u2, "P1", p1Net, ptPassive)
    let s = layout(nl)
    check coStacked(partOf(s, "U1"), partOf(s, "XB2"))
    check not partOf(s, "U1").mirror
    check not partOf(s, "XB2").mirror

  test "the scene JSON round-trips mirror, additively":
    let (nl, _, _) = crossedMirrorShape()
    let s = layout(nl)
    check partOf(s, "U1").mirror
    let text = sceneToJsonString(s)
    check "\"mirror\": true" in text
    let back = jsonToScene(text)
    check partOf(back, "U1").mirror

  test "a mirror-free scene's JSON carries no mirror key at all":
    let s = layout(divider())
    let text = sceneToJsonString(s)
    check "mirror" notin text
