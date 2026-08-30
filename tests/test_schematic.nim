## The schematic pipeline: deterministic layout/routing, self-contained SVG,
## the public JSON API, and the per-run SVG in the run archive.
##
## The properties worth pinning here are not aesthetic. They are: the same
## netlist renders the same scene every time; placement never mutates the
## graph; a rail is detected by annotation rather than by name; an
## unrecognised kind and a hierarchical instance fall back to a box with
## deterministic pin placement; and the archive's SVG is a pure function of
## the netlist, so drawing it cannot change what was simulated.

import std/[json, math, os, streams, strutils, tables, tempfiles, unittest]

import nimcir/netlist
import nimcir/netlist/formats/spice
import nimcir/schematic
import nimcir/spice/ngspice

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
  ## positive-length collinear segment.
  for i in 0 ..< s.wires.len:
    for k in 0 ..< s.wires[i].points.high:
      let a = s.wires[i].points[k]
      let b = s.wires[i].points[k + 1]
      if abs(a.x - b.x) < 1e-9 and abs(a.y - b.y) < 1e-9: continue
      for j in 0 ..< i:
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
  ## to route as a tree with a branch rather than a simple path.
  result = newNetlist("star")
  let gnd = addNet(result, newNet("0", ntGround))
  let star = addNet(result, newNet("star"))
  for i in 1 .. 3:
    let r = addComponent(result, newComponent("R" & $i, kind = "resistor"))
    discard connect(r, "1", star, ptPassive)
    discard connect(r, "2", gnd, ptPassive)

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

template withEnv(key, value: string, body: untyped) =
  let had = existsEnv(key)
  let old = getEnv(key)
  putEnv(key, value)
  try:
    body
  finally:
    if had: putEnv(key, old) else: delEnv(key)

# --- the scene, which needs no simulator --------------------------------

test "layout is deterministic":
  let nl = divider()
  let a = renderSvg(nl)
  let b = renderSvg(nl)
  check a == b
  check sceneToJsonString(nl) == sceneToJsonString(nl)

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
      check w.kind == wkGround
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
        # raw bodies never overlap
        check dx >= (a.bodyW + b.bodyW) / 2.0 - 1e-6 or
              dy >= (a.bodyH + b.bodyH) / 2.0 - 1e-6
        # clearance-inflated bodies never overlap
        check dx >= (a.bodyW + b.bodyW) / 2.0 + 2.0 * clear - 1e-6 or
              dy >= (a.bodyH + b.bodyH) / 2.0 + 2.0 * clear - 1e-6
        # and the channel between inflated bodies stays wider than the
        # clearance, so a route fits between them
        check dx >= (a.bodyW + b.bodyW) / 2.0 + 3.0 * clear - 1e-6 or
              dy >= (a.bodyH + b.bodyH) / 2.0 + 3.0 * clear - 1e-6

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
  # the first hop is horizontally out through the left edge
  check wire[1].x < wire[0].x
  check abs(wire[1].y - wire[0].y) < 1e-6

test "layout rotates an eligible two-terminal part and rotates its pin slots":
  # A T-junction: R1 and R2 run vertically into the shared node b, R3
  # horizontally. The vertical parts are a 90-degree turn from the resistor
  # symbol's default, and the pin slots turn with the body.
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
  let r1p = partOf(s, "R1")
  check r1p.rotation == 90.0
  check r1p.pins.len == 2
  # The two pins now lie on a vertical line through the part centre, 80 world
  # units apart (the symbol's pin span), one above and one below.
  check abs(r1p.pins[0].x - r1p.pins[1].x) < 1e-6
  check abs(r1p.pins[0].x - r1p.x) < 1e-6
  check abs(abs(r1p.pins[0].y - r1p.pins[1].y) - 80.0) < 1e-6
  check (r1p.pins[0].y - r1p.y) * (r1p.pins[1].y - r1p.y) < 0.0
  # An unrotated horizontal part keeps its pins on the horizontal axis.
  let r3p = partOf(s, "R3")
  check r3p.rotation == 0.0
  check abs(r3p.pins[0].y - r3p.pins[1].y) < 1e-6
  check abs(abs(r3p.pins[0].x - r3p.pins[1].x) - 80.0) < 1e-6

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

test "a one-net leaf snaps up against its single net-mate, pin facing it":
  # CSH hangs off the mid node to ground: one signal net, so the force layout
  # gives it a single spring and leaves it adrift with its pin facing away.
  # leafSnap pulls it up against a mid-node pin and turns it so its own mid pin
  # faces there -- a short straight stub, not an L across the sheet.
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
  let lp = pinPoints(s, "CSH", "mid")[0]
  # CSH's mid pin lands on a line with some other mid pin (a straight stub) and
  # within a grid step of it.
  var best = 1e18
  for mate in ["RS", "RO"]:
    let mp = pinPoints(s, mate, "mid")[0]
    if (abs(lp.x - mp.x) < 1e-6 or abs(lp.y - mp.y) < 1e-6):
      best = min(best, abs(lp.x - mp.x) + abs(lp.y - mp.y))
  check best <= 80.0 + 1e-6

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

