## `spice.load_step` -- a pulsed load and the rail's response, via `.tran`.

import std/tables
import ./common
import ../analyses/transient

const loadStepQuantities = ["step_droop_v", "step_droop_pct",
                            "step_overshoot_v", "step_overshoot_pct",
                            "step_recover_s", "step_v_min", "step_v_max"]
  ## Not `overshoot_pct`/`settle_time`, which `spice.startup` produces:
  ## start-up and load-step overshoot are different events, and one name
  ## would let one answer the other.

proc measurementOnly(spec: var LoadStepSpec) =
  ## Nothing to disable yet; kept so a future limit field isn't forgotten.
  discard spec

proc loadStepSpecOf(a: Assertion): LoadStepSpec =
  result = defaultLoadStepSpec()
  measurementOnly(result)
  result.iFrom = conditionFloat(a, "step_from", 0.0)
  result.iTo = conditionFloat(a, "step_to", 0.0)
  result.tEdge = conditionFloat(a, "step_edge", 0.0)
  result.tSettle = conditionFloat(a, "step_at", 0.0)
  result.tHold = conditionFloat(a, "step_hold", 0.0)
  result.tRecover = conditionFloat(a, "step_recover", 0.0)
  result.windowSamples = int(conditionFloat(a, "step_points", 0.0))
  result.settleTol = conditionFloat(a, "step_band", 0.0)

proc loadStepKey(ctx: EvalContext, a: Assertion): string =
  # The whole spec, the step magnitude above all (1 A and 3 A are different
  # questions).
  subjectNet(ctx.design, a) & "|" & specKey(loadStepSpecOf(a))

proc loadStepDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let rail = subjectNet(d, batch[0])
  let spec = loadStepSpecOf(batch[0])
  result = "`.tran` over the whole design as authored -- not isolated, so " &
           "the rail has to hold itself up rather than be held by a boundary " &
           "source. A constant-current sink injected at net '" & rail &
           "' steps from " & eng(spec.iFrom, "A") & " to " &
           eng(spec.iTo, "A") & " in " & eng(edgeOf(spec), "s") & " at " &
           eng(spec.tSettle, "s")
  if spec.tHold > 0.0:
    result &= ", holds for " & eng(spec.tHold, "s") & " and is released again"
  else:
    result &= " and stays there"
  result &= ", with " & eng(recoverOf(spec), "s") & " watched after each " &
            "edge. Nothing is added to the design: a test load is not a part " &
            "anybody solders, and a resistor would sag with the rail and damp " &
            "the network being measured"

proc runLoadStep(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.load_step"
  let rail = subjectNet(d, batch[0])
  if rail.len == 0:
    return failBatch(batch, name, "no net subject to measure")

  let spec = loadStepSpecOf(batch[0])
  if spec.iFrom == spec.iTo:
    for a in batch:
      result.add notEvaluable(a, name,
        "a load step needs two currents and this claim carries " &
        eng(spec.iFrom, "A") & " twice. Every quantity here is a difference " &
        "across the edge, so there is no default magnitude to assume -- " &
        "state `iFrom` and `iTo` on the role that expands this claim")
    return

  var rep: AnalysisReport
  try:
    rep = analyzeLoadStep(d.netlist, rail, spec)
  except CatchableError as e:
    return failBatch(batch, name,
      "the load step on '" & rail & "' failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc registerLoadStepEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.load_step", produces: @loadStepQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    conditions: @["step_from", "step_to", "step_edge", "step_at", "step_hold",
                  "step_recover", "step_points", "step_band"],
    units: {"step_droop_v": "V", "step_droop_pct": "%",
            "step_overshoot_v": "V", "step_overshoot_pct": "%",
            "step_recover_s": "s", "step_v_min": "V", "step_v_max": "V"}.toTable,
    setupKey: loadStepKey, setupDoc: loadStepDoc, run: runLoadStep))
