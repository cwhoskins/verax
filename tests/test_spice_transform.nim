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
# The LT8640A is what forced this: an averaged model answers where the rail
# settles and how it starts up, a switching one answers what ripple is left on
# it, and neither is the better model. What follows pins down the selection
# rules, since "which model ran" silently changing is the failure mode the
# whole mechanism exists to prevent.

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
  # `simReplace` still reads as it always did: the default model.
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
  # Every other purpose falls back to the default rather than refusing: a
  # model declaring itself for one question must not make the others
  # unanswerable.
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
  # A `simDefault` naming nothing falls back rather than returning nil, since
  # a part that carries a model must always have one to stand in with.
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
  # The field this replaced held one value, so a caller writing it is saying
  # what stands in for the part -- not adding to a set.
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
# `materializeSimNetlist` (clone + replace, combined) is still correct and
# still tested above -- a nested `simReplace` component survives it intact.
# What changed is that every analysis in `verax/analysis/analyses/` no
# longer calls it before flattening; each now does clone -> flatten ->
# `applySimReplacements` as three explicit steps, because an XSPICE code
# model's `attrs["xspice.ports"]` is a string frozen once at replacement
# time (`spice/xspice/instance.addCodeModelInstance`) and never revisited --
# replace before flatten freezes child-template-local net names that
# flatten then renames the underlying `Net` objects out from under, without
# ever touching the frozen string. See `spice/flatten.nim`'s module doc and
# `applySimReplacements`'s own doc comment for the full account.

proc gainSpec(): ModelSpec =
  ## The minimal single-ended two-port model `test_xspice_instance.nim` uses,
  ## reused here rather than invented again: one real ngspice-verified port
  ## shape is enough to prove ports freeze correctly, and nothing about *this*
  ## bug depends on the model's own behaviour.
  ModelSpec(
    name: "nimgain", cFunction: "cm_nimgain", description: "gain",
    ports: @[
      PortSpec(name: "inp", dir: xdIn, default: xpV, allowed: @[xpV]),
      PortSpec(name: "outp", dir: xdOut, default: xpV, allowed: @[xpV])],
    params: @[ParamSpec(name: "gain", dataType: xtReal, default: "1.0",
                        nullAllowed: true)])

proc buildGainStandin(nl: Netlist, old: Component): Component =
  ## A `SimReplacement.build` shaped exactly like a real one
  ## (`designs/lib/lt8640a.nim`'s `buildLt8640aAvg`): remove the real part,
  ## add an `A` code-model instance wired to the same nets, under `"A" &
  ## old.designator` -- the letter *prepended* to whatever designator `old`
  ## has at build time, dotted and all, on the same "prepend, not
  ## substitute" convention `formats/spice.deckDesignator` documents (so
  ## post-flatten `"XA.U1"` becomes `"AXA.U1"`, one flat key, not a second
  ## level of hierarchy). `addCodeModelInstance` freezes
  ## `result.attrs["xspice.ports"]` from `nl`/`old`'s net names *at this
  ## exact call* -- which is the whole bug, and the whole fix, in one line.
  let inNet = old.pins["IN"].net
  let outNet = old.pins["OUT"].net
  let desig = old.designator
  removeComponent(nl, desig)
  result = addCodeModelInstance(nl, "A" & desig, gainSpec(), [inNet, outNet],
                                {"gain": "2.0"})

proc nestedCodeModelBoard(): tuple[nl: Netlist, globals: OrderedTable[string, Net]] =
  ## `XA` wraps a one-part `STAGE` template whose part carries a
  ## `SimReplacement.build`, one level deep -- the shape
  ## `designs/lib/lt8640a.nim`'s `buckConfig` doc comment describes finding
  ## this bug in.
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
  # Post-flatten names -- the port net objects were renamed to these by
  # `flatten`'s `mergeNets`, and the frozen string was built *after* that,
  # from the live `Net.name` at the time `addCodeModelInstance` ran.
  check "vin" in ports
  check "vout" in ports
  check "IN" notin ports
  check "OUT" notin ports

test "the old order (replace before flatten) freezes child-template-local names instead":
  ## Documents the bug this reorder fixes, on the exact same fixture: run
  ## `materializeSimNetlist` (replace) and *then* flatten -- what every
  ## analysis used to do -- and the frozen ports string never sees the
  ## post-flatten names at all, because nothing revisits it once it is
  ## written. This is what a deck's `A` line named nodes that did not exist
  ## post-flatten, giving ngspice a singular matrix and "Timestep too
  ## small" on what was actually a failed `.op`.
  let (top, globalNets0) = nestedCodeModelBoard()
  var globalNets = globalNets0
  let work = materializeSimNetlist(top, globalNets)
  discard flatten(work)

  # Replaced while still nested (local designator "U1"), so the new part is
  # "AU1" inside XA's own child netlist -- flatten renames *that* to
  # "XA.AU1" afterward, but has no way to revisit the string already frozen
  # onto it.
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
  # And the design netlist still describes the board, which is the invariant
  # every one of these transforms is written around.
  check nl.components["U1"].kind == "buck"
  check materializeSimNetlist(nl, g3).components["V1"].kind == "voltage_source"
