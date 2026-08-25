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
import ./startup
import ./transient
import ./opamp

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
  for s in a.subjects:
    if s.kind == skNet and d.netlist.nets.hasKey(s.name): return s.name
  ""

proc bindingName(d: Design, a: Assertion, part: string): string =
  ## A part bound by the role that expanded this assertion. This is how an
  ## adapter recovers topology the assertion does not carry -- see
  ## `evaluate.originRole`.
  let s = originBinding(d, a, part)
  if s.isNone: return ""
  s.get.name

# --- the shared operating point -----------------------------------------

var sharedOp: OperatingPoint
var sharedOpFor: Design = nil

proc clearSharedOperatingPoint*() =
  ## Drops the cached operating point. Call it after mutating a design that
  ## has already been evaluated.
  sharedOpFor = nil
  sharedOp = OperatingPoint()

proc sharedOperatingPoint*(d: Design): OperatingPoint =
  ## One `.op` per design, solved on first request and reused by everything
  ## after it.
  ##
  ## **The cache is keyed by design identity and is deliberately not
  ## invalidated by content.** Nothing here can tell that a caller mutated a
  ## netlist between two evaluations, so the rule is stated instead: within a
  ## single `evaluate` this is exactly right, because the design does not
  ## change under it; a caller that edits a design and evaluates again must
  ## call `clearSharedOperatingPoint`. `verify.readiness` does.
  ##
  ## Sharing it is worth the rule. `dc_voltage` solved one, `analysis/derating`
  ## solved another per claimed rail, and every one of them was the same
  ## design with the same answer -- a design claiming two rails plus derating
  ## on both did three identical solves. It also makes DC-bias derating see
  ## nodes that no annotation describes, which is the blind spot that mattered.
  if sharedOpFor != d:
    sharedOp = solveOperatingPoint(root(d.netlist))
    sharedOpFor = d
  sharedOp

# --- dc_voltage, via .op ------------------------------------------------

const dcVoltageQuantities = ["dc_voltage"]

proc opKey(d: Design, a: Assertion): string = ""
  ## One `.op` answers every node voltage in the design at once, so every
  ## `dc_voltage` assertion shares a step no matter which net it names. This
  ## is the harvest model at its most visible: N assertions, one simulation.

proc opDoc(d: Design, batch: seq[Assertion]): string =
  var nets: seq[string]
  for a in batch:
    let n = subjectNet(d, a)
    if n.len > 0 and n notin nets: nets.add n
  result = "one `.op` solve of the whole design -- not isolated, so each " &
           "rail has to solve for itself rather than be told what it is"
  if nets.len > 0: result &= ". Reading net " & nets.join(", ")

proc runDcVoltage(d: Design, batch: seq[Assertion]): seq[AssertionResult] =
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
  const name = "spice.dc_voltage"

  # This used to solve its own `.op`. It now reads the shared one, which is
  # the same solve on the same netlist -- `solveOperatingPoint` materializes,
  # flattens and stands in for unmodelled parts exactly as this did, and for
  # the same stated reasons.
  let op = sharedOperatingPoint(d)
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

proc pdnKey(d: Design, a: Assertion): string =
  subjectNet(d, a) & "|" & $conditionFloat(a, "f_from", 0.0) &
                     "|" & $conditionFloat(a, "f_to", 0.0)

proc pdnDoc(d: Design, batch: seq[Assertion]): string =
  let rail = subjectNet(d, batch[0])
  let spec = defaultPdnSpec()
  let fFrom = conditionFloat(batch[0], "f_from", spec.targetFrom)
  let fTo = conditionFloat(batch[0], "f_to", spec.targetTo)
  "`.ac` sweep of net '" & rail & "' with 1 A injected, so the node voltage " &
  "*is* the impedance. Everything on the rail is isolated and the supply " &
  "cut away -- an ideal source is a dead short at AC and would read 0 ohm " &
  "everywhere. Judged over " & eng(fFrom, "Hz") & " .. " & eng(fTo, "Hz")

