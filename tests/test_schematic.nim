## The schematic pipeline: deterministic layout/routing, self-contained SVG,
## the public JSON API, and the per-run SVG in the run archive.
##
## The properties worth pinning here are not aesthetic. They are: the same
## netlist renders the same scene every time; placement never mutates the
## graph; a rail is detected by annotation rather than by name; an
## unrecognised kind and a hierarchical instance fall back to a box with
## deterministic pin placement; and the archive's SVG is a pure function of
## the netlist, so drawing it cannot change what was simulated.

import std/[algorithm, json, math, os, sets, streams, strutils, tables, tempfiles, unittest]

import verax/netlist
import verax/netlist/formats/spice
import verax/schematic
import verax/spice/ngspice

import designs/lib/riaa

let haveNgspice = findExe("ngspice").len > 0

proc divider(): Netlist =
  ## A two-resistor divider with an output cap and an unmodelled MCU (whose
  ## VDD pin makes `vin` a power rail, and whose kind has no symbol).
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
  ## A simulatable RC divider -- the shape a derived simulation fragment
  ## actually has -- for the archive test, which must be able to run it.
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
  ## The top sheet of `designs/riaa_preamp.nim`: two `riaaChannel()` instances
  ## plus the shared supplies. Its four signal nets (`inL`, `outL`, `inR`,
  ## `outR`) each touch exactly one pin -- the channel box's port -- so each
  ## is a dangling single-pin net and must be drawn as a fallback marker.
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
  ## An orientable composite (`lsCompositeOrient`) may turn a two-member
  ## parallel/series unit through any of 0/90/180/270, so its members share
  ## *one* axis coordinate and sit `pitch` apart on the other -- assert that
  ## rather than a hardcoded column or row.
  ((abs(a.x - b.x) < 1e-6 and abs(abs(a.y - b.y) - pitch) < 1e-6) or
   (abs(a.y - b.y) < 1e-6 and abs(abs(a.x - b.x) - pitch) < 1e-6))

proc unitVertical(members: openArray[SchematicPart]): bool =
  ## Whether a rigid composite unit runs along y (its canonical frame) rather
  ## than along x after an `lsCompositeOrient` quarter-turn. Ties -> vertical.
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
  ## Direction changes along a polyline, counting every interior vertex --
  ## including the corners where the endpoint pin stubs meet the routed path.
  for k in 1 ..< poly.len - 1:
    let a = poly[k - 1]
    let b = poly[k]
    let c = poly[k + 1]
    let abHoriz = abs(a.y - b.y) < 1e-9
    let bcHoriz = abs(b.y - c.y) < 1e-9
    if abHoriz != bcHoriz: inc result

proc routeBends(poly: seq[Point]): int =
  ## Direction changes along a signal wire's *routed* portion: the first and
  ## last segments are the short outward pin stubs and are free, so only the
  ## interior vertices are charged.
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
  ## True when the axis-aligned segments a-b and c-d share a positive-length
  ## collinear run. Touching at one point is not an overlap.
  let av = abs(a.x - b.x) < 1e-9
  let cv = abs(c.x - d.x) < 1e-9
  if av != cv: return false
  if av:
    return abs(a.x - c.x) < 1e-9 and positiveOverlapT(a.y, b.y, c.y, d.y)
  else:
    return abs(a.y - c.y) < 1e-9 and positiveOverlapT(a.x, b.x, c.x, d.x)

proc distinctWiresNeverShareCollinearRuns(s: Schematic): bool =
  ## The within-net routing invariant: two distinct `SchematicWire` objects may
  ## meet at a vertex and may cross perpendicularly, but never overlap along a
  ## positive-length collinear segment. A `wkChain` arc is a dashed annotation,
  ## not a routed wire -- it deliberately runs beside its own pin's wire -- so
  ## it is exempt.
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
  ## True when the axis-aligned segments a-b and c-d lie on the same line and
  ## their intervals share any point -- a positive-length overlap *or* an
  ## end-to-end touch.
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
  ## True when the axis-aligned segments are parallel on distinct lines closer
  ## than 8 world units and their projections along that axis overlap by more
  ## than a point.
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
  ## The stronger cross-net invariant: two wires of different nets never touch
  ## collinearly (not even end-to-end) and keep at least 8 world units of
  ## centreline separation wherever they run parallel and their projections
  ## overlap.
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
  ## A fallback stub is a marker, never connectivity: it must not touch a real
  ## wire collinearly (not even end-to-end) nor run closer than 8 world units
  ## to a parallel real wire, exactly as if it were a foreign net. A
  ## perpendicular crossing stays allowed -- the dashed amber marker reads as
  ## "unconnected", not as a junction.
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
  ## The outward unit direction of a placed pin, by the same body-half-extent
  ## test `layout.escapeDir` uses: a pin on a body edge leaves along that
  ## edge's outward normal.
  let dx = pt.x - p.x
  let dy = pt.y - p.y
  let hw = p.bodyW / 2.0
  let hh = p.bodyH / 2.0
  if abs(abs(dx) - hw) < abs(abs(dy) - hh):
    Point(x: (if dx >= 0.0: 1.0 else: -1.0), y: 0.0)
  else:
    Point(x: 0.0, y: (if dy >= 0.0: 1.0 else: -1.0))

proc escapeSeedsT(s: Schematic): seq[tuple[net: string, a, b: Point]] =
  ## The fixed escape stubs `layout` protects: one per signal pin leaving the
  ## body, and one per interface port leaving its connection point inward.
  ## Rail and ground nets have no seed (they draw their own stubs instead).
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
  ## The stem plus every bar rendered by `svg.renderSvg` for a rail terminal.
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
  ## The placement repair is judged against the prospective 40-unit glyph,
  ## not the possibly shortened terminal the routing safeguard ultimately
  ## emits. It must clear foreign signal corridors, inflated foreign bodies,
  ## and terminal ink on another net.
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
  ## A signal wire may touch a foreign-net escape seed at an endpoint and may
  ## cross it perpendicularly, but never runs along any positive-length part
  ## of it. Same-net seeds are excluded: a wire's own stub *is* that seed.
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
  ## The label's ink box, by the same monospace estimate `layout` places with.
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
  ## The label invariant: no label's text box crosses a wire segment, overlaps
  ## a part's *drawn* ink or a port body, or overlaps another label. (A label
  ## may sit in a routing channel -- only a wire that actually took it counts.)
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
  ## The larger per-axis gap between two non-overlapping rects, 0 if they touch
  ## or overlap. Small for a label that hugs its part, large for one adrift.
  let gx = max(0.0, max(box.x1 - ink.x2, ink.x1 - box.x2))
  let gy = max(0.0, max(box.y1 - ink.y2, ink.y1 - box.y2))
  max(gx, gy)

proc starNet(): Netlist =
  ## Three resistors whose pin 1 all meet on one signal net, forcing the net
  ## to route as a tree with a branch rather than a simple path. Each pin 2
  ## lands on its own distinct net (not a shared ground/rail pair) so the
  ## three never share an unordered net pair and `parallelRecognize` cannot
  ## collapse them into one composite -- which would hand "star" entirely to
  ## `compositeInternalRoutes`' internal fanout instead of the ordinary
  ## router this fixture means to exercise.
  result = newNetlist("star")
  let star = addNet(result, newNet("star"))
  for i in 1 .. 3:
    let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
    discard connect(r, "1", star, ptPassive)
    discard connect(r, "2", addNet(result, newNet("tail" & $i)), ptPassive)

proc resistorChain(n: int): Netlist =
  ## `n` resistors in series sharing a signal net between neighbours -- a
  ## crowded netlist whose force layout would overlap without the separation
  ## pass.
  result = newNetlist("chain")
  var prev = addNet(result, newNet("n0"))
  for i in 1 .. n:
    let net = addNet(result, newNet("n" & $i))
    let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
    discard connect(r, "1", prev, ptPassive)
    discard connect(r, "2", net, ptPassive)
    prev = net

