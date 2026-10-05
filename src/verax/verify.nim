## Running a design's contract, and saying plainly what was *not* checked.
##
## `verax/contract` can already state intent and evaluate it; `verax/analysis`
## can already check a netlist's structure. Neither is reachable without
## writing a program, and nothing joins the two into one answer. This module is
## that answer: the runner behind `verax check` and behind the one line a
## design file ends with.
##
## It sits at the package root for the reason `units.nim` and `eng.nim` do --
## more than one submodule is needed at once and the dependency order gives it
## nowhere else. A readiness report needs `contract` (plan, evaluate),
## `analysis` (the static IO checks) and `netlist/annotations` (vocabulary
## validation) simultaneously, and `contract` must never gain an edge to
## `analysis`, because a design staying inspectable with no simulator in the
## build is what that separation buys.
##
## **It imports `analysis/contract_eval` unconditionally, and that is the
## point.** Without it, a perfectly good requirement reports
## `no evaluator produces 'z_max_in_band'` -- which is false; `spice.pdn`
## produces it, the module registering that evaluator merely was not imported.
## A reader who believes the message deletes a correct requirement. With one
## entry point that always registers the simulated evaluators and gates on
## *capabilities* instead, the same claim reports `requires capSpiceAc, which
## was not offered`, which is true and tells the reader what to do about it.
##
## The report's centre of gravity is deliberately **not** pass/fail. It is the
## `NOT CHECKED` section: an assertion nobody evaluated is not a passing
## assertion, and a contract layer whose silence reads as approval is the
## failure mode the whole layer exists to prevent.
##
## **The body is one block per *test*.** A test is one analysis run -- a plan
## step, seen after it has run -- and it is the grouping the whole layer is
## built around, because an evaluator is handed a *batch* and one simulation
## answers every claim in it. Reported as a flat list of results instead,
## three things a reader needs together are lost: which claims came out of
## one run, what that run actually was, and which invented values it rested
## on. The last is the sharpest. An assumption is attached to every result in
## its batch, so pooling them at the foot of the report says forty numbers
## were assumed *somewhere* and leaves the reader to work out which
## measurement each one moved -- which is the only question worth asking
## about an assumption.
##
## So `readiness` runs the plan through `runPlan` rather than `evaluate`: the
## grouping cannot be recovered afterwards, since a result carries its
## evaluator's name but not its setup key, and two steps of one evaluator are
## two different runs of it.

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
import ./analysis/io_check
import ./analysis/evaluators/contract_eval
import ./pcb/units
import ./pcb/assemble
# Registers the KiCad `FootprintSource` (`pcb/footprint.registerFootprintSource`)
# so `verax layout` resolves real land patterns off
# `/usr/share/kicad/footprints` (or `$VERAX_FOOTPRINT_PATH`) with no further
# setup -- opt-in per import everywhere else in this codebase, and this is
# the one call site that must actually opt in for the CLI command to do
# anything but report every part `footprint_unresolved`.
import ./pcb/formats/kicadmod

export contract_eval, io_check, environment, assemble, kicadmod

