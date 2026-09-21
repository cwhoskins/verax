import std/[streams, strutils, tables, unittest]

import verax/netlist/dsl
import verax/netlist/graph
import verax/netlist/formats/spice as spiceFormat
import verax/netlist/formats/common
import verax/spice/flatten
import verax/spice/transform
import verax/spice/xspice

proc rcBlock(): Netlist =
  subckt("RC", [IN, OUT, GND]):
    net GND, kind = ntGround, name = "0"
    net IN, kind = ntSignal
    net OUT, kind = ntSignal
    net mid, kind = ntSignal
    component R1, kind = "resistor", value = "1k":
      pin "1", IN, kind = ptPassive
      pin "2", mid, kind = ptPassive
    component R2, kind = "resistor", value = "1k":
      pin "1", mid, kind = ptPassive
      pin "2", OUT, kind = ptPassive
    component C1, kind = "capacitor", value = "100n":
      pin "1", OUT, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0402"

proc board(): Netlist =
  netlist("board"):
    net gnd, kind = ntGround, name = "0", global = true
    net a, kind = ntSignal
    net b, kind = ntSignal
    net c, kind = ntSignal
    instance XA, rcBlock(), [a, b, gnd]
    instance XB, rcBlock(), [b, c, gnd]

suite "flattening hierarchy for simulation":

  test "an instance dissolves and its parts arrive under a hierarchical name":
    let nl = board()
    let f = flatten(nl)
    check "XA" in f.dissolved
    check "XB" in f.dissolved
    check nl.children.len == 0
    check nl.components.hasKey("XA.R1")
    check nl.components.hasKey("XB.C1")
    check not nl.components.hasKey("XA")

  test "two instances of one subcircuit do not collide":
    # The reason a stereo board is two instances rather than two copies: the
    # values are written once, and nothing here may merge them.
    let nl = board()
    discard flatten(nl)
    check nl.components["XA.R1"] != nl.components["XB.R1"]
    check nl.nets["XA.mid"] != nl.nets["XB.mid"]

  test "a port net merges into the parent net it was wired to":
    # A port is not a net of its own -- the net inside and the net outside
    # were always one conductor, joined by the instance pin.
    let nl = board()
    discard flatten(nl)
    check not nl.nets.hasKey("XA.OUT")
    check not nl.nets.hasKey("XB.IN")
    # XA's output and XB's input were both wired to `b`, so R1 of XB and C1
    # of XA must now share it.
    var onB: seq[string]
    for p in nl.nets["b"].pins: onB.add p.component.designator
    check "XA.C1" in onB
    check "XB.R1" in onB

  test "opened bus ports stay distinct after flattening":
    let openBus = subckt("OPEN_BUS", [S, DQ]):
      net S, kind = ntSignal
      bus DQ, width = 2
      component U1, kind = "ic":
        pin "S", S, kind = ptInput
        pin "D0", DQ[0], kind = ptInput
        pin "D1", DQ[1], kind = ptInput
    let nl = netlist("top"):
      instance XA, openBus, {"S": open, "DQ": open}

    # An opened group creates one marked scalar net per exposed port, not a
    # shared dangling net for the whole group.
    check nl.nets["nc_XA_S"].attrs["iface.nc"] == "1"
    check nl.nets["nc_XA_DQ_0"].attrs["iface.nc"] == "1"
    check nl.nets["nc_XA_DQ_1"].attrs["iface.nc"] == "1"
    check nl.nets["nc_XA_S"] != nl.nets["nc_XA_DQ_0"]
    check nl.nets["nc_XA_DQ_0"] != nl.nets["nc_XA_DQ_1"]

    discard flatten(nl)
    let u = nl.components["XA.U1"]
    check u.pins["S"].net == nl.nets["nc_XA_S"]
    check u.pins["D0"].net == nl.nets["nc_XA_DQ_0"]
    check u.pins["D1"].net == nl.nets["nc_XA_DQ_1"]
    check u.pins["S"].net != u.pins["D0"].net
    check u.pins["D0"].net != u.pins["D1"].net

  test "ground stays one net rather than becoming XA.0":
    let nl = board()
    discard flatten(nl)
    check nl.nets.hasKey("0")
    check not nl.nets.hasKey("XA.0")
    check not nl.nets.hasKey("XB.0")

  test "annotations and role tags survive being re-homed":
    # `adopt*` moves the object rather than copying it, precisely so that
    # `attrs` -- which carries voltage, esr, and the role.* membership tags
    # that must outlive any transform -- comes along untouched.
    let nl = board()
    nl.children["XA"].components["C1"].attrs["role.bus0"] = "filter"
    discard flatten(nl)
    check nl.components["XA.C1"].attrs["package"] == "0402"
    check nl.components["XA.C1"].attrs["role.bus0"] == "filter"

  test "provenance records which instance a part came out of":
    let nl = board()
    let f = flatten(nl)
    check nl.components["XA.R1"].attrs[flattenProvenance] == "XA"
    check f.renamed["XA.R1"] == "XA.R1"

  test "keep leaves an instance intact":
    let nl = board()
    let f = flatten(nl, ["XA"])
    check f.kept == @["XA"]
    check nl.components.hasKey("XA")
    check nl.children.hasKey("XA")
    check nl.components.hasKey("XB.R1")

  test "a keep entry matching no instance raises rather than protecting nothing":
    # The hazard it guards against is that the thing it was meant to protect
    # gets dissolved and the failure surfaces three steps later as a missing
    # component -- the same shape as a misspelled `without` suffix.
    let nl = board()
    expect NetlistError:
      discard flatten(nl, ["XZ"])

  test "nesting flattens innermost first and composes the names":
    let inner = subckt("INNER", [P, G]):
      net G, kind = ntGround, name = "0"
      net P, kind = ntSignal
      component R9, kind = "resistor", value = "10k":
        pin "1", P, kind = ptPassive
        pin "2", G, kind = ptPassive
    let outer = subckt("OUTER", [Q, G2]):
      net G2, kind = ntGround, name = "0"
      net Q, kind = ntSignal
      instance XI, inner, [Q, G2]
    let nl = netlist("top"):
      net gnd, kind = ntGround, name = "0", global = true
      net n, kind = ntSignal
      instance XO, outer, [n, gnd]
    discard flatten(nl)
    check nl.components.hasKey("XO.XI.R9")

  test "identical model cards collapse, conflicting ones are mangled":
    # `xspice/instance` derives a `.MODEL` name from the designator, so two
    # instances of one block really do register the same name twice.
    proc diodeBlock(card: string): Netlist =
      subckt("D", [A, K]):
        net A, kind = ntSignal
        net K, kind = ntSignal
        model "PART", card
        component D1, kind = "diode", value = "PART":
          pin "A", A, kind = ptPassive
          pin "K", K, kind = ptPassive
    let same = netlist("same"):
      net p, kind = ntSignal
      net q, kind = ntSignal
      net r, kind = ntSignal
      instance XA, diodeBlock("D(IS=1n)"), [p, q]
      instance XB, diodeBlock("D(IS=1n)"), [q, r]
    discard flatten(same)
    check same.models.len == 1
    check same.components["XB.D1"].attrs["value"] == "PART"

    let differ = netlist("differ"):
      net p, kind = ntSignal
      net q, kind = ntSignal
      net r, kind = ntSignal
      instance XA, diodeBlock("D(IS=1n)"), [p, q]
      instance XB, diodeBlock("D(IS=5n)"), [q, r]
    discard flatten(differ)
    check differ.models.len == 2
    check differ.models.hasKey("XB.PART")
    # and the part that needed the mangled card now names it
    check differ.components["XB.D1"].attrs["value"] == "XB.PART"

  test "the flattened deck carries no subcircuit and spells devices correctly":
    # A flattened `XA.R1` starts with `X`, which SPICE reads as a subcircuit
    # call. `deckDesignator` takes the letter from `kind` and *prepends* it,
    # so the line is `RXA.R1` -- the same invariant that turns `FB1` into
    # `LFB1`, now load-bearing far more often.
    let nl = board()
    discard flatten(nl)
    let s = newStringStream()
    writeNetlist(nl, s)
    let deck = s.data
    check ".SUBCKT" notin deck.toUpperAscii
    check "RXA.R1" in deck
    check "CXB.C1" in deck

  test "flattening is idempotent":
    let nl = board()
    discard flatten(nl)
    let again = flatten(nl)
    check again.dissolved.len == 0
    check nl.components.hasKey("XA.R1")

