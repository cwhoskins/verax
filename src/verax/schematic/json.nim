## Public JSON API for a `Schematic`: writer *and* reader.
##
## The scene is serialized as plain JSON so the same placement/routing that
## produces an SVG is also consumable by a future interactive frontend
## (pan/zoom/hover, per the design notes) without re-parsing the SVG, and so a
## scene archived beside an SVG (`runNNN.json`, `runFULL.json`, child sheets)
## can be read back for diagnostics that need the routed geometry but not the
## netlist graph. The writer emits `schemaVersion` 1 with every `Schematic`
## field present; the reader is strict for version 1 (missing or mistyped
## fields raise `SceneJsonError`) and also reads the legacy *unversioned*
## archive format honestly: that format predates both `schemaVersion` and the
## fallback `ex`/`ey` escape direction, so the reader reconstructs the escape
## direction from the scene's own part/port geometry -- `(0, 0)` when the
## scene cannot identify the owning pin or port, never an invented direction.

import std/json
import ../netlist/types
import ./scene
import ./layout

const sceneSchemaVersion* = 1
  ## The JSON schema version this module writes and reads. Version 1 is the
  ## complete scene (every `Schematic` field). JSON without `schemaVersion`
  ## is the legacy unversioned archive format and is still read, with the one
  ## missing piece (fallback `ex`/`ey`) reconstructed rather than invented.

type
  SceneJsonError* = object of CatchableError
    ## Raised by the strict reader on malformed or unsupported scene JSON.
    ## `msg` names the offending field.

proc fail(msg: string) {.noreturn.} =
  raise newException(SceneJsonError, msg)

proc wireKindName(k: WireKind): string =
  case k
  of wkSignal: "signal"
  of wkGround: "ground"
  of wkSupply: "supply"
  of wkBus: "bus"
  of wkInterface: "interface"
  of wkChain: "chain"
  of wkPowerLink: "powerlink"

proc wireKindFromName(s: string): WireKind =
  case s
  of "signal": wkSignal
  of "ground": wkGround
  of "supply": wkSupply
  of "bus": wkBus
  of "interface": wkInterface
  of "chain": wkChain
  of "powerlink": wkPowerLink
  else: fail("scene JSON: field \"kind\" has unknown wire kind \"" & s & "\"")

proc pinMarkName(m: PinMark): string =
  case m
  of pmNone: "none"
  of pmBusBar: "busbar"
  of pmBusSlash: "busslash"
  of pmForkCap: "forkcap"

proc pinMarkFromName(s: string): PinMark =
  case s
  of "none": pmNone
  of "busbar": pmBusBar
  of "busslash": pmBusSlash
  of "forkcap": pmForkCap
  else: fail("scene JSON: field \"mark\" has unknown pin mark \"" & s & "\"")

proc fallbackKindName(k: FallbackKind): string =
  case k
  of fbUnrouted: "unrouted"
  of fbNetLabel: "netlabel"

proc fallbackKindFromName(s: string): FallbackKind =
  case s
  of "unrouted": fbUnrouted
  of "netlabel": fbNetLabel
  else: fail("scene JSON: field \"kind\" has unknown fallback kind \"" & s & "\"")

proc textAnchorName(a: TextAnchor): string =
  case a
  of taStart: "start"
  of taMiddle: "middle"
  of taEnd: "end"

proc textAnchorFromName(s: string): TextAnchor =
  case s
  of "start": taStart
  of "middle": taMiddle
  of "end": taEnd
  else: fail("scene JSON: field \"anchor\" has unknown text anchor \"" & s & "\"")

proc labelRoleName(r: LabelRole): string =
  case r
  of lrNet: "net"
  of lrDesignator: "designator"
  of lrValue: "value"
  of lrRail: "rail"

proc labelRoleFromName(s: string): LabelRole =
  case s
  of "net": lrNet
  of "designator": lrDesignator
  of "value": lrValue
  of "rail": lrRail
  else: fail("scene JSON: field \"role\" has unknown label role \"" & s & "\"")