type
  Check* = object
    ## One *test*: a single analysis run, everything it rests on, and every
    ## claim it answered.
    ##
    ## A plan step and a `Check` are the same grouping seen before and after
    ## running -- which is the grouping that matters, because an evaluator is
    ## handed a *batch* and one run answers every claim in it. Reported as a
    ## flat list of results instead, three facts are lost that a reader needs
    ## together: which claims came out of one simulation (so a single wrong
    ## setup explains all of them at once), what that simulation was, and
    ## which invented values it rested on. The last is the sharpest: an
    ## assumption is attached to every result in its batch, so a pooled list
    ## at the foot of a report says forty things were assumed *somewhere* and
    ## leaves the reader to work out which number each one moved.
    evaluator*: string
    needs*: set[Capability]
    key*: string
      ## The setup key that grouped this batch. Machinery, kept for a caller
      ## that wants to correlate two runs; `setup` is what a person reads.
    setup*: string
      ## What actually ran, in the evaluator's own words.
    results*: seq[AssertionResult]
    assumptions*: seq[Assumption]
      ## Deduplicated across this batch, and only what nobody stated --
      ## `annAuthored` values are the design speaking, not the tool.

  Readiness* = object
    ## Everything one run of a design's contract found out.
    design*: string
    requested*: set[Capability]
      ## What the caller offered.
    available*: set[Capability]
      ## What this machine can actually do. `requested - available` is an
      ## environment problem, reported as one rather than degraded silently.
    simulator*: string
      ## Version line of the backing simulator, or "" if there is none.
    environment*: Environment
      ## The board-level operating conditions the design stated. Reported
      ## rather than used: nothing here is temperature-dependent yet, and a
      ## premise that is quietly carried is a premise nobody checks.
    hottest*: string
      ## The part running hottest at the top of the ambient range, and how
      ## hot, pre-rendered -- or "" when nothing states a rise. A `delta_t`
      ## that nothing repeats back is indistinguishable from one that was
      ## never written.
    structural*: seq[Issue]
      ## Annotation-vocabulary and static IO findings, before any claim is
      ## considered. A misspelled `esr` makes every impedance number below it
      ## meaningless, so it is reported first.
    plan*: Plan
      ## What was going to run, kept even after running: the count of analysis
      ## steps against the count of assertions is the cheapest evidence that
      ## claims are being batched rather than re-simulated one by one.
    checks*: seq[Check]
      ## The steps with what each one produced, in plan order. A run that
      ## existed only to measure a relative claim's reference (and so
      ## answered no authored claim of its own) is folded into the claim that
      ## used it rather than printed as an empty block.
    rejected*: seq[AssertionResult]
      ## Claims no step could take: nothing produces the quantity, the
      ## subjects are the wrong shape, or the capability was withheld. Kept
      ## apart from `checks` because no test ran for them -- filing them
      ## under one would say a run happened that did not.
    results*: seq[AssertionResult]
      ## Every result flat, `checks` then `rejected`, in the order
      ## `evaluate` would have produced them. Kept so everything that reads a
      ## whole run -- `summary`, `failed`, `invented` -- goes on working.

const
  exitClean* = 0
  exitFailed* = 1
    ## At least one assertion was checked and did not hold.
  exitStructural* = 2
    ## The netlist itself is wrong in a way that makes claims about it
    ## untrustworthy.
  exitUnchecked* = 3
    ## Nothing can produce some quantity that was claimed. Non-zero on
    ## purpose: a claim nobody checks must not exit like a claim that passed.
  exitEnvironment* = 4
    ## A capability was requested that this machine cannot provide.
  exitCompile* = 5
    ## The design file did not compile. Only `verax check` produces this --
    ## a design file that failed to build never ran to report anything. It is
    ## separate from every other code on purpose: told only "it failed", a
    ## reader edits the circuit to fix what is actually a syntax error.

type
  ReportFormat* = enum
    ## `rfText` is the default and the only one a human reads directly;
    ## `rfJson`/`rfJunit` exist for `verax check` to sit in a CI job rather
    ## than only a terminal -- a pass/fail exit code alone cannot carry *why*,
    ## and a build system that wants to diff two runs needs a document, not a
    ## paragraph.
    rfText, rfJson, rfJunit

  BaselineEntry* = object
    ## One remembered result, read back from a previous run's `--format=json`
    ## document by `loadBaseline`. Only what a comparison needs -- `status`,
    ## `value`, `unit` -- never the whole `AssertionResult`, since a baseline
    ## is a stored fact about one earlier run, not a rehydrated one.
    value*: float
    unit*: string
    status*: string

  BaselineChange* = object
    ## What differs about one claim between a baseline and this run. One
    ## record per id, not one record per *kind* of difference, because a
    ## claim can carry more than one at once (a status transition and a
    ## value move together) and a reader wants them about the claim, not
    ## scattered across separate entries that happen to share an id.
    id*: string
    isNew*: bool
      ## This id was not in the baseline at all.
    isGone*: bool
      ## This id was in the baseline and is not among this run's results.
    statusChanged*: bool
    regressed*: bool
      ## `pass -> fail`, or a checked claim (`pass`/`fail`) going to an
      ## unchecked one (`not_evaluated`/`not_evaluable`) -- the direction a
      ## reader has to see first, since the opposite motion (a claim that
      ## started passing again, or one that started being checked) is good
      ## news carried by the same two fields.
    fromStatus*, toStatus*: string
    valueChanged*: bool
      ## A numeric move worth reporting: the relative change exceeds 1e-6,
      ## or the prior value was exactly zero and the new one is not (where a
      ## relative change is not a number at all). Never set when the units
      ## disagree -- see `unitChanged`.
    fromValue*, toValue*: float
    unitChanged*: bool
      ## The measurement's unit itself moved -- a role or an evaluator was
      ## changed to report in different terms. Reported as a move that
      ## cannot be numerically compared, never silently differenced against
      ## a number in a different unit.
    fromUnit*, toUnit*: string

  BaselineError* = object of CatchableError
    ## Raised by `loadBaseline` on anything short of a readable, parseable
    ## `--format=json` document with a `results` array. `verify` turns this
    ## into a usage error (`exitCompile`) rather than letting the exception
    ## propagate as a stack trace, and never into a silently skipped
    ## comparison -- a CI job whose baseline file went missing or got
    ## corrupted and quietly stopped comparing is a worse failure than one
    ## that stops and says why.

