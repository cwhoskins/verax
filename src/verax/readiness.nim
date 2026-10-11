## Checking a design: `readiness` runs the structural validators and the
## contract plan and returns everything found, unrendered. Split out of
## `verify` so both `verify` (text/JSON/JUnit) and `report` (the HTML test
## report) sit above it; `verify` re-exports it.
##
## **A `Readiness` never holds an `AnalysisReport`** -- curves reach a report
## only through the `spice/ngspice` run observer (see `report/collect`).

import std/[algorithm, editdistance, os, osproc, sets, strutils, tables]

import ./eng
import ./netlist/types
import ./netlist/annotations
import ./netlist/environment
import ./netlist/packages
import ./netlist/bomdefaults
import ./netlist/interfaces
import ./netlist/pinmux
import ./netlist/layouthints
import ./netlist/traversal
import ./analysis/io_check
import ./analysis/evaluators/contract_eval
import ./pcb/types as pcbtypes

export contract_eval, io_check, environment

type
  Check* = object
    ## One *test*: a single analysis run, what it rests on, and every claim
    ## it answered (a plan step, seen after running).
    evaluator*: string
    needs*: set[Capability]
    key*: string
      ## The setup key that grouped this batch; `setup` is the readable form.
    setup*: string
      ## What actually ran, in the evaluator's own words.
    results*: seq[AssertionResult]
    assumptions*: seq[Assumption]
      ## Deduplicated; only what nobody stated (`annAuthored` is excluded).
    step*: int
      ## Index into `Readiness.plan.steps` (checks with no visible result are
      ## dropped, so this is not the check's own index).

  Readiness* = object
    ## Everything one run of a design's contract found out.
    design*: string
    requested*: set[Capability]
      ## What the caller offered.
    available*: set[Capability]
      ## What this machine can do. `requested - available` is reported as an
      ## environment problem, not degraded silently.
    simulator*: string
      ## Version line of the backing simulator, or "" if there is none.
    environment*: Environment
      ## The stated operating conditions, echoed back. Nothing is
      ## temperature-dependent yet.
    hottest*: string
      ## The hottest part at top-of-range ambient, pre-rendered; "" when no
      ## rise is stated.
    structural*: seq[Issue]
      ## Annotation-vocabulary and static IO findings, reported first (a
      ## misspelled `esr` invalidates every impedance number).
    plan*: Plan
      ## The plan, kept after running: steps vs. assertions shows claims are
      ## batched.
    checks*: seq[Check]
      ## Steps with their results, in plan order. A step that only measured a
      ## relative claim's reference is folded into that claim.
    rejected*: seq[AssertionResult]
      ## Claims no step could take (no producer, wrong subject shape,
      ## capability withheld). No test ran for them.
    results*: seq[AssertionResult]
      ## Every result flat, `checks` then `rejected`, as `evaluate` would
      ## return them (for `summary`, `failed`, `invented`).

const
  exitClean* = 0
  exitFailed* = 1
    ## At least one assertion was checked and did not hold.
  exitStructural* = 2
    ## The netlist is wrong in a way that makes claims untrustworthy.
  exitUnchecked* = 3
    ## Nothing can produce some claimed quantity. Non-zero on purpose.
  exitEnvironment* = 4
    ## A capability was requested that this machine cannot provide.
  exitCompile* = 5
    ## The design file did not compile (`verax check` only). Separate so a
    ## syntax error isn't mistaken for a circuit problem.

# --- what this machine can do -------------------------------------------

proc ngspiceVersion*(exe = "ngspice"): string =
  ## The installed simulator's version, or "" when none is on `PATH`. An
  ## unparseable banner reports the executable, not absence.
  if findExe(exe).len == 0: return ""
  try:
    let (outp, _) = execCmdEx(exe & " -v")
    for line in outp.splitLines():
      let i = line.find("ngspice-")
      if i >= 0:
        var j = i + len("ngspice-")
        while j < line.len and line[j] in Digits: inc j
        return line[i ..< j]
  except OSError, IOError:
    discard
  exe

proc availableCapabilities*(simulator = ""): set[Capability] =
  ## `capBench` is never included: nothing takes bench measurements, and
  ## offering it would turn "not offered" into "ran and produced nothing".
  result = {capStatic, capSiTran}   # the SI engine is native: always here
  let sim = if simulator.len > 0: simulator else: ngspiceVersion()
  if sim.len > 0:
    result = result + simCapabilities

proc claimLabel*(a: Assertion): string =
  ## The claim's id, or its quantity when it has none.
  if a.id.len > 0: a.id else: a.quantity

