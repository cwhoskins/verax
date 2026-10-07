## `--format=json`, `--format=junit`, per-claim margins, and `--baseline`
## diffing. Runs offline.

import std/[json, options, os, strutils, tables, unittest, xmlparser, xmltree]

import verax/contract/dsl
import verax/verify
import verax/units

proc net(name: string): Subject = Subject(kind: skNet, name: name)

proc bus(pullup: string): Design =
  ## An I2C board whose RC corner passes or fails depending on `pullup`.
  design("board"):
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

# --- margin arithmetic ----------------------------------------------------

proc fakeResult(status: EvalStatus, expect: Expectation, value: float,
               unit = ""): AssertionResult =
  AssertionResult(assertion: Assertion(quantity: "q", unit: unit, expect: expect),
                  status: status, value: value, unit: unit)

suite "margin arithmetic":
  test "dead centre of a two-sided band is a fraction of 1.0":
    let m = marginOf(fakeResult(esPass, nominal(10.0, fracTol = 0.1), 10.0))
    check m.isSome
    check m.get.twoSided
    check m.get.hasFrac
    check abs(m.get.frac - 1.0) < 1e-9

  test "sitting exactly on an edge is a fraction of 0.0":
    let m = marginOf(fakeResult(esPass, nominal(10.0, fracTol = 0.1), 11.0))
    check m.isSome
    check abs(m.get.frac - 0.0) < 1e-9
    check abs(m.get.abs - 0.0) < 1e-9

  test "a one-sided minimum is a fraction of the limit, not of a band":
    let m = marginOf(fakeResult(esPass, atLeast(1.0e6), 1.234e6))
    check m.isSome
    check not m.get.twoSided
    check m.get.hasFrac
    check abs(m.get.abs - 2.34e5) < 1.0
    check abs(m.get.frac - 0.234) < 1e-6

  test "a zero one-sided limit has no fraction, only absolute headroom":
    let m = marginOf(fakeResult(esPass, atLeast(0.0), 5.0))
    check m.isSome
    check not m.get.hasFrac
    check m.get.abs == 5.0

  test "a nominal target with zero tolerance has no fraction either":
    let m = marginOf(fakeResult(esPass, nominal(1.0, absTol = 0.0), 1.0))
    check m.isSome
    check m.get.twoSided
    check not m.get.hasFrac

  test "margin is negative when the claim failed, not clamped to zero":
    let m = marginOf(fakeResult(esFail, atMost(1.0), 1.5))
    check m.isSome
    check m.get.abs < 0.0

  test "a relative or predicate expectation never gets a margin":
    let rel = relative(roGe, 2.0, measurementRef("pullup_count", @[net("scl")]))
    check marginOf(fakeResult(esPass, rel, 3.0)).isNone
    let pred = predicate(@[], proc (v: seq[float]): bool {.nimcall.} = true)
    check marginOf(fakeResult(esPass, pred, 1.0)).isNone

  test "a claim nothing measured has no margin":
    check marginOf(fakeResult(esNotEvaluated, atLeast(1.0), NaN)).isNone
    check marginOf(fakeResult(esNotEvaluable, atLeast(1.0), NaN)).isNone

# --- --format=json ---------------------------------------------------------

suite "--format=json":
  test "parses, and every documented top-level and result key is present":
    let r = readiness(bus("2.2k"), offlineCapabilities)
    let j = parseJson(renderJson(r))
    for key in ["schema", "design", "simulator", "capabilities", "environment",
                "exit", "summary", "structural", "checks", "results"]:
      check j.hasKey(key)
    check j["schema"].getStr() == "verax.readiness/1"
    check j["capabilities"].hasKey("requested")
    check j["capabilities"].hasKey("available")
    check j["capabilities"].hasKey("missing")
    check j["summary"]["total"].getInt() == r.results.len
    check j["results"].len == r.results.len
    let one = j["results"][0]
    for key in ["id", "quantity", "subjects", "condition", "expect", "status",
                "value", "unit", "margin", "evaluator", "check", "severity",
                "reason", "rationale", "assumptions", "issues"]:
      check one.hasKey(key)

  test "a passing claim's margin is a populated object, not null":
    let r = readiness(bus("2.2k"), offlineCapabilities)
    let j = parseJson(renderJson(r))
    var sawMargin = false
    for res in j["results"]:
      if res["status"].getStr() == "pass":
        check res["margin"].kind == JObject
        check res["margin"].hasKey("abs")
        check res["margin"].hasKey("frac")
        check res["margin"].hasKey("twoSided")
        sawMargin = true
    check sawMargin

  test "NaN never reaches the document as the bare invalid-JSON literal":
    var d = bus("2.2k")
    d.assertThat mkAssertion("z_ripple", @[net("vdd")], expectMax(10.mV), "V",
                            id = "REQ-BOGUS")
    let text = renderJson(readiness(d, offlineCapabilities))
    # `parseJson` raises on a bare `nan`; the field checks pin where it would
    # have been.
    let j = parseJson(text)
    var found = false
    for res in j["results"]:
      if res["id"].getStr() == "REQ-BOGUS":
        found = true
        check res["value"].kind == JNull
        check res["margin"].kind == JNull
    check found

  test "a design claiming nothing writes a valid, empty-results document":
    let j = parseJson(renderJson(readiness(claimingNothing(), offlineCapabilities)))
    check j["results"].len == 0
    check j["summary"]["total"].getInt() == 0

  test "--baseline present only when a baseline path was given":
    let r = readiness(bus("2.2k"), offlineCapabilities)
    check not parseJson(renderJson(r)).hasKey("baseline")
    let withBaseline = parseJson(renderJson(r, changes = @[], baselinePath = "/tmp/x.json"))
    check withBaseline.hasKey("baseline")
    check withBaseline["baseline"]["path"].getStr() == "/tmp/x.json"
    check withBaseline["baseline"]["changes"].len == 0

