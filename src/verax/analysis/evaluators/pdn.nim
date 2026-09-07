## `spice.pdn` -- the decoupling-impedance bundle, via `.ac`.

import ./common
import ../analyses/pdn

const pdnQuantities = ["z_min", "f_z_min", "z_max_in_band", "f_z_max_in_band",
                       "z_antiresonance", "f_antiresonance", "cap_count"]

proc measurementOnly(spec: var PdnSpec) =
  spec.targetZ = Inf  ## `pdn.nim` tests `z > targetZ`; zero would flag everything.

proc pdnKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  subjectNet(d, a) & "|" & $conditionFloat(a, "f_from", 0.0) &
                     "|" & $conditionFloat(a, "f_to", 0.0)

proc pdnDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let rail = subjectNet(d, batch[0])
  let spec = defaultPdnSpec()
  let fFrom = conditionFloat(batch[0], "f_from", spec.targetFrom)
  let fTo = conditionFloat(batch[0], "f_to", spec.targetTo)
  "`.ac` sweep of net '" & rail & "' with 1 A injected, so the node voltage " &
  "*is* the impedance. Everything on the rail is isolated and the supply " &
  "cut away -- an ideal source is a dead short at AC and would read 0 ohm " &
  "everywhere. Judged over " & eng(fFrom, "Hz") & " .. " & eng(fTo, "Hz")

proc runPdn(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.pdn"
  let rail = subjectNet(d, batch[0])
  if rail.len == 0:
    return failBatch(batch, name, "no net subject to sweep")

  var spec = defaultPdnSpec()
  measurementOnly(spec)
  # The sweep runs against capacitances derated from the shared operating
  # point rather than from whatever the nets happened to be annotated with.
  spec.bias = nodeVoltages(sharedOperatingPoint(ctx))
  let fFrom = conditionFloat(batch[0], "f_from", 0.0)
  let fTo = conditionFloat(batch[0], "f_to", 0.0)
  if fFrom > 0.0: spec.targetFrom = fFrom
  if fTo > 0.0: spec.targetTo = fTo

  var rep: AnalysisReport
  try:
    rep = analyzePdn(d.netlist, rail, groundNetOf(d), spec)
  except CatchableError as e:
    return failBatch(batch, name, "the PDN sweep of '" & rail & "' failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc registerPdnEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.pdn", produces: @pdnQuantities,
    needs: {capSpiceOp, capSpiceAc}, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: pdnKey, setupDoc: pdnDoc, run: runPdn))
