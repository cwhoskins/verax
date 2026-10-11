## `spice.dc_sweep` -- source and load sweeps, via `.dc`. One evaluator for
## both (one producer per quantity); the `sweep` condition, carried in the
## setup key, picks which runs.

import std/tables
import ./common
import ../analyses/dcsweep

const dcSweepQuantities = ["dc_out_min", "dc_out_max", "dc_out_delta",
                           "dc_transfer", "line_reg_pct",
                           "line_reg_pct_per_v", "dropout_v",
                           "load_reg_pct", "z_out_dc"]

proc sweepKind(a: Assertion): string =
  ## `"source"` or `"load"`, from the expanding role. Empty is refused, not
  ## defaulted: guessing would run some sweep and report it as the one asked.
  let s = conditionOf(a, "sweep")
  if s.isNone: "" else: s.get

proc dcSweepSpecOf(ctx: EvalContext, a: Assertion): DcSweepSpec =
  result = defaultDcSweepSpec()
  applyScopeConditions(a, result.scope)
  result.fromVal = conditionFloat(a, "sweep_from", 0.0)
  result.toVal = conditionFloat(a, "sweep_to", 0.0)
  result.step = conditionFloat(a, "sweep_step", 0.0)
  result.nominal = conditionFloat(a, "v_nominal", 0.0)
  result.inputNet = bindingName(ctx.design, a, "input")

proc dcSweepKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # Which sweep, of what, at which node, plus the whole spec (answers are
  # differences across the range).
  sweepKind(a) & "|" & bindingName(d, a, "source") & "|" & subjectNet(d, a) &
    "|" & specKey(dcSweepSpecOf(ctx, a))

proc dcSweepDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let a0 = batch[0]
  let node = subjectNet(d, a0)
  let spec = dcSweepSpecOf(ctx, a0)
  case sweepKind(a0)
  of "source":
    let src = bindingName(d, a0, "source")
    result = "`.dc` sweep of " & (if src.len > 0: src else: "an unbound source") &
             " from " & eng(spec.fromVal, "V") & " to " & eng(spec.toVal, "V") &
             ", measured at net '" & node &
             "'. Everything connected to it is simulated (`source_closed`: nothing terminated), so the " &
             "node has to follow the sweep rather than be held at its " &
             "nominal by a boundary source"
    if spec.inputNet.len > 0:
      result &= ". Any dropout is the differential to net '" & spec.inputNet &
                "', not to the source"
  of "load":
    result = "`.dc` sweep of a constant-current sink the analysis injects at " &
             "net '" & node & "', from " & eng(spec.fromVal, "A") & " to " &
             eng(spec.toVal, "A") & ". Nothing is added to the design: a test " &
             "load is not a part anybody solders, and a resistor would sweep " &
             "the drive along with the load"
  else:
    result = "nothing ran: the claim says nothing about what to sweep"

proc runDcSweep(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.dc_sweep"
  let a0 = batch[0]
  let node = subjectNet(d, a0)
  if node.len == 0:
    return failBatch(batch, name, "no net subject to measure")

  let kind = sweepKind(a0)
  if kind.len == 0:
    for a in batch:
      result.add notEvaluable(a, name,
        "a dc sweep has to know what is being swept and over what range, " &
        "and this claim says neither -- its subjects name only the node. " &
        "State it through the `source_sweep` role (which binds the source " &
        "to sweep) or the `load_sweep` role (which injects its own sink)")
    return

  let spec = dcSweepSpecOf(ctx, a0)
  if not (spec.toVal > spec.fromVal):
    for a in batch:
      result.add notEvaluable(a, name,
        "the sweep runs from " & eng(spec.fromVal) & " to " &
        eng(spec.toVal) & ", which is not a range. Every quantity a sweep " &
        "produces is a difference across it, so the answer is a function of " &
        "the range and there is no default one to assume")
    return

  var rep: AnalysisReport
  try:
    case kind
    of "source":
      let src = bindingName(d, a0, "source")
      if src.len == 0:
        for a in batch:
          result.add notEvaluable(a, name,
            "a source sweep needs to know which source to sweep, and the " &
            "assertion carries only its subjects; bind a `source` part on " &
            "the role that expands this claim")
        return
      rep = analyzeLineSweep(d.netlist, src, node, spec)
    else:
      rep = analyzeLoadSweep(d.netlist, node, spec)
  except CatchableError as e:
    return failBatch(batch, name,
      "the dc sweep on '" & node & "' failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc registerDcSweepEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.dc_sweep", produces: @dcSweepQuantities,
    needs: {capSpiceDc}, arity: 1 .. 1, subjectKinds: {skNet},
    binds: @["source"],
    conditions: @["sweep", "sweep_from", "sweep_to", "sweep_step", "v_nominal",
                  "ic_sinks"],
    units: {"dc_out_min": "V", "dc_out_max": "V", "dc_out_delta": "V",
            "dc_transfer": "", "line_reg_pct": "%", "line_reg_pct_per_v": "%/V",
            "dropout_v": "V", "load_reg_pct": "%", "z_out_dc": "ohm"}.toTable,
    setupKey: dcSweepKey, setupDoc: dcSweepDoc, run: runDcSweep))