proc portDirName(d: PortDirection): string =
  case d
  of pdUnspecified: "unspecified"
  of pdInput: "input"
  of pdOutput: "output"
  of pdBidir: "bidir"

proc portDirFromName(s: string): PortDirection =
  case s
  of "unspecified": pdUnspecified
  of "input": pdInput
  of "output": pdOutput
  of "bidir": pdBidir
  else: fail("scene JSON: field \"dir\" has unknown port direction \"" & s & "\"")

proc membersJson(members: seq[BundleMember]): JsonNode =
  result = newJArray()
  for m in members:
    var o = newJObject()
    o["name"] = %m.name
    o["net"] = %m.net
    result.add o

proc sceneToJson*(s: Schematic): JsonNode =
  result = newJObject()
  result["schemaVersion"] = %sceneSchemaVersion
  result["title"] = %s.title
  result["minX"] = %s.minX
  result["minY"] = %s.minY
  result["maxX"] = %s.maxX
  result["maxY"] = %s.maxY

  var parts = newJArray()
  for p in s.parts:
    var o = newJObject()
    o["designator"] = %p.designator
    o["label"] = %p.label
    o["kind"] = %p.kind
    o["name"] = %p.name
    o["value"] = %p.value
    o["symbol"] = %p.symbol
    o["isBox"] = %p.isBox
    o["bodyW"] = %p.bodyW
    o["bodyH"] = %p.bodyH
    o["inkW"] = %p.inkW
    o["inkH"] = %p.inkH
    o["x"] = %p.x
    o["y"] = %p.y
    o["rotation"] = %p.rotation
    if p.count > 0: o["count"] = %p.count
    if p.members.len > 0:
      var ms = newJArray()
      for m in p.members: ms.add %m
      o["members"] = ms
    var pins = newJArray()
    for pin in p.pins:
      var po = newJObject()
      po["name"] = %pin.name
      po["net"] = %pin.net
      po["x"] = %pin.x
      po["y"] = %pin.y
      if pin.members.len > 0: po["members"] = membersJson(pin.members)
      if pin.mark != pmNone: po["mark"] = %pinMarkName(pin.mark)
      if pin.tag.len > 0: po["tag"] = %pin.tag
      pins.add po
    o["pins"] = pins
    parts.add o
  result["parts"] = parts

  var wires = newJArray()
  for w in s.wires:
    var wo = newJObject()
    wo["net"] = %w.net
    wo["kind"] = %wireKindName(w.kind)
    if w.members.len > 0:
      var ms = newJArray()
      for m in w.members: ms.add %m
      wo["members"] = ms
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
    if pt.members.len > 0: o["members"] = membersJson(pt.members)
    ports.add o
  result["ports"] = ports

  var fallbacks = newJArray()
  for f in s.fallbacks:
    var o = newJObject()
    if f.kind != fbUnrouted: o["kind"] = %fallbackKindName(f.kind)
    if f.bundle.len > 0: o["bundle"] = %f.bundle
    o["net"] = %f.net
    o["part"] = %f.part
    o["pin"] = %f.pin
    o["x"] = %f.x
    o["y"] = %f.y
    o["ex"] = %f.ex
    o["ey"] = %f.ey
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

# --- strict reader ----------------------------------------------------------

proc reqStr(n: JsonNode, key: string): string =
  if not n.hasKey(key): fail("scene JSON: missing field \"" & key & "\"")
  if n[key].kind != JString:
    fail("scene JSON: field \"" & key & "\" must be a string")
  n[key].str

proc optStr(n: JsonNode, key: string): string =
  ## An additive string field: `""` when absent (so an archive written before
  ## the field existed still parses), but type-checked when present.
  if not n.hasKey(key): return ""
  if n[key].kind != JString:
    fail("scene JSON: field \"" & key & "\" must be a string")
  n[key].str

proc optInt(n: JsonNode, key: string): int =
  ## An additive integer field: 0 when absent (so an archive written before
  ## the field existed still parses), type-checked when present. Beside
  ## `optStr`/`optArr` -- the same additive contract, for the subsheet-array
  ## instance count.
  if not n.hasKey(key): return 0
  if n[key].kind != JInt:
    fail("scene JSON: field \"" & key & "\" must be an integer")
  int(n[key].num)

