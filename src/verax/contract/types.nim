## What a design *claims*, as opposed to what it *is*.
##
## An `Assertion` is one checkable claim: a quantity, of some subjects,
## under some conditions, lies within an expectation. Not an expression
## language.
##
## **`quantity` names an analysis `Measurement`**, so evaluation is "run
## what produces it, then compare", with one shared comparison, a free
## failing witness, and room for bench results later. A quantity nothing
## produces shows up as unevaluable immediately.

import std/[algorithm, editdistance, math, sets, strutils, tables]
import ../netlist/issue
import ../netlist/annotations
import ../eng

export issue

type
  SubjectKind* = enum
    skNet, skComponent, skPin, skClass, skDesign

  Subject* = object
    kind*: SubjectKind
    name*: string
      ## Net name, designator, `"U1.OUT"`, or a role-instance name; a
      ## `hierSep` path reaches inside an instance (`XL.U1`).

  MeasurementRef* = object
    ## A reference to another measurement, used as the bound of a relative
    ## expectation or as a named dependency of a predicate.
    quantity*: string
    subjects*: seq[Subject]
    condition*: OrderedTable[string, string]
      ## Conditions for that measurement (a dependency is its own request);
      ## the DSL stamps the trailing conditions onto each.

  PredicateDep* = object
    name*: string
      ## The author-chosen name, for diagnostics: "dependency 'vdd' ...".
    measurement*: MeasurementRef

  PredicateProc* = proc (values: seq[float]): bool {.nimcall.}
    ## A non-capturing proc over dependency values, in the order named.
    ## `{.nimcall.}` enforces it: capturing outer state fails to compile.

  RelativeOp* = enum
    roLe   ## `value <= coeff * reference`
    roGe   ## `value >= coeff * reference`
    roEq   ## `value` within the stated band of `coeff * reference`

  ExpectKind* = enum
    ekNominal   ## a target with a tolerance band
    ekMin
    ekMax
    ekRange
    ekRelative  ## a bound referring to another measurement
    ekPredicate ## a Nim proc over named measurement dependencies

  Expectation* = object
    ## A variant object, so new kinds of expectation are additive.
    case kind*: ExpectKind
    of ekNominal:
      nominal*, fracTol*, absTol*: float
    of ekMin:
      lo*: float
    of ekMax:
      hi*: float
    of ekRange:
      rlo*, rhi*: float
    of ekRelative:
      relOp*: RelativeOp
      coeff*: float
        ## Multiplier on the referenced value ("a fifth of" = `0.2`).
      reference*: MeasurementRef
      relFracTol*, relAbsTol*: float
        ## The `roEq` band, fractional or absolute; the wider is accepted.
    of ekPredicate:
      deps*: seq[PredicateDep]
      predicate*: PredicateProc

  Assertion* = object
    id*: string
      ## Stable and human-chosen, so it can be quoted in reports and
      ## requirements.
    subjects*: seq[Subject]
      ## A sequence: multi-subject quantities (one signal versus another)
      ## aren't a special case.
    quantity*: string
      ## An analysis `Measurement` name -- `dc_voltage`, `bw_3db`, `z_min`.
    condition*: OrderedTable[string, string]
      ## Under what circumstances: `"f_from"`/`"f_to"`, `"t_settle"`, ...
      ## Bare keys must be registered (`registerCondition`); `plan` refuses
      ## an unknown one rather than let the evaluator ignore it.
    expect*: Expectation
    unit*: string
    severity*: Severity
    rationale*: string
      ## Why this number -- a limit whose reason is lost gets relaxed the
      ## first time it fails.
    origin*: string
      ## `"authored"`, or the role instance that expanded it.

proc nominal*(target: float, fracTol = 0.0, absTol = 0.0): Expectation =
  Expectation(kind: ekNominal, nominal: target, fracTol: fracTol, absTol: absTol)

proc atLeast*(lo: float): Expectation = Expectation(kind: ekMin, lo: lo)
proc atMost*(hi: float): Expectation = Expectation(kind: ekMax, hi: hi)
proc between*(lo, hi: float): Expectation = Expectation(kind: ekRange, rlo: lo, rhi: hi)

proc measurementRef*(quantity: string, subjects: seq[Subject]): MeasurementRef =
  MeasurementRef(quantity: quantity, subjects: subjects)

