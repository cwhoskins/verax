import std/[tables, unittest]

import nimcir/netlist/dsl
import nimcir/analysis

test "clean netlist: output driving input directly, proper power/ground tags -> no issues":
  let nl = netlist("clean"):
    net y, kind = ntSignal
    net vdd, kind = ntPower
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
