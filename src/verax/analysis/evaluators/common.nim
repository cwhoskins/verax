## Shared machinery for the simulation-backed contract evaluators. They live
## in `analysis` (not `contract`, which stays simulator-free) and register
## through the ordinary path.
##
## This is the core only: harvest adapter, batch-refusal helper, subject
## resolvers, and the run-scoped operating-point cache. Adapters live beside
## it, one file per evaluator; `contract_eval` registers them all (and is
## what `verify.nim` imports).
##
## **Analyses run in measurement-only mode**: the assertion is the
## authority, so each adapter disables the spec's own limit checks. The
## disabling values differ and are verified: `targetZ`, `overshootLimit`,
## `maxPeaking` need `Inf`; `minPhaseMargin` needs `-Inf`; `currentLimit`
## and `minBandwidth` are disabled by `0`.
##
## Non-limit issues (`pdn_no_decoupling`, `opamp_no_feedback`,
## `*_simulation_failed`) still ride along on `AssertionResult.issues`.

import std/[math, options, strutils, tables]
import ../../netlist/graph
import ../../netlist/kinds
import ../../contract/evaluate
import ../report
import ../analyses/operating
from ../../spice/region_strategy import ScopeChoice

export evaluate, report, operating

# --- shared helpers -----------------------------------------------------

proc groundNetOf*(d: Design): string =
  ## The ground net's name; empty when it's already `"0"` or tagged
  ## `ntGround` (the analyses then find it).
  for name, n in d.netlist.nets:
    if isGround(n): return (if name == "0": "" else: name)
  ""

proc harvest*(a: Assertion, rep: AnalysisReport,
              evaluator: string): AssertionResult =
  ## Compare one assertion against an existing report. The measurement's
  ## unit is passed so `verdict` catches unit mismatches; the report's
  ## assumptions ride along on every result.
  for m in rep.measurements:
    if m.name == a.quantity:
      result = verdict(a, m.value, m.unit, evaluator, rep.assumptions,
                       rep.issues)
      # Say where the number came from when it isn't the subject (e.g.
      # `inrush_peak`).
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
  ## Assumptions ride along even when nothing was measured: a stand-in that
  ## declined usually explains what to state.
  for a in batch:
    var r = notEvaluated(a, evaluator, reason)
    r.assumptions = assumptions
    result.add r

proc subjectNet*(d: Design, a: Assertion): string =
  ## The first net subject's name, or empty. Resolved through `findNet`, so
  ## a path into an instance (`XA.XI.sns`) works; returned as written, which
  ## is also its flattened name.
  for s in a.subjects:
    if s.kind == skNet and findNet(d.netlist, s.name) != nil: return s.name
  ""

proc subjectComponent*(d: Design, a: Assertion): string =
  ## The first component subject's designator, or empty; resolved like
  ## `subjectNet`.
  for s in a.subjects:
    if s.kind == skComponent and findComponent(d.netlist, s.name) != nil:
      return s.name
  ""

proc bindingName*(d: Design, a: Assertion, part: string): string =
  ## A part bound by the role that expanded this assertion (see
  ## `evaluate.originRole`).
  let s = originBinding(d, a, part)
  if s.isNone: return ""
  s.get.name

proc transientWindow*(a: Assertion): tuple[tSettle, tWindow: float] =
  ## The settled-measurement window for `spice.transient`, `spice.oscillator`
  ## and `spice.current_path`: opens at `t_settle`, length `t_window`
  ## (default `t_settle / 5`).
  let tSettle = conditionFloat(a, "t_settle", 0.0)
  var tWindow = conditionFloat(a, "t_window", 0.0)
  if tWindow <= 0.0 and tSettle > 0.0: tWindow = tSettle * 0.2
  (tSettle, tWindow)

# --- the shared operating point -----------------------------------------

const opScratchKey = "spice.operating_point"

type OpCacheEntry = ref object of RootObj
  ## A `RootObj` wrapper, since `contract`'s `scratch` can't name
  ## `OperatingPoint`.
  op: OperatingPoint

proc sharedOperatingPoint*(ctx: EvalContext, unmated: seq[string] = @[]):
    OperatingPoint =
  ## One `.op` per run -- per set of `unmated` connectors -- solved on first
  ## request and reused. Scoped to the `EvalContext`, so it can never be
  ## stale. Shared by `dc_voltage`, derating and DC-bias derating of
  ## capacitors. `unmated` is expected sorted (`unmatedConnectors`).
  let key = if unmated.len == 0: opScratchKey
            else: opScratchKey & ".unmated=" & unmated.join(",")
  if ctx.scratch.hasKey(key):
    return OpCacheEntry(ctx.scratch[key]).op
  var spec = defaultOperatingSpec()
  spec.unmated = unmated
  result = solveOperatingPoint(root(ctx.design.netlist), spec)
  ctx.scratch[key] = OpCacheEntry(op: result)

proc applyScopeConditions*(a: Assertion, choice: var ScopeChoice) =
  ## `ic_sinks = "off"` keeps load ICs' stand-ins (see `ScopeChoice`).
  let v = conditionOf(a, "ic_sinks")
  if v.isSome: choice.icSinks = v.get != "off"
