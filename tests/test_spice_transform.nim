import std/[strutils, tables, unittest]

import verax/netlist
import verax/netlist/dsl
import verax/spice/transform
import verax/spice/flatten
import verax/spice/xspice

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

# --- more than one model on one part ----------------------------------------
#
# E.g. an averaged model for settling and start-up, a switching one for
# ripple. Pins down the selection rules, so "which model ran" can't silently
# change.

proc twoModelPart(): Component =
  var nl = newNetlist("board")
  let n1 = addNet(nl, newNet("a"))
  let n2 = addNet(nl, newNet("0", ntGround))
  let u1 = addComponent(nl, newComponent("U1", kind = "buck"))
  discard connect(u1, "OUT", n1)
  discard connect(u1, "GND", n2)
  u1

test "a component carries several models, keyed by name":
  let u1 = twoModelPart()
  addSimModel(u1, newSimReplacement("voltage_source", name = "averaged"))
  addSimModel(u1, newSimReplacement("vcvs", name = "switching",
                                    suits = [spSteadyState]))
  check u1.simModels.len == 2
  # `simReplace` reads the default model.
  check u1.simReplace.name == "averaged"
  check defaultSimModel(u1).name == "averaged"

test "a duplicate model name raises rather than replacing":
  let u1 = twoModelPart()
  addSimModel(u1, newSimReplacement("voltage_source", name = "averaged"))
  expect NetlistError:
    addSimModel(u1, newSimReplacement("vcvs", name = "averaged"))

test "a purpose picks the model that claims it, and nothing else changes":
  let u1 = twoModelPart()
  addSimModel(u1, newSimReplacement("voltage_source", name = "averaged"))
  addSimModel(u1, newSimReplacement("vcvs", name = "switching",
                                    suits = [spSteadyState]))
  check selectSimModel(u1, spSteadyState).name == "switching"
  # Other purposes fall back to the default rather than refusing.
  for p in [spOperating, spSmallSignal, spStartup, spLargeSignal]:
    check selectSimModel(u1, p).name == "averaged"
  check selectSimModel(u1, "").name == "averaged"
  check selectSimModel(u1, "something nobody registered").name == "averaged"

test "simDefault names the default; without it, the first added wins":
  let u1 = twoModelPart()
  addSimModel(u1, newSimReplacement("voltage_source", name = "averaged"))
  addSimModel(u1, newSimReplacement("vcvs", name = "switching"))
  check u1.simReplace.name == "averaged"
  u1.simDefault = "switching"
  check u1.simReplace.name == "switching"
  # A `simDefault` naming nothing falls back rather than returning nil.
  u1.simDefault = "typo"
  check u1.simReplace.name == "averaged"

test "two models claiming one purpose raises, naming both":
  let u1 = twoModelPart()
  addSimModel(u1, newSimReplacement("voltage_source", name = "averaged",
                                    suits = [spSteadyState]))
  addSimModel(u1, newSimReplacement("vcvs", name = "switching",
                                    suits = [spSteadyState]))
  var msg = ""
  try:
    discard selectSimModel(u1, spSteadyState)
  except NetlistError as e:
    msg = e.msg
  check "'averaged'" in msg
  check "'switching'" in msg
  check spSteadyState in msg

test "assigning simReplace still means `this is the model`":
  let u1 = twoModelPart()
  addSimModel(u1, newSimReplacement("voltage_source", name = "averaged"))
  addSimModel(u1, newSimReplacement("vcvs", name = "switching"))
  # Assigning `simReplace` replaces the whole set.
  u1.simReplace = newSimReplacement("resistor")
  check u1.simModels.len == 1
  check u1.simReplace.kind == "resistor"
  u1.simReplace = nil
  check u1.simModels.len == 0
  check u1.simReplace == nil

test "clone carries every model, not just the default":
  var nl = newNetlist("board")
  let a = addNet(nl, newNet("a"))
  discard addNet(nl, newNet("0", ntGround))
  let u1 = addComponent(nl, newComponent("U1", kind = "buck"))
  discard connect(u1, "OUT", a)
  addSimModel(u1, newSimReplacement("voltage_source", name = "averaged"))
  addSimModel(u1, newSimReplacement("vcvs", name = "switching",
                                    suits = [spSteadyState]))
  u1.simDefault = "averaged"

  var globals: OrderedTable[string, Net]
  let copy = clone(nl, globals)
  let c = copy.components["U1"]
  check c.simModels.len == 2
  check selectSimModel(c, spSteadyState).name == "switching"
  check c.simReplace.name == "averaged"

# --- pass ordering: flatten before applySimReplacements ------------------
#
# Analyses run clone -> flatten -> `applySimReplacements`, not
# `materializeSimNetlist` then flatten: a code model's `xspice.ports` string
# is frozen at replacement time and flatten would rename the nets under it.
# See `spice/flatten.nim`.

