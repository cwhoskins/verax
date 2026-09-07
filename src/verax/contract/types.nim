## What a design *claims*, as opposed to what it *is*.
##
## An `Assertion` is one checkable claim: some quantity, of some subjects,
## under some conditions, lies within some expectation. Deliberately not an
## expression language -- see the module doc of `verax/contract` for why, and
## for the escalation path when a plain interval is not enough.
##
## The load-bearing decision is that **`quantity` is the name of an analysis
## `Measurement`** (see `verax/analysis/report`). Evaluating an assertion is
## then "run whatever analysis produces `bw_3db`, then compare", with one
## comparison shared by every quantity; the failing witness comes free,
## because the `Measurement` and the curve behind it already exist; and a
## bench result is also a `Measurement`, so correlating measured against
## simulated is later the same comparison with a different source. It also
## keeps the coupling honest: a quantity nothing can produce is a claim
## nobody can check, and that shows up immediately rather than at report time.

import std/[math, sets, strutils, tables]
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
      ## Net name, designator, `"U1.OUT"`, or a role-instance name.
      ##
      ## Flat, within the design's root netlist. Naming something *inside* a
      ## hierarchical instance needs a path syntax that does not exist yet --
      ## a real gap, called out rather than half-solved, because the right
      ## spelling depends on how imported hierarchy ends up looking.

  MeasurementRef* = object
    ## A reference to another measurement, used as the bound of a relative
    ## expectation or as a named dependency of a predicate.
    quantity*: string
    subjects*: seq[Subject]
    condition*: OrderedTable[string, string]
      ## The circumstances that measurement must be made under. A dependency
      ## is its own measurement request, so its conditions may differ from
      ## the claim's own; the DSL stamps the trailing conditions onto every
      ## one.

  PredicateDep* = object
    name*: string
      ## The author-chosen name, for diagnostics: "dependency 'vdd' ...".
    measurement*: MeasurementRef

  PredicateProc* = proc (values: seq[float]): bool {.nimcall.}
    ## A non-capturing Nim proc over the dependency values, in the order the
    ## dependencies were named. `{.nimcall.}` is what enforces non-capturing:
    ## a proc that reaches an outer variable will not convert and the design
    ## fails to compile, rather than silently capturing state the contract
    ## layer cannot see.

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
    ## A variant object rather than a set of nullable bounds, so the cases
    ## that do not exist yet -- `ekRelative` (a bound referring to another
    ## measurement, for "no more than a fifth of the primary filter") and
    ## `ekPredicate` (an arbitrary Nim proc) -- are additive rather than a
    ## redesign.
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
        ## The multiplier on the referenced measurement's value: "no more
        ## than a fifth of the primary filter" is `coeff = 0.2`.
      reference*: MeasurementRef
      relFracTol*, relAbsTol*: float
        ## The band for `roEq`, as a fraction of the bound or an absolute.
        ## The wider of the two is accepted, exactly as `ekNominal` does.
    of ekPredicate:
      deps*: seq[PredicateDep]
      predicate*: PredicateProc

  Assertion* = object
    id*: string
      ## Stable and human-chosen, so it can be quoted in a report, a commit
      ## message, or a requirements document.
    subjects*: seq[Subject]
      ## A sequence, not one subject plus a second-operand field: setup/hold
      ## is inherently about one signal *versus* another, and a two-subject
      ## quantity must not be a special case bolted on later.
    quantity*: string
      ## An analysis `Measurement` name -- `dc_voltage`, `bw_3db`, `z_min`.
    condition*: OrderedTable[string, string]
      ## Under what circumstances: `"f_from"`/`"f_to"`, `"at_t"`, `"temp"`.
    expect*: Expectation
    unit*: string
    severity*: Severity
    rationale*: string
      ## Why this number. In practice the most valuable field in the object:
      ## a limit whose reason is lost gets relaxed the first time it fails.
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
  ## The operator the author wrote, for a sentence a designer reads. Shared
  ## by the renderer and the verdict, so the two can never spell one of them
  ## two ways.
  case op
  of roLe: "<="
  of roGe: ">="
  of roEq: "=="

