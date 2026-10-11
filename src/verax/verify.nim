## Running a design's contract, and saying plainly what was *not* checked:
## the runner behind `verax check` and a design file's last line.
##
## At the package root because it needs `contract`, `analysis` and
## `netlist/annotations` at once, and `contract` must never depend on
## `analysis`.
##
## **It imports `analysis/contract_eval` unconditionally.** Without it a valid
## claim reports `no evaluator produces 'z_max_in_band'` (false -- the
## registering module just wasn't imported) and a reader deletes it. Gating on
## capabilities instead gives `requires capSpiceAc, which was not offered`.
##
## The report centres on `NOT CHECKED`, not pass/fail: an unevaluated claim is
## not a passing one.
##
## **The body is one block per test** (one analysis run), so a reader sees
## which claims one run answered, what it was, and which assumptions moved
## which numbers. `readiness` therefore uses `runPlan`, not `evaluate`: a
## result carries its evaluator but not its setup key, so the grouping can't
## be recovered afterwards.

import std/[algorithm, editdistance, json, math, os, osproc, sets, strutils,
            tables, wordwrap, xmltree]

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
import ./schematic
import ./run_archive
import ./analysis/io_check
import ./analysis/evaluators/contract_eval
import ./pcb/units
import ./pcb/assemble
# Registers the KiCad `FootprintSource`; without it `verax layout` reports
# every part `footprint_unresolved`.
import ./pcb/formats/kicadmod
# `verax bom`. No catalogue registers by default; only files named by
# `--bom-catalog=` or `$VERAX_BOM_CATALOG` are read.
import ./bom
import ./bom/sources/local
# `--board=` (findings §18: a board reaching evaluators through
# `EvalContext.scratch`) and `verax constraints`.
import ./pcb/types as pcbtypes
import ./pcb/formats/kicad as kicadfmt
import ./analysis/analyses/si as sianalysis

export contract_eval, io_check, environment, assemble, kicadmod

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

type
  ReportFormat* = enum
    ## `rfText` for humans; `rfJson`/`rfJunit` for CI.
    rfText, rfJson, rfJunit

  BomFormat* = enum
    ## `verax bom` output; JSON doubles as the next run's `--bom-lock`.
    bfText, bfCsv, bfJson

  BaselineEntry* = object
    ## One result read back from a previous `--format=json` run: only
    ## `status`, `value`, `unit`.
    value*: float
    unit*: string
    status*: string

  BaselineChange* = object
    ## What differs about one claim between a baseline and this run; one
    ## record per id, since a status and a value can move together.
    id*: string
    isNew*: bool
      ## This id was not in the baseline at all.
    isGone*: bool
      ## This id was in the baseline and is not among this run's results.
    statusChanged*: bool
    regressed*: bool
      ## `pass -> fail`, or checked -> unchecked: shown first. The reverse
      ## motion uses the same fields.
    fromStatus*, toStatus*: string
    valueChanged*: bool
      ## Set when the relative change exceeds 1e-6, or the prior value was
      ## zero and the new one isn't. Never set when units differ.
    fromValue*, toValue*: float
    unitChanged*: bool
      ## The unit itself changed; reported, never differenced numerically.
    fromUnit*, toUnit*: string

  BaselineError* = object of CatchableError
    ## Raised by `loadBaseline` on anything but a readable `--format=json`
    ## document. `verify` turns it into `exitCompile`, never a silently
    ## skipped comparison.

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

proc label(a: Assertion): string =
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
      "claim '" & label(r.assertion) & "' states no unit, but " &
      r.assertion.quantity & " is measured in " & unit &
      ". The comparison " & (if r.status in {esPass, esFail}: "went ahead"
                             else: "would go ahead") & " unchecked. If the " &
      "limit came from a Fraction literal such as 5.pct, it is 0.05 where " &
      "the measurement is 5.0 -- a factor of a hundred.")

proc previewRole*(def: RoleDef,
                  params: openArray[(string, string)] = []): seq[Assertion] =
  ## What a role would claim, with placeholder bindings. Safe because
  ## `expand` never touches a netlist; an expander that raises yields
  ## nothing, so a bad third-party role can't break `verax roles`.
  var inst = RoleInstance(role: def.name, name: "<preview>")
  for p in def.parts:
    inst.bindings[p.name] = Subject(kind: p.kind, name: "<" & p.name & ">")
  for pair in params: inst.params[pair[0]] = pair[1]
  try:
    def.expand(inst)
  except CatchableError:
    @[]

proc previewRoleDelta*(def: RoleDef, param: string): seq[Assertion] =
  ## The claims stating `param` adds, found by diffing two expansions.
  var seen: seq[string]
  for a in previewRole(def): seen.add a.id
  for a in previewRole(def, [(param, "1")]):
    if a.id notin seen: result.add a

# --- running -------------------------------------------------------------

proc readiness*(d: Design, allowed = allCapabilities, board: Pcb = nil): Readiness =
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
                  setup: describeStep(ctx, step))
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

# --- rendering -----------------------------------------------------------

proc capList*(s: set[Capability]): string =
  ## A capability set as the labels a designer reads, shared by the report
  ## and `verax env`.
  var parts: seq[string]
  for c in s: parts.add capLabel(c)
  if parts.len == 0: "none" else: parts.join(", ")

proc sevLabel(s: Severity): string =
  case s
  of sevInfo: "info"
  of sevWarning: "warning"
  of sevError: "error"

proc statusJsonName(s: EvalStatus): string =
  ## The snake_case status spelling shared by `--format=json`,
  ## `loadBaseline` and `baselineDiff`.
  case s
  of esPass: "pass"
  of esFail: "fail"
  of esNotEvaluated: "not_evaluated"
  of esNotEvaluable: "not_evaluable"

proc annSourceName(s: AnnSource): string =
  case s
  of annAbsent: "absent"
  of annAuthored: "authored"
  of annImported: "imported"
  of annDefaulted: "defaulted"
  of annDerived: "derived"

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

proc indented(text: string, prefix: string, hang = "",
              width = 74): seq[string] =
  ## Wrapped, with an optional deeper indent on continuation lines.
  let cont = if hang.len > 0: hang else: prefix
  var first = true
  for line in wrapWords(text, width).splitLines():
    result.add (if first: prefix else: cont) & line
    first = false

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

proc statusMark(st: EvalStatus): string =
  ## Four characters, fixed width. `----`/`????` match `$AssertionResult`
  ## and read as absence rather than as verdicts.
  case st
  of esPass: "PASS"
  of esFail: "FAIL"
  of esNotEvaluated: "----"
  of esNotEvaluable: "????"

proc marginText(r: AssertionResult, m: Margin): string =
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

