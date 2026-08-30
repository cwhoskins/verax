## Public JSON API for a `Schematic`.
##
## The scene is serialized as plain JSON so the same placement/routing that
## produces an SVG is also consumable by a future interactive frontend
## (pan/zoom/hover, per the design notes) without re-parsing the SVG. This is
## a *writer beside the SVG writer*, not a replacement: the archive stays
## SVG-only; this API exists for callers who want the scene programmatically.

import std/json
import ../netlist/types
import ./scene
import ./layout

proc wireKindName(k: WireKind): string =
  case k
  of wkSignal: "signal"
  of wkGround: "ground"
  of wkSupply: "supply"

proc textAnchorName(a: TextAnchor): string =
  case a
  of taStart: "start"
  of taMiddle: "middle"
  of taEnd: "end"

proc labelRoleName(r: LabelRole): string =
  case r
  of lrNet: "net"
  of lrDesignator: "designator"
  of lrValue: "value"
  of lrRail: "rail"

proc portDirName(d: PortDirection): string =
  case d
  of pdUnspecified: "unspecified"
  of pdInput: "input"
  of pdOutput: "output"
  of pdBidir: "bidir"

proc sceneToJson*(s: Schematic): JsonNode =
  result = newJObject()
  result["title"] = %s.title
  result["minX"] = %s.minX
  result["minY"] = %s.minY
  result["maxX"] = %s.maxX
  result["maxY"] = %s.maxY

  var parts = newJArray()
  for p in s.parts:
    var o = newJObject()
    o["designator"] = %p.designator
    o["kind"] = %p.kind
    o["name"] = %p.name
    o["value"] = %p.value
    o["symbol"] = %p.symbol
    o["isBox"] = %p.isBox
    o["inkW"] = %p.inkW
    o["inkH"] = %p.inkH
    o["x"] = %p.x
    o["y"] = %p.y
    o["rotation"] = %p.rotation
    var pins = newJArray()
    for pin in p.pins:
      var po = newJObject()
      po["name"] = %pin.name
      po["net"] = %pin.net
      po["x"] = %pin.x
      po["y"] = %pin.y
      pins.add po
    o["pins"] = pins
    parts.add o
  result["parts"] = parts

  var wires = newJArray()
  for w in s.wires:
    var wo = newJObject()
    wo["net"] = %w.net
    wo["kind"] = %wireKindName(w.kind)
    var pts = newJArray()
    for pt in w.points:
      var pto = newJObject()
      pto["x"] = %pt.x
      pto["y"] = %pt.y
      pts.add pto
    wo["points"] = pts
    wires.add wo
  result["wires"] = wires

  var junctions = newJArray()
  for j in s.junctions:
    var jo = newJObject()
    jo["net"] = %j.net
    jo["x"] = %j.x
    jo["y"] = %j.y
    junctions.add jo
  result["junctions"] = junctions

  var labels = newJArray()
  for lb in s.labels:
    var lo = newJObject()
    lo["text"] = %lb.text
    lo["x"] = %lb.x
    lo["y"] = %lb.y
    lo["anchor"] = %textAnchorName(lb.anchor)
    lo["size"] = %lb.size
    lo["role"] = %labelRoleName(lb.role)
    lo["owner"] = %lb.owner
    labels.add lo
  result["labels"] = labels

  var ports = newJArray()
  for pt in s.ports:
    var o = newJObject()
    o["name"] = %pt.name
    o["net"] = %pt.net
    o["dir"] = %portDirName(pt.dir)
    o["x"] = %pt.x
    o["y"] = %pt.y
    o["bodyW"] = %pt.bodyW
    o["bodyH"] = %pt.bodyH
    o["rotation"] = %pt.rotation
    ports.add o
  result["ports"] = ports

  var fallbacks = newJArray()
  for f in s.fallbacks:
    var o = newJObject()
    o["net"] = %f.net
    o["part"] = %f.part
    o["pin"] = %f.pin
    o["x"] = %f.x
    o["y"] = %f.y
    var pts = newJArray()
    for pt in f.points:
      var pto = newJObject()
      pto["x"] = %pt.x
      pto["y"] = %pt.y
      pts.add pto
    o["points"] = pts
    fallbacks.add o
  result["fallbacks"] = fallbacks

proc sceneToJson*(nl: Netlist): JsonNode =
  ## Convenience: lay out `nl` and serialize the scene.
  sceneToJson(layout(nl))

proc sceneToJsonString*(s: Schematic, pretty = true): string =
  if pretty: s.sceneToJson().pretty(2)
  else: $(s.sceneToJson())

proc sceneToJsonString*(nl: Netlist, pretty = true): string =
  sceneToJsonString(layout(nl), pretty)

proc writeSceneJsonFile*(s: Schematic, path: string) =
  let f = open(path, fmWrite)
  defer: f.close()
  f.write(sceneToJsonString(s, pretty = true))

proc writeSceneJsonFile*(nl: Netlist, path: string) =
  writeSceneJsonFile(layout(nl), path)
