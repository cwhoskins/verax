## The readiness report and its exit-code contract.
##
## Everything here runs with `offlineCapabilities`, so the whole file is
## hermetic and needs no simulator -- the graded exit codes are a property of
## how results are classified, not of what a simulation returned.

import std/[os, strutils, tables, unittest]

import verax/contract/dsl
import verax/verify
import verax/netlist/packages

# --- fixtures -----------------------------------------------------------

proc bus(pullup: string): Design =
  ## An I2C board whose RC corner passes or fails depending on `pullup`.
  design("board"):
    # Stated: an unstated rail is a STRUCTURE finding of its own, and the
    # i2c sink-current claim cannot be evaluated without it.
    net vdd, kind = ntPower, voltage = "3.3"
    net gnd, kind = ntGround, name = "0"
    net sda, kind = ntSignal
    net scl, kind = ntSignal

    component R1, kind = "resistor", value = pullup:
      pin "1", vdd, kind = ptPassive
      pin "2", sda, kind = ptPassive
    component R2, kind = "resistor", value = pullup:
      pin "1", vdd, kind = ptPassive
      pin "2", scl, kind = ptPassive
    component U1, kind = "mcu":
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut

    role "i2c", i2c0, sda = sda, scl = scl, pullupRail = vdd,
         controller = U1, frequency = 100.kHz

proc claimingNothing(): Design =
  design("empty"):
    net gnd, kind = ntGround, name = "0"
    net vdd, kind = ntPower, voltage = "3.3"
    component R1, kind = "resistor", value = "10k":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive

# --- the report ---------------------------------------------------------

