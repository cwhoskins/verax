## Self-contained SVG writer for a `Schematic`.
##
## This is the reference visualizer's export step: every colour is resolved to
## a literal and every style is inlined, so the file opens standalone with no
## stylesheet, no font dependency beyond a generic family, and no external
## resources. Pure string building over the scene -- no DOM, no interactivity.

import std/[math, strutils]
import ../netlist/types
import ./scene
import ./layout

proc xmlEscape(s: string): string =
  result = newStringOfCap(s.len)
  for ch in s:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&apos;"
    else: result.add ch

proc num(x: float): string =
  ## A world coordinate as a clean, deterministic decimal (grid-snapped
  ## coordinates render as "40", not "40.000").
  if abs(x) < 0.0005: return "0"
  let r = round(x * 1000.0) / 1000.0
  if abs(r) < 0.0005: return "0"
  result = formatFloat(r, ffDecimal, 3)
  if '.' in result:
    while result.endsWith("0"): result.setLen(result.len - 1)
    if result.endsWith("."): result.setLen(result.len - 1)

proc pointsAttr(pts: seq[Point]): string =
  var toks: seq[string]
  for p in pts: toks.add num(p.x) & "," & num(p.y)
  toks.join(" ")

proc anchorName(a: TextAnchor): string =
  case a
  of taStart: "start"
  of taMiddle: "middle"
  of taEnd: "end"

proc textAt(x, y: float, s: string, anchor = "start", size = 12): string =
  "<text x=\"" & num(x) & "\" y=\"" & num(y) &
    "\" font-family=\"monospace\" font-size=\"" & $size &
    "\" fill=\"#333333\" text-anchor=\"" & anchor & "\">" &
    xmlEscape(s) & "</text>"

proc lineAt(x1, y1, x2, y2: float, stroke = "#333333", width = "2"): string =
  ## `stroke`/`width` default to the historical literals, so every existing
  ## call site emits the identical string. A bus/interface wire passes a
  ## colour and stroke 4; stroke width is purely cosmetic (it stays inside
  ## `wireMinSeparation`'s 8-unit gap), so the router needs no per-net rule.
  "<line x1=\"" & num(x1) & "\" y1=\"" & num(y1) &
    "\" x2=\"" & num(x2) & "\" y2=\"" & num(y2) &
    "\" stroke=\"" & stroke & "\" stroke-width=\"" & width & "\"/>"

proc polyAt(pts: seq[Point], stroke = "#333333", width = "2"): string =
  "<polyline fill=\"none\" stroke=\"" & stroke & "\" stroke-width=\"" & width &
    "\" points=\"" & pointsAttr(pts) & "\"/>"

proc isJunction(junctions: seq[SchematicJunction], net: string, p: Point): bool =
  for j in junctions:
    if j.net == net and abs(j.x - p.x) < 1e-9 and abs(j.y - p.y) < 1e-9:
      return true

proc chamferedWirePoints(wire: SchematicWire,
                        junctions: seq[SchematicJunction]): seq[Point] =
  ## Renderer-only corner cuts. Scene geometry remains the routed orthogonal
  ## polyline so JSON, routing, and junction semantics remain unchanged.
  if wire.points.len < 3:
    return wire.points

  result.add wire.points[0]
  for i in 1 ..< wire.points.high:
    let a = wire.points[i - 1]
    let b = wire.points[i]
    let c = wire.points[i + 1]
    let dx1 = b.x - a.x
    let dy1 = b.y - a.y
    let dx2 = c.x - b.x
    let dy2 = c.y - b.y
    let len1 = abs(dx1) + abs(dy1)
    let len2 = abs(dx2) + abs(dy2)
    let orthogonal = (abs(dx1) < 1e-9 and abs(dy2) < 1e-9) or
                     (abs(dy1) < 1e-9 and abs(dx2) < 1e-9)
    if len1 > 1e-9 and len2 > 1e-9 and orthogonal and
        not isJunction(junctions, wire.net, b):
      let cut = min(4.0, min(len1 / 2.0, len2 / 2.0))
      result.add Point(x: b.x - dx1 / len1 * cut,
                       y: b.y - dy1 / len1 * cut)
      result.add Point(x: b.x + dx2 / len2 * cut,
                       y: b.y + dy2 / len2 * cut)
    else:
      result.add b
  result.add wire.points[^1]

