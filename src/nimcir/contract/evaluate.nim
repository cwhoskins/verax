## Checking what a design claims about itself.
##
## `contract/types` declares an `Assertion`, `contract/roles` expands roles
## into them and `contract/design` prints them. This module is what actually
## produces a verdict, and the verdict type is the design decision worth
## stating first: an `AssertionResult` is **not** an `Issue`. `Issue` can say
## "something is wrong here" and nothing else -- it has no way to say "checked,
## and it is fine", and no way to say "could not check". Silence meaning pass
## is how an assertion layer turns into filler that always agrees with you.
##
## **Quantity to evaluator is many-to-one, and the "many" already exists.**
## `analysis/pdn.analyzePdn` emits eight measurement names from a single `.ac`
## run; `analyzeStartup` emits six from one `.tran`. So an evaluator is handed
## a *batch* of assertions and returns a batch of results, and the loop is:
##
## 1. **plan** -- group assertions by the evaluator that produces their
##    quantity and by a setup key, so one analysis runs once per distinct
##    setup rather than once per assertion;
## 2. **run** each step;
## 3. **harvest** the measurements it produced;
## 4. **compare**, with the `satisfies` in `contract/types` that every
##    evaluator shares.
##
## Grouping is the *planner's* job, via `Evaluator.setupKey`, rather than
## something each evaluator reimplements -- that way "one run per setup" is a
## property of this module, provable by a test that counts steps.
##
## **This module depends only on `nimcir/netlist`**, which is what keeps a
## design and its contract inspectable with no simulator anywhere in the
## build. An `Evaluator` is a value with a `proc` field, exactly as
## `RoleDef.expand` is, so the simulation-backed evaluators register
## themselves from `nimcir/analysis/contract_eval` -- a module that *is*
## allowed to import a simulator -- and take an identical path to the static
## ones registered here. A built-in that cheats makes user-defined evaluators
## second-class, and then nobody writes one.

import std/[algorithm, math, options, strutils, tables]
import ../netlist/types
import ../netlist/annotations
import ../eng
import ./types as ctypes
import ./roles
import ./design

# `AssertionResult` carries `Assumption`s, so anything holding a result needs
# the accessors that build and read one without a second import -- the same
# reason `analysis/report` re-exports this.
# `originRole`/`netSubject` and friends hand back `Option`s, so an evaluator
# module needs those accessors without a second import too.
export ctypes, roles, design, annotations, options

type
  EvalStatus* = enum
    esPass          ## measured, and it meets the claim
    esFail          ## measured, and it does not
    esNotEvaluated  ## an evaluator exists but did not produce a number
    esNotEvaluable  ## nothing can produce this quantity for these subjects

  Capability* = enum
    ## What running an evaluator costs. A closed enum, deliberately, while
    ## `Assertion.quantity`, `Issue.kind` and `Measurement.name` are all open
    ## strings: quantity names are owned by whoever writes a role, but the set
    ## of *execution environments* is owned by this library, and a host has to
    ## be able to state what it can offer as a `set`. Finer-grained bench
    ## requirements (an IVI class-driver taxonomy -- DMM, scope, fgen, PSU)
    ## belong on a later field of `Evaluator`, not as more members here.
    capStatic     ## a graph walk; no external tool
    capSpiceOp
    capSpiceAc
    capSpiceTran
    capBench      ## a measurement on real hardware

const
  simCapabilities* = {capSpiceOp, capSpiceAc, capSpiceTran}
  offlineCapabilities* = {capStatic}
  allCapabilities* = {capStatic, capSpiceOp, capSpiceAc, capSpiceTran}
    ## Everything reachable without hardware. `capBench` is deliberately left
    ## out: it is opt-in, because offering it means a person is standing at a
    ## bench.

