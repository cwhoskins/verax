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

  EvalContext* = ref object
    ## Everything one evaluation run may see, and the **only** argument an
    ## evaluator receives.
    ##
    ## This exists because `EvalProc` is the plugin ABI. An evaluator loaded
    ## at runtime compiles against that signature, so anything an evaluator
    ## might ever need has to be reachable through it -- and a `Design` alone
    ## is not enough. Three things already arrived by side doors before this
    ## type existed: a shared operating point lived in a module-level `var`
    ## (so two designs checked in one process shared one slot, and an edited
    ## design silently kept a stale answer), the offered capabilities were
    ## known to the planner and not to the evaluator, and a `Pcb` or a bench
    ## reading had no route in at all. Widening the argument once is cheap;
    ## widening it after a third party has compiled against it is not.
    design*: Design
    allowed*: set[Capability]
      ## What this run may actually do. The planner has already refused any
      ## assertion whose evaluator needs more than this, so an evaluator sees
      ## it only to decide how far to go *within* what it was granted --
      ## refining a result with an extra analysis when one is offered, and
      ## saying so rather than silently skipping it when it is not.
    scratch*: Table[string, RootRef]
      ## Per-run storage, owned by whoever puts something in it, keyed by a
      ## dotted name the owner picks (`"spice.operating_point"`).
      ##
      ## Deliberately type-erased, and that is the whole point: `contract`
      ## must not gain an edge to `analysis` or to `pcb`, so it cannot name
      ## an `OperatingPoint` or a `Pcb` in a field. A module that owns such a
      ## type declares `ref object of RootObj`, stashes it here, and downcasts
      ## on the way out. That keeps the layering intact *and* keeps this type
      ## from having to change again every time something new needs carrying.
      ##
      ## Lifetime is one run. A cache in here cannot go stale against an
      ## edited design, because there is no run during which the design
      ## changes -- which is what the previous module-level cache could not
      ## promise and documented a rule about instead.

  EvalProc* = proc (ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] {.nimcall.}
    ## Takes every assertion routed to this evaluator that shares a setup key,
    ## and must return one result per assertion in the batch.
  SetupKeyProc* = proc (ctx: EvalContext, a: Assertion): string {.nimcall.}
    ## Two assertions with the same key can be answered by one run. `nil`
    ## means "the subject names", which is the right default for anything
    ## measured per-net.
  SetupDocProc* = proc (ctx: EvalContext, batch: seq[Assertion]): string {.nimcall.}
    ## What this run actually *is*, in one sentence, given the batch routed
    ## to it. A proc on the data object for the same reason `run` and
    ## `setupKey` are: an evaluator registered at runtime must be able to
    ## describe itself exactly as a built-in does.

  Evaluator* = object
    name*: string
    produces*: seq[string]
      ## Quantity names, matching `analysis/report.Measurement.name`.
    needs*: set[Capability]
      ## Every capability a run of this evaluator actually uses -- not the
      ## headline one.
      ##
      ## A set rather than a scalar because more than one built-in genuinely
      ## needs two, and while this was a single `Capability` they had no way
      ## to say so: `spice.pdn` declared `.ac` and solved an operating point
      ## for its bias derating, and `spice.large_signal` declared `.tran` and
      ## solved one to find the bias its stimulus sits on. Both ran an
      ## analysis that `--caps` had withheld. Under-declaring is invisible
      ## while every capability happens to be available and becomes a wrong
      ## answer the moment one is not -- which is exactly the case a bench
      ## host, or `--caps=ac`, is.
      ##
      ## Empty means `{capStatic}`; `registerEvaluator` normalises it.
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
    setupDoc*: SetupDocProc
      ## Renders the run for a reader: `"one .op solve of the whole design"`,
      ## `"an .ac sweep of net 'vdd', 1 A injected"`.
      ##
      ## The setup key exists to *group*, not to be read -- `vdd|100000.0|
      ## 100000000.0` and `U1|vdda` are correct keys and say nothing about
      ## what was simulated. A report that names the evaluator and the key is
      ## naming the machinery; a reader needs to know which analysis produced
      ## the number they are about to trust, because that is what says what
      ## the number does and does not cover. `nil` falls back to the key.
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

  Plan* = object
    ## What *would* run. Separated from running it because an assertion set
    ## you cannot inspect before it executes is the same failure mode
    ## `design.explain` exists to prevent.
    steps*: seq[PlanStep]
    rejected*: seq[Rejection]