proc roundedPath(pts: seq[Point], radius: float): string =
  ## An SVG path following `pts` with each interior corner rounded to at most
  ## `radius` (never more than half of either adjacent leg). The `wkChain` arc
  ## uses it -- a renderer-only smoothing of routed orthogonal points, the same
  ## treatment `chamferedWirePoints` gives at 4 units, at a larger radius and
  ## with a curve rather than a bevel.
  if pts.len < 2: return ""
  var d = "M " & num(pts[0].x) & " " & num(pts[0].y)
  if pts.len == 2:
    return d & " L " & num(pts[1].x) & " " & num(pts[1].y)
  for i in 1 ..< pts.high:
    let a = pts[i - 1]
    let b = pts[i]
    let c = pts[i + 1]
    let ab = b - a
    let bc = c - b
    let lab = sqrt(ab.x * ab.x + ab.y * ab.y)
    let lbc = sqrt(bc.x * bc.x + bc.y * bc.y)
    if lab < 1e-9 or lbc < 1e-9:
      d.add " L " & num(b.x) & " " & num(b.y)
      continue
    let r = min(radius, min(lab, lbc) / 2.0)
    let p1 = Point(x: b.x - ab.x / lab * r, y: b.y - ab.y / lab * r)
    let p2 = Point(x: b.x + bc.x / lbc * r, y: b.y + bc.y / lbc * r)
    d.add " L " & num(p1.x) & " " & num(p1.y)
    d.add " Q " & num(b.x) & " " & num(b.y) & " " & num(p2.x) & " " & num(p2.y)
  d.add " L " & num(pts[^1].x) & " " & num(pts[^1].y)
  d

proc zigzag(cx, cy, hw: float, peaks: int): seq[Point] =
  result.add Point(x: cx - hw, y: cy)
  let dx = 2.0 * hw / float(peaks)
  var x = cx - hw
  for i in 0 ..< peaks - 1:
    x += dx
    result.add Point(x: x, y: cy + (if i mod 2 == 0: -10.0 else: 10.0))
  result.add Point(x: cx + hw, y: cy)

proc drawGrid(minX, minY, maxX, maxY: float): seq[string] =
  const step = 40.0
  var x = floor(minX / step) * step
  while x <= maxX:
    result.add "<line x1=\"" & num(x) & "\" y1=\"" & num(minY) &
      "\" x2=\"" & num(x) & "\" y2=\"" & num(maxY) &
      "\" stroke=\"#eef0f3\" stroke-width=\"1\"/>"
    x += step
  var y = floor(minY / step) * step
  while y <= maxY:
    result.add "<line x1=\"" & num(minX) & "\" y1=\"" & num(y) &
      "\" x2=\"" & num(maxX) & "\" y2=\"" & num(y) &
      "\" stroke=\"#eef0f3\" stroke-width=\"1\"/>"
    y += step

