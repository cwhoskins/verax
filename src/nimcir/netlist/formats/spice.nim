## SPICE deck reader/writer.
##
## Raw SPICE encodes component pins *positionally* per device-type letter
## (e.g. `R1 net1 net2 1k`), not via named/typed pins — SPICE has no native
## concept of pin "type" (power/ground/input/output). Pin names/types here
## come from a small built-in template per known device-type letter, or (for
## `X`/`U` subcircuit instances) from the matching `.SUBCKT` port list.
## Unrecognized device letters fall back to generic `pin1..pinN` pins.
## This means pin `kind`/name fidelity through a SPICE round-trip is
## best-effort only — that's an inherent limitation of the format, not a bug.
##
## `.SUBCKT`/`.ENDS` blocks become hierarchical sub-netlists (see
## `nimcir/netlist/graph.instantiate`); node `"0"` (and any `.GLOBAL` names)
## are shared as a single `Net` object across the whole hierarchy, matching
## real SPICE ground/global semantics. `.MODEL` cards are stored verbatim in
## `Netlist.models` (passthrough, not structurally parsed). Other simulation
## directives (`.OPTIONS`, `.TRAN`, `.PARAM`, ...) are topology-irrelevant
## and are skipped silently.

import std/[streams, strutils, tables, os]
import ../types
import ../graph
import ./common

type
  SubcktRaw = object
    name: string
    ports: seq[string]
    body: seq[seq[string]]

  ParseCtx = ref object
    root: Netlist
    globalNets: OrderedTable[string, Net]
    subcktRaws: OrderedTable[string, SubcktRaw]
    subcktDefs: OrderedTable[string, Netlist]
    building: seq[string]

let deviceKindByPrefix = {
  'R': "resistor", 'C': "capacitor", 'L': "inductor",
  'D': "diode", 'Q': "bjt", 'M': "mosfet",
  'V': "voltage_source", 'I': "current_source",
}.toTable

let prefixByDeviceKind = block:
  var t: Table[string, char]
  for prefix, kind in deviceKindByPrefix:
    t[kind] = prefix
  t

proc designatorPrefix*(kind: string): char =
  ## The SPICE reference-designator prefix letter for a known device `kind`
  ## (e.g. `"voltage_source"` -> `'V'`). Raises `NetlistFormatError` if
  ## `kind` isn't one of the built-in device kinds this module recognizes --
  ## SPICE infers device type from this letter, not from any `kind` field,
  ## so getting it right matters for anything synthesizing new components
  ## meant to be simulated (see `nimcir/spice`).
  if not prefixByDeviceKind.hasKey(kind):
    raise newException(NetlistFormatError, "no SPICE designator prefix for kind: " & kind)
  prefixByDeviceKind[kind]

let pinTemplates = {
  "resistor": @[("1", ptPassive), ("2", ptPassive)],
  "capacitor": @[("1", ptPassive), ("2", ptPassive)],
  "inductor": @[("1", ptPassive), ("2", ptPassive)],
  "diode": @[("A", ptPassive), ("K", ptPassive)],
  "bjt": @[("C", ptPassive), ("B", ptPassive), ("E", ptPassive)],
  "mosfet": @[("D", ptPassive), ("G", ptPassive), ("S", ptPassive), ("B", ptPassive)],
  "voltage_source": @[("+", ptPassive), ("-", ptPassive)],
  "current_source": @[("+", ptPassive), ("-", ptPassive)],
}.toTable

proc processLine(ctx: ParseCtx, nl: Netlist, toks: seq[string])
proc parseDeviceLine(ctx: ParseCtx, nl: Netlist, toks: seq[string])
proc resolveSubckt(ctx: ParseCtx, name: string): Netlist

proc netFor(ctx: ParseCtx, nl: Netlist, name: string): Net =
  ## Resolves `name` to a `Net` in the current scope `nl`, transparently
  ## sharing the object from `ctx.globalNets` when `name` is a global/ground
  ## net (this is what keeps e.g. node "0" a single identical object across
  ## every hierarchy level).
  if nl.nets.hasKey(name):
    return nl.nets[name]
  if ctx.globalNets.hasKey(name):
    result = ctx.globalNets[name]
    nl.nets[name] = result
    return result
  var kind = ntUnknown
  if name.toLowerAscii in ["gnd", "ground"]:
    kind = ntGround
  result = addNet(nl, newNet(name, kind))

