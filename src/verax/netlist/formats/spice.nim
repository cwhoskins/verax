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
## `verax/netlist/graph.instantiate`); node `"0"` (and any `.GLOBAL` names)
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
  # Deliberately *not* a pure inverse of deviceKindByPrefix. An XSPICE code
  # model instance is an `A` device, so anything synthesizing one needs the
  # letter -- but `'A'` must never appear in deviceKindByPrefix itself, since
  # an A line is not positional and routing one through the positional reader
  # invents nets literally named `%v(in)`.
  t["code_model"] = 'A'
  # Same writer-only treatment for the linear controlled sources. `E`/`G`
  # lines *are* positional, so unlike `A` they read back correctly through
  # the generic `pin1..pinN` fallback -- they are kept out of
  # `deviceKindByPrefix` only because nothing yet needs to recover the named
  # `IN+`/`IN-` roles from a deck, and inventing a mapping that no reader
  # test covers would be a claim this module cannot back up.
  t["vcvs"] = 'E'
  t["vccs"] = 'G'
  # The current-controlled pair, and they are here for a narrower reason than
  # `E`/`G`. An `F`/`H` line is **not** simply positional over nets: its third
  # token names the *voltage source* whose current controls it, so writing one
  # through the normal device-line path would emit a value where ngspice
  # expects a source name. Nothing synthesizes either kind today, so that is
  # latent. What is not latent is the letter: without an entry here a `cccs`
  # designated `CCCS1` reaches the deck unchanged and ngspice reads the
  # leading `C` as a **capacitor**, silently. With one it is an `F` line with
  # the wrong arguments, which fails loudly. A loud failure about a device
  # that exists beats a silent 2 F capacitor.
  t["cccs"] = 'F'
  t["ccvs"] = 'H'
  # The switch pair and the mutual-inductance card, all write-side only and
  # all synthesized by `spice/models` -- never authored, never read back. An
  # `S` line is plainly positional over four nodes, so it goes through the
  # normal `pinTemplates` path below. A `W` line's third token names a
  # *voltage source* (`Wname n+ n- VNAM MODEL`), so it is here for the letter
  # and nothing more -- same reason `F`/`H` are. A `K` line carries **no
  # nodes at all**, only two inductor names, and is handled by a special case
  # in `formatDeviceLine` like `xspice.ports`.
  t["vswitch"] = 'S'
  t["iswitch"] = 'W'
  t["mutual_inductance"] = 'K'
  # Behavioural source, also write-side only. `spice/models` uses one to
  # bound an op-amp macromodel to its supply rails: a VCVS is ideal and
  # cannot saturate, and clamping its *output* with diodes achieves nothing
  # because an ideal source holds its node regardless. A `B` device carries
  # the limit in its own expression instead.
  t["bsource"] = 'B'
  t

proc spiceValue*(x: float): string =
  ## Formats a float as a SPICE device value. Always scientific notation with
  ## an explicit exponent: SPICE reads a trailing letter as a unit multiplier
  ## (`1m` is milli, `1MEG` is mega), so any format that could end in one is a
  ## silent-misread hazard on a synthesized device line. Anything synthesizing
  ## components to be simulated (see `verax/spice`) should format through here.
  formatFloat(x, ffScientific, 9)

const spiceSuffixes = [
  # Longest first: `meg` and `mil` must both beat `m`.
  ("meg", 1.0e6), ("mil", 25.4e-6),
  ("t", 1.0e12), ("g", 1.0e9), ("k", 1.0e3),
  ("m", 1.0e-3), ("u", 1.0e-6), ("n", 1.0e-9),
  ("p", 1.0e-12), ("f", 1.0e-15),
]

