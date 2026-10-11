## The op-amp evaluators -- `spice.opamp_response`, `spice.large_signal`,
## `spice.loop_gain` -- sharing `opampSetup` (topology), `opampKey`/
## `opampDoc`, and `runOpAmpKind` (both `.ac` adapters).

import std/tables
import ./common
import ../analyses/opamp

const
  # Verified against `opamp.nim`'s `result.add` calls: `f_unity` comes from
  # the closed-loop sweep, `crossover_hz` from the loop gain.
  responseQuantities = ["bw_3db", "gain_dc_db", "gain_bw_product",
                        "peaking_db", "f_unity",
                        # Referenced to the response maximum (for AC-coupled
                        # stages).
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

proc responseSpecOf(a: Assertion): OpAmpSpec =
  ## The `.ac` spec for the response and loop-gain sweeps.
  result = defaultOpAmpSpec()
  measurementOnly(result)
  result.gainAtFreq = conditionFloat(a, "at_f", 0.0)

proc largeSignalSpecOf(a: Assertion): OpAmpSpec =
  result = defaultOpAmpSpec()
  measurementOnly(result)
  result.driveAmplitude = conditionFloat(a, "drive_v", 0.0)
  result.driveFreq = conditionFloat(a, "drive_f", 1.0e3)

proc topologyKey(ctx: EvalContext, a: Assertion): string =
  let d = ctx.design
  bindingName(d, a, "opamp") & "|" & bindingName(d, a, "input") & "|" &
  bindingName(d, a, "output") & "|" & subjectNet(d, a)

proc opampKey(ctx: EvalContext, a: Assertion): string =
  topologyKey(ctx, a) & "|" & specKey(responseSpecOf(a))

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
  let atF = responseSpecOf(batch[0]).gainAtFreq
  if atF > 0.0: result &= ", with gain also read at " & eng(atF, "Hz")

proc runOpAmpKind(ctx: EvalContext, batch: seq[Assertion], name: string,
                  loop: bool): seq[AssertionResult] =
  let d = ctx.design
  let (amp, inp, outp, reason) = opampSetup(ctx, batch[0])
  if reason.len > 0:
    for a in batch: result.add notEvaluable(a, name, reason)
    return

  let spec = responseSpecOf(batch[0])

  var rep: AnalysisReport
  try:
    rep = if loop: analyzeLoopGain(d.netlist, amp, inp, outp, spec)
          else: analyzeOpAmpResponse(d.netlist, amp, inp, outp, spec)
  except CatchableError as e:
    return failBatch(batch, name, "the op-amp sweep failed: " & e.msg)
  for a in batch: result.add harvest(a, rep, name)

proc largeSignalKey(ctx: EvalContext, a: Assertion): string =
  # The drive level is setup, not a limit: two amplitudes are two runs.
  topologyKey(ctx, a) & "|" & specKey(largeSignalSpecOf(a))

proc largeSignalDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  let (amp, inp, outp, reason) = opampSetup(ctx, batch[0])
  if reason.len > 0: return "nothing ran: " & reason
  let spec = largeSignalSpecOf(batch[0])
  let (v, f) = (spec.driveAmplitude, spec.driveFreq)
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

  let spec = largeSignalSpecOf(batch[0])
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
  runOpAmpKind(ctx, batch, "spice.opamp_response", loop = false)

proc runLoopGain(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  runOpAmpKind(ctx, batch, "spice.loop_gain", loop = true)

proc responseDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  opampDoc(ctx, batch, loop = false)

proc loopGainDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  opampDoc(ctx, batch, loop = true)

proc registerOpAmpEvaluators*() =
  registerEvaluator(Evaluator(
    name: "spice.opamp_response", produces: @responseQuantities,
    needs: {capSpiceAc}, arity: 1 .. 1, subjectKinds: {skNet, skComponent},
    binds: @["opamp", "input"],
    conditions: @["at_f"],
    units: {"bw_3db": "Hz", "gain_dc_db": "dB", "gain_bw_product": "Hz",
            "peaking_db": "dB", "f_unity": "Hz", "gain_max_db": "dB",
            "f_gain_max": "Hz", "f_lo_3db": "Hz", "f_hi_3db": "Hz",
            "gain_at_f": "dB"}.toTable,
    setupKey: opampKey, setupDoc: responseDoc, run: runOpAmpResponse))

  registerEvaluator(Evaluator(
    name: "spice.large_signal", produces: @largeSignalQuantities,
    needs: {capSpiceOp, capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet, skComponent},
    binds: @["opamp", "input"],
    conditions: @["drive_v", "drive_f"],
    units: {"thd_pct": "%", "output_swing": "V", "clip_high": "V",
            "clip_low": "V", "gain_compressed_db": "dB"}.toTable,
    setupKey: largeSignalKey, setupDoc: largeSignalDoc, run: runLargeSignal))

  registerEvaluator(Evaluator(
    name: "spice.loop_gain", produces: @loopQuantities,
    needs: {capSpiceAc}, arity: 1 .. 1, subjectKinds: {skNet, skComponent},
    binds: @["opamp", "input"],
    conditions: @["at_f"],
    units: {"phase_margin_deg": "deg", "gain_margin_db": "dB",
            "loop_gain_dc_db": "dB", "crossover_hz": "Hz"}.toTable,
    setupKey: opampKey, setupDoc: loopGainDoc, run: runLoopGain))