type
  AssertionResult* = object
    assertion*: Assertion
    status*: EvalStatus
    value*: float
      ## The measured number. `NaN` unless `status` is `esPass`/`esFail`.
    unit*: string
    reason*: string
      ## For a fail, the witness. For anything not checked, why not -- naming
      ## what was missing, since that is the only part a reader can act on.
    evaluator*: string
    assumptions*: seq[Assumption]
      ## What the verdict rested on that the design did not state. A pass
      ## built on an invented number has to carry it, or this layer quietly
      ## launders confidence.
    issues*: seq[Issue]
      ## Diagnostic context the underlying analysis reported alongside the
      ## measurement -- never a duplicate of this result's own verdict.

  EvalProc* = proc (d: Design, batch: seq[Assertion]): seq[AssertionResult] {.nimcall.}
    ## Takes every assertion routed to this evaluator that shares a setup key,
    ## and must return one result per assertion in the batch.
  SetupKeyProc* = proc (d: Design, a: Assertion): string {.nimcall.}
    ## Two assertions with the same key can be answered by one run. `nil`
    ## means "the subject names", which is the right default for anything
    ## measured per-net.

  Evaluator* = object
    name*: string
    produces*: seq[string]
      ## Quantity names, matching `analysis/report.Measurement.name`.
    needs*: Capability
    arity*: Slice[int]
      ## Accepted subject count. Left at its zero default, means `1 .. high`.
    subjectKinds*: set[SubjectKind]
      ## Empty means every kind.
    binds*: seq[string]
      ## Role *parts* this evaluator reads back off `Assertion.origin`,
      ## beyond the assertion's own subjects.
      ##
      ## Declared rather than inferred, for the same reason
      ## `BehavioralModel.passesSignal` is: something has to answer "can a
      ## bare `require` reach this quantity?" **without running anything**,
      ## and only the evaluator knows. Empty means the subjects are enough --
      ## a `dc_voltage` or a PDN sweep needs only the net it is about.
      ## Non-empty means the quantity is reachable *only* through a role that
      ## binds those parts, because an assertion carries no other channel for
      ## them: `overshoot_pct(vdd)` names the rail but not the regulator
      ## driving it, and nothing in a netlist recovers that.
    setupKey*: SetupKeyProc
    run*: EvalProc

  PlanStep* = object
    evaluator*: string
    key*: string
    needs*: Capability
    assertions*: seq[Assertion]

  Rejection* = object
    assertion*: Assertion
    status*: EvalStatus  ## `esNotEvaluable` or `esNotEvaluated`
    reason*: string
    evaluator*: string   ## empty when nothing claimed the quantity

  Plan* = object
    ## What *would* run. Separated from running it because an assertion set
    ## you cannot inspect before it executes is the same failure mode
    ## `design.explain` exists to prevent.
    steps*: seq[PlanStep]
    rejected*: seq[Rejection]

# --- registry ----------------------------------------------------------

var evaluatorRegistry: OrderedTable[string, Evaluator]
var quantityIndex: Table[string, string]  ## quantity -> evaluator name

proc registerEvaluator*(ev: Evaluator) =
  ## Registering a quantity a previous evaluator claimed replaces it, exactly
  ## as `registerRole` replaces a role -- that is how an application overrides
  ## a built-in with something better suited to its own designs.
  if ev.name.len == 0:
    raise newException(NetlistError, "evaluator name must not be empty")
  if ev.run == nil:
    raise newException(NetlistError, "evaluator '" & ev.name & "' has no run proc")
  if ev.produces.len == 0:
    raise newException(NetlistError,
      "evaluator '" & ev.name & "' produces no quantities")

  var it = ev
  if it.arity.a == 0 and it.arity.b == 0: it.arity = 1 .. int.high
  if it.subjectKinds == {}:
    it.subjectKinds = {skNet, skComponent, skPin, skClass, skDesign}

  evaluatorRegistry[it.name] = it
  for q in it.produces: quantityIndex[q] = it.name

proc evaluatorFor*(quantity: string): Option[Evaluator] =
  if not quantityIndex.hasKey(quantity): return none(Evaluator)
  let name = quantityIndex[quantity]
  if not evaluatorRegistry.hasKey(name): return none(Evaluator)
  some(evaluatorRegistry[name])

proc isEvaluable*(quantity: string): bool = quantityIndex.hasKey(quantity)

proc registeredEvaluators*(): seq[string] =
  for k in evaluatorRegistry.keys: result.add k

proc evaluableQuantities*(): seq[string] =
  for q in quantityIndex.keys: result.add q
  result.sort()