proc parseSpiceMagnitude*(text: string, value: var float): bool =
  ## Reads a device value the way SPICE reads it, returning `false` for
  ## anything that is not an unambiguous magnitude.
  ##
  ## The partial inverse of `spiceValue`, and the counterpart to
  ## `annotations.parseAnnFloat`: that one *rejects* magnitude suffixes
  ## because an annotation is in SI base units, whereas here a trailing letter
  ## genuinely is a multiplier, because this is what goes into a deck.
  ##
  ## Deliberately refuses two things rather than guessing at them:
  ##
  ## * **Anything that is not just a magnitude.** `attrs["value"]` may carry a
  ##   whole source specification (`"DC 0 AC 1"`), which is why the annotation
  ##   registry documents that field as never parsed as a number. Only a
  ##   caller that knows the component kind makes a value a bare magnitude
  ##   (a resistor's, a capacitor's) should ask.
  ## * **RKM notation, where a digit follows the multiplier** -- `"2k2"`,
  ##   `"4u7"`. An EDA tool means 2200 and 4.7u by those; ngspice reads the
  ##   multiplier and *discards the trailing digits*, giving 2000 and 4u
  ##   (verified against ngspice, not assumed). Since `value` is passed
  ##   through to the deck verbatim, the simulator's reading is the one that
  ##   gets simulated, and any static check that quietly used the other would
  ##   disagree with the simulation about the same part by 10%. Two plausible
  ##   readings that differ is exactly the case to hand back rather than pick.
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
    # An explicit exponent -- what `spiceValue` itself emits.
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
      # A digit here is RKM: the author and the simulator disagree. Refuse.
      if tail.len > 0 and tail[0] in Digits: return false
      value = mantissa * scale
      return true

  # A trailing unit with no multiplier (`"1ohm"`, `"10f"` is farads only by
  # context and is read as femto above). SPICE ignores it.
  if rest[0] in Letters:
    value = mantissa
    return true
  false

proc designatorPrefix*(kind: string): char =
  ## The SPICE reference-designator prefix letter for a known device `kind`
  ## (e.g. `"voltage_source"` -> `'V'`). Raises `NetlistFormatError` if
  ## `kind` isn't one of the built-in device kinds this module recognizes --
  ## SPICE infers device type from this letter, not from any `kind` field,
  ## so getting it right matters for anything synthesizing new components
  ## meant to be simulated (see `verax/spice`).
  if not prefixByDeviceKind.hasKey(kind):
    raise newException(NetlistFormatError, "no SPICE designator prefix for kind: " & kind)
  prefixByDeviceKind[kind]

proc deckDesignator*(comp: Component): string =
  ## The reference designator as it has to be spelled in a deck.
  ##
  ## SPICE infers a device's *type* from the first letter of its designator
  ## and from nothing else, so a part whose designator disagrees with its
  ## declared `kind` is silently simulated as a different device. That is not
  ## an exotic case: `FB` (ferrite bead), `BT` (battery), `J` (connector),
  ## `SW` (switch), `TP` (test point) and `Y` (crystal) are all ordinary EDA
  ## designators and all collide with a SPICE device letter. A ferrite called
  ## `FB1` is read as a current-controlled current source, which at least
  ## fails loudly; an inductor a librarian filed as `C12` is read as a
  ## *capacitor*, which parses, simulates, and is wrong by the difference
  ## between an inductor and a capacitor with nothing reported anywhere.
  ##
  ## So the letter comes from `kind`, which is what the design actually
  ## stated. It is **prepended, not substituted** -- `FB1` becomes `LFB1`,
  ## never `L1` -- because the original designators are unique as a set and a
  ## truncated one need not be: substituting would silently merge `FB1` and
  ## `L1` into one device on a board that has both.
  ##
  ## A `kind` this module has no letter for is left alone, since there is
  ## nothing to correct it against; such a part is either substituted before
  ## it reaches a deck (see `verax/spice/models`) or written as a subcircuit
  ## instance by `deckInstanceDesignator`.
  let desig = comp.designator.multiReplace(("\t", "_"), (" ", "_"))
  if not prefixByDeviceKind.hasKey(comp.kind): return desig
  let want = prefixByDeviceKind[comp.kind]
  if desig.len > 0 and desig[0].toUpperAscii == want.toUpperAscii: return desig
  want & desig

