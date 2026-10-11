## `spice.pdn` -- the decoupling-impedance bundle, via `.ac`.

import std/tables
import ./common
import ../analyses/pdn

const pdnQuantities = ["z_min", "f_z_min", "z_max_in_band", "f_z_max_in_band",
                       "z_antiresonance", "f_antiresonance", "cap_count"]

proc measurementOnly(spec: var PdnSpec) =
  spec.targetZ = Inf  ## `pdn.nim` tests `z > targetZ`; zero would flag everything.

proc pdnSpecOf(a: Assertion): PdnSpec =
  ## Everything but the bias, which the run reads off the shared `.op`.
  result = defaultPdnSpec()
  measurementOnly(result)
  let fFrom = conditionFloat(a, "f_from", 0.0)
  let fTo = conditionFloat(a, "f_to", 0.0)
  if fFrom > 0.0: result.targetFrom = fFrom
  if fTo > 0.0: result.targetTo = fTo

proc pdnKey(ctx: EvalContext, a: Assertion): string =
  subjectNet(ctx.design, a) & "|" & specKey(pdnSpecOf(a))

proc pdnDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let rail = subjectNet(d, batch[0])
  let spec = pdnSpecOf(batch[0])
  let (fFrom, fTo) = (spec.targetFrom, spec.targetTo)
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

  var spec = pdnSpecOf(batch[0])
  # Derate capacitances from the shared operating point, not net
  # annotations.
  spec.bias = nodeVoltages(sharedOperatingPoint(ctx))

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
    conditions: @["f_from", "f_to"],
    units: {"z_min": "ohm", "f_z_min": "Hz", "z_max_in_band": "ohm",
            "f_z_max_in_band": "Hz", "z_antiresonance": "ohm",
            "f_antiresonance": "Hz", "cap_count": ""}.toTable,
    setupKey: pdnKey, setupDoc: pdnDoc, run: runPdn))