proc optArr(n: JsonNode, key: string): JsonNode =
  ## An additive array field: an empty `JArray` when absent (so an archive
  ## written before the field existed still parses), but type-checked when
  ## present. Beside `optStr` -- the same additive contract, for the bundle
  ## member lists added with buses/interfaces.
  if not n.hasKey(key): return newJArray()
  if n[key].kind != JArray:
    fail("scene JSON: field \"" & key & "\" must be an array")
  n[key]

proc optBundleMembers(n: JsonNode, key: string): seq[BundleMember] =
  for m in optArr(n, key):
    if m.kind != JObject: fail("scene JSON: bundle member must be an object")
    result.add BundleMember(name: reqStr(m, "name"), net: reqStr(m, "net"))

proc reqBool(n: JsonNode, key: string): bool =
  if not n.hasKey(key): fail("scene JSON: missing field \"" & key & "\"")
  if n[key].kind != JBool:
    fail("scene JSON: field \"" & key & "\" must be a boolean")
  n[key].bval

proc reqFloat(n: JsonNode, key: string): float =
  if not n.hasKey(key): fail("scene JSON: missing field \"" & key & "\"")
  case n[key].kind
  of JInt: float(n[key].num)
  of JFloat: n[key].fnum
  else: fail("scene JSON: field \"" & key & "\" must be a number")

proc reqArr(n: JsonNode, key: string): JsonNode =
  if not n.hasKey(key): fail("scene JSON: missing field \"" & key & "\"")
  if n[key].kind != JArray:
    fail("scene JSON: field \"" & key & "\" must be an array")
  n[key]

proc reqPoint(n: JsonNode): Point =
  ## Reads a `{"x": float, "y": float}` object strictly.
  if n.kind != JObject: fail("scene JSON: point must be an object")
  Point(x: reqFloat(n, "x"), y: reqFloat(n, "y"))

