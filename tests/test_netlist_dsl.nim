import std/[strutils, streams, tables, unittest, streams]

import verax/netlist/dsl
import verax/netlist/kinds
import verax/netlist/formats/spice

test "flat netlist built with the DSL matches hand-built structure":
  let nl = netlist("divider"):
    net vin, kind = ntSignal
    net vout, kind = ntSignal
    net gnd, kind = ntGround, name = "0"

    component R1, kind = "resistor", partNumber = "RC0603", tolerance = "5%":
      pin "1", vin, kind = ptPassive
      pin "2", vout, kind = ptPassive

    component R2, kind = "resistor", partNumber = "RC0603":
      pin "1", vout, kind = ptPassive
      pin "2", gnd, kind = ptPassive

  check nl.name == "divider"
  check nl.nets["0"].name == "0"
  check nl.nets["0"].kind == ntGround

  check nl.components["R1"].kind == "resistor"
  check nl.components["R1"].partNumber == "RC0603"
  check nl.components["R1"].attrs["tolerance"] == "5%"
  check nl.components["R2"].attrs.hasKey("tolerance") == false

  check nl.components["R1"].pins["1"].net.name == "vin"
  check nl.components["R1"].pins["2"].net.name == "vout"
  check nl.components["R1"].pins["1"].kind == ptPassive

  let voutComponents = connectedComponents(nl.nets["vout"])
  check voutComponents.len == 2

test "component/net designator overrides and string-literal labels work":
  let nl = netlist("t"):
    net "weird net name", kind = ntSignal
    component "weird designator", kind = "misc"

  check nl.nets.hasKey("weird net name")
  check nl.components.hasKey("weird designator")

test "a multi-dimensional bus needs no macro change, only a new addBus overload":
  ## `width =`'s expression passes straight to `addBus` (`handleBus`), so
  ## `width = [8, 2]` resolves to the new `openArray[int]` overload with no
  ## change to the DSL itself.
  let nl = netlist("t"):
    bus a, width = [8, 2]
    component U1, kind = "mcu":
      pin "A0", a[3, 0], kind = ptInput
      pin "A1", a[3, 1], kind = ptInput

  check nl.nets.hasKey("a_3_0")
  check nl.nets.hasKey("a_3_1")
  check findBus(nl, "a").dims == @[8, 2]

test "net [a, b, c], kind = ... declares a group sharing one kind":
  let nl = netlist("group"):
    net [a, b, c], kind = ntSignal
    net gnd, kind = ntGround, name = "0"
    component R1, kind = "resistor", value = "1k":
      pin "1", a, kind = ptPassive
      pin "2", b, kind = ptPassive

  check nl.nets.len == 4
  for n in ["a", "b", "c"]:
    check nl.nets[n].kind == ntSignal
  # Each name is a real bound identifier, not a runtime loop variable, so it
  # stays addressable for the rest of the block -- `a`/`b` above wired R1.
  check nl.components["R1"].pins["1"].net.name == "a"

test "net [...] entries may be string literals too, with no identifier bound":
  let nl = netlist("group"):
    net ["odd name 1", "odd name 2"], kind = ntSignal
  check nl.nets.hasKey("odd name 1")
  check nl.nets.hasKey("odd name 2")

test "net [...], global = true registers every net in the group globally":
  let GATE = subckt("GATE", [A, B]):
    net A, kind = ntSignal
    net B, kind = ntSignal
    component U1, kind = "ic":
      pin "A", A, kind = ptInput
      pin "B", B, kind = ptInput
  let top = netlist("top"):
    net [ga, gb], kind = ntSignal, global = true
    instance "X1", GATE, [ga, gb]
  check top.components["X1"].pins["A"].net == top.nets["ga"]
  check top.components["X1"].pins["B"].net == top.nets["gb"]

test "net [...], name = ... is refused: it would name every net alike":
  check(not compiles(block:
    discard netlist("bad"):
      net [a, b], kind = ntSignal, name = "shared"))

test "an empty net [] is refused rather than silently declaring nothing":
  check(not compiles(block:
    discard netlist("bad"):
      net [], kind = ntSignal))

