import std/[tables, unittest]

import verax/netlist

test "hand-built netlist is walkable both ways":
  let nl = newNetlist("divider")
  let vin = addNet(nl, newNet("vin", ntSignal))
  let vout = addNet(nl, newNet("vout", ntSignal))
  let gnd = addNet(nl, newNet("0", ntGround))

  let r1 = addComponent(nl, newComponent("R1", partNumber = "RC0603", kind = "resistor"))
  let r2 = addComponent(nl, newComponent("R2", partNumber = "RC0603", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", vout, ptPassive)
  discard connect(r2, "1", vout, ptPassive)
  discard connect(r2, "2", gnd, ptPassive)

  check nl.components["R1"].pins["1"].net.name == "vin"
  check nl.components["R1"].pins["2"].net.name == "vout"

  let voutComponents = connectedComponents(vout)
  check voutComponents.len == 2
  check r1 in voutComponents
  check r2 in voutComponents

  # walk from a net, through a pin, to the component, and back to a different pin
  let pinOnVout = vout.pins[0]
  check pinOnVout.component.designator in ["R1", "R2"]
  check pinOnVout.net == vout

test "unconnected pin has no net and is absent from any net's pins":
  let nl = newNetlist("t")
  let n = addNet(nl, newNet("n1"))
  let c = addComponent(nl, newComponent("U1"))
  let p = addPin(c, newPin("A"))
  check p.net == nil
  check not isConnected(p)
  check p notin n.pins

test "duplicate designator or net name raises NetlistError":
  let nl = newNetlist("t")
  discard addComponent(nl, newComponent("R1"))
  expect(NetlistError):
    discard addComponent(nl, newComponent("R1"))

  discard addNet(nl, newNet("n1"))
  expect(NetlistError):
    discard addNet(nl, newNet("n1"))

test "connect then disconnect clears both sides; reconnect moves the pin":
  let nl = newNetlist("t")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("b"))
  let c = addComponent(nl, newComponent("R1"))
  let pin = connect(c, "1", a)

  check pin.net == a
  check pin in a.pins

  disconnect(pin)
  check pin.net == nil
  check pin notin a.pins

  connect(pin, a)
  connect(pin, b)
  check pin.net == b
  check pin notin a.pins
  check pin in b.pins

test "hierarchical instantiate wires parent pins, hierNet, and independent instances":
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
  let netC = addNet(parent, newNet("netC"))
  let netD = addNet(parent, newNet("netD"))

  let x1 = instantiate(parent, "X1", templ, @[netA, netB], globalNets)
  let x2 = instantiate(parent, "X2", templ, @[netC, netD], globalNets)

  check x1.subNetlist.parent == parent
  check x1.subNetlist.instanceOf == x1
  check x1.pins["IN"].net == netA
  check x1.pins["IN"].hierNet == x1.subNetlist.nets["IN"]
  check x1.pins["IN"].hierNet.name == "IN"

  # independent instances: distinct component/net objects, not aliased
  check x1.subNetlist != x2.subNetlist
  check x1.subNetlist.components["U1"] != x2.subNetlist.components["U1"]
  check x1.pins["IN"].hierNet != x2.pins["IN"].hierNet

test "shared global net resolves to the identical object across instances":
  var globalNets: OrderedTable[string, Net]

  let templ = newNetlist("GATE")
  let vdd = addNet(templ, newNet("VDD", ntPower))
  let gnd = addNet(templ, newNet("0", ntGround))
  addPort(templ, "VDD", vdd)
  addPort(templ, "GND", gnd)

  let parent = newNetlist("TOP")
  let sharedGnd = addNet(parent, newNet("0", ntGround))
  globalNets["0"] = sharedGnd
  let vddA = addNet(parent, newNet("vddA"))
  let vddB = addNet(parent, newNet("vddB"))

  let x1 = instantiate(parent, "X1", templ, @[vddA, sharedGnd], globalNets)
  let x2 = instantiate(parent, "X2", templ, @[vddB, sharedGnd], globalNets)

  check x1.pins["GND"].hierNet == x2.pins["GND"].hierNet
  check x1.pins["GND"].hierNet == sharedGnd