proc drawPart(p: SchematicPart): seq[string] =
  let cx = p.x
  let cy = p.y
  let hw = p.bodyW / 2.0
  let hh = p.bodyH / 2.0
  let rot = if abs(p.rotation) > 1e-9: p.rotation else: 0.0
  if rot != 0.0:
    # Rotate the body around the part centre. The pin slots were rotated by
    # the same SVG transform in `layout.rotatedSlot`, so the drawn symbol
    # lands exactly on the wire endpoints. Labels are added after the group
    # closes, deliberately outside it, so they stay upright.
    result.add "<g transform=\"rotate(" & num(rot) & " " & num(cx) & " " &
      num(cy) & ")\">"

  case p.symbol
  of "box":
    # `bodyW`/`bodyH` is the pin extent; the visible rectangle is inset by
    # `boxStub` so every pin juts out on a stub from the drawn edge, with its
    # name printed just inside.
    let bx = cx - hw + boxStub
    let by = cy - hh + boxStub
    result.add "<rect x=\"" & num(bx) & "\" y=\"" & num(by) &
      "\" width=\"" & num(p.bodyW - 2.0 * boxStub) &
      "\" height=\"" & num(p.bodyH - 2.0 * boxStub) &
      "\" fill=\"#fdfdfd\" stroke=\"#333333\" stroke-width=\"2\"/>"
    for pin in p.pins:
      # Outward escape unit vector, from which box edge the pin sits on.
      var ox, oy = 0.0
      if pin.x < bx + 1e-6: ox = -1.0
      elif pin.x > cx + hw - boxStub - 1e-6: ox = 1.0
      elif pin.y < by + 1e-6: oy = -1.0
      else: oy = 1.0
      if pin.x < bx + 1e-6:                       # left edge
        result.add lineAt(bx, pin.y, pin.x, pin.y)
        if pin.name.len > 0:
          result.add textAt(bx + 5.0, pin.y + 3.0, pin.name, "start", 9)
      elif pin.x > cx + hw - boxStub - 1e-6:      # right edge
        result.add lineAt(cx + hw - boxStub, pin.y, pin.x, pin.y)
        if pin.name.len > 0:
          result.add textAt(cx + hw - boxStub - 5.0, pin.y + 3.0, pin.name, "end", 9)
      elif pin.y < by + 1e-6:                     # top edge
        result.add lineAt(pin.x, by, pin.x, pin.y)
        if pin.name.len > 0:
          result.add textAt(pin.x, by + 12.0, pin.name, "middle", 9)
      else:                                       # bottom edge
        result.add lineAt(pin.x, cy + hh - boxStub, pin.x, pin.y)
        if pin.name.len > 0:
          result.add textAt(pin.x, cy + hh - boxStub - 6.0, pin.name, "middle", 9)
      # Array-collapse pin decoration: a bus-bar tick (common), a diagonal
      # slash + range tag (distributed), or a forked cap + count (irregular).
      if pin.mark != pmNone:
        let qx = -oy
        let qy = ox
        let tip = Point(x: pin.x + ox * 6.0, y: pin.y + oy * 6.0)
        case pin.mark
        of pmBusBar:
          result.add "<line x1=\"" & num(tip.x - qx * 8.0) & "\" y1=\"" &
            num(tip.y - qy * 8.0) & "\" x2=\"" & num(tip.x + qx * 8.0) &
            "\" y2=\"" & num(tip.y + qy * 8.0) &
            "\" stroke=\"#1f6feb\" stroke-width=\"4\"/>"
        of pmBusSlash:
          let m = Point(x: pin.x + ox * 12.0, y: pin.y + oy * 12.0)
          result.add "<line x1=\"" & num(m.x + (qx - ox) * 8.0) & "\" y1=\"" &
            num(m.y + (qy - oy) * 8.0) & "\" x2=\"" & num(m.x - (qx - ox) * 8.0) &
            "\" y2=\"" & num(m.y - (qy - oy) * 8.0) &
            "\" stroke=\"#1f6feb\" stroke-width=\"3\"/>"
          if pin.tag.len > 0:
            result.add textAt(m.x + qx * 12.0, m.y + qy * 12.0 + 3.0,
              pin.tag, "middle", 10)
        of pmForkCap:
          for d in [-8.0, 0.0, 8.0]:
            let e = Point(x: pin.x + ox * 18.0 + qx * d,
                          y: pin.y + oy * 18.0 + qy * d)
            let dashed = d > 0.0 and pin.tag.endsWith(" open")
            result.add "<line x1=\"" & num(tip.x) & "\" y1=\"" & num(tip.y) &
              "\" x2=\"" & num(e.x) & "\" y2=\"" & num(e.y) & "\" stroke=\"" &
              (if dashed: "#e67e22" else: "#333333") &
              "\" stroke-width=\"2\"" &
              (if dashed: " stroke-dasharray=\"4 3\"" else: "") & "/>"
            if dashed:
              result.add "<circle cx=\"" & num(e.x) & "\" cy=\"" & num(e.y) &
                "\" r=\"3\" fill=\"none\" stroke=\"#e67e22\" stroke-width=\"2\"/>"
          if pin.tag.len > 0:
            let label = pin.tag.replace(" open", "")
            result.add textAt(pin.x + ox * 22.0 + qx * 14.0,
              pin.y + oy * 22.0 + qy * 14.0 + 3.0, label, "middle", 10)
        of pmNone: discard
    # Designator and value/name stack at the top-left inside corner, clear of
    # the centred rows and columns of pin labels.
    result.add textAt(bx + 5.0, by + 13.0,
                      (if p.label.len > 0: p.label else: p.designator), "start")
    if p.count >= 2:
      result.add textAt(cx + hw - boxStub - 5.0, by + 13.0,
                        "x" & $p.count, "end")
    let sub = if p.value.len > 0: p.value
              elif p.name.len > 0: p.name
              else: p.kind
    if sub.len > 0:
      result.add textAt(bx + 5.0, by + 27.0, sub, "start", 10)

  of "resistor":
    result.add polyAt(zigzag(cx, cy, hw, 6))

  of "capacitor":
    result.add lineAt(cx - hw, cy, cx - 6.0, cy)
    result.add lineAt(cx + 6.0, cy, cx + hw, cy)
    result.add lineAt(cx - 6.0, cy - 12.0, cx - 6.0, cy + 12.0)
    result.add lineAt(cx + 6.0, cy - 12.0, cx + 6.0, cy + 12.0)

  of "inductor":
    result.add lineAt(cx - hw, cy, cx - 14.0, cy)
    result.add lineAt(cx + 14.0, cy, cx + hw, cy)
    var d = "M " & num(cx - 14.0) & " " & num(cy)
    let seg = 28.0 / 3.0
    var x = cx - 14.0
    for i in 0 ..< 3:
      let sweep = (if i mod 2 == 0: 1 else: 0)
      d &= " A " & num(seg / 2.0) & " " & num(seg / 2.0) & " 0 0 " & $sweep &
           " " & num(x + seg) & " " & num(cy)
      x += seg
    result.add "<path d=\"" & d & "\" fill=\"none\" stroke=\"#333333\" stroke-width=\"2\"/>"

  of "diode":
    result.add lineAt(cx - hw, cy, cx - 8.0, cy)
    result.add lineAt(cx + 8.0, cy, cx + hw, cy)
    result.add "<polygon points=\"" & num(cx - 8.0) & "," & num(cy - 10.0) & " " &
      num(cx - 8.0) & "," & num(cy + 10.0) & " " &
      num(cx + 8.0) & "," & num(cy) &
      "\" fill=\"none\" stroke=\"#333333\" stroke-width=\"2\"/>"
    result.add lineAt(cx + 8.0, cy - 10.0, cx + 8.0, cy + 10.0)

  of "passive":
    result.add lineAt(cx - hw, cy, cx - 8.0, cy)
    result.add lineAt(cx + 8.0, cy, cx + hw, cy)
    result.add "<rect x=\"" & num(cx - 8.0) & "\" y=\"" & num(cy - 12.0) &
      "\" width=\"16\" height=\"24\" fill=\"#ffffff\" stroke=\"#333333\" stroke-width=\"2\"/>"

  of "voltage_source":
    result.add lineAt(cx, cy - hh, cx, cy - 16.0)
    result.add lineAt(cx, cy + 16.0, cx, cy + hh)
    result.add "<circle cx=\"" & num(cx) & "\" cy=\"" & num(cy) &
      "\" r=\"16\" fill=\"#ffffff\" stroke=\"#333333\" stroke-width=\"2\"/>"
    result.add lineAt(cx - 6.0, cy - 7.0, cx + 6.0, cy - 7.0)
    result.add lineAt(cx, cy - 10.0, cx, cy - 4.0)
    result.add lineAt(cx - 6.0, cy + 7.0, cx + 6.0, cy + 7.0)

  of "current_source":
    result.add lineAt(cx, cy - hh, cx, cy - 16.0)
    result.add lineAt(cx, cy + 16.0, cx, cy + hh)
    result.add "<circle cx=\"" & num(cx) & "\" cy=\"" & num(cy) &
      "\" r=\"16\" fill=\"#ffffff\" stroke=\"#333333\" stroke-width=\"2\"/>"
    result.add lineAt(cx, cy - 6.0, cx, cy + 6.0)
    result.add "<polygon points=\"" & num(cx) & "," & num(cy + 6.0) & " " &
      num(cx - 4.0) & "," & num(cy + 1.0) & " " &
      num(cx + 4.0) & "," & num(cy + 1.0) & "\" fill=\"#333333\"/>"

  of "source4":
    # A rectangular buffer/controlled source: OUT+/OUT- on the right edge,
    # IN+/IN- on the left edge, each labelled inside the body. No source-type
    # polarity/arrow marker -- the labels carry the pin identity instead.
    result.add "<rect x=\"" & num(cx - hw) & "\" y=\"" & num(cy - hh) &
      "\" width=\"" & num(p.bodyW) & "\" height=\"" & num(p.bodyH) &
      "\" fill=\"#ffffff\" stroke=\"#333333\" stroke-width=\"2\"/>"
    result.add textAt(cx - hw + 6.0, cy - 12.0, "IN+", "start", 10)
    result.add textAt(cx - hw + 6.0, cy + 16.0, "IN-", "start", 10)
    result.add textAt(cx + hw - 6.0, cy - 12.0, "OUT+", "end", 10)
    result.add textAt(cx + hw - 6.0, cy + 16.0, "OUT-", "end", 10)

  of "transistor":
    result.add lineAt(cx, cy - hh, cx, cy - 16.0)
    result.add lineAt(cx - hh, cy, cx - 16.0, cy)
    result.add lineAt(cx, cy + 16.0, cx, cy + hh)
    result.add "<circle cx=\"" & num(cx) & "\" cy=\"" & num(cy) &
      "\" r=\"16\" fill=\"#ffffff\" stroke=\"#333333\" stroke-width=\"2\"/>"
    result.add lineAt(cx - 16.0, cy - 12.0, cx - 16.0, cy + 12.0)

  else:
    # Should not happen -- `layout` only emits the names above -- but a
    # graceful box beats a blank for a symbol registry extended later.
    result.add "<rect x=\"" & num(cx - 16.0) & "\" y=\"" & num(cy - 16.0) &
      "\" width=\"32\" height=\"32\" fill=\"#ffffff\" stroke=\"#333333\" stroke-width=\"2\"/>"

  if rot != 0.0:
    result.add "</g>"

  # A non-box symbol's designator and value are emitted as SchematicLabels by
  # `layout`'s label pass (placed against wires and neighbouring bodies), not
  # drawn here. A box draws its own designator/value inside the body above,
  # where `boxSlots` has reserved the space.