proc renderClaim(L: var seq[string], r: AssertionResult, indent: string,
                 verbose: bool) =
  ## One claim as a comparison: expected and measured on one line, with the
  ## band or drive level on the heading line.
  var head = indent & "[" & statusMark(r.status) & "]  " & label(r.assertion)
  if r.assertion.expect.kind == ekPredicate:
    head &= "   predicate"
  else:
    var subj: seq[string]
    for sub in r.assertion.subjects: subj.add $sub
    head &= "   " & r.assertion.quantity & "(" & subj.join(", ") & ")"
  let conds = conditionText(r.assertion)
  if conds.len > 0: head &= "   " & conds
  L.add head

  let deep = indent & "         "
  var cmpLine = "expect " & `$`(r.assertion.expect, r.assertion.unit)
  let interval = acceptance(r.assertion)
  if interval.len > 0: cmpLine &= " (" & interval & ")"
  case r.status
  of esPass, esFail:
    if r.assertion.expect.kind in {ekRelative, ekPredicate}:
      # The referenced values are in `reason`; there's no single number.
      cmpLine &= "   " & r.reason
    else:
      cmpLine &= "   measured " & eng(r.value, r.unit)
      # `reason` may name where the value was measured (`inrush_peak` is read
      # on the rail being charged).
      let at = r.reason.find(" at ")
      if at >= 0: cmpLine &= r.reason[at .. ^1]
      let m = marginOf(r)
      if m.isSome: cmpLine &= "   " & marginText(r, m.get)
  of esNotEvaluated, esNotEvaluable:
    cmpLine &= "   not measured"
  for line in indented(cmpLine, deep, deep & "  "): L.add line

  if r.status in {esNotEvaluated, esNotEvaluable} and r.reason.len > 0:
    for line in indented(r.reason, deep, deep & "  "): L.add line

  # Rationale: always when not passing, on request otherwise.
  if r.assertion.rationale.len > 0 and (verbose or r.status != esPass):
    for line in indented("because " & r.assertion.rationale, deep,
                         deep & "  "): L.add line

proc renderResult(L: var seq[string], r: AssertionResult,
                  seenIssues: var HashSet[string]) =
  ## One claim in a status section, rendered like the check block (via
  ## `renderClaim`) so both spell the limit the same way.
  renderClaim(L, r, "  ", verbose = true)

  # An analysis that couldn't answer usually explains why in an `Issue`, not
  # in `verdict`'s generic `reason`, so print the issues too. Deduplicated
  # across the report, since one batched run attaches them to every claim.
  for i in r.issues:
    if i.message in seenIssues: continue
    seenIssues.incl i.message
    L.add "           [" & sevLabel(i.severity) & "] " & i.kind
    for line in indented(i.message, "             "): L.add line

proc renderChecks(L: var seq[string], r: Readiness, verbose: bool) =
  ## The body of the report: one block per test.
  var walks, sims = 0
  for c in r.checks:
    if c.needs <= {capStatic}: inc walks else: inc sims

  var assumed = initHashSet[string]()
  for a in invented(r.results): assumed.incl $a

  var head = "CHECKS  " & $r.checks.len & " test(s)"
  if r.checks.len > 0:
    head &= " -- " & $walks & " graph walk(s), " & $sims & " simulation run(s)"
  head &= ", " & $assertionCount(r.plan) & " claim(s)"
  if assumed.len > 0: head &= ", " & $assumed.len & " assumed value(s)"
  L.add head
  if r.checks.len > 0:
    L.add "        [PASS] met   [FAIL] missed   " &
          "[----] no result came back   [????] nothing could check it"

  for c in r.checks:
    var tally: array[EvalStatus, int]
    for res in c.results: inc tally[res.status]
    var counts: seq[string]
    if tally[esPass] > 0: counts.add $tally[esPass] & " met"
    if tally[esFail] > 0: counts.add $tally[esFail] & " missed"
    if tally[esNotEvaluated] > 0: counts.add $tally[esNotEvaluated] & " no result"
    if tally[esNotEvaluable] > 0: counts.add $tally[esNotEvaluable] & " uncheckable"

    L.add ""
    L.add "  " & c.evaluator & "  [" & capLabel(c.needs) & "]  --  " &
          $c.results.len & " claim(s): " & counts.join(", ")
    if c.setup.len > 0:
      for line in indented("ran: " & c.setup, "    ", "         "): L.add line

    # Assumptions under the run that rests on them, never pooled.
    if c.assumptions.len > 0:
      L.add "    assuming " & $c.assumptions.len & " value(s) nobody stated:"
      for text in foldAssumptions(c.assumptions):
        for line in indented(text, "      - ", "        "): L.add line

    for res in c.results: renderClaim(L, res, "    ", verbose)

  # Rejected claims aren't repeated here; they are `NOT CHECKED`'s content.
  if r.rejected.len > 0:
    L.add ""
    L.add "  " & $r.rejected.len & " further claim(s) reached no test at all" &
          " -- see NOT CHECKED below"

proc describeBaselineChange(c: BaselineChange): string =
  if c.isNew:
    result = c.id & "   new claim, now " & c.toStatus
    if c.toStatus in ["pass", "fail"]: result &= " (" & eng(c.toValue) & ")"
    return
  if c.isGone:
    result = c.id & "   claim gone, was " & c.fromStatus
    if c.fromStatus in ["pass", "fail"]: result &= " (" & eng(c.fromValue) & ")"
    return
  var parts: seq[string]
  if c.statusChanged:
    parts.add c.fromStatus & " -> " & c.toStatus &
             (if c.regressed: " (regression)" else: "")
  if c.unitChanged:
    parts.add "unit " & c.fromUnit & " -> " & c.toUnit & ", cannot compare"
  elif c.valueChanged:
    parts.add eng(c.fromValue, c.fromUnit) & " -> " & eng(c.toValue, c.toUnit)
  c.id & "   " & parts.join(", ")

proc renderBaselineSection(L: var seq[string], changes: seq[BaselineChange],
                           path: string) =
  ## `MOVED`, after `NOT CHECKED` and before the summary. Its own section
  ## because a moved value isn't itself a verdict.
  if changes.len == 0: return
  L.add "MOVED  " & $changes.len & " measurement(s) changed since " & path
  # `sort` is stable, so `results` order survives within each bucket.
  var ordered = changes
  ordered.sort(proc (a, b: BaselineChange): int =
    cmp((if a.regressed: 0 else: 1), (if b.regressed: 0 else: 1)))
  for c in ordered:
    for line in indented(describeBaselineChange(c), "  ", "    "): L.add line

