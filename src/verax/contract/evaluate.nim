## Checking what a design claims about itself.
##
## An `AssertionResult` is **not** an `Issue`: it can say "checked and fine"
## and "could not check", which silence-means-pass cannot.
##
## Evaluators take a *batch*, since one analysis emits many quantities. The
## loop: **plan** (group by evaluator and `setupKey`, so one run per setup --
## a property of this module, testable by counting steps), **run**,
## **harvest**, **compare** (shared `satisfies`).
##
## **Depends only on `verax/netlist`**, so a design is inspectable with no
## simulator. Simulation-backed evaluators register from
## `analysis/evaluators/contract_eval` through the same path as static ones,
## so user evaluators are first-class.

import std/[algorithm, math, options, sets, strutils, tables]
import ../netlist/types
import ../netlist/annotations
import ../eng
import ./types as ctypes
import ./roles/core
import ./design

# Results carry `Assumption`s and accessors return `Option`s, so evaluator
# modules get both without extra imports.
export ctypes, roles, design, annotations, options

type
  EvalStatus* = enum
    esPass          ## measured, and it meets the claim
    esFail          ## measured, and it does not
    esNotEvaluated  ## an evaluator exists but did not produce a number
    esNotEvaluable  ## nothing can produce this quantity for these subjects

  Capability* = enum
    ## What running an evaluator costs. Closed (unlike quantity names) because
    ## the library owns execution environments and a host states its offer as
    ## a `set`. Finer bench requirements belong on a later `Evaluator` field.
    capStatic     ## a graph walk; no external tool
    capSpiceOp
    capSpiceDc    ## a source sweep: N operating points, one per swept value
    capSpiceAc
    capSpiceTran
    capSiTran     ## the native SI transient engine (`si/`); no external tool
    capBench      ## a measurement on real hardware

const
  simCapabilities* = {capSpiceOp, capSpiceDc, capSpiceAc, capSpiceTran}
    ## What needs ngspice. `capSiTran` is not here: the SI engine is native.
  offlineCapabilities* = {capStatic, capSiTran}
    ## No external tool. Includes `capSiTran` (plan open decision 4): the
    ## cost is that a plain `--offline` check also runs SI simulations.
  allCapabilities* = {capStatic, capSpiceOp, capSpiceDc, capSpiceAc,
                      capSpiceTran, capSiTran}
    ## Everything reachable without hardware. `capBench` is opt-in: it means
    ## someone is at a bench.

type
  AssertionResult* = object
    assertion*: Assertion
    status*: EvalStatus
    value*: float
      ## The measured number. `NaN` unless `status` is `esPass`/`esFail`.
    unit*: string
    reason*: string
      ## For a fail, the witness; for anything unchecked, what was missing.
    evaluator*: string
    assumptions*: seq[Assumption]
      ## What the verdict rested on that the design didn't state.
    issues*: seq[Issue]
      ## Diagnostics the analysis reported alongside the measurement.

  EvalContext* = ref object
    ## Everything one evaluation run may see -- the **only** argument an
    ## evaluator receives. `EvalProc` is the plugin ABI, so anything an
    ## evaluator might need must be reachable here.
    design*: Design
    allowed*: set[Capability]
      ## What this run may do. The planner already refused anything needing
      ## more; an evaluator uses it to decide how far to go within it.
    scratch*: Table[string, RootRef]
      ## Per-run storage keyed by an owner-chosen dotted name
      ## (`"spice.operating_point"`). Type-erased so `contract` never depends
      ## on `analysis` or `pcb`: owners store a `ref object of RootObj` and
      ## downcast. Lives one run, so caches can't go stale against an edit.

  EvalProc* = proc (ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] {.nimcall.}
    ## Takes every assertion routed here with one setup key; returns one
    ## result per assertion.
  SetupKeyProc* = proc (ctx: EvalContext, a: Assertion): string {.nimcall.}
    ## Same key = answerable by one run. `nil` means "the subject names".
  SetupDocProc* = proc (ctx: EvalContext, batch: seq[Assertion]): string {.nimcall.}
    ## One sentence saying what the run is, given its batch.

  Evaluator* = object
    name*: string
    produces*: seq[string]
      ## Quantity names, matching `analysis/report.Measurement.name`.
    needs*: set[Capability]
      ## Every capability a run uses, not just the headline one (e.g. an
      ## `.ac` evaluator that also solves an `.op` for derating). Under-
      ## declaring gives wrong answers once a capability is withheld. Empty
      ## means `{capStatic}`; `registerEvaluator` normalises it.
    arity*: Slice[int]
      ## Accepted subject count; the zero default means `1 .. high`.
    subjectKinds*: set[SubjectKind]
      ## Empty means every kind.
    binds*: seq[string]
      ## Role parts read off a role instance beyond the subjects (via
      ## `originBinding` or `subjectRoleBinding`). Declared so "can a bare
      ## `require` reach this?" is answerable without running. Non-empty
      ## means reachable only through a role (`overshoot_pct(vdd)` names the
      ## rail, not its regulator).
    setupKey*: SetupKeyProc
    setupDoc*: SetupDocProc
      ## Renders the run for a reader (`"an .ac sweep of net 'vdd', 1 A
      ## injected"`); the setup key groups but says nothing. `nil` falls back
      ## to the key.
    run*: EvalProc

  PlanStep* = object
    evaluator*: string
    key*: string
    needs*: set[Capability]
    assertions*: seq[Assertion]

  Rejection* = object
    assertion*: Assertion
    status*: EvalStatus  ## `esNotEvaluable` or `esNotEvaluated`
    reason*: string
    evaluator*: string   ## empty when nothing claimed the quantity

  ResolveStep* = object
    ## How a relative or predicate claim folds back into one result after
    ## its hidden requests run.
    assertion*: Assertion
      ## The authored claim, kept whole.
    primary*: string
      ## Hidden request id for the left-hand measurement; "" for a predicate.
    deps*: seq[tuple[name, request: string]]
      ## Named dependencies in predicate-argument order; a relative claim has
      ## one, `reference`.

  Plan* = object
    ## What *would* run, inspectable before execution.
    steps*: seq[PlanStep]
    rejected*: seq[Rejection]
    resolves*: seq[ResolveStep]
      ## Relative and predicate claims, folded after the steps run.
    hidden*: HashSet[string]
      ## Planner-invented request ids, excluded from user-facing results.