proc bounds*(e: Expectation): tuple[lo, hi: float] =
  ## The acceptance interval, with infinities for an open end. `ekNominal`
  ## takes the *wider* of its fractional and absolute tolerances when both are
  ## given, since each is a separate statement of what is acceptable and
  ## meeting either one should pass.
  case e.kind
  of ekNominal:
    let tol = max(abs(e.nominal) * e.fracTol, e.absTol)
    (e.nominal - tol, e.nominal + tol)
  of ekMin: (e.lo, Inf)
  of ekMax: (-Inf, e.hi)
  of ekRange: (e.rlo, e.rhi)
  of ekRelative, ekPredicate:
    # No constant interval exists: the bound is another measurement, or the
    # answer is a proc over several. `NaN` is the honest reading, and the
    # planner never routes either kind through this single-value comparison.
    (NaN, NaN)

proc satisfies*(e: Expectation, value: float): bool =
  ## The comparison every evaluator will share. Exposed now so an assertion
  ## can be checked against a number by hand, and so the semantics are pinned
  ## by tests before anything depends on them.
  ##
  ## A `NaN` value never satisfies anything: "the measurement did not happen"
  ## must not read as a pass.
  ##
  ## A relative or predicate expectation has no single-value answer -- the
  ## planner decomposes those into hidden measurement requests and folds them
  ## back -- so a lone value never satisfies one.
  if value.isNaN: return false
  if e.kind in {ekRelative, ekPredicate}: return false
  let (lo, hi) = e.bounds
  value >= lo and value <= hi

proc satisfies*(e: Expectation, value, reference: float): bool =
  ## The two-value form, for `ekRelative` only. `reference` is the referenced
  ## measurement's value; the bound is `coeff * reference`.
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
  ## A multiplier is a plain number, not an engineering quantity -- `0.2`,
  ## not `200m` -- so `eng` would be the wrong renderer for it.
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
  ## The claim on its own, without the id.
  ##
  ## `$` prefixes the id, which is right for a bare list but wrong for any
  ## renderer that already prints the id as a label -- that produced
  ## `[FAIL] rail.voltage: rail.voltage: dc_voltage(...)`.
  ##
  ## A predicate has no left-hand quantity of its own, so it is spelled
  ## entirely from its named dependencies.
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
# `describe` above is the compact one-line form, right for a list. A report
# that means to be read instead of scanned needs the same claim broken into
# its parts -- what is measured, under what circumstances, and what interval
# would be accepted -- because that is what a reader checks a measurement
# against. Rendering them separately rather than adding a longer `describe`
# keeps each piece placeable: a table wants them in columns, a paragraph
# wants them in a sentence.

const conditionUnits = {
  "f_from": "Hz", "f_to": "Hz", "at_f": "Hz", "drive_f": "Hz",
  "at_t": "s", "settle_t": "s",
  "drive_v": "V", "temp": "degC",
  # The load step's and the ripple tone's, added with them. A step magnitude
  # printed as a bare `1.0` in a report about a rail is exactly the misread
  # the units module exists to remove.
  "step_from": "A", "step_to": "A",
  "step_edge": "s", "step_at": "s", "step_hold": "s", "step_recover": "s",
  "step_band": "",
  "ripple_f": "Hz", "ripple_v": "V",
  "t_settle": "s", "t_window": "s", "t_run": "s"
}.toTable

proc conditionText*(a: Assertion): string =
  ## The circumstances the claim is made under, in words.
  ##
  ## `condition` is the only channel an assertion has for a frequency band, a
  ## drive level or an instant, and stored as raw `key=value` pairs it reads
  ## as machinery -- `[f_from=100k, f_to=100M]` states a band without saying
  ## it is one. A limit whose band is not obvious is a limit nobody checks
  ## against the right part of the curve.
  if a.condition.len == 0: return ""
  var parts: seq[string]
  var used: HashSet[string]

  proc num(key: string): string =
    eng(parseFloat(a.condition[key]), conditionUnits.getOrDefault(key, ""))

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
    of "at_t": parts.add "at t = " & num(k)
    of "temp": parts.add "at " & num(k)
    else: parts.add k & " = " & prettyValue(v)
  parts.join(", ")

proc acceptance*(a: Assertion): string =
  ## The accepted interval as two plain numbers, or "" when the compact form
  ## already is one.
  ##
  ## Only `ekNominal` gets one: a target with a tolerance is the one shape
  ## whose limits a reader has to compute before they can compare a
  ## measurement against them, and `3.30 V +-2.00%` next to `measured 3.37 V`
  ## is a comparison nobody should be doing in their head.
  if a.expect.kind != ekNominal: return ""
  let (lo, hi) = a.expect.bounds
  # A target with no tolerance is already two identical numbers; printing
  # `1.00 (1.00 .. 1.00)` says the same thing three times.
  if lo == hi: return ""
  eng(lo, a.unit) & " .. " & eng(hi, a.unit)
