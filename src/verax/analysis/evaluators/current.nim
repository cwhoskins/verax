## `spice.current_path` -- device branch currents, via `.tran`.

import std/[math, strutils]
import ./common
import ../../netlist/graph
import ../analyses/transient

const currentQuantities = ["i_peak", "i_rms", "i_avg", "i_pp",
                           "i_min", "i_max",
                           "i_peak_derating", "i_rms_derating",
                           "i_out_derating"]
  ## `i_out_derating` is the odd one out and is here rather than in an
  ## evaluator of its own for one reason: it is read off the **same run**.
  ##
  ## The other two derating figures divide a part's measured current by a
  ## rating that part states. This one divides it by a rating a *different*
  ## part states -- the regulator's, against the current measured through
  ## whatever carries its output (a buck's inductor, a linear's pass
  ## element). `analyzeCurrent` cannot compute it, because it is handed
  ## designators and knows nothing about roles; the adapter below can,
  ## because it has both the subject and the role binding. Registering a
  ## second evaluator for it would double the `.tran` -- and on
  ## `designs/lt8640a_buck.nim` that run is the switching model at fifty
  ## timepoints a cycle, which is most of the check.
  ##
  ## The price is one line of honesty in `verax quantities`. `binds` is a
  ## property of an *evaluator*, not of a quantity, so declaring
  ## `binds: @["regulator"]` here would mark `i_peak` and the rest as
  ## reachable only through a role -- which is false and is exactly the
  ## conflation that column exists to prevent. Left empty, the table reports
  ## `i_out_derating` as "`require` / role: regulator" where only the second
  ## half is true. The runtime message covers the difference: a bare
  ## `require i_out_derating(L1)` comes back naming the missing binding
  ## rather than failing obscurely.

proc currentKey(ctx: EvalContext, a: Assertion): string =
  ## **Deliberately not keyed by the part.** One `.tran` answers every part in
  ## the design at once -- the currents are all readings of the same set of
  ## waveforms -- so the setup is the window and nothing else. Keying by part
  ## would simulate a switching model once per claimed part to read one run
  ## several ways, which on `lt8640a_buck` is fifty timepoints a cycle paid
  ## twice for an inductor and its input capacitor.
  $conditionFloat(a, "t_settle", 0.0) & "|" &
  $conditionFloat(a, "t_window", 0.0)

proc currentParts(ctx: EvalContext, batch: seq[Assertion]): seq[string] =
  for a in batch:
    let p = subjectComponent(ctx.design, a)
    if p.len > 0 and p notin result: result.add p

proc currentDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let parts = currentParts(ctx, batch)
  let (tSettle, tWindow) = transientWindow(batch[0])
  result = "`.tran` over the whole design as authored -- not isolated, so " &
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
  ## `harvest`, restricted to the measurements belonging to one part.
  ##
  ## One run produces `i_peak` for every claimed part, so a lookup by quantity
  ## alone would answer a claim about the input capacitor with the inductor's
  ## number. `Measurement.at` carries the designator, and matching on it is
  ## what keeps the batching honest.
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
  ## The sense part's RMS current as a fraction of the **regulator's** own
  ## continuous rating.
  ##
  ## Both halves are deliberate. The current is read where it actually flows:
  ## a regulator that reaches the deck as a code model or a subcircuit has no
  ## terminal current of its own, so a converter's output current is its
  ## inductor's and a linear's is its pass element's, and the role says which
  ## by binding `sense`. The rating is read off the regulator, because that
  ## is the part it describes -- a 5 A converter's limit is not a property of
  ## the inductor somebody chose to put after it, and writing it on the
  ## inductor would put the wrong number in the BoM.
  ##
  ## `NaN` when the regulator states no `current_rating`, on the rule
  ## `current_path` already follows: a part nobody has chosen yet reads as
  ## *not evaluated*, never as infinite headroom.
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

  let rating = annotationFloat(reg, "current_rating")
  let frac = if rating.has and rating.value > 0.0: rms / rating.value else: NaN
  result = verdict(a, frac, "", evaluator, rep.assumptions, rep.issues)
  if frac.isNaN:
    result.reason = "'" & regName & "' states no `current_rating`, so how " &
      "much of it the " & eng(rms, "A") & " through '" & part & "' uses up " &
      "is not a question this design has answered yet"
  else:
    result.reason &= " of " & regName & "'s stated " &
      eng(rating.value, "A") & ", measured through " & part

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

  var spec = defaultTransientSpec()
  spec.settleTol = 0.0
  let (tSettle, tWindow) = transientWindow(batch[0])
  spec.tSettle = tSettle
  spec.tWindow = tWindow

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
    setupKey: currentKey, setupDoc: currentDoc, run: runCurrent))