proc capLabel*(c: Capability): string =
  ## Short readable form, shared by every renderer.
  case c
  of capStatic: "static"
  of capSpiceOp: ".op"
  of capSpiceDc: ".dc"
  of capSpiceAc: ".ac"
  of capSpiceTran: ".tran"
  of capSiTran: "si"
  of capBench: "bench"

proc capLabel*(s: set[Capability]): string =
  ## The set form, readable (not `{capSpiceOp, capSpiceAc}`).
  var parts: seq[string]
  for c in s: parts.add capLabel(c)
  if parts.len == 0: "none" else: parts.join(" + ")

proc newEvalContext*(d: Design, allowed = offlineCapabilities): EvalContext =
  ## One context per run. Hold one across `plan`, `runPlan` and
  ## `describeStep` to share caches; build one per call for isolation.
  EvalContext(design: d, allowed: allowed)

# --- registry ----------------------------------------------------------

var evaluatorRegistry: OrderedTable[string, Evaluator]
var quantityIndex: Table[string, string]  ## quantity -> evaluator name

proc registerEvaluator*(ev: Evaluator) =
  ## Re-registering under the same name replaces (the override path).
  ## Claiming a quantity a **different** evaluator produces raises: it would
  ## silently take over every claim on that quantity.
  if ev.name.len == 0:
    raise newException(NetlistError, "evaluator name must not be empty")
  if ev.run == nil:
    raise newException(NetlistError, "evaluator '" & ev.name & "' has no run proc")
  if ev.produces.len == 0:
    raise newException(NetlistError,
      "evaluator '" & ev.name & "' produces no quantities")

  var it = ev
  if it.arity.a == 0 and it.arity.b == 0: it.arity = 1 .. int.high
  # Declaring nothing means a graph walk; an empty set would pass any offer.
  if it.needs == {}: it.needs = {capStatic}
  if it.subjectKinds == {}:
    it.subjectKinds = {skNet, skComponent, skPin, skClass, skDesign}

  for q in it.produces:
    let owner = quantityIndex.getOrDefault(q)
    if owner.len > 0 and owner != it.name:
      raise newException(NetlistError,
        "evaluator '" & it.name & "' produces '" & q &
        "', which evaluator '" & owner & "' already produces -- one quantity " &
        "has one producer, or a claim on it silently changes which analysis " &
        "answers it; rename the quantity, or register under '" & owner &
        "' to replace that evaluator outright")

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
  ## The role instance that expanded this assertion, if any. How an
  ## evaluator recovers topology the assertion lacks (the regulator behind
  ## `overshoot_pct(vdd)`): roles stamp their instance into `origin`.
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