proc drawPort(p: SchematicPort): seq[string] =
  ## An Altium-style port pennant at `p.x, p.y` (its body centre). The
  ## connecting stub is a separate wire in the scene, meeting the pennant at
  ## the edge `layout` sized it to: the pointed end for an input, unspecified
  ## or bidirectional port, the flat end for an output. Signal reads left to
  ## right, so every arrow points right.
  let y = p.y
  let h = p.bodyH / 2.0
  let left = p.x - p.bodyW / 2.0
  let right = p.x + p.bodyW / 2.0
  const tip = 8.0
  var pts: seq[Point]
  case p.dir
  of pdInput, pdOutput:
    pts = @[Point(x: left, y: y - h), Point(x: right - tip, y: y - h),
            Point(x: right, y: y), Point(x: right - tip, y: y + h),
            Point(x: left, y: y + h)]
  of pdBidir:
    pts = @[Point(x: left, y: y), Point(x: left + tip, y: y - h),
            Point(x: right - tip, y: y - h), Point(x: right, y: y),
            Point(x: right - tip, y: y + h), Point(x: left + tip, y: y + h)]
  of pdUnspecified:
    pts = @[Point(x: left, y: y - h), Point(x: right, y: y - h),
            Point(x: right, y: y + h), Point(x: left, y: y + h)]
  result.add "<polygon points=\"" & pointsAttr(pts) &
    "\" fill=\"#ffffff\" stroke=\"#333333\" stroke-width=\"2\"/>"
  result.add textAt(p.x, y + 4.0, p.name, "middle", 10)