test "unknown key on net/component/pin lands in attrs, not a compile error":
  let nl = netlist("t"):
    net n1, tolerance = "1%"
    component U1, footprint = "SOT23":
      pin "A", n1, note = "test"

  check nl.nets["n1"].attrs["tolerance"] == "1%"
  check nl.components["U1"].attrs["footprint"] == "SOT23"
  check nl.components["U1"].pins["A"].attrs["note"] == "test"

test "a genuine type mismatch on a known field fails to compile":
  check(not compiles(block:
    discard netlist("t"):
      net n1, kind = "not a NetType"
  ))

test "subckt template is not registered into any parent, and instance clones independently":
  let GATE = subckt("GATE", [VDD, GND]):
    net VDD, kind = ntPower
    net GND, kind = ntGround, name = "0"
    component U1, kind = "ic":
      pin "A", VDD, kind = ptPower
      pin "B", GND, kind = ptGround

  check GATE.parent == nil
  check GATE.ports.hasKey("VDD")
  check GATE.ports.hasKey("GND")

  let top = netlist("TOP"):
    net gnd, kind = ntGround, name = "0", global = true
    net vddA, kind = ntPower
    net vddB, kind = ntPower

    instance "X1", GATE, [vddA, gnd]
    instance "X2", GATE, [vddB, gnd]

  check top.components["X1"].subNetlist != top.components["X2"].subNetlist
  check top.components["X1"].pins["GND"].net == top.nets["0"]
  check top.components["X1"].pins["GND"].hierNet == top.components["X2"].pins["GND"].hierNet
  check top.components["X1"].pins["GND"].hierNet == top.nets["0"]
  check top.components["X1"].pins["VDD"].net == top.nets["vddA"]
  check top.components["X2"].pins["VDD"].net == top.nets["vddB"]
  check top.components["X1"].subNetlist.parent == top
  check top.components["X1"].subNetlist.instanceOf == top.components["X1"]

test "named instance groups can be explicitly opened":
  let linkDef = interfaceDef("dsl_open_link"):
    signal valid
    signal data, width = 2
    modport target:
      valid = ptInput
      data = ptInput
  let peripheral = subckt("PERIPHERAL", [sense, link.target]):
    net sense, kind = ntSignal
    iface link, linkDef
    component U1, kind = "ic":
      pin "SENSE", sense, kind = ptInput
      port link, target

  let top = netlist("top"):
    net wired, kind = ntSignal
    instance XOPEN, peripheral, {"sense": open, "link": open}
    # A named scalar connection remains ordinary wiring while another group
    # is explicitly open.
    instance XWIRED, peripheral, {"sense": wired, "link": open}

  let opened = top.components["XOPEN"]
  check opened.pins["sense"].net.name == "nc_XOPEN_sense"
  check opened.pins["link_valid"].net.name == "nc_XOPEN_link_valid"
  check opened.pins["link_data_0"].net.name == "nc_XOPEN_link_data_0"
  check opened.pins["link_data_1"].net.name == "nc_XOPEN_link_data_1"
  for pinName in ["sense", "link_valid", "link_data_0", "link_data_1"]:
    check opened.pins[pinName].net.attrs["iface.nc"] == "1"
  check opened.pins["sense"].net != opened.pins["link_valid"].net
  check opened.pins["link_data_0"].net != opened.pins["link_data_1"].net
  check top.components["XWIRED"].pins["sense"].net == top.nets["wired"]

  expect NetlistError:
    discard netlist("bad"):
      instance XBAD, peripheral, {"absent": open}

test "a model statement registers a card that reaches the deck verbatim":
  let nl = netlist("d"):
    net a, kind = ntSignal
    net gnd, kind = ntGround, name = "0"
    model "1N4148", "D(IS=2.52n RS=0.568 N=1.752)"
    component D1, kind = "diode", value = "1N4148":
      pin "A", a, kind = ptPassive
      pin "K", gnd, kind = ptPassive
  check nl.models["1N4148"] == "D(IS=2.52n RS=0.568 N=1.752)"

  let s = newStringStream()
  writeNetlist(nl, s)
  check ".MODEL 1N4148 D(IS=2.52n RS=0.568 N=1.752)" in s.data
  check "D1 a 0 1N4148" in s.data

