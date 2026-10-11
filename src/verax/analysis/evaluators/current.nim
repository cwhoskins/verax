## `spice.current_path` -- device branch currents, via `.tran`.

import std/[math, strutils, tables]
import ./common
import ../../netlist/graph
import ../analyses/transient

const currentQuantities = ["i_peak", "i_rms", "i_avg", "i_pp",
                           "i_min", "i_max",
                           "i_peak_derating", "i_rms_derating",
                           "i_out_derating"]
  ## `i_out_derating` lives here because it reads the **same run**: the
  ## sense part's current (a buck's inductor, a linear's pass element)
  ## against the *regulator's* rating, which only the adapter (with the role
  ## binding) can compute. A separate evaluator would double the `.tran`.
  ##
  ## The cost: `binds` is per evaluator, so declaring `@["regulator"]` would
  ## wrongly mark `i_peak` etc. role-only. Left empty, `verax quantities`
  ## overstates `i_out_derating`'s reach; a bare `require` gets a message
  ## naming the missing binding.

proc currentSpecOf(a: Assertion): TransientSpec =
  result = defaultTransientSpec()
  applyScopeConditions(a, result.scope)
  result.settleTol = 0.0
  let (tSettle, tWindow) = transientWindow(a)
  result.tSettle = tSettle
  result.tWindow = tWindow

proc currentKey(ctx: EvalContext, a: Assertion): string =
  ## **Not keyed by part**: one `.tran` answers every part, so the setup is
  ## the spec alone (keying by part would re-simulate per part).
  specKey(currentSpecOf(a))

proc currentParts(ctx: EvalContext, batch: seq[Assertion]): seq[string] =
  for a in batch:
    let p = subjectComponent(ctx.design, a)
    if p.len > 0 and p notin result: result.add p

proc currentDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let parts = currentParts(ctx, batch)
  let (tSettle, tWindow) = transientWindow(batch[0])
  result = "`.tran` over everything connected to the measurement (the `source_closed` scope: nothing terminated), so " &
           "each part carries what the circuit actually pushes through it. " &
           "Reading the branch current of " &
           (if parts.len > 0: parts.join(", ") else: "no resolvable part")
  if tSettle > 0.0:
    result &= " over " & eng(tWindow, "s") & " from " & eng(tSettle, "s") &
              ", with everything before that simulated and discarded"
  else:
    result &= " over the whole run"
  result &= ". Peak, RMS and average are magnitudes: the sign of a branch " &
            "current is a deck convention, not a fact about the circuit"

proc harvestPart(a: Assertion, rep: AnalysisReport, part, evaluator: string):
    AssertionResult =
  ## `harvest` restricted to one part's measurements (`Measurement.at`
  ## carries the designator), so one batched run answers each claim with the
  ## right part's number.
  for m in rep.measurements:
    if m.name == a.quantity and m.at == part:
      return verdict(a, m.value, m.unit, evaluator, rep.assumptions,
                     rep.issues)
  var produced: seq[string]
  for m in rep.measurements:
    if m.at == part and m.name notin produced: produced.add m.name
  result = notEvaluable(a, evaluator,
    (if produced.len == 0:
       "the run measured nothing through '" & part & "'"
     else:
       "the analysis produced no '" & a.quantity & "' for '" & part &
       "'; it measured " & produced.join(", ")))
  result.assumptions = rep.assumptions
  result.issues = rep.issues

proc harvestOutputDerating(d: Design, a: Assertion, rep: AnalysisReport,
                           part, evaluator: string): AssertionResult =
  ## The sense part's RMS current as a fraction of the **regulator's**
  ## continuous rating. Current is read where it flows (a code-model
  ## regulator has no terminal current); the rating is the regulator's (a
  ## converter's limit isn't the inductor's). `NaN` when the regulator states
  ## no `current_rating`.
  var rms = NaN
  for m in rep.measurements:
    if m.name == "i_rms" and m.at == part:
      rms = m.value
      break
  if rms.isNaN:
    result = notEvaluable(a, evaluator,
      "no RMS current was measured through '" & part & "', so there is " &
      "nothing to compare against a rating")
    result.assumptions = rep.assumptions
    result.issues = rep.issues
    return

  let regName = bindingName(d, a, "regulator")
  let reg = if regName.len == 0: nil else: findComponent(d.netlist, regName)
  if reg == nil:
    result = notEvaluable(a, evaluator,
      "this claim states a fraction of the regulator's own current rating, " &
      "and no `regulator` part is bound on the role that expanded it -- so " &
      "there is no part to read a rating off")
    result.assumptions = rep.assumptions
    result.issues = rep.issues
    return

  let rating = currentRating(reg)
  let frac = if rating.has and float(rating.value) > 0.0: rms / float(rating.value)
             else: NaN
  result = verdict(a, frac, "", evaluator, rep.assumptions, rep.issues)
  if frac.isNaN:
    result.reason = "'" & regName & "' states no `current_rating`, so how " &
      "much of it the " & eng(rms, "A") & " through '" & part & "' uses up " &
      "is not a question this design has answered yet"
  else:
    result.reason &= " of " & regName & "'s stated " &
      eng(float(rating.value), "A") & ", measured through " & part

proc runCurrent(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.current_path"
  let parts = currentParts(ctx, batch)
  if parts.len == 0:
    for a in batch:
      result.add notEvaluable(a, name,
        "a current is carried by a part, not by a net: this claim's subject " &
        "has to be a component that exists in this design. State it through " &
        "the `current_path` role, or write `require i_peak(L1) <= ...`")
    return

  let spec = currentSpecOf(batch[0])

  var rep: AnalysisReport
  try:
    rep = analyzeCurrent(d.netlist, parts, spec)
  except CatchableError as e:
    return failBatch(batch, name,
      "the transient run measuring " & parts.join(", ") & " failed: " & e.msg)

  for a in batch:
    let part = subjectComponent(d, a)
    if part.len == 0:
      result.add notEvaluable(a, name,
        "this claim names no component that exists in this design, so there " &
        "is nothing to measure a current through")
      continue
    if a.quantity == "i_out_derating":
      result.add harvestOutputDerating(d, a, rep, part, name)
      continue
    result.add harvestPart(a, rep, part, name)

proc registerCurrentEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.current_path", produces: @currentQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skComponent},
    conditions: @["t_settle", "t_window", "ic_sinks"],
    units: {"i_peak": "A", "i_rms": "A", "i_avg": "A", "i_pp": "A",
            "i_min": "A", "i_max": "A", "i_peak_derating": "",
            "i_rms_derating": "", "i_out_derating": ""}.toTable,
    setupKey: currentKey, setupDoc: currentDoc, run: runCurrent))