# --- what this machine can do -------------------------------------------

proc ngspiceVersion*(exe = "ngspice"): string =
  ## The installed simulator's version, or "" when there is none on `PATH`.
  ##
  ## Best-effort by design: a version we cannot parse is still a simulator we
  ## can run, so an unrecognised banner reports the executable rather than
  ## claiming absence.
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
  ## `capBench` is never included: nothing in this library takes a bench
  ## measurement, and offering a capability nothing can honour would turn
  ## every bench-backed claim from "not offered" into "ran and produced
  ## nothing", which reads much worse than it is.
  result = {capStatic}
  let sim = if simulator.len > 0: simulator else: ngspiceVersion()
  if sim.len > 0:
    result = result + simCapabilities

proc label(a: Assertion): string =
  if a.id.len > 0: a.id else: a.quantity

proc claimLint*(results: seq[AssertionResult]): seq[Issue] =
  ## Claims whose stated unit is missing where the measurement has one.
  ##
  ## `unitsAgree` treats an empty unit as "not stated, therefore unchecked",
  ## which is right for a bare count like `pullup_count` and dangerous
  ## everywhere else. The trap in practice: `unitOf(Fraction)` is "" and
  ## `overshoot_pct` is measured in "%" as `5.0`, so
  ## `require overshoot_pct(vdd) <= 5.pct` compares 5.0 against 0.05 and is
  ## wrong by a hundred -- with no mismatch reported, because neither side
  ## claimed a unit to disagree about.
  ##
  ## Detected after the fact rather than before, because nothing declares what
  ## unit a quantity comes back in until it has been measured. That is worth
  ## fixing at the source one day (a `units` field on `Evaluator`, parallel to
  ## `produces`); until then, reporting it beats comparing silently.
  for r in results:
    if r.status notin {esPass, esFail}: continue
    if r.assertion.expect.kind in {ekRelative, ekPredicate}: continue
    if r.assertion.unit.len > 0 or r.unit.len == 0: continue
    result.add newIssue("claim_unit_unstated", sevWarning,
      "claim '" & label(r.assertion) & "' states no unit, but " &
      r.assertion.quantity & " is measured in " & r.unit &
      ". The comparison went ahead unchecked. If the limit came from a " &
      "Fraction literal such as 5.pct, it is 0.05 where the measurement is " &
      "5.0 -- a factor of a hundred.")

proc previewRole*(def: RoleDef,
                  params: openArray[(string, string)] = []): seq[Assertion] =
  ## What a role would claim, with placeholder bindings.
  ##
  ## Safe because `RoleExpander` takes only a `RoleInstance` and never touches
  ## a netlist -- that is what separates `expand` from `apply`. A role someone
  ## else registered may still dislike placeholder bindings, so an expander
  ## that raises yields nothing rather than taking down the caller: a bad
  ## third-party role must not make `verax roles` unusable.
  var inst = RoleInstance(role: def.name, name: "<preview>")
  for p in def.parts:
    inst.bindings[p.name] = Subject(kind: p.kind, name: "<" & p.name & ">")
  for pair in params: inst.params[pair[0]] = pair[1]
  try:
    def.expand(inst)
  except CatchableError:
    @[]

proc previewRoleDelta*(def: RoleDef, param: string): seq[Assertion] =
  ## The claims that stating `param` adds, found by diffing two expansions
  ## rather than documented by hand -- so it cannot drift from the expander.
  var seen: seq[string]
  for a in previewRole(def): seen.add a.id
  for a in previewRole(def, [(param, "1")]):
    if a.id notin seen: result.add a

# --- running -------------------------------------------------------------

