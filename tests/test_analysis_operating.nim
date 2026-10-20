import std/[math, os, strutils, tables, unittest]

import verax/netlist/dsl
import verax/netlist/formats/spice
import verax/units
import verax/spice/models
import verax/analysis/analyses/operating
import verax/contract/dsl
import verax/verify
import verax/netlist/graph
import verax/netlist/annotations
import verax/spice/boundary
import std/options

let haveNgspice = findExe("ngspice").len > 0

proc divider(cval = "10u", rating = "6.3"): Netlist =
  ## 12 V into a 10k/10k divider with a cap across the lower leg. `mid`
  ## sits at 6 V with nothing annotating it, like any bias node.
  netlist("b"):
    net gnd, kind = ntGround, name = "0"
    net vin, kind = ntPower:
      spec:
        voltage = 12.0.V
    net mid, kind = ntSignal
    component V1, kind = "voltage_source", value = "DC 12":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = "10k":
      pin "1", vin, kind = ptPassive
      pin "2", mid, kind = ptPassive
    component R2, kind = "resistor", value = "10k":
      pin "1", mid, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component C1, kind = "capacitor", value = cval, voltage_rating = rating:
      pin "1", mid, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"

proc capOf(nl: Netlist): float =
  discard parseSpiceMagnitude(nl.components["C1"].attrs["value"], result)

if not haveNgspice:
  echo "SKIP: ngspice not found on PATH"