proc twoBlocks(): Netlist =
  ## Two independent RC pairs that share no net at all -- the shape whose two
  ## halves the force layout used to fling ~1200 world units apart.
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
  ## An MCU with a decoupling cap on its rail pair, plus an unrelated resistor
  ## divider. The cap shares only VDD/GND with the MCU, so a signal-only
  ## grouping would strand it -- the merge rule must keep it in the MCU's
  ## group rather than packing it beside the divider.
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
  ## `n` parallel R||C pairs strung in series between successive nets, an
  ## `mcu` output driving the first net and an `mcu` input reading the last.
  ## Both members of pair `i` share the unordered net pair `(n(i-1), ni)`, so
  ## `parallelRecognize` -- and therefore `compositePlan` -- collapses each pair
  ## to one placement unit: `2n` raw parts plus the two driver/sink `mcu`s
  ## (`2n + 2`), but only `n + 2` pool items. This is the shape Stage 2.3/2.5
  ## exist for: at `n = 33` the sheet is 68 raw parts (over
  ## `constrainedMaxParts` (64) on raw count alone) and 35 pool items (under
  ## it), so it must still get the constrained treatment instead of falling
  ## back to the ungrouped golden-spiral seed.
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

# `layout()` is superlinear and its placement-routing feedback loop is not
# cheap: a 37-resistor chain costs ~16s and the real RIAA channel ~2s. Every
# test that only *reads* one of these scenes shares a single module-level
# layout; the determinism tests below still re-run `layout` on purpose.
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
  # That the *default* policy still equals a bare `layout(nl)` is pinned by
  # "the default pipeline and its reserved no-op stages are byte-stable";
  # here the point is that opting in to `lpConstrainedLayered` produces a
  # scene that still upholds the collinear-run and cross-net separation rules.
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
  # The final sink has no declared output, so it shares or follows its driver;
  # it never reverses the stated output flow.
  check partOf(s, "U3").x <= partOf(s, "R1").x

test "constrained layering follows input ports and feedback paths semantically":
  # The input port has no pin direction at all: it must use portDirection's
  # existing no-driver fallback. The local-feedback case below uses an
  # unrecognised two-terminal kind, proving this walk is not passive-gated.
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

  # The walk must pass *through* a composite, not stop at its first member.
  # A pi section between an input port and a sink: the grounded shunt on the
  # port net used to consume the pi's pool position so the series member was
  # never traversed and no arc ordered the pi against the sink -- the pi then
  # landed in layer 0's seed order, on RIAA to the right of the op-amp it
  # feeds. All three members share one pool item, so they move together.
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

  # The same, one step further: a tee's two series legs are one pool item, so
  # `seen` keyed on the pool used to stop the walk at the mid net. Both legs
  # and the grounded shunt must land left of the sink they drive.
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

  # A feedback chain returning to the same component is a local loop, not an
  # earlier-layer feedback edge: the traversed device stays in the source's
  # semantic column.
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
    # A local return has bounded stage freedom around its source; later
    # legalization may retain the co-column position when that routes best.
    check abs(partOf(s, "RFB").x - partOf(s, "U1").x) <= 200.0

  # Insertion order would otherwise put RFB before its source. A genuine
  # return to an earlier component instead keeps the path passive right of
  # the output that drives it.
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
    # A third connected terminal stops the two-terminal feedback walker here.
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
  # R7 || C5 and R8 || C6 are each one placement unit despite their different
  # declarations and values: their paired symbols stay adjacent and co-stacked
  # on one axis (the unit's frame is `lsCompositeOrient`'s to choose).
  check coStacked(partOf(s, "R7"), partOf(s, "C5"))
  check coStacked(partOf(s, "R8"), partOf(s, "C6"))
  # RL (shunt on IN) -- CIN (series) -- RB (shunt on amp) is a pi section:
  # a pinned unit, series horizontal with a shunt one grid pitch below each
  # of its pins (pi is not orientable).
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
  # Compact composite routing may now clear this formerly crowded OUT route;
  # fallback cardinality is placement-dependent, not a RIAA contract. The
  # focused constrained-chain case below owns atomic fallback coverage.
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(riaaChannel(), options) == s

test "a composite whose leg lands on a global net still packs on a child sheet":
  # `render.keepFullSchematic` draws each subcircuit instance's *cloned child*,
  # where ground "0" stays a single shared object owned by the root. A
  # recognizer that rejected any pin whose `net.netlist` is not this sheet
  # would drop the pi's grounded shunts and leave RL/CIN/RB scattered --
  # `onThisSheet` accepts the shared global, so the child sheet packs it too.
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
  # The capability the whole Stage 2.3-2.5 effort was for: 33 R||C pairs is
  # 68 raw parts -- over `constrainedMaxParts` (64) by raw count alone -- but
  # only 35 pool items once each pair collapses to one composite, so the
  # semantic layering must still run instead of falling back to the
  # ungrouped golden-spiral seed. `lsRecoverRouting`/`lsRoutingAwareRepair`
  # are excluded so this measures placement, not the feedback loop.
  # Measured (this machine, debug build): ~1.9s for `layout()` -- felt, but
  # nowhere near the ~16s `resistorChain(37)` already costs elsewhere in this
  # file under the historical policy, so it does not move the needle on
  # `nimble test`'s wall time.
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  options.stages.excl lsRecoverRouting
  options.stages.excl lsRoutingAwareRepair
  let nl = parallelPairChain(33)
  let s = layout(nl, options)
  check s.parts.len == 68
  check partOf(s, "U1").x < partOf(s, "U2").x
  for i in 1 .. 33:
    # Each R||C pair is one placement unit: adjacent and co-stacked on one
    # axis, whichever frame `lsCompositeOrient` gave the unit.
    check coStacked(partOf(s, "R" & $i), partOf(s, "C" & $i))
  let box = sceneBBox(s)
  # The layered treatment produces a wide, short sheet; the ungrouped
  # golden-spiral seed (what a raw-count-only gate would have fallen back to)
  # does not.
  check box.x2 - box.x1 > box.y2 - box.y1
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(nl, options) == s

test "constrained layering falls back cleanly once the pool itself exceeds the gate":
  # 63 pairs pools to 65 -- one over `constrainedMaxParts` even after
  # collapsing every composite, so `constrainedEligible` must refuse the
  # semantic treatment and `layout` must still produce a complete, valid
  # scene from the plain force/separate/route pipeline instead of raising or
  # leaving a partial result. No placement/column assertions here: the point
  # is that the over-pool path degrades to "still lays out", not that it
  # looks like the eligible case above.
  # Measured (this machine, debug build): ~10.3s with force placement,
  # packing and terminal repair also excluded (irrelevant to what this test
  # checks and expensive at this raw part count); ~19s with them included.
  # Kept minimal on purpose -- this is a gate smoke test, not a
  # placement-quality test.
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
  # every pin sits on the body extent, which is `boxStub` outside the drawn body
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
      # A plain `wkGround` stub for a raw pin, or `wkPowerLink` for a parallel
      # composite's internal fanout to its one shared glyph (`divider`'s
      # R2/C1 pair) -- never `wkSignal`, and never more than a 2-point run.
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
  # An op-amp box: V+ (ptPower) on the top edge, V- (ptGround-kinded but on an
  # ntPower net -- a negative supply) on the bottom edge. Both rails must stub
  # outward from their pin, so the bottom one goes *down*, away from the body.
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
  # each stub starts at its pin and its far end is further from the body centre
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
  # Declare the pins out of the canonical order: placement must key on the
  # pin name, never on declaration order.
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
  # The shared coordinate is not a semantic junction, and each wire caps its
  # own cut from its adjacent segment lengths.
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
  # Glyphs still derive their orientation and ground-bar offsets from the
  # original terminal stubs, not the renderer-only chamfered polylines.
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
  # Painter order: a junction dot sits on top of the wires it joins but under
  # any symbol fill, so it never paints over a body.
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
  # the two blocks clear each other on one axis; the gutter is a few grid
  # cells, not the ~1200-unit spread the unbounded force layout produced
  let gapX = max(g2.x1 - g1.x2, g1.x1 - g2.x2)
  let gapY = max(g2.y1 - g1.y2, g1.y1 - g2.y2)
  check max(gapX, gapY) <= 5.0 * 40.0

