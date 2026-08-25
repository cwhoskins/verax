import std/[strutils, tables, unittest]

import nimcir/netlist/dsl
import nimcir/netlist/annotations
import nimcir/units
import nimcir/spice/isolate
import nimcir/spice/models

proc board(): Netlist =
  ## An op-amp with an input divider and feedback, its own decoupling cap on
  ## VDD, and a downstream ADC three passives away.
  netlist("board"):
    net vdd, kind = ntPower, voltage = "3.3"
    net gnd, kind = ntGround, name = "0"
    net inp, kind = ntSignal
    net inn, kind = ntSignal
    net outn, kind = ntSignal
    net mid, kind = ntSignal
    net far, kind = ntSignal

    component U1, kind = "opamp":
      pin "INP", inp, kind = ptInput
      pin "INN", inn, kind = ptInput
      pin "OUT", outn, kind = ptOutput
      pin "V+", vdd, kind = ptPower
      pin "V-", gnd, kind = ptGround

    component R1, kind = "resistor", value = "10k":
      pin "1", outn, kind = ptPassive
      pin "2", inn, kind = ptPassive
    component R2, kind = "resistor", value = "1.111k":
      pin "1", inn, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component R3, kind = "resistor", value = "1k":
      pin "1", outn, kind = ptPassive
      pin "2", mid, kind = ptPassive
    component R4, kind = "resistor", value = "1k":
      pin "1", mid, kind = ptPassive
      pin "2", far, kind = ptPassive

    component C1, kind = "capacitor", value = "100n", package = "0402":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component C2, kind = "capacitor", value = "10u", package = "tantalum":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    component U2, kind = "adc":
      pin "IN", far, kind = ptInput
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround

proc names(nl: Netlist): seq[string] =
  for d in nl.components.keys: result.add d

test "growth absorbs passives, stops at active devices, and never crosses a rail":
  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec("opamp_stage")
  let iso = isolate(board(), ["U1"], spec, globals)

  check iso.seeds == @["U1"]
  for d in ["R1", "R2", "R3", "R4"]:
    check d in iso.absorbed
  check iso.dropped == @["U2"]

  # C1/C2 hang between two rails, so the walk never reaches them. That is
  # the rail rule working: a decoupling cap is irrelevant to the op-amp's
  # response once VDD is an ideal source, and traversing VDD would have
  # pulled in the whole board.
  check "C1" notin iso.absorbed
  check "C2" notin iso.absorbed
  check "U2" notin iso.absorbed

test "the boundary is terminated into something a simulator will accept":
  var globals: OrderedTable[string, Net]
  let iso = isolate(board(), ["U1"], defaultIsolationSpec("opamp_stage"), globals)
  let frag = iso.netlist

  check frag.nets.hasKey("0")
  check frag.nets["0"].kind == ntGround

  # VDD became an ideal 3.3 V source, taken from Net.attrs["voltage"].
  check iso.railNets == @["vdd"]
  check "V_vdd" in frag.names
  check frag.components["V_vdd"].kind == "voltage_source"
  check frag.components["V_vdd"].attrs["value"].startsWith("DC 3.3")

  # `mid` was cut mid-chain, so it is open and gets a DC reference.
  check "far" in iso.openPorts
  check "R_LEAK_far" in frag.names

  # Every assumption the fragment rests on is stated.
  check iso.assumptions.len == 2
  check ($iso.assumptions[0]).contains("ideal")
  check ($iso.assumptions[1]).contains("DC reference")
  # Structured, not prose: the rail voltage is a real number with provenance.
  check iso.assumptions[0].key == "voltage"
  check abs(iso.assumptions[0].value - 3.3) < 1e-12
  check iso.assumptions[0].source == annDerived

test "the design netlist is never mutated":
  let nl = board()
  let before = nl.components.len
  let netsBefore = nl.nets.len
  var globals: OrderedTable[string, Net]
  discard isolate(nl, ["U1"], defaultIsolationSpec(), globals)
  check nl.components.len == before
  check nl.nets.len == netsBefore
  check "V_vdd" notin nl.names

test "maxHops bounds the growth":
  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec()
  spec.maxHops = 0
  let iso = isolate(board(), ["U1"], spec, globals)
  # R3 sits on a hop-0 net so it is still absorbed, but its far side (`mid`)
  # is never enqueued, so R4 is not.
  check "R3" in iso.absorbed
  check "R4" notin iso.absorbed

test "stopKinds cuts a part that would otherwise be absorbed":
  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec()
  spec.stopKinds = @["resistor"]
  let iso = isolate(board(), ["U1"], spec, globals)
  check iso.absorbed.len == 0
  check "R1" in iso.dropped

test "an unknown rail voltage raises rather than being guessed":
  let nl = board()
  nl.nets["vdd"].attrs.del("voltage")
  var globals: OrderedTable[string, Net]
  expect(NetlistError):
    discard isolate(nl, ["U1"], defaultIsolationSpec(), globals)

