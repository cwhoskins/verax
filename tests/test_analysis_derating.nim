import std/[math, os, strutils, tables, unittest]

import verax/netlist/dsl
import verax/units
import verax/netlist/graph
import verax/spice/models
import verax/netlist/formats/spice
import verax/analysis/analyses/derating

let haveNgspice = findExe("ngspice").len > 0

proc board(rating: string, dielectric = "X7R"): Netlist =
  netlist("b"):
    net gnd, kind = ntGround, name = "0"
    net vdd, kind = ntPower:
      spec:
        voltage = 5.0.V
    component V1, kind = "voltage_source", value = "DC 5":
      pin "+", vdd, kind = ptPower
      pin "-", gnd, kind = ptGround
    component C1, kind = "capacitor", value = "10u", voltage_rating = rating:
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
    component R1, kind = "resistor", value = "1k":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive

suite "DC-bias derating changes the capacitance, not just the paperwork":
  # The largest silent error in the PDN path, and bigger than every other
  # correction in spice/models put together: an X5R bank at two thirds of its
  # rating measured 1.23 ohm of worst in-band rail impedance where the same
  # parts at their nominal values said 173 mohm.

  test "a Class 2 ceramic on a rail loses capacitance":
    let nl = board("16")
    discard expandCapacitorParasitics(nl)
    var got: float
    check parseSpiceMagnitude(nl.components["C1"].attrs["value"], got)
    check got < 10.0e-6            # derated
    check got > 6.0e-6             # 5 V on a 16 V part is light bias

  test "a Class 1 ceramic does not, and that is exact rather than typical":
    let nl = board("16", dielectric = "C0G")
    nl.components["C1"].attrs["dielectric"] = "C0G"
    discard expandCapacitorParasitics(nl)
    var got: float
    check parseSpiceMagnitude(nl.components["C1"].attrs["value"], got)
    check abs(got - 10.0e-6) / 10.0e-6 < 1e-9

  test "deeper bias costs more":
    proc capAt(rating: string): float =
      let nl = board(rating)
      discard expandCapacitorParasitics(nl)
      discard parseSpiceMagnitude(nl.components["C1"].attrs["value"], result)
    check capAt("6.3") < capAt("16")
    check capAt("16") < capAt("50")

  test "a non-ceramic family is not guessed into a ceramic":
    let nl = board("16")
    nl.components["C1"].attrs["package"] = "tantalum"
    discard expandCapacitorParasitics(nl)
    var got: float
    check parseSpiceMagnitude(nl.components["C1"].attrs["value"], got)
    check abs(got - 10.0e-6) / 10.0e-6 < 1e-9

  test "a capacitor with no DC across it is left alone":
    # A coupling capacitor between two signal nets. The working voltage is
    # not knowable before there is an operating point, and guessing at it
    # would be inventing the circuit.
    let nl = netlist("c"):
      net gnd, kind = ntGround, name = "0"
      net a, kind = ntSignal
      net b, kind = ntSignal
      component C1, kind = "capacitor", value = "100n", voltage_rating = "16":
        pin "1", a, kind = ptPassive
        pin "2", b, kind = ptPassive
    discard expandCapacitorParasitics(nl)
    var got: float
    check parseSpiceMagnitude(nl.components["C1"].attrs["value"], got)
    check abs(got - 100.0e-9) / 100.0e-9 < 1e-9

  test "every invented input is declared":
    let nl = board("16")
    let a = expandCapacitorParasitics(nl)
    var sawDielectric = false
    var sawDerate = false
    for x in a:
      if "dielectric assumed" in $x: sawDielectric = true
      if "derates to" in $x: sawDerate = true
    check sawDielectric
    check sawDerate

  test "expanding twice does not derate twice":
    let nl = board("16")
    discard expandCapacitorParasitics(nl)
    let once = nl.components["C1"].attrs["value"]
    discard expandCapacitorParasitics(nl)
    check nl.components["C1"].attrs["value"] == once

suite "is every part inside its ratings":
  test "the ceiling is per family, because the reason to derate differs":
    var spec = defaultDeratingSpec()
    check spec.ceilingByFamily["tantalum"] == 0.5
    check spec.defaultCeiling == 0.8

  if not haveNgspice:
    echo "SKIP: ngspice not found on PATH"
  else:
    test "a part over its ceiling is reported, naming what it sees":
      # 5 V across a 5.5 V part is 91% of rating, past the 80% ceramic
      # ceiling. A 6.3 V part would be 79% and deliberately would *not* be
      # reported -- the ceiling is a threshold, not a nudge.
      let r = analyzeDerating(board("5.5"))
      check r["worst_voltage_derating"] > 0.85
      check r["parts_over_derating"] >= 1.0
      var found = false
      for i in r.issues:
        if i.kind == KindOverVoltage and "C1" in i.message: found = true
      check found

    test "a part just inside the ceiling is not reported":
      let r = analyzeDerating(board("6.3"))
      check r["worst_voltage_derating"] > 0.75
      check r["parts_over_derating"] == 0.0

    test "a part with margin is not":
      let r = analyzeDerating(board("50"))
      check r["worst_voltage_derating"] < 0.2
      check r["parts_over_derating"] == 0.0

    test "over the rating is an error, merely under-derated is a warning":
      let over = analyzeDerating(board("4"))
      var sev = sevWarning
      for i in over.issues:
        if i.kind == KindOverVoltage: sev = i.severity
      check sev == sevError

    test "a design stating no rating is told so, not passed":
      # An operating point cannot tell a 6.3 V part from a 50 V one, so a
      # silent pass here would be the tool inventing the answer.
      let nl = netlist("n"):
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
      let r = analyzeDerating(nl)
      var told = false
      for a in r.assumptions:
        if "states a `voltage_rating`" in $a: told = true
      check told
