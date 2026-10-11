## The circuit-under-test picture for one test: a region of what was
## simulated (or, for a check that ran nothing, of the flattened design),
## grown from where the test drives and reads, with modelling elements
## folded back into the design parts they stand for.
##
## - **Growth** (`netlist/region`): from the seeds, through two-terminal
##   passives (model elements included) up to `viewHops` nets away,
##   shrinking the reach until at most `viewMaxParts` parts are shown.
##   ICs, sources and instances are boundary blocks (drawn, not walked
##   through); ground is never walked, other rails only when seeded.
##   Fixture parts (stimulus, load, termination) are always walked into.
## - **Folding**: elements marked `bench.role` `model`/`standin` are drawn
##   as their `bench.of` design part (from the flattened design), so a
##   capacitor's ESR/ESL, an op-amp macromodel or an IC's per-pin stand-ins
##   read as the part. A 0 V current-sense source is not drawn (it is listed
##   in the bench table); its split net is merged back.
## - **Trimming**: a drawn part with more than `pinTrimMin` pins keeps only
##   its pins on the view's nets (an MCU on an I2C bus is two pins).
##
## Never mutates its inputs.

import std/[algorithm, sets, strutils, tables]
import ../netlist/types
import ../netlist/graph
import ../netlist/kinds
import ../netlist/region
import ../spice/provenance

const
  viewMaxParts* = 30
    ## Most parts a view draws.
  viewHops* = 2
    ## How far from the seeds a view reaches through passives.
  pinTrimMin* = 6
    ## A drawn part with more pins than this shows only its pins on the
    ## view's nets.

type
  View* = object
    netlist*: Netlist
      ## What to lay out; nil when nothing could be drawn.
    parts*: seq[string]
      ## Displayed designators, in order.
    hops*: int
    total*: int
      ## Parts (after folding) in the source.
    truncated*: int
      ## Parts within reach not drawn because of `viewMaxParts`.
    folded*: seq[tuple[part: string, elements: seq[string]]]
      ## Design parts drawn in place of their simulation elements, and the
      ## elements (`designator value`).
    trimmed*: seq[string]
      ## Parts drawn with only some of their pins.
    missing*: seq[string]
      ## Seed nets not found in the source.

const foldRoles = [$brModel, $brStandIn]

proc normPin(name: string): string =
  ## Op-amp pin spellings are many; everything else matches as written.
  case name.toUpperAscii
  of "+", "IN+", "INP", "NONINV": "INP"
  of "-", "IN-", "INN", "INV": "INN"
  of "OUT", "VOUT", "OUTPUT": "OUT"
  else: name.toUpperAscii

proc displayOf(c: Component): string =
  if benchRole(c) in foldRoles and benchOf(c).len > 0: benchOf(c)
  else: c.designator

proc isSenseSource(c: Component): bool =
  benchRole(c) == $brProbe and c.kind == "voltage_source"

proc walkable(c: Component): bool =
  ## Two-terminal and fully described by its value: the view walks on.
  c.subNetlist == nil and c.pins.len == 2 and isPassive(c) and
    c.kind notin ["voltage_source", "current_source"]

proc viewRules(hops: int): RegionRules =
  RegionRules(maxHops: hops, closeCouplings: true,
    traverseNet: proc (n: Net, seeded: bool): bool =
      not (isGround(n) or n.name == "0") and (seeded or not isRail(n)),
    absorb: proc (c: Component, via: Net): RegionAction =
      let role = benchRole(c)
      if role in [$brStimulus, $brLoad, $brTermination, $brProbe]: raInclude
      elif walkable(c): raInclude
      else: raBoundary)

proc groundName(nl: Netlist): string =
  if nl.nets.hasKey("0"): return "0"
  for k, n in nl.nets:
    if isGround(n): return k
  "0"