proc readiness*(d: Design, allowed = allCapabilities): Readiness =
  ## Check a design as far as `allowed` and this machine jointly permit.
  ##
  ## Pure with respect to the design: nothing here mutates `d` or its netlist.
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
  # One context for the whole run, and that is the point of it: the simulated
  # evaluators share an operating point through `EvalContext.scratch`, so
  # planning, running and describing all have to be the same run. It lives
  # exactly as long as this call, so nothing it caches can outlive the design
  # state it was computed from -- which a module-level cache could only
  # promise by asking every caller to remember to clear it.
  let ctx = newEvalContext(d, usable)
  result.plan = plan(ctx)
  let batches = runPlan(ctx, result.plan)

  # Run through the plan rather than calling `evaluate`, which flattens the
  # batches away. The grouping cannot be recovered afterwards: a result
  # carries its evaluator's name but not its setup key, and two steps of one
  # evaluator -- a PDN sweep of two rails, a start-up of two regulators --
  # are two separate runs resting on two separate sets of assumptions.
  #
  # Relative and predicate claims were decomposed by `plan` into hidden
  # measurement requests. Those requests run in the same steps, but they are
  # not claims: they are filtered out of every check block, and the single
  # authored claim they feed is folded back and attached to the run that
  # measured it.
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
      # The anchor request never reached a step (it was rejected at plan
      # time), so the folded claim files with the others no test took.
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
  ## Graded, so a caller can branch on *why* rather than only on whether.
  ##
  ## Precedence runs most-fundamental first: an unavailable capability makes
  ## the run incomplete, a broken netlist makes its numbers untrustworthy, a
  ## failed assertion is a real answer, and an unevaluable one is a claim
  ## nobody checked. `esNotEvaluated` alone stays clean -- withholding a
  ## capability is a deliberate act, not an oversight -- unless `strict`.
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
  ## A capability set as a comma list of the labels a designer reads, so a
  ## report and `verax env` never spell the same set two ways. Exported
  ## because the CLI echoed `$s` and printed the enum identifiers -- which is
  ## right in a stack trace and wrong in the one line meant to tell somebody
  ## what this machine can do.
  var parts: seq[string]
  for c in s: parts.add capLabel(c)
  if parts.len == 0: "none" else: parts.join(", ")

proc sevLabel(s: Severity): string =
  case s
  of sevInfo: "info"
  of sevWarning: "warning"
  of sevError: "error"

proc statusJsonName(s: EvalStatus): string =
  ## The spelling `--format=json`, `loadBaseline` and `baselineDiff` all
  ## share, so a status is never spelled two ways across a report and the
  ## baseline it is compared against. Snake-cased rather than `$s`'s bare
  ## enum identifier (`esNotEvaluated`), which is implementation vocabulary,
  ## not a value a consuming tool should have to know this library's enum
  ## names to match against.
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
  ## The registered quantities closest to one nothing produces.
  ##
  ## A misspelled quantity is the likeliest way to write a claim that cannot
  ## be checked, and `no evaluator produces 'z_ripple'` on its own is a dead
  ## end -- it says the door is locked without mentioning that a door exists.
  let budget = max(3, quantity.len div 2)
  var scored: seq[(int, string)]
  for q in evaluableQuantities():
    let dist = editDistance(quantity, q)
    if dist <= budget: scored.add (dist, q)
  scored.sort()
  for i in 0 ..< min(limit, scored.len): result.add scored[i][1]

proc indented(text: string, prefix: string, hang = "",
              width = 74): seq[string] =
  ## Wrapped, with an optional deeper indent on continuation lines so a
  ## multi-line entry cannot be mistaken for two entries.
  let cont = if hang.len > 0: hang else: prefix
  var first = true
  for line in wrapWords(text, width).splitLines():
    result.add (if first: prefix else: cont) & line
    first = false

proc foldAssumptions*(assumptions: seq[Assumption]): seq[string] =
  ## One line per *distinct* assumption, naming every part it was made about.
  ##
  ## Producers emit one record per component, which is right -- a consumer
  ## that wants to count them, or ask which parts a package default touched,
  ## needs them separate. Printed one per line it is mostly repetition: a
  ## four-capacitor bank contributes twelve lines that say the same three
  ## things, and the reader who skims past them is skimming past the two
  ## lines that were about something else. Folding on `(key, value, unit,
  ## detail)` loses nothing -- every entity is still named -- and it is the
  ## difference between a list worth reading and a wall.
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
    # A narrative assumption has no key and no magnitude -- "these parts were
    # cut at the boundary" is a real thing a result rests on -- and its
    # `detail` is already a whole sentence. It still folds, when it names a
    # part.
    var body = a.detail
    if a.key.len > 0:
      body = a.key & " " & eng(a.value, a.unit) &
             (if a.detail.len > 0: " " & a.detail else: "")
    result.add (if entities[sig].len == 0: body
                else: entities[sig].join(", ") & ": " & body)

proc statusMark(st: EvalStatus): string =
  ## Four characters, fixed width, so a column of verdicts is scannable.
  ## `----` and `????` rather than words for the two negative statuses: they
  ## are the same marks `$AssertionResult` already uses, and they read as
  ## *absence* rather than as a third and fourth kind of verdict.
  case st
  of esPass: "PASS"
  of esFail: "FAIL"
  of esNotEvaluated: "----"
  of esNotEvaluable: "????"