test "a part whose value names a model is no longer unmodelled":
  # Which is the point: without one a diode was stood in for by two
  # resistors to ground, and `spice/isolate` would not traverse it.
  let nl = netlist("d"):
    net a, kind = ntSignal
    net gnd, kind = ntGround, name = "0"
    model "1N4148", "D(IS=2.52n)"
    component D1, kind = "diode", value = "1N4148":
      pin "A", a, kind = ptPassive
      pin "K", gnd, kind = ptPassive
    component D2, kind = "diode", value = "1N5819":
      pin "A", a, kind = ptPassive
      pin "K", gnd, kind = ptPassive
  check hasDeviceModel(nl.components["D1"])
  check isPassive(nl.components["D1"])
  # D2 names a model nobody registered.
  check not hasDeviceModel(nl.components["D2"])
  check not isPassive(nl.components["D2"])

test "model binding is case-insensitive, as SPICE is":
  # A deck saying `1n4148` against a card saying `1N4148` binds in the
  # simulator, and a check that disagreed with the simulator about the same
  # part is the failure this area keeps producing.
  let nl = netlist("d"):
    net a, kind = ntSignal
    net gnd, kind = ntGround, name = "0"
    model "1N4148", "D(IS=2.52n)"
    component D1, kind = "diode", value = "1n4148":
      pin "A", a, kind = ptPassive
      pin "K", gnd, kind = ptPassive
  check hasDeviceModel(nl.components["D1"])

test "a value that is a source spec is not mistaken for a model name":
  let nl = netlist("d"):
    net a, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    model "AC", "D(IS=1n)"
    component V1, kind = "voltage_source", value = "DC 0 AC 1":
      pin "+", a, kind = ptPower
      pin "-", gnd, kind = ptGround
  check not hasDeviceModel(nl.components["V1"])

test "a model needs a name":
  var nl = newNetlist("d")
  expect NetlistError:
    setModel(nl, "", "D(IS=1n)")

