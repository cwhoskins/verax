## Cutting a simulatable fragment out of a design. `spice/extract` turns a
## designator list into a standalone netlist with boundary ports; this adds:
##
## 1. **Choosing the list**: grown from seeds through parts fully described
##    by their value, stopping at anything needing a model or at a rail.
## 2. **Terminating the cut**: ground becomes node `"0"`, other rails get an
##    ideal source at nominal, open signal ports get a leak to ground.
##
## **The boundary is the result.** A rail is never traversed *through* (it
## would absorb every bypass cap), nor is an unmodellable part (recorded in
## `dropped`). `maxHops` is a backstop.
##
## Never mutates its input.

import std/[sets, strutils, tables]
import ../netlist/types
import ../netlist/graph
import ../netlist/kinds
import ../netlist/annotations
import ../netlist/formats/spice as spiceFormat
import ./extract

type
  IsolationSpec* = object
    name*: string
      ## Name for the resulting `Netlist` (becomes the deck title).
    maxHops*: int
      ## How many nets from a seed growth may reach -- a backstop; the rail
      ## and active-device rules normally stop it.
    stopKinds*: seq[string]
      ## Kinds that always cut even if absorbable (e.g. `@["fuse"]`).
    railVoltages*: OrderedTable[string, float]
      ## Net name -> nominal volts; overrides `Net.attrs["voltage"]`.
    groundNet*: string
      ## Which net becomes node `"0"`. Empty: an existing `"0"`, else the
      ## first `kinds.isGround` net.
    requireKnownRails*: bool
      ## When true (default), a rail with no known voltage raises.
    excludeRails*: seq[string]
      ## Rails **not** to drive with an ideal source: one is a dead short at
      ## AC, so terminating the rail being measured reports Z = 0. Left open,
      ## with the leak path.
    openPortLeak*: float
      ## Ohms to ground at each open signal port, or `0` for none (see
      ## `terminate`).

  Isolated* = object
    netlist*: Netlist
      ## Standalone and simulate-ready.
    seeds*: seq[string]
    absorbed*: seq[string]
      ## Components pulled in by the growth, in the order they were reached.
    dropped*: seq[string]
      ## Components touching the fragment that were cut: what the
      ## simulation does *not* account for.
    railNets*: seq[string]
      ## Nets terminated with an ideal source.
    openPorts*: seq[string]
      ## Nets left open for the caller: signal ports plus `excludeRails`.
    assumptions*: seq[Assumption]

proc defaultIsolationSpec*(name = "isolated"): IsolationSpec =
  IsolationSpec(name: name, maxHops: 4, requireKnownRails: true, openPortLeak: 1.0e9)

proc nominalVoltage(spec: IsolationSpec, net: Net): tuple[v: float, known: bool] =
  ## An explicit override wins, else the net's `voltage` annotation.
  if spec.railVoltages.hasKey(net.name):
    return (spec.railVoltages[net.name], true)
  let ann = annotations.railVoltage(net)
  if ann.has:
    return (ann.value, true)
  (0.0, false)

proc uniqueDesignator(nl: Netlist, base: string): string =
  result = base
  var n = 0
  while nl.components.hasKey(result):
    inc n
    result = base & "_" & $n