proc buildView*(src: Netlist, seedNets, seedParts: openArray[string],
                design: Netlist = nil): View =
  ## `design`: the flattened design, for folding; nil draws elements as
  ## they are.
  if src == nil: return
  # Folded display groups of the whole source, for `total`.
  var allGroups = initHashSet[string]()
  for _, c in src.components:
    if not isSenseSource(c): allGroups.incl displayOf(c)
  result.total = allGroups.len

  var nets: seq[Net]
  for name in seedNets:
    let n = findNet(src, name)
    if n == nil:
      if name notin result.missing: result.missing.add name
    elif n notin nets: nets.add n
  # A seed part is walked through only if a passive or the fixture would
  # be; an IC named as a seed is drawn but not walked (all 144 of an MCU's
  # nets would otherwise seed the view).
  var parts, blocks: seq[string]
  for d in seedParts:
    if not src.components.hasKey(d) or d in parts or d in blocks: continue
    let c = src.components[d]
    if walkable(c) or benchRole(c) in [$brStimulus, $brLoad, $brTermination]:
      parts.add d
    else: blocks.add d
  if nets.len == 0 and parts.len == 0 and blocks.len == 0: return

  # Shrink the reach until the folded picture fits.
  var region: Region
  var groups: OrderedTable[string, seq[Component]]
  for hops in countdown(viewHops, 0):
    region = growRegion(src, parts, nets, viewRules(hops))
    for d in blocks:
      if d notin region.parts: region.parts.add d
    groups.clear()
    for d in region.parts:
      let c = src.components[d]
      if isSenseSource(c): continue
      groups.mgetOrPut(displayOf(c), @[]).add c
    result.hops = hops
    if groups.len <= viewMaxParts: break
  if groups.len > viewMaxParts:
    # Keep seeds' own parts and the fixture first.
    var keep: seq[string]
    for k, elems in groups:
      for c in elems:
        if benchRole(c) in [$brStimulus, $brLoad] or c.designator in parts or
           c.designator in blocks:
          if k notin keep: keep.add k
    for k in groups.keys:
      if keep.len >= viewMaxParts: break
      if k notin keep: keep.add k
    var trimmedGroups: OrderedTable[string, seq[Component]]
    for k, v in groups:
      if k in keep: trimmedGroups[k] = v
    result.truncated = groups.len - trimmedGroups.len
    groups = trimmedGroups

  # Nets a 0 V sense source split off merge back into the net it sensed.
  var alias: Table[string, string]
  for _, c in src.components:
    if isSenseSource(c) and c.pins.hasKey("+") and c.pins.hasKey("-") and
       c.pins["+"].net != nil and c.pins["-"].net != nil:
      alias[c.pins["-"].net.name] = c.pins["+"].net.name
  proc canon(name: string): string =
    result = name
    var guard = 0
    while result in alias and guard < 8:
      result = alias[result]
      inc guard

  var regionNets = initHashSet[string]()
  for n in region.nets: regionNets.incl canon(n)
  let gname = groundName(src)

  let view = newNetlist(src.name & "_view")
  proc netFor(name: string, kind: NetType): Net =
    let key = canon(name)
    if view.nets.hasKey(key): return view.nets[key]
    var k = kind
    let s = src.nets.getOrDefault(key)
    if s != nil: k = s.kind
    addNet(view, newNet(key, k))

  proc copyPart(designator: string, like: Component,
                pinNet: proc (p: Pin): Net): bool =
    ## Adds `designator` shaped like `like`; trims a many-pin part. True
    ## when trimmed.
    let c = addComponent(view, newComponent(designator, like.name,
                                            like.partNumber, like.kind))
    for k, v in like.attrs: c.attrs[k] = v
    let trim = like.pins.len > pinTrimMin
    for pname, p in like.pins:
      let n = pinNet(p)
      if n == nil: continue
      let onView = n.name in regionNets or isGround(n) or n.name == gname
      if trim and not onView:
        result = true
        continue
      discard connect(c, pname, netFor(n.name, n.kind), p.kind)

  # Every element of each displayed part, in or out of reach: a capacitor
  # whose ESL lies a net beyond the reach still folds.
  var members: Table[string, seq[Component]]
  for _, c in src.components:
    if not isSenseSource(c): members.mgetOrPut(displayOf(c), @[]).add c

  for key, inReach in groups:
    let elems = members.getOrDefault(key, inReach)
    let folds = elems.len > 1 or benchRole(elems[0]) in foldRoles
    let orig = if design != nil and folds: findComponent(design, key) else: nil
    if orig != nil and orig.subNetlist == nil:
      # A simulated element with the design pin's name says where that pin
      # really went (a loop broken at the inverting input).
      var simNet: Table[string, Net]
      # Only multi-pin stand-ins (a macromodel instance): a two-terminal
      # element's pins are `1`/`2` whatever it stands for.
      for c in elems:
        if c.pins.len <= 2: continue
        for pn, p in c.pins:
          if p.net != nil and pn.normPin notin simNet: simNet[pn.normPin] = p.net
      var trimmed = copyPart(key, orig, proc (p: Pin): Net =
        if p.net == nil: return nil
        if isGround(p.net): return src.nets.getOrDefault(gname,
                                     newNet(gname, ntGround))
        let sim = simNet.getOrDefault(p.name.normPin)
        if sim != nil and not isGround(sim) and sim.attrs.getOrDefault(
             benchOfKey, "").len == 0:
          return sim
        let f = flatName(p.net)
        result = src.nets.getOrDefault(f)
        if result == nil: result = newNet(f, p.net.kind))
      if trimmed: result.trimmed.add key
      var shown: seq[string]
      for c in elems:
        if c.designator != key:
          shown.add c.designator & " " & c.attrs.getOrDefault("value", c.kind)
      if shown.len > 0: result.folded.add (part: key, elements: shown)
    else:
      for c in inReach:
        if copyPart(c.designator, c, proc (p: Pin): Net = p.net):
          result.trimmed.add c.designator
    result.parts.add key

  result.netlist = view

proc viewKey*(v: View): string =
  ## Content key for a layout cache: two views with the same parts, pins
  ## and nets lay out identically.
  if v.netlist == nil: return ""
  var lines: seq[string]
  for d, c in v.netlist.components:
    var pins: seq[string]
    for pn, p in c.pins:
      pins.add pn & "=" & (if p.net == nil: "" else: p.net.name)
    lines.add d & "|" & c.kind & "|" & c.attrs.getOrDefault("value", "") &
              "|" & pins.join(",")
  lines.sort()
  lines.join("\n")