proc marginText(r: AssertionResult, m: Margin): string =
  ## `contract/evaluate.marginOf` computes the number; this is the one place
  ## it is put into words, matching `acceptance`'s split (types.nim computes
  ## the interval, `renderClaim` here decides how to say it). A two-sided
  ## band is read as a fraction of *itself* (1.0 = dead centre, 0.0 = right
  ## on an edge) because "58% of band" needs nothing else to be understood; a
  ## one-sided limit has no natural ceiling to be a fraction *of* -- a
  ## measurement can clear a floor by 500% -- so the absolute headroom leads
  ## and the fraction rides along in parentheses.
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
  ## One claim as *a comparison*: what was expected, what came back.
  ##
  ## The two numbers go on one line together because that is the act a reader
  ## performs, and separating them across a `describe` line and a `reason`
  ## line -- which is what the status sections do -- makes them something to
  ## be reassembled. The band or drive level comes first, on the heading
  ## line, since a limit read against the wrong part of a curve is not a
  ## check at all.
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
      # The comparison needs the referenced value(s), which are in `reason`;
      # there is no single bare number to print after "measured".
      cmpLine &= "   " & r.reason
    else:
      cmpLine &= "   measured " & eng(r.value, r.unit)
      # `reason` carries more than the bare number when the measurement was
      # taken somewhere the subject does not name -- `inrush_peak` is read on
      # the rail being charged, not on the net the claim judges.
      let at = r.reason.find(" at ")
      if at >= 0: cmpLine &= r.reason[at .. ^1]
      let m = marginOf(r)
      if m.isSome: cmpLine &= "   " & marginText(r, m.get)
  of esNotEvaluated, esNotEvaluable:
    cmpLine &= "   not measured"
  for line in indented(cmpLine, deep, deep & "  "): L.add line

  if r.status in {esNotEvaluated, esNotEvaluable} and r.reason.len > 0:
    for line in indented(r.reason, deep, deep & "  "): L.add line

  # The most valuable field on an assertion, and until now printed nowhere:
  # a limit whose reason is lost is the limit that gets relaxed the first
  # time it fails. Shown wherever the reader is deciding what to do about
  # the claim -- always when it did not pass, on request when it did.
  if r.assertion.rationale.len > 0 and (verbose or r.status != esPass):
    for line in indented("because " & r.assertion.rationale, deep,
                         deep & "  "): L.add line