test "a decoupling cap is packed with the part it decouples":
  # C1 shares only VDD/GND with U1, so a signal-only grouping strands it. The
  # merge rule folds it into U1's block: its edge-to-edge clearance to U1 is
  # one separation, while a full block gutter separates it from the divider.
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
        # The binding axis's margin past raw-body touching (whichever axis is
        # smaller): 0 for two composite members placed at their canonical
        # raw-body-touching offset (`divider`'s R2/C1 parallel-stack pair), or
        # >= 2*placementPad (40) for two independently separated parts -- the
        # separation invariant never lands strictly between the two.
        let marginX = dx - (a.bodyW + b.bodyW) / 2.0
        let marginY = dy - (a.bodyH + b.bodyH) / 2.0
        let margin = max(marginX, marginY)
        let touching = margin < 1.0
        # raw bodies never overlap
        check margin >= -1e-6
        # clearance-inflated bodies never overlap, unless they are one
        # composite's raw-touching members (no channel is needed between them:
        # they are wired to each other directly, never through the router)
        check touching or margin >= 2.0 * clear - 1e-6
        # and the channel between two independently placed inflated bodies
        # stays wider than the clearance, so a route fits between them
        check touching or margin >= 3.0 * clear - 1e-6

test "signal wires keep the routing clearance except at their own pins":
  let s = layout(divider())
  let pinPart = pinPartIndex(s)
  for w in s.wires:
    if w.kind != wkSignal: continue
    check w.points.len >= 2
    # direct pin access: every signal wire ends at the pin it connects (the
    # first wire also starts at a pin; later wires start at a tree vertex)
    check w.points[^1] in pinPart
    for k in 0 ..< w.points.high:
      let a = w.points[k]
      let b = w.points[k + 1]
      for pi, p in s.parts:
        let r = inflatedRect(p)
        # the short outward stub from a pin of `p` to its escape point is the
        # one place a wire may be inside `p`'s inflated body
        if pinPart.getOrDefault(a, -1) == pi or pinPart.getOrDefault(b, -1) == pi:
          continue
        check not segCrossesRect(a, b, r)

test "a tall box pin escapes through its own edge, not the dominant axis":
  let nl = newNetlist("tall")
  let a = addNet(nl, newNet("a"))
  let u1 = addComponent(nl, newComponent("U1", kind = "mcu"))
  # 12 pins -> a fallback box with 6 rows; its top-left pin sits at y = -85,
  # farther from the centre than its x = -70, which a dominant-axis rule would
  # misread as a vertical pin.
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
  # the first hop is horizontally out through the left edge, exactly to the
  # terminal escape coordinate that is now also an axis of the Hanan grid.
  check wire[1] == Point(x: p0.x - 12.0, y: p0.y)

test "layout rotates an eligible two-terminal part and rotates its pin slots":
  # A T-junction: R1, R2 and R3 all meet at shared node b. Whichever of them
  # placement turns 90/270 degrees from the resistor symbol's default, its
  # pin slots must turn with the body; whichever stays at 0/180 keeps its
  # pins on the horizontal axis. The three cannot all take the same axis --
  # a T-junction forces at least one part onto each.
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
      # The two pins now lie on a vertical line through the part centre, 80
      # world units apart (the symbol's pin span), one above and one below.
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
  # A four-resistor chain, but R2 is declared with its two pins swapped. Its
  # n1 pin (shared with R1, to its left) must still come out on the left and
  # its n2 pin (shared with R3, to its right) on the right -- which is a 180
  # turn from the symbol's default, chosen with no rule beyond "shorter wire".
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
  # RP and CP both bridge nets a and b. The pin-to-pin attraction is pulled by
  # both wires at once, so the two parts settle side by side with one
  # orientation between them -- where centre-to-centre forces left them in
  # unrelated spots and angles.
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
  ## Generic (non-RIAA) regression fixture: two grounded legs joined by a
  ## parallel bridge.  The bridge declarations may be reversed independently.
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
    # Parallel 80 x 80 passives are a raw-body-touching composite: no
    # placementPad between private members, and they stay co-stacked on one
    # axis whichever frame `lsCompositeOrient` picked.
    check coStacked(rb, cb)
    for net in ["left", "right"]:
      let p = pinPoints(s, "RB", net)[0]
      let q = pinPoints(s, "CB", net)[0]
      check abs(p.x - q.x) + abs(p.y - q.y) <= 160.0
    # Even a compact bridge may need a recoverable marker in a crowded
    # candidate, but its emitted routing remains deterministic and valid.
    check distinctWiresNeverShareCollinearRuns(s)
  # Reversed endpoint declaration changes only the member's deterministic
  # flip; it cannot make equal-net pins face across the bridge or randomise it.
  check layout(groundedLegsPlusBridge(true), options) == b

proc mixedNativeBridge(): Netlist =
  ## Three parallel members deliberately mix horizontal passive slots with the
  ## voltage source's native vertical slots. The constrained composite must
  ## map terminal *slots*, not copy one member's numeric rotation.
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
  # The mixed-axis members remain one locked, raw-body-touching unit, stacked
  # 80 apart along whichever axis `lsCompositeOrient` chose for the unit.
  let vert = unitVertical([rb, vb, cb])
  if vert:
    check rb.x == vb.x and vb.x == cb.x
    check abs(rb.y - vb.y) == 80.0 and abs(vb.y - cb.y) == 80.0
  else:
    check rb.y == vb.y and vb.y == cb.y
    check abs(rb.x - vb.x) == 80.0 and abs(vb.x - cb.x) == 80.0
  for part in [rb, vb, cb]:
    # Every member, not just the reference passive, has its two pins on the
    # unit's cross-axis, 80 apart -- the native-vertical source included.
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
  # Three members exercise the one-trunk fanout; no pair of emitted wires may
  # retain the old overlapping collinear root runs.
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
  ## A pi section: L1 series between `fin` and `mid`, a shunt cap to ground at
  ## each end, driven through a source resistor and loaded by a divider so
  ## both external nets reach beyond the composite.
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
  # The three members are one locked, canonical unit: series horizontal, a
  # shunt one grid pitch below each of its pins.
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
  ## A tee section: L1 and L2 in series through a private `mid` node that also
  ## carries a shunt cap to ground; nothing else touches `mid`.
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
  # Canonical T: the two series parts in one horizontal row, the shunt on the
  # midline between them, one grid pitch below, ground pin down.
  check l1.y == l2.y
  check abs(l1.pins[0].y - l1.pins[1].y) < 1e-6
  check abs(l2.pins[0].y - l2.pins[1].y) < 1e-6
  check c1.rotation in [90.0, 270.0]
  check abs(c1.x - (l1.x + l2.x) / 2.0) < 1e-6
  check c1.y > l1.y
  check c1.pins[1].net == "0" and c1.pins[1].y > c1.pins[0].y
  # The mid net is wholly internal: it has real wires (its T-junction), not a
  # fallback marker.
  check s.fallbacks.len == 0
  check wirePoints(s, "mid").len > 0
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(teeFilter(), options) == s