else:
  suite "one operating point, solved once":

    test "an unknown node is NaN, not zero":
    # A node the solver never saw is not at ground.
      let op = solveOperatingPoint(divider())
      check op.solved
      check abs(voltageAt(op, "mid") - 6.0) < 1e-6
      check voltageAt(op, "0") == 0.0
      check voltageAt(op, "nosuchnet").classify == fcNan
      check across(op, "vin", "0") > 11.9
      check across(op, "vin", "nosuchnet").classify == fcNan

    test "a design that cannot solve carries the reason, not an empty table":
      let nl = netlist("floating"):
        net gnd, kind = ntGround, name = "0"
        net a, kind = ntSignal
        net b, kind = ntSignal
        component C1, kind = "capacitor", value = "100n":
          pin "1", a, kind = ptPassive
          pin "2", b, kind = ptPassive
      let op = solveOperatingPoint(nl)
      check not op.solved
      check op.reason.len > 0

  suite "the operating point feeding derating":

    test "there is no circularity to worry about":
    # A capacitor is open at DC, so the operating point doesn't depend on it.
      let small = solveOperatingPoint(divider("100p"))
      let large = solveOperatingPoint(divider("1000u"))
      check voltageAt(small, "mid") == voltageAt(large, "mid")

    test "a capacitor on an unannotated node was invisible, and is not now":
    # Unannotated nodes are where bias is worst.
      let without = divider()
      discard expandCapacitorParasitics(without)
      check abs(capOf(without) - 10.0e-6) / 10.0e-6 < 1e-6   # untouched

      let op = solveOperatingPoint(divider())
      let with = divider()
      discard expandCapacitorParasitics(with, defaultParasitics(),
                                        defaultDerating(), nodeVoltages(op))
    # 6 V on a 6.3 V part: about a third of nominal left.
      check capOf(with) < 4.0e-6
      check capOf(with) > 2.5e-6

    test "the bias wins over a stated rail, because it is the measurement":
    # The operating point knows what the node is actually doing.
      let op = solveOperatingPoint(divider())
      let nl = divider()
      nl.nets["mid"].attrs["voltage"] = "1.0"    # wrong, and stated
      discard expandCapacitorParasitics(nl, defaultParasitics(),
                                        defaultDerating(), nodeVoltages(op))
      check capOf(nl) < 4.0e-6                   # derated from 6 V, not 1 V

    test "a node the bias does not cover falls back, not off a cliff":
      let nl = divider()
      var partial: OrderedTable[string, float]
      partial["somewhereelse"] = 3.0
      discard expandCapacitorParasitics(nl, defaultParasitics(),
                                        defaultDerating(), partial)
      check abs(capOf(nl) - 10.0e-6) / 10.0e-6 < 1e-6

  suite "the shared point has a stated lifetime":
    # Cached by design identity; `readiness` clears it on both sides, which
    # this test guards.
    test "a design edited between checks is not answered from a stale solve":
      let d = design("stale"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower:
          spec:
            voltage = 5.0.V
        component V1, kind = "voltage_source", value = "DC 5":
          pin "+", vdd, kind = ptPower
          pin "-", gnd, kind = ptGround
        component R1, kind = "resistor", value = "1k":
          pin "1", vdd, kind = ptPassive
          pin "2", gnd, kind = ptPassive
        role "power_rail", r, rail = vdd, voltage = 5.0.V, band = 5.pct
      let before = readiness(d)
      check before.results.len == 1
      check before.results[0].status == esPass

    # Change the rail, not the claim.
      d.netlist.components["V1"].attrs["value"] = "DC 3"
      let after = readiness(d)
      check after.results[0].status == esFail

# --- the board with a cable pulled (`unmated`) -----------------------------

proc headerBoard(pulled: bool): Design =
  ## A header drives an MCU input; `pulled` gives the input an internal
  ## pull-up. `driveConnector` states what is plugged in: 0 V behind 100 ohm.
  result = design("hdr"):
    net gnd, kind = ntGround, name = "0"
    net vdd, kind = ntPower:
      spec:
        voltage = 3.3.V
    net tms, kind = ntSignal
    component V1, kind = "voltage_source", value = "DC 3.3":
      pin "+", vdd, kind = ptPower
      pin "-", gnd, kind = ptGround
    component J1, kind = "connector":
      pin "TMS", tms, kind = ptOutput
      pin "GND", gnd, kind = ptGround
    component U1, kind = "mcu":
      pin "PA13", tms, kind = ptInput
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
    require dc_voltage(tms) <= 0.5.V, id = "MATED"
    require dc_voltage(tms) >= 2.31.V, unmated = "J1", id = "UNMATED"
  driveConnector(findComponent(result.netlist, "J1"),
                 {"TMS": driveSource(0.0.V, rout = 100.ohm)})
  if pulled:
    setAnnotation(findPin(result.netlist, "U1.PA13"), "pull_up", 40.kohm)

proc resultFor(r: Readiness, id: string): AssertionResult =
  for x in r.results:
    if x.assertion.id == id: return x

if haveNgspice:
  suite "unmated: the board with the cable pulled":
    test "mated and unmated claims solve separately, and the pull holds the line":
      let r = readiness(headerBoard(pulled = true))
      check resultFor(r, "MATED").status == esPass        # the mate drives 0 V
      let u = resultFor(r, "UNMATED")
      check u.status == esPass
      check u.value > 3.2                                  # the pull-up, no leak
      check u.assertion.condition["unmated"] == "J1"

    test "with no pull the unmated line fails as floating, with no margin":
      let r = readiness(headerBoard(pulled = false))
      let u = resultFor(r, "UNMATED")
      check u.status == esFail
      check "floats" in u.reason
      check marginOf(u).isNone

    test "an operating point with a connector unmated records it and leaks its nets":
      var spec = defaultOperatingSpec()
      spec.unmated = @["J1"]
      let op = solveOperatingPoint(headerBoard(pulled = true).netlist, spec)
      check op.solved
      check abs(voltageAt(op, "tms") - 3.3) < 0.01
      var noted = false
      for a in op.assumptions:
        if "nothing plugged in" in $a: noted = true
      check noted

    test "unmating something that is not a connector is a reason, not a crash":
      var spec = defaultOperatingSpec()
      spec.unmated = @["U1"]
      let op = solveOperatingPoint(headerBoard(pulled = true).netlist, spec)
      check not op.solved
      check "not a connector" in op.reason
      spec.unmated = @["J9"]
      check "no such component" in solveOperatingPoint(
        headerBoard(pulled = true).netlist, spec).reason
