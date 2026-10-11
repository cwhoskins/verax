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

test "leafComponents walks instances to leaves with hierarchical paths":
  var globals: OrderedTable[string, Net]
  let child = newNetlist("CHILD")
  let a = addNet(child, newNet("a"))
  addPort(child, "a", a)
  discard connect(addComponent(child, newComponent("R1", kind = "resistor")), "1", a)
  let top = newNetlist("TOP")
  let n = addNet(top, newNet("n"))
  discard connect(addComponent(top, newComponent("C1", kind = "capacitor")), "1", n)
  discard instantiate(top, "X1", child, @[n], globals)
  var paths: seq[string]
  for (c, path) in leafComponents(top): paths.add path
  check paths == @["C1", "X1.R1"]

proc mergeTemplate(): Netlist =
  result = newNetlist("MERGE")
  let a = addNet(result, newNet("a"))
  let b = addNet(result, newNet("b"))
  addPort(result, "first", b)
  addPort(result, "kept", a)
  addPort(result, "alias", b)
  a.attrs["shared"] = "keep"
  b.attrs["shared"] = "gone"
  b.attrs["local"] = "inherited"
  let r = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r, "1", a)
  discard connect(r, "2", b)

proc checkMergedPorts(nl: Netlist) =
  var names: seq[string]
  for name, n in nl.ports:
    names.add name
    check n == nl.nets["a"]
  check names == @["first", "kept", "alias"]
  check nl.nets.len == 1
  check nl.nets["a"].attrs["shared"] == "keep"
  check nl.nets["a"].attrs["local"] == "inherited"
  check nl.nets["a"].pins.len == 2
  for _, p in nl.components["R1"].pins:
    check p.net == nl.nets["a"]
    check p in nl.nets["a"].pins

test "merge preserves aliases, order, pins and attributes through clone":
  let nl = mergeTemplate()
  let gone = nl.nets["b"]
  mergeNets(nl.nets["a"], gone)
  check gone.netlist == nil
  check gone.pins.len == 0
  checkMergedPorts(nl)
  var globals: OrderedTable[string, Net]
  let copied = clone(nl, globals)
  checkMergedPorts(copied)
  check copied.nets["a"] != nl.nets["a"]

test "merge in nested instantiated child retargets only its owner bindings":
  var globals: OrderedTable[string, Net]
  let templ = mergeTemplate()
  let middle = newNetlist("MIDDLE")
  let m = addNet(middle, newNet("m"))
  addPort(middle, "m", m)
  discard instantiate(middle, "XI", templ, @[m, m, m], globals)
  let top = newNetlist("TOP")
  let n = addNet(top, newNet("n"))
  let x = instantiate(top, "X", middle, @[n], globals)
  let sibling = instantiate(top, "Y", middle, @[n], globals)
  let inner = x.subNetlist.components["XI"]
  let child = inner.subNetlist
  let keep = child.nets["a"]
  mergeNets(keep, child.nets["b"])
  checkMergedPorts(child)
  for _, p in inner.pins:
    check p.hierNet == keep
    check p.net == x.subNetlist.nets["m"]
  check x.pins["m"].hierNet == x.subNetlist.nets["m"]
  check sibling.subNetlist.children["XI"].nets.len == 2
  check middle.children["XI"].nets.len == 2
  check templ.ports["first"] == templ.nets["b"]
  let copied = clone(top, globals)
  let ci = copied.children["X"].components["XI"]
  checkMergedPorts(ci.subNetlist)
  for _, p in ci.pins: check p.hierNet == ci.subNetlist.nets["a"]

test "merge in an immediate child preserves cloneable owner bindings":
  var globals: OrderedTable[string, Net]
  let templ = mergeTemplate()
  let top = newNetlist("TOP")
  let n = addNet(top, newNet("n"))
  let x = instantiate(top, "X", templ, @[n, n, n], globals)
  mergeNets(x.subNetlist.nets["a"], x.subNetlist.nets["b"])
  let copied = clone(top, globals)
  for _, p in copied.components["X"].pins:
    check p.hierNet == copied.children["X"].nets["a"]
  check templ.nets.len == 2

test "cross-netlist merge removes consumed aliases but keeps dissolution bindings":
  var globals: OrderedTable[string, Net]
  let top = newNetlist("TOP")
  let n = addNet(top, newNet("n"))
  let x = instantiate(top, "X", mergeTemplate(), @[n, n, n], globals)
  let child = x.subNetlist
  let gone = child.nets["b"]
  mergeNets(n, gone)
  check child.ports.len == 1
  check child.ports["kept"] == child.nets["a"]
  check x.pins["first"].hierNet == gone
  check x.pins["alias"].hierNet == gone
  check child.components["R1"].pins["2"].net == n
  check n.attrs["local"] == "inherited"
  check gone.netlist == nil

test "nil and self merges leave ports, pins and attributes untouched":
  let nl = mergeTemplate()
  let a = nl.nets["a"]
  mergeNets(nil, a)
  mergeNets(a, nil)
  mergeNets(nil, nil)
  mergeNets(a, a)
  check nl.nets.len == 2
  check nl.ports.len == 3
  check nl.ports["kept"] == a
  check nl.ports["first"] == nl.nets["b"]
  check a.netlist == nl
  check a.pins.len == 1
  check a.attrs["shared"] == "keep"
  check not a.attrs.hasKey("local")