proc chevronCap(tip: Point, outward: Point): string =
  ## A two-segment "<" pointing back along `outward` at `tip` -- the solid cap
  ## that tells a deliberate net-label tag apart from a routing failure's open
  ## circle. `outward` is the stub's own leaving direction (unit ±x / ±y).
  let o =
    if abs(outward.x) >= abs(outward.y) and outward.x != 0.0:
      Point(x: (if outward.x > 0.0: 1.0 else: -1.0), y: 0.0)
    elif outward.y != 0.0:
      Point(x: 0.0, y: (if outward.y > 0.0: 1.0 else: -1.0))
    else:
      Point(x: 1.0, y: 0.0)
  let q = Point(x: -o.y, y: o.x)
  let b = tip - o * 6.0
  "<polyline fill=\"none\" stroke=\"#0f7b6c\" stroke-width=\"2\" points=\"" &
    pointsAttr(@[b + q * 5.0, tip, b - q * 5.0]) & "\"/>"

proc drawFallback(f: SchematicFallback): seq[string] =
  ## `fbUnrouted`: a dashed amber stub plus an open-endpoint marker -- "this
  ## net is here, and is deliberately not connected" rather than copper.
  ## `fbNetLabel`: a solid teal stub plus a chevron cap -- "this net is
  ## carried by name" (a bus/interface broken out or an unroutable bundle).
  ## Both never join the occupancy set. A zero-space fallback (empty `points`)
  ## draws only the cap at the pin.
  case f.kind
  of fbUnrouted:
    const amber = "#e67e22"
    if f.points.len >= 2:
      result.add "<polyline fill=\"none\" stroke=\"" & amber &
        "\" stroke-width=\"2\" stroke-dasharray=\"6 4\" points=\"" &
        pointsAttr(f.points) & "\"/>"
      let e = f.points[^1]
      result.add "<circle cx=\"" & num(e.x) & "\" cy=\"" & num(e.y) &
        "\" r=\"4\" fill=\"#ffffff\" stroke=\"" & amber & "\" stroke-width=\"2\"/>"
    else:
      result.add "<circle cx=\"" & num(f.x) & "\" cy=\"" & num(f.y) &
        "\" r=\"4\" fill=\"#ffffff\" stroke=\"" & amber & "\" stroke-width=\"2\"/>"
  of fbNetLabel:
    const teal = "#0f7b6c"
    if f.points.len >= 2:
      result.add "<polyline fill=\"none\" stroke=\"" & teal &
        "\" stroke-width=\"2\" points=\"" & pointsAttr(f.points) & "\"/>"
      result.add chevronCap(f.points[^1], f.points[^1] - f.points[^2])
    else:
      result.add chevronCap(Point(x: f.x, y: f.y), Point(x: f.ex, y: f.ey))

