import std/[math, strutils, tables, unittest]

import verax/contract/dsl
import verax/contract/evaluate
import verax/contract/evaluators/static
import verax/netlist/interfaces

# --- fixtures -----------------------------------------------------------

proc i2cBoard(pullup: string): Design =
  ## A 3V3 board with an I2C bus pulled up through two resistors of `pullup`.
  design("board"):
    net vdd, kind = ntPower:
      spec:
        voltage = 3.3.V
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
                controller = U1, frequency = 400.kHz

proc resultFor(rs: seq[AssertionResult], id: string): AssertionResult =
  for r in rs:
    if r.assertion.id == id: return r
  raise newException(KeyError, "no result for " & id & "; got " &
    (block:
      var ids: seq[string]
      for r in rs: ids.add r.assertion.id
      ids.join(", ")))

# --- the static evaluators ---------------------------------------------

test "pull-up presence is answered from the graph, with no simulator":
  let rs = evaluate(i2cBoard("2200"))
  check resultFor(rs, "i2c0.sda.pullup").status == esPass
  check resultFor(rs, "i2c0.sda.pullup").value == 1.0
  check resultFor(rs, "i2c0.scl.pullup").status == esPass

test "a bus with no pull-up at all fails the claim rather than skipping it":
  let d = design("bare"):
    net vdd, kind = ntPower
    net sda, kind = ntSignal
    net scl, kind = ntSignal
    component U1, kind = "mcu":
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
    role "i2c", i2c0, sda = sda, scl = scl
  let rs = evaluate(d)
  check resultFor(rs, "i2c0.sda.pullup").status == esFail
  check "measured 0" in resultFor(rs, "i2c0.sda.pullup").reason

test "the RC corner is measured, and a marginal bus is reported as failing":
  # 2.2k against two assumed pin capacitances puts the corner at ~3.6 MHz,
  # below the 10x clock a 400 kHz role asks for.
  let rs = evaluate(i2cBoard("2200"))
  let r = resultFor(rs, "i2c0.sda.rc_corner")
  check r.status == esFail
  check abs(r.value - 3.617e6) < 1.0e4
  check r.unit == "Hz"

  # The same bus pulled up harder clears it.
  let ok = resultFor(evaluate(i2cBoard("1000")), "i2c0.sda.rc_corner")
  check ok.status == esPass
  check ok.value > 4.0e6

test "a verdict that rests on an invented number carries the assumption":
  let rs = evaluate(i2cBoard("1000"))
  let r = resultFor(rs, "i2c0.sda.rc_corner")
  check r.assumptions.len == 1
  check r.assumptions[0].key == "bus_capacitance"
  check r.assumptions[0].source == annDefaulted
  # It also surfaces through the whole-run filter.
  check invented(rs).len >= 1

test "an RKM value is refused rather than read as either of its two meanings":
  # ngspice reads "2k2" as 2000 and `value` reaches the deck verbatim, so the
  # static check must agree.
  let r = resultFor(evaluate(i2cBoard("2k2")), "i2c0.sda.rc_corner")
  check r.status == esNotEvaluable
  check "2000" in r.reason and "2200" in r.reason

test "controller count comes from the role binding, since topology cannot say":
  let rs = evaluate(i2cBoard("1000"))
  let r = resultFor(rs, "i2c0.controllers")
  check r.status == esPass
  check r.value == 1.0

test "two roles naming different controllers on one bus is caught":
  let d = design("two"):
    net sda, kind = ntSignal
    net scl, kind = ntSignal
    component U1, kind = "mcu":
      pin "SDA", sda, kind = ptInOut
    component U2, kind = "mcu":
      pin "SDA", sda, kind = ptInOut
    role "i2c", busA, sda = sda, scl = scl, controller = U1
    role "i2c", busB, sda = sda, scl = scl, controller = U2
  let rs = evaluate(d)
  check resultFor(rs, "busA.controllers").status == esFail
  check resultFor(rs, "busA.controllers").value == 2.0

test "with no controller bound the answer is 'cannot know', not a guess":
  let d = design("nocontroller"):
    net sda, kind = ntSignal
    net scl, kind = ntSignal
    component U1, kind = "mcu":
      pin "SDA", sda, kind = ptInOut
    role "i2c", i2c0, sda = sda, scl = scl
  let r = resultFor(evaluate(d), "i2c0.controllers")
  check r.status == esNotEvaluable
  check "cannot be recovered from topology" in r.reason