proc relative*(op: RelativeOp, coeff: float, reference: MeasurementRef,
               fracTol = 0.0, absTol = 0.0): Expectation =
  ## The runtime form of `value <= coeff * reference`.
  Expectation(kind: ekRelative, relOp: op, coeff: coeff,
              reference: reference, relFracTol: fracTol, relAbsTol: absTol)

proc predicate*(deps: seq[PredicateDep], pred: PredicateProc): Expectation =
  Expectation(kind: ekPredicate, deps: deps, predicate: pred)

proc relOpText*(op: RelativeOp): string =
  ## The operator as written, shared by renderer and verdict.
  case op
  of roLe: "<="
  of roGe: ">="
  of roEq: "=="

proc bounds*(e: Expectation): tuple[lo, hi: float] =
  ## The acceptance interval (infinite open ends). `ekNominal` takes the
  ## *wider* of its fractional and absolute tolerances.
  case e.kind
  of ekNominal:
    let tol = max(abs(e.nominal) * e.fracTol, e.absTol)
    (e.nominal - tol, e.nominal + tol)
  of ekMin: (e.lo, Inf)
  of ekMax: (-Inf, e.hi)
  of ekRange: (e.rlo, e.rhi)
  of ekRelative, ekPredicate:
    # No constant interval: the bound is another measurement or a proc.
    (NaN, NaN)

proc satisfies*(e: Expectation, value: float): bool =
  ## The comparison every evaluator shares. A `NaN` value never satisfies;
  ## nor does a lone value against a relative or predicate expectation
  ## (the planner decomposes those).
  if value.isNaN: return false
  if e.kind in {ekRelative, ekPredicate}: return false
  let (lo, hi) = e.bounds
  value >= lo and value <= hi

proc satisfies*(e: Expectation, value, reference: float): bool =
  ## The two-value form, `ekRelative` only: the bound is `coeff *
  ## reference`.
  if e.kind != ekRelative: return false
  if value.isNaN or reference.isNaN: return false
  let bound = e.coeff * reference
  case e.relOp
  of roLe: value <= bound
  of roGe: value >= bound
  of roEq:
    let tol = max(abs(bound) * e.relFracTol, e.relAbsTol)
    value >= bound - tol and value <= bound + tol

proc coeffText(c: float): string =
  ## A multiplier is a plain number (`0.2`, not `200m`), so not `eng`.
  var t = formatFloat(c, ffDecimal, 9)
  while t.endsWith("0"): t.setLen(t.len - 1)
  if t.endsWith("."): t.setLen(t.len - 1)
  t

proc `$`*(s: Subject): string =
  case s.kind
  of skNet: "net '" & s.name & "'"
  of skComponent: s.name
  of skPin: "pin " & s.name
  of skClass: "role " & s.name
  of skDesign: "the design"

proc `$`*(e: Expectation, unit = ""): string =
  case e.kind
  of ekNominal:
    result = eng(e.nominal, unit)
    if e.fracTol > 0.0: result &= " +-" & eng(e.fracTol * 100.0) & "%"
    if e.absTol > 0.0: result &= " +-" & eng(e.absTol, unit)
  of ekMin: result = ">= " & eng(e.lo, unit)
  of ekMax: result = "<= " & eng(e.hi, unit)
  of ekRange: result = eng(e.rlo, unit) & " .. " & eng(e.rhi, unit)
  of ekRelative:
    var subj: seq[string]
    for s in e.reference.subjects: subj.add $s
    let refText = e.reference.quantity & "(" & subj.join(", ") & ")"
    result = relOpText(e.relOp) & " "
    if e.coeff != 1.0: result &= coeffText(e.coeff) & " * "
    result &= refText
    if e.relOp == roEq and (e.relFracTol > 0.0 or e.relAbsTol > 0.0):
      if e.relFracTol > 0.0: result &= " +-" & eng(e.relFracTol * 100.0) & "%"
      if e.relAbsTol > 0.0: result &= " +-" & eng(e.relAbsTol, unit)
  of ekPredicate:
    var parts: seq[string]
    for d in e.deps:
      var subj: seq[string]
      for s in d.measurement.subjects: subj.add $s
      parts.add d.name & " = " & d.measurement.quantity & "(" &
               subj.join(", ") & ")"
    result = "predicate(" & parts.join(", ") & ")"