proc runPdn(d: Design, batch: seq[Assertion]): seq[AssertionResult] =
  const name = "spice.pdn"
  let rail = subjectNet(d, batch[0])
  if rail.len == 0:
    return failBatch(batch, name, "no net subject to sweep")

  var spec = defaultPdnSpec()
  measurementOnly(spec)
  # The sweep runs against capacitances derated from the shared operating
  # point rather than from whatever the nets happened to be annotated with.
  spec.bias = nodeVoltages(sharedOperatingPoint(d))
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

proc deratingKey(d: Design, a: Assertion): string = subjectNet(d, a)
  ## Keyed by rail, so each claimed rail is one `.op`. Unlike `dc_voltage`,
  ## which answers every net from a single run, this reduces to a *worst*
  ## over a filtered set of parts -- so one run cannot serve two subjects
  ## without returning two answers.

proc deratingDoc(d: Design, batch: seq[Assertion]): string =
  "the shared `.op`, read back as the DC actually across every part " &
  "touching net '" & subjectNet(d, batch[0]) &
  "', compared with the rating each part states"

proc runDerating(d: Design, batch: seq[Assertion]): seq[AssertionResult] =
  const name = "spice.derating"
  let rail = subjectNet(d, batch[0])
  if rail.len == 0:
    return failBatch(batch, name, "no net subject whose parts could be checked")

  var spec = defaultDeratingSpec()
  spec.onlyTouching = rail
  spec.precomputed = nodeVoltages(sharedOperatingPoint(d))
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

# --- the start-up bundle, via .tran -------------------------------------

const startupQuantities = ["final_v", "overshoot_pct", "rise_time_10_90",
                           "settle_time", "inrush_peak", "t_inrush_peak"]

proc measurementOnly(spec: var StartupSpec) =
  spec.overshootLimit = Inf  ## a `>` test
  spec.currentLimit = 0.0    ## explicitly gated on `> 0`

proc startupKey(d: Design, a: Assertion): string =
  bindingName(d, a, "regulator") & "|" & subjectNet(d, a)

proc startupDoc(d: Design, batch: seq[Assertion]): string =
  let a0 = batch[0]
  let regulator = bindingName(d, a0, "regulator")
  let measured = subjectNet(d, a0)
  let outputNet = bindingName(d, a0, "output")
  let driven = if outputNet.len > 0: outputNet else: measured
  if regulator.len == 0:
    return "a `.tran` from power-on -- but no `regulator` part is bound, so " &
           "nothing says what drives the rail"
  result = "`.tran` from power-on with " & regulator &
           " stood up as an ideal source following an assumed soft-start " &
           "ramp into net '" & driven & "'"
  if measured.len > 0 and measured != driven:
    result &= ", measured at net '" & measured &
              "' on the far side of the filter"
  result &= ". No control loop, current limit or dropout is modelled"

proc runStartup(d: Design, batch: seq[Assertion]): seq[AssertionResult] =
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

proc transientKey(d: Design, a: Assertion): string =
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

proc transientDoc(d: Design, batch: seq[Assertion]): string =
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

proc runTransient(d: Design, batch: seq[Assertion]): seq[AssertionResult] =
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

proc opampKey(d: Design, a: Assertion): string =
  # `at_f` joins the key for the same reason `f_from`/`f_to` do on the PDN
  # side: it changes the analysis's setup, so two claims at two frequencies
  # are two runs rather than one run reported twice.
  bindingName(d, a, "opamp") & "|" & bindingName(d, a, "input") & "|" &
  subjectNet(d, a) & "|" & $conditionFloat(a, "at_f", 0.0)

proc opampSetup(d: Design, a: Assertion): tuple[amp, inp, outp, reason: string] =
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

proc opampDoc(d: Design, batch: seq[Assertion], loop: bool): string =
  let (amp, inp, outp, reason) = opampSetup(d, batch[0])
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

proc runOpAmpKind(d: Design, batch: seq[Assertion], name: string,
                  loop: bool): seq[AssertionResult] =
  let (amp, inp, outp, reason) = opampSetup(d, batch[0])
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

proc largeSignalKey(d: Design, a: Assertion): string =
  # The drive level is part of the *setup*, not a limit: the whole point of
  # a large-signal run is that the answer depends on it, so two claims at
  # two amplitudes are two runs.
  opampKey(d, a) & "|" & $conditionFloat(a, "drive_v", 0.0) &
                   "|" & $conditionFloat(a, "drive_f", 0.0)

