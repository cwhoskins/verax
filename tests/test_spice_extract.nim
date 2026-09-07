import std/[tables, unittest]

import verax/netlist
import verax/spice/extract

test "extractInstance clones a hierarchical component's subNetlist, detached from its parent":
  var globalNets: OrderedTable[string, Net]
  let templ = newNetlist("BUF")
  let inNet = addNet(templ, newNet("IN"))
  let outNet = addNet(templ, newNet("OUT"))
  addPort(templ, "IN", inNet)
  addPort(templ, "OUT", outNet)
  let u = addComponent(templ, newComponent("U1", kind = "ic"))
  discard connect(u, "A", inNet, ptInput)
  discard connect(u, "Y", outNet, ptOutput)

  let parent = newNetlist("TOP")
  let netA = addNet(parent, newNet("netA"))
  let netB = addNet(parent, newNet("netB"))
  let x1 = instantiate(parent, "X1", templ, @[netA, netB], globalNets)

  let extracted = extractInstance(x1, globalNets)
  check extracted.parent == nil
  check extracted.ports.hasKey("IN")
  check extracted.ports.hasKey("OUT")
  check extracted.components.hasKey("U1")
  check extracted.components["U1"] != x1.subNetlist.components["U1"]

test "extractInstance raises on a component with no subNetlist":
  let nl = newNetlist("t")
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  var globalNets: OrderedTable[string, Net]
  expect(NetlistError):
    discard extractInstance(r1, globalNets)

test "extractSubcircuit promotes boundary nets and drops non-selected components/nets":
  let nl = newNetlist("board")
  let vin = addNet(nl, newNet("vin"))
  let mid = addNet(nl, newNet("mid"))
  let vout = addNet(nl, newNet("vout"))
  let gnd = addNet(nl, newNet("0", ntGround))

  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", mid, ptPassive)
  let r2 = addComponent(nl, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", mid, ptPassive)
  discard connect(r2, "2", vout, ptPassive)
  let r3 = addComponent(nl, newComponent("R3", kind = "resistor"))
  discard connect(r3, "1", vout, ptPassive)
  discard connect(r3, "2", gnd, ptPassive)

  var globalNets: OrderedTable[string, Net]
  let sub = extractSubcircuit(nl, "front_end", ["R1", "R2"], globalNets)

  check sub.name == "front_end"
  check sub.components.len == 2
  check sub.components.hasKey("R1")
  check sub.components.hasKey("R2")
  check not sub.components.hasKey("R3")

  # "mid" is fully internal to the selection (only R1/R2 pins) -- not a port
  check not sub.ports.hasKey("mid")
  # "vout" is the boundary: R2 (selected) and R3 (not selected) both use it
  check sub.ports.hasKey("vout")
  check sub.ports["vout"] == sub.nets["vout"]

  # the original netlist is untouched
  check nl.components.len == 3
  check nl.nets.len == 4

test "extractSubcircuit raises on an unknown designator":
  let nl = newNetlist("board")
  var globalNets: OrderedTable[string, Net]
  expect(NetlistError):
    discard extractSubcircuit(nl, "x", ["NOPE"], globalNets)

test "extractSubcircuit preserves a nested hierarchical instance inside the selection":
  var globalNets: OrderedTable[string, Net]
  let inner = newNetlist("INNER")
  let a = addNet(inner, newNet("A"))
  addPort(inner, "A", a)
  discard addComponent(inner, newComponent("R9", kind = "resistor"))
  discard connect(inner.components["R9"], "1", a, ptPassive)

  let nl = newNetlist("board")
  let vin = addNet(nl, newNet("vin"))
  discard instantiate(nl, "X1", inner, @[vin], globalNets)
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)

  let sub = extractSubcircuit(nl, "sub", ["X1", "R1"], globalNets)
  check sub.children.hasKey("X1")
  check sub.children["X1"].components.hasKey("R9")