proc processLine(ctx: ParseCtx, nl: Netlist, toks: seq[string]) =
  let head = toks[0].toUpperAscii
  if head == ".MODEL":
    if toks.len < 2:
      raise newException(NetlistFormatError, ".MODEL directive missing a name")
    nl.models[toks[1]] = toks[2..^1].join(" ")
  elif head == ".GLOBAL":
    for nodeName in toks[1..^1]:
      if not ctx.globalNets.hasKey(nodeName):
        ctx.globalNets[nodeName] = netFor(ctx, ctx.root, nodeName)
  elif head.startsWith("."):
    discard # unrecognized simulation directive: topology-irrelevant, skip
  else:
    parseDeviceLine(ctx, nl, toks)

proc parseDeviceLine(ctx: ParseCtx, nl: Netlist, toks: seq[string]) =
  let designator = toks[0]
  let prefix = designator[0].toUpperAscii

  if prefix == 'X' or prefix == 'U':
    if toks.len < 3:
      raise newException(NetlistFormatError, "malformed subcircuit instantiation: " & toks.join(" "))
    let subName = toks[^1]
    let nodeNames = toks[1 ..< toks.len - 1]
    let defNl = resolveSubckt(ctx, subName)
    var portNets: seq[Net]
    for nodeName in nodeNames:
      portNets.add(netFor(ctx, nl, nodeName))
    discard instantiate(nl, designator, defNl, portNets, ctx.globalNets)
    return

  let kind = deviceKindByPrefix.getOrDefault(prefix, "")
  let comp = addComponent(nl, newComponent(designator, kind = kind))

  if kind.len > 0 and pinTemplates.hasKey(kind):
    let templ = pinTemplates[kind]
    if toks.len < 1 + templ.len:
      raise newException(NetlistFormatError, "not enough nodes for " & kind & " device: " & toks.join(" "))
    for idx in 0 ..< templ.len:
      let (pinName, pinKind) = templ[idx]
      let net = netFor(ctx, nl, toks[1 + idx])
      discard connect(comp, pinName, net, pinKind)
    if toks.len > 1 + templ.len:
      comp.attrs["value"] = toks[(1 + templ.len) .. ^1].join(" ")
  else:
    if toks.len < 2:
      raise newException(NetlistFormatError, "malformed device line: " & toks.join(" "))
    let nodeToks = toks[1 ..< toks.len - 1]
    for idx, nodeName in nodeToks:
      let net = netFor(ctx, nl, nodeName)
      discard connect(comp, "pin" & $(idx + 1), net)
    comp.attrs["value"] = toks[^1]

proc resolveSubckt(ctx: ParseCtx, name: string): Netlist =
  if ctx.subcktDefs.hasKey(name):
    return ctx.subcktDefs[name]
  if not ctx.subcktRaws.hasKey(name):
    raise newException(NetlistFormatError, "reference to undefined .SUBCKT: " & name)
  if name in ctx.building:
    raise newException(NetlistFormatError, "recursive .SUBCKT instantiation involving: " & name)
  ctx.building.add(name)

  let raw = ctx.subcktRaws[name]
  let templ = newNetlist(raw.name)
  for portName in raw.ports:
    let n = netFor(ctx, templ, portName)
    addPort(templ, portName, n)
  for bodyToks in raw.body:
    processLine(ctx, templ, bodyToks)

  ctx.subcktDefs[name] = templ
  discard ctx.building.pop()
  result = templ

