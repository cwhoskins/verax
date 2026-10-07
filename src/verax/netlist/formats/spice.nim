## SPICE deck reader/writer.
##
## SPICE pins are positional per device letter and untyped, so pin names and
## kinds come from a built-in template per letter, or from the `.SUBCKT` port
## list for `X`/`U` instances; unknown letters get `pin1..pinN`. Pin fidelity
## through a round trip is best-effort by nature.
##
## `.SUBCKT` blocks become sub-netlists; node `"0"` and `.GLOBAL` names are
## one shared `Net` across the hierarchy. `.MODEL` cards are stored verbatim.
## Other directives are skipped.

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
  # Not a pure inverse of `deviceKindByPrefix`: `'A'` must never be read
  # positionally (an A line would invent nets named `%v(in)`).
  t["code_model"] = 'A'
  # Linear controlled sources, write-side only: `E`/`G` read back through the
  # generic fallback, and nothing needs their named roles from a deck.
  t["vcvs"] = 'E'
  t["vccs"] = 'G'
  # `F`/`H` name a controlling *voltage source*, so the normal device-line
  # path would emit the wrong arguments -- but without the letter, a `cccs`
  # named `CCCS1` would silently become a capacitor. A loud failure beats
  # that.
  t["cccs"] = 'F'
  t["ccvs"] = 'H'
  # Switches and mutual inductance, write-side only (synthesized by
  # `spice/models`). `S` is positional; `W` names a voltage source (letter
  # only, like `F`/`H`); `K` has no nodes and is special-cased in
  # `formatDeviceLine`.
  t["vswitch"] = 'S'
  t["iswitch"] = 'W'
  t["mutual_inductance"] = 'K'
  # Behavioural source, write-side only: bounds an op-amp macromodel to its
  # rails (diodes can't clamp an ideal source's output).
  t["bsource"] = 'B'
  t

proc spiceValue*(x: float): string =
  ## Formats a float as a SPICE device value, always with an explicit
  ## exponent: a trailing letter would be read as a multiplier (`1m`,
  ## `1MEG`). Use it for every synthesized device value.
  formatFloat(x, ffScientific, 9)

const spiceSuffixes = [
  # Longest first: `meg` and `mil` must both beat `m`.
  ("meg", 1.0e6), ("mil", 25.4e-6),
  ("t", 1.0e12), ("g", 1.0e9), ("k", 1.0e3),
  ("m", 1.0e-3), ("u", 1.0e-6), ("n", 1.0e-9),
  ("p", 1.0e-12), ("f", 1.0e-15),
]

proc parseSpiceMagnitude*(text: string, value: var float): bool =
  ## Reads a device value as SPICE does (suffixes are multipliers, unlike
  ## `annotations.parseAnnFloat`), returning `false` for anything that isn't
  ## an unambiguous magnitude. Refuses:
  ##
  ## * **Anything but a magnitude** -- `value` may be a source spec
  ##   (`"DC 0 AC 1"`); only callers that know the kind should ask.
  ## * **RKM notation** (`"2k2"`, `"4u7"`): ngspice reads the multiplier and
  ##   drops the trailing digits (2000, 4u), so a static check using the EDA
  ##   reading would disagree with the simulation.
  value = NaN
  let s = text.strip().toLowerAscii()
  if s.len == 0: return false

  var i = 0
  if i < s.len and s[i] in {'+', '-'}: inc i
  let digitsStart = i
  while i < s.len and s[i] in Digits: inc i
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] in Digits: inc i
  if i == digitsStart: return false

  if i < s.len and s[i] == 'e':
    # An explicit exponent, as `spiceValue` emits.
    var j = i + 1
    if j < s.len and s[j] in {'+', '-'}: inc j
    let expStart = j
    while j < s.len and s[j] in Digits: inc j
    if j > expStart: i = j

  var mantissa: float
  try:
    mantissa = parseFloat(s[0 ..< i])
  except ValueError:
    return false

  let rest = s[i .. ^1]
  if rest.len == 0:
    value = mantissa
    return true

  for (suffix, scale) in spiceSuffixes:
    if rest.startsWith(suffix):
      let tail = rest[suffix.len .. ^1]
      # RKM: author and simulator disagree. Refuse.
      if tail.len > 0 and tail[0] in Digits: return false
      value = mantissa * scale
      return true

  # A trailing unit with no multiplier (`"1ohm"`); SPICE ignores it.
  if rest[0] in Letters:
    value = mantissa
    return true
  false

