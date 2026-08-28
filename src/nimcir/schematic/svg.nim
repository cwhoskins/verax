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

proc textAt(x, y: float, s: string, anchor = "start", size = 12): string =
  "<text x=\"" & num(x) & "\" y=\"" & num(y) &
    "\" font-family=\"monospace\" font-size=\"" & $size &
    "\" fill=\"#333333\" text-anchor=\"" & anchor & "\">" &
    xmlEscape(s) & "</text>"

proc lineAt(x1, y1, x2, y2: float): string =
  "<line x1=\"" & num(x1) & "\" y1=\"" & num(y1) &
    "\" x2=\"" & num(x2) & "\" y2=\"" & num(y2) &
    "\" stroke=\"#333333\" stroke-width=\"2\"/>"

proc polyAt(pts: seq[Point]): string =
  "<polyline fill=\"none\" stroke=\"#333333\" stroke-width=\"2\" points=\"" &
    pointsAttr(pts) & "\"/>"

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
    result.add "<rect x=\"" & num(cx - hw) & "\" y=\"" & num(cy - hh) &
      "\" width=\"" & num(p.bodyW) & "\" height=\"" & num(p.bodyH) &
      "\" fill=\"#fdfdfd\" stroke=\"#333333\" stroke-width=\"2\"/>"
    result.add textAt(cx, cy - 4.0, p.designator, "middle")
    let sub = if p.value.len > 0: p.value
              elif p.name.len > 0: p.name
              else: p.kind
    if sub.len > 0: result.add textAt(cx, cy + 12.0, sub, "middle", 10)

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
    result.add "<polygon points=\"" & num(cx - 8.0) & "," & num(cy) & " " &
      num(cx + 4.0) & "," & num(cy - 10.0) & " " &
      num(cx + 4.0) & "," & num(cy + 10.0) &
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

  if p.symbol != "box":
    result.add textAt(cx, cy - hh - 12.0, p.designator, "middle")
    if p.value.len > 0:
      result.add textAt(cx, cy + hh + 16.0, p.value, "middle", 10)

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
    case wire.kind
    of wkSignal:
      L.add "  " & polyAt(wire.points)
    of wkGround:
      L.add "  " & polyAt(wire.points)
      let p = wire.points[^1]
      L.add "  " & lineAt(p.x - 10.0, p.y, p.x + 10.0, p.y)
      L.add "  " & lineAt(p.x - 6.0, p.y + 4.0, p.x + 6.0, p.y + 4.0)
      L.add "  " & lineAt(p.x - 2.0, p.y + 8.0, p.x + 2.0, p.y + 8.0)
    of wkSupply:
      L.add "  " & polyAt(wire.points)
      let p = wire.points[^1]
      L.add "  " & lineAt(p.x - 10.0, p.y, p.x + 10.0, p.y)
      if wire.net.len > 0:
        L.add "  " & textAt(p.x + 14.0, p.y + 4.0, wire.net)

  for p in s.parts:
    for e in drawPart(p): L.add "  " & e

  for p in s.ports:
    for e in drawPort(p): L.add "  " & e

  for j in s.junctions:
    L.add "  <circle cx=\"" & num(j.x) & "\" cy=\"" & num(j.y) &
      "\" r=\"3\" fill=\"#333333\"/>"

  for lb in s.labels:
    L.add "  " & textAt(lb.x, lb.y, lb.text)

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
