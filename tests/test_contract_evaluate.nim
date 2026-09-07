import std/[math, strutils, tables, unittest]

import verax/contract/dsl
import verax/contract/evaluate
import verax/contract/evaluators/static

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
  # 2.2k against two pins of assumed capacitance puts the corner at ~3.6 MHz,
  # below the ten-times-clock the 400 kHz role asks for.
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
  # And it surfaces through the whole-run filter, which is the question
  # "how much of this answer did we make up?"
  check invented(rs).len >= 1

test "an RKM value is refused rather than read as either of its two meanings":
  # ngspice reads "2k2" as 2000, an EDA tool means 2200. Since `value` is
  # passed to the deck verbatim, a static check that quietly picked 2200 would
  # disagree with the simulation about the same part.
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

# --- the four statuses, each reached deliberately ------------------------

proc runFixed(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  ## A user-defined evaluator, registered from a test file through the
  ## ordinary path, exactly as `test_contract_roles.nim` does for roles.
  for a in batch:
    if a.quantity == "test_nan":
      result.add verdict(a, NaN, "V", "test.fixed")
    elif a.quantity == "test_wrong_unit":
      result.add verdict(a, 1.0, "Hz", "test.fixed")
    else:
      result.add verdict(a, 42.0, "V", "test.fixed")

proc fixedKey(ctx: EvalContext, a: Assertion): string =
  ## Everything this evaluator answers shares one setup, so one step should
  ## carry every assertion routed to it.
  "shared"

registerEvaluator(Evaluator(
  name: "test.fixed",
  produces: @["test_value", "test_nan", "test_wrong_unit"],
  needs: {capStatic},
  arity: 1 .. 1,
  subjectKinds: {skNet},
  setupKey: fixedKey,
  run: runFixed))

# --- a two-subject quantity, the §53 plumbing ------------------------

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
  # "the quantity was never found in the range analysed" and "this design is
  # wrong" are different claims, and only one of them is supported.
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
  # The distinction that matters: nothing is wrong with the claim, and
  # offering the capability would answer it.
  let d = design("needs_sim"):
    net a, kind = ntSignal
    require test_value(a) == 42.0.V, id = "X"
  let rs = evaluate(d, {capSpiceOp})   # capStatic deliberately withheld
  check resultFor(rs, "X").status == esNotEvaluated
  # Named by the label a designer reads (`static`, `.op`), not by the enum
  # identifier -- the two must not drift, which is why `capLabel` is one proc.
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
  # Three quantities across two nets all key to "shared", so one run answers
  # them; the two unroutable ones never reach a step at all.
  check p.steps.len == 1
  check p.steps[0].assertions.len == 4
  check p.rejected.len == 1

test "distinct setups get distinct steps":
  # The default key is the subject name, so the two nets do not share a run.
  let p = plan(i2cBoard("1000"))
  var pullupSteps = 0
  for s in p.steps:
    if s.evaluator == "static.pullup_count": inc pullupSteps
  check pullupSteps == 2

test "a plan is printable before anything runs":
  let text = explainPlan(plan(statusBoard()))
  check "test.fixed" in text
  # The rendered label, not the enum identifier: `capLabel` exists so one
  # capability never appears under two names, and `$capStatic` is right in a
  # stack trace and wrong in a line a designer reads.
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
  # `reason` is written by `verdict` and cannot name a cause `verdict` does
  # not know. The analysis that produced the NaN usually does know and says
  # so in an Issue -- dropping it strands the diagnosis and leaves the
  # reader with a generic sentence pointing at the wrong thing.
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
  # (3.3 - 0.4) / 1200 = 2.417 mA. The 0.4 V is the specification's VOL,
  # not a design choice, which is why it is not a parameter.
  let r = resultFor(evaluate(i2cBoard("1.2k")), "i2c0.sda.sink_current")
  check r.status == esPass
  check abs(r.value - 2.417e-3) / 2.417e-3 < 0.01

test "a pull-up too strong for the bus to sink is caught":
  # The bound rc_corner does not give. Both limits squeeze from opposite
  # sides, and a design pushed off one by fixing the other had no way to
  # find out.
  let r = resultFor(evaluate(i2cBoard("680")), "i2c0.sda.sink_current")
  check r.status == esFail
  check abs(r.value - 4.265e-3) / 4.265e-3 < 0.01

test "a weak pull-up passes the sink check and fails the RC one":
  # Which is the point of having both.
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
  # Honest rather than helpful: out here nothing knows what the key's fields
  # mean, so a guess would be worse than saying the run is opaque.
  let d = design("undescribed"):
    net a, kind = ntSignal
    require test_value(a) == 42.0.V, id = "U"
  let p = plan(d, {capStatic})
  check describeStep(d, p.steps[0]) == "setup shared"

test "a description that raises does not take down the report":
  # The same rule `previewRole` applies to a bad role expander: one broken
  # third-party evaluator must not make the run unreadable.
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
  # And flattening it is exactly what `evaluate` returns, so nothing that
  # reads a whole run has to know the grouping exists.
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
  # `quantityIndex` is a flat map, so the second registration would take over
  # every claim on that quantity in every design with nothing said -- the same
  # quantity name in the report either way, and a different analysis behind
  # it. An override says so by keeping the name; a collision is an accident,
  # and once it has happened the two are indistinguishable.
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