proc capLabel*(c: Capability): string =
  ## Short form, shared by every renderer so one capability never appears
  ## under two names. `$capSpiceOp` is the enum identifier, which is right in
  ## a stack trace and wrong in a sentence a designer reads.
  case c
  of capStatic: "static"
  of capSpiceOp: ".op"
  of capSpiceAc: ".ac"
  of capSpiceTran: ".tran"
  of capBench: "bench"

proc capLabel*(s: set[Capability]): string =
  ## The set form, so a requirement of two capabilities is never rendered as
  ## the enum's `{capSpiceOp, capSpiceAc}` in a sentence a designer reads.
  var parts: seq[string]
  for c in s: parts.add capLabel(c)
  if parts.len == 0: "none" else: parts.join(" + ")

proc newEvalContext*(d: Design, allowed = offlineCapabilities): EvalContext =
  ## One context per run. Callers that hold one across `plan`, `runPlan` and
  ## `describeStep` get the sharing this type exists for; callers that build
  ## one per call get isolation, which is what a sweep over many candidate
  ## designs wants.
  EvalContext(design: d, allowed: allowed)

# --- registry ----------------------------------------------------------

var evaluatorRegistry: OrderedTable[string, Evaluator]
var quantityIndex: Table[string, string]  ## quantity -> evaluator name

proc registerEvaluator*(ev: Evaluator) =
  ## Registering an evaluator under a name already taken replaces it, exactly
  ## as `registerRole` replaces a role -- that is how an application overrides
  ## a built-in with something better suited to its own designs.
  ##
  ## Claiming a quantity a **different** evaluator already produces raises.
  ## `quantityIndex` is a flat map, so the second registration would silently
  ## take over every claim on that quantity in every design: an assertion that
  ## was answered by a `.ac` sweep would start being answered by something
  ## else, with no diagnostic anywhere and the same quantity name in the
  ## report either way. An override says so by keeping the name; a collision
  ## is an accident, and the two are indistinguishable once it has happened.
  if ev.name.len == 0:
    raise newException(NetlistError, "evaluator name must not be empty")
  if ev.run == nil:
    raise newException(NetlistError, "evaluator '" & ev.name & "' has no run proc")
  if ev.produces.len == 0:
    raise newException(NetlistError,
      "evaluator '" & ev.name & "' produces no quantities")

  var it = ev
  if it.arity.a == 0 and it.arity.b == 0: it.arity = 1 .. int.high
  # An evaluator that declares nothing is a graph walk. Left as the empty
  # set it would pass `<= allowed` against *any* offer, including `--offline`,
  # which would make an omitted declaration mean "runs everywhere" -- the one
  # reading a defaulted field must never have.
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

proc plan*(ctx: EvalContext): Plan =
  ## Routes every assertion in the design -- authored and role-expanded alike
  ## -- to an evaluator, grouping into one step per `(evaluator, setup key)`.
  ##
  ## Pure: nothing runs, nothing is simulated, and the design is not touched.
  let d = ctx.design
  let allowed = ctx.allowed
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

    let missing = ev.needs - allowed
    if missing.len > 0:
      result.rejected.add Rejection(assertion: a, status: esNotEvaluated,
        evaluator: ev.name,
        reason: "needs the " & capLabel(missing) &
                (if missing.len > 1: " capabilities, which were not offered"
                 else: " capability, which was not offered"))
      continue

    let key = if ev.setupKey != nil: ev.setupKey(ctx, a) else: defaultKey(a)
    let slot = ev.name & "\x1f" & key
    if not stepIndex.hasKey(slot):
      stepIndex[slot] = result.steps.len
      result.steps.add PlanStep(evaluator: ev.name, key: key, needs: ev.needs)
    result.steps[stepIndex[slot]].assertions.add a

proc plan*(d: Design, allowed: set[Capability] = offlineCapabilities): Plan =
  ## Convenience for a caller that does not need to hold a context. Note that
  ## nothing is shared with a later `runPlan(d, ...)`: pass one `EvalContext`
  ## to both to share an operating point across the whole run.
  plan(newEvalContext(d, allowed))

proc assertionCount*(p: Plan): int =
  for s in p.steps: result += s.assertions.len
  result += p.rejected.len