proc gainSpec(): ModelSpec =
  ## A minimal single-ended two-port model; any verified port shape will do.
  ModelSpec(
    name: "nimgain", cFunction: "cm_nimgain", description: "gain",
    ports: @[
      PortSpec(name: "inp", dir: xdIn, default: xpV, allowed: @[xpV]),
      PortSpec(name: "outp", dir: xdOut, default: xpV, allowed: @[xpV])],
    params: @[ParamSpec(name: "gain", dataType: xtReal, default: "1.0",
                        nullAllowed: true)])

proc buildGainStandin(nl: Netlist, old: Component): Component =
  ## A realistic `SimReplacement.build`: remove the part and add an `A`
  ## instance on the same nets as `"A" & old.designator` (prepended, so
  ## `"XA.U1"` becomes `"AXA.U1"`). `addCodeModelInstance` freezes
  ## `xspice.ports` from the net names at this call.
  let inNet = old.pins["IN"].net
  let outNet = old.pins["OUT"].net
  let desig = old.designator
  removeComponent(nl, desig)
  result = addCodeModelInstance(nl, "A" & desig, gainSpec(), [inNet, outNet],
                                {"gain": "2.0"})

proc nestedCodeModelBoard(): tuple[nl: Netlist, globals: OrderedTable[string, Net]] =
  ## `XA` wraps a one-part `STAGE` whose part carries a
  ## `SimReplacement.build`, one level deep.
  var globalNets: OrderedTable[string, Net]
  let templ = newNetlist("STAGE")
  let inN = addNet(templ, newNet("IN"))
  let outN = addNet(templ, newNet("OUT"))
  addPort(templ, "IN", inN)
  addPort(templ, "OUT", outN)
  let u1 = addComponent(templ, newComponent("U1", kind = "amplifier"))
  discard connect(u1, "IN", inN)
  discard connect(u1, "OUT", outN)
  u1.simReplace = newSimReplacement(buildGainStandin, name = "codemodel")

  let top = newNetlist("TOP")
  let vin = addNet(top, newNet("vin"))
  let vout = addNet(top, newNet("vout"))
  discard instantiate(top, "XA", templ, @[vin, vout], globalNets)
  (top, globalNets)

test "flatten before applySimReplacements: a nested code model's ports resolve to flat net names":
  let (top, _) = nestedCodeModelBoard()
  var cloneNets: OrderedTable[string, Net]
  let work = clone(top, cloneNets)
  discard flatten(work)
  applySimReplacements(work)

  check work.components.hasKey("AXA.U1")
  let ports = work.components["AXA.U1"].attrs["xspice.ports"]
  # Post-flatten names: the string was frozen after `mergeNets` renamed the
  # nets.
  check "vin" in ports
  check "vout" in ports
  check "IN" notin ports
  check "OUT" notin ports

test "the old order (replace before flatten) freezes child-template-local names instead":
  ## The wrong order on the same fixture: replace, then flatten. The frozen
  ## ports never see the post-flatten names, so the deck's `A` line names
  ## nonexistent nodes (a singular matrix in ngspice).
  let (top, globalNets0) = nestedCodeModelBoard()
  var globalNets = globalNets0
  let work = materializeSimNetlist(top, globalNets)
  discard flatten(work)

  # Replaced while nested as "AU1"; flatten renames it "XA.AU1" but can't
  # revisit the frozen string.
  check work.components.hasKey("XA.AU1")
  let ports = work.components["XA.AU1"].attrs["xspice.ports"]
  check "IN" in ports
  check "OUT" in ports
  check "vin" notin ports
  check "vout" notin ports

test "materializeSimNetlist applies the model that suits the purpose":
  var nl = newNetlist("board")
  let outp = addNet(nl, newNet("out", ntPower))
  let gnd = addNet(nl, newNet("0", ntGround))
  let u1 = addComponent(nl, newComponent("U1", kind = "buck"))
  discard connect(u1, "OUT", outp)
  discard connect(u1, "GND", gnd)

  var slow = newSimReplacement("voltage_source", name = "averaged")
  slow.pinNets["+"] = "out"
  slow.pinNets["-"] = "0"
  var fast = newSimReplacement("resistor", name = "switching",
                               suits = [spSteadyState])
  fast.pinNets["1"] = "out"
  fast.pinNets["2"] = "0"
  addSimModel(u1, slow)
  addSimModel(u1, fast)

  var g1, g2, g3: OrderedTable[string, Net]
  check materializeSimNetlist(nl, g1, purpose = spOperating)
        .components["V1"].kind == "voltage_source"
  check materializeSimNetlist(nl, g2, purpose = spSteadyState)
        .components["R1"].kind == "resistor"
  # The design netlist still describes the board.
  check nl.components["U1"].kind == "buck"
  check materializeSimNetlist(nl, g3).components["V1"].kind == "voltage_source"
