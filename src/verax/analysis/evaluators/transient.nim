## `spice.transient` -- what a node settled to (settling and ripple), via `.tran`.

import std/tables
import ./common
import ../analyses/transient

const transientQuantities = ["settled_v", "ripple_pp",
                             "settled_min", "settled_max"]
  ## Not `final_v`, which `spice.startup` produces (one producer per
  ## quantity).

proc measurementOnly(spec: var TransientSpec) =
  spec.settleTol = 0.0       ## explicitly gated on `> 0`

proc transientSpecOf(a: Assertion): TransientSpec =
  result = defaultTransientSpec()
  measurementOnly(result)
  let (tSettle, tWindow) = transientWindow(a)
  result.tSettle = tSettle
  result.tWindow = tWindow

proc transientKey(ctx: EvalContext, a: Assertion): string =
  subjectNet(ctx.design, a) & "|" & specKey(transientSpecOf(a))

proc transientDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let rail = subjectNet(d, batch[0])
  let (tSettle, tWindow) = transientWindow(batch[0])
  result = "`.tran` over the whole design as authored -- not isolated, so " &
           "the node has to arrive where it arrives rather than be held " &
           "there by a boundary source. Reading net '" & rail & "'"
  if tSettle > 0.0:
    result &= " over " & eng(tWindow, "s") & " from " & eng(tSettle, "s") &
              ", with everything before that simulated and discarded"
  else:
    result &= " over the whole run"

proc runTransient(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.transient"
  let rail = subjectNet(d, batch[0])
  if rail.len == 0:
    return failBatch(batch, name, "no net subject to measure")

  let spec = transientSpecOf(batch[0])

  var rep: AnalysisReport
  try:
    rep = analyzeTransient(d.netlist, rail, spec)
  except CatchableError as e:
    return failBatch(batch, name,
      "the transient run on '" & rail & "' failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc registerTransientEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.transient", produces: @transientQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    conditions: @["t_settle", "t_window"],
    units: {"settled_v": "V", "ripple_pp": "V", "settled_min": "V",
            "settled_max": "V"}.toTable,
    setupKey: transientKey, setupDoc: transientDoc, run: runTransient))
