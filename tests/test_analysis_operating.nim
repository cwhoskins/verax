import std/[math, os, strutils, tables, unittest]

import verax/netlist/dsl
import verax/netlist/formats/spice
import verax/units
import verax/spice/models
import verax/analysis/analyses/operating
import verax/contract/dsl
import verax/verify

let haveNgspice = findExe("ngspice").len > 0

proc divider(cval = "10u", rating = "6.3"): Netlist =
  ## A 12 V rail into a 10k/10k divider, with a capacitor across the lower
  ## leg. `mid` sits at 6 V and **nothing annotates it**, which is the shape
  ## every biased single-supply stage and divider-derived reference has.
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
      # A node the solver never saw must not be reported as sitting at
      # ground: those are different answers and only one of them is a fact.
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
      # At DC a capacitor is an open circuit, so the operating point cannot
      # depend on capacitance. That is what makes this a straight line rather
      # than a fixed point, and it is worth pinning rather than assuming.
      let small = solveOperatingPoint(divider("100p"))
      let large = solveOperatingPoint(divider("1000u"))
      check voltageAt(small, "mid") == voltageAt(large, "mid")

    test "a capacitor on an unannotated node was invisible, and is not now":
      # The blind spot covered exactly the nodes where bias is worst.
      let without = divider()
      discard expandCapacitorParasitics(without)
      check abs(capOf(without) - 10.0e-6) / 10.0e-6 < 1e-6   # untouched

      let op = solveOperatingPoint(divider())
      let with = divider()
      discard expandCapacitorParasitics(with, defaultParasitics(),
                                        defaultDerating(), nodeVoltages(op))
      # 6 V on a 6.3 V part is 95% of rating: about a third of nominal left.
      check capOf(with) < 4.0e-6
      check capOf(with) > 2.5e-6

    test "the bias wins over a stated rail, because it is the measurement":
      # Both are available here; the operating point is the one that knows
      # what the node is actually doing.
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
    # It is cached by design identity with no content invalidation, because
    # nothing down there can tell that a caller edited a netlist. `readiness`
    # clearing it on both sides is what makes that rule safe -- and this is
    # the test that would fail if somebody removed those calls.
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

      # Change what the rail actually is, leaving the claim alone.
      d.netlist.components["V1"].attrs["value"] = "DC 3"
      let after = readiness(d)
      check after.results[0].status == esFail