proc claimLint*(results: seq[AssertionResult]): seq[Issue] =
  ## Claims with no stated unit where the quantity has one. `unitsAgree`
  ## treats "" as unchecked, so `overshoot_pct <= 5.pct` compares 5.0 (in
  ## "%") with 0.05 and is wrong by 100 with no mismatch reported. The unit
  ## is the producer's **declared** one (`Evaluator.units`), so a claim is
  ## flagged whether or not it ran; for an evaluator that declares none, the
  ## unit actually measured.
  for r in results:
    if r.assertion.expect.kind in {ekRelative, ekPredicate}: continue
    if r.assertion.unit.len > 0: continue
    let declared = declaredUnit(r.assertion.quantity)
    let unit =
      if declared.isSome: declared.get
      elif r.status in {esPass, esFail}: r.unit
      else: ""
    if unit.len == 0: continue
    result.add newIssue("claim_unit_unstated", sevWarning,
      "claim '" & claimLabel(r.assertion) & "' states no unit, but " &
      r.assertion.quantity & " is measured in " & unit &
      ". The comparison " & (if r.status in {esPass, esFail}: "went ahead"
                             else: "would go ahead") & " unchecked. If the " &
      "limit came from a Fraction literal such as 5.pct, it is 0.05 where " &
      "the measurement is 5.0 -- a factor of a hundred.")

# --- running -------------------------------------------------------------

proc readiness*(d: Design, allowed = allCapabilities, board: Pcb = nil,
                onStep: proc (index: int, starting: bool) {.closure.} = nil):
                Readiness =
  ## Check a design as far as `allowed` and this machine permit. Does not
  ## mutate `d`. `board`, when given, reaches evaluators as
  ## `scratch[boardScratchKey]` (the SI evaluator reads it).
  result.design = if d.netlist.name.len > 0: d.netlist.name else: "(unnamed)"
  result.requested = allowed
  result.simulator = ngspiceVersion()
  result.available = availableCapabilities(result.simulator)

  result.structural = validateAnnotations(d.netlist)
  for i in analyzeIO(d.netlist): result.structural.add i
  for i in validateEnvironment(d.netlist): result.structural.add i
  for i in validatePackages(d.netlist): result.structural.add i
  for i in validateBomDefaults(d.netlist): result.structural.add i
  for i in validateInterfaces(d.netlist): result.structural.add i
  for i in validatePinmux(d.netlist): result.structural.add i
  for i in validateLayoutHints(d.netlist): result.structural.add i
  for i in validateTraversal(d.netlist): result.structural.add i

  result.environment = environmentOf(d.netlist)
  result.hottest = describeHottest(d.netlist, result.environment)

  let usable = allowed * result.available
  # One context per run: simulated evaluators share an operating point
  # through `EvalContext.scratch`, and nothing cached outlives this call.
  let ctx = newEvalContext(d, usable)
  ctx.onStep = onStep
  if board != nil: ctx.scratch[boardScratchKey] = BoardRef(pcb: board)
  result.plan = plan(ctx)
  let batches = runPlan(ctx, result.plan)

  # Run through the plan rather than `evaluate` to keep the per-run grouping.
  # Hidden requests from relative/predicate claims run in the same steps but
  # are filtered out; the authored claim they feed is attached to the run
  # that measured it.
  var stepOf = initTable[string, int]()
  for i, step in result.plan.steps:
    for a in step.assertions:
      if a.id in result.plan.hidden: stepOf[a.id] = i

  var checks: seq[Check]
  checks.setLen(result.plan.steps.len)
  for i, step in result.plan.steps:
    var c = Check(evaluator: step.evaluator, needs: step.needs, key: step.key,
                  setup: describeStep(ctx, step), step: i)
    for r in batches[i]:
      if r.assertion.id notin result.plan.hidden: c.results.add r
    checks[i] = c

  result.rejected = visibleRejections(result.plan)

  let resolved = resolveHidden(result.plan, batches)
  for j, r in resolved:
    let rs = result.plan.resolves[j]
    let anchor = if rs.primary.len > 0: rs.primary else: rs.deps[0].request
    if stepOf.hasKey(anchor):
      checks[stepOf[anchor]].results.add r
    else:
      # The anchor was rejected at plan time, so the folded claim is too.
      result.rejected.add r

  for c in checks:
    if c.results.len == 0: continue   # a run that only fed another claim
    var kept = c
    var seen = initHashSet[string]()
    for r in kept.results:
      for a in r.assumptions:
        if a.source == annAuthored: continue
        let text = $a
        if text in seen: continue
        seen.incl text
        kept.assumptions.add a
    result.checks.add kept
    for r in kept.results: result.results.add r
  for r in result.rejected: result.results.add r

  for i in claimLint(result.results): result.structural.add i