proc renderResult(L: var seq[string], r: AssertionResult,
                  seenIssues: var HashSet[string]) =
  ## One claim in a status section: the same comparison the check block
  ## printed, plus the diagnosis.
  ##
  ## Rendered through `renderClaim` rather than through `describe` so a
  ## failure and the check it came out of read the same -- a band spelled
  ## `over 100 kHz .. 100 MHz` in one place and `[f_from=100k, f_to=100M]` in
  ## the other is two spellings of one claim, and the reader has to work out
  ## that they are the same limit.
  renderClaim(L, r, "  ", verbose = true)

  # An analysis that could not answer usually knows *why*, and says so in an
  # `Issue` rather than in `reason` -- which is a short, generic sentence
  # written by `verdict` and cannot name a cause it does not know. Printing
  # only the reason strands the diagnosis: a Sallen-Key's phase margin comes
  # back "the quantity was not found in the range that was analysed", which
  # is true and sends the reader to widen a sweep that is not the problem,
  # while the issue sitting next to it says the loop break did not open the
  # loop and why.
  #
  # De-duplicated across the whole report, because evaluation is *batched*:
  # one loop-gain run answers every claim in its batch, so its issues ride
  # on all of them and would otherwise print once per claim.
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

    # Under the run that rests on them, never pooled at the foot of the
    # report. Which number an invented value moved is the whole question, and
    # a single list answers it for none of them.
    if c.assumptions.len > 0:
      L.add "    assuming " & $c.assumptions.len & " value(s) nobody stated:"
      for text in foldAssumptions(c.assumptions):
        for line in indented(text, "      - ", "        "): L.add line

    for res in c.results: renderClaim(L, res, "    ", verbose)

  # The claims no step could take are *not* listed again here. They are the
  # whole content of `NOT CHECKED`, which prints the same comparison plus the
  # spelling hint, and a report that says the identical thing twice teaches
  # the reader to skip one of the two places.
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
  ## `MOVED`, placed by `render` after `NOT CHECKED` and before the summary:
  ## informational relative to structure, a failure or an unchecked claim --
  ## the report's existing ordering doctrine -- but still worth its own
  ## section rather than folding into `FAILED`, since a value moving is not
  ## itself a verdict; whether it should have moved is a question only the
  ## reader can answer.
  if changes.len == 0: return
  L.add "MOVED  " & $changes.len & " measurement(s) changed since " & path
  # `algorithm.sort` is a stable merge sort, so within each of the two
  # buckets (regression / everything else) insertion order -- `results`
  # order -- survives.
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
  # Printed only when stated. Nothing consumes the range yet, so nagging
  # every design for one would be noise -- but a design that *has* stated it
  # has stated a premise, and a premise is worth reading back.
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
# `std/json` only, hand-assembled with `newJObject`/`newJArray` rather than
# the `%*` macro -- the same explicit style `schematic/json.nim` already
# uses for a public, versioned document. `jnum` is the one float-writing
# path everything here goes through, because `NaN`/`Inf` written as the bare
# Nim literal `nan`/`inf` is not valid JSON and would corrupt every `jq` or
# parser call downstream of this format -- the whole reason `--format=json`
# exists is to be machine-read, so this is the one place that cannot be
# gotten away with fixing later.

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
  ## `verax.readiness/1`, versioned so a consumer can branch on it rather
  ## than guess from field presence. `results` is the flat authoritative
  ## list, mirroring `Readiness.results` (`checks` then `rejected`); `checks`
  ## carries run metadata only, and each result names the check it came from
  ## by index (`null` for a rejected claim) rather than being nested inside
  ## it, so nothing is serialized twice.
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

  # Only when `--baseline` was given -- an absent key, not an empty object,
  # is how a consumer tells "nothing changed" apart from "nothing was asked".
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
  ## One `<testsuite>`, one `<testcase>` per result plus one per structural
  ## issue -- `classname="<design>.<evaluator>"` for a result,
  ## `"<design>.structure"` for a structural finding, so a CI tool grouping
  ## by classname gets the same grouping `CHECKS` uses. `esFail` becomes
  ## `<failure>` (message is the expect/measured comparison, matching
  ## `renderClaim`'s own line; the body is `reason` plus `rationale` plus
  ## every issue, so the diagnosis a text report prints under `FAILED`
  ## is not lost here); `esNotEvaluated`/`esNotEvaluable` become `<skipped>`
  ## with `reason` as the message -- the `NOT CHECKED` content, which must
  ## not silently vanish from a CI job the way an ordinary skip would; a
  ## pass carries its margin, when it has one, as `<system-out>` rather than
  ## dropping it, since a CI consumer that only reads JUnit should not have
  ## to also fetch `--format=json` to see how close a claim ran.
  ##
  ## Escaped with `xmltree.escape`, never by hand -- a designator or a
  ## rationale containing `<`, `>` or `&` is ordinary English, not an attack,
  ## but it is exactly the character class that breaks hand-rolled XML.
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
  # The exit code a text or JSON run would have handed to the shell, carried
  # as a JUnit `<properties>` extension rather than a bespoke attribute --
  # `tests`/`failures`/`skipped` alone cannot distinguish "clean" from
  # "capability unavailable", and a CI job branching on more than pass/fail
  # needs somewhere to read that from without also fetching `--format=json`.
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
  ## Parses a document this same module's `renderJson` wrote, indexed by
  ## `id`. Anything short of that -- a missing file, invalid JSON, JSON that
  ## is not a verax readiness report -- raises `BaselineError`; `verify`
  ## turns that into a usage error rather than a silently skipped
  ## comparison.
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
  ## Per id: a numeric move (the relative change exceeds 1e-6, or the prior
  ## value was exactly zero and the new one is not), a status transition, a
  ## claim new since the baseline, or one gone since it. A unit change is
  ## reported as a move that cannot be compared -- never silently
  ## differenced against a number in a different unit, which is worse than
  ## not comparing at all.
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
      # `pass -> fail`, or a checked claim going unchecked: the direction a
      # reader needs to see before anything else in this section.
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
             strict = false, format = rfText, baseline = ""): int =
  ## Check a design, print the report, and hand back the exit code.
  ##
  ## The one line a design file ends with: `quit(verify(d))`. `format` and
  ## `baseline` are appended at the end, with defaults, so every existing
  ## call site (every design's `quit(verifyMain(d))`, every test calling
  ## `verify` with the original four arguments) keeps compiling unchanged.
  keepFullSchematic(d.netlist)
  let r = readiness(d, allowed)

  var changes: seq[BaselineChange]
  if baseline.len > 0:
    # A usage error (`exitCompile`), not a silent skip -- caught here rather
    # than left to propagate as a stack trace, and never swallowed: a CI job
    # whose baseline went missing or got corrupted and quietly stopped
    # comparing is a worse failure than one that stops and says why.
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
      ## Where to archive each simulation (deck, rawfile, ngspice log, an
      ## SVG schematic and its JSON scene, and an index). Empty means keep
      ## nothing, which is the default.
    saveCurrents*: bool
      ## Ask ngspice for device terminal currents as well as the node
      ## voltages it saves anyway. Only meaningful alongside `keepRuns`.
    schematicLayout*: string
      ## Normalized archive-layout spelling, or empty when the environment's
      ## selection (if any) should remain in effect.
    schematicOnly*: bool
      ## Draw the `runFULL*` archive and stop -- no `readiness`, so no
      ## simulation runs. Needs `--keep-runs=<dir>`; nothing to draw into is
      ## a usage error, not a silent no-op.
    layoutOut*: string
      ## `pcb/assemble.writeBoard`'s target path. Empty means "not asked",
      ## the same shape `keepRuns` takes -- `verax layout` is the CLI
      ## surface, `--layout-out=<path>` is what actually reaches the design
      ## binary through `cmdCheck`'s two-process shape (`cli.nim`'s
      ## `cmdLayout` forwards it as an ordinary compiled-design flag rather
      ## than adding a second entry point that would need its own copy of
      ## `locateLib`/the compile step).
    layoutLayers*: int
      ## `0` means "not stated" -- `AssembleOptions`' own default (2) applies.
    layoutSize*: tuple[w, h: Nm]
      ## `(nm(0), nm(0))` means "not stated" -- `AssembleOptions`' own
      ## default board size applies.
    format*: ReportFormat
      ## `rfText` by default -- a human at a terminal is still the common
      ## case, and every existing invocation with no `--format` flag must
      ## keep printing exactly what it always has.
    baseline*: string
      ## `--baseline=<path>`, made absolute for the same reason `--keep-runs`
      ## is: the design binary inherits the caller's working directory, not
      ## necessarily the shell's.