proc drawChainArc(wire: SchematicWire): seq[string] =
  ## A collapsed array's recirculation arc: a dashed `#6e7781` staple over the
  ## box body from the OUT pin to its lined-up IN pin, an arrowhead into the IN
  ## end, and -- when `members` is non-empty (the lead of a parallel-chain
  ## group) -- an `xN` link-count badge at the midpoint of its longest segment.
  ## Drawn after the parts so the box fill does not cover it.
  if wire.points.len < 2: return
  result.add "<path d=\"" & roundedPath(wire.points, 9.0) &
    "\" fill=\"none\" stroke=\"#6e7781\" stroke-width=\"2\" stroke-dasharray=\"6 4\"/>"
  block:
    let tip = wire.points[^1]
    let d = tip - wire.points[^2]
    let n = max(abs(d.x) + abs(d.y), 1e-6)
    let ux = d.x / n
    let uy = d.y / n
    result.add "<polyline fill=\"none\" stroke=\"#6e7781\" stroke-width=\"2\" points=\"" &
      num(tip.x - ux * 7.0 - uy * 4.0) & "," & num(tip.y - uy * 7.0 + ux * 4.0) & " " &
      num(tip.x) & "," & num(tip.y) & " " &
      num(tip.x - ux * 7.0 + uy * 4.0) & "," & num(tip.y - uy * 7.0 - ux * 4.0) & "\"/>"
  if wire.members.len > 0:
    var bi = 0
    var blen = -1.0
    for k in 0 ..< wire.points.high:
      let seg = wire.points[k + 1] - wire.points[k]
      let sl = abs(seg.x) + abs(seg.y)
      if sl > blen:
        blen = sl
        bi = k
    let mx = (wire.points[bi].x + wire.points[bi + 1].x) / 2.0
    let my = (wire.points[bi].y + wire.points[bi + 1].y) / 2.0
    result.add textAt(mx, my - 4.0, "x" & $wire.members.len, "middle", 11)