proc designatorPrefix*(kind: string): char =
  ## The SPICE designator letter for a known device `kind` (`"voltage_source"`
  ## -> `'V'`). Raises `NetlistFormatError` for an unknown kind.
  if not prefixByDeviceKind.hasKey(kind):
    raise newException(NetlistFormatError, "no SPICE designator prefix for kind: " & kind)
  prefixByDeviceKind[kind]

proc deckDesignator*(comp: Component): string =
  ## The designator as spelled in a deck. SPICE infers device type from the
  ## first letter alone, and common EDA designators collide (`FB`, `BT`, `J`,
  ## `SW`, `TP`, `Y`), so an inductor named `C12` would silently simulate as
  ## a capacitor. The letter from `kind` is **prepended, not substituted**
  ## (`FB1` -> `LFB1`), so `FB1` and `L1` stay distinct.
  ##
  ## A `kind` with no letter is left alone (it is substituted before reaching
  ## a deck, or written as an instance by `deckInstanceDesignator`).
  let desig = comp.designator.multiReplace(("\t", "_"), (" ", "_"))
  if not prefixByDeviceKind.hasKey(comp.kind): return desig
  let want = prefixByDeviceKind[comp.kind]
  if desig.len > 0 and desig[0].toUpperAscii == want.toUpperAscii: return desig
  want & desig

proc deckInstanceDesignator*(comp: Component): string =
  ## The same correction for a hierarchical instance: always `X` (the reader
  ## accepts `U`, but ngspice reads `U` as a distributed RC line).
  let desig = comp.designator.multiReplace(("\t", "_"), (" ", "_"))
  if desig.len > 0 and desig[0].toUpperAscii == 'X': return desig
  "X" & desig

let pinTemplates = {
  "resistor": @[("1", ptPassive), ("2", ptPassive)],
  "capacitor": @[("1", ptPassive), ("2", ptPassive)],
  "inductor": @[("1", ptPassive), ("2", ptPassive)],
  "diode": @[("A", ptPassive), ("K", ptPassive)],
  "bjt": @[("C", ptPassive), ("B", ptPassive), ("E", ptPassive)],
  "mosfet": @[("D", ptPassive), ("G", ptPassive), ("S", ptPassive), ("B", ptPassive)],
  "voltage_source": @[("+", ptPassive), ("-", ptPassive)],
  "current_source": @[("+", ptPassive), ("-", ptPassive)],
  # `Exxx n+ n- nc+ nc- gain`, write-side only. The template's pin order is
  # what makes the line positionally correct.
  "vcvs": @[("OUT+", ptOutput), ("OUT-", ptPassive), ("IN+", ptInput), ("IN-", ptInput)],
  "vccs": @[("OUT+", ptOutput), ("OUT-", ptPassive), ("IN+", ptInput), ("IN-", ptInput)],
  # `Sname n+ n- nc+ nc- MODEL`; `MODEL` rides in `attrs["value"]`.
  "vswitch": @[("1", ptPassive), ("2", ptPassive), ("C+", ptInput), ("C-", ptInput)],
  # `Bxxx n+ n- V=<expr>`: the expression names its own inputs.
  "bsource": @[("OUT+", ptOutput), ("OUT-", ptPassive)],
}.toTable

proc processLine(ctx: ParseCtx, nl: Netlist, toks: seq[string])
proc parseDeviceLine(ctx: ParseCtx, nl: Netlist, toks: seq[string])
proc resolveSubckt(ctx: ParseCtx, name: string): Netlist

proc netFor(ctx: ParseCtx, nl: Netlist, name: string): Net =
  ## Resolves `name` in scope `nl`, sharing the object from `ctx.globalNets`
  ## for a global net (one node "0" across every level).
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
  if comp.attrs.hasKey("spice.couples"):
    # `K` card: `Kname Lname1 Lname2 kvalue`, no nodes. `spice.couples` holds
    # graph designators, resolved to deck spelling here so a rename can't
    # leave a stale name.
    result = deckDesignator(comp)
    for d in comp.attrs["spice.couples"].split(','):
      let other = if comp.netlist != nil: comp.netlist.components.getOrDefault(d.strip())
                  else: nil
      result &= " " & (if other != nil: deckDesignator(other) else: d.strip())
    if comp.attrs.hasKey("value"):
      result &= " " & comp.attrs["value"]
    return result

  if comp.attrs.hasKey("xspice.ports"):
    # An XSPICE `A` device: its port list isn't positional (differential,
    # vector, `null`), so `xspice/instance` renders it into `xspice.ports`.
    # The pins still carry connectivity for graph walks.
    result = deckDesignator(comp) & " " & comp.attrs["xspice.ports"]
    if comp.attrs.hasKey("value"):
      result &= " " & comp.attrs["value"]
    return result

  let templ = pinTemplates.getOrDefault(comp.kind, @[])
  var nodes: seq[string]
  if templ.len > 0:
    for (pinName, _) in templ:
      let pin = comp.pins.getOrDefault(pinName)
      nodes.add(if pin != nil and pin.net != nil: pin.net.name else: "")
  else:
    for pinName, pin in comp.pins:
      nodes.add(if pin.net != nil: pin.net.name else: "")
  result = deckDesignator(comp) & " " & nodes.join(" ")
  if comp.attrs.hasKey("value"):
    result &= " " & comp.attrs["value"]