proc render*(r: Readiness, verbose = false, changes: seq[BaselineChange] = @[],
            baselinePath = ""): string =
  ## The whole finding, ordered so the actionable part cannot be missed.
  var L: seq[string]

  var seenIssues = initHashSet[string]()
  L.add "verax -- design '" & r.design & "'"
  var capLine = "capabilities: " & capList(r.requested * r.available)
  if r.simulator.len > 0: capLine &= "   (" & r.simulator & ")"
  L.add capLine
  # Printed only when stated: nothing consumes the range yet.
  if r.environment.stated:
    L.add "environment: " & $r.environment &
          (if r.hottest.len > 0: "   hottest " & r.hottest else: "")

  let gone = r.missing
  if gone.len > 0:
    L.add ""
    L.add "UNAVAILABLE  " & capList(gone)
    for line in indented("requested but this machine cannot provide it; " &
        "install ngspice, or pass --offline to state that graph walks are " &
        "all you wanted. Claims needing it are reported below as not " &
        "evaluated rather than quietly skipped.", "  "):
      L.add line

  if r.structural.len > 0:
    L.add ""
    L.add "STRUCTURE  " & $r.structural.len & " issue(s)"
    for i in r.structural:
      L.add "  [" & sevLabel(i.severity) & "] " & i.kind
      for line in indented(i.message, "      "): L.add line

  L.add ""
  renderChecks(L, r, verbose)

  let bad = failed(r.results)
  if bad.len > 0:
    L.add ""
    L.add "FAILED  " & $bad.len
    for res in bad: renderResult(L, res, seenIssues)

  let open = unchecked(r.results)
  if open.len > 0:
    L.add ""
    L.add "NOT CHECKED  " & $open.len & "   <- nothing verified these claims"
    for res in open:
      renderResult(L, res, seenIssues)
      if res.status == esNotEvaluable and
         res.reason.startsWith("no evaluator produces"):
        let near = didYouMean(res.assertion.quantity)
        if near.len > 0:
          L.add "           did you mean: " & near.join(", ") & "?"
        else:
          L.add "           run `verax quantities` for what can be measured"

  if changes.len > 0:
    L.add ""
    renderBaselineSection(L, changes, baselinePath)

  L.add ""
  if r.results.len == 0:
    L.add "NO CLAIMS  this design states nothing that could be checked"
    for line in indented("A netlist on its own asserts nothing, so there is " &
        "nothing here to pass or fail. Add a `role` or a `require`; " &
        "`verax roles` and `verax quantities` list what is available.",
        "  "):
      L.add line
    L.add ""
  L.add summary(r.results)
  let code = exitCode(r)
  L.add "exit " & $code & " (" & exitLabel(code) & ")"
  L.join("\n")

# --- JSON (--format=json) -------------------------------------------------
#
# Hand-assembled with `std/json`. Every float goes through `jnum`, since a
# bare `nan`/`inf` is not valid JSON.

proc jnum(x: float): JsonNode =
  if x.isNaN or x == Inf or x == -Inf: newJNull() else: newJFloat(x)

proc capArrayJson(s: set[Capability]): JsonNode =
  result = newJArray()
  for c in s: result.add newJString(capLabel(c))

proc subjectJsonNode(s: Subject): JsonNode =
  result = newJObject()
  result["kind"] = newJString((($s.kind))[2 .. ^1].toLowerAscii)
  result["name"] = newJString(s.name)

proc conditionJsonNode(a: Assertion): JsonNode =
  result = newJObject()
  for k, v in a.condition: result[k] = newJString(v)

proc expectJsonNode(e: Expectation, unit: string): JsonNode =
  result = newJObject()
  case e.kind
  of ekNominal:
    result["kind"] = newJString("nominal")
    result["nominal"] = jnum(e.nominal)
    result["fracTol"] = jnum(e.fracTol)
    result["absTol"] = jnum(e.absTol)
  of ekMin:
    result["kind"] = newJString("min")
    result["lo"] = jnum(e.lo)
    result["hi"] = newJNull()
  of ekMax:
    result["kind"] = newJString("max")
    result["lo"] = newJNull()
    result["hi"] = jnum(e.hi)
  of ekRange:
    result["kind"] = newJString("range")
    result["lo"] = jnum(e.rlo)
    result["hi"] = jnum(e.rhi)
  of ekRelative:
    result["kind"] = newJString("relative")
  of ekPredicate:
    result["kind"] = newJString("predicate")
  result["unit"] = newJString(unit)
  result["text"] = newJString(`$`(e, unit))

proc assumptionJsonNode(a: Assumption): JsonNode =
  result = newJObject()
  result["entity"] = newJString(a.entity)
  result["key"] = newJString(a.key)
  result["value"] = jnum(a.value)
  result["unit"] = newJString(a.unit)
  result["source"] = newJString(annSourceName(a.source))
  result["detail"] = newJString(a.detail)

proc issueJsonNode(i: Issue): JsonNode =
  result = newJObject()
  result["kind"] = newJString(i.kind)
  result["severity"] = newJString(sevLabel(i.severity))
  result["message"] = newJString(i.message)

proc marginJsonNode(mOpt: Option[Margin]): JsonNode =
  if mOpt.isNone: return newJNull()
  let m = mOpt.get
  result = newJObject()
  result["abs"] = jnum(m.abs)
  result["frac"] = (if m.hasFrac: jnum(m.frac) else: newJNull())
  result["twoSided"] = newJBool(m.twoSided)

proc baselineChangeJsonNode(c: BaselineChange): JsonNode =
  result = newJObject()
  result["id"] = newJString(c.id)
  result["new"] = newJBool(c.isNew)
  result["gone"] = newJBool(c.isGone)
  result["statusChanged"] = newJBool(c.statusChanged)
  result["regressed"] = newJBool(c.regressed)
  result["fromStatus"] = newJString(c.fromStatus)
  result["toStatus"] = newJString(c.toStatus)
  result["valueChanged"] = newJBool(c.valueChanged)
  result["fromValue"] = jnum(c.fromValue)
  result["toValue"] = jnum(c.toValue)
  result["unitChanged"] = newJBool(c.unitChanged)
  result["fromUnit"] = newJString(c.fromUnit)
  result["toUnit"] = newJString(c.toUnit)