proc growSelection(nl: Netlist, seedDesignators: openArray[string], seedNets: openArray[Net],
                   spec: IsolationSpec): tuple[selected: seq[string], dropped: seq[string]] =
  var seedNetNames = initHashSet[string]()
  for n in seedNets: seedNetNames.incl n.name

  var selected = initOrderedSet[string]()
  for d in seedDesignators:
    if not nl.components.hasKey(d):
      raise newException(NetlistError, "no such component: " & d)
    selected.incl d

  var visited = initHashSet[string]()
  var queue: seq[tuple[net: Net, hop: int]]
  var droppedSeen = initHashSet[string]()
  var dropped: seq[string]

  template enqueue(n: Net, h: int) =
    if n != nil and n.name notin visited and h <= spec.maxHops:
      visited.incl n.name
      queue.add (net: n, hop: h)

  for d in seedDesignators:
    for _, p in nl.components[d].pins:
      enqueue(p.net, 0)
  for n in seedNets:
    enqueue(n, 0)

  var qi = 0
  while qi < queue.len:
    let (net, hop) = queue[qi]
    inc qi
    # A rail is a boundary, not a highway (every bypass cap shares VDD) --
    # unless the caller seeded it.
    if isRail(net) and net.name notin seedNetNames: continue

    for p in net.pins:
      let comp = p.component
      if comp == nil or comp.designator in selected: continue

      let unmodellable = comp.subNetlist != nil or not isPassive(comp) or
                         comp.kind in spec.stopKinds
      if unmodellable:
        if comp.designator notin droppedSeen:
          droppedSeen.incl comp.designator
          dropped.add comp.designator
        continue

      selected.incl comp.designator
      for _, other in comp.pins:
        if other.net != nil and other.net != net:
          enqueue(other.net, hop + 1)

  # A `K` coupling has no pins, so the walk never reaches it; pull it in
  # when both inductors are selected, or a transformer splits into two
  # independent windings.
  for _, comp in nl.components:
    if comp.kind notin couplingKinds or comp.designator in selected: continue
    let couples = comp.attrs.getOrDefault("spice.couples", "")
    if couples.len == 0: continue
    var both = true
    for d in couples.split(','):
      if d.strip() notin selected: both = false
    if both: selected.incl comp.designator

  var sel: seq[string]
  for d in selected: sel.add d
  (selected: sel, dropped: dropped)

proc terminate(frag: Netlist, spec: IsolationSpec, res: var Isolated) =
  ## Closes the cut boundary so the fragment is a real circuit.

  # --- ground becomes node "0" -----------------------------------------
  var gnd: Net = nil
  if spec.groundNet.len > 0:
    if not frag.nets.hasKey(spec.groundNet):
      raise newException(NetlistError,
        "ground net '" & spec.groundNet & "' is not in the isolated fragment " &
        "(it may not touch any selected component)")
    gnd = frag.nets[spec.groundNet]
  elif frag.nets.hasKey("0"):
    gnd = frag.nets["0"]
  else:
    for _, n in frag.nets:
      if isGround(n):
        gnd = n
        break
  if gnd == nil:
    raise newException(NetlistError,
      "no ground net in the isolated fragment: tag one ntGround, give a pin " &
      "ptGround, name it \"0\", or set IsolationSpec.groundNet")

  if gnd.name != "0":
    if frag.nets.hasKey("0"):
      raise newException(NetlistError,
        "cannot promote net '" & gnd.name & "' to SPICE node \"0\": the fragment " &
        "already has a distinct net named \"0\"; these are two different grounds " &
        "and merging them is a design decision, not a transform")
    renameNet(frag, gnd.name, "0")
  gnd.kind = ntGround

  # --- every other rail gets an ideal source ---------------------------
  # Collected first: adding sources adds nets and components.
  var rails: seq[Net]
  for _, n in frag.nets:
    if n == gnd: continue
    if isRail(n) or spec.railVoltages.hasKey(n.name): rails.add n

  var unterminated: seq[Net]
  for rail in rails:
    if rail.name in spec.excludeRails:
      unterminated.add rail
      continue
    var alreadyDriven = false
    for p in rail.pins:
      if p.component != nil and p.component.kind == "voltage_source":
        alreadyDriven = true
        break
    if alreadyDriven: continue

    let (v, known) = nominalVoltage(spec, rail)
    if not known:
      if spec.requireKnownRails:
        raise newException(NetlistError,
          "no nominal voltage for rail '" & rail.name & "': set it in " &
          "IsolationSpec.railVoltages or as Net.attrs[\"voltage\"] (or set " &
          "requireKnownRails = false to leave it floating)")
      res.assumptions.add note("rail '" & rail.name & "' left floating (no nominal voltage known)")
      unterminated.add rail
      continue

    let desig = uniqueDesignator(frag,
      $spiceFormat.designatorPrefix("voltage_source") & "_" & rail.name)
    let src = addComponent(frag, newComponent(desig, kind = "voltage_source"))
    discard connect(src, "+", rail, ptPower)
    discard connect(src, "-", gnd, ptGround)
    src.attrs["value"] = "DC " & spiceValue(v)
    res.railNets.add rail.name
    res.assumptions.add assumption(
      "rail '" & rail.name & "'", "voltage", v, "V", annDerived,
      "driven by an ideal source (the real supply's impedance and dynamics " &
      "are not modelled)")

  # --- open signal ports ------------------------------------------------
  # A floating node gives a singular matrix. A 1 Gohm leak provides a DC
  # reference without loading anything these analyses resolve.
  var openPorts: seq[tuple[name: string, net: Net]]
  var openSeen = initHashSet[string]()
  # An undriven rail needs the leak too (it reaches ground only through
  # capacitors).
  for rail in unterminated:
    if rail.name notin openSeen:
      openSeen.incl rail.name
      openPorts.add (name: rail.name, net: rail)
  # Excluded nets get the leak whether or not they're rails or ports: a net
  # at a high-impedance input has no DC path otherwise.
  for netName in spec.excludeRails:
    if frag.nets.hasKey(netName) and netName notin openSeen:
      openSeen.incl netName
      openPorts.add (name: netName, net: frag.nets[netName])
  for portName, n in frag.ports:
    if n == gnd or n.name in res.railNets: continue
    if isRail(n) and n.name notin spec.excludeRails: continue
    if n.name in openSeen: continue
    openSeen.incl n.name
    openPorts.add (name: portName, net: n)

  for (portName, n) in openPorts:
    res.openPorts.add portName
    if spec.openPortLeak > 0.0:
      let desig = uniqueDesignator(frag,
        $spiceFormat.designatorPrefix("resistor") & "_LEAK_" & n.name)
      let r = addComponent(frag, newComponent(desig, kind = "resistor"))
      discard connect(r, "1", n, ptPassive)
      discard connect(r, "2", gnd, ptPassive)
      r.attrs["value"] = spiceValue(spec.openPortLeak)
      r.attrs["isolate.leak"] = "true"
  if spec.openPortLeak > 0.0 and openPorts.len > 0:
    var names: seq[string]
    for (portName, _) in openPorts: names.add portName
    res.assumptions.add assumption(
      "open net(s) " & names.join(", "), "leak", spec.openPortLeak, "ohm", annDerived,
      "tied to ground to give them a DC reference")

