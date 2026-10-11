## Supply rejection: `spice.psrr_tone` (`.tran`) and `spice.psrr_ac` (`.ac`).
##
## **Two evaluators**: they need different capabilities, and one evaluator
## needing both would be refused on a host offering either alone. The
## quantity names differ too (a band's worst point vs one tone).

import std/tables
import ./common
import ../analyses/psrr

const psrrToneQuantities = ["psrr_db", "in_ripple_v", "out_ripple_v"]
const psrrAcQuantities = ["psrr_min_db", "f_psrr_min", "psrr_at_f"]

proc measurementOnly(spec: var PsrrSpec) =
  ## Nothing to disable: the only limits (noise floor, SNR margin) decide
  ## whether a number exists, not whether it passes.
  discard spec

proc psrrParts(d: Design, a: Assertion): tuple[src, inp, outp, reason: string] =
  ## The supply to ripple, the measured node, and the reference node.
  ## `output` is the subject; the others come off the expanding role (which
  ## source is "the supply" is a design statement).
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
  ## One spec for both adapters; each reads only its own conditions (the
  ## other's stay at the default), so the spec key never splits a run on a
  ## condition that run doesn't use.
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

proc psrrKey(ctx: EvalContext, a: Assertion): string =
  ## The three nodes and the whole spec. For `.tran` that includes the
  ## amplitude (not linear); for `.ac` it includes `at_f`, without which two
  ## point frequencies shared one run and the second was answered at the
  ## first's frequency.
  let p = psrrParts(ctx.design, a)
  p.src & "|" & p.inp & "|" & p.outp & "|" & specKey(psrrSpecOf(a))

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
  ## Shared resolution, refusals and harvest for both adapters.
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

proc registerPsrrEvaluators*() =
  registerEvaluator(Evaluator(
    name: "spice.psrr_tone", produces: @psrrToneQuantities,
    needs: {capSpiceTran}, arity: 1 .. 1, subjectKinds: {skNet},
    binds: @["source", "input"],
    conditions: @["ripple_f", "ripple_v", "t_settle", "ripple_periods",
                  "ripple_points"],
    units: {"psrr_db": "dB", "in_ripple_v": "V", "out_ripple_v": "V"}.toTable,
    setupKey: psrrKey, setupDoc: psrrToneDoc, run: runPsrrTone))

  registerEvaluator(Evaluator(
    name: "spice.psrr_ac", produces: @psrrAcQuantities,
    needs: {capSpiceAc}, arity: 1 .. 1, subjectKinds: {skNet},
    binds: @["source", "input"],
    conditions: @["f_from", "f_to", "at_f"],
    units: {"psrr_min_db": "dB", "f_psrr_min": "Hz", "psrr_at_f": "dB"}.toTable,
    setupKey: psrrKey, setupDoc: psrrAcDoc, run: runPsrrAc))