proc renderSvg*(s: Schematic): string =
  ## The whole scene as one self-contained SVG document.
  let w = s.maxX - s.minX
  let h = s.maxY - s.minY
  var L: seq[string]
  L.add "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
  L.add "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & num(w) &
         "\" height=\"" & num(h) & "\" viewBox=\"" & num(s.minX) & " " &
         num(s.minY) & " " & num(w) & " " & num(h) & "\">"
  if s.title.len > 0:
    L.add "  <title>" & xmlEscape(s.title) & "</title>"
  L.add "  <rect x=\"" & num(s.minX) & "\" y=\"" & num(s.minY) &
         "\" width=\"" & num(w) & "\" height=\"" & num(h) & "\" fill=\"#ffffff\"/>"
  for g in drawGrid(s.minX, s.minY, s.maxX, s.maxY): L.add "  " & g

  for wire in s.wires:
    # The glyph at a ground/supply stub is drawn perpendicular to the stub, so
    # a stub that juts sideways or downward (a negative rail on a box's bottom
    # edge) still gets an upright bar rather than one laid across the wire.
    proc stubDirs(pts: seq[Point], fallback: Point): tuple[o, q: Point] =
      var o = fallback
      if pts.len >= 2:
        let d = pts[^1] - pts[^2]
        if abs(d.x) > abs(d.y) and abs(d.x) > 1e-6:
          o = Point(x: (if d.x >= 0.0: 1.0 else: -1.0), y: 0.0)
        elif abs(d.y) > 1e-6:
          o = Point(x: 0.0, y: (if d.y >= 0.0: 1.0 else: -1.0))
      (o: o, q: Point(x: -o.y, y: o.x))
    proc bar(c, q: Point, hw: float): string =
      lineAt(c.x - q.x * hw, c.y - q.y * hw, c.x + q.x * hw, c.y + q.y * hw)
    case wire.kind
    of wkSignal:
      L.add "  " & polyAt(chamferedWirePoints(wire, s.junctions))
    of wkBus, wkInterface:
      # Colour is membership (blue bus / purple interface), width is collapse
      # (>1 member -> one thick wire carrying the whole bundle). A lone
      # width-1 interface signal draws thin-but-purple.
      let col = if wire.kind == wkInterface: "#8250df" else: "#1f6feb"
      let wd = if wire.members.len > 1: "4" else: "2"
      L.add "  " & polyAt(chamferedWirePoints(wire, s.junctions), col, wd)
    of wkChain:
      discard   # drawn in a pass after the parts, so the box does not cover it
    of wkGround:
      L.add "  " & polyAt(chamferedWirePoints(wire, s.junctions))
      let p = wire.points[^1]
      let (o, q) = stubDirs(wire.points, Point(x: 0.0, y: 1.0))
      L.add "  " & bar(p, q, 10.0)
      L.add "  " & bar(p + o * 4.0, q, 6.0)
      L.add "  " & bar(p + o * 8.0, q, 2.0)
    of wkSupply:
      L.add "  " & polyAt(chamferedWirePoints(wire, s.junctions))
      let p = wire.points[^1]
      let (_, q) = stubDirs(wire.points, Point(x: 0.0, y: -1.0))
      L.add "  " & bar(p, q, 10.0)
      # The rail's net name is emitted as an `lrRail` SchematicLabel by
      # `layout` (placed against the finished geometry), not drawn here.

  # Fallback stubs are drawn with the wires -- before junction dots and
  # symbols -- so a marker under a body stays under its white fill, exactly
  # like a real wire would.
  for f in s.fallbacks:
    for e in drawFallback(f): L.add "  " & e

  # Junction dots are painted right after the wires and before any symbol:
  # a dot marks where three or more segments of one net meet, so it must sit
  # on top of the wires it joins, but under a part body or port pennant should
  # one ever touch it (a symbol's white fill is the foreground).
  for j in s.junctions:
    L.add "  <circle cx=\"" & num(j.x) & "\" cy=\"" & num(j.y) &
      "\" r=\"3\" fill=\"#333333\"/>"

  for p in s.parts:
    for e in drawPart(p): L.add "  " & e

  for p in s.ports:
    for e in drawPort(p): L.add "  " & e

  # Recirculation arcs sit on the box body, so they are drawn last -- after the
  # opaque box fill that would otherwise hide them.
  for wire in s.wires:
    if wire.kind == wkChain:
      for e in drawChainArc(wire): L.add "  " & e

  for lb in s.labels:
    let sz = if lb.size > 0.0: int(lb.size.round) else: 12
    L.add "  " & textAt(lb.x, lb.y, lb.text, anchorName(lb.anchor), sz)

  L.add "</svg>"
  result = L.join("\n") & "\n"

proc renderSvg*(nl: Netlist): string =
  ## Convenience: lay out `nl` and render it.
  renderSvg(layout(nl))

proc writeSvgFile*(s: Schematic, path: string) =
  let f = open(path, fmWrite)
  defer: f.close()
  f.write(renderSvg(s))

proc writeSvgFile*(nl: Netlist, path: string) =
  writeSvgFile(layout(nl), path)