test "with no role on the net at all, the reason explains why topology cannot say":
  let d = design("norole"):
    net sda, kind = ntSignal
    component U1, kind = "mcu":
      pin "SDA", sda, kind = ptInOut
    require controller_count(sda) == 1.0, id = "C"
  let r = resultFor(evaluate(d), "C")
  check r.status == esNotEvaluable
  check "inout" in r.reason

# --- the static evaluators see through hierarchy ------------------------
#
# A bus declared at the top whose pull-up sits inside a child subckt: the
# resistor's pin is on the inner net, linked by `Pin.hierNet`. `allPins`
# must reach it.

proc pullupBlock(): Netlist =
  ## A one-resistor pull-up subckt, port `SDA` the only way in or out.
  subckt("PULLUP", [SDA]):
    net SDA, kind = ntSignal
    net vdd, kind = ntPower:
      spec:
        voltage = 3.3.V
    component R1, kind = "resistor", value = "2200":
      pin "1", vdd, kind = ptPassive
      pin "2", SDA, kind = ptPassive

proc pullupBlockOuter(): Netlist =
  ## `pullupBlock` one level further down, behind a second pass-through port.
  subckt("PULLUP_OUTER", [SDA]):
    net SDA, kind = ntSignal
    instance XI, pullupBlock(), [SDA]

test "a pull-up nested one level inside an instance is seen through its pass-through port":
  let d = design("nested_pullup"):
    net sda, kind = ntSignal
    instance XA, pullupBlock(), [sda]
    require pullup_count(sda) == 1.0, id = "PU"
  let r = resultFor(evaluate(d), "PU")
  check r.status == esPass
  check r.value == 1.0

test "a bus fanned into two sibling instances, each with its own pull-up, counts both":
  # Two instances' `R1`s are distinct components with the same designator;
  # de-dup is by component identity, so both count.
  let d = design("fanout_pullup"):
    net sda, kind = ntSignal
    instance XA, pullupBlock(), [sda]
    instance XB, pullupBlock(), [sda]
    require pullup_count(sda) == 2.0, id = "PU"
  let r = resultFor(evaluate(d), "PU")
  check r.status == esPass
  check r.value == 2.0

test "a pull-up reached two hierarchy levels deep is found by the transitive closure":
  let d = design("nested_two_deep"):
    net sda, kind = ntSignal
    instance XO, pullupBlockOuter(), [sda]
    require pullup_count(sda) == 1.0, id = "PU"
  let r = resultFor(evaluate(d), "PU")
  check r.status == esPass
  check r.value == 1.0

test "rc_corner: the same bus authored flat or nested agrees to within the crossing's own assumed load":
  # Not byte-identical: `hierNetGroup` includes the instance's boundary pin,
  # so the nested bus capacitance is one `assumedPinCapacitance` heavier
  # (`spice/flatten` would dissolve it; this evaluator never flattens). The
  # corners differ by ~1e-4 relative; a wrong pin count would shift it far
  # more.
  proc pullupCapFlat(): Design =
    design("flat_pullup_cap"):
      net vdd, kind = ntPower:
        spec:
          voltage = 3.3.V
      net gnd, kind = ntGround, name = "0"
      net sda, kind = ntSignal
      component R1, kind = "resistor", value = "2200":
        pin "1", vdd, kind = ptPassive
        pin "2", sda, kind = ptPassive
      component C1, kind = "capacitor", value = "100n":
        pin "1", sda, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      require rc_corner(sda) >= 0.0.Hz, id = "RC"

  proc pullupCapBlock(): Netlist =
    subckt("PULLUP_CAP", [SDA]):
      net SDA, kind = ntSignal
      net vdd, kind = ntPower:
        spec:
          voltage = 3.3.V
      net gnd, kind = ntGround, name = "0"
      component R1, kind = "resistor", value = "2200":
        pin "1", vdd, kind = ptPassive
        pin "2", SDA, kind = ptPassive
      component C1, kind = "capacitor", value = "100n":
        pin "1", SDA, kind = ptPassive
        pin "2", gnd, kind = ptPassive

  proc pullupCapNested(): Design =
    design("nested_pullup_cap"):
      net sda, kind = ntSignal
      instance XA, pullupCapBlock(), [sda]
      require rc_corner(sda) >= 0.0.Hz, id = "RC"

  let flat = resultFor(evaluate(pullupCapFlat()), "RC")
  let nested = resultFor(evaluate(pullupCapNested()), "RC")
  check flat.status == esPass
  check nested.status == esPass
  check abs(flat.value - 723.2869021281895) < 1.0e-4
  check abs(nested.value - 723.2145951300761) < 1.0e-4
  check abs(flat.value - nested.value) / flat.value < 2.0e-4