proc largeSignalDoc(d: Design, batch: seq[Assertion]): string =
  let (amp, inp, outp, reason) = opampSetup(d, batch[0])
  if reason.len > 0: return "nothing ran: " & reason
  let v = conditionFloat(batch[0], "drive_v", 0.0)
  let f = conditionFloat(batch[0], "drive_f", 1.0e3)
  "`.tran` driving " & eng(v, "V") & " at " & eng(f, "Hz") & " into net '" &
  inp & "' through " & amp & ", measured at net '" & outp &
  "'. The stimulus carries the node's own DC bias, so a single-supply stage " &
  "is measured where it actually sits. The macromodel has no slew or " &
  "current limit, so any distortion here is the network's, not the part's"

proc runLargeSignal(d: Design, batch: seq[Assertion]): seq[AssertionResult] =
  const name = "spice.large_signal"
  let (amp, inp, outp, reason) = opampSetup(d, batch[0])
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

proc runOpAmpResponse(d: Design, batch: seq[Assertion]): seq[AssertionResult] =
  runOpAmpKind(d, batch, "spice.opamp_response", loop = false)

proc runLoopGain(d: Design, batch: seq[Assertion]): seq[AssertionResult] =
  runOpAmpKind(d, batch, "spice.loop_gain", loop = true)

proc responseDoc(d: Design, batch: seq[Assertion]): string =
  opampDoc(d, batch, loop = false)

proc loopGainDoc(d: Design, batch: seq[Assertion]): string =
  opampDoc(d, batch, loop = true)

# --- registration -------------------------------------------------------

proc registerSimulatedEvaluators*() =
  ## Called at module init; exposed for the same reason
  ## `roles.registerBuiltinRoles` is.
  registerEvaluator(Evaluator(
    name: "spice.dc_voltage", produces: @dcVoltageQuantities,
    needs: capSpiceOp, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: opKey, setupDoc: opDoc, run: runDcVoltage))

  registerEvaluator(Evaluator(
    name: "spice.derating", produces: @deratingQuantities,
    needs: capSpiceOp, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: deratingKey, setupDoc: deratingDoc, run: runDerating))

  registerEvaluator(Evaluator(
    name: "spice.pdn", produces: @pdnQuantities,
    needs: capSpiceAc, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: pdnKey, setupDoc: pdnDoc, run: runPdn))

  registerEvaluator(Evaluator(
    name: "spice.startup", produces: @startupQuantities,
    needs: capSpiceTran, arity: 1 .. 1, subjectKinds: {skNet},
    binds: @["regulator", "output"],
    setupKey: startupKey, setupDoc: startupDoc, run: runStartup))

  registerEvaluator(Evaluator(
    name: "spice.transient", produces: @transientQuantities,
    needs: capSpiceTran, arity: 1 .. 1, subjectKinds: {skNet},
    setupKey: transientKey, setupDoc: transientDoc, run: runTransient))

  registerEvaluator(Evaluator(
    name: "spice.opamp_response", produces: @responseQuantities,
    needs: capSpiceAc, arity: 1 .. 1, subjectKinds: {skNet, skComponent},
    binds: @["opamp", "input"],
    setupKey: opampKey, setupDoc: responseDoc, run: runOpAmpResponse))

  registerEvaluator(Evaluator(
    name: "spice.large_signal", produces: @largeSignalQuantities,
    needs: capSpiceTran, arity: 1 .. 1, subjectKinds: {skNet, skComponent},
    binds: @["opamp", "input"],
    setupKey: largeSignalKey, setupDoc: largeSignalDoc, run: runLargeSignal))

  registerEvaluator(Evaluator(
    name: "spice.loop_gain", produces: @loopQuantities,
    needs: capSpiceAc, arity: 1 .. 1, subjectKinds: {skNet, skComponent},
    binds: @["opamp", "input"],
    setupKey: opampKey, setupDoc: loopGainDoc, run: runLoopGain))

registerSimulatedEvaluators()
