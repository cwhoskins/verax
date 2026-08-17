import std/[tables, unittest]

import nimcir/netlist/dsl

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
