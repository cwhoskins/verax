## Running a design's contract, and saying plainly what was *not* checked.
##
## `nimcir/contract` can already state intent and evaluate it; `nimcir/analysis`
## can already check a netlist's structure. Neither is reachable without
## writing a program, and nothing joins the two into one answer. This module is
## that answer: the runner behind `nimcir check` and behind the one line a
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

import std/[algorithm, editdistance, os, osproc, sets, strutils, tables,
            wordwrap]

import ./eng
import ./netlist/annotations
import ./netlist/environment
import ./analysis/io_check
import ./analysis/contract_eval

export contract_eval, io_check, environment

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
    needs*: Capability
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
      ## The same steps, with what each one produced. One per plan step, in
      ## plan order.
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
    ## The design file did not compile. Only `nimcir check` produces this --
    ## a design file that failed to build never ran to report anything. It is
    ## separate from every other code on purpose: told only "it failed", a
    ## reader edits the circuit to fix what is actually a syntax error.

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
  ## third-party role must not make `nimcir roles` unusable.
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

  result.environment = environmentOf(d.netlist)
  result.hottest = describeHottest(d.netlist, result.environment)

  let usable = allowed * result.available
  result.plan = plan(d, usable)
  # The simulated evaluators share one operating point across the whole run,
  # and its cache is keyed by design identity with no content invalidation --
  # nothing down there can tell that a caller edited a netlist between two
  # checks. Clearing it here is what makes that rule safe: within this call
  # the design does not change, and every entry into it starts clean.
  clearSharedOperatingPoint()
  let batches = runPlan(d, result.plan)
  clearSharedOperatingPoint()

  # Run through the plan rather than calling `evaluate`, which flattens the
  # batches away. The grouping cannot be recovered afterwards: a result
  # carries its evaluator's name but not its setup key, and two steps of one
  # evaluator -- a PDN sweep of two rails, a start-up of two regulators --
  # are two separate runs resting on two separate sets of assumptions.
  for i, step in result.plan.steps:
    var c = Check(evaluator: step.evaluator, needs: step.needs, key: step.key,
                  setup: describeStep(d, step), results: batches[i])
    var seen = initHashSet[string]()
    for r in c.results:
      for a in r.assumptions:
        if a.source == annAuthored: continue
        let text = $a
        if text in seen: continue
        seen.incl text
        c.assumptions.add a
    result.checks.add c
    for r in batches[i]: result.results.add r

  result.rejected = rejectionResults(result.plan)
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

proc capList(s: set[Capability]): string =
  var parts: seq[string]
  for c in s: parts.add capLabel(c)
  if parts.len == 0: "none" else: parts.join(", ")

proc sevLabel(s: Severity): string =
  case s
  of sevInfo: "info"
  of sevWarning: "warning"
  of sevError: "error"

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
    cmpLine &= "   measured " & eng(r.value, r.unit)
    # `reason` carries more than the bare number when the measurement was
    # taken somewhere the subject does not name -- `inrush_peak` is read on
    # the rail being charged, not on the net the claim judges.
    let at = r.reason.find(" at ")
    if at >= 0: cmpLine &= r.reason[at .. ^1]
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
    if c.needs == capStatic: inc walks else: inc sims

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

proc render*(r: Readiness, verbose = false): string =
  ## The whole finding, ordered so the actionable part cannot be missed.
  var L: seq[string]

  var seenIssues = initHashSet[string]()
  L.add "nimcir -- design '" & r.design & "'"
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
          L.add "           run `nimcir quantities` for what can be measured"

  L.add ""
  if r.results.len == 0:
    L.add "NO CLAIMS  this design states nothing that could be checked"
    for line in indented("A netlist on its own asserts nothing, so there is " &
        "nothing here to pass or fail. Add a `role` or a `require`; " &
        "`nimcir roles` and `nimcir quantities` list what is available.",
        "  "):
      L.add line
    L.add ""
  L.add summary(r.results)
  let code = exitCode(r)
  L.add "exit " & $code & " (" & exitLabel(code) & ")"
  L.join("\n")

proc verify*(d: Design, allowed = allCapabilities, verbose = false,
             strict = false): int =
  ## Check a design, print the report, and hand back the exit code.
  ##
  ## The one line a design file ends with: `quit(verify(d))`.
  let r = readiness(d, allowed)
  echo render(r, verbose)
  exitCode(r, strict)

# --- command-line entry --------------------------------------------------

type
  VerifyOptions* = object
    allowed*: set[Capability]
    verbose*, strict*: bool

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
    of "ac": result.incl capSpiceAc
    of "tran": result.incl capSpiceTran
    of "all", "sim": result = result + simCapabilities
    else:
      raise newException(ValueError,
        "unknown capability '" & raw.strip() &
        "'; expected any of static, op, ac, tran, all")

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

# --- the catalog: what may be claimed ------------------------------------
#
# Rendered to strings rather than printed, because there are two consumers
# with no terminal in common: the CLI echoes these, and the MCP server
# returns them. An author working outside this repository has no other way
# to find out what vocabulary exists.

proc describeRoles*(): string =
  var L = @["roles -- each is a bundle of claims you get by naming it", ""]
  for name in registeredRoles():
    let def = roleDef(name)
    L.add name
    L.add "    " & def.doc
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
  L.add "`nimcir role <name>` shows the claims each one makes."
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
      "no role named '" & name & "'; `nimcir roles` lists them")
  let def = roleDef(name)
  var L = @["role " & def.name & " -- " & def.doc, "", "parts"]
  for p in def.parts:
    L.add "  " & p.name.alignLeft(14) &
          ($p.kind)[2 .. ^1].toLowerAscii.alignLeft(11) &
          (if p.optional: "optional  " else: "required  ") & p.doc
  if def.params.len > 0:
    L.add ""
    L.add "params"
    for p in def.params:
      L.add "  " & p.key.alignLeft(14) &
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
    L.add "  " & q.alignLeft(w + 2) & ev.get.name.alignLeft(24) &
          ("[" & capLabel(ev.get.needs) & "]").alignLeft(10) & reach

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
    L.add "`nimcir guide` shows how, and the built-ins use no mechanism yours cannot."
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
  verify(d, o.allowed, o.verbose, o.strict)