# --- what an evaluator can recover about its setup ----------------------

proc originRole*(d: Design, a: Assertion): Option[RoleInstance] =
  ## The role instance that expanded this assertion, if a role did.
  ##
  ## This is how an evaluator recovers topology the assertion itself does not
  ## carry. `overshoot_pct(vdd)` names a rail but not the regulator driving
  ## it, and `analyzeStartup` needs both -- but `roles.nim` stamps the role
  ## instance name into `Assertion.origin`, and the instance holds every part
  ## the role bound. So a role, which already knows its own topology, supplies
  ## the setup its own claims need.
  if a.origin.len == 0 or a.origin == "authored": return none(RoleInstance)
  if not d.roles.hasKey(a.origin): return none(RoleInstance)
  some(d.roles[a.origin])

proc originBinding*(d: Design, a: Assertion, part: string): Option[Subject] =
  ## A named part of the role that expanded this assertion.
  let inst = originRole(d, a)
  if inst.isNone: return none(Subject)
  if not inst.get.bindings.hasKey(part): return none(Subject)
  some(inst.get.bindings[part])

proc originParam*(d: Design, a: Assertion, name: string): Option[string] =
  let inst = originRole(d, a)
  if inst.isNone: return none(string)
  if not inst.get.params.hasKey(name): return none(string)
  some(inst.get.params[name])

proc conditionOf*(a: Assertion, key: string): Option[string] =
  if not a.condition.hasKey(key): return none(string)
  some(a.condition[key])

proc conditionFloat*(a: Assertion, key: string, fallback: float): float =
  if not a.condition.hasKey(key): return fallback
  try: parseAnnFloat(key, a.condition[key])
  except CatchableError: fallback

proc netSubject*(d: Design, a: Assertion, index = 0): Option[Net] =
  ## The `index`-th subject as a live net, when it is one and it exists.
  if index >= a.subjects.len: return none(Net)
  let s = a.subjects[index]
  if s.kind != skNet: return none(Net)
  if not d.netlist.nets.hasKey(s.name): return none(Net)
  some(d.netlist.nets[s.name])

# --- building results ---------------------------------------------------

proc unitsAgree(claimed, measured: string): bool =
  ## An empty unit on either side means "not stated", which is unchecked
  ## rather than mismatched: `pullup_count` is a bare number and always will
  ## be.
  if claimed.len == 0 or measured.len == 0: return true
  cmpIgnoreCase(claimed, measured) == 0

proc notEvaluable*(a: Assertion, evaluator, reason: string): AssertionResult =
  AssertionResult(assertion: a, status: esNotEvaluable, value: NaN,
                  unit: a.unit, reason: reason, evaluator: evaluator)

proc notEvaluated*(a: Assertion, evaluator, reason: string): AssertionResult =
  AssertionResult(assertion: a, status: esNotEvaluated, value: NaN,
                  unit: a.unit, reason: reason, evaluator: evaluator)