proc describe*(a: Assertion): string =
  ## The claim without its id (for renderers that print the id as a label).
  ## A predicate is spelled from its named dependencies.
  if a.expect.kind == ekPredicate:
    result = `$`(a.expect, a.unit)
    if a.condition.len > 0:
      var conds: seq[string]
      for k, v in a.condition: conds.add k & "=" & prettyValue(v)
      result &= " [" & conds.join(", ") & "]"
    return
  var subj: seq[string]
  for s in a.subjects: subj.add $s
  result = a.quantity & "(" & subj.join(", ") & ") " & `$`(a.expect, a.unit)
  if a.condition.len > 0:
    var conds: seq[string]
    for k, v in a.condition: conds.add k & "=" & prettyValue(v)
    result &= " [" & conds.join(", ") & "]"

proc `$`*(a: Assertion): string =
  result = describe(a)
  if a.id.len > 0:
    result = a.id & ": " & result

# --- saying a claim out loud ---------------------------------------------
#
# The claim broken into parts -- what's measured, under what circumstances,
# what interval is accepted -- so tables and sentences can place each.

# --- the condition vocabulary --------------------------------------------
#
# Conditions are the inputs that most directly change what gets simulated,
# so a misspelled one (`f_form`) must not be silently ignored while the
# evaluator falls back to its default. As with annotations: a **bare key must
# be registered**, a dotted key is owned by whoever wrote it and never
# validated. `plan` refuses a claim carrying an unknown bare key or a value
# that doesn't parse (`conditionProblem`).

type
  ConditionKind* = enum
    cdFloat   ## a plain SI number (`parseAnnFloat`): no SPICE suffixes
    cdText    ## a word, optionally from `allowed`

  ConditionDef* = object
    key*: string
    kind*: ConditionKind
    unit*: string
      ## SI unit for rendering; "" for dimensionless or caller-dependent.
    allowed*: seq[string]
      ## `cdText` only; empty means any word.
    doc*: string

proc cond(key: string, unit, doc: string): ConditionDef =
  ConditionDef(key: key, kind: cdFloat, unit: unit, doc: doc)

let builtinConditions = [
  cond("f_from", "Hz", "lower edge of a swept or judged band"),
  cond("f_to", "Hz", "upper edge of a swept or judged band"),
  cond("at_f", "Hz", "the single frequency a point figure is read at"),
  cond("drive_v", "V", "large-signal drive amplitude"),
  cond("drive_f", "Hz", "large-signal drive frequency"),
  cond("kick_v", "V", "oscillator start-up kick amplitude"),
  cond("t_settle", "s", "time before a settled-measurement window opens"),
  cond("t_window", "s", "length of the settled-measurement window"),
  cond("t_run", "s", "start-up transient length"),
  cond("step_from", "A", "load-step current before the edge"),
  cond("step_to", "A", "load-step current after the edge"),
  cond("step_edge", "s", "load-step edge time"),
  cond("step_at", "s", "when the load step happens"),
  cond("step_hold", "s", "how long the stepped load is held (0: no release)"),
  cond("step_recover", "s", "how long recovery is watched for"),
  cond("step_points", "", "load-step sample count"),
  cond("step_band", "", "recovery band, as a fraction of the settled level"),
  cond("ripple_f", "Hz", "injected ripple frequency"),
  cond("ripple_v", "V", "injected ripple amplitude"),
  cond("ripple_periods", "", "ripple periods measured"),
  cond("ripple_points", "", "samples per ripple period"),
  cond("sweep_from", "", "DC sweep start (volts for a source, amps for a load)"),
  cond("sweep_to", "", "DC sweep end"),
  cond("sweep_step", "", "DC sweep increment"),
  cond("v_nominal", "V", "the nominal line voltage percentages refer to"),
  ConditionDef(key: "ic_sinks", kind: cdText, allowed: @["on", "off"],
               doc: "whether a load IC on a rail is drawn as a constant " &
                    "current sink (the `source_closed` scope); off keeps " &
                    "its stand-in"),
  ConditionDef(key: "sweep", kind: cdText, allowed: @["source", "load"],
               doc: "which DC sweep: an existing source, or an injected load"),
  ConditionDef(key: "unmated", kind: cdText,
               doc: "connectors with nothing plugged in, comma-separated " &
                    "designators (\"J3\", \"J2,J3\"): each is removed from " &
                    "the bench, so the board is checked with the cable pulled"),
]