suite "readiness":
  test "a passing design is clean":
    let r = readiness(bus("2.2k"), offlineCapabilities)
    check exitCode(r) == exitClean
    check count(r.results, esFail) == 0

  test "a failing claim exits 1":
    # 100k against the assumed bus capacitance puts the corner far under the
    # ten-times-clock the role asks for.
    let r = readiness(bus("100k"), offlineCapabilities)
    check exitCode(r) == exitFailed
    check count(r.results, esFail) > 0
    check "FAILED" in render(r)

  test "a quantity nothing produces exits 3, and is not a failure":
    var d = bus("2.2k")
    d.assertThat mkAssertion("z_ripple", @[Subject(kind: skNet, name: "vdd")],
                             expectMax(10.mV), "V", id = "REQ-BOGUS")
    let r = readiness(d, offlineCapabilities)
    check exitCode(r) == exitUnchecked
    check count(r.results, esNotEvaluable) == 1
    check count(r.results, esFail) == 0

  test "an unevaluable quantity suggests near matches":
    var d = bus("2.2k")
    d.assertThat mkAssertion("z_mim", @[Subject(kind: skNet, name: "vdd")],
                             expectMax(1.ohm), "ohm", id = "REQ-TYPO")
    let text = render(readiness(d, offlineCapabilities))
    check "did you mean" in text
    check "z_min" in text

  test "withholding a capability is not the same as nothing producing it":
    # `dc_voltage` has an evaluator; offline simply does not offer it. That
    # must read as not-evaluated, never as not-evaluable, or an author
    # deletes a requirement that was fine.
    var d = bus("2.2k")
    d.assertThat mkAssertion("dc_voltage", @[Subject(kind: skNet, name: "vdd")],
                             expectEq(3.3.V, 5.pct), "V", id = "REQ-DC")
    let r = readiness(d, offlineCapabilities)
    check count(r.results, esNotEvaluated) == 1
    check count(r.results, esNotEvaluable) == 0
    check exitCode(r) == exitClean          # a deliberate choice, not an oversight
    check exitCode(r, strict = true) == exitUnchecked

  test "structural errors outrank assertion failures":
    let d = bus("100k")                     # already has failing claims
    d.netlist.nets["sda"].attrs["ESR"] = "1.0"   # bare key, not registered
    let r = readiness(d, offlineCapabilities)
    check r.structural.len > 0
    check exitCode(r) == exitFailed              # warning does not promote
    check exitCode(r, strict = true) == exitStructural

  test "a package finding reaches STRUCTURE and grades the exit code":
    registerPackage(newPackageDef("TEST_DUAL_RDY", [
      (id: "1", section: "A", logical: "OUT"),
      (id: "2", section: "A", logical: "IN"),
      (id: "3", section: "",  logical: "V+"),
      (id: "4", section: "B", logical: "IN"),
      (id: "5", section: "B", logical: "OUT")], partNumber = "TEST_DUAL_RDY"))
    let pkg = packageInstance("TEST_DUAL_RDY", "U9")
    let d = design("packaged"):
      net gnd, kind = ntGround, name = "0"
      net vpa, kind = ntPower, voltage = "5"
      net vpb, kind = ntPower, voltage = "5"
      net a, kind = ntSignal
      net b, kind = ntSignal
      component U9A, kind = "opamp", partNumber = "TEST_DUAL_RDY":
        pin "OUT", a
        pin "IN", gnd
        pin "V+", vpa, kind = ptPower
      component U9B, kind = "opamp", partNumber = "TEST_DUAL_RDY":
        pin "OUT", b
        pin "IN", gnd
        pin "V+", vpb, kind = ptPower
    pkg.assign(d.netlist, "A", "U9A")
    pkg.assign(d.netlist, "B", "U9B")
    let r = readiness(d, offlineCapabilities)
    var found = false
    for i in r.structural:
      if i.kind == "package_global_pin_conflict": found = true
    check found
    check exitCode(r) == exitStructural
    check "STRUCTURE" in render(r)

  test "a design claiming nothing says so":
    let r = readiness(claimingNothing(), offlineCapabilities)
    check r.results.len == 0
    check "NO CLAIMS" in render(r)

  test "sections appear in priority order":
    let text = render(readiness(bus("100k"), offlineCapabilities))
    # Structure first (it undermines every number below it), then the tests
    # themselves, then the digest of what did not hold -- last, so it is what
    # is still on screen when the run ends.
    check text.find("CHECKS") < text.find("FAILED")

  test "an assumption is reported under the test that rests on it":
    # Pooled at the foot of the report, forty invented values say that
    # something was assumed *somewhere*, and the reader cannot tell which
    # number each one moved.
    let text = render(readiness(bus("2.2k"), offlineCapabilities))
    check "ASSUMPTIONS" notin text
    let ass = text.find("assuming")
    check ass > text.find("CHECKS")
    # ... inside a check block, above the claims that rest on it.
    check ass < text.find("rc_corner(net 'sda')")

  test "a claim is rendered as a comparison, both numbers on one line":
    let text = render(readiness(bus("100k"), offlineCapabilities))
    var cmpLine = ""
    for line in text.splitLines():
      if "expect" in line and "measured" in line: cmpLine = line
    check cmpLine.len > 0
    check cmpLine.find("expect") < cmpLine.find("measured")

  test "what each test actually ran is stated in words, not as a setup key":
    let text = render(readiness(bus("2.2k"), offlineCapabilities))
    check "ran: a graph walk of net 'sda'" in text

  test "the report never carries a simulation curve":
    # `AnalysisReport.raw` holds thousands of points. `AssertionResult` has no
    # field for it, which is what keeps this true -- pin the size anyway, so a
    # future "attach the curve for context" change fails here rather than in
    # someone's context window.
    let text = render(readiness(bus("2.2k"), offlineCapabilities), verbose = true)
    check text.splitLines().len < 200

  test "a claim stating no unit against a measured one is reported":
    # `unitOf(Fraction)` is "" and `unitsAgree` treats an empty unit as
    # unchecked, so `<= 5.pct` against a quantity measured in "%" compares
    # 0.05 to 5.0 and is wrong by a hundred with nothing said.
    var d = bus("2.2k")
    d.assertThat mkAssertion("rc_corner", @[Subject(kind: skNet, name: "sda")],
                             expectMin(1.0), "", id = "REQ-NOUNIT")
    let r = readiness(d, offlineCapabilities)
    var found = false
    for i in r.structural:
      if i.kind == "claim_unit_unstated": found = true
    check found

