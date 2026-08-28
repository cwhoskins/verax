## Cutting a simulatable fragment out of a full design netlist.
##
## `nimcir/spice/extract` already answers "given this exact list of
## designators, give me a standalone netlist with the boundary nets promoted
## to ports". That is the mechanical half. Two things are missing before the
## result can actually be simulated, and this module supplies both:
##
## 1. **Choosing the list.** In practice you know one or two components you
##    care about -- a regulator, an op-amp, a rail -- not the twenty passives
##    around them. So the selection is *grown* outward from those seeds
##    through parts whose behaviour is fully described by their value, and
##    stopped at anything that would need a model (another IC, a transistor)
##    or at a power rail.
## 2. **Terminating what was cut.** A fragment with open ports, no node `"0"`
##    and no excitation is not a circuit; ngspice will report a singular
##    matrix or simply refuse. So the promoted boundary is *closed*: the
##    ground rail becomes node `"0"`, every other rail gets an ideal source
##    at its nominal voltage, and open signal ports get a leak path to ground.
##
## **Where the boundary is drawn is the whole result.** Grow too far and you
## are simulating the board; stop too early and you have deleted the load
## that made the answer interesting. Two rules do the work: a rail is never
## traversed *through* (every decoupling capacitor on a board hangs off the
## same VDD, so one hop through it absorbs everything), and an unmodellable
## component is never traversed through either (it is recorded in `dropped`,
## so the caller can see exactly what was thrown away). `maxHops` is a
## backstop, not the primary mechanism.
##
## Nothing here mutates the netlist it is given: `extractSubcircuit` clones
## first, and every mutation lands on that clone.

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
      ## How many nets away from a seed the growth may reach. A backstop
      ## against a pathological topology; the rail and active-device rules
      ## are what normally stop it.
    stopKinds*: seq[string]
      ## Component kinds that always cut, even though they would otherwise
      ## be absorbed -- e.g. `@["fuse"]` to keep a fuse out of a fragment.
    railVoltages*: OrderedTable[string, float]
      ## Net name -> nominal volts. Takes precedence over
      ## `Net.attrs["voltage"]`.
    groundNet*: string
      ## Which net becomes SPICE node `"0"`. Empty means "find it": an
      ## existing `"0"`, else the first net that `kinds.isGround` accepts.
    requireKnownRails*: bool
      ## When true (the default), a rail with no known voltage raises rather
      ## than being quietly left floating or guessed at.
    excludeRails*: seq[string]
      ## Rails that must **not** be driven by an ideal source. An ideal
      ## voltage source is a dead short at AC, so terminating the rail whose
      ## impedance you are measuring would report Z = 0 at every frequency --
      ## the measurement would destroy itself. Such a rail is left open (and
      ## given the leak path below, so it still has a DC reference).
    openPortLeak*: float
      ## Ohms to ground added at each open signal port, or `0` to add none.
      ## See `terminate` for why this exists.

  Isolated* = object
    netlist*: Netlist
      ## Standalone and simulate-ready.
    seeds*: seq[string]
    absorbed*: seq[string]
      ## Components pulled in by the growth, in the order they were reached.
    dropped*: seq[string]
      ## Components that touched the fragment but were cut at the boundary.
      ## Worth showing a user: it is the list of things whose behaviour the
      ## simulation is *not* accounting for.
    railNets*: seq[string]
      ## Nets terminated with an ideal source.
    openPorts*: seq[string]
      ## Nets left open for the caller to stimulate, load or measure --
      ## promoted signal ports plus any `excludeRails` entry.
    assumptions*: seq[Assumption]

proc defaultIsolationSpec*(name = "isolated"): IsolationSpec =
  IsolationSpec(name: name, maxHops: 4, requireKnownRails: true, openPortLeak: 1.0e9)

proc nominalVoltage(spec: IsolationSpec, net: Net): tuple[v: float, known: bool] =
  ## An explicit override wins; otherwise the net's own `voltage` annotation,
  ## read through `netlist/annotations` so the parse rules and the error
  ## message are the same ones every other consumer gets.
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
    # A rail is a boundary, not a highway. Every bypass capacitor on the
    # board shares VDD, so traversing through it would absorb the design.
    # A rail named as an explicit seed is the exception: that is where the
    # caller asked to start, not somewhere the walk wandered into.
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

  # A `mutual_inductance` (SPICE `K` card) has no pins, so the walk above
  # never reaches it. Pull one in whenever both inductors it couples are
  # already selected -- otherwise a common-mode choke or a transformer
  # isolates into two independent windings and the fragment is a different
  # circuit, with nothing said about it.
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
  # Collected before mutating, since adding sources adds nets and components.
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
  # A promoted port with nothing on the far side is a floating node, and a
  # floating node is how an isolated fragment turns into "singular matrix"
  # rather than a result. A leak resistor to ground gives every such node a
  # DC reference without materially loading it -- at 1 Gohm it is far below
  # any impedance these analyses resolve -- and the caller usually replaces
  # it with a real stimulus or load anyway.
  var openPorts: seq[tuple[name: string, net: Net]]
  var openSeen = initHashSet[string]()
  # An undriven rail needs the leak path just as much as an open signal port
  # does -- more so, since a rail reaches ground only through capacitors and
  # so has no DC path at all without it.
  for rail in unterminated:
    if rail.name notin openSeen:
      openSeen.incl rail.name
      openPorts.add (name: rail.name, net: rail)
  # Anything the caller excluded is by definition something they intend to
  # drive or measure themselves, so it is open until they do. It gets the
  # leak whether or not it is a rail and whether or not it became a port: a
  # net at a high-impedance input (an op-amp's own `+` pin, say) has no DC
  # path to ground at all, and ngspice answers that with a singular matrix.
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
  ## The general form: seed from components, from nets, or from both. `nl` is
  ## never modified.
  ##
  ## Seeding from both at once is what a start-up analysis needs -- the
  ## regulator is the component of interest, but its output rail must also be
  ## expanded to pick up the capacitor bank whose charging *is* the inrush,
  ## and a rail is never expanded unless it was named a seed.
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
  ## Grows a selection outward from `seedDesignators`, extracts it, and
  ## terminates the boundary.
  isolateFrom(nl, seedDesignators, [], spec, globalNets)

proc isolateNets*(nl: Netlist, seedNetNames: openArray[string], spec: IsolationSpec,
                  globalNets: var OrderedTable[string, Net]): Isolated =
  ## Seeds from nets rather than components: "everything hanging off this
  ## rail", which is how a decoupling network is actually specified. A rail
  ## given here is expanded even though the growth otherwise refuses to
  ## traverse through rails, and the unmodellable components hanging off it
  ## are still recorded in `dropped` -- for a PDN sweep that list is the ICs
  ## whose actual current draw the simulation is not representing.
  isolateFrom(nl, [], seedNetNames, spec, globalNets)
