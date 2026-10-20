import std/[tables, unittest, strutils]
import verax/units
import verax/netlist/graph
import verax/netlist/annotations

import verax/netlist/dsl
import verax/analysis

test "clean netlist: output driving input directly, proper power/ground tags -> no issues":
  let nl = netlist("clean"):
    net y, kind = ntSignal
    # Stated: an unnamed rail voltage is its own finding.
    net vdd, kind = ntPower, voltage = "3.3"
    net gnd, kind = ntGround, name = "0"

    component U1, kind = "driver_ic":
      pin "OUT", y, kind = ptOutput
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround

    component U2, kind = "receiver_ic":
      pin "IN", y, kind = ptInput
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround

  check analyzeIO(nl).len == 0

test "two output pins on one net -> output_conflict error":
  let nl = netlist("conflict"):
    net y, kind = ntSignal
    component U1, kind = "driver_ic":
      pin "OUT", y, kind = ptOutput
    component U2, kind = "driver_ic":
      pin "OUT", y, kind = ptOutput

  let issues = checkOutputConflicts(nl)
  check issues.len == 1
  check issues[0].kind == "output_conflict"
  check issues[0].severity == sevError
  check issues[0].pins.len == 2

test "an output plus a shared-bus ptInOut pin is only a warning, not an error":
  let nl = netlist("open_drain_bus"):
    net sda, kind = ntSignal
    component U1, kind = "driver_ic":
      pin "OUT", sda, kind = ptOutput
    component U2, kind = "io_expander":
      pin "SDA", sda, kind = ptInOut

  let issues = checkOutputConflicts(nl)
  check issues.len == 1
  check issues[0].kind == "output_conflict"
  check issues[0].severity == sevWarning
  check issues[0].pins.len == 2

test "input with no dc path to anything is flagged":
  let nl = netlist("floating"):
    net y, kind = ntSignal
    component U1, kind = "receiver_ic":
      pin "IN", y, kind = ptInput

  let issues = checkDCPaths(nl)
  check issues.len == 1
  check issues[0].kind == "no_dc_path"
  check issues[0].severity == sevError

test "unconnected input pin is flagged distinctly":
  let nl = newNetlist("unconnected")
  let u1 = addComponent(nl, newComponent("U1", kind = "receiver_ic"))
  discard addPin(u1, newPin("IN", ptInput))

  let issues = checkDCPaths(nl)
  check issues.len == 1
  check issues[0].kind == "unconnected_input"
  check issues[0].severity == sevError

test "input reaching ground via Net.kind only satisfies the dc-path check":
  let nl = netlist("gnd_net_kind"):
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "receiver_ic":
      pin "IN", gnd, kind = ptInput

  check checkDCPaths(nl).len == 0

test "input reaching a pin tagged ptPower on an untyped net satisfies the dc-path check":
  let nl = netlist("power_pin_kind"):
    net vdd, kind = ntUnknown
    component U1, kind = "regulator_ic":
      pin "OUT", vdd, kind = ptPower
    component U2, kind = "receiver_ic":
      pin "IN", vdd, kind = ptInput

  check checkDCPaths(nl).len == 0