proc renderJson*(r: Readiness, strict = false,
                 changes: seq[BaselineChange] = @[],
                 baselinePath = ""): string =
  ## `verax.readiness/1`. `results` is the flat authoritative list (`checks`
  ## then `rejected`); `checks` carries run metadata, and each result names
  ## its check by index (`null` if rejected), so nothing is serialized twice.
  var root = newJObject()
  root["schema"] = newJString("verax.readiness/1")
  root["design"] = newJString(r.design)
  root["simulator"] = newJString(r.simulator)

  var caps = newJObject()
  caps["requested"] = capArrayJson(r.requested)
  caps["available"] = capArrayJson(r.available)
  caps["missing"] = capArrayJson(r.missing)
  root["capabilities"] = caps

  var env = newJObject()
  env["stated"] = newJBool(r.environment.stated)
  if r.environment.stated:
    env["tAmbientMin"] = jnum(r.environment.tAmbientMin.value)
    env["tAmbientMax"] = jnum(r.environment.tAmbientMax.value)
  env["hottest"] = newJString(r.hottest)
  root["environment"] = env

  let code = exitCode(r, strict)
  var exitNode = newJObject()
  exitNode["code"] = newJInt(code)
  exitNode["label"] = newJString(exitLabel(code))
  root["exit"] = exitNode

  var summaryNode = newJObject()
  summaryNode["total"] = newJInt(r.results.len)
  summaryNode["pass"] = newJInt(count(r.results, esPass))
  summaryNode["fail"] = newJInt(count(r.results, esFail))
  summaryNode["notEvaluated"] = newJInt(count(r.results, esNotEvaluated))
  summaryNode["notEvaluable"] = newJInt(count(r.results, esNotEvaluable))
  root["summary"] = summaryNode

  var structural = newJArray()
  for i in r.structural: structural.add issueJsonNode(i)
  root["structural"] = structural

  var checks = newJArray()
  for c in r.checks:
    var co = newJObject()
    co["evaluator"] = newJString(c.evaluator)
    co["needs"] = capArrayJson(c.needs)
    co["key"] = newJString(c.key)
    co["setup"] = newJString(c.setup)
    var assumptions = newJArray()
    for a in c.assumptions: assumptions.add assumptionJsonNode(a)
    co["assumptions"] = assumptions
    checks.add co
  root["checks"] = checks

  var checkOf = initTable[string, int]()
  for i, c in r.checks:
    for res in c.results: checkOf[label(res.assertion)] = i

  var results = newJArray()
  for res in r.results:
    var ro = newJObject()
    let id = label(res.assertion)
    ro["id"] = newJString(id)
    ro["quantity"] = newJString(res.assertion.quantity)
    var subjects = newJArray()
    for s in res.assertion.subjects: subjects.add subjectJsonNode(s)
    ro["subjects"] = subjects
    ro["condition"] = conditionJsonNode(res.assertion)
    ro["expect"] = expectJsonNode(res.assertion.expect, res.assertion.unit)
    ro["status"] = newJString(statusJsonName(res.status))
    ro["value"] = jnum(res.value)
    ro["unit"] = newJString(res.unit)
    ro["margin"] = marginJsonNode(marginOf(res))
    ro["evaluator"] = newJString(res.evaluator)
    ro["check"] = (if checkOf.hasKey(id): newJInt(checkOf[id]) else: newJNull())
    ro["severity"] = newJString(sevLabel(res.assertion.severity))
    ro["reason"] = newJString(res.reason)
    ro["rationale"] = newJString(res.assertion.rationale)
    var assumptions = newJArray()
    for a in res.assumptions: assumptions.add assumptionJsonNode(a)
    ro["assumptions"] = assumptions
    var issues = newJArray()
    for i in res.issues: issues.add issueJsonNode(i)
    ro["issues"] = issues
    results.add ro
  root["results"] = results

  # Only with `--baseline`: an absent key means "not asked", not "no change".
  if baselinePath.len > 0:
    var baselineNode = newJObject()
    baselineNode["path"] = newJString(baselinePath)
    var changesNode = newJArray()
    for c in changes: changesNode.add baselineChangeJsonNode(c)
    baselineNode["changes"] = changesNode
    root["baseline"] = baselineNode

  pretty(root)

# --- JUnit (--format=junit) ------------------------------------------------

proc renderJunit*(r: Readiness, strict = false): string =
  ## One `<testsuite>`; one `<testcase>` per result (`<design>.<evaluator>`)
  ## and per structural issue (`<design>.structure`). `esFail` -> `<failure>`
  ## (comparison as message; reason, rationale and issues as body);
  ## unevaluated -> `<skipped>` with the reason; a pass carries its margin in
  ## `<system-out>`. Escaped with `xmltree.escape`.
  let code = exitCode(r, strict)
  var failures = count(r.results, esFail)
  for i in r.structural:
    if i.severity == sevError: inc failures
  let skipped = count(r.results, esNotEvaluated) + count(r.results, esNotEvaluable)
  let tests = r.results.len + r.structural.len

  var body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  body &= "<testsuite name=\"" & xmltree.escape(r.design) & "\" tests=\"" & $tests &
          "\" failures=\"" & $failures & "\" skipped=\"" & $skipped &
          "\">\n"
  # The exit code goes in `<properties>`: test counts can't distinguish
  # "clean" from "capability unavailable".
  body &= "  <properties>\n"
  body &= "    <property name=\"exitCode\" value=\"" & $code & "\"/>\n"
  body &= "    <property name=\"exitLabel\" value=\"" &
          xmltree.escape(exitLabel(code)) & "\"/>\n"
  body &= "  </properties>\n"

  for res in r.results:
    let id = label(res.assertion)
    let ev = if res.evaluator.len > 0: res.evaluator else: "unclaimed"
    let cmp = "expect " & `$`(res.assertion.expect, res.assertion.unit) &
              (if res.status in {esPass, esFail}:
                 "   measured " & eng(res.value, res.unit)
               else: "   not measured")
    body &= "  <testcase name=\"" & xmltree.escape(id) & "\" classname=\"" &
            xmltree.escape(r.design & "." & ev) & "\">\n"
    case res.status
    of esFail:
      var detail = res.reason
      if res.assertion.rationale.len > 0:
        detail &= "\nbecause " & res.assertion.rationale
      for i in res.issues:
        detail &= "\n[" & sevLabel(i.severity) & "] " & i.kind & ": " & i.message
      body &= "    <failure message=\"" & xmltree.escape(cmp) & "\">" &
              xmltree.escape(detail) & "</failure>\n"
    of esNotEvaluated, esNotEvaluable:
      body &= "    <skipped message=\"" & xmltree.escape(res.reason) & "\"/>\n"
    of esPass:
      let m = marginOf(res)
      if m.isSome:
        body &= "    <system-out>" & xmltree.escape(marginText(res, m.get)) &
                "</system-out>\n"
    body &= "  </testcase>\n"

  for i, iss in r.structural:
    body &= "  <testcase name=\"" & xmltree.escape(iss.kind & " #" & $i) &
            "\" classname=\"" & xmltree.escape(r.design & ".structure") & "\">\n"
    if iss.severity == sevError:
      body &= "    <failure message=\"" & xmltree.escape(iss.message) & "\"/>\n"
    body &= "  </testcase>\n"

  body &= "</testsuite>\n"
  body

# --- baseline (--baseline=<path>) ------------------------------------------

proc loadBaseline*(path: string): Table[string, BaselineEntry] =
  ## Parses a `renderJson` document, indexed by `id`. Anything else raises
  ## `BaselineError`.
  var text: string
  try:
    text = readFile(path)
  except IOError as e:
    raise newException(BaselineError,
      "cannot read baseline '" & path & "': " & e.msg)
  var j: JsonNode
  try:
    j = parseJson(text)
  except CatchableError as e:
    raise newException(BaselineError,
      "cannot parse baseline '" & path & "' as JSON: " & e.msg)
  if j.isNil or j.kind != JObject or j{"results"}.isNil or
     j{"results"}.kind != JArray:
    raise newException(BaselineError,
      "'" & path & "' is not a verax readiness report (no 'results' " &
      "array) -- pass a file this same binary wrote with `--format=json`")
  for item in j["results"]:
    let id = item{"id"}.getStr("")
    if id.len == 0: continue
    result[id] = BaselineEntry(
      status: item{"status"}.getStr(""),
      unit: item{"unit"}.getStr(""),
      value: item{"value"}.getFloat(NaN))

