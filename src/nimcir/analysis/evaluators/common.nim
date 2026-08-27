## Shared machinery for the simulation-backed contract evaluators.
##
## `contract/evaluate` depends only on `nimcir/netlist`, which is what keeps a
## design and its contract inspectable with no simulator in the build. The
## evaluators that *do* need one therefore cannot live there, and live here
## instead: `analysis` already depends on `spice`, and an `Evaluator` is a
## value with a `proc` field, so registering one from another module is the
## ordinary path rather than a workaround.
##
## **This module is the core only** -- the harvest adapter, the batch-refusal
## helper, the subject resolvers and the run-scoped operating-point cache that
## every adapter shares. The adapters themselves live beside it under
## `analysis/evaluators/`, one file per evaluator (tightly-coupled evaluators
## share one), and `analysis/evaluators/contract_eval` assembles them: it
## imports each, calls their `register*` procs from `registerSimulatedEvaluators`
## and runs it at init. Import `analysis/evaluators/common` for the machinery;
## import `analysis/evaluators/contract_eval` (which `verify.nim` does) to get
## the simulated evaluators registered.
##
## **Every analysis runs in measurement-only mode.** Each `*Spec` carries
## limit fields (`targetZ`, `minBandwidth`, `overshootLimit`, ...) that state
## the same kind of claim an `Assertion` states. Left live, the same claim is
## reported twice -- once as an `Issue` from the analysis and once as an
## `AssertionResult` -- possibly against two different thresholds. The
## assertion is the authority, so each adapter disables those checks and keeps
## only the measurements, through a local `measurementOnly` overload. The
## disabling values are **not consistent** across the modules and are verified
## rather than assumed: `targetZ` and `overshootLimit` and `maxPeaking` are `>`
## comparisons needing `Inf` (`targetZ = 0` would flag *every* rail),
## `minPhaseMargin` is a `<` comparison needing `-Inf`, while `currentLimit`
## and `minBandwidth` are explicitly gated on `> 0` and so are disabled by
## zero.
##
## Issues that are *not* limit checks -- `pdn_no_decoupling`,
## `opamp_no_feedback`, `*_simulation_failed` -- still ride along on
## `AssertionResult.issues` as context, since they are diagnosis rather than a
## duplicate verdict.

import std/[math, options, strutils, tables]
import ../../netlist/graph
import ../../netlist/kinds
import ../../contract/evaluate
import ../report
import ../analyses/operating

export evaluate, report, operating

# --- shared helpers -----------------------------------------------------

proc groundNetOf*(d: Design): string =
  ## The ground net's name, for analyses that need it named explicitly.
  ## Empty when the design already calls it `"0"` or tags it `ntGround`, which
  ## is what those analyses treat as "work it out yourself".
  for name, n in d.netlist.nets:
    if isGround(n): return (if name == "0": "" else: name)
  ""

proc harvest*(a: Assertion, rep: AnalysisReport,
              evaluator: string): AssertionResult =
  ## Compare one assertion against a report that has already been produced.
  ##
  ## The measurement's own unit is passed through so `verdict` can catch a
  ## claim stated in the wrong one, and the report's assumptions ride along on
  ## every result drawn from it -- a verdict that rests on an assumed op-amp
  ## macromodel or a package-typical ESL has to carry that with it.
  for m in rep.measurements:
    if m.name == a.quantity:
      result = verdict(a, m.value, m.unit, evaluator, rep.assumptions,
                       rep.issues)
      # Where the number actually came from, when the subject would imply
      # somewhere else. Silence here reads as "measured on the subject",
      # which for `inrush_peak` is not true and cannot be made true: the
      # subject has to name the judged net for the isolation to be right.
      if m.at.len > 0 and a.subjects.len > 0 and
         m.at != ("net '" & a.subjects[0].name & "'") and
         result.reason.len > 0:
        result.reason &= " at " & m.at
      return result
  var produced: seq[string]
  for m in rep.measurements: produced.add m.name
  result = notEvaluable(a, evaluator,
    "the analysis produced no '" & a.quantity & "'; it measured " &
    produced.join(", "))
  result.assumptions = rep.assumptions
  result.issues = rep.issues