proc subjectRole*(d: Design, a: Assertion, index: int): Option[RoleInstance] =
  ## The role instance the `index`-th `skClass` subject names, if it exists.
  ## The subject-side counterpart of `originRole`, for multi-subject claims
  ## like `channel_match` (expanders have no `Design` to dereference).
  ## Returns `none` so the evaluator can name what was missing.
  if index < 0 or index >= a.subjects.len: return none(RoleInstance)
  let s = a.subjects[index]
  if s.kind != skClass: return none(RoleInstance)
  if not d.roles.hasKey(s.name): return none(RoleInstance)
  some(d.roles[s.name])

proc subjectRoleBinding*(d: Design, a: Assertion, index: int,
                         part: string): Option[Subject] =
  ## A named part of the role instance the `index`-th subject references.
  let inst = subjectRole(d, a, index)
  if inst.isNone: return none(Subject)
  if not inst.get.bindings.hasKey(part): return none(Subject)
  some(inst.get.bindings[part])

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
  ## An empty unit on either side is unchecked, not mismatched.
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
  ## The single place pass/fail semantics live:
  ##
  ## * **`NaN` is `esNotEvaluated`, not `esFail`**: "never crossed -3 dB in
  ##   the band" isn't "the design is wrong" (`z_antiresonance` is `NaN` when
  ##   there's no peak, the good outcome).
  ## * **A unit mismatch is `esNotEvaluable`.**
  ##
  ## Both still carry the analysis's assumptions and issues: the issue
  ## usually explains the `NaN`, which this generic `reason` can't.
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

const hiddenIdPrefix = "\x1fcontract-dep\x1f"

proc hiddenId(serial: int, role: string): string =
  ## A request id no authored claim can collide with: the planner's record
  ## separator plus a counter.
  hiddenIdPrefix & $serial & "\x1f" & role

proc routePlain(ctx: EvalContext, p: var Plan,
                stepIndex: var Table[string, int], a: Assertion) =
  ## Routes one plain measurement request. Hidden requests use this path
  ## too, so they group with authored claims sharing evaluator and setup.
  let d = ctx.design
  let allowed = ctx.allowed
  let evOpt = evaluatorFor(a.quantity)
  if evOpt.isNone:
    p.rejected.add Rejection(assertion: a, status: esNotEvaluable,
      reason: "no evaluator produces '" & a.quantity & "'")
    return
  let ev = evOpt.get

  if a.subjects.len notin ev.arity:
    p.rejected.add Rejection(assertion: a, status: esNotEvaluable,
      evaluator: ev.name,
      reason: "'" & a.quantity & "' takes " & $ev.arity.a & ".." &
              (if ev.arity.b == int.high: "n" else: $ev.arity.b) &
              " subjects, got " & $a.subjects.len)
    return

  var badKind = false
  for s in a.subjects:
    if s.kind notin ev.subjectKinds:
      p.rejected.add Rejection(assertion: a, status: esNotEvaluable,
        evaluator: ev.name,
        reason: "'" & a.quantity & "' cannot be measured of " & $s)
      badKind = true
      break
  if badKind: return

  let missing = ev.needs - allowed
  if missing.len > 0:
    p.rejected.add Rejection(assertion: a, status: esNotEvaluated,
      evaluator: ev.name,
      reason: "needs the " & capLabel(missing) &
              (if missing.len > 1: " capabilities, which were not offered"
               else: " capability, which was not offered"))
    return

  let key = if ev.setupKey != nil: ev.setupKey(ctx, a) else: defaultKey(a)
  let slot = ev.name & "\x1f" & key
  if not stepIndex.hasKey(slot):
    stepIndex[slot] = p.steps.len
    p.steps.add PlanStep(evaluator: ev.name, key: key, needs: ev.needs)
  p.steps[stepIndex[slot]].assertions.add a