suite "control flow over DSL statements":
  # `for`, `if`, `case` and `when` are admitted the same way: the header is
  # passed through untouched and every branch body is expanded by the same
  # dispatcher, so whatever is inside is still a net/component/instance/model.
  # `for` removes repetition; `if`/`case` remove the other way a value drifts
  # out of step -- build variants kept as two files, or as one file with the
  # unused half commented out.

  test "a repeated part is generated once and registered N times":
    let nl = netlist("bank"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      for i in 1 .. 8:
        component C, designator = "C" & $i, kind = "capacitor", value = "100n":
          pin "1", vdd, kind = ptPassive
          pin "2", gnd, kind = ptPassive
          spec:
            package = "0402"
    check nl.components.len == 8
    check nl.components["C5"].attrs["package"] == "0402"
    check nl.nets["vdd"].pins.len == 8

  test "values, designators and spec entries may all vary per iteration":
    let bank = @[("C10", "10u", "0805"), ("C11", "1u", "0603")]
    let nl = netlist("bank2"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      for (d, v, pkg) in bank:
        component C, designator = d, kind = "capacitor", value = v:
          pin "1", vdd, kind = ptPassive
          pin "2", gnd, kind = ptPassive
          spec:
            package = pkg
    check nl.components["C11"].attrs["value"] == "1u"
    check nl.components["C11"].attrs["package"] == "0603"

  test "nets can be generated too":
    let nl = netlist("taps"):
      net gnd, kind = ntGround, name = "0"
      for i in 1 .. 4:
        net t, name = "tap" & $i, kind = ntSignal
    check nl.nets.len == 5
    check nl.nets.hasKey("tap3")

  test "a loop whose naming does not vary fails exactly as two literals would":
    # `addComponent` has always raised at runtime rather than at compile time,
    # so nothing is weakened here.
    expect NetlistError:
      discard netlist("dup"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        for i in 1 .. 3:
          component C, kind = "capacitor", value = "100n":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive

  test "the body stays a closed vocabulary":
    check(not compiles(block:
      discard netlist("bad"):
        net gnd, kind = ntGround, name = "0"
        for i in 1 .. 2:
          echo "not a DSL statement"))

  test "spec: keys are still validated at compile time inside a loop":
    # The strictness that matters does not depend on how many times the body
    # runs, so none of it is weakened by looping.
    check(not compiles(block:
      discard netlist("badkey"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        for i in 1 .. 2:
          component C, designator = "C" & $i, kind = "capacitor", value = "1n":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive
            spec:
              ESL = 1.nH))

  test "if and else each build their own variant":
    proc board(bulk: bool): Netlist =
      netlist("b"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        if bulk:
          component C1, kind = "capacitor", value = "220u":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive
            spec:
              package = "electrolytic"
        else:
          component C1, kind = "capacitor", value = "10u":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive
            spec:
              package = "0805"
    check board(true).components["C1"].attrs["value"] == "220u"
    check board(true).components["C1"].attrs["package"] == "electrolytic"
    check board(false).components["C1"].attrs["value"] == "10u"

  test "case picks a branch, including its else":
    proc board(v: int): Netlist =
      netlist("b"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        case v
        of 1:
          component R1, kind = "resistor", value = "1k":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive
        of 2:
          component R1, kind = "resistor", value = "10k":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive
        else:
          component R1, kind = "resistor", value = "100k":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive
    check board(1).components["R1"].attrs["value"] == "1k"
    check board(2).components["R1"].attrs["value"] == "10k"
    check board(9).components["R1"].attrs["value"] == "100k"

  test "a for nests inside an if":
    proc board(populate: bool): Netlist =
      netlist("b"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        if populate:
          for i in 1 .. 3:
            component C, designator = "CD" & $i, kind = "capacitor", value = "100n":
              pin "1", vdd, kind = ptPassive
              pin "2", gnd, kind = ptPassive
    check board(true).components.len == 3
    check board(false).components.len == 0

  test "when switches at compile time":
    let nl = netlist("b"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      when defined(veraxNoSuchDefine):
        component R1, kind = "resistor", value = "1k":
          pin "1", vdd, kind = ptPassive
          pin "2", gnd, kind = ptPassive
      else:
        component R1, kind = "resistor", value = "9k":
          pin "1", vdd, kind = ptPassive
          pin "2", gnd, kind = ptPassive
    check nl.components["R1"].attrs["value"] == "9k"

  test "a bare discard is an empty branch":
    # `if`/`case` branches need a body, and "this variant adds no parts" is an
    # ordinary thing for one to say.
    proc board(extra: bool): Netlist =
      netlist("b"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        if extra:
          component R1, kind = "resistor", value = "1k":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive
        else:
          discard
    check board(true).components.len == 1
    check board(false).components.len == 0

  test "but discard of an expression is arbitrary code wearing a keyword":
    check(not compiles(block:
      discard netlist("b"):
        net gnd, kind = ntGround, name = "0"
        if true:
          discard openArray[int]))

  test "strictness holds inside a branch, not just at the top level":
    check(not compiles(block:
      discard netlist("b"):
        net gnd, kind = ntGround, name = "0"
        if true:
          echo "arbitrary code"))
    check(not compiles(block:
      discard netlist("b"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        case 1
        of 1:
          component C1, kind = "capacitor", value = "1n":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive
            spec:
              ESR = 1.mohm
        else: discard))

suite "designators you did not write":
  # For the parts nobody ever refers to -- a decoupling bank, a termination
  # network -- where hand-authoring twenty designators buys nothing. Safe
  # *because* nothing addresses them: a generated designator is positional,
  # so inserting a part earlier renumbers everything after it.

  test "omitting the label generates one from kind":
    let nl = netlist("b"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      for i in 1 .. 3:
        component kind = "capacitor", value = "100n":
          pin "1", vdd, kind = ptPassive
          pin "2", gnd, kind = ptPassive
    check nl.components.len == 3
    check nl.components.hasKey("C1")
    check nl.components.hasKey("C3")
    check nl.components["C2"].kind == "capacitor"

  test "hand-authored designators are respected, not overwritten":
    let nl = netlist("b"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      component C1, kind = "capacitor", value = "22u":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      component kind = "capacitor", value = "100n":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
    check nl.components["C1"].attrs["value"] == "22u"
    check nl.components["C2"].attrs["value"] == "100n"

  test "the prefix is the schematic convention, not the SPICE device letter":
    # They genuinely disagree, and deriving either from the other is how a
    # ferrite bead came to be simulated as a current-controlled current
    # source. FB on a board; L in a deck.
    let nl = netlist("b"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      component kind = "ferrite_bead", value = "600":
        pin "1", a, kind = ptPassive
        pin "2", b, kind = ptPassive
      component kind = "opamp":
        pin "OUT", b, kind = ptOutput
    check nl.components.hasKey("FB1")
    check nl.components.hasKey("U1")

  test "an unregistered kind falls back to U, and can be registered":
    let nl = netlist("b"):
      net a, kind = ntSignal
      component kind = "widget":
        pin "A", a, kind = ptPassive
    check nl.components.hasKey("U1")
    registerDesignatorPrefix("widget", "WD")
    let nl2 = netlist("b2"):
      net a, kind = ntSignal
      component kind = "widget":
        pin "A", a, kind = ptPassive
    check nl2.components.hasKey("WD1")

  test "generated ones are marked, so a board flow can tell them apart":
    # A designator is the join key to a layout, a BoM line and silkscreen
    # text. One this library chose is positional and must not be trusted to
    # be stable the way a written one is.
    let nl = netlist("b"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      component C1, kind = "capacitor", value = "22u":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      component kind = "capacitor", value = "100n":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
    check generatedDesignators(nl) == @["C2"]

  test "numbering is per netlist, so one module cannot renumber another":
    proc blk(): Netlist =
      subckt("B", [P, G]):
        net G, kind = ntGround, name = "0"
        net P, kind = ntSignal
        component kind = "capacitor", value = "1n":
          pin "1", P, kind = ptPassive
          pin "2", G, kind = ptPassive
    let nl = netlist("top"):
      net gnd, kind = ntGround, name = "0", global = true
      net a, kind = ntSignal
      component kind = "capacitor", value = "10u":
        pin "1", a, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      instance XA, blk(), [a, gnd]
      instance XB, blk(), [a, gnd]
    # Each netlist numbers from 1 in its own scope.
    check nl.components.hasKey("C1")
    check nl.children["XA"].components.hasKey("C1")
    check nl.children["XB"].components.hasKey("C1")

  test "an explicit designator still wins over generation":
    let nl = netlist("b"):
      net a, kind = ntSignal
      component designator = "C99", kind = "capacitor", value = "1n":
        pin "1", a, kind = ptPassive
    check nl.components.hasKey("C99")
    check generatedDesignators(nl).len == 0

  test "no label and no kind is a compile error, not a guess":
    check(not compiles(block:
      discard netlist("b"):
        net a, kind = ntSignal
        component value = "1n":
          pin "1", a, kind = ptPassive))

  test "a generated designator still reaches the deck as the right device":
    # The two naming schemes stay independent all the way to the simulator:
    # the generated designator is the board's name, and `deckDesignator`
    # prepends the SPICE letter from `kind` on top of it.
    let nl = netlist("b"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      component kind = "capacitor", value = "1n":
        pin "1", a, kind = ptPassive
        pin "2", b, kind = ptPassive
      component kind = "inductor", value = "600n", designator = "FB1":
        pin "1", b, kind = ptPassive
        pin "2", a, kind = ptPassive
    let s = newStringStream()
    writeNetlist(nl, s)
    check "C1 " in s.data
    check "LFB1" in s.data          # prepended, not substituted

test "a component may carry more than one simReplace, told apart by name":
  # The DSL statement adds rather than assigns, which is what lets a part
  # declare the model for each question it can be asked. `suits` is the only
  # thing that says which is which; without it every model would be a
  # candidate for every analysis and the choice would be an accident.
  let nl = netlist("two models"):
    net vout, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "buck", simDefault = "averaged":
      pin "OUT", vout
      pin "GND", gnd
      simReplace kind = "voltage_source", name = "averaged":
        pin "+", vout
        pin "-", gnd
      simReplace kind = "vcvs", name = "switching", suits = "steady_state":
        pin "+", vout
        pin "-", gnd

  let u1 = nl.components["U1"]
  check u1.simModels.len == 2
  check u1.simReplace.kind == "voltage_source"
  check u1.simModels["switching"].suits == @["steady_state"]
  check u1.simModels["averaged"].suits.len == 0
  # And the component itself is untouched: `simReplace` is inert data beside
  # the part, never a mutation of it.
  check u1.kind == "buck"
  check u1.pins.len == 2

test "a model may claim several purposes":
  let nl = netlist("multi"):
    net a
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "buck":
      pin "OUT", a
      simReplace kind = "resistor", name = "m", suits = ["startup", "steady_state"]:
        pin "1", a
        pin "2", gnd
  check nl.components["U1"].simModels["m"].suits == @["startup", "steady_state"]

# --- multi-channel packaging -----------------------------------------

import verax/netlist/packages

test "with = u10.section(...) composes with instance and writes package.*":
  let dual = newPackageDef("DSL_DUAL", [
    (id: "1", section: "A", logical: "OUT"),
    (id: "2", section: "",  logical: "V+"),
    (id: "3", section: "B", logical: "OUT")], partNumber = "DSL_DUAL")
  registerPackage(dual)
  let u10 = packageInstance("DSL_DUAL", "U10")

  let ch = block:
    proc mk(): Netlist =
      subckt("CH", [O, VP]):
        net O, kind = ntSignal
        net VP, kind = ntPower
        component U1, kind = "opamp":
          pin "OUT", O, kind = ptOutput
          pin "V+", VP, kind = ptPower
    mk

  let top = netlist("top"):
    net vp, kind = ntPower
    net oa, kind = ntSignal
    net ob, kind = ntSignal
    instance XA, ch(), [oa, vp], with = u10.section("A", "U1")
    instance XB, ch(), [ob, vp], with = u10.section("B", "U1")

  let a = findComponent(top, "XA.U1")
  let b = findComponent(top, "XB.U1")
  check a.attrs["package.ref"] == "U10"
  check a.attrs["package.section"] == "A"
  check a.attrs["package.def"] == "DSL_DUAL"
  check b.attrs["package.section"] == "B"
  check displayDesignator(a) == "U10A"

test "the flat assign path writes the same three keys":
  let dual = newPackageDef("DSL_FLAT", [
    (id: "1", section: "A", logical: "OUT"),
    (id: "2", section: "B", logical: "OUT")], partNumber = "DSL_FLAT")
  registerPackage(dual)
  let u1 = packageInstance("DSL_FLAT", "U1")
  let nl = netlist("flat"):
    net gnd, kind = ntGround, name = "0"
    net a, kind = ntSignal
    net b, kind = ntSignal
    component U1A, kind = "opamp":
      pin "OUT", a
    component U1B, kind = "opamp":
      pin "OUT", b
  u1.assign(nl, "A", "U1A")
  u1.assign(nl, "B", "U1B")
  check nl.components["U1A"].attrs["package.ref"] == "U1"
  check nl.components["U1A"].attrs["package.section"] == "A"
  check nl.components["U1B"].attrs["package.def"] == "DSL_FLAT"

suite "layout: block":
  test "layout: side = left/right writes and reads back through layoutSide":
    let nl = netlist("sides"):
      net gnd, kind = ntGround, name = "0"
      net a, kind = ntSignal
      component U1, kind = "mcu":
        layout:
          side = left
        pin "1", a, kind = ptPassive
      component U2, kind = "mcu":
        layout:
          side = right
        pin "1", a, kind = ptPassive
      component U3, kind = "mcu":
        pin "1", a, kind = ptPassive
    check nl.components["U1"].attrs["layout.side"] == "left"
    check layoutSide(nl.components["U1"]) == sideLeft
    check nl.components["U2"].attrs["layout.side"] == "right"
    check layoutSide(nl.components["U2"]) == sideRight
    check not nl.components["U3"].attrs.hasKey("layout.side")
    check layoutSide(nl.components["U3"]) == sideAuto

  test "instance ..., side = left/right sets the instantiated subcircuit's own side":
    proc blk(): Netlist =
      subckt("B", [P, G]):
        net G, kind = ntGround, name = "0"
        net P, kind = ntSignal
        component kind = "capacitor", value = "1n":
          pin "1", P, kind = ptPassive
          pin "2", G, kind = ptPassive
    let nl = netlist("top"):
      net gnd, kind = ntGround, name = "0", global = true
      net a, kind = ntSignal
      instance XA, blk(), [a, gnd], side = left
      instance XB, blk(), [a, gnd], side = right
      instance XC, blk(), [a, gnd]
    check layoutSide(nl.components["XA"]) == sideLeft
    check layoutSide(nl.components["XB"]) == sideRight
    check layoutSide(nl.components["XC"]) == sideAuto

  test "an unknown layout key is a compile error naming the registered keys":
    check(not compiles(block:
      discard netlist("bad"):
        net gnd, kind = ntGround, name = "0"
        component U1, kind = "mcu":
          layout:
            rotation = 90))

  test "an unknown side value is a compile error":
    check(not compiles(block:
      discard netlist("bad"):
        net gnd, kind = ntGround, name = "0"
        component U1, kind = "mcu":
          layout:
            side = sideways))

  test "side = auto clears any override":
    let c = newComponent("U1", kind = "mcu")
    setLayoutSide(c, sideLeft)
    setLayoutSide(c, sideAuto)
    check not c.attrs.hasKey("layout.side")
    check layoutSide(c) == sideAuto

  test "layout: mirror = true/false writes and reads back through layoutMirror":
    let nl = netlist("mirrors"):
      net gnd, kind = ntGround, name = "0"
      net a, kind = ntSignal
      component U1, kind = "mcu":
        layout:
          mirror = true
        pin "1", a, kind = ptPassive
      component U2, kind = "mcu":
        layout:
          mirror = false
        pin "1", a, kind = ptPassive
      component U3, kind = "mcu":
        pin "1", a, kind = ptPassive
    check nl.components["U1"].attrs["layout.mirror"] == "true"
    check layoutMirror(nl.components["U1"]) == mirrorOn
    check nl.components["U2"].attrs["layout.mirror"] == "false"
    check layoutMirror(nl.components["U2"]) == mirrorOff
    check not nl.components["U3"].attrs.hasKey("layout.mirror")
    check layoutMirror(nl.components["U3"]) == mirrorAuto

  test "an unknown mirror value is a compile error":
    check(not compiles(block:
      discard netlist("bad"):
        net gnd, kind = ntGround, name = "0"
        component U1, kind = "mcu":
          layout:
            mirror = sideways))

  test "mirror = auto clears any override":
    let c = newComponent("U1", kind = "mcu")
    setLayoutMirror(c, mirrorOn)
    setLayoutMirror(c, mirrorAuto)
    check not c.attrs.hasKey("layout.mirror")
    check layoutMirror(c) == mirrorAuto

  test "layout: power = true/false writes and reads back through layoutPower":
    let nl = netlist("powers"):
      net gnd, kind = ntGround, name = "0"
      net a, kind = ntSignal
      component U1, kind = "mcu":
        layout:
          power = true
        pin "1", a, kind = ptPassive
      component U2, kind = "mcu":
        layout:
          power = false
        pin "1", a, kind = ptPassive
      component U3, kind = "mcu":
        pin "1", a, kind = ptPassive
    check nl.components["U1"].attrs["layout.power"] == "true"
    check layoutPower(nl.components["U1"]) == powerOn
    check nl.components["U2"].attrs["layout.power"] == "false"
    check layoutPower(nl.components["U2"]) == powerOff
    check not nl.components["U3"].attrs.hasKey("layout.power")
    check layoutPower(nl.components["U3"]) == powerAuto

  test "an unknown power value is a compile error":
    check(not compiles(block:
      discard netlist("bad"):
        net gnd, kind = ntGround, name = "0"
        component U1, kind = "mcu":
          layout:
            power = sideways))

  test "power = auto clears any override":
    let c = newComponent("U1", kind = "mcu")
    setLayoutPower(c, powerOn)
    setLayoutPower(c, powerAuto)
    check not c.attrs.hasKey("layout.power")
    check layoutPower(c) == powerAuto

  test "layout: variant = \"name\" writes and reads back through layoutVariant":
    # Unlike `side`/`mirror`/`power`, `variant` takes a string literal
    # rather than a bare ident -- `pcb/variant.LayoutVariant` names are
    # open-ended, not a closed set `netlist/dsl.nim` could enumerate.
    let nl = netlist("variants"):
      net gnd, kind = ntGround, name = "0"
      net a, kind = ntSignal
      component U1, kind = "mcu":
        layout:
          variant = "compact"
        pin "1", a, kind = ptPassive
      component U2, kind = "mcu":
        pin "1", a, kind = ptPassive
    check nl.components["U1"].attrs["layout.variant"] == "compact"
    check layoutVariant(nl.components["U1"]) == "compact"
    check not nl.components["U2"].attrs.hasKey("layout.variant")

suite "traverse: block":
  test "one edge: \"A\" <-> \"B\" writes a single conducting path":
    let nl = netlist("t"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      component Z1, kind = "rf_switch":
        traverse:
          "RFC" <-> "RF1"
        pin "RFC", a, kind = ptPassive
        pin "RF1", b, kind = ptPassive
    check nl.components["Z1"].attrs["traverse.paths"] == "RFC,RF1"
    check not nl.components["Z1"].attrs.hasKey("traverse.blocked")
    check not nl.components["Z1"].attrs.hasKey("traverse.mode")

  test "\"A\" <-> [list] is the cross product, one edge per list member":
    let nl = netlist("t"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      net c, kind = ntSignal
      component Z1, kind = "rf_switch":
        traverse:
          "RFC" <-> ["RF1", "RF2"]
        pin "RFC", a, kind = ptPassive
        pin "RF1", b, kind = ptPassive
        pin "RF2", c, kind = ptPassive
    check nl.components["Z1"].attrs["traverse.paths"] == "RFC,RF1;RFC,RF2"

  test "[list] <-> [list] is the full cross product on both sides":
    let nl = netlist("t"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      net c, kind = ntSignal
      component Z1, kind = "rf_switch":
        traverse:
          ["A", "B"] <-> ["C"]
        pin "A", a, kind = ptPassive
        pin "B", b, kind = ptPassive
        pin "C", c, kind = ptPassive
    check nl.components["Z1"].attrs["traverse.paths"] == "A,C;B,C"

  test "blocks \"A\" <-> \"B\" writes a non-conducting (schematic-only) edge":
    let nl = netlist("t"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      component C1, kind = "capacitor":
        traverse:
          blocks "IN" <-> "OUT"
        pin "IN", a, kind = ptPassive
        pin "OUT", b, kind = ptPassive
    check nl.components["C1"].attrs["traverse.blocked"] == "IN,OUT"
    check not nl.components["C1"].attrs.hasKey("traverse.paths")

  test "none writes traverse.mode = none":
    let nl = netlist("t"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      component R1, kind = "resistor":
        traverse:
          none
        pin "1", a, kind = ptPassive
        pin "2", b, kind = ptPassive
    check nl.components["R1"].attrs["traverse.mode"] == "none"

  test "all writes traverse.mode = all":
    let nl = netlist("t"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      component U1, kind = "connector":
        traverse:
          all
        pin "1", a, kind = ptPassive
        pin "2", b, kind = ptPassive
    check nl.components["U1"].attrs["traverse.mode"] == "all"

  test "several statements in one block accumulate rather than clobber":
    let nl = netlist("t"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      net c, kind = ntSignal
      net d, kind = ntSignal
      component Z1, kind = "rf_switch":
        traverse:
          "RFC" <-> ["RF1", "RF2"]
          blocks "RF1" <-> "RF2"
        pin "RFC", a, kind = ptPassive
        pin "RF1", b, kind = ptPassive
        pin "RF2", c, kind = ptPassive
        pin "EN", d, kind = ptInput
    check nl.components["Z1"].attrs["traverse.paths"] == "RFC,RF1;RFC,RF2"
    check nl.components["Z1"].attrs["traverse.blocked"] == "RF1,RF2"

  test "traverse: block may precede the pin statements it names":
    # The worked example from the plan: pin names inside `traverse:` are not
    # checked against the component's own pins at DSL time, so the block may
    # come first -- `validateTraversal` is what catches an unknown pin name.
    let nl = netlist("t"):
      net a, kind = ntSignal
      net b, kind = ntSignal
      component Z1, kind = "rf_switch":
        traverse:
          "RFC" <-> "RF1"
        pin "RFC", a, kind = ptPassive
        pin "RF1", b, kind = ptPassive
    check nl.components["Z1"].attrs["traverse.paths"] == "RFC,RF1"

  test "an unrecognized keyword inside traverse is a compile error":
    check(not compiles(block:
      discard netlist("bad"):
        component Z1, kind = "rf_switch":
          traverse:
            rotate = 90
          pin "1", 1, kind = ptPassive))

  test "a malformed pin-pair statement inside traverse is a compile error":
    check(not compiles(block:
      discard netlist("bad"):
        component Z1, kind = "rf_switch":
          traverse:
            "RFC" -> "RF1"    # `->`, not `<->`
          pin "1", 1, kind = ptPassive))

  test "traverse with no block is a compile error":
    check(not compiles(block:
      discard netlist("bad"):
        component Z1, kind = "rf_switch":
          traverse
          pin "1", 1, kind = ptPassive))