let controllerIfaceDef = block:
  ## A single-signal interface def, for `runControllerCount`'s
  ## interface-metadata path (the other source besides role bindings).
  var def: InterfaceDef
  def.name = "test_ctrl_iface"
  def.signals = @[SignalDef(name: "sda", width: 1)]
  var m: Modport
  m.name = "controller"
  m.controller = true
  m.dirs["sda"] = ptInOut
  def.modports[m.name] = m
  registerInterfaceDef(def)
  def

proc controllerBlock(): Netlist =
  subckt("CTRL_BLOCK", [SDA]):
    net SDA, kind = ntSignal
    component U1, kind = "mcu":
      pin "SDA", SDA, kind = ptInOut

test "controller_count's interface fallback finds a controller reached through a pass-through port":
  # `iface.def` is on the outer net; `iface.modport` is on the pin one level
  # down inside `XA`.
  let d = design("nested_controller"):
    net sda, kind = ntSignal
    instance XA, controllerBlock(), [sda]
    require controller_count(sda) == 1.0, id = "CC"
  d.netlist.nets["sda"].attrs["iface.def"] = controllerIfaceDef.name
  d.netlist.children["XA"].components["U1"].pins["SDA"].attrs["iface.modport"] = "controller"
  let r = resultFor(evaluate(d), "CC")
  check r.status == esPass
  check r.value == 1.0

# --- the four statuses, each reached deliberately ------------------------