test "rotation is deterministic":
  let a = layout(divider())
  let b = layout(divider())
  check a.parts.len == b.parts.len
  for i in 0 ..< a.parts.len:
    check a.parts[i].rotation == b.parts[i].rotation

test "the public json api exposes rotation additively":
  let node = parseJson(sceneToJsonString(divider()))
  var rotOf = initTable[string, float]()
  for part in node["parts"]:
    check part.hasKey("rotation")
    let rot = part["rotation"].getFloat
    check rot in [0.0, 90.0, 180.0, 270.0]
    rotOf[part["designator"].getStr] = rot
  check rotOf["R1"] == 0.0
  check rotOf["R2"] == 180.0     # flipped end-for-end to shorten its wires
  check rotOf["U1"] == 0.0       # a fallback box never rotates

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

test "the real RIAA channel routes through the placement-routing feedback":
  # `designs/lib/riaa.nim`'s `RIAA_CHANNEL` is the case the feedback loop
  # exists for: under the stronger cross-net rules the `fb` net's first pin is
  # boxed in, and a single feedback move unblocks it. The recovered scene must
  # still uphold the hard routing invariants, and the feedback move must not
  # leave raw symbol bodies overlapping (placement separation may relax, but
  # symbols never overlap).
  let s = layout(riaaChannel())
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
  let a = layout(riaaChannel())
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
  let s = layout(fullRiaaTop())
  check s.fallbacks.len == 4
  for f in s.fallbacks:
    check f.net in ["inL", "inR", "outL", "outR"]
    check f.part in ["XL", "XR"]
    check f.pin in ["IN", "OUT"]
    check f.points.len == 2
  check fallbacksClearOfWires(s)
  check distinctWiresNeverShareCollinearRuns(s)
  check differentNetsRespectSeparation(s)

  let child = layout(riaaChannel())
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
  let s = layout(resistorChain(37))
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
  # The "tee" shape turns R1 to 90 degrees: its pins now leave top and bottom,
  # so its labels must sit left or right, clear of the vertical pin wires.
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
  let r1p = partOf(s, "R1")
  check r1p.rotation == 90.0
  check labelsClearOfGeometry(s)
  for lb in s.labels:
    if lb.owner != "R1": continue
    check abs(lb.x - r1p.x) >= 8.0     # offset sideways, not stacked on the wire

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

test "bend-aware routing prefers the equal-length pin with the fewest bends":
  # On the tee's net b, R2's and R3's escape points are both 96 world units
  # from R1's, so a length-only tie-break (lowest pin index) attaches R2
  # first and draws a two-bend staircase. The lexicographic (length, then
  # bends) cost attaches R3 first: one clean L.
  let s = layout(bendTee())
  check partOf(s, "R1").rotation == 90.0
  check partOf(s, "R3").rotation == 0.0
  var first: seq[Point]
  for w in s.wires:
    if w.net == "b" and w.kind == wkSignal:
      first = w.points
      break
  check first.len == 5
  if first.len == 5:
    check first[0] == pinPoints(s, "R1", "b")[0]
    check first[^1] == pinPoints(s, "R3", "b")[0]
    check routeBends(first) == 1

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
    # The first and last segments are the 12-unit outward stubs; the routed
    # path between the two escape points is a single-bend L, so the whole wire
    # has three visual corners but only one routed bend.
    check visualBends(wire) == 3
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

test "port layout is deterministic":
  check sceneToJsonString(portedSubckt()) == sceneToJsonString(portedSubckt())

test "the public json api exposes ports additively":
  let node = parseJson(sceneToJsonString(portedSubckt()))
  check node.hasKey("ports")
  check node["ports"].len == 4
  # existing keys untouched
  check node.hasKey("parts")
  check node.hasKey("wires")
  check node.hasKey("labels")
  var dirs: seq[string]
  for p in node["ports"]: dirs.add p["dir"].getStr
  check "input" in dirs
  check "output" in dirs
  check "bidir" in dirs
  check "unspecified" in dirs

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

# --- the archive, which needs the simulator -----------------------------

suite "run archive svg":
  if not haveNgspice:
    echo "  [skipped: ngspice not found on PATH]"
  else:
    test "an svg lands beside the deck, rawfile and log":
      let dir = createTempDir("nimcir_svgtests_", "")
      defer: removeDir(dir)
      withEnv("NIMCIR_KEEP_RUNS", dir):
        discard run(plainDivider(), ".op")

      check fileExists(dir / "run000.svg")
      let svg = readFile(dir / "run000.svg")
      check svg.startsWith("<?xml")
      check ">R1</text>" in svg
      check ">C1</text>" in svg
      check ">V1</text>" in svg

    test "a failed run still keeps its svg, like its deck and log":
      # `keepSchematic` renders before ngspice runs, so a convergence failure
      # leaves the picture of the fragment that failed -- the one worth reading.
      let dir = createTempDir("nimcir_svgtests_", "")
      defer: removeDir(dir)
      withEnv("NIMCIR_KEEP_RUNS", dir):
        expect(SpiceSimError):
          discard run(divider(), ".op")

      check fileExists(dir / "run000.svg")
      check ">U1</text>" in readFile(dir / "run000.svg")