proc parseCapabilities*(text: string): set[Capability] =
  ## `--caps=op,ac` and friends. `capStatic` is always included: withholding
  ## graph walks would withhold the checks that cost nothing and need no
  ## toolchain, which nobody wants and no flag should quietly do.
  result = {capStatic}
  for raw in text.split(','):
    case raw.strip().toLowerAscii().strip(chars = {'.'})
    of "": discard
    of "static": discard
    of "op": result.incl capSpiceOp
    of "dc": result.incl capSpiceDc
    of "ac": result.incl capSpiceAc
    of "tran": result.incl capSpiceTran
    of "all", "sim": result = result + simCapabilities
    else:
      raise newException(ValueError,
        "unknown capability '" & raw.strip() &
        "'; expected any of static, op, dc, ac, tran, all")

proc parseVerifyArgs*(args: openArray[string]): VerifyOptions =
  ## Flags a design file understands. Unrecognised arguments are left alone,
  ## so a design may take flags of its own without this stealing them.
  result.allowed = allCapabilities
  for a in args:
    if a == "--offline": result.allowed = offlineCapabilities
    elif a == "--verbose" or a == "-v": result.verbose = true
    elif a == "--strict": result.strict = true
    elif a.startsWith("--caps="):
      result.allowed = parseCapabilities(a["--caps=".len .. ^1])
    elif a == "--save-currents": result.saveCurrents = true
    elif a.startsWith("--keep-runs="):
      # Absolute, because the path is baked into each archived deck's own
      # `write` line and the design binary inherits the caller's directory.
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