proc plan*(ctx: EvalContext): Plan =
  ## Routes every assertion (authored and role-expanded) to an evaluator,
  ## one step per `(evaluator, setup key)`. Relative and predicate claims
  ## become hidden requests plus a `ResolveStep`; evaluators never see them.
  ## Pure: nothing runs.
  let d = ctx.design
  let allowed = ctx.allowed
  var stepIndex: Table[string, int]
  var serial = 0

  for a in d.expandAll():
    case a.expect.kind
    of ekNominal, ekMin, ekMax, ekRange:
      routePlain(ctx, result, stepIndex, a)
    of ekRelative:
      let primId = hiddenId(serial, "primary"); inc serial
      result.hidden.incl primId
      var prim = a
      prim.id = primId
      prim.expect = atLeast(-Inf)
      routePlain(ctx, result, stepIndex, prim)

      let depId = hiddenId(serial, "reference"); inc serial
      result.hidden.incl depId
      let reference = a.expect.reference
      var dep = Assertion(id: depId, subjects: reference.subjects,
        quantity: reference.quantity, expect: atLeast(-Inf), unit: "",
        severity: a.severity, rationale: "", origin: a.origin)
      for k, v in reference.condition: dep.condition[k] = v
      routePlain(ctx, result, stepIndex, dep)

      result.resolves.add ResolveStep(assertion: a, primary: primId,
        deps: @[(name: "reference", request: depId)])
    of ekPredicate:
      var reqs: seq[tuple[name, request: string]]
      for d in a.expect.deps:
        let depId = hiddenId(serial, "dep." & d.name); inc serial
        result.hidden.incl depId
        var req = Assertion(id: depId, subjects: d.measurement.subjects,
          quantity: d.measurement.quantity, expect: atLeast(-Inf), unit: "",
          severity: a.severity, rationale: "", origin: a.origin)
        for k, v in d.measurement.condition: req.condition[k] = v
        routePlain(ctx, result, stepIndex, req)
        reqs.add (name: d.name, request: depId)
      result.resolves.add ResolveStep(assertion: a, primary: "", deps: reqs)

proc plan*(d: Design, allowed: set[Capability] = offlineCapabilities): Plan =
  ## Convenience overload. Shares nothing with a later `runPlan(d, ...)`;
  ## pass one `EvalContext` to both to share an operating point.
  plan(newEvalContext(d, allowed))

proc assertionCount*(p: Plan): int =
  ## The number of authored claims (hidden requests excluded).
  for s in p.steps:
    for a in s.assertions:
      if a.id notin p.hidden: inc result
  for r in p.rejected:
    if r.assertion.id notin p.hidden: inc result
  result += p.resolves.len

proc explainPlan*(p: Plan): string =
  var lines: seq[string]
  lines.add "plan: " & $p.steps.len & " step(s), " &
            $assertionCount(p) & " assertion(s)"
  for s in p.steps:
    lines.add "  " & s.evaluator & " [" & capLabel(s.needs) & "]" &
              (if s.key.len > 0: " on " & s.key else: "") &
              " -- " & $s.assertions.len & " request(s)"
    for a in s.assertions:
      if a.id in p.hidden: continue
      lines.add "      " & (if a.id.len > 0: a.id else: a.quantity)
  for r in p.rejected:
    if r.assertion.id in p.hidden: continue
    lines.add "  (" & $r.status & ") " &
              (if r.assertion.id.len > 0: r.assertion.id else: r.assertion.quantity) &
              " -- " & r.reason
  lines.join("\n")

proc describeStep*(ctx: EvalContext, s: PlanStep): string =
  ## What one plan step runs, in the evaluator's words; falls back to the
  ## setup key rather than guessing.
  if not evaluatorRegistry.hasKey(s.evaluator): return s.key
  let ev = evaluatorRegistry[s.evaluator]
  if ev.setupDoc == nil or s.assertions.len == 0:
    return (if s.key.len > 0: "setup " & s.key else: "")
  try:
    ev.setupDoc(ctx, s.assertions)
  except CatchableError:
    # A third-party description that raises must not break the report.
    (if s.key.len > 0: "setup " & s.key else: "")

proc describeStep*(d: Design, s: PlanStep): string =
  describeStep(newEvalContext(d, allCapabilities), s)

# --- running ------------------------------------------------------------

proc runStep(ctx: EvalContext, step: PlanStep): seq[AssertionResult] =
  ## A misbehaving evaluator (wrong result count, raises) must not take down
  ## the whole run.
  let ev = evaluatorRegistry[step.evaluator]
  var produced: seq[AssertionResult]
  try:
    produced = ev.run(ctx, step.assertions)
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

proc runPlan*(ctx: EvalContext, p: Plan): seq[seq[AssertionResult]] =
  ## One inner `seq` per plan step, in order. `evaluate` flattens it; the
  ## grouping is what lets a report attach assumptions to the run they came
  ## from, and it can't be recovered from a flat list.
  for step in p.steps: result.add runStep(ctx, step)

