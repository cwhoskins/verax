## The condition vocabulary: a bare condition key must be registered, and a
## value must parse, or `plan` refuses the claim -- an unknown or malformed
## condition would otherwise be ignored while the evaluator used its default.

import std/[options, strutils, tables, unittest]

import verax/contract/dsl
import verax/contract/evaluate
import verax/contract/evaluators/static

proc board(): Design =
  design("board"):
    net vdd, kind = ntPower:
      spec:
        voltage = 3.3.V
    net gnd, kind = ntGround, name = "0"
    net sda, kind = ntSignal
    component R1, kind = "resistor", value = "4.7k":
      pin "1", vdd, kind = ptPassive
      pin "2", sda, kind = ptPassive

proc claim(conditions: openArray[(string, string)]): Assertion =
  mkAssertion("pullup_count", @[Subject(kind: skNet, name: "sda")],
              atLeast(1.0), "", id = "PU", condition = conditions)

proc runBanded(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  for a in batch:
    result.add verdict(a, conditionFloat(a, "f_from", 0.0), "Hz", "test.banded")

proc bandKey(ctx: EvalContext, a: Assertion): string =
  $conditionFloat(a, "f_from", 0.0) & "|" & $conditionFloat(a, "f_to", 0.0)

registerCondition(ConditionDef(key: "bench_temp_c", kind: cdFloat,
                               unit: "degC", doc: "test"))
registerEvaluator(Evaluator(name: "test.banded", produces: @["banded_f"],
  arity: 1 .. 1, conditions: @["f_from", "f_to", "bench_temp_c"],
  units: {"banded_f": "Hz"}.toTable, setupKey: bandKey, run: runBanded))

proc banded(conditions: openArray[(string, string)], unit = "",
            id = "B"): Assertion =
  mkAssertion("banded_f", @[Subject(kind: skNet, name: "sda")],
              atLeast(1.0), unit, id = id, condition = conditions)

proc rejection(d: Design, id: string): Rejection =
  for r in plan(d).rejected:
    if r.assertion.id == id: return r
  raise newException(KeyError, "no rejection for " & id)

test "every condition an evaluator reads is registered":
  for key in ["f_from", "f_to", "at_f", "t_settle", "t_window", "step_to",
              "ripple_f", "sweep", "sweep_from", "v_nominal", "kick_v"]:
    check isConditionKey(key)

test "a misspelled condition is refused at plan time, naming the near miss":
  let d = board()
  d.assertThat claim({"f_form": "1e5"})
  let r = rejection(d, "PU")
  check r.status == esNotEvaluable
  check "unknown condition 'f_form'" in r.reason
  check "did you mean 'f_from'" in r.reason

test "a condition value that is not a plain SI number is refused, not defaulted":
  let d = board()
  d.assertThat claim({"f_from": "100k"})
  let r = rejection(d, "PU")
  check r.status == esNotEvaluable
  check "f_from" in r.reason

test "a text condition outside its allowed words is refused":
  let d = board()
  d.assertThat claim({"sweep": "lien"})
  check "not one of source, load" in rejection(d, "PU").reason

test "a dotted condition is the author's own and is not validated":
  let d = board()
  d.assertThat claim({"mine.note": "anything at all"})
  check plan(d).rejected.len == 0

test "a registered condition its evaluator reads passes and is routed":
  let d = board()
  d.assertThat banded({"f_from": "1e5", "f_to": "1e8"})
  let p = plan(d)
  check p.rejected.len == 0
  check p.steps.len == 1

test "a runtime-registered condition is accepted":
  let d = board()
  d.assertThat banded({"bench_temp_c": "25"})
  check plan(d).rejected.len == 0

test "conditionFloat defaults only an absent key; a malformed one raises":
  let a = claim({"f_from": "100k"})
  check conditionFloat(a, "f_to", 7.0) == 7.0
  expect CatchableError:
    discard conditionFloat(a, "f_from", 0.0)

test "a relative claim's reference conditions are validated too":
  let d = board()
  var a = relAssertion("pullup_count", @[Subject(kind: skNet, name: "sda")],
                       roGe, 1.0, "pullup_count",
                       @[Subject(kind: skNet, name: "sda")], id = "REL",
                       conditions = {"t_setle": "1e-3"})
  d.assertThat a
  var found = false
  for r in evaluate(d):
    if r.assertion.id == "REL":
      found = true
      check r.status == esNotEvaluable
      check "t_setle" in r.reason
  check found

# --- R1.2: evaluators declare the conditions they read -------------------

test "a registered condition the evaluator does not read is refused":
  let d = board()
  d.assertThat claim({"at_f": "1e3"})
  let r = rejection(d, "PU")
  check r.status == esNotEvaluable
  check r.evaluator == "static.pullup_count"
  check "does not read condition 'at_f'" in r.reason
  check "reads no conditions" in r.reason

test "the refusal names what the evaluator does read":
  let d = board()
  d.assertThat banded({"at_f": "1e3"})
  let r = rejection(d, "B")
  check "f_from, f_to, bench_temp_c" in r.reason

test "an evaluator may not declare an unregistered condition":
  expect NetlistError:
    registerEvaluator(Evaluator(name: "test.bad", produces: @["bad_q"],
      conditions: @["f_form"], run: runBanded))

test "a trailing condition read by one predicate dependency is dropped from the others":
  let d = board()
  d.assertThat predicateAssertion(@[
      PredicateDep(name: "b", measurement: measurementRef("banded_f",
        @[Subject(kind: skNet, name: "sda")])),
      PredicateDep(name: "n", measurement: measurementRef("pullup_count",
        @[Subject(kind: skNet, name: "sda")]))],
    proc (v: seq[float]): bool {.nimcall.} = v[0] > v[1],
    id = "P", conditions = {"f_from": "1e5"})
  let p = plan(d)
  check p.rejected.len == 0
  for s in p.steps:
    for a in s.assertions:
      if a.quantity == "pullup_count": check not a.condition.hasKey("f_from")
      if a.quantity == "banded_f": check a.condition.hasKey("f_from")

test "a trailing condition no dependency reads is still refused":
  let d = board()
  d.assertThat predicateAssertion(@[
      PredicateDep(name: "n", measurement: measurementRef("pullup_count",
        @[Subject(kind: skNet, name: "sda")]))],
    proc (v: seq[float]): bool {.nimcall.} = v[0] > 0,
    id = "P", conditions = {"f_from": "1e5"})
  check plan(d).rejected.len == 1

# --- R1.5: evaluators declare units --------------------------------------

test "a claim in the wrong unit is refused before anything runs":
  let d = board()
  d.assertThat banded({"f_from": "1e5"}, unit = "V")
  let r = rejection(d, "B")
  check "unit mismatch" in r.reason
  check "measured in Hz" in r.reason

test "declaredUnit reads the producer's declaration":
  check declaredUnit("banded_f") == some("Hz")
  check declaredUnit("pullup_count") == some("")
  check declaredUnit("no_such_quantity").isNone

test "a measurement in a unit its evaluator does not declare is not trusted":
  let a = banded({"f_from": "1e5"})
  let r = verdict(a, 1.0e5, "V", "test.banded")
  check r.status == esNotEvaluated
  check "internal" in r.reason

test "a declared unit must name a produced quantity":
  expect NetlistError:
    registerEvaluator(Evaluator(name: "test.bad2", produces: @["bad2_q"],
      units: {"other_q": "V"}.toTable, run: runBanded))

# --- R1.1: setup keys derived from the run's spec ------------------------

type
  Inner = object
    z: float
  Spec = object
    a: float
    n: int
    name: string
    tab: OrderedTable[string, float]
    inner: Inner
    xs: seq[float]

test "specKey sees every field, nested and tabled":
  var s1 = Spec(a: 1.0, n: 2, name: "x", inner: Inner(z: 3.0), xs: @[1.0])
  var s2 = s1
  check specKey(s1) == specKey(s2)
  s2.inner.z = 4.0
  check specKey(s1) != specKey(s2)
  s2 = s1
  s2.xs.add 2.0
  check specKey(s1) != specKey(s2)
  s2 = s1
  s2.tab["k"] = 1.0
  check specKey(s1) != specKey(s2)

test "specKey keys a table by content, not insertion order":
  var s1, s2: Spec
  s1.tab["a"] = 1.0
  s1.tab["b"] = 2.0
  s2.tab["b"] = 2.0
  s2.tab["a"] = 1.0
  check specKey(s1) == specKey(s2)
