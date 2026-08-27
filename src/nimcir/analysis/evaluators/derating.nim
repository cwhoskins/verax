## `spice.derating` -- part voltage/power ratings, via the shared `.op`.

import std/tables
import ./common
import ../analyses/derating

const deratingQuantities = ["worst_voltage_derating", "worst_power_derating",
                            "parts_over_derating"]

proc deratingKey(ctx: EvalContext, a: Assertion): string = subjectNet(ctx.design, a)
  ## Keyed by rail, so each claimed rail is one `.op`. Unlike `dc_voltage`,
  ## which answers every net from a single run, this reduces to a *worst*
  ## over a filtered set of parts -- so one run cannot serve two subjects
  ## without returning two answers.

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

  var spec = defaultDeratingSpec()
  spec.onlyTouching = rail
  spec.precomputed = nodeVoltages(sharedOperatingPoint(ctx))
  # The ceiling belongs to the assertion, not to the analysis. Left in place
  # it would report the same claim twice, possibly at two thresholds -- the
  # same reason every other adapter here runs measurement-only.
  spec.defaultCeiling = Inf
  for k in spec.ceilingByFamily.keys:
    spec.ceilingByFamily[k] = Inf

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
    setupKey: deratingKey, setupDoc: deratingDoc, run: runDerating))