proc readNetlist*(s: Stream, name = ""): Netlist =
  var physLines: seq[string]
  while not s.atEnd:
    physLines.add(s.readLine())

  let title = if physLines.len > 0: physLines[0] else: ""
  let ctx = ParseCtx(root: newNetlist(if name.len > 0: name else: title))
  let zeroNet = addNet(ctx.root, newNet("0", ntGround))
  ctx.globalNets["0"] = zeroNet

  # Merge `+` continuations and drop `*` comments / blank lines.
  var logical: seq[string]
  for i in 1 ..< physLines.len:
    let stripped = physLines[i].strip(leading = true, trailing = true)
    if stripped.len == 0: continue
    if stripped[0] == '*': continue
    if stripped[0] == '+':
      if logical.len == 0:
        raise newException(NetlistFormatError, "line " & $(i + 1) & ": continuation with no preceding line")
      logical[^1] = logical[^1] & " " & stripped[1..^1].strip()
    else:
      logical.add(stripped)

  var tokLines: seq[seq[string]]
  for l in logical:
    let toks = l.splitWhitespace()
    if toks.len > 0:
      tokLines.add(toks)

  for idx, toks in tokLines:
    if toks[0].toUpperAscii == ".END":
      tokLines.setLen(idx)
      break

  # Pass 1: extract all .SUBCKT/.ENDS blocks; everything else is top-level.
  var topLevel: seq[seq[string]]
  var i = 0
  while i < tokLines.len:
    let toks = tokLines[i]
    if toks[0].toUpperAscii == ".SUBCKT":
      if toks.len < 2:
        raise newException(NetlistFormatError, ".SUBCKT directive missing a name")
      var raw = SubcktRaw(name: toks[1], ports: toks[2..^1])
      inc i
      while i < tokLines.len and tokLines[i][0].toUpperAscii != ".ENDS":
        raw.body.add(tokLines[i])
        inc i
      if i >= tokLines.len:
        raise newException(NetlistFormatError, ".SUBCKT " & raw.name & " missing matching .ENDS")
      inc i # skip .ENDS
      ctx.subcktRaws[raw.name] = raw
    else:
      topLevel.add(toks)
      inc i

  # Pass 2: build the root netlist, resolving .SUBCKT templates on demand.
  for toks in topLevel:
    processLine(ctx, ctx.root, toks)

  result = ctx.root

proc readNetlistFile*(path: string): Netlist =
  let s = newFileStream(path, fmRead)
  if s == nil:
    raise newException(NetlistFormatError, "cannot open: " & path)
  defer: s.close()
  result = readNetlist(s, name = path.extractFilename)

proc formatDeviceLine(comp: Component): string =
  let templ = pinTemplates.getOrDefault(comp.kind, @[])
  var nodes: seq[string]
  if templ.len > 0:
    for (pinName, _) in templ:
      let pin = comp.pins.getOrDefault(pinName)
      nodes.add(if pin != nil and pin.net != nil: pin.net.name else: "")
  else:
    for pinName, pin in comp.pins:
      nodes.add(if pin.net != nil: pin.net.name else: "")
  result = comp.designator & " " & nodes.join(" ")
  if comp.attrs.hasKey("value"):
    result &= " " & comp.attrs["value"]

proc formatInstanceLine(child: Netlist): string =
  let comp = child.instanceOf
  var nodes: seq[string]
  for portName, _ in child.ports:
    let pin = comp.pins[portName]
    nodes.add(if pin.net != nil: pin.net.name else: "")
  result = comp.designator & " " & nodes.join(" ") & " " & comp.partNumber

proc collectTemplates(nl: Netlist, seen: var OrderedTable[string, Netlist]) =
  for designator, child in nl.children:
    let key = child.instanceOf.partNumber
    if not seen.hasKey(key):
      seen[key] = child
    collectTemplates(child, seen)

proc writeSubcktBlock(s: Stream, templ: Netlist) =
  var header = ".SUBCKT " & templ.name
  for portName, _ in templ.ports:
    header &= " " & portName
  s.writeLine(header)
  for designator, comp in templ.components:
    if comp.subNetlist == nil:
      s.writeLine(formatDeviceLine(comp))
  for designator, child in templ.children:
    s.writeLine(formatInstanceLine(child))
  s.writeLine(".ENDS " & templ.name)

proc writeNetlist*(nl: Netlist, s: Stream, cards: seq[string] = @[]) =
  ## `cards` are raw control/analysis card lines (e.g. `@[".op"]`), written
  ## after the `.MODEL` lines and before `.END`. Empty by default, so this
  ## writes pure topology exactly as before -- validating a generated deck
  ## by actually simulating it (see `nimcir/spice`) is what `cards` is for.
  s.writeLine(nl.name)

  var templates: OrderedTable[string, Netlist]
  collectTemplates(nl, templates)
  for name, templ in templates:
    writeSubcktBlock(s, templ)

  for designator, comp in nl.components:
    if comp.subNetlist == nil:
      s.writeLine(formatDeviceLine(comp))

  for designator, child in nl.children:
    s.writeLine(formatInstanceLine(child))

  for name, modelLine in nl.models:
    s.writeLine(".MODEL " & name & " " & modelLine)

  for card in cards:
    s.writeLine(card)

  s.writeLine(".END")

proc writeNetlistFile*(nl: Netlist, path: string, cards: seq[string] = @[]) =
  let s = newFileStream(path, fmWrite)
  if s == nil:
    raise newException(NetlistFormatError, "cannot open for writing: " & path)
  defer: s.close()
  writeNetlist(nl, s, cards)
