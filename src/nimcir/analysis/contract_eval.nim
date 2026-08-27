## Simulation-backed evaluators for `nimcir/contract`.
##
## `contract/evaluate` depends only on `nimcir/netlist`, which is what keeps a
## design and its contract inspectable with no simulator in the build. The
## evaluators that *do* need one therefore cannot live there, and live here
## instead: `analysis` already depends on `spice`, and an `Evaluator` is a
## value with a `proc` field, so registering one from another module is the
## ordinary path rather than a workaround.
##
## **Opt-in per-import.** `nimcir/analysis.nim` does not export this, exactly
## as it does not export `pdn`/`startup`/`opamp`, and `nimcir/contract.nim`
## cannot. Import it explicitly, and pass `allCapabilities` to `evaluate`:
##
## ```nim
## import nimcir/contract
## import nimcir/analysis/contract_eval  # registers the simulated evaluators
##
## let results = evaluate(design, allCapabilities)
## ```
##
## **Every analysis runs in measurement-only mode.** Each `*Spec` carries
## limit fields (`targetZ`, `minBandwidth`, `overshootLimit`, ...) that state
## the same kind of claim an `Assertion` states. Left live, the same claim is
## reported twice -- once as an `Issue` from the analysis and once as an
## `AssertionResult` -- possibly against two different thresholds. The
## assertion is the authority, so the adapters below disable those checks and
## keep only the measurements. The disabling values are **not consistent**
## across the three modules and are verified rather than assumed: `targetZ`
## and `overshootLimit` and `maxPeaking` are `>` comparisons needing `Inf`
## (`targetZ = 0` would flag *every* rail), `minPhaseMargin` is a `<`
## comparison needing `-Inf`, while `currentLimit` and `minBandwidth` are
## explicitly gated on `> 0` and so are disabled by zero.
##
## Issues that are *not* limit checks -- `pdn_no_decoupling`,
## `opamp_no_feedback`, `*_simulation_failed` -- still ride along on
## `AssertionResult.issues` as context, since they are diagnosis rather than a
## duplicate verdict.

import std/[math, strutils, tables]
import ../netlist/types
import ../netlist/graph
import ../netlist/kinds
import ../contract/evaluate
import ../contract/evaluators/static
import ../spice/backend
import ../spice/transform
import ../spice/models
import ../spice/flatten
import ../spice/ngspice
import ./report
import ./pdn
import ./derating
import ./operating
import ./dcsweep
import ./startup
import ./transient
import ./psrr
import ./opamp
import ./match

export evaluate, static

# --- shared helpers -----------------------------------------------------

proc groundNetOf(d: Design): string =
  ## The ground net's name, for analyses that need it named explicitly.
  ## Empty when the design already calls it `"0"` or tags it `ntGround`, which
  ## is what those analyses treat as "work it out yourself".
  for name, n in d.netlist.nets:
    if isGround(n): return (if name == "0": "" else: name)
  ""

proc harvest(a: Assertion, rep: AnalysisReport,
             evaluator: string): AssertionResult =
  ## Compare one assertion against a report that has already been produced.
  ##
  ## The measurement's own unit is passed through so `verdict` can catch a
  ## claim stated in the wrong one, and the report's assumptions ride along on
  ## every result drawn from it -- a verdict that rests on an assumed op-amp
  ## macromodel or a package-typical ESL has to carry that with it.
  for m in rep.measurements:
    if m.name == a.quantity:
      result = verdict(a, m.value, m.unit, evaluator, rep.assumptions,
                       rep.issues)
      # Where the number actually came from, when the subject would imply
      # somewhere else. Silence here reads as "measured on the subject",
      # which for `inrush_peak` is not true and cannot be made true: the
      # subject has to name the judged net for the isolation to be right.
      if m.at.len > 0 and a.subjects.len > 0 and
         m.at != ("net '" & a.subjects[0].name & "'") and
         result.reason.len > 0:
        result.reason &= " at " & m.at
      return result
  var produced: seq[string]
  for m in rep.measurements: produced.add m.name
  result = notEvaluable(a, evaluator,
    "the analysis produced no '" & a.quantity & "'; it measured " &
    produced.join(", "))
  result.assumptions = rep.assumptions
  result.issues = rep.issues

proc failBatch(batch: seq[Assertion], evaluator, reason: string,
               assumptions: seq[Assumption] = @[]): seq[AssertionResult] =
  ## Assumptions ride along even when nothing was measured. That is not
  ## bookkeeping: when a stand-in *declines* to model a part it explains what
  ## to state so it could, and dropping that leaves the reader holding a raw
  ## ngspice error instead of the one sentence that fixes it.
  for a in batch:
    var r = notEvaluated(a, evaluator, reason)
    r.assumptions = assumptions
    result.add r

proc subjectNet(d: Design, a: Assertion): string =
  ## The first net-shaped subject's name, or empty.
  ##
  ## Resolved through `findNet` rather than by a flat key lookup, so a subject
  ## naming a net *inside* a subcircuit instance -- `XA.XI.sns`, which is what
  ## `design.innerNet` builds and what `resolve` already accepts when the role
  ## or requirement is attached -- is found here too. A flat lookup made that
  ## subject representable, bindable and then uncheckable, reporting `needs a
  ## net subject that exists in this design` about a net that does.
  ##
  ## The name is returned exactly as written, because `spice/flatten` names
  ## the same net by the same path once the hierarchy is gone -- and the
  ## flattened netlist is the one the operating point was solved on.
  for s in a.subjects:
    if s.kind == skNet and findNet(d.netlist, s.name) != nil: return s.name
  ""

