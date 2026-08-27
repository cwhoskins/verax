## `spice.load_step` -- a pulsed load and the rail's response, via `.tran`.

import ./common
import ../analyses/transient

const loadStepQuantities = ["step_droop_v", "step_droop_pct",
                            "step_overshoot_v", "step_overshoot_pct",
                            "step_recover_s", "step_v_min", "step_v_max"]
  ## Deliberately none of `overshoot_pct` or `settle_time`, which
  ## `spice.startup` already produces and `registerEvaluator` would refuse a
  ## second producer of. That refusal is right here rather than merely
  ## procedural: a start-up overshoot is what a rail does on the way up from
  ## nothing, and a step overshoot is what it does on the way back down from
  ## a load. Two different measurements about two different events, and one
  ## name for both would let a claim about one be answered with the other.

proc measurementOnly(spec: var LoadStepSpec) =
  ## `analyzeLoadStep` states no limits of its own -- every figure it emits is
  ## a measurement and the assertion is the only judge -- so there is nothing
  ## to disable. Present so the module's shape holds and so a limit field
  ## added later cannot be forgotten here.
  discard spec

proc loadStepKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # Everything that changes the run joins the key. The step *magnitude* in
  # particular: two claims at two magnitudes are two different questions --
  # a rail that holds up under 1 A may not under 3 A -- and pooling them
  # would answer one with the other's number, which is exactly what the
  # swept range does for `spice.dc_sweep`.
  subjectNet(d, a) & "|" & $conditionFloat(a, "step_from", 0.0) &
    "|" & $conditionFloat(a, "step_to", 0.0) &
    "|" & $conditionFloat(a, "step_edge", 0.0) &
    "|" & $conditionFloat(a, "step_at", 0.0) &
    "|" & $conditionFloat(a, "step_hold", 0.0) &
    "|" & $conditionFloat(a, "step_recover", 0.0) &
    "|" & $conditionFloat(a, "step_points", 0.0) &
    "|" & $conditionFloat(a, "step_band", 0.0)

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
    setupKey: loadStepKey, setupDoc: loadStepDoc, run: runLoadStep))