proc runPlan*(d: Design, p: Plan): seq[seq[AssertionResult]] =
  ## Convenience overload with a fresh context (shares nothing with `plan`).
  runPlan(newEvalContext(d, allCapabilities), p)

proc rejectionResults*(p: Plan): seq[AssertionResult] =
  ## Every rejection, hidden requests included. User-facing flows use
  ## `visibleRejections`.
  for rej in p.rejected:
    result.add AssertionResult(assertion: rej.assertion, status: rej.status,
                               value: NaN, unit: rej.assertion.unit,
                               reason: rej.reason, evaluator: rej.evaluator)

proc visibleRejections*(p: Plan): seq[AssertionResult] =
  ## Authored claims that never reached an evaluator, as results.
  for rej in p.rejected:
    if rej.assertion.id in p.hidden: continue
    result.add AssertionResult(assertion: rej.assertion, status: rej.status,
                               value: NaN, unit: rej.assertion.unit,
                               reason: rej.reason, evaluator: rej.evaluator)

proc relativeResult(a: Assertion, prim, dep: AssertionResult): AssertionResult =
  ## Fold one relative claim from its measurement and reference.
  let e = a.expect

  template refuse(r: AssertionResult, prefix: string): AssertionResult =
    var res = AssertionResult(assertion: a, status: r.status, value: NaN,
      unit: r.unit, reason: prefix & r.reason, evaluator: r.evaluator)
    res.assumptions = r.assumptions
    res.issues = r.issues
    res

  if prim.status notin {esPass, esFail}:
    return refuse(prim, "")
  if dep.status notin {esPass, esFail}:
    return refuse(dep, "the reference measurement '" & e.reference.quantity &
      "' could not be made: ")

  if not unitsAgree(prim.unit, dep.unit):
    result = notEvaluable(a, prim.evaluator,
      "unit mismatch: " & a.quantity & " is measured in " & prim.unit &
      " but its reference " & e.reference.quantity & " in " & dep.unit)
    result.assumptions = prim.assumptions & dep.assumptions
    result.issues = prim.issues & dep.issues
    return

  let bound = e.coeff * dep.value
  let unit = if prim.unit.len > 0: prim.unit else: dep.unit
  let ok = case e.relOp
    of roLe: prim.value <= bound
    of roGe: prim.value >= bound
    of roEq:
      let tol = max(abs(bound) * e.relFracTol, e.relAbsTol)
      prim.value >= bound - tol and prim.value <= bound + tol

  result = AssertionResult(assertion: a, value: prim.value, unit: unit,
    evaluator: prim.evaluator,
    assumptions: prim.assumptions & dep.assumptions,
    issues: prim.issues & dep.issues)
  if ok:
    result.status = esPass
    result.reason = "measured " & eng(prim.value, unit) &
      " (reference " & e.reference.quantity & " = " & eng(dep.value, unit) & ")"
  else:
    result.status = esFail
    result.reason = "measured " & eng(prim.value, unit) & ", expected " &
      relOpText(e.relOp) & " " & eng(bound, unit) &
      " (reference " & e.reference.quantity & " = " & eng(dep.value, unit) & ")"

proc predicateResult(a: Assertion,
                     deps: seq[tuple[name: string, r: AssertionResult]]): AssertionResult =
  ## Fold one predicate claim: gather dependency values in order, run the
  ## proc, report whether it held.
  var values: seq[float]
  var assumptions: seq[Assumption]
  var issues: seq[Issue]
  var evaluator = ""
  var unit = ""

  for (name, r) in deps:
    if r.status notin {esPass, esFail}:
      result = AssertionResult(assertion: a, status: r.status, value: NaN,
        unit: r.unit, evaluator: r.evaluator,
        reason: "dependency '" & name & "' could not be made: " & r.reason)
      result.assumptions = r.assumptions
      result.issues = r.issues
      return
    values.add r.value
    assumptions.add r.assumptions
    issues.add r.issues
    if evaluator.len == 0: evaluator = r.evaluator
    if unit.len == 0 and r.unit.len > 0: unit = r.unit

  var ok = false
  try:
    ok = a.expect.predicate(values)
  except CatchableError as e:
    result = notEvaluated(a, evaluator, "the predicate raised: " & e.msg)
    result.assumptions = assumptions
    result.issues = issues
    return

  result = AssertionResult(assertion: a, status: (if ok: esPass else: esFail),
    value: NaN, unit: unit, evaluator: evaluator,
    reason: (if ok: "predicate held" else: "predicate did not hold"),
    assumptions: assumptions, issues: issues)