suite "name collisions flattening produces, and the ones it cannot":

  test "a generated name colliding with an existing one names both sides":
    # The instance designator is unique among its siblings by construction, so
    # sibling instances never collide. What can collide is a name the design
    # already spelled the way flatten is about to.
    let nl = netlist("top"):
      net gnd, kind = ntGround, name = "0", global = true
      net a, kind = ntSignal
      component "XA.R1", kind = "resistor", value = "9k":
        pin "1", a, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      instance XA, rcBlock(), [a, a, gnd]
    var msg = ""
    try:
      discard flatten(nl)
    except NetlistError as e:
      msg = e.msg
    check "XA.R1" in msg
    check "flattening instance 'XA'" in msg      # where the new name came from
    check "resistor" in msg                       # and what already held it
    check "9k" in msg

  test "a colliding internal net says the same":
    let nl = netlist("top"):
      net gnd, kind = ntGround, name = "0", global = true
      net a, kind = ntSignal
      net "XA.mid", kind = ntSignal
      instance XA, rcBlock(), [a, a, gnd]
    var msg = ""
    try:
      discard flatten(nl)
    except NetlistError as e:
      msg = e.msg
    check "XA.mid" in msg
    check "flattening instance 'XA'" in msg

  test "graph uniqueness does not imply deck uniqueness":
    # `deckDesignator` *prepends* the device letter from `kind` rather than
    # substituting it -- which is what stops `FB1` and `L1` collapsing onto
    # one name, and is deliberately not reversible. So two components that
    # are distinct in the graph can be one line in the deck. Flatten makes
    # generated dotted designators ordinary, which is what moves this from
    # theoretical to reachable.
    let nl = netlist("top"):
      net gnd, kind = ntGround, name = "0", global = true
      net a, kind = ntSignal
      component "RXA.R1", kind = "resistor", value = "9k":
        pin "1", a, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      instance XA, rcBlock(), [a, a, gnd]
    discard flatten(nl)
    check nl.components.hasKey("XA.R1")
    check nl.components.hasKey("RXA.R1")          # distinct in the graph
    let s = newStringStream()
    var msg = ""
    try:
      writeNetlist(nl, s)
    except NetlistFormatError as e:
      msg = e.msg
    check "RXA.R1" in msg
    check "XA.R1" in msg
    check "defined twice" in msg

  test "and the ordinary case still writes":
    let nl = board()
    discard flatten(nl)
    let s = newStringStream()
    writeNetlist(nl, s)
    check "RXA.R1" in s.data

