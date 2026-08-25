## The readiness report and its exit-code contract.
##
## Everything here runs with `offlineCapabilities`, so the whole file is
## hermetic and needs no simulator -- the graded exit codes are a property of
## how results are classified, not of what a simulation returned.

import std/[strutils, tables, unittest]

import nimcir/contract/dsl
import nimcir/verify

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

  test "a design claiming nothing says so":
    let r = readiness(claimingNothing(), offlineCapabilities)
    check r.results.len == 0
    check "NO CLAIMS" in render(r)

  test "sections appear in priority order":
    let text = render(readiness(bus("100k"), offlineCapabilities))
    check text.find("PLAN") < text.find("FAILED")
    check text.find("FAILED") < text.find("ASSUMPTIONS")

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

  test "an unknown capability is rejected rather than ignored":
    expect ValueError:
      discard parseCapabilities("dc")

  test "unrecognised flags are left for the design file":
    let o = parseVerifyArgs(["--something-else", "--strict"])
    check o.strict
    check o.allowed == allCapabilities