suite "capabilities":
  test "static is always available and never withheld by --caps":
    check capStatic in availableCapabilities("none")
    check capStatic in parseCapabilities("ac")

  test "flags parse":
    check parseVerifyArgs(["--offline"]).allowed == offlineCapabilities
    check parseVerifyArgs(["--verbose"]).verbose
    check parseVerifyArgs(["--strict"]).strict
    check parseVerifyArgs(["--caps=ac,tran"]).allowed ==
          {capStatic, capSpiceAc, capSpiceTran}
    check parseCapabilities(".op") == {capStatic, capSpiceOp}
    check parseVerifyArgs(["--schematic-layout=constrained-layered"]).schematicLayout ==
          "constrained-layered"

  test "the schematic-layout flag bridges to the archive environment":
    let had = existsEnv("VERAX_SCHEMATIC_LAYOUT")
    let old = getEnv("VERAX_SCHEMATIC_LAYOUT")
    try:
      discard verifyMain(claimingNothing(),
        @["--offline", "--schematic-layout=constrained-layered"])
      check getEnv("VERAX_SCHEMATIC_LAYOUT") == "constrained-layered"
    finally:
      if had: putEnv("VERAX_SCHEMATIC_LAYOUT", old)
      else: delEnv("VERAX_SCHEMATIC_LAYOUT")

  test "an unknown capability is rejected rather than ignored":
    # `dc` used to be the example here, which is what an enum member's
    # arrival looks like from a test: the word stopped being unknown.
    check parseCapabilities("dc") == {capStatic, capSpiceDc}
    expect ValueError:
      discard parseCapabilities("noise")
    expect ValueError:
      discard parseVerifyArgs(["--schematic-layout=diagonal"])

  test "unrecognised flags are left for the design file":
    let o = parseVerifyArgs(["--something-else", "--strict"])
    check o.strict
    check o.allowed == allCapabilities

suite "checks: one block per test":
  test "results are grouped by the run that produced them, not by status":
    let r = readiness(bus("2.2k"), offlineCapabilities)
    check r.checks.len > 0
    # Every result accounted for exactly once: the flat list is the checks
    # followed by whatever reached no test at all.
    var grouped = 0
    for c in r.checks: grouped += c.results.len
    check grouped + r.rejected.len == r.results.len
    for c in r.checks:
      check c.results.len > 0
      check c.evaluator.len > 0

  test "a check carries only the assumptions its own batch rested on":
    let r = readiness(bus("2.2k"), offlineCapabilities)
    # `rc_corner` invents a per-pin bus capacitance; `pullup_count` counts
    # resistors and invents nothing. Pooling them would attribute the
    # invented number to both.
    var withAssumption, without: int
    for c in r.checks:
      if c.evaluator == "static.rc_corner":
        check c.assumptions.len == 1
        check c.assumptions[0].key == "bus_capacitance"
        inc withAssumption
      elif c.evaluator == "static.pullup_count":
        check c.assumptions.len == 0
        inc without
    check withAssumption > 0
    check without > 0

  test "an assumption carries no author-stated value":
    let r = readiness(bus("2.2k"), offlineCapabilities)
    for c in r.checks:
      for a in c.assumptions:
        check a.source != annAuthored