# --- --format=junit ---------------------------------------------------------

suite "--format=junit":
  test "parses as XML, and its counts agree with the text summary":
    let r = readiness(bus("100k"), offlineCapabilities)  # rc_corner fails
    let text = renderJunit(r)
    let xml = parseXml(text)
    check xml.tag == "testsuite"
    check xml.attr("tests") == $(r.results.len + r.structural.len)
    check xml.attr("failures") == $(count(r.results, esFail) +
      (block:
        var errs = 0
        for i in r.structural:
          if i.severity == sevError: inc errs
        errs))
    check xml.attr("skipped") == $(count(r.results, esNotEvaluated) +
                                   count(r.results, esNotEvaluable))
    var cases = 0
    for c in xml.findAll("testcase"): inc cases
    check cases == r.results.len + r.structural.len

  test "a failure carries the comparison as its message":
    let r = readiness(bus("100k"), offlineCapabilities)
    let xml = parseXml(renderJunit(r))
    var sawFailure = false
    for c in xml.findAll("testcase"):
      for f in c.findAll("failure"):
        sawFailure = true
        check "expect" in f.attr("message")
    check sawFailure

  test "text containing XML-hostile characters is escaped, not corrupted":
    var d = bus("2.2k")
    d.assertThat mkAssertion("z_ripple", @[net("vdd")], expectMax(10.mV), "V",
                            id = "REQ-<A&B>")
    let text = renderJunit(readiness(d, offlineCapabilities))
    check "<A&B>" notin text
    discard parseXml(text)  # raises on malformed XML

# --- --baseline --------------------------------------------------------

suite "baseline diff":
  test "a moved measurement is detected":
    var baseline = initTable[string, BaselineEntry]()
    baseline["i2c0.sda.rc_corner"] = BaselineEntry(value: 1.0e6, unit: "Hz",
                                                    status: "pass")
    let changes = baselineDiff(readiness(bus("2.2k"), offlineCapabilities), baseline)
    var found = false
    for c in changes:
      if c.id == "i2c0.sda.rc_corner":
        found = true
        check c.valueChanged
        check not c.isNew
        check not c.isGone
    check found

  test "a pass -> fail transition is flagged as a regression":
    var baseline = initTable[string, BaselineEntry]()
    baseline["i2c0.sda.rc_corner"] = BaselineEntry(value: 10.0e6, unit: "Hz",
                                                    status: "pass")
    let changes = baselineDiff(readiness(bus("100k"), offlineCapabilities), baseline)
    var found = false
    for c in changes:
      if c.id == "i2c0.sda.rc_corner":
        found = true
        check c.statusChanged
        check c.regressed
        check c.toStatus == "fail"
    check found

  test "a claim new since the baseline is reported as new, not as moved":
    let r = readiness(bus("2.2k"), offlineCapabilities)
    let changes = baselineDiff(r, initTable[string, BaselineEntry]())
    check changes.len == r.results.len
    for c in changes:
      check c.isNew
      check not c.valueChanged

  test "a claim gone since the baseline is reported":
    var baseline = initTable[string, BaselineEntry]()
    baseline["ghost.claim"] = BaselineEntry(value: 1.0, unit: "", status: "pass")
    let changes = baselineDiff(readiness(claimingNothing(), offlineCapabilities),
                               baseline)
    check changes.len == 1
    check changes[0].isGone
    check changes[0].id == "ghost.claim"

  test "an unparseable baseline is a usage error, not a silent skip":
    let path = getTempDir() / "verax_test_bad_baseline.json"
    writeFile(path, "not json at all {{{")
    expect BaselineError:
      discard loadBaseline(path)
    removeFile(path)

  test "a missing baseline file is a usage error":
    expect BaselineError:
      discard loadBaseline(getTempDir() / "verax_test_missing_baseline_xyz.json")

  test "a baseline JSON with no 'results' array is refused by name":
    let path = getTempDir() / "verax_test_not_a_report.json"
    writeFile(path, """{"hello": "world"}""")
    expect BaselineError:
      discard loadBaseline(path)
    removeFile(path)

  test "round-tripping a report through renderJson finds nothing moved":
    let r = readiness(bus("2.2k"), offlineCapabilities)
    let path = getTempDir() / "verax_test_roundtrip_baseline.json"
    writeFile(path, renderJson(r))
    check baselineDiff(r, loadBaseline(path)).len == 0
    removeFile(path)
