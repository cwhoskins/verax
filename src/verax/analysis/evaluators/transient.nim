## `spice.transient` -- what a node settled to (settling and ripple), via `.tran`.

import ./common
import ../analyses/transient

const transientQuantities = ["settled_v", "ripple_pp",
                             "settled_min", "settled_max"]
  ## Deliberately **not** `final_v`, which `spice.startup` already produces.
  ## `analyzeTransient` measures one and the report shows it, but a second
  ## evaluator claiming the quantity would take over every `final_v` claim in
  ## every design; `registerEvaluator` refuses it outright, and that refusal
  ## is the reason this list is shorter than the analysis's own output.

proc measurementOnly(spec: var TransientSpec) =
  spec.settleTol = 0.0       ## explicitly gated on `> 0`

proc transientKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # The window joins the key for the same reason the drive level does on the
  # large-signal side: it is what was run, not what is claimed, so two claims
  # over two windows are two runs rather than one run reported twice.
  subjectNet(d, a) & "|" & $conditionFloat(a, "t_settle", 0.0) &
                     "|" & $conditionFloat(a, "t_window", 0.0)

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

  var spec = defaultTransientSpec()
  measurementOnly(spec)
  let (tSettle, tWindow) = transientWindow(batch[0])
  spec.tSettle = tSettle
  spec.tWindow = tWindow

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
    setupKey: transientKey, setupDoc: transientDoc, run: runTransient))