proc seriesChainFilter(portOnLink = false): Netlist =
  ## A four-part series chain RS-a-R1-m1-C1-m2-L1 driven from a source and
  ## ending at an output port `b`, with no grounded shunt anywhere on the chain
  ## so pi/tee cannot fire. `a`, `m1`, `m2` are private two-pin link nets;
  ## `src` has a non-usable source pin on it and `b` is a declared port, so the
  ## chain stops cleanly at RS and L1. With `portOnLink` the middle link `m1`
  ## is also a declared port -- it must then route externally and split the
  ## chain into RS-R1 and C1-L1.
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
  # One rigid unit: every member aligned on the unit's cross-axis and its two
  # pins on that same cross-axis. `lsCompositeOrient` chose the frame.
  let vert = unitVertical(members)
  let along = proc(m: SchematicPart): float = (if vert: m.y else: m.x)
  let across = proc(m: SchematicPart): float = (if vert: m.x else: m.y)
  let base = across(members[0])
  for m in members:
    check across(m) == base
    if vert: check abs(m.pins[0].x - m.pins[1].x) < 1e-6
    else: check abs(m.pins[0].y - m.pins[1].y) < 1e-6
  # Evenly spaced on a fixed 160 pitch, grid-aligned: four distinct members at
  # d0, d0+160, d0+320, d0+480 in some order.
  var minD = along(members[0])
  for m in members: minD = min(minD, along(m))
  var slots: array[4, bool]
  for m in members:
    let k = int(round((along(m) - minD) / 160.0))
    check k in 0 .. 3
    check abs((along(m) - minD) - float(k) * 160.0) < 1e-6
    check not slots[k]
    slots[k] = true
  # The three internal link nets are real wires, not fallback markers.
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
  # R1 and C1 no longer form one rigid unit: `m1` is a routed external net
  # (its own port symbol), so they are not aligned-and-160-apart the way two
  # members of one chain unit would be (in either frame).
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
  ## R1-R2-R3 in series from a driven VCC rail down to ground: a series chain
  ## whose free ends are a rail and ground, so `powerRank` alone (not fragile
  ## wirelength) forces `lsCompositeOrient` to stand it into a vertical column.
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
  # VCC end up, ground end down -- the powerRank result, with no motif rule.
  check pinPoints(s, "R1", "VCC")[0].y < pinPoints(s, "R3", "0")[0].y
  check s.fallbacks.len == 0
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)
  check layout(railToGroundChain(), options) == s

test "a rail decoupling bank turns its caps upright, side by side":
  # C1||C2 across VDD/0: powerRank prefers each cap vertical (VDD up, gnd down),
  # so the stack runs horizontal -- the conventional decoupling picture.
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
  # pi/tee are not orientable: their scenes are byte-identical to what they
  # were before the stage existed, which is also exactly the scene with
  # lsCompositeOrient dropped.
  for mk in [piFilter, teeFilter]:
    let withStage = layout(mk(), options)
    var without = options
    without.stages.excl lsCompositeOrient
    check layout(mk(), without) == withStage

test "a parallel pair is still a parallel stack, not a series chain":
  # RP||CP share the identical net pair (a, b): those nets carry four pins, so
  # neither is a chain link and the series kind cannot claim either part.
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
  # CSH hangs off the mid node to ground. Power direction is a stronger
  # rotation rank than plain wirelength, so the definitive rotation pass
  # keeps its ground pin down regardless of where its signal mate sits.
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
  # In this uncluttered case placement settles the power-directed capacitor
  # close beside V1, on the side its signal pin faces. It must remain
  # ground-down while that signal connection stays aligned, near, and
  # repeatable.
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
  # while positive and unannotated rails point up. An explicit ntPower kind
  # also beats the ptGround convention used by an op-amp V- pin.
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

# "rotation is deterministic" and "the public json api exposes rotation
# additively" folded away: `layout is deterministic` already compares
# `renderSvg` output (which encodes rotation) across two layouts, and the
# rotation values + JSON key now live in "the public json writer emits
# schemaVersion 1 with complete scene fields".

test "a rotated part draws its body in a rotate group, its labels kept outside it":
  var s = Schematic(title: "rot")
  var p = SchematicPart(designator: "R1", kind: "resistor", name: "",
                        value: "1k", symbol: "resistor", isBox: false,
                        bodyW: 80.0, bodyH: 80.0, inkW: 80.0, inkH: 20.0,
                        x: 100.0, y: 100.0, rotation: 90.0)
  p.pins.add SchematicPin(name: "1", x: 100.0, y: 60.0, net: "a")
  p.pins.add SchematicPin(name: "2", x: 100.0, y: 140.0, net: "b")
  s.parts.add p
  # `layout` places these; a hand-built scene supplies its own.
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
  # A part carries both the pin-span body extents and the drawn-ink extents;
  # a fallback carries its escape direction. These are the fields a reader
  # needs to rebuild the exact scene object.
  check node["parts"][0].hasKey("bodyW")
  check node["parts"][0].hasKey("bodyH")
  check node["parts"][0].hasKey("inkW")
  check node["parts"][0].hasKey("inkH")
  let withFb = parseJson(sceneToJsonString(riaaTopScene))
  check withFb["fallbacks"].len == 4
  check withFb["fallbacks"][0].hasKey("ex")
  check withFb["fallbacks"][0].hasKey("ey")

  # Rotation is exposed additively, as one of {0,90,180,270}, and carries the
  # value layout assigned: divider R1/R2 turn 90 for their rail/ground pins,
  # the U1 fallback box never turns.
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
  # The pre-schemaVersion writer stored no `schemaVersion` and no fallback
  # `ex`/`ey`; both are reconstructible from the scene's own part/port
  # geometry, never invented.
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
  # An unowned legacy fallback must retain its geometry while reporting no
  # fabricated escape direction.
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
  # A rotation-0 port sits to the right of its connection point -> inward -x.
  check fallbackEscapeDir(s.parts, s.ports,
    SchematicFallback(net: "b", part: "", pin: "", x: 110.0, y: 40.0)) ==
    Point(x: -1.0, y: 0.0)
  # A rotation-180 port sits to the left -> inward +x.
  check fallbackEscapeDir(s.parts, s.ports,
    SchematicFallback(net: "a", part: "", pin: "", x: -110.0, y: 40.0)) ==
    Point(x: 1.0, y: 0.0)
  # An owner the scene cannot identify yields the honest (0, 0).
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
  # The stronger cross-net invariant: two different nets may cross
  # perpendicularly, but never touch collinearly (not even end-to-end) and
  # keep at least 8 world units of centreline separation wherever they run
  # parallel and their projections overlap.
  for nl in [divider(), resistorChain(16), starNet(), twoBlocks(),
             decoupledMcu()]:
    let s = layout(nl)
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)

test "signal wires clear complete ground and supply terminal glyphs":
  # Focused rail/ground coverage: each terminal's stem and every bar emitted
  # by SVG are forbidden to signal routing, unlike an ordinary wire crossing.
  check signalWiresClearTerminalGlyphs(layout(divider()))
  check signalWiresClearTerminalGlyphs(layout(decoupledMcu()))

  # The real RIAA channel and its hierarchical top sheet exercise dense
  # positive/negative rails, ground terminals, fallback markers and boxes.
  check signalWiresClearTerminalGlyphs(riaaChannelScene)
  check signalWiresClearTerminalGlyphs(riaaTopScene)

  # Sheet-wide compatibility: existing ordinary signal-to-signal crossings
  # remain governed by the separation helper (perpendicular crossings allowed)
  # rather than being turned into terminal-style blockers.
  for nl in [resistorChain(16), starNet(), twoBlocks()]:
    check differentNetsRespectSeparation(layout(nl))

test "placement reserves full terminal glyphs before routing":
  # The compact divider is the minimal mixed signal/terminal case. Layout
  # determinism itself is pinned by "the placement-routing feedback is
  # deterministic" below.
  check fullTerminalGlyphsClearPlacementReservations(layout(divider()))
  # The real RIAA channel is a known, open exception (`docs/findings.md`,
  # "composite-locked terminal repair"): `RL`'s prospective ground glyph
  # crosses `CG`'s body because `repairTerminalClearance` cannot move a
  # composite member alone (moving it would break the pi/tee's rigid
  # offsets) and no unlocked part can release the corridor instead. Routing's
  # own defensive stem-shortening is the fallback safeguard for exactly this,
  # and does resolve it -- "signal wires clear complete ground and supply
  # terminal glyphs" above checks the *routed* (possibly shortened) result on
  # this same scene and passes.