proc baselineDiff*(r: Readiness, baseline: Table[string, BaselineEntry]):
                   seq[BaselineChange] =
  ## Per id: a numeric move (relative change > 1e-6, or from exactly zero), a
  ## status transition, a new claim, or a gone one. A unit change is reported
  ## as incomparable, never differenced.
  var seen = initHashSet[string]()
  for res in r.results:
    let id = label(res.assertion)
    seen.incl id
    let toStatus = statusJsonName(res.status)
    if not baseline.hasKey(id):
      result.add BaselineChange(id: id, isNew: true, toStatus: toStatus,
                                toValue: res.value, toUnit: res.unit)
      continue
    let b = baseline[id]
    var c = BaselineChange(id: id, fromStatus: b.status, toStatus: toStatus,
                           fromValue: b.value, toValue: res.value,
                           fromUnit: b.unit, toUnit: res.unit)
    if b.status != toStatus:
      c.statusChanged = true
      # `pass -> fail`, or checked -> unchecked: shown first.
      let wasChecked = b.status in ["pass", "fail"]
      let nowChecked = toStatus in ["pass", "fail"]
      c.regressed = (b.status == "pass" and toStatus == "fail") or
                    (wasChecked and not nowChecked)
    if b.unit.len > 0 and res.unit.len > 0 and b.unit != res.unit:
      c.unitChanged = true
    elif b.status in ["pass", "fail"] and res.status in {esPass, esFail}:
      if b.value == 0.0:
        c.valueChanged = res.value != 0.0
      else:
        c.valueChanged = abs(res.value - b.value) / abs(b.value) > 1e-6
    if c.statusChanged or c.valueChanged or c.unitChanged:
      result.add c

  for id, b in baseline:
    if id notin seen:
      result.add BaselineChange(id: id, isGone: true, fromStatus: b.status,
                                fromValue: b.value, fromUnit: b.unit)

proc verify*(d: Design, allowed = allCapabilities, verbose = false,
             strict = false, format = rfText, baseline = "", board: Pcb = nil): int =
  ## Check a design, print the report, and return the exit code: a design
  ## file ends with `quit(verify(d))`.
  keepFullSchematic(d.netlist)
  let r = readiness(d, allowed, board)

  var changes: seq[BaselineChange]
  if baseline.len > 0:
    # A bad baseline is a usage error, never a silently skipped comparison.
    try:
      changes = baselineDiff(r, loadBaseline(baseline))
    except BaselineError as e:
      stderr.writeLine "verax: " & e.msg
      return exitCompile

  case format
  of rfText: echo render(r, verbose, changes, baseline)
  of rfJson: echo renderJson(r, strict, changes, baseline)
  of rfJunit: echo renderJunit(r, strict)
  exitCode(r, strict)

# --- command-line entry --------------------------------------------------

type
  VerifyOptions* = object
    allowed*: set[Capability]
    verbose*, strict*: bool
    keepRuns*: string
      ## Where to archive each simulation (deck, rawfile, log, schematic SVG
      ## and JSON, index). Empty keeps nothing.
    saveCurrents*: bool
      ## Also save device terminal currents. Only with `keepRuns`.
    schematicLayout*: string
      ## Normalized archive-layout spelling; empty leaves the environment's
      ## choice in effect.
    schematicOnly*: bool
      ## Draw the `runFULL*` archive and stop (no simulation). Needs
      ## `--keep-runs=<dir>`.
    layoutOut*: string
      ## `pcb/assemble.writeBoard`'s target; empty means not asked.
      ## `verax layout` forwards it as `--layout-out=<path>`.
    layoutLayers*: int
      ## `0` means "not stated" -- `AssembleOptions`' own default (2) applies.
    layoutSize*: tuple[w, h: Nm]
      ## `(nm(0), nm(0))` means not stated (the default board size applies).
    format*: ReportFormat
      ## `rfText` by default.
    baseline*: string
      ## `--baseline=<path>`, made absolute (the design binary may run in a
      ## different directory).
    bom*: bool
      ## Compile a BOM and stop. Set by `--bom` or any `--bom-*` flag, so a
      ## BOM flag can't be silently ignored.
    bomOut*: string
      ## Where the rendered BOM goes; empty is stdout.
    bomFormat*: BomFormat
    bomLock*: string
      ## A prior `--bom-format=json` document whose choices to keep.
    bomCatalogs*: seq[string]
      ## `--bom-catalog=`, repeatable, registered in the order given. Empty
      ## falls back to `$VERAX_BOM_CATALOG` (a `PathSep`-separated list).
    bomMinCandidates*: int
      ## `-1` means "not stated" -- `defaultResolveOptions` applies.
    board*: string
      ## `--board=<file.kicad_pcb>`: the routed board SI claims are checked
      ## on. Empty: none (SI claims are unevaluable, pointing at
      ## `verax constraints`).
    siConstraints*: bool
      ## Derive SI routing rules for every `si_net` and stop.
    siNet*: string
      ## `--net=`: only this `si_net`'s net.
    siDru*: string
      ## `--dru=`: also write the KiCad rules there.
    siOut*: string
    siJson*: bool
    stackupLayers*: int
      ## `0` means "not stated" (4).

proc parseCapabilities*(text: string): set[Capability] =
  ## `--caps=op,ac` and friends. `capStatic` is always included.
  result = {capStatic}
  for raw in text.split(','):
    case raw.strip().toLowerAscii().strip(chars = {'.'})
    of "": discard
    of "static": discard
    of "op": result.incl capSpiceOp
    of "dc": result.incl capSpiceDc
    of "ac": result.incl capSpiceAc
    of "tran": result.incl capSpiceTran
    of "si": result.incl capSiTran
    of "sim": result = result + simCapabilities
    of "all": result = result + allCapabilities
    else:
      raise newException(ValueError,
        "unknown capability '" & raw.strip() &
        "'; expected any of static, op, dc, ac, tran, si, all")