proc runFixed(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  ## A user-defined evaluator registered from a test file.
  for a in batch:
    if a.quantity == "test_nan":
      result.add verdict(a, NaN, "V", "test.fixed")
    elif a.quantity == "test_wrong_unit":
      result.add verdict(a, 1.0, "Hz", "test.fixed")
    else:
      result.add verdict(a, 42.0, "V", "test.fixed")

proc fixedKey(ctx: EvalContext, a: Assertion): string =
  ## Everything this evaluator answers shares one setup.
  "shared"

registerEvaluator(Evaluator(
  name: "test.fixed",
  produces: @["test_value", "test_nan", "test_wrong_unit"],
  needs: {capStatic},
  arity: 1 .. 1,
  subjectKinds: {skNet},
  setupKey: fixedKey,
  run: runFixed))

# --- a two-subject quantity ---------------------------------------------

proc runPair(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  for a in batch: result.add verdict(a, 1.0, "V", "test.pair")

registerEvaluator(Evaluator(
  name: "test.pair",
  produces: @["test_pair"],
  needs: {capStatic},
  arity: 2 .. 2,
  subjectKinds: {skNet},
  run: runPair))          # no setupKey, so `defaultKey` joins both names

test "a two-subject assertion routes to an arity 2..2 evaluator and runs":
  let d = design("pairs"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    require test_pair(a, b) <= 2.0.V, id = "OK"
  let r = resultFor(evaluate(d), "OK")
  check r.status == esPass
  check r.evaluator == "test.pair"

test "a one- or three-subject claim on a two-subject quantity is rejected with the arity message":
  let d1 = design("one"):
    net a, kind = ntSignal
    require test_pair(a) <= 2.0.V, id = "ONE"
  let r1 = resultFor(evaluate(d1), "ONE")
  check r1.status == esNotEvaluable
  check "takes 2..2 subjects" in r1.reason
  check "got 1" in r1.reason

  let d3 = design("three"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    net c, kind = ntSignal
    require test_pair(a, b, c) <= 2.0.V, id = "THREE"
  let r3 = resultFor(evaluate(d3), "THREE")
  check r3.status == esNotEvaluable
  check "got 3" in r3.reason

test "defaultKey groups a two-subject claim by both subject names":
  let d = design("grp"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    net c, kind = ntSignal
    require test_pair(a, b) <= 1.0.V, id = "AB1"
    require test_pair(a, b) >= 0.0.V, id = "AB2"
    require test_pair(a, c) <= 1.0.V, id = "AC"
  let p = plan(d)
  var steps = 0
  for s in p.steps:
    if s.evaluator == "test.pair": inc steps
  # {a,b} answers two claims in one step; {a,c} is a different pair.
  check steps == 2

proc statusBoard(): Design =
  design("statuses"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    require test_value(a) == 42.0.V, id = "PASS"
    require test_value(b) == 1.0.V, id = "FAIL"
    require test_nan(a) == 42.0.V, id = "NAN"
    require test_wrong_unit(a) == 42.0.V, id = "UNIT"
    require nothing_produces_this(a) >= 1.0, id = "UNKNOWN"

test "a user-defined evaluator takes the identical path to a built-in":
  check "test.fixed" in registeredEvaluators()
  check isEvaluable("test_value")
  check resultFor(evaluate(statusBoard()), "PASS").evaluator == "test.fixed"

test "pass and fail are distinguished, and a fail carries its witness":
  let rs = evaluate(statusBoard())
  check resultFor(rs, "PASS").status == esPass
  let f = resultFor(rs, "FAIL")
  check f.status == esFail
  check "42" in f.reason      # what was measured
  check "1" in f.reason       # what was expected

test "a NaN measurement is not evaluated, rather than failed":
  # "never found in the range" and "the design is wrong" are different
  # claims.
  let r = resultFor(evaluate(statusBoard()), "NAN")
  check r.status == esNotEvaluated
  check r.value.isNaN

test "a unit mismatch declines to compare rather than comparing silently":
  let r = resultFor(evaluate(statusBoard()), "UNIT")
  check r.status == esNotEvaluable
  check "unit mismatch" in r.reason

test "a quantity nothing produces is not evaluable, and says so":
  let r = resultFor(evaluate(statusBoard()), "UNKNOWN")
  check r.status == esNotEvaluable
  check "no evaluator produces" in r.reason

test "an evaluator whose capability was not offered is not *evaluated*":
  # Nothing is wrong with the claim; offering the capability would answer it.
  let d = design("needs_sim"):
    net a, kind = ntSignal
    require test_value(a) == 42.0.V, id = "X"
  let rs = evaluate(d, {capSpiceOp})   # capStatic deliberately withheld
  check resultFor(rs, "X").status == esNotEvaluated
  # Named by the label a designer reads, via `capLabel`.
  check "the static capability" in resultFor(rs, "X").reason

# --- relative and predicate expectations ------------------------------

proc runRel(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  for a in batch:
    case a.quantity
    of "rel_a": result.add verdict(a, 10.0, "V", "test.rel")
    of "rel_b": result.add verdict(a, 100.0, "V", "test.rel")
    else: result.add notEvaluable(a, "test.rel", "no such quantity")

proc relKey(ctx: EvalContext, a: Assertion): string = "shared"

registerEvaluator(Evaluator(
  name: "test.rel",
  produces: @["rel_a", "rel_b"],
  needs: {capStatic},
  arity: 1 .. 1,
  subjectKinds: {skNet},
  setupKey: relKey,
  run: runRel))

proc runPerNet(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  for a in batch: result.add verdict(a, 7.0, "V", "test.pernet")

registerEvaluator(Evaluator(
  name: "test.pernet",
  produces: @["pn_q"],
  needs: {capStatic},
  arity: 1 .. 1,
  subjectKinds: {skNet},
  run: runPerNet))   # no setupKey: `defaultKey` groups by subject name

test "a relative bound compares the two measurements, both ways":
  let d = design("rel"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    require rel_a(a) <= 0.5 * rel_b(b), id = "LE"   # 10 <= 50
    require rel_a(a) >= 0.5 * rel_b(b), id = "GE"   # 10 >= 50 is false
    require rel_a(a) == 0.1 * rel_b(b), band = 5.pct, id = "EQ"  # 10 == 10
  let rs = evaluate(d)
  check resultFor(rs, "LE").status == esPass
  let ge = resultFor(rs, "GE")
  check ge.status == esFail
  check "expected >=" in ge.reason
  check resultFor(rs, "EQ").status == esPass
  # The claim carries the left-hand value, not the reference's.
  check abs(resultFor(rs, "LE").value - 10.0) < 1e-12
  check resultFor(rs, "LE").unit == "V"

test "a relative bound whose reference cannot be made reports the reference":
  let d = design("relbad"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    require rel_a(a) <= 0.5 * nothing_here(b), id = "NOPROD"
    require rel_a(a) <= 0.5 * test_nan(b), id = "NAN"
    require rel_a(a) <= 0.5 * test_wrong_unit(b), id = "UNIT"
  let rs = evaluate(d)
  check resultFor(rs, "NOPROD").status == esNotEvaluable
  check "reference measurement" in resultFor(rs, "NOPROD").reason
  check "no evaluator produces" in resultFor(rs, "NOPROD").reason
  check resultFor(rs, "NAN").status == esNotEvaluated
  let unit = resultFor(rs, "UNIT")
  check unit.status == esNotEvaluable
  check "unit mismatch" in unit.reason
  check "V" in unit.reason and "Hz" in unit.reason

test "a predicate runs its proc over the dependency values in order":
  let d = design("pred"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    require pred(x = rel_a(a), y = rel_b(b), id = "P") do (x, y: float) -> bool:
      x < y
  let r = resultFor(evaluate(d), "P")
  check r.status == esPass
  check "predicate held" in r.reason
  # The values it judged, named, so a verdict says how far off it was.
  checkpoint r.reason
  check "x = 10" in r.reason and "y = 100" in r.reason

test "a failing predicate shows the values it judged":
  let d = design("predfail"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    require pred(x = rel_a(a), y = rel_b(b), id = "P") do (x, y: float) -> bool:
      x > y
  let r = resultFor(evaluate(d), "P")
  check r.status == esFail
  checkpoint r.reason
  check "predicate did not hold" in r.reason
  check "x = 10" in r.reason and "y = 100" in r.reason

test "a predicate whose dependency cannot be made names that dependency":
  let d = design("predbad"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    require pred(x = rel_a(a), y = nothing_here(b), id = "P") do (x, y: float) -> bool:
      x < y
  let r = resultFor(evaluate(d), "P")
  check r.status == esNotEvaluable
  check "dependency 'y'" in r.reason

test "a relative claim's two measurements may live in different setups":
  let d = design("cross"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    require pn_q(a) <= 0.5 * pn_q(b), id = "CROSS"
  # defaultKey groups by subject name, so the two sides are two runs.
  var steps = 0
  for s in plan(d).steps:
    if s.evaluator == "test.pernet": inc steps
  check steps == 2
  # ...and still fold into exactly one user-visible result.
  let rs = evaluate(d)
  check rs.len == 1
  check rs[0].assertion.id == "CROSS"
  check rs[0].status == esFail          # 7 <= 3.5 is false

test "relative and predicate claims are one result each, never one per request":
  let d = design("mix"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    require rel_a(a) <= 0.5 * rel_b(b), id = "R"
    require pred(x = rel_a(a), y = rel_b(b), id = "P") do (x, y: float) -> bool:
      x < y
    require test_value(a) == 42.0.V, id = "PLAIN"
  let rs = evaluate(d)
  check rs.len == d.expandAll().len
  check rs.len == 3

# --- planning ------------------------------------------------------------

test "assertions sharing a setup are grouped into a single step":
  let p = plan(statusBoard())
  # Three quantities on two nets key to "shared": one run. The two
  # unroutable ones never reach a step.
  check p.steps.len == 1
  check p.steps[0].assertions.len == 4
  check p.rejected.len == 1

test "distinct setups get distinct steps":
  # The default key is the subject name, so two nets are two runs.
  let p = plan(i2cBoard("1000"))
  var pullupSteps = 0
  for s in p.steps:
    if s.evaluator == "static.pullup_count": inc pullupSteps
  check pullupSteps == 2

test "a plan is printable before anything runs":
  let text = explainPlan(plan(statusBoard()))
  check "test.fixed" in text
  # The rendered label, not the enum identifier.
  check "[static]" in text
  check "capStatic" notin text
  check "UNKNOWN" in text

test "planning is pure -- it neither simulates nor touches the design":
  let d = i2cBoard("1000")
  let before = d.netlist.components.len
  discard plan(d, allCapabilities)
  check d.netlist.components.len == before

# --- reading the results -------------------------------------------------

test "a run is summarised, and what went unchecked is visible":
  let rs = evaluate(statusBoard())
  check count(rs, esPass) == 1
  check count(rs, esFail) == 1
  check unchecked(rs).len == 3
  check "1 passed" in summary(rs)
  check failed(rs).len == 1

test "the worst severity reported reflects only actual failures":
  let rs = evaluate(statusBoard())
  check worstSeverity(rs) == sevError

test "every assertion in the design produces exactly one result":
  let d = i2cBoard("1000")
  check evaluate(d).len == d.expandAll().len

# --- declining to answer still carries the diagnosis -------------------

proc probe(quantity, unit: string): Assertion =
  Assertion(id: "a", subjects: @[Subject(kind: skNet, name: "n")],
            quantity: quantity, expect: atLeast(1.0), unit: unit,
            severity: sevError, rationale: "why")

test "a NaN verdict carries the analysis's issues and assumptions":
  # The analysis's Issue carries the diagnosis `verdict` can't know; it must
  # survive.
  let notes = @[note("stood in for something")]
  let issues = @[newIssue("test_why", sevWarning, "the loop never opened")]
  let r = verdict(probe("bw_3db", "Hz"), NaN, "Hz", "test.fixed", notes, issues)
  check r.status == esNotEvaluated
  check r.issues.len == 1
  check r.issues[0].kind == "test_why"
  check r.assumptions.len == 1

test "a unit-mismatch verdict carries them too":
  let notes = @[note("stood in for something")]
  let issues = @[newIssue("test_why", sevWarning, "the loop never opened")]
  let r = verdict(probe("bw_3db", "V"), 1.0, "Hz", "test.fixed", notes, issues)
  check r.status == esNotEvaluable
  check r.issues.len == 1
  check r.assumptions.len == 1

test "a passing verdict still carries them, unchanged":
  let notes = @[note("stood in for something")]
  let issues = @[newIssue("test_why", sevWarning, "worth knowing")]
  let r = verdict(probe("bw_3db", "Hz"), 5.0, "Hz", "test.fixed", notes, issues)
  check r.status == esPass
  check r.issues.len == 1
  check r.assumptions.len == 1

# --- the pull-up floor, which rc_corner does not provide ---------------

test "pullup_sink_current is what a target has to sink to pull the line low":
  # (3.3 - 0.4) / 1200 = 2.417 mA. 0.4 V is the spec's VOL.
  let r = resultFor(evaluate(i2cBoard("1.2k")), "i2c0.sda.sink_current")
  check r.status == esPass
  check abs(r.value - 2.417e-3) / 2.417e-3 < 0.01

test "a pull-up too strong for the bus to sink is caught":
  # The bound rc_corner doesn't give; the two squeeze from opposite sides.
  let r = resultFor(evaluate(i2cBoard("680")), "i2c0.sda.sink_current")
  check r.status == esFail
  check abs(r.value - 4.265e-3) / 4.265e-3 < 0.01

test "a weak pull-up passes the sink check and fails the RC one":
  # Hence both.
  let rs = evaluate(i2cBoard("10k"))
  check resultFor(rs, "i2c0.sda.sink_current").status == esPass
  check resultFor(rs, "i2c0.sda.rc_corner").status == esFail

test "the sink current is declined, not guessed, without a rail voltage":
  let d = design("b"):
    net vdd, kind = ntPower           # no voltage stated
    net gnd, kind = ntGround, name = "0"
    net sda, kind = ntSignal
    net scl, kind = ntSignal
    component R1, kind = "resistor", value = "1.2k":
      pin "1", vdd, kind = ptPassive
      pin "2", sda, kind = ptPassive
    component R2, kind = "resistor", value = "1.2k":
      pin "1", vdd, kind = ptPassive
      pin "2", scl, kind = ptPassive
    role "i2c", i2c0, sda = sda, scl = scl, frequency = 100.kHz
  let r = resultFor(evaluate(d), "i2c0.sda.sink_current")
  check r.status == esNotEvaluable
  check "voltage" in r.reason

# --- describing a run, and running it in batches -------------------------

proc raisingDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  raise newException(ValueError, "a third-party evaluator misbehaving")

registerEvaluator(Evaluator(
  name: "test.described", produces: @["test_described"], needs: {capStatic},
  arity: 1 .. 1, subjectKinds: {skNet}, setupKey: fixedKey,
  setupDoc: proc (ctx: EvalContext, batch: seq[Assertion]): string {.nimcall.} =
    "a made-up walk over " & $batch.len & " claim(s)",
  run: runFixed))

registerEvaluator(Evaluator(
  name: "test.badDoc", produces: @["test_bad_doc"], needs: {capStatic},
  arity: 1 .. 1, subjectKinds: {skNet}, setupKey: fixedKey,
  setupDoc: raisingDoc, run: runFixed))

test "an evaluator says in words what its run is":
  let d = design("described"):
    net a, kind = ntSignal
    require test_described(a) == 42.0.V, id = "D"
  let p = plan(d, {capStatic})
  check describeStep(d, p.steps[0]) == "a made-up walk over 1 claim(s)"

test "an evaluator that describes nothing falls back to its setup key":
  # Nothing here knows what the key's fields mean, so the run is opaque.
  let d = design("undescribed"):
    net a, kind = ntSignal
    require test_value(a) == 42.0.V, id = "U"
  let p = plan(d, {capStatic})
  check describeStep(d, p.steps[0]) == "setup shared"

test "a description that raises does not take down the report":
  # As with `previewRole`: one broken evaluator mustn't make the run
  # unreadable.
  let d = design("bad"):
    net a, kind = ntSignal
    require test_bad_doc(a) == 42.0.V, id = "B"
  let p = plan(d, {capStatic})
  check describeStep(d, p.steps[0]) == "setup shared"

test "running the plan keeps the batches the planner grouped":
  let d = statusBoard()
  let p = plan(d, {capStatic})
  let batches = runPlan(d, p)
  check batches.len == p.steps.len
  for i, b in batches:
    check b.len == p.steps[i].assertions.len
  # Flattening it is exactly what `evaluate` returns.
  var flat: seq[AssertionResult]
  for b in batches: flat.add b
  for r in rejectionResults(p): flat.add r
  let direct = evaluate(d, {capStatic})
  check flat.len == direct.len
  for i in 0 ..< flat.len:
    check flat[i].assertion.id == direct[i].assertion.id
    check flat[i].status == direct[i].status

# --- one quantity, one producer ---------------------------------------------

proc runDup(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  for a in batch: result.add verdict(a, 1.0, "V", "test.dup")

test "a second evaluator claiming an existing quantity raises":
  # A second registration would silently take over the quantity everywhere.
  # An override keeps the name; a collision is refused.
  var msg = ""
  try:
    registerEvaluator(Evaluator(
      name: "test.dup", produces: @["test_value"], needs: {capStatic},
      arity: 1 .. 1, subjectKinds: {skNet}, run: runDup))
  except NetlistError as e:
    msg = e.msg
  check "test_value" in msg
  check "test.fixed" in msg
  # And the original is still the producer.
  check evaluatorFor("test_value").get.name == "test.fixed"

test "re-registering under the same name is still an override":
  registerEvaluator(Evaluator(
    name: "test.overridable", produces: @["test_override_q"], needs: {capStatic},
    arity: 1 .. 1, subjectKinds: {skNet}, run: runDup))
  registerEvaluator(Evaluator(
    name: "test.overridable", produces: @["test_override_q"], needs: {capBench},
    arity: 1 .. 1, subjectKinds: {skNet}, run: runDup))
  check evaluatorFor("test_override_q").get.needs == {capBench}

# --- batch identity, including misbehaving plugins ----------------------

var batchMode: string
var seenBatch: seq[Assertion]

proc runIdentity(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  seenBatch = batch
  if batchMode == "raise": raise newException(ValueError, "broken batch")
  var answers: seq[AssertionResult]
  for i, a in batch:
    var r = verdict(a, float(i + 1), "V", "test.identity",
      @[note("retained assumption")],
      @[newIssue("original_issue", sevInfo, "retained issue")])
    # An evaluator may return an altered assertion, but owns no authored data.
    r.assertion.rationale = "plugin rewrite"
    answers.add r
  case batchMode
  of "duplicate": result = @[answers[0], answers[0]]
  of "reverse":
    for i in countdown(answers.high, 0): result.add answers[i]
  of "statuses":
    result = answers
    result[0].status = esFail
    result[0].reason = "plugin failure witness"
    result[1].status = esNotEvaluable
    result[1].value = NaN
    result[1].reason = "plugin refusal"
  of "empty": discard
  of "partial": result = @[answers[0]]
  of "foreign", "extra":
    var foreign = answers[0]
    foreign.assertion.id = "not-requested"
    if batchMode == "extra": result = answers
    else: result = @[answers[0]]
    result.add foreign
  else: result = answers

registerEvaluator(Evaluator(name: "test.identity", produces: @["identity_q"],
  needs: {capStatic}, setupKey: fixedKey, run: runIdentity))

proc identityClaims(ids: openArray[string]): seq[Assertion] =
  for id in ids:
    var a = probe("identity_q", "V")
    a.id = id
    result.add a

proc identityResults(ids: openArray[string], mode: string): seq[AssertionResult] =
  batchMode = mode
  let p = Plan(steps: @[PlanStep(evaluator: "test.identity",
    assertions: identityClaims(ids))])
  runPlan(newEvalContext(statusBoard()), p)[0]

test "equal-length duplicate answers cannot masquerade as a complete batch":
  let rs = identityResults(["A", "B"], "duplicate")
  check rs.len == 2
  check rs[0].assertion.id == "A"
  check rs[1].assertion.id == "B"
  for r in rs:
    check r.status == esNotEvaluated
    check r.value.isNaN
  check "duplicate" in rs[0].reason
  check "no result" in rs[1].reason

test "reordered answers retain payloads but restore requested assertions":
  let rs = identityResults(["A", "B"], "reverse")
  check rs.len == 2
  for i, r in rs:
    check r.assertion.id == ["A", "B"][i]
    check r.assertion.rationale == "why"
    check r.value == float(i + 1)
    check r.status == esPass
    check r.unit == "V"
    check r.evaluator == "test.identity"
    check "measured" in r.reason
    check r.assumptions.len == 1
    check r.issues.len == 1
    check r.issues[0].kind == "original_issue"

test "matched fail and declined statuses are preserved, not recomputed":
  let rs = identityResults(["A", "B"], "statuses")
  check rs[0].status == esFail
  check rs[0].value == 1.0
  check rs[0].reason == "plugin failure witness"
  check rs[1].status == esNotEvaluable
  check rs[1].value.isNaN
  check rs[1].reason == "plugin refusal"
  for r in rs:
    check r.assertion.rationale == "why"
    check r.assumptions.len == 1
    check r.issues.len == 1
    check r.issues[0].kind == "original_issue"

test "empty and partial batches account for every missing request":
  for mode in ["empty", "partial"]:
    let rs = identityResults(["A", "B"], mode)
    check rs.len == 2
    check rs[1].assertion.id == "B"
    check rs[1].status == esNotEvaluated
    check rs[1].value.isNaN
    check "no result" in rs[1].reason
    check rs[0].status == (if mode == "empty": esNotEvaluated else: esPass)

test "foreign and extra answers warn without poisoning valid matches":
  for mode in ["foreign", "extra"]:
    let rs = identityResults(["A", "B"], mode)
    check rs.len == 2
    check rs[0].status == esPass
    check rs[0].value == 1.0
    check rs[0].issues[0].kind == "original_issue"
    check rs[1].status == (if mode == "foreign": esNotEvaluated else: esPass)
    for r in rs:
      check r.assertion.id in ["A", "B"]
      check r.issues[^1].kind == "evaluator_foreign_result"
      check r.issues[^1].severity == sevWarning
      check "not-requested" in r.issues[^1].message

test "anonymous and mixed requests get collision-free temporary identities":
  for ids in [@["", ""], @["", "\x1fcontract-anon\x1f0", "", "A"]]:
    let rs = identityResults(ids, "reverse")
    check rs.len == ids.len
    for i, r in rs:
      check r.assertion.id == ids[i]
      check r.assertion.rationale == "why"
      check r.value == float(i + 1)
      check seenBatch[i].id.len > 0
      for j in 0 ..< i: check seenBatch[i].id != seenBatch[j].id
    let partial = identityResults(ids, "partial")
    check partial[0].status == esPass
    for i in 1 ..< ids.len:
      check partial[i].status == esNotEvaluated
      check partial[i].assertion.id == ids[i]

test "duplicate authored request IDs are ambiguous even with one answer":
  for mode in ["normal", "partial"]:
    let rs = identityResults(["A", "A", "B"], mode)
    check rs.len == 3
    for i in 0 .. 1:
      check rs[i].status == esNotEvaluated
      check rs[i].value.isNaN
      check "duplicate request" in rs[i].reason
    if mode == "normal": check rs[2].status == esPass

test "a raising batch is contained and restores anonymous requests too":
  batchMode = "raise"
  let p = Plan(steps: @[
    PlanStep(evaluator: "test.identity", assertions: identityClaims(["", "B"])),
    PlanStep(evaluator: "test.fixed", assertions: @[probe("test_value", "V")])])
  let rs = runPlan(newEvalContext(statusBoard()), p)
  check rs.len == 2
  check rs[0].len == 2
  check rs[0][0].assertion.id == ""
  for r in rs[0]:
    check r.status == esNotEvaluated
    check r.value.isNaN
    check "broken batch" in r.reason
  check rs[1][0].status == esPass

test "reconciliation preserves hidden dependency folding and capability gates":
  let d = design("identity_deps"):
    net a, kind = ntSignal
    require identity_q(a) <= 2.0 * identity_q(a), id = "REL"
    require pred(x = identity_q(a), y = identity_q(a), id = "PRED") do (x, y: float) -> bool:
      x < y
  batchMode = "reverse"
  let rs = evaluate(d)
  check rs.len == 2
  check rs[0].assertion.id == "REL"
  check rs[1].assertion.id == "PRED"
  for r in rs: check r.status == esPass
  batchMode = "duplicate"
  let bad = evaluate(d)
  check bad.len == 2
  for r in bad: check r.status == esNotEvaluated
  seenBatch = @[]
  let gated = evaluate(d, {capSpiceAc})
  check seenBatch.len == 0
  check gated.len == 2
  for r in gated: check r.status == esNotEvaluated