test "requireKnownRails = false leaves the rail floating and says so":
  let nl = board()
  nl.nets["vdd"].attrs.del("voltage")
  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec()
  spec.requireKnownRails = false
  let iso = isolate(nl, ["U1"], spec, globals)
  check iso.railNets.len == 0
  check ($iso.assumptions[0]).contains("left floating")

test "railVoltages overrides the net attribute":
  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec()
  spec.railVoltages["vdd"] = 5.0
  let iso = isolate(board(), ["U1"], spec, globals)
  check iso.netlist.components["V_vdd"].attrs["value"].startsWith("DC 5")

test "isolateNets from a rail collects the decoupling network and drops the ICs":
  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec("pdn")
  spec.excludeRails = @["vdd"]
  let iso = isolateNets(board(), ["vdd"], spec, globals)

  check "C1" in iso.absorbed
  check "C2" in iso.absorbed
  # The op-amp and the ADC hang off VDD but cannot be modelled, so they are
  # reported as cut rather than silently ignored.
  check "U1" in iso.dropped
  check "U2" in iso.dropped
  # Nothing downstream of the rail leaked in.
  check "R1" notin iso.absorbed

test "an excluded rail is left open instead of being shorted by an ideal source":
  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec("pdn")
  spec.excludeRails = @["vdd"]
  let iso = isolateNets(board(), ["vdd"], spec, globals)

  check iso.railNets.len == 0
  check "V_vdd" notin iso.netlist.names
  check "vdd" in iso.openPorts
  check "R_LEAK_vdd" in iso.netlist.names

test "a fragment with no ground at all raises a clear error":
  let nl = netlist("floating"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    component R1, kind = "resistor", value = "1k":
      pin "1", a, kind = ptPassive
      pin "2", b, kind = ptPassive
  var globals: OrderedTable[string, Net]
  expect(NetlistError):
    discard isolate(nl, ["R1"], defaultIsolationSpec(), globals)

test "a named ground that is not called 0 is promoted to node 0":
  let nl = netlist("agnd"):
    net agnd, kind = ntGround
    net a, kind = ntSignal
    component R1, kind = "resistor", value = "1k":
      pin "1", a, kind = ptPassive
      pin "2", agnd, kind = ptPassive
  var globals: OrderedTable[string, Net]
  let iso = isolate(nl, ["R1"], defaultIsolationSpec(), globals)
  check iso.netlist.nets.hasKey("0")
  check not iso.netlist.nets.hasKey("agnd")

test "two distinct grounds are a design decision, not a transform":
  let nl = netlist("two_grounds"):
    net agnd, kind = ntGround
    net dgnd, kind = ntGround, name = "0"
    net a, kind = ntSignal
    component R1, kind = "resistor", value = "1k":
      pin "1", a, kind = ptPassive
      pin "2", agnd, kind = ptPassive
    component R2, kind = "resistor", value = "1k":
      pin "1", a, kind = ptPassive
      pin "2", dgnd, kind = ptPassive
  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec()
  spec.groundNet = "agnd"
  expect(NetlistError):
    discard isolate(nl, ["R1", "R2"], spec, globals)

# --- annotations and role membership across the cut --------------------

import nimcir/contract

test "annotations and role membership survive isolation, rename included":
  # The decisive case for storing this on the entity rather than in a
  # side-car keyed by name: `terminate` renames the ground net to "0", so a
  # name-keyed store would lose exactly the net whose annotations matter most.
  let nl = netlist("agnd_board"):
    net agnd, kind = ntGround
    net vdd, kind = ntPower
    net sig, kind = ntSignal
    component R1, kind = "resistor", value = "1k":
      pin "1", vdd, kind = ptPassive
      pin "2", sig, kind = ptPassive
    component C1, kind = "capacitor", value = "100n":
      pin "1", sig, kind = ptPassive
      pin "2", agnd, kind = ptPassive
    component U1, kind = "mcu":
      pin "IN", sig, kind = ptInput
      pin "VDD", vdd, kind = ptPower

  let d = newDesign(nl)
  discard d.addRole("power_rail", "vdd_rail",
                    {"rail": Subject(kind: skNet, name: "vdd")}, {"voltage": "3.3"})
  setAnnotation(nl.components["C1"], "esr", 20.mohm)
  # Tag the ground net too, so the rename is genuinely exercised.
  nl.nets["agnd"].attrs["role.gnd_ref"] = "rail"

  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec("frag")
  spec.groundNet = "agnd"
  let iso = isolate(nl, ["C1"], spec, globals)
  let frag = iso.netlist

  # The rename happened...
  check frag.nets.hasKey("0")
  check not frag.nets.hasKey("agnd")
  # ...and the annotation came with it.
  check rolesOf(frag.nets["0"]) == @[(instance: "gnd_ref", part: "rail")]

  # The rail's role tag and its voltage both crossed the boundary, and the
  # voltage is what let `terminate` drive the rail without being told.
  check rolesOf(frag.nets["vdd"]) == @[(instance: "vdd_rail", part: "rail")]
  check iso.railNets == @["vdd"]
  check frag.components["V_vdd"].attrs["value"].startsWith("DC 3.3")

  # Component annotations survive too.
  check abs(esr(frag.components["C1"]).value - 0.02) < 1e-15