suite "flatten before applySimReplacements, for a nested XSPICE component":
  # The pairing that fixed the bug `designs/lib/lt8640a_config.nim` found and
  # documented: `test_spice_transform.nim` proves the ports string freezes
  # to the right names in isolation, and this proves the two passes
  # actually compose into a deck ngspice can read -- no `.SUBCKT`, and the
  # `A` line naming nets that exist.

  proc gainSpec(): ModelSpec =
    ModelSpec(
      name: "nimgain", cFunction: "cm_nimgain", description: "gain",
      ports: @[
        PortSpec(name: "inp", dir: xdIn, default: xpV, allowed: @[xpV]),
        PortSpec(name: "outp", dir: xdOut, default: xpV, allowed: @[xpV])],
      params: @[ParamSpec(name: "gain", dataType: xtReal, default: "1.0",
                          nullAllowed: true)])

  proc buildGainStandin(nl: Netlist, old: Component): Component =
    ## As `test_spice_transform.nim`'s: prepend `"A"` to whatever designator
    ## `old` carries when this runs, dotted and all.
    let inNet = old.pins["IN"].net
    let outNet = old.pins["OUT"].net
    let desig = old.designator
    removeComponent(nl, desig)
    result = addCodeModelInstance(nl, "A" & desig, gainSpec(), [inNet, outNet])

  test "flatten then applySimReplacements produces a deck with a flat A line and no .SUBCKT":
    let templ = subckt("AMP", [IN, OUT]):
      net IN, kind = ntSignal
      net OUT, kind = ntSignal
      component U1, kind = "amplifier":
        pin "IN", IN, kind = ptInput
        pin "OUT", OUT, kind = ptOutput
    templ.components["U1"].simReplace = newSimReplacement(buildGainStandin, name = "cm")

    let nl = netlist("top"):
      net vin, kind = ntSignal
      net vout, kind = ntSignal
      instance XA, templ, [vin, vout]

    discard flatten(nl)
    applySimReplacements(nl)

    check nl.components.hasKey("AXA.U1")
    let ports = nl.components["AXA.U1"].attrs["xspice.ports"]
    check "vin" in ports and "vout" in ports
    check "IN" notin ports and "OUT" notin ports

    let s = newStringStream()
    writeNetlist(nl, s)
    let deck = s.data
    check ".SUBCKT" notin deck.toUpperAscii
    check "AXA.U1 vin vout" in deck

  test "the old order (replace, then flatten) leaves the deck's A line naming nets that do not exist":
    ## The bug, end to end through a written deck rather than the frozen
    ## attribute alone: `materializeSimNetlist` (replace while still nested)
    ## followed by `flatten` is what every analysis used to do, and this is
    ## what an ngspice deck derived that way actually contained.
    let templ = subckt("AMP2", [IN, OUT]):
      net IN, kind = ntSignal
      net OUT, kind = ntSignal
      component U1, kind = "amplifier":
        pin "IN", IN, kind = ptInput
        pin "OUT", OUT, kind = ptOutput
    templ.components["U1"].simReplace = newSimReplacement(buildGainStandin, name = "cm")

    let nl = netlist("top2"):
      net vin, kind = ntSignal
      net vout, kind = ntSignal
      instance XA, templ, [vin, vout]

    var globalNets: OrderedTable[string, Net]
    let work = materializeSimNetlist(nl, globalNets)
    discard flatten(work)

    check work.components.hasKey("XA.AU1")
    let s = newStringStream()
    writeNetlist(work, s)
    let deck = s.data
    # The A line is written verbatim from the frozen string -- "IN"/"OUT",
    # not "vin"/"vout" -- so it names nodes nothing else in the flattened
    # deck uses. `net.pins.len` accounting elsewhere in this suite is what
    # would go wrong reading a deck like this into ngspice: two floating
    # nodes and a duplicate "vin"/"vout" pair with no device on them.
    check "XA.AU1 IN OUT" in deck
    check "XA.AU1 vin vout" notin deck