proc formatInstanceLine(child: Netlist): string =
  let comp = child.instanceOf
  var nodes: seq[string]
  for portName, _ in child.ports:
    let pin = comp.pins[portName]
    nodes.add(if pin.net != nil: pin.net.name else: "")
  # `child.name`, not `partNumber`: it must name the `.SUBCKT` block written,
  # and a design may set its own `partNumber`.
  result = deckInstanceDesignator(comp) & " " & nodes.join(" ") & " " & child.name

proc collectTemplates(nl: Netlist, seen: var OrderedTable[string, Netlist]) =
  for designator, child in nl.children:
    let key = child.name
    if not seen.hasKey(key):
      seen[key] = child
    collectTemplates(child, seen)

proc checkDeckDesignators(nl: Netlist) =
  ## Every component at one deck level must spell a distinct designator.
  ## Prepending the letter isn't injective (`XA.R1` and `RXA.R1` both become
  ## `RXA.R1`), and flattening makes dotted designators common. ngspice would
  ## silently use one definition, so this raises. Per level: `.SUBCKT`
  ## scopes designators.
  var seen: OrderedTable[string, string]
  for designator, comp in nl.components:
    let deck =
      if comp.subNetlist != nil: deckInstanceDesignator(comp)
      else: deckDesignator(comp)
    if seen.hasKey(deck) and seen[deck] != designator:
      raise newException(NetlistFormatError,
        "'" & seen[deck] & "' and '" & designator & "' are different " &
        "components but are both written '" & deck & "' in the deck, so " &
        "ngspice would see one device defined twice. The device letter is " &
        "prepended from `kind` rather than substituted, which is not " &
        "reversible -- rename one of them.")
    seen[deck] = designator

proc writeSubcktBlock(s: Stream, templ: Netlist) =
  checkDeckDesignators(templ)
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

proc writeSubcktDefinition*(nl: Netlist, s: Stream) =
  ## Writes `nl` as a standalone `.SUBCKT` block with ports (`writeNetlist`
  ## drops ports -- right for a board, wrong for a reusable template such as
  ## `spice/boundary.asSubcircuit` output). Nested templates come first;
  ## `.MODEL` cards go inside the block.
  checkDeckDesignators(nl)
  var templates: OrderedTable[string, Netlist]
  collectTemplates(nl, templates)
  for name, templ in templates:
    writeSubcktBlock(s, templ)

  var header = ".SUBCKT " & (if nl.name.len > 0: nl.name else: "UNNAMED")
  for portName, _ in nl.ports:
    header &= " " & portName
  s.writeLine(header)
  for name, modelLine in nl.models:
    s.writeLine(".MODEL " & name & " " & modelLine)
  for designator, comp in nl.components:
    if comp.subNetlist == nil:
      s.writeLine(formatDeviceLine(comp))
  for designator, child in nl.children:
    s.writeLine(formatInstanceLine(child))
  s.writeLine(".ENDS " & (if nl.name.len > 0: nl.name else: "UNNAMED"))

proc writeSubcktFile*(nl: Netlist, path: string) =
  ## `writeSubcktDefinition` to a file.
  let s = newFileStream(path, fmWrite)
  if s == nil:
    raise newException(NetlistFormatError, "cannot open for writing: " & path)
  defer: s.close()
  writeSubcktDefinition(nl, s)

proc writeNetlist*(nl: Netlist, s: Stream, cards: seq[string] = @[]) =
  ## `cards` are raw control/analysis lines (e.g. `@[".op"]`), written after
  ## the `.MODEL` lines and before `.END`. Empty writes pure topology.
  checkDeckDesignators(nl)
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