proc failBatch*(batch: seq[Assertion], evaluator, reason: string,
                assumptions: seq[Assumption] = @[]): seq[AssertionResult] =
  ## Assumptions ride along even when nothing was measured. That is not
  ## bookkeeping: when a stand-in *declines* to model a part it explains what
  ## to state so it could, and dropping that leaves the reader holding a raw
  ## ngspice error instead of the one sentence that fixes it.
  for a in batch:
    var r = notEvaluated(a, evaluator, reason)
    r.assumptions = assumptions
    result.add r

proc subjectNet*(d: Design, a: Assertion): string =
  ## The first net-shaped subject's name, or empty.
  ##
  ## Resolved through `findNet` rather than by a flat key lookup, so a subject
  ## naming a net *inside* a subcircuit instance -- `XA.XI.sns`, which is what
  ## `design.innerNet` builds and what `resolve` already accepts when the role
  ## or requirement is attached -- is found here too. A flat lookup made that
  ## subject representable, bindable and then uncheckable, reporting `needs a
  ## net subject that exists in this design` about a net that does.
  ##
  ## The name is returned exactly as written, because `spice/flatten` names
  ## the same net by the same path once the hierarchy is gone -- and the
  ## flattened netlist is the one the operating point was solved on.
  for s in a.subjects:
    if s.kind == skNet and findNet(d.netlist, s.name) != nil: return s.name
  ""

proc subjectComponent*(d: Design, a: Assertion): string =
  ## The first component-shaped subject's designator, or empty. The
  ## counterpart of `subjectNet`, resolved the same way and for the same
  ## reason: a part *inside* a subcircuit instance is named by a
  ## `hierSep`-separated path, and `spice/flatten` keeps that path.
  for s in a.subjects:
    if s.kind == skComponent and findComponent(d.netlist, s.name) != nil:
      return s.name
  ""

proc bindingName*(d: Design, a: Assertion, part: string): string =
  ## A part bound by the role that expanded this assertion. This is how an
  ## adapter recovers topology the assertion does not carry -- see
  ## `evaluate.originRole`.
  let s = originBinding(d, a, part)
  if s.isNone: return ""
  s.get.name

proc transientWindow*(a: Assertion): tuple[tSettle, tWindow: float] =
  ## The settled-measurement window, shared by `spice.transient`,
  ## `spice.oscillator` and `spice.current_path`: `t_settle` opens it and
  ## `t_window` is its length, defaulting to a fifth of `t_settle`.
  let tSettle = conditionFloat(a, "t_settle", 0.0)
  var tWindow = conditionFloat(a, "t_window", 0.0)
  if tWindow <= 0.0 and tSettle > 0.0: tWindow = tSettle * 0.2
  (tSettle, tWindow)

# --- the shared operating point -----------------------------------------

const opScratchKey = "spice.operating_point"

type OpCacheEntry = ref object of RootObj
  ## `EvalContext.scratch` is type-erased on purpose -- `contract` may not
  ## name an `OperatingPoint`, which lives up here in `analysis`. So the
  ## owning module wraps its own type and downcasts on the way out.
  op: OperatingPoint

proc sharedOperatingPoint*(ctx: EvalContext): OperatingPoint =
  ## One `.op` per run, solved on first request and reused by everything
  ## after it.
  ##
  ## **Scoped to the `EvalContext`, which is what makes it correct rather
  ## than merely conventional.** This was a module-level `var` keyed on
  ## `Design` reference identity with no content invalidation, and it carried
  ## a documented rule instead of a guarantee: a caller that edited a design
  ## and evaluated again got a stale operating point with no diagnostic, two
  ## designs checked in one process shared one slot, and `verify.readiness`
  ## had to bracket every run with a cache-clearing call to stay safe. A
  ## context lives exactly as long as one run, and a design does not change
  ## under a run, so there is no window in which the entry can be wrong.
  ##
  ## Sharing it is worth having. `dc_voltage` solved one, `analysis/derating`
  ## solved another per claimed rail, and every one of them was the same
  ## design with the same answer -- a design claiming two rails plus derating
  ## on both did three identical solves. It also makes DC-bias derating see
  ## nodes that no annotation describes, which is the blind spot that mattered.
  if ctx.scratch.hasKey(opScratchKey):
    return OpCacheEntry(ctx.scratch[opScratchKey]).op
  result = solveOperatingPoint(root(ctx.design.netlist))
  ctx.scratch[opScratchKey] = OpCacheEntry(op: result)
