## `spice.oscillator` -- what a node is running at, via `.tran`.

import std/tables
import ./common
import ../analyses/transient

const oscQuantities = ["osc_freq", "swing_pp", "osc_thd_pct"]
  ## `swing_pp`, not `output_swing` (`spice.large_signal`'s): one producer
  ## per quantity, and an undriven oscillation isn't a driven response.

proc measurementOnly(spec: var TransientSpec) =
  spec.settleTol = 0.0

proc oscKick(ctx: EvalContext, a: Assertion): tuple[net: string, v: float] =
  ## The kicked node and voltage; empty when no `kick` is bound (a
  ## self-starting circuit), hence no `binds`.
  (bindingName(ctx.design, a, "kick"), conditionFloat(a, "kick_v", 0.1))

proc oscSpecOf(ctx: EvalContext, a: Assertion): TransientSpec =
  ## The window, and the kick as an initial condition (so it is in the key).
  result = defaultTransientSpec()
  applyScopeConditions(a, result.scope)
  measurementOnly(result)
  let (tSettle, tWindow) = transientWindow(a)
  result.tSettle = tSettle
  result.tWindow = tWindow
  let k = oscKick(ctx, a)
  if k.net.len > 0:
    result.initialConditions[k.net] = k.v

proc oscKey(ctx: EvalContext, a: Assertion): string =
  subjectNet(ctx.design, a) & "|" & specKey(oscSpecOf(ctx, a))

proc oscDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let outNet = subjectNet(d, batch[0])
  let (tSettle, tWindow) = transientWindow(batch[0])
  let k = oscKick(ctx, batch[0])
  result = "`.tran` over everything connected to the measurement (the `source_closed` scope: nothing terminated), and " &
           "not swept, because an oscillator has no transfer function to " &
           "sweep and driving its input would hold the node the loop " &
           "returns to. Reading net '" & outNet & "'"
  if tSettle > 0.0:
    result &= " over " & eng(tWindow, "s") & " from " & eng(tSettle, "s") &
              ", with everything before that simulated and discarded"
  else:
    result &= " over the whole run"
  if k.net.len > 0:
    result &= ", started by putting " & eng(k.v, "V") & " on net '" & k.net &
              "' as an initial condition with uic"
  else:
    result &= ", started from its own operating point -- which for anything " &
              "that sits at a balance means it does not start at all; bind a " &
              "`kick` net on the role if it reports a flat line"

proc runOscillation(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.oscillator"
  let outNet = subjectNet(d, batch[0])
  if outNet.len == 0:
    return failBatch(batch, name, "no net subject to measure")

  let spec = oscSpecOf(ctx, batch[0])

  var rep: AnalysisReport
  try:
    rep = analyzeOscillation(d.netlist, outNet, spec)
  except CatchableError as e:
    return failBatch(batch, name,
      "the oscillation run on '" & outNet & "' failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc registerOscillatorEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.oscillator", produces: @oscQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    conditions: @["t_settle", "t_window", "kick_v", "ic_sinks"],
    units: {"osc_freq": "Hz", "swing_pp": "V", "osc_thd_pct": "%"}.toTable,
    setupKey: oscKey, setupDoc: oscDoc, run: runOscillation))