proc unmatedConnectors*(a: Assertion): seq[string] =
  ## The `unmated` condition's designators, trimmed and sorted (so a
  ## setup key built from them is order-independent); empty when absent.
  if not a.condition.hasKey("unmated"): return
  for part in a.condition["unmated"].split(','):
    let d = part.strip()
    if d.len > 0 and d notin result: result.add d
  result.sort()

var conditionRegistry: OrderedTable[string, ConditionDef]
for d in builtinConditions: conditionRegistry[d.key] = d

proc registerCondition*(def: ConditionDef) =
  ## Adds (or replaces) a bare condition key, for an evaluator that reads
  ## one the built-ins don't. A dotted key needs no registration.
  if def.key.len == 0 or '.' in def.key:
    raise newException(ValueError,
      "a registered condition key must be bare and non-empty: '" & def.key & "'")
  conditionRegistry[def.key] = def

proc isConditionKey*(key: string): bool = conditionRegistry.hasKey(key)

proc conditionDef*(key: string): ConditionDef =
  if not conditionRegistry.hasKey(key):
    raise newException(KeyError, "no such condition: " & key)
  conditionRegistry[key]

proc registeredConditions*(): seq[string] =
  for k in conditionRegistry.keys: result.add k

proc conditionProblem*(a: Assertion): string =
  ## Why this claim's conditions can't be trusted, or "". An unknown bare
  ## key, a number that isn't a plain SI value, or a word outside `allowed`.
  for k, v in a.condition:
    if '.' in k: continue
    if not conditionRegistry.hasKey(k):
      var best = ""
      var bestD = high(int)
      for known in conditionRegistry.keys:
        let d = editDistance(k, known)
        if d < bestD: (best, bestD) = (known, d)
      result = "unknown condition '" & k & "'"
      if bestD <= 2: result &= " -- did you mean '" & best & "'?"
      result &= " A misspelled condition would be ignored and the " &
                "evaluator's default used; namespace it ('mine." & k &
                "') if it is your own note"
      return
    let def = conditionRegistry[k]
    case def.kind
    of cdFloat:
      try: discard parseAnnFloat(k, v)
      except CatchableError as e: return "condition " & e.msg
    of cdText:
      if def.allowed.len > 0 and v notin def.allowed:
        return "condition '" & k & "' = " & v.escape() & " is not one of " &
               def.allowed.join(", ")

proc conditionText*(a: Assertion): string =
  ## The claim's circumstances in words (`over 100 kHz .. 100 MHz`, not
  ## `[f_from=100k, f_to=100M]`).
  if a.condition.len == 0: return ""
  var parts: seq[string]
  var used: HashSet[string]

  proc num(key: string): string =
    let unit = if conditionRegistry.hasKey(key): conditionRegistry[key].unit
               else: ""
    eng(parseFloat(a.condition[key]), unit)

  if a.condition.hasKey("f_from") and a.condition.hasKey("f_to"):
    parts.add "over " & num("f_from") & " .. " & num("f_to")
    used.incl "f_from"
    used.incl "f_to"
  if a.condition.hasKey("drive_v") and a.condition.hasKey("drive_f"):
    parts.add "driven at " & num("drive_v") & ", " & num("drive_f")
    used.incl "drive_v"
    used.incl "drive_f"

  for k, v in a.condition:
    if k in used: continue
    case k
    of "at_f": parts.add "at " & num(k)
    else: parts.add k & " = " & prettyValue(v)
  parts.join(", ")

proc acceptance*(a: Assertion): string =
  ## The accepted interval as two numbers, or "". Only `ekNominal`, whose
  ## limits a reader would otherwise compute (`3.30 V +-2.00%`).
  if a.expect.kind != ekNominal: return ""
  let (lo, hi) = a.expect.bounds
  # No tolerance: the interval is one number.
  if lo == hi: return ""
  eng(lo, a.unit) & " .. " & eng(hi, a.unit)
