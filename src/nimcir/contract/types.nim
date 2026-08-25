## What a design *claims*, as opposed to what it *is*.
##
## An `Assertion` is one checkable claim: some quantity, of some subjects,
## under some conditions, lies within some expectation. Deliberately not an
## expression language -- see the module doc of `nimcir/contract` for why, and
## for the escalation path when a plain interval is not enough.
##
## The load-bearing decision is that **`quantity` is the name of an analysis
## `Measurement`** (see `nimcir/analysis/report`). Evaluating an assertion is
## then "run whatever analysis produces `bw_3db`, then compare", with one
## comparison shared by every quantity; the failing witness comes free,
## because the `Measurement` and the curve behind it already exist; and a
## bench result is also a `Measurement`, so correlating measured against
## simulated is later the same comparison with a different source. It also
## keeps the coupling honest: a quantity nothing can produce is a claim
## nobody can check, and that shows up immediately rather than at report time.

import std/[math, strutils, tables]
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

  ExpectKind* = enum
    ekNominal   ## a target with a tolerance band
    ekMin
    ekMax
    ekRange

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

proc satisfies*(e: Expectation, value: float): bool =
  ## The comparison every evaluator will share. Exposed now so an assertion
  ## can be checked against a number by hand, and so the semantics are pinned
  ## by tests before anything depends on them.
  ##
  ## A `NaN` value never satisfies anything: "the measurement did not happen"
  ## must not read as a pass.
  if value.isNaN: return false
  let (lo, hi) = e.bounds
  value >= lo and value <= hi

proc `$`*(e: Expectation, unit = ""): string =
  case e.kind
  of ekNominal:
    result = eng(e.nominal, unit)
    if e.fracTol > 0.0: result &= " +-" & eng(e.fracTol * 100.0) & "%"
    if e.absTol > 0.0: result &= " +-" & eng(e.absTol, unit)
  of ekMin: result = ">= " & eng(e.lo, unit)
  of ekMax: result = "<= " & eng(e.hi, unit)
  of ekRange: result = eng(e.rlo, unit) & " .. " & eng(e.rhi, unit)

proc `$`*(s: Subject): string =
  case s.kind
  of skNet: "net '" & s.name & "'"
  of skComponent: s.name
  of skPin: "pin " & s.name
  of skClass: "role " & s.name
  of skDesign: "the design"

proc describe*(a: Assertion): string =
  ## The claim on its own, without the id.
  ##
  ## `$` prefixes the id, which is right for a bare list but wrong for any
  ## renderer that already prints the id as a label -- that produced
  ## `[FAIL] rail.voltage: rail.voltage: dc_voltage(...)`.
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
