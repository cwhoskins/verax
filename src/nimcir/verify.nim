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

import std/[algorithm, editdistance, os, osproc, sets, strutils, tables,
            wordwrap]

import ./netlist/annotations
import ./netlist/environment
import ./analysis/io_check
import ./analysis/contract_eval

export contract_eval, io_check, environment

type
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
    results*: seq[AssertionResult]

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
  result.results = evaluate(d, usable)
  clearSharedOperatingPoint()
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

proc capLabel*(c: Capability): string =
  ## Short form, shared by the report and the CLI so one capability never
  ## appears under two names.
  case c
  of capStatic: "static"
  of capSpiceOp: ".op"
  of capSpiceAc: ".ac"
  of capSpiceTran: ".tran"
  of capBench: "bench"

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

proc renderResult(L: var seq[string], r: AssertionResult,
                  seenIssues: var HashSet[string], tag = "",
                  showIssues = true) =
  L.add "  " & (if tag.len > 0: tag & " " else: "") & label(r.assertion) &
        "  --  " & describe(r.assertion)
  if r.reason.len > 0:
    for line in indented(r.reason, "      "): L.add line

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
  if not showIssues: return
  for i in r.issues:
    if i.message in seenIssues: continue
    seenIssues.incl i.message
    L.add "      [" & sevLabel(i.severity) & "] " & i.kind
    for line in indented(i.message, "        "): L.add line

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
  var walks, sims = 0
  for s in r.plan.steps:
    if s.needs == capStatic: inc walks else: inc sims
  L.add "PLAN  " & $assertionCount(r.plan) & " claim(s) via " &
        $walks & " graph walk(s) and " & $sims & " simulation run(s)"
  if verbose:
    for line in explainPlan(r.plan).splitLines()[1 .. ^1]: L.add line
  else:
    var w = 0
    for s in r.plan.steps: w = max(w, s.evaluator.len)
    for s in r.plan.steps:
      L.add "  " & s.evaluator.alignLeft(w + 2) &
            "[" & capLabel(s.needs) & "]" &
            (if s.key.len > 0: "  on " & s.key else: "") &
            "  -- " & $s.assertions.len

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
      let tag = if res.status == esNotEvaluable: "[not evaluable]"
                else: "[not evaluated]"
      renderResult(L, res, seenIssues, tag)
      if res.status == esNotEvaluable and
         res.reason.startsWith("no evaluator produces"):
        let near = didYouMean(res.assertion.quantity)
        if near.len > 0:
          L.add "      did you mean: " & near.join(", ") & "?"
        else:
          L.add "      run `nimcir quantities` for what can be measured"

  if verbose:
    var good: seq[AssertionResult]
    for res in r.results:
      if res.status == esPass: good.add res
    if good.len > 0:
      L.add ""
      L.add "PASSED  " & $good.len
      # A passing claim's issues are noise: it passed.
      for res in good: renderResult(L, res, seenIssues, showIssues = false)

  var seen: seq[string]
  for a in invented(r.results):
    let text = $a
    if text notin seen: seen.add text
  if seen.len > 0:
    L.add ""
    L.add "ASSUMPTIONS  " & $seen.len & " value(s) nobody stated"
    for text in seen:
      for line in indented(text, "  ", "      "): L.add line

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