proc parseVerifyArgs*(args: openArray[string]): VerifyOptions =
  ## Flags a design file understands. Unrecognised arguments are left for
  ## the design's own flags.
  result.allowed = allCapabilities
  result.bomMinCandidates = -1
  for a in args:
    if a == "--bom" or a.startsWith("--bom-"): result.bom = true
    if a == "--offline": result.allowed = offlineCapabilities
    elif a == "--verbose" or a == "-v": result.verbose = true
    elif a == "--strict": result.strict = true
    elif a.startsWith("--caps="):
      result.allowed = parseCapabilities(a["--caps=".len .. ^1])
    elif a == "--save-currents": result.saveCurrents = true
    elif a.startsWith("--keep-runs="):
      # Absolute: it's baked into each archived deck and the design binary
      # inherits the caller's directory.
      result.keepRuns = absolutePath(a["--keep-runs=".len .. ^1])
    elif a.startsWith("--schematic-layout="):
      result.schematicLayout = layoutPolicyName(parseLayoutPolicy(
        a["--schematic-layout=".len .. ^1]))
    elif a == "--schematic-only": result.schematicOnly = true
    elif a.startsWith("--layout-out="):
      result.layoutOut = absolutePath(a["--layout-out=".len .. ^1])
    elif a.startsWith("--layout-layers="):
      try: result.layoutLayers = parseInt(a["--layout-layers=".len .. ^1])
      except ValueError:
        raise newException(ValueError,
          "--layout-layers wants an integer copper-layer count, got '" &
          a["--layout-layers=".len .. ^1] & "'")
    elif a.startsWith("--layout-size="):
      let spec = a["--layout-size=".len .. ^1]
      let x = spec.find('x')
      if x < 0:
        raise newException(ValueError,
          "--layout-size wants WxH in millimetres, e.g. 100x80, got '" &
          spec & "'")
      try:
        result.layoutSize = (mm(parseFloat(spec[0 ..< x])),
                             mm(parseFloat(spec[x + 1 .. ^1])))
      except ValueError:
        raise newException(ValueError,
          "--layout-size wants WxH in millimetres, e.g. 100x80, got '" &
          spec & "'")
    elif a.startsWith("--format="):
      case a["--format=".len .. ^1]
      of "text": result.format = rfText
      of "json": result.format = rfJson
      of "junit": result.format = rfJunit
      else:
        raise newException(ValueError,
          "unknown --format '" & a["--format=".len .. ^1] &
          "'; expected text, json or junit")
    elif a.startsWith("--baseline="):
      result.baseline = absolutePath(a["--baseline=".len .. ^1])
    elif a.startsWith("--board="):
      result.board = absolutePath(a["--board=".len .. ^1])
    elif a == "--si-constraints": result.siConstraints = true
    elif a.startsWith("--net="): result.siNet = a["--net=".len .. ^1]
    elif a.startsWith("--dru="): result.siDru = absolutePath(a["--dru=".len .. ^1])
    elif a.startsWith("--si-out="): result.siOut = absolutePath(a["--si-out=".len .. ^1])
    elif a == "--si-format=json": result.siJson = true
    elif a == "--si-format=text": result.siJson = false
    elif a.startsWith("--stackup-layers="):
      try: result.stackupLayers = parseInt(a["--stackup-layers=".len .. ^1])
      except ValueError:
        raise newException(ValueError,
          "--stackup-layers wants an integer copper-layer count, got '" &
          a["--stackup-layers=".len .. ^1] & "'")
    elif a.startsWith("--bom-out="):
      result.bomOut = absolutePath(a["--bom-out=".len .. ^1])
    elif a.startsWith("--bom-format="):
      case a["--bom-format=".len .. ^1]
      of "text": result.bomFormat = bfText
      of "csv": result.bomFormat = bfCsv
      of "json": result.bomFormat = bfJson
      else:
        raise newException(ValueError,
          "unknown --bom-format '" & a["--bom-format=".len .. ^1] &
          "'; expected text, csv or json")
    elif a.startsWith("--bom-lock="):
      result.bomLock = absolutePath(a["--bom-lock=".len .. ^1])
    elif a.startsWith("--bom-catalog="):
      result.bomCatalogs.add absolutePath(a["--bom-catalog=".len .. ^1])
    elif a.startsWith("--bom-min-candidates="):
      let n = a["--bom-min-candidates=".len .. ^1]
      try: result.bomMinCandidates = parseInt(n)
      except ValueError: result.bomMinCandidates = -2
      if result.bomMinCandidates < 0:
        raise newException(ValueError,
          "--bom-min-candidates wants a count, 0 to disable, got '" & n & "'")
    elif a.startsWith("--bom-"):
      raise newException(ValueError, "unknown flag '" & a & "'; the --bom " &
        "flags are --bom-out, --bom-format, --bom-lock, --bom-catalog and " &
        "--bom-min-candidates")

# --- the catalog: what may be claimed ------------------------------------
#
# Rendered to strings for both the CLI and the MCP server.

proc describeInterfaces*(): string =
  var lines = @["interfaces -- declared wire bundles and their modports", ""]
  for name in registeredInterfaceDefs():
    let def = interfaceDefOf(name)
    lines.add $def
    if def.implies.len > 0:
      var roles: seq[string]
      for claim in def.implies: roles.add claim.role
      lines.add "    implies: " & roles.join(", ")
  lines.join("\n")

proc describeInterface*(name: string): string =
  try:
    describeInterfaceDef(interfaceDefOf(name))
  except NetlistError:
    raise newException(ValueError, "no interface named '" & name & "'; `verax interfaces` lists them")

proc describeRoles*(): string =
  var L = @["roles -- each is a bundle of claims you get by naming it", ""]
  for name in registeredRoles():
    let def = roleDef(name)
    L.add name
    L.add "    " & def.doc
    if def.expects.len > 0: L.add "    interface: " & def.expects
    var parts: seq[string]
    for p in def.parts:
      parts.add p.name & (if p.optional: " (optional)" else: "")
    L.add "    parts:  " & parts.join(", ")
    if def.params.len > 0:
      var ps: seq[string]
      for p in def.params:
        ps.add p.key & (if p.unit.len > 0: " [" & p.unit & "]" else: "")
      L.add "    params: " & ps.join(", ")
    L.add ""
  L.add "`verax role <name>` shows the claims each one makes."
  L.join("\n")

proc claimLine(a: Assertion): string =
  ## Quantity and subjects only: a preview's bounds come from placeholder
  ## parameters, so printing them would state limits nobody set.
  var subj: seq[string]
  for s in a.subjects: subj.add $s
  result = "  " & a.id & " : " & a.quantity & "(" & subj.join(", ") & ")"
  let ev = evaluatorFor(a.quantity)
  if ev.isSome:
    result &= "   -> " & ev.get.name & " [" & capLabel(ev.get.needs) & "]"
  else:
    result &= "   -> nothing produces this"

proc describeRole*(name: string): string =
  if not isRole(name):
    raise newException(ValueError,
      "no role named '" & name & "'; `verax roles` lists them")
  let def = roleDef(name)
  # Widened to the longest name present.
  var w = 12
  for p in def.parts: w = max(w, p.name.len)
  for p in def.params: w = max(w, p.key.len)
  w += 2
  var L = @["role " & def.name & " -- " & def.doc, "", "parts"]
  for p in def.parts:
    # An `skClass` part references another role instance, so print "role".
    let kindText = if p.kind == skClass: "role"
                   else: ($p.kind)[2 .. ^1].toLowerAscii
    L.add "  " & p.name.alignLeft(w) &
          kindText.alignLeft(11) &
          (if p.optional: "optional  " else: "required  ") & p.doc
  if def.params.len > 0:
    L.add ""
    L.add "params"
    for p in def.params:
      L.add "  " & p.key.alignLeft(w) &
            (if p.unit.len > 0: p.unit else: "-").alignLeft(11) & p.doc

  let base = previewRole(def)
  L.add ""
  L.add "always claims"
  if base.len == 0: L.add "  (nothing, until a parameter is stated)"
  for a in base: L.add claimLine(a)

  for p in def.params:
    let extra = previewRoleDelta(def, p.key)
    if extra.len > 0:
      L.add ""
      L.add "stating `" & p.key & "` also claims"
      for a in extra: L.add claimLine(a)
  L.join("\n")

proc claimingRoles*(): Table[string, seq[string]] =
  ## Quantity -> the built-in roles that can claim it, computed by expanding
  ## every role rather than kept by hand.
  for name in registeredRoles():
    let def = roleDef(name)
    # Every parameter at once, then each alone: a parameter can redirect a
    # claim (`gain_stage.atF`: `gain_max_db` -> `gain_at_f`), so one
    # expansion hides branches.
    var shots: seq[seq[(string, string)]] = @[@[]]
    var all: seq[(string, string)]
    for p in def.params:
      all.add (p.key, "1")
      shots.add @[(p.key, "1")]
    shots.add all
    for params in shots:
      for a in previewRole(def, params):
        if name notin result.mgetOrPut(a.quantity, @[]):
          result[a.quantity].add name