test "a signal wire never threads a foreign-net escape seed":
  # Every signal pin and every interface port owns a short escape stub to the
  # routing grid. A signal route may touch a foreign-net stub at an endpoint
  # and may cross it perpendicularly, but may not run along any
  # positive-length part of it -- the seed's open interior stays clear for
  # the net that owns it. The real RIAA channel exercises both seed kinds:
  # its component-pin stubs plus its IN/OUT interface-port stubs.
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
  # `designs/lib/riaa.nim`'s `RIAA_CHANNEL` is the case the feedback loop
  # exists for: under the stronger cross-net rules the `fb` net's first pin is
  # boxed in, and a single feedback move unblocks it. The recovered scene must
  # still uphold the hard routing invariants, and the feedback move must not
  # leave raw symbol bodies overlapping (placement separation may relax, but
  # symbols never overlap).
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
  # The full stereo design (`designs/riaa_preamp.nim`) is not importable as a
  # netlist -- it runs `verify` at import -- so this builds its top sheet with
  # the importable `riaaChannel()` builder. The four channel ports (`inL`,
  # `outL`, `inR`, `outR`) each carry exactly one pin on the top sheet, so
  # each must be drawn as a dashed fallback stub rather than vanishing, and
  # the child channel sheet itself must still route with no fallbacks.
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

  # The archive renders the same scene through `renderSvg`; the top sheet's
  # picture carries the dashed amber markers while the child's does not.
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
  # A long resistor chain eventually crowds the Hanan lanes until one net can
  # no longer satisfy the 8-unit cross-net separation. `layout` must then
  # degrade that net to dashed fallback markers instead of raising -- the old
  # unchecked straight fallback would have drawn a wire across bodies and
  # other nets, and the old AssertionDefect made the archive unrenderable. The
  # real wires that remain still uphold the hard invariants, and the fallbacks
  # never join them as connectivity.
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
  # A failed tree must leave no partial real branches for that net: the
  # constrained route restores occupancy and emits only per-pin markers.
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
    # The canonical external endpoint represents every covered physical pin:
    # a failed composite tree cannot leave a partial real branch behind.
    check actual == expected
  for w in s.wires:
    if w.kind == wkSignal:
      check w.net notin fallbackNets
  check fallbacksClearOfWires(s)

test "fallback diagnostics route through exact terminal Hanan axes":
  # Both pins escape left through off-centre box-edge positions. Their escape
  # y coordinates are not obstacle-boundary axes, so the one-bend route needs
  # terminal-aware Hanan axes rather than a detour along a body boundary.
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

  # The JSON public layout preserves the same terminal-aware diagnostic.
  check diagnoseFallbackNet(jsonToScene(sceneToJsonString(s)), "sig") == d

test "the fallback reroute diagnostic reads a finished scene, not the netlist":
  # `diagnoseAllFallbacks` re-runs the router against the scene's own final
  # geometry (parts, wires, ports), so it works on an archived scene with no
  # netlist in hand -- the point of the run-archive JSON reader.
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

  # Fallback names are deduplicated in first-appearance order, and a caller
  # can explicitly ask about a net absent from the scene.
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
  # The terminal-aware grid gives former interior fallback n28 a direct Hanan
  # turn; only the two genuine one-pin endpoints remain fallback markers.
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
  # No signal wire was routed for the dangling net -- only the marker.
  var routed = false
  for w in s.wires:
    if w.net == "a" and w.kind == wkSignal: routed = true
  check not routed
  check fallbacksClearOfWires(s)
  # The exact net name is still labelled at the pin.
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
  # Parallel, distinct lines 4 < 8 apart, projections overlap -> too close.
  check parallelTooCloseT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                          Point(x: 0.0, y: 4.0), Point(x: 10.0, y: 4.0))
  # Parallel, distinct lines exactly 8 apart -> allowed.
  check not parallelTooCloseT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                              Point(x: 0.0, y: 8.0), Point(x: 10.0, y: 8.0))
  # Parallel and close, but projections only meet at a point -> allowed.
  check not parallelTooCloseT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                              Point(x: 10.0, y: 4.0), Point(x: 20.0, y: 4.0))
  # Collinear end-to-end contact is a touch.
  check collinearTouchT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                        Point(x: 10.0, y: 0.0), Point(x: 20.0, y: 0.0))
  # Collinear but separated by a gap is not a touch.
  check not collinearTouchT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                            Point(x: 11.0, y: 0.0), Point(x: 20.0, y: 0.0))

# --- label placement -------------------------------------------------------

test "no label lands on a wire, a body or another label":
  for nl in [divider(), starNet(), twoBlocks(), decoupledMcu(),
             resistorChain(6)]:
    check labelsClearOfGeometry(layout(nl))

test "every part label hugs its part rather than drifting off":
  # The "needlessly far" half of the complaint: a designator/value label sits
  # within one line-height-and-a-bit of its part's drawn ink, never out at the
  # old pin-span offset.
  let s = layout(divider())
  for lb in s.labels:
    if lb.role notin {lrDesignator, lrValue}: continue
    let p = partOf(s, lb.owner)
    check axisGapToInk(labelBoxT(lb), partInkRectT(p)) <= 40.0

test "a vertical-pin part keeps its labels off the pin wires":
  # V1's pins leave top and bottom, so its designator/value must go to a side.
  let s = layout(divider())
  let v1 = partOf(s, "V1")
  for lb in s.labels:
    if lb.owner != "V1": continue
    check abs(lb.x - v1.x) >= v1.inkW / 2.0 - 1e-6

test "a rotated part's labels follow the short axis of its ink":
  # The "tee" shape turns whichever of R1/R2/R3 placement elects as the
  # vertical branch to 90 degrees: its pins then leave top and bottom, so its
  # labels must sit left or right, clear of the vertical pin wires.
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
  # Three pins on one net -> exactly two wires, one per attached pin.
  check starWires == 2
  # Every pin of the net appears on some emitted wire.
  let pts = wirePoints(s, "star")
  for desig in ["R1", "R2", "R3"]:
    for p in pinPoints(s, desig, "star"):
      check p in pts

proc bendTee(): Netlist =
  ## A T-junction: R1 and R2 vertical, R3 horizontal, all three meeting on
  ## net `b`. R1's pin is equidistant (96 world units) from R2's and R3's
  ## escape points, but R3 is reachable in one bend while R2 needs two on the
  ## obstacle-boundary grid.
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
  ## One signal net between a transistor's top pin (vertical escape) and a
  ## fallback box's left-edge pin (horizontal escape): the two escape points
  ## sit on a diagonal with a single grid corner between them.
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
    # The first and last segments are the 12-unit outward stubs. Terminal
    # axes may align either stub with the routed L, removing visual corners,
    # but that cannot turn a stub into a charged routing bend.
    check visualBends(wire) <= 3
    check routeBends(wire) == 1

test "the overlap helper allows crossings and shared vertices, not collinear runs":
  # Perpendicular crossing.
  check not collinearOverlapT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                              Point(x: 5.0, y: -5.0), Point(x: 5.0, y: 5.0))
  # Meeting at one endpoint.
  check not collinearOverlapT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                              Point(x: 10.0, y: 0.0), Point(x: 20.0, y: 0.0))
  # Positive-length collinear overlap.
  check collinearOverlapT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                          Point(x: 5.0, y: 0.0), Point(x: 15.0, y: 0.0))
  # Identical collinear segments.
  check collinearOverlapT(Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0),
                          Point(x: 0.0, y: 0.0), Point(x: 10.0, y: 0.0))

# --- interface ports ---------------------------------------------------

proc portedSubckt(): Netlist =
  ## Shaped like `designs/lib/riaa.nim`'s `RIAA_CHANNEL`: an all-passive
  ## input, an op-amp-driven output, a power rail, a rail whose only clue is
  ## a `ptGround`-kinded op-amp supply pin, ground, plus a bidirectional bus
  ## port, an unspecified port a bare IC drives, and a declared port with no
  ## pins. Every interface net is registered with `addPort`.
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
  # IN is all-passive with nothing driving it -> input, via the fallback.
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

# "port layout is deterministic" folded away: layout determinism is already
# pinned on divider and the RIAA channel.

test "the public json api exposes ports additively, each with its direction":
  let node = parseJson(sceneToJsonString(portedSubckt()))
  # None of the pre-existing top-level keys are disturbed by adding ports.
  for key in ["parts", "wires", "labels", "ports"]:
    check node.hasKey(key)
  check node["ports"].len == 4
  var dirs: seq[string]
  for p in node["ports"]: dirs.add p["dir"].getStr
  for d in ["input", "output", "bidir", "unspecified"]:
    check d in dirs

