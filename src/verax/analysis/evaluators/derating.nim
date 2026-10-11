## `spice.derating` -- part voltage/power ratings, via the shared `.op`.

import std/tables
import ./common
import ../analyses/derating

const deratingQuantities = ["worst_voltage_derating", "worst_power_derating",
                            "parts_over_derating"]

proc deratingSpecOf(ctx: EvalContext, a: Assertion): DeratingSpec =
  ## Everything but the operating point, which the run solves (once, shared).
  result = defaultDeratingSpec()
  result.onlyTouching = subjectNet(ctx.design, a)
  # The assertion owns the ceiling (measurement-only, as everywhere).
  result.defaultCeiling = Inf
  for k in result.ceilingByFamily.keys:
    result.ceilingByFamily[k] = Inf

proc deratingKey(ctx: EvalContext, a: Assertion): string =
  ## Keyed by rail (inside the spec): each claim is a worst case over a
  ## filtered set of parts, so one run can't serve two subjects (unlike
  ## `dc_voltage`).
  specKey(deratingSpecOf(ctx, a))

proc deratingDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  "the shared `.op`, read back as the DC actually across every part " &
  "touching net '" & subjectNet(d, batch[0]) &
  "', compared with the rating each part states"

proc runDerating(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.derating"
  let rail = subjectNet(d, batch[0])
  if rail.len == 0:
    return failBatch(batch, name, "no net subject whose parts could be checked")

  var spec = deratingSpecOf(ctx, batch[0])
  spec.precomputed = nodeVoltages(sharedOperatingPoint(ctx))

  var rep: AnalysisReport
  try:
    rep = analyzeDerating(d.netlist, spec)
  except CatchableError as e:
    return failBatch(batch, name,
      "the operating point needed to check ratings on '" & rail &
      "' failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc registerDeratingEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.derating", produces: @deratingQuantities,
    needs: {capSpiceOp}, arity: 1 .. 1, subjectKinds: {skNet},
    units: {"worst_voltage_derating": "", "worst_power_derating": "",
            "parts_over_derating": ""}.toTable,
    setupKey: deratingKey, setupDoc: deratingDoc, run: runDerating))