proc describeQuantities*(): string =
  ## Which quantities exist, what produces them, and what can claim them. A
  ## quantity whose evaluator needs a role binding is `not evaluable` from a
  ## bare `require`, however correctly spelled.
  let byRole = claimingRoles()
  var L = @["quantities -- what a `require` can name", ""]
  var w = 0
  for q in evaluableQuantities(): w = max(w, q.len)

  var orphans: seq[string]
  for q in evaluableQuantities():
    let ev = evaluatorFor(q)
    if ev.isNone: continue
    let roles = byRole.getOrDefault(q, @[])
    # Three distinct answers; conflating them leads to unchecked claims.
    var reach: string
    if ev.get.binds.len == 0:
      # The subjects are all the evaluator needs.
      reach = "`require`"
      if roles.len > 0: reach &= " / role: " & roles.join(", ")
    elif roles.len > 0:
      reach = "role: " & roles.join(", ")
    else:
      reach = "-- needs a role binding " & ev.get.binds.join("/")
      orphans.add q
    # A multi-subject quantity needs the pair, not a bare `require q(x)`.
    var subjTag = ""
    if ev.get.arity != 1 .. 1:
      subjTag =
        if ev.get.arity.a == ev.get.arity.b: "   " & $ev.get.arity.a & " subjects"
        elif ev.get.arity.b == int.high: "   " & $ev.get.arity.a & "+ subjects"
        else: "   " & $ev.get.arity.a & ".." & $ev.get.arity.b & " subjects"
    let unit = if ev.get.units.hasKey(q):
                 (if ev.get.units[q].len > 0: ev.get.units[q] else: "-")
               else: "?"
    var condTag = ""
    if ev.get.conditions.len > 0:
      condTag = "   conditions: " & ev.get.conditions.join(", ")
    L.add "  " & q.alignLeft(w + 2) & unit.alignLeft(6) &
          ev.get.name.alignLeft(24) &
          ("[" & capLabel(ev.get.needs) & "]").alignLeft(10) & reach & subjTag &
          condTag

  L.add ""
  L.add "A quantity not listed here cannot be checked by anything in this build."
  L.add "The second column is the unit it is measured in (`-` for a count or"
  L.add "ratio, `?` where its evaluator declares none). `conditions:` lists the"
  L.add "only bare conditions a claim on it may carry."
  L.add ""
  L.add "`require` marks a quantity a bare `require` reaches: its subjects are all"
  L.add "its evaluator needs. `role:` marks one a role must expand, and names the"
  L.add "built-ins that do."
  if orphans.len > 0:
    L.add ""
    L.add "The " & $orphans.len & " marked `--` are reachable but not by any built-in role."
    L.add "They need topology an assertion does not carry -- which component drives"
    L.add "the rail, which part is the amplifier -- and that is read back off the"
    L.add "role that expanded the claim, so a bare `require` reports `not evaluable`"
    L.add "however correctly it is spelled. Write a role of your own to reach them:"
    L.add "`verax guide` shows how, and the built-ins use no mechanism yours cannot."
  L.join("\n")

proc describeAnnotations*(): string =
  var L = @["annotations -- the keys a `spec:` block accepts", ""]
  # Width from the longest key present; the registry is open.
  var keyW = 12
  for key in registeredKeys():
    if key.len + 2 > keyW: keyW = key.len + 2
  for key in registeredKeys():
    let d = annDef(key)
    var scopes: seq[string]
    for sc in d.scopes: scopes.add $sc
    L.add "  " & key.alignLeft(keyW) &
          (($d.kind)[2 .. ^1].toLowerAscii).alignLeft(8) &
          (if d.unit.len > 0: d.unit else: "-").alignLeft(6) & scopes.join("/")
    L.add "      " & d.doc
  L.add ""
  L.add "Bare keys are the shared vocabulary and are validated. A dotted key"
  L.add "(`parasitics.q`, anything of your own) is namespaced and never is."
  L.join("\n")

# --- bill of materials (--bom) ----------------------------------------------

proc compileBom*(nl: Netlist, o: VerifyOptions): int =
  ## Collect -> resolve -> render, then stop (no `readiness`). An unreadable
  ## catalogue or lock is `exitCompile`; an unresolved assembled part is
  ## `exitStructural`. With CSV/JSON on stdout, findings go to stderr.
  var catalogs = o.bomCatalogs
  if catalogs.len == 0:
    for p in getEnv("VERAX_BOM_CATALOG").split(PathSep):
      if p.strip.len > 0: catalogs.add absolutePath(p.strip)
  for path in catalogs:
    try:
      discard registerCatalogFile(path, path.splitFile.name)
    except CatalogError as e:
      stderr.writeLine "verax: " & e.msg
      return exitCompile
  var opts = defaultResolveOptions()
  if o.bomMinCandidates >= 0: opts.minCandidates = o.bomMinCandidates
  if o.bomLock.len > 0:
    try:
      opts.lock = loadLock(o.bomLock)
    except LockError as e:
      stderr.writeLine "verax: " & e.msg
      return exitCompile
  let res = resolve(collect(nl), opts)
  let doc = case o.bomFormat
    of bfText: render(res)
    of bfCsv: renderCsv(res)
    of bfJson: renderJson(res)
  let issues = allIssues(res)
  if o.bomOut.len > 0:
    try:
      createDir(o.bomOut.parentDir)
      writeFile(o.bomOut, (if doc.endsWith("\n"): doc else: doc & "\n"))
    except OSError, IOError:
      stderr.writeLine "verax: cannot write " & o.bomOut & ": " &
        getCurrentExceptionMsg()
      return exitCompile
    for i in issues: echo $i
    echo "wrote ", o.bomOut, "  (", res.lines.len, " line(s), ",
      issues.len, " issue(s))"
  elif o.bomFormat == bfText:
    echo doc
  else:
    stdout.write(if doc.endsWith("\n"): doc else: doc & "\n")
    for i in issues: stderr.writeLine $i
  if worstSeverity(res) == sevError: exitStructural else: exitClean

proc siCriteria*(inst: RoleInstance): Criteria =
  ## The `si_net` claims as stage-5 pass criteria: one statement of intent
  ## drives both deriving the rules and checking the board.
  result = defaultCriteria()
  result.requireMonotonic = false       # not an `si_net` claim
  result.useOvershootLimits = false     # nor is the [Model Spec] limit
  if inst.hasParam("max_flight_time"):
    result.maxFlightTime = inst.paramFloat("max_flight_time", NaN)
  if inst.hasParam("max_overshoot"):
    result.maxOvershoot = inst.paramFloat("max_overshoot", NaN)
  if inst.hasParam("max_undershoot"):
    result.maxUndershoot = inst.paramFloat("max_undershoot", NaN)
  if inst.hasParam("max_settle_time"):
    result.maxSettleTime = inst.paramFloat("max_settle_time", NaN)
  elif inst.hasParam("ui"):
    result.maxSettleTime = inst.paramFloat("ui", NaN)
  if inst.hasParam("ui"):
    result.ui = inst.paramFloat("ui", NaN)
  if inst.hasParam("max_crosstalk"):
    result.maxCrosstalk = inst.paramFloat("max_crosstalk", NaN)
  if inst.hasParam("min_eye_height"):
    result.minEyeHeight = inst.paramFloat("min_eye_height", NaN)
  if inst.hasParam("min_eye_width"):
    result.minEyeWidth = inst.paramFloat("min_eye_width", NaN)
  if not result.minEyeHeight.isNaN or not result.minEyeWidth.isNaN:
    result.eyeBits = 127