test "renderSvg draws one polygon per port, each named":
  let text = renderSvg(portedSubckt())
  var polys = 0
  var i = 0
  while true:
    let n = text.find("<polygon", i)
    if n < 0: break
    inc polys
    i = n + 1
  check polys == 4
  check ">IN</text>" in text
  check ">OUT</text>" in text
  check ">BUS</text>" in text

test "the default pipeline and its reserved no-op stages are byte-stable":
  let nl = divider()
  let baseline = layout(nl)
  let baselineJson = sceneToJsonString(baseline)
  let baselineSvg = renderSvg(baseline)

  # An explicit default LayoutOptions is the same as none at all.
  check sceneToJsonString(layout(nl, defaultLayoutOptions())) == baselineJson
  check allLayoutStages == {lsPrepare..lsBounds}
  check defaultLayoutOptions().stageSpecs.len == ord(StageId.high) + 1

  # The reserved stages are still no-ops: dropping any one changes nothing.
  # `lsConstrainedRefinement` in particular is unfinished, so this is the
  # guard that it stays inert until it is done. `lsCompositeOrient` is a
  # no-op with no orientable composite on the sheet, and `lsPortRefine` is a
  # real pass but `divider` has no interface ports, so both are no-ops here.
  # `lsSemanticSeed` is deliberately excluded: it is the constrained pipeline's
  # real left-to-right layering pass, and `divider`'s R1-R2-C1/U1 sheet gives
  # it something to do.
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

      # The JSON is the same routed scene the SVG was drawn from: byte-for-byte
      # the public JSON of a fresh layout of that fragment.
      check fileExists(dir / "run000.json")
      check readFile(dir / "run000.json") == sceneToJsonString(plainDivider())

    test "a failed run still keeps its svg and json, like its deck and log":
      # `keepSchematic` renders before ngspice runs, so a convergence failure
      # leaves the picture of the fragment that failed -- the one worth reading.
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
    ## U1 -> U2 -> U3 -> R1, an output-pin chain so constrained layering
    ## naturally orders them left to right -- the same shape as "constrained
    ## layered policy places output flow in increasing columns" above.
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
    ## `n` resistors sharing no net with one another -- no motif can group
    ## any of them, so the composite-collapsed pool is exactly `n` raw parts.
    result = newNetlist("isolated_many")
    for i in 1 .. n:
      let a = addNet(result, newNet("a" & $i))
      let b = addNet(result, newNet("b" & $i))
      let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
      discard connect(r, "1", a, ptPassive)
      discard connect(r, "2", b, ptPassive)

  test "the side guarantee holds on a sheet too large for constrained layering":
    # 65 pool items is one over `constrainedMaxParts` (64): `constrainedEligible`
    # declines the sheet, so the semantic-seed hint (`constrainedTopology`)
    # never runs -- this exercises `enforceLayoutSides` alone.
    let nl = manyIsolatedResistors(65)
    setLayoutSide(findComponent(nl, "R1"), sideLeft)
    let s = layout(nl)
    let r1 = partOf(s, "R1")
    for i in 2 .. 65:
      check rightEdge(r1) < leftEdge(partOf(s, "R" & $i))

  proc parallelPair(): Netlist =
    ## R1 and C1 in parallel across the same two nets -- `parallelStackKind`'s
    ## recognized composite: one placement unit for both.
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
    ## Mirrors `designs/lib/spi_memory.nim`: one memory box, its SPI link
    ## published as a peripheral modport port, plus two straps to a rail.
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
    ## Mirrors `designs/spi_memories.nim`'s top: an MCU sharing one SPI bus
    ## between two peripheral boxes, plus a MISO pull-down. Portless.
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
    ## Mirrors `designs/i2c_eeprom.nim`: an interface instantiated across four
    ## parts but never *published* -- flat, no subckt, no port.
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
    # The whole interface fails collapse (MCU + two memory boxes + the MISO
    # pull-down = 4 component entities). Under the 3+-entity rule it becomes
    # ONE net-label bundle over every member net -- the per-signal retry is
    # skipped, so there is no `spi1_cs` sub-bundle.
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
    ## A width-1 bus wired between three parts: below the two-member floor, so
    ## it is *discarded* -- its net routes as an ordinary scalar and only the
    ## `ofNet` blue colour applies. Geometry is identical to the bus-free
    ## netlist by construction.
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
    # Same geometry, only the wire kind differs.
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
    ## A 2-net bus over exactly two component entities, non-uniform (one member
    ## touches both parts, the other only U2) and non-ported: below the
    ## 3-entity net-label threshold, so it stays `brScalar` -- ordinary wires,
    ## recoloured.
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
    ## A bus wired between two boxes and nowhere else: {U1, U2}, not ported ->
    ## 2 + 0 == 2 entities -> collapses to one thick wire, no port.
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
    # One merged port, bidirectional (sclk/mosi in, miso inout -> mixed).
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
    # The 4-unit stroke did not leak into the router.
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
    ## A bus wired identically to THREE boxes, every member touching every
    ## box -- {U1, U2, U3}, uniform, not ported. There is no entity cap on
    ## collapse: this draws as one bus tree, not the 3+-entity net-label
    ## convention (`xbar_rf`'s `m` bus is the same shape, across eight).
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
    ## An 8-wide bus, one member per distinct box -> fails uniform collapse
    ## -> `brNetLabel`, exactly the shape `designs/xbar_rf.nim`'s `en` bus
    ## takes. `published` names which members reach the sheet boundary.
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
    # An interface's own merged tag keeps the shipped count form instead --
    # see "a ported interface broken out ..." below (`rep[0].port == "spi[3]"`):
    # its members are heterogeneous named signals, not bus bits.

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
    ## Reversed premise: `bussed()` (4 component entities) now degrades to
    ## grouped net labels and is no longer inert. What still holds is the
    ## zero-value guarantee -- a netlist carrying no `bus.*`/`iface.*` net attr
    ## lays out byte-identically with `lsBundles` on or off, no wire-kind
    ## exemption.
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
    # As authored (i2c interface across 4 entities) it is a real net-label bundle.
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

  test "the i2c shared-bus shape: merged tags on the boxes, bare tags on the pull-ups":
    let nl = i2cUnpublishedSheet()
    let rep = bundleReport(nl)
    check rep.len == 1
    check rep[0].role == "netlabel"
    check rep[0].labels.sorted == @["R1=", "R2=", "U1=i2c", "U2=i2c"]
    let s = layout(nl)
    # The two boxes carry one merged "i2c" pin each; the pull-ups keep a bare
    # member tag.
    var mergedBoxes = 0
    for p in s.parts:
      if p.designator notin ["U1", "U2"]: continue
      for pin in p.pins:
        if pin.name == "i2c":
          check pin.members.len == 2
          inc mergedBoxes
    check mergedBoxes == 2
    var tags = initCountTable[string]()
    for f in s.fallbacks:
      check f.kind == fbNetLabel
      tags.inc f.net
    check tags["i2c"] == 2
    check tags["i2c_sda"] == 1
    check tags["i2c_scl"] == 1
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
    ## A subckt taking an interface modport port and wiring every signal into
    ## *two* internal parts -> three entities (the boundary + two parts) ->
    ## brNetLabel: every member drawn as a deliberate teal name tag, no wires.
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
    ## Both boxes carry all three signals, so the whole entity set (U1, U2,
    ## the sheet boundary) is uniform -- collapse has no entity cap and wins
    ## over the old 3+-entity net-label convention.
    let nl = brokenOutInterfaceSheet()
    let rep = bundleReport(nl)
    check rep.len == 1
    check rep[0].role == "collapsed"
    check rep[0].entities == @["U1", "U2"]
    check rep[0].port == "spi[3]"                    # interface -> count form
    let s = layout(nl)
    # The three published members fold to ONE pennant, not three.
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
    # U1 and U2 each collapse their three member pins onto one merged pin.
    var merged = 0
    for p in s.parts:
      if p.designator notin ["U1", "U2"]: continue
      for pin in p.pins:
        if pin.name == "spi[3]":
          check pin.members.len == 3
          check pin.net == rep[0].display
          inc merged
    check merged == 2
    # The purple interface wire, not the teal net-label chevron.
    let svg = renderSvg(s)
    check "#8250df" in svg
    check "#0f7b6c" notin svg

  test "diagnostics refuses a deliberate net label and skips it in the sweep":
    let s = layout(spiSharedBusSheet())
    # Diagnose one member's own deliberate tag -- U1's bare group text, not
    # a net (this bundle is non-uniform -- R1/U2/U3 each hold different
    # signals -- so it stays `brNetLabel` regardless of the entity count).
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
    # Four distinct tags -- U1's bare group text, one merged slice tag each
    # on U2/U3, and R1's own bare member net -- each drawn exactly once,
    # none doubled by the net-name pass.
    for tag in ["spi1", "spi1(cs0)", "spi1(cs1)", "spi1_miso"]:
      check fbCount[tag] == 1
      check labelCount[tag] == 1
    # The member names folded into a merged tag are never drawn as free text.
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
    # U2 owns cs_0, U3 owns cs_1 -> slice tags on the two memory boxes.
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
    # The merged pin's members reached the explorer model.
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
    ## One buffer sheet: a power port, a series in/out pair, a per-instance
    ## tap, and an enable.
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
    ## Four CELLs: `vdd` common but a **rail**, `sin`/`sout` a daisy chain,
    ## `tap` distributed, `en` irregular (two share, two differ), and `sel` a
    ## common **signal** port bound identically across every member -- once a
    ## rail-bound common port suppresses `pmBusBar` (a glyph-drawing pin
    ## already says "shared rail"; see the "component arrays" suite), `vdd`
    ## alone would leave that mark with no coverage here.
    ##
    ## Each termination resistor gets a **different** value (1k/2k/3k/4k):
    ## four otherwise-identical `resistor`s each wired one distributed `t*`
    ## pin to the shared `vdd` rail would themselves now qualify as a
    ## *component* array (exactly the both-ends-distributed shape the
    ## "component arrays" suite's dedicated fixture tests) -- differing
    ## values keep that a separate, deliberately-constructed test case rather
    ## than an accidental side effect landing on every subsheet-array
    ## assertion below.
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
    ## Six CELLs whose `en` splits them cleanly into two groups of three.
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
    ## Two splitting ports whose partitions do not align: the intersection is
    ## all singletons, so nothing collapses.
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
    # Each BCELL shares a private 2-wire bus point-to-point with one widget
    # box, so `bus:a`/`bus:b`/`bus:c` each collapse -- and every array member
    # is in one, so the array is declined.
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
    # Three BCELLs sharing ONE bus fan across four entities -> brNetLabel, not
    # brCollapsed, so the array still collapses; the io port reads bundled.
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
    # one wkChain wire carrying the three link nets
    var chainWires = 0
    for w in s.wires:
      if w.kind == wkChain:
        inc chainWires
        check w.members == @["l1", "l2", "l3"]
    check chainWires == 1
    # one wkBus wire for the distributed `tap` port
    var busWires = 0
    for w in s.wires:
      if w.kind == wkBus and w.members.len == 4: inc busWires
    check busWires >= 1
    # the marks landed
    var marks: HashSet[PinMark]
    for p in s.parts:
      for pin in p.pins: marks.incl pin.mark
    check pmBusBar in marks      # sel (a common *signal* port; vdd is a
                                 # common rail, and a rail-bound common port
                                 # never gets this mark -- see arrayPinFor)
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
    # and a netlist with no array is identical with the stage on or off
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
    # `designs/lib/spi_dev.nim`: an internal net published twice, `clk_in` and
    # `clk_out`. `portDirection` sees one internal pin and would call both
    # inputs; the `_in` / `_out` suffix orients them instead, and both keep
    # their real port name -- the interface is the two ports, not the net.
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
    # a published net that will not route degrades to a by-name label, never
    # an amber "unrouted" marker
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
    # the representative carries its instance list and count in the model
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
    ## `n` identical 50-ohm terminations, one per channel -- `xbar_rf.nim`'s
    ## own `RT_*` bench resistors in miniature: distinct nets on port "1"
    ## (per-channel), one shared ground on port "2".
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
    # Two identical resistors never collapse -- N < 3 -- however alike.
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

    # An array-free netlist's scene is byte-identical whether `lsPartArrays`
    # is on or off -- the zero-value guarantee at the pipeline-stage level.
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
    ## `n` decoupling caps across one rail pair -- every port `apCommon` and
    ## `railCommon`, the bypass-bank shape the all-common decline now *lets
    ## through* (see the test below): a genuine rail/ground bank collapses
    ## to one badged symbol rather than staying `composites/passive
    ## .parallelStackKind`'s visible stack.
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
    ## `n` identical resistors in parallel across one *signal* net pair --
    ## every port `apCommon`, none of it a rail/ground pair. The all-common
    ## decline still applies here: `composites/passive.parallelStackKind`
    ## already draws this as a visible stack, and stealing it would hide the
    ## count behind an `xN` badge instead.
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
    # still one `parallelStackKind` composite: every resistor shares one
    # coordinate on its canonical axis (x or y, whichever `lsCompositeOrient`
    # settles the unit on -- unlike the rail case, nothing here forces a
    # power-directed frame) and is evenly spaced on the other.
    var xs, ys: HashSet[float]
    for i in 1 .. 8:
      xs.incl partOf(s, "R" & $i).x
      ys.incl partOf(s, "R" & $i).y
    check xs.len == 1 or ys.len == 1

  proc filterBank(n: int): Netlist =
    ## `n` independent RC low-pass channels, `in_i -[R_i]- mid_i -[C_i]- gnd`.
    ## Every `mid_i` sits on the R array's port "2" *and* the C array's port
    ## "1" -- the both-ends-distributed shape `finalizeArrayPlan` exists for.
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
    ## Four 10k and four 2k resistors, otherwise identical: `value` is in the
    ## identity key precisely so these two groups never merge into one.
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
    ## Three sections of one physical package, otherwise identical enough to
    ## qualify -- `isPackaged` must exclude them before the identity key is
    ## even built, or their own "U9A"/"U9B"/"U9C" labels would fight the
    ## array's "X1..X3" label for the same box.
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
    ## `n` resistors in series -- `out(i) == in(i+1)`, exactly the chain
    ## shape a subsheet array would recirculate. A resistor symbol has no box
    ## interior for that arc, so it must degrade to distributed instead.
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
    ## Three resistors each on their own net, all three plus a reading MCU
    ## forming a >= 3-entity bus -- a `brNetLabel` bundle, which keeps its
    ## own drawing at the pin but does not veto the array (only a
    ## `brCollapsed` bundle, whose far endpoint would vanish, does that).
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
    # `bundledTerminationBank`'s R1/R2/R3 each sit on port "1", every one
    # bound to a distinct member of `bus grp` -- but `U1` on the far side
    # *merges* all three (P1/P2/P3 fold to one box pin), so this is a *mixed*
    # bundle: one carrier merged, three not. A bus tree drawn between R1 and
    # a `U1` that stands for a merged trio has no single occupancy tag left
    # for the array to route under (`xbar_rf`'s `a` bus is the same shape:
    # every switch merges its own `A0`+`A1`, every pulldown resistor owns
    # just one member) -- the array defers to the bundle's own drawing
    # wholesale (`mergedByBundle` is forced true everywhere on a bundle that
    # merges *anywhere*), not only at the one carrier that individually
    # merges. The array's own mark/tag is suppressed (bundle wins at the
    # pin), but the representative's own raw binding ("a1") must not leak
    # through either: once the array collapses, this one pin stands for
    # every hidden member's binding on the bus, so its identity is the bus
    # itself.
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
    # The one visible net-label tag the representative still draws (its two
    # hidden siblings' own tags vanished along with their pins) reads the
    # same bus name, not the pre-collapse index ("a1") the representative
    # happened to keep.
    var sawFallback = false
    for f in s.fallbacks:
      if f.part == "R1" and f.pin == "1":
        sawFallback = true
        check f.net == "grp"
    check sawFallback

  proc twoBusBank(): Netlist =
    ## Eight resistors, each on its own net -- four members of `bus fam1`,
    ## four of `bus fam2` -- the exact shape `xbar_rf`'s `rin`/`rout` split
    ## hits: a distributed port whose members never share a single net (so
    ## raw-identity sub-grouping saw no split at all, before `splitKeyOf`)
    ## but which visibly falls into two families through declared bus
    ## membership. No net here has more than one pin, so this also becomes a
    ## `>= 3`-entity `brNetLabel` bundle on each half -- the realistic
    ## shape, since a bus fanning out to distinct single-pin entities is
    ## exactly what makes a bundle in the first place.
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
    ## Four connectors and four switches, channel `i` wired
    ## `Ji.RF -- b[i] -- Ui.IN` -- `xbar_rf`'s `rin`/`rout` shape exactly: a
    ## bus non-uniform across its whole 8-entity span (`brNetLabel`), but
    ## each half forms its OWN 4-member component array, one member per
    ## carrier (never merged), so the array on either end now draws and
    ## routes it -- one real bus wire between the two boxes, not a bare tag
    ## on each end.
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
    ## Three otherwise-identical "gadget" parts, each with a private two-wire
    ## bus to its own widget -- a `brCollapsed` bundle, whose far endpoint
    ## would vanish were the gadget hidden as a non-representative array
    ## member. This is the one decline the array respects.
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
    ## Five identical-shape gadgets share ONE uniform 2-wide bus -- a single
    ## `brCollapsed` bundle across all five entities, the `xbar_rf` `m`-bus
    ## shape (every member wired identically across every entity). Only
    ## G1..G3 (`value = "v1"`) share a signature; G4/G5 carry a different
    ## value and, at two members, never reach the array floor, so they stay
    ## visible. Hiding G2/G3 as the array's non-representative members still
    ## leaves G1, G4 and G5 on the bundle -- three surviving entities -- so
    ## the array should still collapse: `survivesCollapsedBundles`'s
    ## placeable-endpoint count, not the old blanket "any member touches
    ## some collapsed bundle" veto, which would have declined this outright.
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
  ## `piFilter`'s exact shape (series `L1` between `fin`/`mid`, a grounded
  ## shunt cap at each end), except `L1` may carry a third connected pin (to
  ## its own private net) and may declare its own `RFC`-style `traverse:`
  ## edge between the two pins that would otherwise make it a pi's series
  ## leg. `piRecognize` tests `isTwoTerminal` and never the widened
  ## `isTraversable` that only `constrained.pathsFrom` calls -- so a third
  ## pin must decline the pi regardless of what `L1` declares, and a bare
  ## declaration on an otherwise-ordinary 2-pin part must change nothing.
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
  ## `piInternalLayout`'s exact canonical signature: series horizontal, each
  ## shunt exactly `2 * grid` pitches below and `grid` pitches either side of
  ## it (`piInternalLayout`'s `pinSpan`-based offsets, grid-rounded) --
  ## unreachable by ordinary force placement, which never lands two
  ## unrelated parts on that precise a relationship by coincidence, so this
  ## is a reliable positive/negative signature for "the pi composite formed
  ## around L1", not just "L1 and its shunts ended up near each other".
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
    # `wouldBePi(false, false)` is exactly `piFilter`'s shape (an ordinary
    # 2-pin `L1`, nothing declared) -- the existing "constrained pi
    # composite" test above already pins this geometry; this just confirms
    # the traversal machinery being present at all does not perturb the
    # historical no-declaration path for the identical shape built here.
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    let s = layout(wouldBePi(thirdPin = false, declareSpec = false), options)
    check pinLocked(s)
    check s.fallbacks.len == 0
    check distinctWiresNeverShareCollinearRuns(s)
    check differentNetsRespectSeparation(s)

  test "an ordinary 2-pin part declaring its own conduction still forms the pi":
    # A bare `traverse:` declaration that only restates what `isTwoTerminal`
    # already established changes nothing: `piRecognize` never reads it.
    var options = defaultLayoutOptions()
    options.policy = lpConstrainedLayered
    let s = layout(wouldBePi(thirdPin = false, declareSpec = true), options)
    check pinLocked(s)

  test "a declared multi-exit part is still declined by the pi recognizer":
    # The motivating regression: an 8-pin RF switch that states its own
    # conduction must not be picked up by a composite recognizer keyed on
    # exactly two connected pins -- `pi`/`tee`/`series` call `isTwoTerminal`,
    # never the widened `isTraversable`, specifically so this stays declined.
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
    ## The ADG904's exact pin table (`designs/xbar_rf.nim`): `RFC`/`RF1..4`
    ## all `ptPassive`, `A0`/`A1`/`EN` all `ptInput`, `VDD`/`GND`. 10 pins
    ## with no registered symbol -> a fallback box.
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
    ## -1 left, 0 top/bottom (or off the pin extent, unexpected), 1 right.
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
    # The three ptInput select/enable pins are unaffected -- still left.
    for pinName in ["A0", "A1", "EN"]:
      check sideOf(u1, pinName) == -1

  test "no traverse: spec produces the identical historical alternation":
    let s = layout(adg904Shape(declareSpec = false))
    let u1 = partOf(s, "U1")
    # RFC, RF2, RF4 alternate to the left; RF1, RF3 to the right -- exactly
    # `left.len <= right.len` walking the pins in declared order with no
    # traversal opinion at all.
    check sideOf(u1, "RFC") == -1
    check sideOf(u1, "RF1") == 1
    check sideOf(u1, "RF2") == -1
    check sideOf(u1, "RF3") == 1
    check sideOf(u1, "RF4") == -1
    for pinName in ["A0", "A1", "EN"]:
      check sideOf(u1, pinName) == -1

  proc oddCycleShape(): Netlist =
    ## Three `ptPassive` pins in a triangle of declared edges -- an odd
    ## cycle, which has no two-sided drawing.
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
    # `left.len <= right.len`, unaffected by the undrawable triangle: A left,
    # B right, C left.
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
    ## A 3-pin path `P0 <-> MID <-> P2`. When `MID` is `ptOutput` it forces
    ## its own connected component's colour seed to "right", flipping both
    ## `P0` and `P2` from the unseeded default (left) to right -- proving the
    ## seed actually changes the two-colouring rather than merely agreeing
    ## with it by coincidence.
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
    ## The actual regression: `designs/xbar_rf.nim`'s exact shape -- two
    ## switches sharing one midplane bus (`m`, width 4), each with its own
    ## `RFC <-> RF1..4` through-path, exactly like the crossbar's two-stage
    ## `m[0..3]` nets. Two entities uniformly touching all four bus members
    ## is what makes `bundles.nim` collapse `RF1..4` into **one merged pin**
    ## per switch (`brCollapsed`) -- unlike a single-entity bus, which stays
    ## unmerged and never exercises the bug. `RF1..4` are `ptPassive` with no
    ## kind-based side of their own, so before a merged bundle lane was
    ## checked against `traversalSides`, `bundleGroupsFor`'s `portDirection`
    ## fallback ("nothing drives it, call it an input") put the whole merged
    ## `m` lane on the **same** side as `RFC` -- silently defeating the
    ## traversal split the instant a design's RF pins also happened to be a
    ## declared bus, which every real ADG904 usage is.
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
    ## `U1` is a 2-pin fallback box; historically `P0` (ordinal 0) lands on
    ## the box's left edge and `P1` (ordinal 1) on its right. `P0`'s net is
    ## wired to `RA`, forced strictly right of the sheet; `P1`'s net to `RB`,
    ## forced strictly left -- crossed, so mirroring `U1` (putting `P0` on
    ## the right, facing `RA`, and `P1` on the left, facing `RB`) shortens
    ## both wires.
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
    # A second box sharing exactly `U1`'s two nets forces a parallel-stack
    # composite of two members -- `chooseMirrors` must skip both.
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
