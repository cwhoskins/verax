## Supply rejection -- `spice.psrr_tone` (via `.tran`) and `spice.psrr_ac`
## (via `.ac`).
##
## **Two evaluators and two disjoint quantity sets, not one of each.**
##
## `spice.dc_sweep` is one evaluator for two sweeps and the precedent does
## not carry: both of *its* modes are `.dc`, while these need different
## capabilities, and `Evaluator.needs` is a single set. One evaluator would
## have to declare `{capSpiceAc, capSpiceTran}` and would then be refused on
## a host offering only one of them -- under-serving both to serve neither.
##
## The names differ for a reason beyond the mechanics, too. A swept curve's
## worst point and a single tone's rejection are different measurements, and
## one name for both would let a claim about a band be answered with a number
## from one frequency.

import ./common
import ../analyses/psrr

const psrrToneQuantities = ["psrr_db", "in_ripple_v", "out_ripple_v"]
const psrrAcQuantities = ["psrr_min_db", "f_psrr_min", "psrr_at_f"]

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

proc registerPsrrEvaluators*() =
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
