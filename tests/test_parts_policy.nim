import std/[strutils, tables, unittest]

import verax/units
import verax/parts
import verax/netlist/dsl
import verax/netlist/graph
import verax/netlist/annotations

suite "a module asks by function, a board answers by part":
  # The module knows what a part is for; the board knows its environment.

  test "function decides the dielectric, and timing is not a preference":
    # A Class 2 dielectric loses capacitance to bias and temperature; a
    # corner-setting cap can't, so C0G is forced by physics.
    let timing = defaultCapacitor(CapRequest(value: 22.nF, use: cuTiming))
    check timing.dielectric == "C0G"
    check isClass1(timing.dielectric)

    let decoupling = defaultCapacitor(CapRequest(value: 100.nF, use: cuDecoupling))
    check decoupling.dielectric == "X7R"
    check not isClass1(decoupling.dielectric)

  test "the decoupling guess is defaulted and said out loud, every time":
    # A real judgement, and where a wrong guess costs most in rail impedance.
    let ch = defaultCapacitor(CapRequest(value: 10.uF, use: cuDecoupling))
    check ch.notes.len == 1
    check "X7R assumed" in ch.notes[0]
    check defaultCapacitor(CapRequest(value: 22.nF, use: cuTiming)).notes.len == 0

  test "a rating is derived from the working voltage, or not at all":
    let known = defaultCapacitor(
      CapRequest(value: 100.nF, use: cuDecoupling, working: some(3.3.V)))
    check float(known.voltageRating.get) == 10.0        # 2x 3.3 rounded up

    # Zero working voltage means unknown; a rating would invent the circuit.
    let unknown = defaultCapacitor(CapRequest(value: 100.nF, use: cuDecoupling))
    check unknown.voltageRating.isNone

  test "an inductor is rated above the peak it was told about, not at it":
    # Saturation lowers inductance, raising ripple, which compounds.
    let ch = defaultInductor(IndRequest(value: 3.3.uH, use: iuPower, carrying: some(5.A)))
    check float(ch.isat.get) > 5.0
    check float(ch.currentRating.get) > 5.0
    check float(ch.isat.get) > float(ch.currentRating.get)

  test "package sizing climbs with capacitance, and with voltage rating too":
    # Higher rating -> bigger case for the same capacitance.
    check smallestCeramicPackage(100.nF, 16.V) == "0603"
    check smallestCeramicPackage(100.nF, 50.V) == "0805"
    # Never bigger than 1206, this module's ceiling.
    check smallestCeramicPackage(1.F, 100.V) == "1206"
    # Unstated voltage is the most permissive tier.
    check smallestCeramicPackage(100.nF) == smallestCeramicPackage(100.nF, 16.V)

  test "a Choice carries the use that produced it, spelled for part_use":
    # `Choice.use` records why the dielectric was picked, so a timing "C0G"
    # and a bypass "C0G" stay distinguishable.
    check defaultCapacitor(CapRequest(value: 22.nF, use: cuTiming)).use == "timing"
    check defaultCapacitor(CapRequest(value: 100.nF, use: cuCoupling)).use == "coupling"
    check defaultCapacitor(CapRequest(value: 100.nF, use: cuDecoupling)).use == "decoupling"
    check defaultCapacitor(CapRequest(value: 10.uF, use: cuBulk)).use == "bulk"
    check defaultResistor(ResRequest(value: 1.kohm, use: ruPrecision)).use == "precision"
    check defaultResistor(ResRequest(value: 1.kohm, use: ruGeneral)).use == "general"
    check defaultResistor(ResRequest(value: 1.kohm, use: ruPower)).use == "power"
    check defaultInductor(IndRequest(value: 10.uH, use: iuFilter)).use == "filter"
    # `part_use` allows the union of the three enums' meanings.
    check defaultInductor(IndRequest(value: 10.uH, use: iuPower)).use == "power"

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
    # The policy writes the same vocabulary a designer would type.
    let nl = netlist("t"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      component C1, kind = "capacitor", value = "100n":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
    let c = nl.components["C1"]
    applyChoice(c, defaultCapacitor(
      CapRequest(value: 100.nF, use: cuDecoupling, working: some(3.3.V))))
    check c.attrs["dielectric"] == "X7R"
    check annotationFloat(c, "voltage_rating").value == 10.0
    check c.attrs.hasKey("package")
    # ...with provenance, so it isn't mistaken for a datasheet figure.
    check annotation(c, "dielectric").source == annDerived
    # `part_use` lets a BoM compiler or reviewer tell timing from bypass.
    check c.attrs["part_use"] == "decoupling"
    check partUse(c).value == "decoupling"
    check partUse(c).source == annDerived

  test "a bad part_use that reaches attrs some other way is caught at readiness":
    # `setAnnotation` refuses a bad `part_use`, so this bypasses it the way a
    # file reader or raw attrs would.
    let nl = netlist("t"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower
      component C1, kind = "capacitor", value = "100n":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
    let c = nl.components["C1"]
    c.attrs["part_use"] = "timming"
    let issues = validateAnnotations(nl)
    check issues.len == 1
    check issues[0].kind == "annotation_not_allowed"
    check issues[0].severity == sevError
    check "timming" in issues[0].message

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