proc bindingName(d: Design, a: Assertion, part: string): string =
  ## A part bound by the role that expanded this assertion. This is how an
  ## adapter recovers topology the assertion does not carry -- see
  ## `evaluate.originRole`.
  let s = originBinding(d, a, part)
  if s.isNone: return ""
  s.get.name

# --- the shared operating point -----------------------------------------

const opScratchKey = "spice.operating_point"

type OpCacheEntry = ref object of RootObj
  ## `EvalContext.scratch` is type-erased on purpose -- `contract` may not
  ## name an `OperatingPoint`, which lives up here in `analysis`. So the
  ## owning module wraps its own type and downcasts on the way out.
  op: OperatingPoint

proc sharedOperatingPoint*(ctx: EvalContext): OperatingPoint =
  ## One `.op` per run, solved on first request and reused by everything
  ## after it.
  ##
  ## **Scoped to the `EvalContext`, which is what makes it correct rather
  ## than merely conventional.** This was a module-level `var` keyed on
  ## `Design` reference identity with no content invalidation, and it carried
  ## a documented rule instead of a guarantee: a caller that edited a design
  ## and evaluated again got a stale operating point with no diagnostic, two
  ## designs checked in one process shared one slot, and `verify.readiness`
  ## had to bracket every run with a cache-clearing call to stay safe. A
  ## context lives exactly as long as one run, and a design does not change
  ## under a run, so there is no window in which the entry can be wrong.
  ##
  ## Sharing it is worth having. `dc_voltage` solved one, `analysis/derating`
  ## solved another per claimed rail, and every one of them was the same
  ## design with the same answer -- a design claiming two rails plus derating
  ## on both did three identical solves. It also makes DC-bias derating see
  ## nodes that no annotation describes, which is the blind spot that mattered.
  if ctx.scratch.hasKey(opScratchKey):
    return OpCacheEntry(ctx.scratch[opScratchKey]).op
  result = solveOperatingPoint(root(ctx.design.netlist))
  ctx.scratch[opScratchKey] = OpCacheEntry(op: result)

# --- dc_voltage, via .op ------------------------------------------------

const dcVoltageQuantities = ["dc_voltage"]

proc opKey(ctx: EvalContext, a: Assertion): string = ""
  ## One `.op` answers every node voltage in the design at once, so every
  ## `dc_voltage` assertion shares a step no matter which net it names. This
  ## is the harvest model at its most visible: N assertions, one simulation.

proc opDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  var nets: seq[string]
  for a in batch:
    let n = subjectNet(d, a)
    if n.len > 0 and n notin nets: nets.add n
  result = "one `.op` solve of the whole design -- not isolated, so each " &
           "rail has to solve for itself rather than be told what it is"
  if nets.len > 0: result &= ". Reading net " & nets.join(", ")

