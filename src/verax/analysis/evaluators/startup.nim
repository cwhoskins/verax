## `spice.startup` -- rail ramp-up and inrush, via `.tran`.

import std/tables
import ./common
import ../../netlist/graph
import ../../spice/transform
import ../analyses/startup

const startupQuantities = ["final_v", "overshoot_pct", "rise_time_10_90",
                           "settle_time", "inrush_peak", "t_inrush_peak"]

proc measurementOnly(spec: var StartupSpec) =
  spec.overshootLimit = Inf  ## a `>` test
  spec.currentLimit = 0.0    ## explicitly gated on `> 0`

proc startupSpecOf(a: Assertion): StartupSpec =
  result = defaultStartupSpec()
  measurementOnly(result)
  result.tStop = conditionFloat(a, "t_run", 0.0)

proc startupKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  bindingName(d, a, "regulator") & "|" & bindingName(d, a, "output") & "|" &
    subjectNet(d, a) & "|" & specKey(startupSpecOf(a))

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
  # Say which happened: with an assumed ramp the rise time describes the
  # output network; with the part's own model it describes the part.
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
  let tRun = startupSpecOf(batch[0]).tStop
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
    # The likeliest reason to land here; say how to fix it.
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

  let spec = startupSpecOf(a0)

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
    conditions: @["t_run"],
    units: {"final_v": "V", "overshoot_pct": "%", "rise_time_10_90": "s",
            "settle_time": "s", "inrush_peak": "A", "t_inrush_peak": "s"}.toTable,
    setupKey: startupKey, setupDoc: startupDoc, run: runStartup))
