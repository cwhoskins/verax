import std/[tables, unittest]

import nimcir/netlist
import nimcir/netlist/dsl
import nimcir/spice/transform

test "replaceComponent swaps kind and auto-derives a SPICE-correct designator":
  let nl = newNetlist("t")
  let vin = addNet(nl, newNet("vin"))
  let vout = addNet(nl, newNet("vout"))
  let gnd = addNet(nl, newNet("0", ntGround))
  let u1 = addComponent(nl, newComponent("U1", kind = "regulator_ic"))
  discard connect(u1, "IN", vin)
  discard connect(u1, "OUT", vout)
  discard connect(u1, "GND", gnd)

  let newComp = replaceComponent(nl, "U1", "voltage_source", [("+", vout), ("-", gnd)])

  check not nl.components.hasKey("U1")
  check nl.components.hasKey("V1")
  check newComp == nl.components["V1"]
  check newComp.kind == "voltage_source"
  check newComp.pins["+"].net == vout
  check newComp.pins["-"].net == gnd

test "replaceComponent accepts an explicit new designator and partNumber":
  let nl = newNetlist("t")
  let vout = addNet(nl, newNet("vout"))
  let gnd = addNet(nl, newNet("0", ntGround))
  discard addComponent(nl, newComponent("U9", kind = "regulator_ic"))

  let newComp = replaceComponent(nl, "U9", "voltage_source", [("+", vout), ("-", gnd)],
                                  newDesignator = "VREG", partNumber = "ideal-3v3")
  check newComp.designator == "VREG"
  check newComp.partNumber == "ideal-3v3"

test "replaceComponent raises on an unknown designator":
  let nl = newNetlist("t")
  expect(NetlistError):
    discard replaceComponent(nl, "U1", "voltage_source", [])

test "replaceComponent works inside a nested child sub-netlist":
  var globalNets: OrderedTable[string, Net]
  let templ = newNetlist("POWER")
  let vin = addNet(templ, newNet("VIN"))
  let vout = addNet(templ, newNet("VOUT"))
  let gnd = addNet(templ, newNet("0", ntGround))
  addPort(templ, "VIN", vin)
  addPort(templ, "VOUT", vout)
  addPort(templ, "0", gnd)
  let u1 = addComponent(templ, newComponent("U1", kind = "regulator_ic"))
  discard connect(u1, "IN", vin)
  discard connect(u1, "OUT", vout)
  discard connect(u1, "GND", gnd)

  let parent = newNetlist("TOP")
  let pvin = addNet(parent, newNet("vin"))
  let pvout = addNet(parent, newNet("vout"))
  let pgnd = addNet(parent, newNet("0", ntGround))
  discard instantiate(parent, "X1", templ, @[pvin, pvout, pgnd], globalNets)

  let child = parent.children["X1"]
  let childVout = child.nets["VOUT"]
  let childGnd = child.nets["0"]
  discard replaceComponent(child, "U1", "voltage_source", [("+", childVout), ("-", childGnd)])

  check not child.components.hasKey("U1")
  check child.components.hasKey("V1")

test "materializeSimNetlist leaves the original netlist untouched":
  let nl = netlist("board"):
    net vin, kind = ntSignal
    net vout, kind = ntSignal
    net gnd, kind = ntGround, name = "0"

    component U1, kind = "regulator_ic", partNumber = "LM317":
      pin "IN", vin
      pin "OUT", vout
      pin "GND", gnd
      simReplace kind = "voltage_source":
        pin "+", vout
        pin "-", gnd

  var globalNets: OrderedTable[string, Net]
  let simNl = materializeSimNetlist(nl, globalNets)

  check nl.components.hasKey("U1")
  check nl.components["U1"].kind == "regulator_ic"
  check not simNl.components.hasKey("U1")
  check simNl.components.hasKey("V1")
  check simNl.components["V1"].kind == "voltage_source"
  check simNl.components["V1"].pins["+"].net == simNl.nets["vout"]
  check simNl.components["V1"].pins["-"].net == simNl.nets["0"]
  # the clone's nets are genuinely distinct objects from the original's
  check simNl.nets["vout"] != nl.nets["vout"]

test "materializeSimNetlist applies a simReplace nested inside a child sub-netlist":
  let templ = subckt("POWER", [VIN, VOUT, GND]):
    net VIN, kind = ntSignal
    net VOUT, kind = ntSignal
    net GND, kind = ntGround

    component U1, kind = "regulator_ic":
      pin "IN", VIN
      pin "OUT", VOUT
      pin "GND", GND
      simReplace kind = "voltage_source":
        pin "+", VOUT
        pin "-", GND

  let nl = netlist("top"):
    net vin, kind = ntSignal
    net vout, kind = ntSignal
    net gnd, kind = ntGround, name = "0"
    instance X1, templ, [vin, vout, gnd]

  var globalNets: OrderedTable[string, Net]
  let simNl = materializeSimNetlist(nl, globalNets)

  check nl.children["X1"].components.hasKey("U1")
  let simChild = simNl.children["X1"]
  check not simChild.components.hasKey("U1")
  check simChild.components.hasKey("V1")
  check simChild.components["V1"].pins["+"].net == simChild.nets["VOUT"]