# --- the catalog: what may be claimed ------------------------------------
#
# Rendered to strings rather than printed, because there are two consumers
# with no terminal in common: the CLI echoes these, and the MCP server
# returns them. An author working outside this repository has no other way
# to find out what vocabulary exists.

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
  ## Quantity and subjects only. A preview's bounds come from placeholder
  ## parameters, so printing `<= 1 ohm` would state a limit nobody set.
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
  # Widened to the longest name actually present rather than a constant: a
  # column that a name overruns runs the name into the next one, and
  # `maxLineRegPerV%/V` is what that reads as.
  var w = 12
  for p in def.parts: w = max(w, p.name.len)
  for p in def.params: w = max(w, p.key.len)
  w += 2
  var L = @["role " & def.name & " -- " & def.doc, "", "parts"]
  for p in def.parts:
    # `skClass` renders `class` through the generic `[2..^1]` slice, which is
    # wrong for a part that references another role instance -- to a reader it
    # is a role. The other kinds (`net`, `component`, `pin`) come out right.
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
  ## Quantity -> the built-in roles that can claim it.
  ##
  ## Computed by expanding every registered role with every one of its
  ## parameters stated, rather than written down: a hand-kept list is exactly
  ## the thing that drifts from the expanders, and this answer is the one a
  ## reader is about to act on.
  for name in registeredRoles():
    let def = roleDef(name)
    # Every parameter at once, then each on its own. One expansion is not
    # enough: a parameter can *redirect* a claim rather than add one --
    # `gain_stage`'s `atF` moves the gain claim from `gain_max_db` onto
    # `gain_at_f` -- so the all-params expansion hides the branch the
    # single-param one shows, and vice versa.
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
  ## Which quantities exist, what produces them, and **what can claim them**.
  ##
  ## The third column is the one worth having. A quantity is only reachable
  ## through a role that binds the topology its evaluator needs -- an op-amp
  ## measurement has to know which component the stage is built around, and
  ## an assertion carries only its subjects -- so a quantity no role claims
  ## is one a bare `require` will report as `not evaluable`, however
  ## correctly it is spelled. Listing them without saying so invited exactly
  ## that: ten of twenty-six were unreachable by any built-in path and
  ## nothing said which.
  let byRole = claimingRoles()
  var L = @["quantities -- what a `require` can name", ""]
  var w = 0
  for q in evaluableQuantities(): w = max(w, q.len)

  var orphans: seq[string]
  for q in evaluableQuantities():
    let ev = evaluatorFor(q)
    if ev.isNone: continue
    let roles = byRole.getOrDefault(q, @[])
    # Three genuinely different answers, and conflating any two of them is
    # how a reader ends up writing a claim nothing will check.
    var reach: string
    if ev.get.binds.len == 0:
      # The subjects are all its evaluator needs, so a bare `require`
      # reaches it whether or not a role also happens to claim it.
      reach = "`require`"
      if roles.len > 0: reach &= " / role: " & roles.join(", ")
    elif roles.len > 0:
      reach = "role: " & roles.join(", ")
    else:
      reach = "-- needs a role binding " & ev.get.binds.join("/")
      orphans.add q
    # A quantity whose evaluator takes more than one subject cannot be reached
    # by a bare `require q(x)` -- it needs the pair -- so a reader has to be
    # able to tell that without running it. `channel_match`'s are the first.
    var subjTag = ""
    if ev.get.arity != 1 .. 1:
      subjTag =
        if ev.get.arity.a == ev.get.arity.b: "   " & $ev.get.arity.a & " subjects"
        elif ev.get.arity.b == int.high: "   " & $ev.get.arity.a & "+ subjects"
        else: "   " & $ev.get.arity.a & ".." & $ev.get.arity.b & " subjects"
    L.add "  " & q.alignLeft(w + 2) & ev.get.name.alignLeft(24) &
          ("[" & capLabel(ev.get.needs) & "]").alignLeft(10) & reach & subjTag

  L.add ""
  L.add "A quantity not listed here cannot be checked by anything in this build."
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
  # Width from the longest key present rather than a constant: `voltage_rating`
  # ran straight into the type column and printed `voltage_ratingfloat`. A
  # fixed width is a bet that no future key is longer than today's, and the
  # registry is a runtime table anyone may add to.
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

proc verifyMain*(d: Design, args = commandLineParams()): int =
  ## What a design file's last line calls: `quit(verifyMain(d))`.
  ##
  ## Reading the flags here rather than baking them into the call means the
  ## compiled design can be re-run offline without being edited, which is what
  ## makes it usable as both a check and an artifact.
  let o = parseVerifyArgs(args)
  # The parser stays pure; the environment is set here. An environment
  # variable is the right mechanism at the bottom of this stack: nothing
  # below `readiness` takes an options value, and only the capability set
  # reaches an analysis at all -- so threading an archive directory down to
  # `spice/ngspice.run` would mean a parameter on every analysis between
  # here and there, and an import of `spice` from a module that deliberately
  # has none.
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
    # `pcb/assemble.writeBoard` alone, the same "draw and stop, no
    # `readiness`" shape `--schematic-only` already takes -- board
    # generation itself lives in `pcb/`, not here, exactly as the
    # `$VERAX_KEEP_RUNS` schematic job lives in `schematic/render` and not
    # here either.
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
  verify(d, o.allowed, o.verbose, o.strict, o.format, o.baseline)