test "input reaching an output through a resistor has a dc path":
  let nl = netlist("through_resistor"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    component U1, kind = "driver_ic":
      pin "OUT", a, kind = ptOutput
    component R1, kind = "resistor":
      pin "1", a, kind = ptPassive
      pin "2", b, kind = ptPassive
    component U2, kind = "receiver_ic":
      pin "IN", b, kind = ptInput

  check checkDCPaths(nl).len == 0
  check classifyConductivity(nl.components["R1"]) == condConductive

test "input blocked by a capacitor is flagged as no_dc_path, not ambiguous":
  let nl = netlist("through_capacitor"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    component U1, kind = "driver_ic":
      pin "OUT", a, kind = ptOutput
    component C1, kind = "capacitor":
      pin "1", a, kind = ptPassive
      pin "2", b, kind = ptPassive
    component U2, kind = "receiver_ic":
      pin "IN", b, kind = ptInput

  let issues = checkDCPaths(nl)
  check issues.len == 1
  check issues[0].kind == "no_dc_path"
  check issues[0].components.len == 0
  check classifyConductivity(nl.components["C1"]) == condBlocking

test "input blocked only by an unrecognized/active device is flagged ambiguous":
  let nl = netlist("through_diode"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    component U1, kind = "driver_ic":
      pin "OUT", a, kind = ptOutput
    component D1, kind = "diode":
      pin "A", a, kind = ptPassive
      pin "K", b, kind = ptPassive
    component U2, kind = "receiver_ic":
      pin "IN", b, kind = ptInput

  let issues = checkDCPaths(nl)
  check issues.len == 1
  check issues[0].kind == "ambiguous_dc_path"
  check issues[0].severity == sevWarning
  check issues[0].components.len == 1
  check issues[0].components[0].designator == "D1"
  check classifyConductivity(nl.components["D1"]) == condAmbiguous

test "dc-path walk crosses a hierarchical instance boundary via hierNet":
  let GATE = subckt("GATE", [VIN, VOUT]):
    net VIN, kind = ntSignal
    net VOUT, kind = ntSignal
    component R1, kind = "resistor":
      pin "1", VIN, kind = ptPassive
      pin "2", VOUT, kind = ptPassive

  let top = netlist("top"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    component U1, kind = "driver_ic":
      pin "OUT", a, kind = ptOutput
    instance X1, GATE, [a, b]
    component U2, kind = "receiver_ic":
      pin "IN", b, kind = ptInput

  check checkDCPaths(top).len == 0

# --- a declared traverse: spec on an N-pin switch ----------------------

proc rfSwitchSheet(declared: bool): Netlist =
  ## An ADG904-shaped switch: `RFC` driven, RF1..RF4 on their own nets, `EN`
  ## grounded. Undeclared, `dcReachable` calls the 6-pin `SW1` ambiguous;
  ## declared, `RFC <-> RFn` is the only path to `U2`'s input on `rf1`.
  result = netlist("rf_switch_sheet"):
    net rfc, kind = ntSignal
    net rf1, kind = ntSignal
    net rf2, kind = ntSignal
    net rf3, kind = ntSignal
    net rf4, kind = ntSignal
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "driver_ic":
      pin "OUT", rfc, kind = ptOutput
    component SW1, kind = "rf_switch":
      pin "RFC", rfc, kind = ptPassive
      pin "RF1", rf1, kind = ptPassive
      pin "RF2", rf2, kind = ptPassive
      pin "RF3", rf3, kind = ptPassive
      pin "RF4", rf4, kind = ptPassive
      pin "EN", gnd, kind = ptInput
    component U2, kind = "receiver_ic":
      pin "IN", rf1, kind = ptInput
  if declared:
    let sw = result.components["SW1"]
    for rfn in ["RF1", "RF2", "RF3", "RF4"]:
      addTraversalEdge(sw, "RFC", rfn)

test "an undeclared rf_switch: dcReachable calls it ambiguous, as today":
  let nl = rfSwitchSheet(declared = false)
  let issues = checkDCPaths(nl)
  check issues.len == 1
  check issues[0].kind == "ambiguous_dc_path"
  check issues[0].components.len == 1
  check issues[0].components[0].designator == "SW1"

test "a declared traverse: spec makes dcReachable cross the switch: no findings":
  let nl = rfSwitchSheet(declared = true)
  check checkDCPaths(nl).len == 0

# --- a power rail nobody gave a voltage --------------------------------

proc biasRail(withVoltage: bool): Netlist =
  ## A divider-derived half-rail with a signal path returning to it -- a
  ## single-supply bias node, which no `power_rail` role fits.
  result = newNetlist("b")
  let gnd = addNet(result, newNet("0", ntGround))
  let v9 = addNet(result, newNet("v9", ntPower))
  let vref = addNet(result, newNet("vref", ntPower))
  v9.attrs["voltage"] = "9.0"
  if withVoltage: vref.attrs["voltage"] = "4.5"
  for (desig, p1, p2, kind) in [("R9", v9, vref, "resistor"),
                                ("R10", vref, gnd, "resistor"),
                                ("C6", vref, gnd, "capacitor"),
                                ("R6", vref, gnd, "resistor")]:
    let c = addComponent(result, newComponent(desig, kind = kind))
    discard connect(c, "1", p1, ptPassive)
    discard connect(c, "2", p2, ptPassive)

test "a power rail with no stated voltage is a structural finding":
  # Not an assumption: a voltage-less rail floats when isolated, changing
  # topology rather than substituting a value.
  let issues = checkRailVoltages(biasRail(withVoltage = false))
  check issues.len == 1
  check issues[0].kind == "rail_voltage_unknown"
  check issues[0].severity == sevWarning
  check issues[0].net.name == "vref"

test "it names what would lose its connection, and skips the bypass caps":
  # A rail with only power pins and bypass caps loses little by floating;
  # one with a signal path loses the path.
  let issues = checkRailVoltages(biasRail(withVoltage = false))
  check "R9" in issues[0].message
  check "R6" in issues[0].message
  check "C6" notin issues[0].message

test "stating the voltage clears it":
  check checkRailVoltages(biasRail(withVoltage = true)).len == 0

test "ground is never flagged, however it is spelled":
  var nl = newNetlist("g")
  discard addNet(nl, newNet("0", ntGround))
  discard addNet(nl, newNet("agnd", ntGround))
  check checkRailVoltages(nl).len == 0

test "a warning here does not by itself fail a run":
  # A design may not know a voltage yet: visible, not fatal (`--strict`
  # promotes it).
  let issues = checkRailVoltages(biasRail(withVoltage = false))
  for i in issues: check i.severity != sevError

test "analyzeIO includes it":
  let found = analyzeIO(biasRail(withVoltage = false))
  var kinds: seq[string]
  for i in found: kinds.add i.kind
  check "rail_voltage_unknown" in kinds

# --- connectors (the mate's drivers) and internal pulls ------------------

proc tapBoard(pull: string): Netlist =
  ## A debug header driving an MCU input, with `pull` deciding what else
  ## holds the line: "", "internal" (a stated pull-up), or "resistor".
  result = netlist("tap"):
    net tck, kind = ntSignal
    net vdd, kind = ntPower, voltage = "3.3"
    net gnd, kind = ntGround, name = "0"
    component J1, kind = "connector":
      pin "TCK", tck, kind = ptOutput
      pin "GND", gnd, kind = ptGround
    component U1, kind = "mcu":
      pin "PA14", tck, kind = ptInput
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
  if pull == "internal":
    setAnnotation(findPin(result, "U1.PA14"), "pull_up", 40.kohm)
  elif pull == "resistor":
    let r = addComponent(result, newComponent("R1", kind = "resistor"))
    discard connect(r, "1", findNet(result, "tck"), ptPassive)
    discard connect(r, "2", findNet(result, "vdd"), ptPassive)

test "an input held only by a connector's driver floats when unmated":
  let issues = checkDCPaths(tapBoard(""))
  check issues.len == 1
  check issues[0].kind == "input_floats_unmated"
  check issues[0].severity == sevWarning
  check issues[0].pins[0].name == "PA14"
  check issues[0].components[0].designator == "J1"
  check "J1" in issues[0].message

test "a stated internal pull holds the line with the connector unmated":
  check checkDCPaths(tapBoard("internal")).len == 0

test "an external pull resistor holds the line with the connector unmated":
  check checkDCPaths(tapBoard("resistor")).len == 0

test "a stated pull is a DC terminus on its own, with no connector":
  let nl = netlist("strap"):
    net boot, kind = ntSignal
    net vdd, kind = ntPower, voltage = "3.3"
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "mcu":
      pin "BOOT", boot, kind = ptInput
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
  setAnnotation(findPin(nl, "U1.BOOT"), "pull_down", 40.kohm)
  check checkDCPaths(nl).len == 0

test "floatsWithout names only the connectors it was asked about":
  let nl = tapBoard("")
  let net = findNet(nl, "tck")
  check floatsWithout(net, ["J1"]).floats
  check not floatsWithout(net, ["J9"]).floats
  check not floatsWithout(findNet(tapBoard("internal"), "tck"), ["J1"]).floats

test "checkPulls: both pulls on one pin, and an unresolvable pull rail":
  let nl = netlist("bad_pulls"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    net v1, kind = ntPower, voltage = "3.3"
    net v2, kind = ntPower, voltage = "1.8"
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "mcu":
      pin "A", a, kind = ptInput
      pin "B", b, kind = ptInput
      pin "VDD", v1, kind = ptPower
      pin "VDDIO", v2, kind = ptPower
      pin "GND", gnd, kind = ptGround
  setAnnotation(findPin(nl, "U1.A"), "pull_up", 40.kohm)
  setAnnotation(findPin(nl, "U1.A"), "pull_down", 40.kohm)
  setAnnotation(findPin(nl, "U1.B"), "pull_up", 40.kohm)
  var kinds: seq[string]
  for i in checkPulls(nl): kinds.add i.kind
  check kinds == @["pull_conflict", "pull_rail_unresolved"]
  # Naming the rail resolves it.
  setAnnotation(findPin(nl, "U1.B"), "pull_rail", "VDDIO")
  check checkPulls(nl).len == 1