proc verdict*(a: Assertion, value: float, unit: string, evaluator: string,
              assumptions: seq[Assumption] = @[],
              issues: seq[Issue] = @[]): AssertionResult =
  ## The single place pass/fail semantics live, so every evaluator -- built-in
  ## or not -- gets identical behaviour for free.
  ##
  ## Two decisions are pinned here:
  ##
  ## * **A `NaN` measurement is `esNotEvaluated`, not `esFail`.** `satisfies`
  ##   guarantees a `NaN` never *passes*; this goes one step further and
  ##   declines to call it a failure, because "the response never crossed
  ##   -3 dB anywhere in the swept band" and "this design is wrong" are
  ##   different claims. `z_antiresonance` comes back `NaN` when there is no
  ##   interior impedance peak, which is the good outcome.
  ## * **A unit mismatch is `esNotEvaluable`.** Comparing volts against hertz
  ##   silently is worse than declining to compare them.
  ##
  ## Both of those decline to answer, and both still carry the analysis's
  ## `assumptions` and `issues` out with them -- for the same reason
  ## `failBatch` does. `reason` is written here and cannot name a cause this
  ## proc does not know; the analysis that produced the `NaN` usually does
  ## know, and says so in an `Issue`. Dropping those leaves a reader holding
  ## "the quantity was not found in the range that was analysed" -- true, and
  ## it sends them to widen a sweep -- when an issue one field away says the
  ## loop break never opened the loop and no margin exists to find.
  if not unitsAgree(a.unit, unit):
    result = notEvaluable(a, evaluator,
      "unit mismatch: the assertion is stated in " & a.unit &
      " but " & a.quantity & " is measured in " & unit)
    result.assumptions = assumptions
    result.issues = issues
    return

  if value.isNaN:
    result = notEvaluated(a, evaluator,
      a.quantity & " produced no value for these subjects -- the quantity " &
      "was not found in the range that was analysed")
    result.assumptions = assumptions
    result.issues = issues
    return

  result = AssertionResult(
    assertion: a, value: value,
    unit: if a.unit.len > 0: a.unit else: unit,
    evaluator: evaluator, assumptions: assumptions, issues: issues)

  if a.expect.satisfies(value):
    result.status = esPass
    result.reason = "measured " & eng(value, result.unit)
  else:
    result.status = esFail
    result.reason = "measured " & eng(value, result.unit) & ", expected " &
                    `$`(a.expect, result.unit)

# --- planning -----------------------------------------------------------

proc defaultKey(a: Assertion): string =
  var parts: seq[string]
  for s in a.subjects: parts.add s.name
  parts.join("/")

proc plan*(d: Design, allowed: set[Capability] = offlineCapabilities): Plan =
  ## Routes every assertion in the design -- authored and role-expanded alike
  ## -- to an evaluator, grouping into one step per `(evaluator, setup key)`.
  ##
  ## Pure: nothing runs, nothing is simulated, and the design is not touched.
  var stepIndex: Table[string, int]

  for a in d.expandAll():
    let evOpt = evaluatorFor(a.quantity)
    if evOpt.isNone:
      result.rejected.add Rejection(assertion: a, status: esNotEvaluable,
        reason: "no evaluator produces '" & a.quantity & "'")
      continue
    let ev = evOpt.get

    if a.subjects.len notin ev.arity:
      result.rejected.add Rejection(assertion: a, status: esNotEvaluable,
        evaluator: ev.name,
        reason: "'" & a.quantity & "' takes " & $ev.arity.a & ".." &
                (if ev.arity.b == int.high: "n" else: $ev.arity.b) &
                " subjects, got " & $a.subjects.len)
      continue

    var badKind = false
    for s in a.subjects:
      if s.kind notin ev.subjectKinds:
        result.rejected.add Rejection(assertion: a, status: esNotEvaluable,
          evaluator: ev.name,
          reason: "'" & a.quantity & "' cannot be measured of " & $s)
        badKind = true
        break
    if badKind: continue

    if ev.needs notin allowed:
      result.rejected.add Rejection(assertion: a, status: esNotEvaluated,
        evaluator: ev.name,
        reason: "requires " & $ev.needs & ", which was not offered")
      continue

    let key = if ev.setupKey != nil: ev.setupKey(d, a) else: defaultKey(a)
    let slot = ev.name & "\x1f" & key
    if not stepIndex.hasKey(slot):
      stepIndex[slot] = result.steps.len
      result.steps.add PlanStep(evaluator: ev.name, key: key, needs: ev.needs)
    result.steps[stepIndex[slot]].assertions.add a

proc assertionCount*(p: Plan): int =
  for s in p.steps: result += s.assertions.len
  result += p.rejected.len

proc explainPlan*(p: Plan): string =
  var lines: seq[string]
  lines.add "plan: " & $p.steps.len & " step(s), " &
            $assertionCount(p) & " assertion(s)"
  for s in p.steps:
    lines.add "  " & s.evaluator & " [" & $s.needs & "]" &
              (if s.key.len > 0: " on " & s.key else: "") &
              " -- " & $s.assertions.len & " assertion(s)"
    for a in s.assertions:
      lines.add "      " & (if a.id.len > 0: a.id else: a.quantity)
  for r in p.rejected:
    lines.add "  (" & $r.status & ") " &
              (if r.assertion.id.len > 0: r.assertion.id else: r.assertion.quantity) &
              " -- " & r.reason
  lines.join("\n")