proc isolateFrom*(nl: Netlist, seedDesignators, seedNetNames: openArray[string],
                  spec: IsolationSpec, globalNets: var OrderedTable[string, Net]): Isolated =
  ## The general form: seed from components, nets, or both. `nl` is never
  ## modified. Both at once suits start-up: the regulator plus its output
  ## rail (rails are expanded only when seeded).
  var seedNets: seq[Net]
  for name in seedNetNames:
    if not nl.nets.hasKey(name):
      raise newException(NetlistError, "no such net: " & name)
    seedNets.add nl.nets[name]

  let (selected, dropped) = growSelection(nl, seedDesignators, seedNets, spec)
  for d in seedDesignators: result.seeds.add d
  for d in selected:
    if d notin result.seeds: result.absorbed.add d
  result.dropped = dropped
  result.netlist = extractSubcircuit(nl, spec.name, selected, globalNets)
  terminate(result.netlist, spec, result)

proc isolate*(nl: Netlist, seedDesignators: openArray[string], spec: IsolationSpec,
              globalNets: var OrderedTable[string, Net]): Isolated =
  ## Grows from `seedDesignators`, extracts, and terminates.
  isolateFrom(nl, seedDesignators, [], spec, globalNets)

proc isolateNets*(nl: Netlist, seedNetNames: openArray[string], spec: IsolationSpec,
                  globalNets: var OrderedTable[string, Net]): Isolated =
  ## Seeds from nets: "everything hanging off this rail". The rail is
  ## expanded despite the rail rule; unmodellable parts on it go to
  ## `dropped` (for a PDN sweep, the ICs whose draw isn't modelled).
  isolateFrom(nl, [], seedNetNames, spec, globalNets)