proc runDcVoltage(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  ## **Deliberately does not use `spice/isolate`**, unlike every other
  ## analysis in this submodule.
  ##
  ## `isolate` terminates a cut rail with an ideal source at the rail's
  ## *nominal* voltage, taken from `Net.attrs["voltage"]` -- which is exactly
  ## the number a `dc_voltage` claim is asking us to verify. Isolating first
  ## would therefore measure the assumption back and pass every time. The
  ## whole design has to solve for the rail itself.
  ##
  ## The design must therefore be simulatable end to end. A part carrying no
  ## model is stood in for by `models.expandPinModels`, which gives each of
  ## its pins an impedance chosen from `Pin.kind` -- otherwise a board with an
  ## MCU on it dies in ngspice on `u1 vdd 0 sda scl` with an unknown-model
  ## error, which tells the reader nothing about their circuit. Those
  ## stand-ins are invented, so they ride out on every result's
  ## `assumptions`; a rail whose verdict depends on what an IC loads it with
  ## is resting on a guess and has to say so.
  let d = ctx.design
  const name = "spice.dc_voltage"

  # This used to solve its own `.op`. It now reads the shared one, which is
  # the same solve on the same netlist -- `solveOperatingPoint` materializes,
  # flattens and stands in for unmodelled parts exactly as this did, and for
  # the same stated reasons.
  let op = sharedOperatingPoint(ctx)
  let stood = op.assumptions
  if not op.solved:
    # Tried and could not, which is `esNotEvaluated` -- not a failed claim.
    # A design with no sources or no ground reference is not simulatable
    # as-authored, and that is a fact about the fragment, not about the rail.
    return failBatch(batch, name,
      "the .op run did not produce a result: " & op.reason, stood)

  for a in batch:
    let netName = subjectNet(d, a)
    if netName.len == 0:
      result.add notEvaluable(a, name,
        "dc_voltage needs a net subject that exists in this design")
      continue
    let v = voltageAt(op, netName)
    if v.classify == fcNan:
      result.add notEvaluable(a, name,
        "the operating point holds no voltage for net '" & netName & "'")
      continue
    result.add verdict(a, v, "V", name, stood)

# --- the PDN bundle, via .ac --------------------------------------------

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

# --- part ratings, via .op ----------------------------------------------

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

# --- source sweeps, via .dc ---------------------------------------------

const dcSweepQuantities = ["dc_out_min", "dc_out_max", "dc_out_delta",
                           "dc_transfer", "line_reg_pct",
                           "line_reg_pct_per_v", "dropout_v",
                           "load_reg_pct", "z_out_dc"]
  ## One evaluator for both sweeps, because `registerEvaluator` allows one
  ## producer per quantity and the three envelope figures genuinely come out
  ## of either. Which of the two ran is decided by the `sweep` condition, not
  ## by the quantity: a batch is grouped by setup key, and the key carries it.

proc sweepKind(a: Assertion): string =
  ## `"source"` or `"load"`, from the role that expanded the claim.
  ##
  ## Empty when nothing said, which is refused rather than defaulted. A sweep
  ## has to know what it is sweeping *and over what range*, and an assertion
  ## carries no channel for either except its conditions -- so guessing here
  ## would run some sweep and report the answer as though it were the one
  ## asked for.
  let s = conditionOf(a, "sweep")
  if s.isNone: "" else: s.get

proc dcSweepKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # Everything that changes the run joins the key: which source, which node,
  # and the range. Two claims over two ranges are two runs, and their answers
  # are not comparable -- every quantity here is a difference taken across
  # the range.
  sweepKind(a) & "|" & bindingName(d, a, "source") & "|" &
  bindingName(d, a, "input") & "|" & subjectNet(d, a) & "|" &
  $conditionFloat(a, "sweep_from", 0.0) & "|" &
  $conditionFloat(a, "sweep_to", 0.0) & "|" &
  $conditionFloat(a, "sweep_step", 0.0) & "|" &
  $conditionFloat(a, "v_nominal", 0.0)

proc dcSweepSpecOf(ctx: EvalContext, a: Assertion): DcSweepSpec =
  result = defaultDcSweepSpec()
  result.fromVal = conditionFloat(a, "sweep_from", 0.0)
  result.toVal = conditionFloat(a, "sweep_to", 0.0)
  result.step = conditionFloat(a, "sweep_step", 0.0)
  result.nominal = conditionFloat(a, "v_nominal", 0.0)
  result.inputNet = bindingName(ctx.design, a, "input")

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
             "'. The design is simulated as authored -- not isolated, so the " &
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

# --- the start-up bundle, via .tran -------------------------------------

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

# --- settling and ripple, via .tran -------------------------------------

const transientQuantities = ["settled_v", "ripple_pp",
                             "settled_min", "settled_max"]
  ## Deliberately **not** `final_v`, which `spice.startup` already produces.
  ## `analyzeTransient` measures one and the report shows it, but a second
  ## evaluator claiming the quantity would take over every `final_v` claim in
  ## every design; `registerEvaluator` refuses it outright, and that refusal
  ## is the reason this list is shorter than the analysis's own output.

proc measurementOnly(spec: var TransientSpec) =
  spec.settleTol = 0.0       ## explicitly gated on `> 0`

proc transientKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # The window joins the key for the same reason the drive level does on the
  # large-signal side: it is what was run, not what is claimed, so two claims
  # over two windows are two runs rather than one run reported twice.
  subjectNet(d, a) & "|" & $conditionFloat(a, "t_settle", 0.0) &
                     "|" & $conditionFloat(a, "t_window", 0.0)

proc transientWindow(a: Assertion): tuple[tSettle, tWindow: float] =
  let tSettle = conditionFloat(a, "t_settle", 0.0)
  var tWindow = conditionFloat(a, "t_window", 0.0)
  if tWindow <= 0.0 and tSettle > 0.0: tWindow = tSettle * 0.2
  (tSettle, tWindow)

proc transientDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let rail = subjectNet(d, batch[0])
  let (tSettle, tWindow) = transientWindow(batch[0])
  result = "`.tran` over the whole design as authored -- not isolated, so " &
           "the node has to arrive where it arrives rather than be held " &
           "there by a boundary source. Reading net '" & rail & "'"
  if tSettle > 0.0:
    result &= " over " & eng(tWindow, "s") & " from " & eng(tSettle, "s") &
              ", with everything before that simulated and discarded"
  else:
    result &= " over the whole run"

proc runTransient(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.transient"
  let rail = subjectNet(d, batch[0])
  if rail.len == 0:
    return failBatch(batch, name, "no net subject to measure")

  var spec = defaultTransientSpec()
  measurementOnly(spec)
  let (tSettle, tWindow) = transientWindow(batch[0])
  spec.tSettle = tSettle
  spec.tWindow = tWindow

  var rep: AnalysisReport
  try:
    rep = analyzeTransient(d.netlist, rail, spec)
  except CatchableError as e:
    return failBatch(batch, name,
      "the transient run on '" & rail & "' failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

# --- device currents, via .tran -----------------------------------------

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
  ## The price is one line of honesty in `nimcir quantities`. `binds` is a
  ## property of an *evaluator*, not of a quantity, so declaring
  ## `binds: @["regulator"]` here would mark `i_peak` and the rest as
  ## reachable only through a role -- which is false and is exactly the
  ## conflation that column exists to prevent. Left empty, the table reports
  ## `i_out_derating` as "`require` / role: regulator" where only the second
  ## half is true. The runtime message covers the difference: a bare
  ## `require i_out_derating(L1)` comes back naming the missing binding
  ## rather than failing obscurely.

proc subjectComponent(d: Design, a: Assertion): string =
  ## The first component-shaped subject's designator, or empty. The
  ## counterpart of `subjectNet`, resolved the same way and for the same
  ## reason: a part *inside* a subcircuit instance is named by a
  ## `hierSep`-separated path, and `spice/flatten` keeps that path.
  for s in a.subjects:
    if s.kind == skComponent and findComponent(d.netlist, s.name) != nil:
      return s.name
  ""

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
  measurementOnly(spec)
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

# --- oscillation, via .tran ---------------------------------------------

const oscQuantities = ["osc_freq", "swing_pp", "osc_thd_pct"]
  ## `swing_pp` rather than reusing `output_swing`, which `spice.large_signal`
  ## already produces: `registerEvaluator` refuses a second producer of a
  ## quantity outright, and the two are not the same measurement anyway --
  ## one is the response to a stated drive, the other is what the circuit
  ## does with no drive at all.

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

# --- the op-amp bundles, via .ac ----------------------------------------

const
  # Which analysis emits which name is verified against the `result.add`
  # calls in `opamp.nim`, not guessed: `f_unity` comes off the closed-loop
  # sweep, while `crossover_hz` is the loop gain's own 0 dB crossing.
  responseQuantities = ["bw_3db", "gain_dc_db", "gain_bw_product",
                        "peaking_db", "f_unity",
                        # Referenced to the response's maximum rather than to
                        # DC, which is the only way to describe an AC-coupled
                        # stage. See the note in `opamp.analyzeOpAmpResponse`.
                        "gain_max_db", "f_gain_max", "f_lo_3db", "f_hi_3db",
                        "gain_at_f"]
  largeSignalQuantities = ["thd_pct", "output_swing", "clip_high",
                           "clip_low", "gain_compressed_db"]
  loopQuantities = ["phase_margin_deg", "gain_margin_db", "loop_gain_dc_db",
                    "crossover_hz"]

proc measurementOnly(spec: var OpAmpSpec) =
  spec.maxPeaking = Inf        ## a `>` test
  spec.minPhaseMargin = -Inf   ## a `<` test
  spec.minBandwidth = 0.0      ## explicitly gated on `> 0`
  spec.maxThd = 0.0            ## explicitly gated on `> 0`

proc opampKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # `at_f` joins the key for the same reason `f_from`/`f_to` do on the PDN
  # side: it changes the analysis's setup, so two claims at two frequencies
  # are two runs rather than one run reported twice.
  bindingName(d, a, "opamp") & "|" & bindingName(d, a, "input") & "|" &
  subjectNet(d, a) & "|" & $conditionFloat(a, "at_f", 0.0)

proc opampSetup(ctx: EvalContext, a: Assertion): tuple[amp, inp, outp, reason: string] =
  let d = ctx.design
  let amp = bindingName(d, a, "opamp")
  if amp.len == 0:
    return ("", "", "", "an op-amp measurement needs to know which component " &
            "the stage is built around; bind an `opamp` part on the role that " &
            "expands this claim")
  let inp = bindingName(d, a, "input")
  if inp.len == 0:
    return ("", "", "", "no `input` part is bound on the role that expands " &
            "this claim, and the stage cannot be driven without one")
  var outp = bindingName(d, a, "output")
  if outp.len == 0: outp = subjectNet(d, a)
  if outp.len == 0:
    return ("", "", "", "no output net to measure")
  (amp, inp, outp, "")

proc opampDoc(ctx: EvalContext, batch: seq[Assertion], loop: bool): string =
  let d = ctx.design
  let (amp, inp, outp, reason) = opampSetup(ctx, batch[0])
  if reason.len > 0: return "nothing ran: " & reason
  if loop:
    result = "`.ac` sweep with the loop around " & amp & " broken at its " &
             "inverting input, giving T = -V(A)/V(B) -- a real phase margin " &
             "rather than one read off the closed-loop curve"
  else:
    result = "`.ac` sweep of the closed-loop response of the stage around " &
             amp & ", driven at net '" & inp & "' and measured at net '" &
             outp & "'"
  let atF = conditionFloat(batch[0], "at_f", 0.0)
  if atF > 0.0: result &= ", with gain also read at " & eng(atF, "Hz")

proc runOpAmpKind(ctx: EvalContext, batch: seq[Assertion], name: string,
                  loop: bool): seq[AssertionResult] =
  let d = ctx.design
  let (amp, inp, outp, reason) = opampSetup(ctx, batch[0])
  if reason.len > 0:
    for a in batch: result.add notEvaluable(a, name, reason)
    return

  var spec = defaultOpAmpSpec()
  measurementOnly(spec)
  spec.gainAtFreq = conditionFloat(batch[0], "at_f", 0.0)

  var rep: AnalysisReport
  try:
    rep = if loop: analyzeLoopGain(d.netlist, amp, inp, outp, spec)
          else: analyzeOpAmpResponse(d.netlist, amp, inp, outp, spec)
  except CatchableError as e:
    return failBatch(batch, name, "the op-amp sweep failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc largeSignalKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # The drive level is part of the *setup*, not a limit: the whole point of
  # a large-signal run is that the answer depends on it, so two claims at
  # two amplitudes are two runs.
  opampKey(ctx, a) & "|" & $conditionFloat(a, "drive_v", 0.0) &
                   "|" & $conditionFloat(a, "drive_f", 0.0)

proc largeSignalDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let (amp, inp, outp, reason) = opampSetup(ctx, batch[0])
  if reason.len > 0: return "nothing ran: " & reason
  let v = conditionFloat(batch[0], "drive_v", 0.0)
  let f = conditionFloat(batch[0], "drive_f", 1.0e3)
  "`.tran` driving " & eng(v, "V") & " at " & eng(f, "Hz") & " into net '" &
  inp & "' through " & amp & ", measured at net '" & outp &
  "'. The stimulus carries the node's own DC bias, so a single-supply stage " &
  "is measured where it actually sits. The macromodel has no slew or " &
  "current limit, so any distortion here is the network's, not the part's"

proc runLargeSignal(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.large_signal"
  let (amp, inp, outp, reason) = opampSetup(ctx, batch[0])
  if reason.len > 0:
    for a in batch: result.add notEvaluable(a, name, reason)
    return

  var spec = defaultOpAmpSpec()
  measurementOnly(spec)
  spec.driveAmplitude = conditionFloat(batch[0], "drive_v", 0.0)
  spec.driveFreq = conditionFloat(batch[0], "drive_f", 1.0e3)
  if spec.driveAmplitude <= 0.0:
    for a in batch:
      result.add notEvaluable(a, name,
        "a large-signal measurement has no meaning without a drive level -- " &
        "the answer *is* a function of it. State `driveV` on the role that " &
        "expands this claim")
    return

  var rep: AnalysisReport
  try:
    rep = analyzeLargeSignal(d.netlist, amp, inp, outp, spec)
  except CatchableError as e:
    return failBatch(batch, name, "the large-signal run failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc runOpAmpResponse(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  runOpAmpKind(ctx, batch, "spice.opamp_response", loop = false)

proc runLoopGain(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  runOpAmpKind(ctx, batch, "spice.loop_gain", loop = true)

proc responseDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  opampDoc(ctx, batch, loop = false)

proc loopGainDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  opampDoc(ctx, batch, loop = true)

# --- two channels, compared -- via .ac ---------------------------------
#
# The first evaluator whose subjects are two role instances rather than one
# net. Each subject is an `skClass` reference to a stage role (`gain_stage`,
# `opamp_stage`, or a user-defined one), and `subjectRoleBinding` reads the
# amplifier, input and output off each -- the split the plan's §53 names:
# the expander is pure and states the claim over the two references, the
# evaluator recovers the topology.
#
# **Known cost, not optimised away**: `riaa_preamp` runs four `.ac` sweeps
# where two would do -- its two `gain_stage` steps and this one's two -- and
# routing one step's curves into another is planner work (§52-shaped) that
# §51's result cache is what would absorb. Recorded in `docs/findings.md`
# under §51 as a concrete second customer.

const channelMatchQuantities = ["gain_delta_max_db", "f_gain_delta_max",
                                "gain_delta_at_f", "f_lo_ratio", "f_hi_ratio"]

proc channelMatchSetup(d: Design, a: Assertion):
    tuple[ampA, inA, outA, ampB, inB, outB, reason: string] =
  ## Both channels' amplifier, input and output, read off the two role
  ## instances the subjects name. The refusal deliberately does **not**
  ## require either role to be `gain_stage`: `opamp_stage` binds the same
  ## three parts and a user-defined stage may too, and requiring a name is
  ## exactly the privileged mechanism `contract/CLAUDE.md` says a built-in
  ## must not use.
  if a.subjects.len != 2:
    return ("", "", "", "", "", "",
      "a channel-match claim takes exactly two subjects, the two stages")
  proc side(idx: int, label: string):
      tuple[amp, inp, outp, reason: string] =
    if subjectRole(d, a, idx).isNone:
      return ("", "", "",
        "the " & label & " subject does not name a declared role instance -- " &
        "bind it with `roleRef(\"<name>\")`, and declare that role first")
    let amp = subjectRoleBinding(d, a, idx, "opamp")
    let inp = subjectRoleBinding(d, a, idx, "input")
    let outp = subjectRoleBinding(d, a, idx, "output")
    if amp.isNone or inp.isNone or outp.isNone:
      var missing: seq[string]
      if amp.isNone: missing.add "opamp"
      if inp.isNone: missing.add "input"
      if outp.isNone: missing.add "output"
      return ("", "", "",
        "the " & label & " stage binds no " & missing.join("/") & " -- a " &
        "channel-match evaluator sweeps each stage the way an op-amp " &
        "response is swept, and needs the amplifier, the node it is driven " &
        "at and the node it is measured at")
    (amp.get.name, inp.get.name, outp.get.name, "")
  let (ampA, inA, outA, rA) = side(0, "first")
  if rA.len > 0: return ("", "", "", "", "", "", rA)
  let (ampB, inB, outB, rB) = side(1, "second")
  if rB.len > 0: return ("", "", "", "", "", "", rB)
  (ampA, inA, outA, ampB, inB, outB, "")

proc channelMatchKey(ctx: EvalContext, a: Assertion): string =
  ## Both channels' topology plus the band and the stated frequency. A band
  ## change is a different pair of sweeps, on the same reasoning as `opampKey`
  ## -- two claims over two bands are two runs whose answers are not
  ## comparable.
  let s = channelMatchSetup(ctx.design, a)
  s.ampA & "|" & s.inA & "|" & s.outA & "|" &
  s.ampB & "|" & s.inB & "|" & s.outB & "|" &
  $conditionFloat(a, "f_from", 0.0) & "|" & $conditionFloat(a, "f_to", 0.0) &
  "|" & $conditionFloat(a, "at_f", 0.0)

proc channelMatchSpecOf(a: Assertion): ChannelMatchSpec =
  result = defaultChannelMatchSpec()
  # Each channel's sweep runs in measurement-only mode like every other
  # adapter here: the per-channel `analyzeOpAmpResponse` states peaking and
  # bandwidth limits of its own, and leaving them live would report a claim
  # this evaluator is not making as an issue on its result.
  measurementOnly(result.opamp)
  # The comparison window is exactly what was swept, following `psrrSpecOf`:
  # `f_from`/`f_to` come off the role's conditions and set the `.ac` card, so
  # a claim "over 20 Hz .. 20 kHz" is compared over 20 Hz .. 20 kHz.
  let f0 = conditionFloat(a, "f_from", 0.0)
  let f1 = conditionFloat(a, "f_to", 0.0)
  if f0 > 0.0: result.opamp.fStart = f0
  if f1 > 0.0: result.opamp.fStop = f1
  result.gainAtFreq = conditionFloat(a, "at_f", 0.0)

proc channelMatchDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let s = channelMatchSetup(ctx.design, batch[0])
  if s.reason.len > 0: return "nothing ran: " & s.reason
  let spec = channelMatchSpecOf(batch[0])
  result = "two `.ac` sweeps, one per channel -- the closed-loop response of " &
           "the stage around " & s.ampA & " (driven at net '" & s.inA &
           "', measured at net '" & s.outA & "') and of the stage around " &
           s.ampB & " (net '" & s.inB & "' to net '" & s.outB & "') -- " &
           "compared point by point over " & eng(spec.opamp.fStart, "Hz") &
           " .. " & eng(spec.opamp.fStop, "Hz") & ". Both sweeps share one " &
           "spec so they share one frequency axis; the delta is in dB and " &
           "the figures are magnitudes, so which channel is named first " &
           "cannot change a verdict"
  if spec.gainAtFreq > 0.0:
    result &= ", with the delta also read at " & eng(spec.gainAtFreq, "Hz")

proc runChannelMatch(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  const name = "spice.channel_match"
  let d = ctx.design
  let s = channelMatchSetup(d, batch[0])
  if s.reason.len > 0:
    for a in batch: result.add notEvaluable(a, name, s.reason)
    return
  let spec = channelMatchSpecOf(batch[0])
  var rep: AnalysisReport
  try:
    rep = analyzeChannelMatch(d.netlist, s.ampA, s.inA, s.outA,
                              s.ampB, s.inB, s.outB, spec)
  except CatchableError as e:
    return failBatch(batch, name, "the channel-match run failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

# --- a load step --------------------------------------------------------

const loadStepQuantities = ["step_droop_v", "step_droop_pct",
                            "step_overshoot_v", "step_overshoot_pct",
                            "step_recover_s", "step_v_min", "step_v_max"]
  ## Deliberately none of `overshoot_pct` or `settle_time`, which
  ## `spice.startup` already produces and `registerEvaluator` would refuse a
  ## second producer of. That refusal is right here rather than merely
  ## procedural: a start-up overshoot is what a rail does on the way up from
  ## nothing, and a step overshoot is what it does on the way back down from
  ## a load. Two different measurements about two different events, and one
  ## name for both would let a claim about one be answered with the other.

proc measurementOnly(spec: var LoadStepSpec) =
  ## `analyzeLoadStep` states no limits of its own -- every figure it emits is
  ## a measurement and the assertion is the only judge -- so there is nothing
  ## to disable. Present so the module's shape holds and so a limit field
  ## added later cannot be forgotten here.
  discard spec

proc loadStepKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  # Everything that changes the run joins the key. The step *magnitude* in
  # particular: two claims at two magnitudes are two different questions --
  # a rail that holds up under 1 A may not under 3 A -- and pooling them
  # would answer one with the other's number, which is exactly what the
  # swept range does for `spice.dc_sweep`.
  subjectNet(d, a) & "|" & $conditionFloat(a, "step_from", 0.0) &
    "|" & $conditionFloat(a, "step_to", 0.0) &
    "|" & $conditionFloat(a, "step_edge", 0.0) &
    "|" & $conditionFloat(a, "step_at", 0.0) &
    "|" & $conditionFloat(a, "step_hold", 0.0) &
    "|" & $conditionFloat(a, "step_recover", 0.0) &
    "|" & $conditionFloat(a, "step_points", 0.0) &
    "|" & $conditionFloat(a, "step_band", 0.0)

proc loadStepSpecOf(a: Assertion): LoadStepSpec =
  result = defaultLoadStepSpec()
  measurementOnly(result)
  result.iFrom = conditionFloat(a, "step_from", 0.0)
  result.iTo = conditionFloat(a, "step_to", 0.0)
  result.tEdge = conditionFloat(a, "step_edge", 0.0)
  result.tSettle = conditionFloat(a, "step_at", 0.0)
  result.tHold = conditionFloat(a, "step_hold", 0.0)
  result.tRecover = conditionFloat(a, "step_recover", 0.0)
  result.windowSamples = int(conditionFloat(a, "step_points", 0.0))
  result.settleTol = conditionFloat(a, "step_band", 0.0)

proc loadStepDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let rail = subjectNet(d, batch[0])
  let spec = loadStepSpecOf(batch[0])
  result = "`.tran` over the whole design as authored -- not isolated, so " &
           "the rail has to hold itself up rather than be held by a boundary " &
           "source. A constant-current sink injected at net '" & rail &
           "' steps from " & eng(spec.iFrom, "A") & " to " &
           eng(spec.iTo, "A") & " in " & eng(edgeOf(spec), "s") & " at " &
           eng(spec.tSettle, "s")
  if spec.tHold > 0.0:
    result &= ", holds for " & eng(spec.tHold, "s") & " and is released again"
  else:
    result &= " and stays there"
  result &= ", with " & eng(recoverOf(spec), "s") & " watched after each " &
            "edge. Nothing is added to the design: a test load is not a part " &
            "anybody solders, and a resistor would sag with the rail and damp " &
            "the network being measured"

proc runLoadStep(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  const name = "spice.load_step"
  let rail = subjectNet(d, batch[0])
  if rail.len == 0:
    return failBatch(batch, name, "no net subject to measure")

  let spec = loadStepSpecOf(batch[0])
  if spec.iFrom == spec.iTo:
    for a in batch:
      result.add notEvaluable(a, name,
        "a load step needs two currents and this claim carries " &
        eng(spec.iFrom, "A") & " twice. Every quantity here is a difference " &
        "across the edge, so there is no default magnitude to assume -- " &
        "state `iFrom` and `iTo` on the role that expands this claim")
    return

  var rep: AnalysisReport
  try:
    rep = analyzeLoadStep(d.netlist, rail, spec)
  except CatchableError as e:
    return failBatch(batch, name,
      "the load step on '" & rail & "' failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

# --- supply rejection ---------------------------------------------------

const psrrToneQuantities = ["psrr_db", "in_ripple_v", "out_ripple_v"]
const psrrAcQuantities = ["psrr_min_db", "f_psrr_min", "psrr_at_f"]
  ## **Two evaluators and two disjoint quantity sets, not one of each.**
  ##
  ## `spice.dc_sweep` is one evaluator for two sweeps and the precedent does
  ## not carry: both of *its* modes are `.dc`, while these need different
  ## capabilities, and `Evaluator.needs` is a single set. One evaluator would
  ## have to declare `{capSpiceAc, capSpiceTran}` and would then be refused
  ## on a host offering only one of them -- under-serving both to serve
  ## neither.
  ##
  ## The names differ for a reason beyond the mechanics, too. A swept curve's
  ## worst point and a single tone's rejection are different measurements,
  ## and one name for both would let a claim about a band be answered with a
  ## number from one frequency.

proc measurementOnly(spec: var PsrrSpec) =
  ## Nothing to disable: every figure `analysis/psrr` emits is a measurement
  ## and its only limit -- the noise floor and the signal-to-noise margin --
  ## decides whether a number exists at all, not whether it passes.
  discard spec

proc psrrParts(d: Design, a: Assertion): tuple[src, inp, outp, reason: string] =
  ## The supply to ripple, the node the ripple is quoted at, and the node it
  ## is quoted against.
  ##
  ## `output` is the assertion's own subject; the other two come off the role
  ## that expanded it, because an assertion carries subjects and nothing
  ## else. Rejection is a relation between two nodes and a stimulus, and none
  ## of the three is recoverable from a netlist: which of a board's several
  ## sources is "the supply" is a design statement.
  result.outp = subjectNet(d, a)
  result.src = bindingName(d, a, "source")
  result.inp = bindingName(d, a, "input")
  if result.outp.len == 0:
    result.reason = "no net subject to measure the rejected ripple on"
  elif result.src.len == 0:
    result.reason = "a rejection measurement needs the supply whose ripple " &
      "it injects, and this claim names only the node it is measured at. " &
      "Bind a `source` part on the role that expands it"
  elif result.inp.len == 0:
    result.reason = "a rejection measurement is a ratio between two nodes " &
      "and this claim names one of them. Bind an `input` net on the role " &
      "that expands it -- the regulator's own input pin, so that whatever " &
      "the board's input filter removes counts to the filter and not to the " &
      "part"

proc psrrSpecOf(a: Assertion): PsrrSpec =
  result = defaultPsrrSpec()
  measurementOnly(result)
  result.fStart = conditionFloat(a, "f_from", 0.0)
  result.fStop = conditionFloat(a, "f_to", 0.0)
  result.atF = conditionFloat(a, "at_f", 0.0)
  result.rippleF = conditionFloat(a, "ripple_f", 0.0)
  result.rippleV = conditionFloat(a, "ripple_v", 0.0)
  result.tSettle = conditionFloat(a, "t_settle", 0.0)
  result.periods = int(conditionFloat(a, "ripple_periods", 0.0))
  result.samplesPerPeriod = int(conditionFloat(a, "ripple_points", 0.0))

proc psrrToneKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  let p = psrrParts(d, a)
  # The amplitude joins the key and that is not over-caution: a `.tran` is
  # not linear, so a tone big enough to move a converter's duty cycle gets a
  # different answer, which is the whole reason to run one instead of a
  # sweep.
  p.src & "|" & p.inp & "|" & p.outp & "|" &
    $conditionFloat(a, "ripple_f", 0.0) & "|" &
    $conditionFloat(a, "ripple_v", 0.0) & "|" &
    $conditionFloat(a, "t_settle", 0.0) & "|" &
    $conditionFloat(a, "ripple_periods", 0.0) & "|" &
    $conditionFloat(a, "ripple_points", 0.0)

proc psrrAcKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  let p = psrrParts(d, a)
  # The amplitude is absent on purpose: an `.ac` analysis is linear, so it
  # cannot move the answer and two claims that differ only in it are one run.
  p.src & "|" & p.inp & "|" & p.outp & "|" &
    $conditionFloat(a, "f_from", 0.0) & "|" & $conditionFloat(a, "f_to", 0.0)

proc psrrToneDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let p = psrrParts(d, batch[0])
  let spec = psrrSpecOf(batch[0])
  let f = (if spec.rippleF > 0.0: spec.rippleF else: 120.0)
  let v = (if spec.rippleV > 0.0: spec.rippleV else: 0.1)
  result = "`.tran` with " & eng(v, "V") & " of real ripple at " &
           eng(f, "Hz") & " injected in series with " &
           (if p.src.len > 0: p.src else: "an unbound source") &
           ", reading the amplitude at exactly that frequency on net '" &
           p.inp & "' and net '" & p.outp & "'. One run answers one " &
           "frequency, which is what buys the two things a sweep cannot " &
           "reach: a switching converter, whose rejection has no meaningful " &
           "linearisation, and an XSPICE code model, which contributes " &
           "nothing to an AC matrix unless it sets AC_GAIN and none here " &
           "does. The input amplitude is measured rather than assumed, so " &
           "whatever the board's input filter removed counts to the filter"

proc psrrAcDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let p = psrrParts(d, batch[0])
  let spec = psrrSpecOf(batch[0])
  let f0 = (if spec.fStart > 0.0: spec.fStart else: 10.0)
  let f1 = (if spec.fStop > 0.0: spec.fStop else: 1.0e7)
  result = "`.ac` sweep from " & eng(f0, "Hz") & " to " & eng(f1, "Hz") &
           " with 1 V of AC ripple in series with " &
           (if p.src.len > 0: p.src else: "an unbound source") &
           ", reading net '" & p.inp & "' against net '" & p.outp &
           "'. The sweep is linear, so the drive level cannot move the " &
           "answer. The design is simulated as authored -- not isolated, " &
           "since a rail held at its nominal by a boundary source cannot " &
           "ripple"

template psrrRun(evName: string, analyze: untyped) =
  ## The two adapters differ only in which proc they call, so the resolution,
  ## the refusals and the harvest are written once.
  let d {.inject.} = ctx.design
  let p {.inject.} = psrrParts(d, batch[0])
  if p.reason.len > 0:
    for a in batch: result.add notEvaluable(a, evName, p.reason)
    return
  let spec {.inject.} = psrrSpecOf(batch[0])
  var rep: AnalysisReport
  try:
    rep = analyze
  except CatchableError as e:
    return failBatch(batch, evName,
      "the supply-rejection run on '" & p.outp & "' failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, evName)

proc runPsrrTone(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  psrrRun("spice.psrr_tone",
          analyzePsrrTone(d.netlist, p.src, p.inp, p.outp, spec))

proc runPsrrAc(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  psrrRun("spice.psrr_ac",
          analyzePsrrAc(d.netlist, p.src, p.inp, p.outp, spec))

# --- registration -------------------------------------------------------

proc registerSimulatedEvaluators*() =
  ## Called at module init; exposed for the same reason
  ## `roles.registerBuiltinRoles` is.
  registerEvaluator(Evaluator(
    name: "spice.dc_voltage", produces: @dcVoltageQuantities,
    needs: {capSpiceOp}, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: opKey, setupDoc: opDoc, run: runDcVoltage))

  registerEvaluator(Evaluator(
    name: "spice.derating", produces: @deratingQuantities,
    needs: {capSpiceOp}, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: deratingKey, setupDoc: deratingDoc, run: runDerating))

  registerEvaluator(Evaluator(
    name: "spice.pdn", produces: @pdnQuantities,
    needs: {capSpiceOp, capSpiceAc}, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: pdnKey, setupDoc: pdnDoc, run: runPdn))

  registerEvaluator(Evaluator(
    name: "spice.dc_sweep", produces: @dcSweepQuantities,
    needs: {capSpiceDc}, arity: 1 .. 1, subjectKinds: {skNet},
    binds: @["source"],
    setupKey: dcSweepKey, setupDoc: dcSweepDoc, run: runDcSweep))

  registerEvaluator(Evaluator(
    name: "spice.startup", produces: @startupQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    binds: @["regulator", "output"],
    setupKey: startupKey, setupDoc: startupDoc, run: runStartup))

  registerEvaluator(Evaluator(
    name: "spice.transient", produces: @transientQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: transientKey, setupDoc: transientDoc, run: runTransient))

  registerEvaluator(Evaluator(
    name: "spice.current_path", produces: @currentQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skComponent},
    setupKey: currentKey, setupDoc: currentDoc, run: runCurrent))

  registerEvaluator(Evaluator(
    name: "spice.load_step", produces: @loadStepQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: loadStepKey, setupDoc: loadStepDoc, run: runLoadStep))

  registerEvaluator(Evaluator(
    name: "spice.psrr_tone", produces: @psrrToneQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    binds: @["source", "input"],
    setupKey: psrrToneKey, setupDoc: psrrToneDoc, run: runPsrrTone))

  registerEvaluator(Evaluator(
    name: "spice.psrr_ac", produces: @psrrAcQuantities,
    needs: {capSpiceAc}, arity: 1 .. 1, subjectKinds: {skNet},
    binds: @["source", "input"],
    setupKey: psrrAcKey, setupDoc: psrrAcDoc, run: runPsrrAc))

  registerEvaluator(Evaluator(
    name: "spice.oscillator", produces: @oscQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: oscKey, setupDoc: oscDoc, run: runOscillation))

  registerEvaluator(Evaluator(
    name: "spice.opamp_response", produces: @responseQuantities,
    needs: {capSpiceAc}, arity: 1 .. 1, subjectKinds: {skNet, skComponent},
    binds: @["opamp", "input"],
    setupKey: opampKey, setupDoc: responseDoc, run: runOpAmpResponse))

  registerEvaluator(Evaluator(
    name: "spice.large_signal", produces: @largeSignalQuantities,
    needs: {capSpiceOp, capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet, skComponent},
    binds: @["opamp", "input"],
    setupKey: largeSignalKey, setupDoc: largeSignalDoc, run: runLargeSignal))

  registerEvaluator(Evaluator(
    name: "spice.loop_gain", produces: @loopQuantities,
    needs: {capSpiceAc}, arity: 1 .. 1, subjectKinds: {skNet, skComponent},
    binds: @["opamp", "input"],
    setupKey: opampKey, setupDoc: loopGainDoc, run: runLoopGain))

  registerEvaluator(Evaluator(
    name: "spice.channel_match", produces: @channelMatchQuantities,
    needs: {capSpiceAc}, arity: 2 .. 2, subjectKinds: {skClass},
    binds: @["opamp", "input", "output"],
    setupKey: channelMatchKey, setupDoc: channelMatchDoc, run: runChannelMatch))

registerSimulatedEvaluators()