proc deckInstanceDesignator*(comp: Component): string =
  ## The same correction for a hierarchical instance, which is an `X` device.
  ##
  ## The reader accepts `U` as well, because other tools emit it, but ngspice
  ## reads `U` as a uniformly-distributed RC line -- so a deck this module
  ## *writes* always says `X`.
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
  # Linear controlled sources: `Exxx n+ n- nc+ nc- gain`. Write-side only --
  # see the note in `prefixByDeviceKind`. The pin *order* here is what makes
  # the emitted line positionally correct, which is the whole point of having
  # a template rather than relying on `Component.pins` insertion order.
  "vcvs": @[("OUT+", ptOutput), ("OUT-", ptPassive), ("IN+", ptInput), ("IN-", ptInput)],
  "vccs": @[("OUT+", ptOutput), ("OUT-", ptPassive), ("IN+", ptInput), ("IN-", ptInput)],
  # `Sname n+ n- nc+ nc- MODEL`: the through nodes then the control pair, and
  # `MODEL` rides in `attrs["value"]` the same way a diode's model name does.
  "vswitch": @[("1", ptPassive), ("2", ptPassive), ("C+", ptInput), ("C-", ptInput)],
  # `Bxxx n+ n- V=<expr>`: two nodes, and the expression names its inputs
  # itself rather than taking them positionally.
  "bsource": @[("OUT+", ptOutput), ("OUT-", ptPassive)],
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
  if comp.attrs.hasKey("spice.couples"):
    # A SPICE `K` card: `Kname Lname1 Lname2 kvalue`. It has no nodes -- it
    # names two inductors and a coupling coefficient -- so it cannot go
    # through the positional node path at all. `spice.couples` holds the two
    # inductors' *graph* designators; they are resolved to their deck
    # spelling here rather than baked in, because `deckDesignator` prepends
    # the device letter and a baked name would rot the moment a winding was
    # renamed.
    result = deckDesignator(comp)
    for d in comp.attrs["spice.couples"].split(','):
      let other = if comp.netlist != nil: comp.netlist.components.getOrDefault(d.strip())
                  else: nil
      result &= " " & (if other != nil: deckDesignator(other) else: d.strip())
    if comp.attrs.hasKey("value"):
      result &= " " & comp.attrs["value"]
    return result

  if comp.attrs.hasKey("xspice.ports"):
    # An XSPICE `A` device. Its port list is not positional -- a differential
    # port takes two nodes, a vector port is bracketed, an unconnected one is
    # the literal `null` -- so `verax/spice/xspice/instance` renders it and
    # stores the text here, the same verbatim-passthrough approach this module
    # already takes for `.MODEL` cards. The pins still carry real connectivity
    # for graph walks; this attribute only controls how the line is spelled.
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
  result = deckInstanceDesignator(comp) & " " & nodes.join(" ") & " " & comp.partNumber

proc collectTemplates(nl: Netlist, seen: var OrderedTable[string, Netlist]) =
  for designator, child in nl.children:
    let key = child.instanceOf.partNumber
    if not seen.hasKey(key):
      seen[key] = child
    collectTemplates(child, seen)

proc checkDeckDesignators(nl: Netlist) =
  ## Every component at one level of a deck must spell a distinct designator.
  ##
  ## Graph uniqueness does not imply deck uniqueness, and the gap is
  ## `deckDesignator`, which **prepends** the device letter from `kind`
  ## rather than substituting it. Prepending is what keeps `FB1` and `L1`
  ## from both collapsing onto `L1`, and it is deliberately not injective:
  ## a resistor designated `XA.R1` and a resistor designated `RXA.R1` are
  ## two distinct components in the graph and one line in the deck.
  ##
  ## That was unreachable while every designator was hand-written and short.
  ## `spice/flatten` makes generated, dotted designators ordinary, so it is
  ## reachable now -- and the failure is silent: ngspice sees one designator
  ## defined twice and the fragment simulated is not the circuit. Raising is
  ## the whole point; there is no safe way to guess which one was meant.
  ##
  ## Per level, not per deck: SPICE scopes designators inside a `.SUBCKT`.
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
  ## Writes `nl` as a standalone `.SUBCKT` block, ports and all.
  ##
  ## `writeNetlist` deliberately does not do this: a top-level SPICE deck has
  ## no port concept, so it drops `Netlist.ports` on the floor -- correct for
  ## a board, and silently wrong for a template somebody built to be reused.
  ## `spice/boundary.asSubcircuit` produces exactly such a template, and this
  ## is how it leaves the process.
  ##
  ## Nested templates are emitted first, since a `.SUBCKT` may instantiate
  ## another; `.MODEL` cards go *inside* the block, where SPICE scopes them to
  ## it.
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
  ## `cards` are raw control/analysis card lines (e.g. `@[".op"]`), written
  ## after the `.MODEL` lines and before `.END`. Empty by default, so this
  ## writes pure topology exactly as before -- validating a generated deck
  ## by actually simulating it (see `verax/spice`) is what `cards` is for.
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