proc jsonToScene*(node: JsonNode): Schematic =
  ## The strict inverse of `sceneToJson`: reads a version-1 scene, requiring
  ## every field and checking every type, raising `SceneJsonError` on anything
  ## malformed or on a `schemaVersion` this reader does not know.
  ##
  ## JSON without `schemaVersion` is read as the legacy unversioned archive
  ## format: every field is still required except the fallback `ex`/`ey`
  ## escape direction, which that format never stored and which is
  ## reconstructed from the scene's part/port geometry (see
  ## `layout.fallbackEscapeDir`).
  if node.kind != JObject:
    fail("scene JSON: root must be an object")

  var version = -1          # -1 = legacy unversioned archive
  if node.hasKey("schemaVersion"):
    let v = node["schemaVersion"]
    if v.kind != JInt:
      fail("scene JSON: schemaVersion must be an integer")
    version = int(v.num)
    if version != sceneSchemaVersion:
      fail("scene JSON: unsupported schemaVersion " & $version &
           " (this reader supports " & $sceneSchemaVersion &
           " and the legacy unversioned format)")

  result.title = reqStr(node, "title")
  result.minX = reqFloat(node, "minX")
  result.minY = reqFloat(node, "minY")
  result.maxX = reqFloat(node, "maxX")
  result.maxY = reqFloat(node, "maxY")

  for pn in reqArr(node, "parts"):
    if pn.kind != JObject: fail("scene JSON: part must be an object")
    var p = SchematicPart(
      designator: reqStr(pn, "designator"),
      label: optStr(pn, "label"),
      kind: reqStr(pn, "kind"),
      name: reqStr(pn, "name"),
      value: reqStr(pn, "value"),
      symbol: reqStr(pn, "symbol"),
      isBox: reqBool(pn, "isBox"),
      bodyW: reqFloat(pn, "bodyW"),
      bodyH: reqFloat(pn, "bodyH"),
      inkW: reqFloat(pn, "inkW"),
      inkH: reqFloat(pn, "inkH"),
      x: reqFloat(pn, "x"),
      y: reqFloat(pn, "y"),
      rotation: reqFloat(pn, "rotation"),
      count: optInt(pn, "count"))
    for m in optArr(pn, "members"):
      if m.kind != JString: fail("scene JSON: part member must be a string")
      p.members.add m.str
    for pin in reqArr(pn, "pins"):
      if pin.kind != JObject: fail("scene JSON: pin must be an object")
      p.pins.add SchematicPin(
        name: reqStr(pin, "name"),
        net: reqStr(pin, "net"),
        x: reqFloat(pin, "x"),
        y: reqFloat(pin, "y"),
        members: optBundleMembers(pin, "members"),
        mark: (if pin.hasKey("mark"): pinMarkFromName(reqStr(pin, "mark"))
               else: pmNone),
        tag: optStr(pin, "tag"))
    result.parts.add p

  for wn in reqArr(node, "wires"):
    if wn.kind != JObject: fail("scene JSON: wire must be an object")
    var w = SchematicWire(net: reqStr(wn, "net"),
                          kind: wireKindFromName(reqStr(wn, "kind")))
    for m in optArr(wn, "members"):
      if m.kind != JString: fail("scene JSON: wire member must be a string")
      w.members.add m.str
    for pt in reqArr(wn, "points"):
      w.points.add reqPoint(pt)
    result.wires.add w

  for jn in reqArr(node, "junctions"):
    if jn.kind != JObject: fail("scene JSON: junction must be an object")
    result.junctions.add SchematicJunction(
      net: reqStr(jn, "net"),
      x: reqFloat(jn, "x"),
      y: reqFloat(jn, "y"))

  for ln in reqArr(node, "labels"):
    if ln.kind != JObject: fail("scene JSON: label must be an object")
    result.labels.add SchematicLabel(
      text: reqStr(ln, "text"),
      x: reqFloat(ln, "x"),
      y: reqFloat(ln, "y"),
      anchor: textAnchorFromName(reqStr(ln, "anchor")),
      size: reqFloat(ln, "size"),
      role: labelRoleFromName(reqStr(ln, "role")),
      owner: reqStr(ln, "owner"))

  for ptn in reqArr(node, "ports"):
    if ptn.kind != JObject: fail("scene JSON: port must be an object")
    result.ports.add SchematicPort(
      name: reqStr(ptn, "name"),
      net: reqStr(ptn, "net"),
      dir: portDirFromName(reqStr(ptn, "dir")),
      x: reqFloat(ptn, "x"),
      y: reqFloat(ptn, "y"),
      bodyW: reqFloat(ptn, "bodyW"),
      bodyH: reqFloat(ptn, "bodyH"),
      rotation: reqFloat(ptn, "rotation"),
      members: optBundleMembers(ptn, "members"))

  for fn in reqArr(node, "fallbacks"):
    if fn.kind != JObject: fail("scene JSON: fallback must be an object")
    var f = SchematicFallback(
      kind: (if fn.hasKey("kind"): fallbackKindFromName(reqStr(fn, "kind"))
             else: fbUnrouted),
      bundle: optStr(fn, "bundle"),
      net: reqStr(fn, "net"),
      part: reqStr(fn, "part"),
      pin: reqStr(fn, "pin"),
      x: reqFloat(fn, "x"),
      y: reqFloat(fn, "y"))
    for pt in reqArr(fn, "points"):
      f.points.add reqPoint(pt)
    if version == sceneSchemaVersion:
      f.ex = reqFloat(fn, "ex")
      f.ey = reqFloat(fn, "ey")
    else:
      let d = fallbackEscapeDir(result.parts, result.ports, f)
      f.ex = d.x
      f.ey = d.y
    result.fallbacks.add f

proc jsonToScene*(jsonString: string): Schematic =
  ## Reads a scene from its JSON text (the strict inverse of
  ## `sceneToJsonString`).
  try:
    jsonToScene(parseJson(jsonString))
  except JsonParsingError as e:
    fail("scene JSON: invalid JSON: " & e.msg)

proc readSceneJsonFile*(path: string): Schematic =
  ## Reads a scene from a JSON file, the strict inverse of
  ## `writeSceneJsonFile`.
  jsonToScene(readFile(path))