proc explainPlan*(p: Plan): string =
  var lines: seq[string]
  lines.add "plan: " & $p.steps.len & " step(s), " &
            $assertionCount(p) & " assertion(s)"
  for s in p.steps:
    lines.add "  " & s.evaluator & " [" & capLabel(s.needs) & "]" &
              (if s.key.len > 0: " on " & s.key else: "") &
              " -- " & $s.assertions.len & " assertion(s)"
    for a in s.assertions:
      lines.add "      " & (if a.id.len > 0: a.id else: a.quantity)
  for r in p.rejected:
    lines.add "  (" & $r.status & ") " &
              (if r.assertion.id.len > 0: r.assertion.id else: r.assertion.quantity) &
              " -- " & r.reason
  lines.join("\n")

proc describeStep*(ctx: EvalContext, s: PlanStep): string =
  ## What one plan step will run, in the evaluator's own words.
  ##
  ## Falls back to the setup key, which is honest rather than helpful: an
  ## evaluator that has not said what it does is better reported as opaque
  ## than described by a guess made out here, where nothing knows what the
  ## key's fields mean.
  if not evaluatorRegistry.hasKey(s.evaluator): return s.key
  let ev = evaluatorRegistry[s.evaluator]
  if ev.setupDoc == nil or s.assertions.len == 0:
    return (if s.key.len > 0: "setup " & s.key else: "")
  try:
    ev.setupDoc(ctx, s.assertions)
  except CatchableError:
    # A third-party evaluator whose description raises must not take down a
    # report about its own results, exactly as `previewRole` refuses to let a
    # bad expander make `nimcir roles` unusable.
    (if s.key.len > 0: "setup " & s.key else: "")

proc describeStep*(d: Design, s: PlanStep): string =
  describeStep(newEvalContext(d, allCapabilities), s)

# --- running ------------------------------------------------------------

proc runStep(ctx: EvalContext, step: PlanStep): seq[AssertionResult] =
  ## An evaluator that returns the wrong number of results, or raises, is a
  ## bug in the evaluator -- but it must not take down a whole run, because
  ## then one bad plugin costs every other verdict in the design.
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
  ## One inner `seq` per plan step, in step order.
  ##
  ## `evaluate` flattens this and is what most callers want. Keeping the
  ## grouping is what lets a report say *which run* produced a number and
  ## what that run rested on: an assumption is attached to every result in a
  ## batch, so a flat list of results cannot tell "the op-amp macromodel this
  ## sweep substituted" from "an assumption that happens to be in the pile".
  ## Recovering the grouping afterwards is not possible either -- a result
  ## carries its evaluator's name but not its setup key, and two steps of one
  ## evaluator are two different runs.
  for step in p.steps: result.add runStep(ctx, step)

proc runPlan*(d: Design, p: Plan): seq[seq[AssertionResult]] =
  ## Convenience overload. Builds a fresh context, so nothing is shared with
  ## the `plan` call that produced `p`.
  runPlan(newEvalContext(d, allCapabilities), p)

proc rejectionResults*(p: Plan): seq[AssertionResult] =
  ## The claims that never reached an evaluator, as results, so a caller
  ## handles one kind of thing.
  for rej in p.rejected:
    result.add AssertionResult(assertion: rej.assertion, status: rej.status,
                               value: NaN, unit: rej.assertion.unit,
                               reason: rej.reason, evaluator: rej.evaluator)

proc evaluate*(ctx: EvalContext): seq[AssertionResult] =
  ## Every claim this design makes, checked as far as `ctx.allowed` permits.
  ##
  ## One context throughout, so every step of the run shares whatever the
  ## first one put in `scratch` -- which is what makes "one `.op` per design"
  ## a property of the run rather than of a module-level cache.
  let p = plan(ctx)
  for batch in runPlan(ctx, p):
    for r in batch: result.add r
  for r in rejectionResults(p): result.add r

proc evaluate*(d: Design, allowed: set[Capability] = offlineCapabilities): seq[AssertionResult] =
  ## Every claim this design makes, checked as far as `allowed` permits.
  ##
  ## The default offers nothing but graph walks, mirroring how
  ## `nimcir/analysis` exports only what runs with no external toolchain: pass
  ## `allCapabilities` (and import `nimcir/analysis/contract_eval`) to let the
  ## simulation-backed evaluators run.
  ##
  ## Each call builds its own context, so a caller sweeping many candidate
  ## designs through this gets a clean cache every time by construction.
  evaluate(newEvalContext(d, allowed))

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
