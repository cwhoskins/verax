## `spice.channel_match` -- two amplifier channels compared, via `.ac`.
##
## Subjects are two `skClass` references to stage roles; `subjectRoleBinding`
## reads amplifier, input and output off each.
##
## Known cost: a design with two `gain_stage` claims plus this one runs four
## `.ac` sweeps where two would do (sharing curves between steps would need
## a result cache).

import std/strutils
import ./common
import ../analyses/opamp
import ../analyses/match

const channelMatchQuantities = ["gain_delta_max_db", "f_gain_delta_max",
                                "gain_delta_at_f", "f_lo_ratio", "f_hi_ratio"]

proc measurementOnly(spec: var OpAmpSpec) =
  spec.maxPeaking = Inf
  spec.minPhaseMargin = -Inf
  spec.minBandwidth = 0.0
  spec.maxThd = 0.0

proc channelMatchSetup(d: Design, a: Assertion):
    tuple[ampA, inA, outA, ampB, inB, outB, reason: string] =
  ## Both channels' amplifier, input and output. Doesn't require a
  ## particular role name (`opamp_stage` and user stages bind the same
  ## parts).
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
  ## Both channels' topology, band and frequency; a different band is a
  ## different pair of sweeps.
  let s = channelMatchSetup(ctx.design, a)
  s.ampA & "|" & s.inA & "|" & s.outA & "|" &
  s.ampB & "|" & s.inB & "|" & s.outB & "|" &
  $conditionFloat(a, "f_from", 0.0) & "|" & $conditionFloat(a, "f_to", 0.0) &
  "|" & $conditionFloat(a, "at_f", 0.0)

proc channelMatchSpecOf(a: Assertion): ChannelMatchSpec =
  result = defaultChannelMatchSpec()
  # Measurement-only, so the per-channel analysis's own limits don't
  # surface as issues.
  measurementOnly(result.opamp)
  # Compare over exactly what was swept (`f_from`/`f_to` from conditions).
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

proc registerChannelMatchEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.channel_match", produces: @channelMatchQuantities,
    needs: {capSpiceAc}, arity: 2 .. 2, subjectKinds: {skClass},
    binds: @["opamp", "input", "output"],
    setupKey: channelMatchKey, setupDoc: channelMatchDoc, run: runChannelMatch))
