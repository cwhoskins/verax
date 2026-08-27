## `spice.startup` -- rail ramp-up and inrush, via `.tran`.

import ./common
import ../../netlist/graph
import ../../spice/transform
import ../analyses/startup

const startupQuantities = ["final_v", "overshoot_pct", "rise_time_10_90",
                           "settle_time", "inrush_peak", "t_inrush_peak"]

proc measurementOnly(spec: var StartupSpec) =
  spec.overshootLimit = Inf  ## a `>` test
  spec.currentLimit = 0.0    ## explicitly gated on `> 0`

proc startupKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # `t_run` joins the key for the reason every setup condition does: it is
  # what was run, so two claims over two run lengths are two runs.
  bindingName(d, a, "regulator") & "|" & subjectNet(d, a) & "|" &
    $conditionFloat(a, "t_run", 0.0)

proc startupDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let a0 = batch[0]
  let regulator = bindingName(d, a0, "regulator")
  let measured = subjectNet(d, a0)
  let outputNet = bindingName(d, a0, "output")
  let driven = if outputNet.len > 0: outputNet else: measured
  if regulator.len == 0:
    return "a `.tran` from power-on -- but no `regulator` part is bound, so " &
           "nothing says what drives the rail"
  # Which of the two things happened is not a detail a reader can be left to
  # infer. An assumed ramp measures the *output network's* response to a ramp
  # this tool invented; the part's own model measures the part. The rise time
  # means something completely different in the two cases, and it is reported
  # under the same name.
  let c = findComponent(d.netlist, regulator)
  let sr = if c == nil: nil else: selectSimModel(c, spStartup)
  if sr == nil:
    result = "`.tran` from power-on with " & regulator &
             " stood up as an ideal source following an assumed soft-start " &
             "ramp into net '" & driven & "'"
  else:
    result = "`.tran` from power-on with " & regulator &
             " simulated through its own model" &
             (if sr.name.len > 0: " '" & sr.name & "'" else: "") &
             ", started from zero with uic so that model's own soft start " &
             "is what runs, driving net '" & driven & "'"
  if measured.len > 0 and measured != driven:
    result &= ", measured at net '" & measured &
              "' on the far side of the filter"
  let tRun = conditionFloat(batch[0], "t_run", 0.0)
  if tRun > 0.0:
    result &= ", run for " & eng(tRun, "s")
  if sr == nil:
    result &= ". No control loop, current limit or dropout is modelled"

proc runStartup(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.startup"
  let a0 = batch[0]
  let regulator = bindingName(d, a0, "regulator")
  if regulator.len == 0:
    # The single most likely reason to land here, so say what to do about it.
    for a in batch:
      result.add notEvaluable(a, name,
        "a start-up measurement needs to know which component drives the " &
        "rail, and the assertion carries only its subjects; bind a " &
        "`regulator` part on the role that expands this claim")
    return

  let outputNet = bindingName(d, a0, "output")
  let measured = subjectNet(d, a0)
  let driven = if outputNet.len > 0: outputNet else: measured
  if driven.len == 0:
    return failBatch(batch, name, "no output net to measure")

  var spec = defaultStartupSpec()
  measurementOnly(spec)
  spec.tStop = conditionFloat(a0, "t_run", 0.0)

  var rep: AnalysisReport
  try:
    rep = analyzeStartup(d.netlist, regulator, driven, measured, spec)
  except CatchableError as e:
    return failBatch(batch, name, "the start-up run failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc registerStartupEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.startup", produces: @startupQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    binds: @["regulator", "output"],
    setupKey: startupKey, setupDoc: startupDoc, run: runStartup))