proc resolveHidden*(p: Plan, batches: seq[seq[AssertionResult]]): seq[AssertionResult] =
  ## One result per relative/predicate claim, in `p.resolves` order.
  var byId = initTable[string, AssertionResult]()
  for batch in batches:
    for r in batch:
      if r.assertion.id.len > 0: byId[r.assertion.id] = r
  for rej in p.rejected:
    if rej.assertion.id.len > 0:
      byId[rej.assertion.id] = AssertionResult(
        assertion: rej.assertion, status: rej.status, value: NaN,
        unit: rej.assertion.unit, reason: rej.reason, evaluator: rej.evaluator)

  for step in p.resolves:
    var depResults: seq[tuple[name: string, r: AssertionResult]]
    for d in step.deps:
      depResults.add (name: d.name, r: byId.getOrDefault(d.request,
        notEvaluated(step.assertion, "",
          "internal: hidden request '" & d.request & "' produced no result")))
    if step.primary.len > 0:
      let prim = byId.getOrDefault(step.primary,
        notEvaluated(step.assertion, "",
          "internal: hidden request '" & step.primary & "' produced no result"))
      result.add relativeResult(step.assertion, prim, depResults[0].r)
    else:
      result.add predicateResult(step.assertion, depResults)

proc evaluate*(ctx: EvalContext): seq[AssertionResult] =
  ## Every claim checked as far as `ctx.allowed` permits, one result per
  ## authored claim. One context throughout, so steps share `scratch`.
  let p = plan(ctx)
  let batches = runPlan(ctx, p)
  for batch in batches:
    for r in batch:
      if r.assertion.id notin p.hidden: result.add r
  for r in visibleRejections(p): result.add r
  for r in resolveHidden(p, batches): result.add r

proc evaluate*(d: Design, allowed: set[Capability] = offlineCapabilities): seq[AssertionResult] =
  ## Every claim checked as far as `allowed` permits (default: graph walks
  ## only; pass `allCapabilities` and import `contract_eval` to simulate).
  ## A fresh context per call.
  evaluate(newEvalContext(d, allowed))

# --- reading the results ------------------------------------------------

type
  Margin* = object
    ## How much room a checked claim had, computed from `Expectation.bounds`.
    ## Lets a gate see a margin that halved while still passing.
    abs*: float
      ## Distance to the nearest limit, in the measurement's unit. Negative
      ## on failure (not clamped).
    frac*: float
      ## `abs` as a fraction; meaningless unless `hasFrac`.
    hasFrac*: bool
      ## False with no sane denominator (a one-sided limit of exactly zero).
    twoSided*: bool
      ## True when `frac` is of the half-band (`ekNominal` tolerance or
      ## `ekRange`: 1.0 = centre, 0.0 = edge); false for a one-sided limit,
      ## where it has no ceiling.

proc marginOf*(r: AssertionResult): Option[Margin] =
  ## `none` when nothing was measured, or for `ekRelative`/`ekPredicate`
  ## (limit is another measurement).
  if r.status notin {esPass, esFail}: return none(Margin)
  let e = r.assertion.expect
  if e.kind in {ekRelative, ekPredicate}: return none(Margin)
  let (lo, hi) = e.bounds
  var m: Margin
  case e.kind
  of ekNominal, ekRange:
    m.twoSided = true
    m.abs = min(r.value - lo, hi - r.value)
    let half = (hi - lo) / 2.0
    # `ekNominal` with no tolerance has `lo == hi`: no band to divide by.
    if half != 0.0:
      m.frac = m.abs / half
      m.hasFrac = true
  of ekMin:
    m.abs = r.value - lo
    if lo != 0.0:
      m.frac = m.abs / abs(lo)
      m.hasFrac = true
  of ekMax:
    m.abs = hi - r.value
    if hi != 0.0:
      m.frac = m.abs / abs(hi)
      m.hasFrac = true
  of ekRelative, ekPredicate:
    return none(Margin)  # unreachable; excluded above, kept for the compiler
  some(m)

proc count*(results: seq[AssertionResult], status: EvalStatus): int =
  for r in results:
    if r.status == status: inc result

proc failed*(results: seq[AssertionResult]): seq[AssertionResult] =
  for r in results:
    if r.status == esFail: result.add r

proc unchecked*(results: seq[AssertionResult]): seq[AssertionResult] =
  ## Everything nobody verified. Unchecked claims are not passes.
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