suite "folding assumptions":
  test "one line names every part the same assumption was made about":
    let folded = foldAssumptions(@[
      assumption("C1", "esr", 0.03, "ohm", annDefaulted, "from package default"),
      assumption("C2", "esr", 0.03, "ohm", annDefaulted, "from package default"),
      assumption("C3", "esr", 0.02, "ohm", annDefaulted, "from package default")])
    check folded.len == 2
    check folded[0] == "C1, C2: esr 30.0 mohm from package default"
    check folded[1] == "C3: esr 20.0 mohm from package default"

  test "a differing magnitude is a different assumption, not a fold":
    let folded = foldAssumptions(@[
      assumption("C1", "esl", 6.0e-10, "H", annDefaulted, "0402"),
      assumption("C2", "esl", 8.0e-10, "H", annDefaulted, "0603")])
    check folded.len == 2

  test "a narrative note folds too, when it names a part":
    # `note` has no key and no magnitude, and its detail is a whole sentence.
    # Folding still applies -- four capacitors derated identically are one
    # statement about four parts.
    let folded = foldAssumptions(@[
      note("C1", "derates to 65% of nominal"),
      note("C2", "derates to 65% of nominal"),
      note("no ground reference was found")])
    check folded.len == 2
    check folded[0] == "C1, C2: derates to 65% of nominal"
    check folded[1] == "no ground reference was found"

suite "a claim as a comparison":
  test "a frequency band is stated as one, not as its condition keys":
    var a = mkAssertion("z_max_in_band", @[Subject(kind: skNet, name: "vdd")],
                        expectMax(0.2), "ohm", id = "Z")
    a.condition["f_from"] = "1.0e5"
    a.condition["f_to"] = "1.0e8"
    check conditionText(a) == "over 100 kHz .. 100 MHz"

  test "an unknown condition key is passed through rather than dropped":
    var a = mkAssertion("q", @[Subject(kind: skNet, name: "n")],
                        expectMax(1.0), "", id = "Q")
    a.condition["phase_of_moon"] = "gibbous"
    check "phase_of_moon" in conditionText(a)

  test "a tolerance is spelled out as the interval it accepts":
    let a = mkAssertion("dc_voltage", @[Subject(kind: skNet, name: "vdd")],
                        expectEq(3.3.V, 5.pct), "V", id = "V")
    check acceptance(a) == "3.13 V .. 3.46 V"

  test "a target with no tolerance says the number once":
    let a = mkAssertion("n", @[Subject(kind: skNet, name: "sda")],
                        expectEq(1.0, 0.pct), "", id = "N")
    check acceptance(a) == ""

suite "the catalog names a two-subject quantity as one":
  test "channel_match's role parts render as `role`, not `class`":
    let text = describeRole("channel_match")
    check "role" in text
    # The generic `($kind)[2..^1]` slice would print `class`; a role
    # reference is a role to a reader.
    check "class" notin text

  test "a quantity whose evaluator takes two subjects is marked in the catalog":
    let q = describeQuantities()
    check "gain_delta_max_db" in q
    for line in q.splitLines():
      if line.strip().startsWith("gain_delta_max_db"):
        check "2 subjects" in line

suite "relative and predicate claims in the report":
  test "a relative claim folds to one result and never leaks its hidden requests":
    var d = bus("2.2k")
    # 1 pull-up on sda >= 2 * 1 pull-up on scl is false: the reference run
    # (scl) exists only to feed this claim and must not appear as a claim.
    d.assertThat relAssertion("pullup_count",
      @[Subject(kind: skNet, name: "sda")], roGe, 2.0,
      "pullup_count", @[Subject(kind: skNet, name: "scl")],
      id = "REQ-REL-FAIL")
    let r = readiness(d, offlineCapabilities)
    var seen = 0
    for res in r.results:
      if res.assertion.id == "REQ-REL-FAIL": inc seen
    check seen == 1
    check count(r.results, esFail) == 1
    let text = render(r)
    check "REQ-REL-FAIL" in text
    check "contract-dep" notin text

  test "a predicate claim renders as a predicate, not as a measurement":
    var d = bus("2.2k")
    d.assertThat predicateAssertion(
      @[dep("sda_pullups", "pullup_count", @[Subject(kind: skNet, name: "sda")]),
        dep("scl_pullups", "pullup_count", @[Subject(kind: skNet, name: "scl")])],
      proc (values: seq[float]): bool {.nimcall.} = values[0] == values[1],
      id = "REQ-PRED")
    let r = readiness(d, offlineCapabilities)
    check count(r.results, esPass) >= 1
    let text = render(r)
    check "REQ-PRED" in text
    check "predicate" in text