proc siConstraints*(d: Design, o: VerifyOptions): int =
  ## `verax constraints`: the routing rules every `si_net` needs, before
  ## layout. Text or JSON on stdout (or `--si-out=`), KiCad rules with
  ## `--dru=`.
  var docs: seq[string]
  var json = newJArray()
  var rules: seq[DruRule]
  var failed = false
  var any = false
  for name, inst in d.roles:
    if inst.role != "si_net": continue
    let netName = inst.subject("net").name
    if o.siNet.len > 0 and netName != o.siNet: continue
    any = true
    var req = SiNetRequest(net: netName, driver: pinRef(inst.subject("driver").name))
    for p in ["rx", "rx2", "rx3", "rx4"]:
      if inst.hasPart(p): req.receivers.add pinRef(inst.subject(p).name)
    if inst.hasPart("victim_rx"):
      req.hasVictim = true
      req.victimNet = inst.subject("victim").name
      req.victimDriver = pinRef(inst.subject("victim_driver").name)
      req.victimRx = pinRef(inst.subject("victim_rx").name)
    if inst.hasParam("coupled_length"):
      req.coupledLength = inst.paramFloat("coupled_length", 0.0)
    let st = defaultStackup(if o.stackupLayers > 0: o.stackupLayers else: 4)
    let (ok, why, rep) = deriveSiConstraints(d.netlist, req, siCriteria(inst), st)
    if not ok:
      failed = true
      docs.add "SI constraints for net " & netName & ": not derivable -- " & why & "\n"
      json.add %*{"net": netName, "error": why}
      continue
    docs.add renderText(rep)
    json.add renderJson(rep)
    rules.add druRules(rep, netName)
  for name, inst in d.roles:
    if inst.role != "diff_pair" or not inst.hasPart("driver"): continue
    let pNet = inst.subject("p").name
    let nNet = inst.subject("n").name
    if o.siNet.len > 0 and o.siNet notin [pNet, nNet]: continue
    any = true
    var c = defaultCriteria()
    c.requireMonotonic = false
    c.useOvershootLimits = false
    if inst.hasParam("ui"):
      c.ui = inst.paramFloat("ui", NaN)
      c.maxSettleTime = c.ui
    var req = DiffPairRequest(p: pNet, n: nNet, driver: pinRef(inst.subject("driver").name),
                              rx: pinRef(inst.subject("rx").name),
                              zDiff: (if inst.hasParam("z_diff"): inst.paramFloat("z_diff", 100.0) else: 100.0),
                              skewMax: (if inst.hasParam("skew_intra_max"): inst.paramFloat("skew_intra_max", NaN) else: NaN),
                              ui: c.ui)
    if inst.hasPart("driver_n"):
      req.driverN = pinRef(inst.subject("driver_n").name)
      req.hasDriverN = true
    if inst.hasPart("rx_n"):
      req.rxN = pinRef(inst.subject("rx_n").name)
      req.hasRxN = true
    let st = defaultStackup(if o.stackupLayers > 0: o.stackupLayers else: 4)
    let (ok, why, rep) = deriveDiffConstraints(d.netlist, req, c, st)
    if not ok:
      failed = true
      docs.add "SI constraints for pair " & pNet & "/" & nNet & ": not derivable -- " & why & "\n"
      json.add %*{"net": pNet, "pair": nNet, "error": why}
      continue
    docs.add renderText(rep)
    json.add renderJson(rep)
    rules.add druRules(rep, pNet)
    for r in druRules(rep, nNet):   # the N leg's own length and via rules
      if r.maxSkew.isNaN and r.minClearance.isNaN: rules.add r
  if not any:
    stderr.writeLine "verax: no si_net role" &
      (if o.siNet.len > 0: " on net '" & o.siNet & "'" else: "") & " in this design"
    return exitStructural
  let doc = if o.siJson: pretty(%*{"schema": "verax.si_constraints_set/1", "nets": json}) & "\n"
            else: docs.join("\n")
  if o.siOut.len > 0: writeFile(o.siOut, doc) else: stdout.write doc
  if o.siDru.len > 0:
    writeDru(rules, o.siDru)
    stderr.writeLine "wrote " & o.siDru & " (" & $rules.len & " rule(s))"
  if failed: exitUnchecked else: exitClean

proc verifyMain*(d: Design, args = commandLineParams()): int =
  ## What a design file's last line calls: `quit(verifyMain(d))`. Flags are
  ## read here so the compiled design can be re-run without editing.
  # A bad flag value is a usage error, not an exception (exit 1 reads as a
  # failed claim).
  var o: VerifyOptions
  try:
    o = parseVerifyArgs(args)
  except ValueError as e:
    stderr.writeLine "verax: " & e.msg
    return exitCompile
  # Set via the environment: nothing below `readiness` takes an options
  # value, and threading an archive directory down to `spice/ngspice.run`
  # would touch every analysis.
  if o.keepRuns.len > 0: putEnv("VERAX_KEEP_RUNS", o.keepRuns)
  if o.saveCurrents: putEnv("VERAX_SAVE_CURRENTS", "1")
  if o.schematicLayout.len > 0:
    putEnv("VERAX_SCHEMATIC_LAYOUT", o.schematicLayout)
  if o.schematicOnly:
    if o.keepRuns.len == 0:
      stderr.writeLine "verax: --schematic-only needs --keep-runs=<dir> " &
        "to draw into"
      return exitCompile
    keepFullSchematic(d.netlist)
    echo "wrote runFULL.* to ", o.keepRuns
    return exitClean
  if o.layoutOut.len > 0:
    # Build the board and stop, like `--schematic-only`.
    var opts = defaultAssembleOptions()
    if o.layoutLayers > 0: opts.copperLayers = o.layoutLayers
    if o.layoutSize.w > nm(0) and o.layoutSize.h > nm(0):
      opts.boardSize = o.layoutSize
    let issues = writeBoard(d.netlist, o.layoutOut, opts)
    var worst = sevInfo
    for i in issues:
      echo "[" & $i.severity & "] " & i.kind & ": " & i.message
      if i.severity > worst: worst = i.severity
    echo "wrote ", o.layoutOut, "  (", issues.len, " issue(s))"
    return (if worst == sevError: exitStructural else: exitClean)
  if o.bom: return compileBom(d.netlist, o)
  if o.siConstraints: return siConstraints(d, o)
  var board: Pcb = nil
  if o.board.len > 0:
    try:
      board = kicadfmt.readPcb(o.board)
    except CatchableError as e:
      stderr.writeLine "verax: --board: " & e.msg
      return exitCompile
  verify(d, o.allowed, o.verbose, o.strict, o.format, o.baseline, board)