# --- running ------------------------------------------------------------

proc runStep(d: Design, step: PlanStep): seq[AssertionResult] =
  ## An evaluator that returns the wrong number of results, or raises, is a
  ## bug in the evaluator -- but it must not take down a whole run, because
  ## then one bad plugin costs every other verdict in the design.
  let ev = evaluatorRegistry[step.evaluator]
  var produced: seq[AssertionResult]
  try:
    produced = ev.run(d, step.assertions)
  except CatchableError as e:
    for a in step.assertions:
      result.add notEvaluated(a, ev.name,
        "evaluator '" & ev.name & "' failed: " & e.msg)
    return

  if produced.len == step.assertions.len:
    return produced

  # Match what came back by assertion id, and account for the rest.
  var byId: Table[string, AssertionResult]
  for r in produced:
    if r.assertion.id.len > 0: byId[r.assertion.id] = r
  for a in step.assertions:
    if a.id.len > 0 and byId.hasKey(a.id):
      result.add byId[a.id]
    else:
      result.add notEvaluated(a, ev.name,
        "evaluator '" & ev.name & "' returned no result for this assertion")

proc evaluate*(d: Design, allowed: set[Capability] = offlineCapabilities): seq[AssertionResult] =
  ## Every claim this design makes, checked as far as `allowed` permits.
  ##
  ## The default offers nothing but graph walks, mirroring how
  ## `nimcir/analysis` exports only what runs with no external toolchain: pass
  ## `allCapabilities` (and import `nimcir/analysis/contract_eval`) to let the
  ## simulation-backed evaluators run.
  let p = plan(d, allowed)
  for step in p.steps:
    for r in runStep(d, step): result.add r
  for rej in p.rejected:
    result.add AssertionResult(assertion: rej.assertion, status: rej.status,
                               value: NaN, unit: rej.assertion.unit,
                               reason: rej.reason, evaluator: rej.evaluator)

# --- reading the results ------------------------------------------------

proc count*(results: seq[AssertionResult], status: EvalStatus): int =
  for r in results:
    if r.status == status: inc result

proc failed*(results: seq[AssertionResult]): seq[AssertionResult] =
  for r in results:
    if r.status == esFail: result.add r

proc unchecked*(results: seq[AssertionResult]): seq[AssertionResult] =
  ## Everything nobody actually verified. Worth reading as carefully as the
  ## failures: a contract whose claims are mostly unchecked is not a contract
  ## that passed.
  for r in results:
    if r.status in {esNotEvaluated, esNotEvaluable}: result.add r

proc invented*(results: seq[AssertionResult]): seq[Assumption] =
  for r in results:
    for a in r.assumptions:
      if a.source != annAuthored: result.add a

proc worstSeverity*(results: seq[AssertionResult]): Severity =
  result = sevInfo
  for r in results:
    if r.status == esFail and r.assertion.severity > result:
      result = r.assertion.severity

proc `$`*(r: AssertionResult): string =
  let label = if r.assertion.id.len > 0: r.assertion.id else: r.assertion.quantity
  let mark = case r.status
             of esPass: "PASS"
             of esFail: "FAIL"
             of esNotEvaluated: "----"
             of esNotEvaluable: "????"
  result = "[" & mark & "] " & label & ": " & describe(r.assertion)
  if r.reason.len > 0: result &= "\n         " & r.reason

proc summary*(results: seq[AssertionResult]): string =
  "checked " & $results.len & " assertion(s): " &
  $count(results, esPass) & " passed, " &
  $count(results, esFail) & " failed, " &
  $count(results, esNotEvaluated) & " not evaluated, " &
  $count(results, esNotEvaluable) & " not evaluable"

proc report*(results: seq[AssertionResult]): string =
  var lines: seq[string]
  for r in results: lines.add $r
  lines.add summary(results)
  let inv = invented(results)
  if inv.len > 0:
    lines.add "resting on " & $inv.len & " assumed value(s):"
    for a in inv: lines.add "  " & $a
  lines.join("\n")
