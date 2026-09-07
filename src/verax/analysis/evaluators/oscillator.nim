## `spice.oscillator` -- what a node is running at, via `.tran`.

import std/tables
import ./common
import ../analyses/transient

const oscQuantities = ["osc_freq", "swing_pp", "osc_thd_pct"]
  ## `swing_pp` rather than reusing `output_swing`, which `spice.large_signal`
  ## already produces: `registerEvaluator` refuses a second producer of a
  ## quantity outright, and the two are not the same measurement anyway --
  ## one is the response to a stated drive, the other is what the circuit
  ## does with no drive at all.

proc measurementOnly(spec: var TransientSpec) =
  spec.settleTol = 0.0

proc oscKick(ctx: EvalContext, a: Assertion): tuple[net: string, v: float] =
  ## The node given a starting voltage, and how much. Empty when the role
  ## bound no `kick` part, which is right for a circuit that starts by
  ## itself -- and is why the evaluator declares no `binds`.
  (bindingName(ctx.design, a, "kick"), conditionFloat(a, "kick_v", 0.1))

proc oscKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # The kick joins the key alongside the window: where a circuit is started
  # from and how hard is part of the setup, not part of the claim, and two
  # claims started differently are two runs.
  let k = oscKick(ctx, a)
  subjectNet(d, a) & "|" & $conditionFloat(a, "t_settle", 0.0) &
                     "|" & $conditionFloat(a, "t_window", 0.0) &
                     "|" & k.net & "|" & $k.v

proc oscDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let outNet = subjectNet(d, batch[0])
  let (tSettle, tWindow) = transientWindow(batch[0])
  let k = oscKick(ctx, batch[0])
  result = "`.tran` over the whole design as authored -- not isolated, and " &
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

  var spec = defaultTransientSpec()
  measurementOnly(spec)
  let (tSettle, tWindow) = transientWindow(batch[0])
  spec.tSettle = tSettle
  spec.tWindow = tWindow
  let k = oscKick(ctx, batch[0])
  if k.net.len > 0:
    spec.initialConditions[k.net] = k.v

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
    setupKey: oscKey, setupDoc: oscDoc, run: runOscillation))