proc missing*(r: Readiness): set[Capability] {.inline.} =
  r.requested - r.available

proc exitCode*(r: Readiness, strict = false): int =
  ## Graded, most fundamental first: unavailable capability, broken netlist,
  ## failed assertion, unevaluable claim. `esNotEvaluated` alone is clean
  ## (withholding a capability is deliberate) unless `strict`.
  if r.missing.len > 0: return exitEnvironment
  for i in r.structural:
    if i.severity == sevError or (strict and i.severity == sevWarning):
      return exitStructural
  if count(r.results, esFail) > 0: return exitFailed
  if count(r.results, esNotEvaluable) > 0: return exitUnchecked
  if strict and count(r.results, esNotEvaluated) > 0: return exitUnchecked
  exitClean

proc exitLabel*(code: int): string =
  case code
  of exitClean: "clean"
  of exitFailed: "assertion failure"
  of exitStructural: "structural problem"
  of exitUnchecked: "unchecked claims"
  of exitEnvironment: "capability unavailable"
  of exitCompile: "design did not compile"
  else: "unknown"

# --- shared wording ----------------------------------------------------

proc capList*(s: set[Capability]): string =
  ## A capability set as the labels a designer reads, shared by the report
  ## and `verax env`.
  var parts: seq[string]
  for c in s: parts.add capLabel(c)
  if parts.len == 0: "none" else: parts.join(", ")

proc sevLabel*(s: Severity): string =
  case s
  of sevInfo: "info"
  of sevWarning: "warning"
  of sevError: "error"

proc statusJsonName*(s: EvalStatus): string =
  ## The snake_case status spelling shared by `--format=json`,
  ## `loadBaseline` and `baselineDiff`.
  case s
  of esPass: "pass"
  of esFail: "fail"
  of esNotEvaluated: "not_evaluated"
  of esNotEvaluable: "not_evaluable"

proc didYouMean*(quantity: string, limit = 3): seq[string] =
  ## The registered quantities closest to one nothing produces, since a
  ## misspelling is the likeliest cause.
  let budget = max(3, quantity.len div 2)
  var scored: seq[(int, string)]
  for q in evaluableQuantities():
    let dist = editDistance(quantity, q)
    if dist <= budget: scored.add (dist, q)
  scored.sort()
  for i in 0 ..< min(limit, scored.len): result.add scored[i][1]

proc foldAssumptions*(assumptions: seq[Assumption]): seq[string] =
  ## One line per distinct assumption, naming every part it was made about.
  ## Producers emit one record per component; folding on `(key, value, unit,
  ## detail)` loses nothing and avoids walls of repetition.
  var order: seq[string]
  var entities = initTable[string, seq[string]]()
  var first = initTable[string, Assumption]()
  for a in assumptions:
    let sig = a.key & "\x1f" & $a.value & "\x1f" & a.unit & "\x1f" & a.detail
    if sig notin entities:
      order.add sig
      entities[sig] = @[]
      first[sig] = a
    if a.entity.len > 0 and a.entity notin entities[sig]:
      entities[sig].add a.entity
  for sig in order:
    let a = first[sig]
    # A narrative assumption has no key or magnitude; its `detail` is a
    # whole sentence. It still folds when it names a part.
    var body = a.detail
    if a.key.len > 0:
      body = a.key & " " & eng(a.value, a.unit) &
             (if a.detail.len > 0: " " & a.detail else: "")
    result.add (if entities[sig].len == 0: body
                else: entities[sig].join(", ") & ": " & body)

proc statusMark*(st: EvalStatus): string =
  ## Four characters, fixed width. `----`/`????` match `$AssertionResult`
  ## and read as absence rather than as verdicts.
  case st
  of esPass: "PASS"
  of esFail: "FAIL"
  of esNotEvaluated: "----"
  of esNotEvaluable: "????"

proc marginText*(r: AssertionResult, m: Margin): string =
  ## Puts `marginOf` into words. A two-sided band reads as a fraction of
  ## itself (1.0 = centre, 0.0 = edge); a one-sided limit leads with absolute
  ## headroom, fraction in parentheses.
  if m.twoSided:
    if m.hasFrac: "margin " & eng(m.frac * 100.0) & "% of band"
    else: "margin " & eng(m.abs, r.unit) & " of band"
  else:
    let side = if r.assertion.expect.kind == ekMin: "over the minimum"
               else: "under the maximum"
    if m.hasFrac:
      "margin " & eng(m.abs, r.unit) & " (" & eng(m.frac * 100.0) & "% " &
      side & ")"
    else:
      "margin " & eng(m.abs, r.unit)
