import std/[strutils, tables, unittest]

import verax/units
import verax/parts
import verax/netlist/dsl
import verax/netlist/graph
import verax/netlist/annotations

suite "a module asks by function, a board answers by part":
  # The asymmetry the submodule exists for: the module knows what a part is
  # *for*, the board knows what environment it lives in, and neither can
  # choose it alone.

  test "function decides the dielectric, and timing is not a preference":
    # A Class 2 dielectric loses capacitance to DC bias and to temperature.
    # A capacitor that sets a corner must not, so C0G here is forced by
    # physics rather than chosen -- which is what makes it safe to default.
    let timing = defaultCapacitor(CapRequest(value: 22.nF, use: cuTiming))
    check timing.dielectric == "C0G"
    check isClass1(timing.dielectric)

    let decoupling = defaultCapacitor(CapRequest(value: 100.nF, use: cuDecoupling))
    check decoupling.dielectric == "X7R"
    check not isClass1(decoupling.dielectric)

  test "the decoupling guess is defaulted and said out loud, every time":
    # It is a genuine judgement rather than physics, and it is also exactly
    # where a wrong guess cost a factor of seven in measured rail impedance.
    let ch = defaultCapacitor(CapRequest(value: 10.uF, use: cuDecoupling))
    check ch.notes.len == 1
    check "X7R assumed" in ch.notes[0]
    check defaultCapacitor(CapRequest(value: 22.nF, use: cuTiming)).notes.len == 0

  test "a rating is derived from the working voltage, or not at all":
    let known = defaultCapacitor(
      CapRequest(value: 100.nF, use: cuDecoupling, working: 3.3.V))
    check float(known.voltageRating) == 10.0        # 2x 3.3 rounded up

    # Zero working voltage means the module genuinely does not know -- a
    # coupling capacitor in an unbiased stage -- and inventing a rating for
    # it would be inventing the circuit.
    let unknown = defaultCapacitor(CapRequest(value: 100.nF, use: cuDecoupling))
    check float(unknown.voltageRating) == 0.0

  test "an inductor is rated above the peak it was told about, not at it":
    # An inductor near saturation has less inductance than its label, so the
    # ripple is larger than designed, which pushes it further in. The error
    # compounds rather than averaging out.
    let ch = defaultInductor(IndRequest(value: 3.3.uH, use: iuPower, carrying: 5.A))
    check float(ch.isat) > 5.0
    check float(ch.currentRating) > 5.0
    check float(ch.isat) > float(ch.currentRating)

  test "package sizing climbs with capacitance, and with voltage rating too":
    # Same capacitance, higher rating -> a physically bigger case, because a
    # higher-voltage MLCC needs a thicker dielectric per layer.
    check smallestCeramicPackage(100.nF, 16.V) == "0603"
    check smallestCeramicPackage(100.nF, 50.V) == "0805"
    # The lookup never returns anything bigger than 1206, this module's
    # ceiling -- a capacitance beyond what 1206 plausibly holds still gets
    # 1206 back, not a guess at something larger.
    check smallestCeramicPackage(1.F, 100.V) == "1206"
    # Unstated voltage reads as the most permissive tier, the same
    # "don't know, don't invent" rule the voltage rating itself follows.
    check smallestCeramicPackage(100.nF) == smallestCeramicPackage(100.nF, 16.V)

  test "a policy is ordinary data, so a project's own is not second class":
    proc allFilm(r: CapRequest): Choice =
      result = defaultCapacitor(r)
      result.dielectric = "film"
      result.package = "film"
    var mine = defaultPolicy()
    mine.capacitor = allFilm
    check mine.capacitor(CapRequest(value: 22.nF, use: cuDecoupling)).dielectric == "film"
    check defaultPolicy().capacitor(
      CapRequest(value: 22.nF, use: cuDecoupling)).dielectric == "X7R"

suite "a choice lands as ordinary registered annotations":
  test "everything a policy decided is visible the way a spec: block would be":
    # Nothing here is private to the parts submodule: what the policy chose
    # is the same vocabulary a designer would have typed, so everything
    # downstream reads it identically either way.
    let nl = netlist("t"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      component C1, kind = "capacitor", value = "100n":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
    let c = nl.components["C1"]
    applyChoice(c, defaultCapacitor(
      CapRequest(value: 100.nF, use: cuDecoupling, working: 3.3.V)))
    check c.attrs["dielectric"] == "X7R"
    check annotationFloat(c, "voltage_rating").value == 10.0
    check c.attrs.hasKey("package")
    # ...and with provenance, so nobody mistakes a derived choice for a
    # datasheet figure.
    check annotation(c, "dielectric").source == annDerived

  test "a field the policy said nothing about is left unsaid":
    let nl = netlist("t"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      component C1, kind = "capacitor", value = "100n":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
    let c = nl.components["C1"]
    applyChoice(c, defaultCapacitor(CapRequest(value: 100.nF, use: cuDecoupling)))
    check not c.attrs.hasKey("voltage_rating")
    check not c.attrs.hasKey("isat")
