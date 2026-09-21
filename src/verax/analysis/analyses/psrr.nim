## How much of the supply's ripple reaches the rail.
##
## A regulator is bought on three numbers and this is the third: what voltage
## it makes, how much current it can deliver, and how well it ignores what is
## happening on its input. The first two are answerable here already -- an
## `.op` for the rail, `analyzeCurrent` for what flows -- and the third was
## not askable at all, which left every design in this repository silently
## assuming its regulator rejects everything.
##
## ## Two methods, because there are two kinds of regulator
##
## `analyzePsrrAc` puts a small AC ripple on the supply and sweeps, reading
## rejection across a band in one run. It is the cheap and complete answer,
## and it is the *right* answer for anything an `.ac` can linearise: a linear
## regulator, an LDO, a passive input filter.
##
## `analyzePsrrTone` puts one real sinusoid on the supply, runs a `.tran`, and
## extracts the amplitude at exactly that frequency at both ends. One run per
## frequency, so a curve is expensive and a datasheet-shaped claim ("65 dB at
## 120 Hz") is not. What it buys is everything `.ac` cannot reach:
##
##   * **a switching converter**, whose rejection is a property of how its
##     duty cycle responds cycle by cycle and which has no meaningful
##     linearisation about an operating point at all;
##   * **an XSPICE code model**, which contributes to the AC matrix only if it
##     sets `AC_GAIN`, and none of the models in this repository does;
##   * anything where the ripple is large enough that the answer depends on
##     its size, which is exactly when the question is worth asking.
##
## Neither is a fallback for the other. A design states which it means and the
## quantity names differ, because a curve's worst point and a single tone's
## rejection are different measurements and pooling them would report one as
## the other.
##
## ## Where the ripple goes in
##
## In series with the supply, not written over its value. A source's
## `attrs["value"]` may be any string SPICE accepts -- `"DC 12"`, but also
## `"DC 0 AC 1"` or a whole `PULSE`/`PWL` specification -- so editing it means
## parsing it, and `parseSpiceMagnitude` exists precisely because that is not
## something to do by guesswork. Splitting the supply's own pin onto a fresh
## net and putting the ripple source between them works whatever the supply
## says, and it is the same move `probes.addCurrentProbe` already makes for
## the same reason.
##
## It goes in **before** the supply's own output impedance, which is where a
## supply's ripple actually is: what reaches the board is then filtered by the
## wiring inductance and the input capacitors, and that filtering is part of
## the answer the board is responsible for.
##
## ## Measure the input ripple; never assume it
##
## Both procs report `in_ripple_v` beside `out_ripple_v` and quote the ratio
## of the two. Quoting against the *injected* amplitude instead would credit
## the regulator with whatever the input filter did before the ripple ever
## reached it -- which on a board with a ferrite and two ceramics is most of
## the answer, and belongs to the filter rather than to the part.
##
## ## The guard, and why it is not optional
##
## `spice/models.regulatorModel` stands an unmodelled regulator in as an ideal
## source at its output voltage. An ideal source has no input: no ripple can
## reach its output by any path, so the measured rejection is not large, it is
## *infinite*. So is the rejection of any model whose output does not depend
## on its input -- which is the shape a behavioural regulator naturally takes
## unless it was written not to.
##
## A claim that cannot fail is worse than no claim, so an output ripple at the
## solver's noise floor with a real input ripple above it is reported as
## `NaN` and a `KindNoFeedthrough` issue naming the cause, never as a number.
## "This rail rejects perfectly" and "nothing was simulated that could fail"
## are opposite conclusions and must not share a value.
##
## **No isolation**, on `runDcVoltage`'s and `analyzeTransient`'s reasoning: a
## rail terminated by a boundary source at its nominal voltage cannot ripple.

import std/[math, strutils, tables]

import ../../netlist/types
import ../../netlist/graph
import ../../netlist/kinds
import ../../netlist/formats/spice as spiceFormat
import ../../spice/transform
import ../../spice/flatten
import ../../spice/models
import ../../spice/probes
import ../../spice/ngspice
import ../measure
import ../report

export report

const
  KindSimulationFailed* = "psrr_simulation_failed"
  KindNoFeedthrough* = "psrr_no_feedthrough"
    ## The output carried no measurable ripple while the input did. Almost
    ## always a model with no path from its input to its output rather than a
    ## regulator with infinite rejection.
  KindNoRipple* = "psrr_no_input_ripple"
    ## The *input* carried no measurable ripple: the injection never reached
    ## the node being quoted against.

const
  ripplePrefix = "VPSRRIN"
  defaultFloor = 1.0e-9
    ## Volts. Below this an ngspice result is the solver's own residue rather
    ## than a signal -- ~180 dB down on a volt of ripple, which no real
    ## regulator approaches and no model with a genuine path reports.

type
  PsrrSpec* = object
    fStart*, fStop*: float
      ## The swept band, for `analyzePsrrAc`. 0 takes 10 Hz to 10 MHz.
    ptsPerDecade*: int
      ## 0 takes 20.
    atF*: float
      ## Where `psrr_at_f` is read off the swept curve. 0 omits it. Outside
      ## the band it is `NaN` rather than extrapolated.
    rippleF*: float
      ## The tone, for `analyzePsrrTone`. 0 takes 120 Hz, which is where a
      ## datasheet quotes ripple rejection because it is twice the mains
      ## frequency and therefore what comes off a rectifier.
    rippleV*: float
      ## Its amplitude in volts, zero to peak. 0 takes 100 mV. Unlike an
      ## `.ac` drive this one **matters**: a `.tran` is not linear, and a
      ## tone big enough to move the duty cycle of a converter or to push a
      ## linear regulator toward dropout gets a different answer -- which is
      ## the reason to run one.
    tSettle*: float
      ## When the measurement window opens. Everything before it is
      ## simulated and discarded, on `analyzeTransient`'s reasoning.
    periods*: int
      ## Whole periods of `rippleF` in the window. 0 takes 8. Whole, because
      ## `harmonicAmplitudes` integrates over an exact number of them and a
      ## fractional window leaks the tone into every other bin.
    samplesPerPeriod*: int
      ## 0 takes 200. The derived print step is also ngspice's ceiling on its
      ## own timestep, so this sets how well the tone is *solved*.
    floorV*: float
      ## Below this an output amplitude is treated as no signal at all.
      ## 0 takes 1 nV. An absolute floor is enough for an `.ac` solve, whose
      ## answer for a node nothing reaches is exactly zero; the tone method
      ## needs the signal-to-noise test below as well.
    snrMargin*: float
      ## How far above the run's own numerical residue an output amplitude
      ## has to sit before the tone method believes it. 0 takes 2 (6 dB).
      ## See `noiseAt`: a `.tran` does not answer zero for a node nothing
      ## reaches, it answers a truncation artefact, and on a rail stood up as
      ## an ideal source that artefact measured **107.6 dB** of apparent
      ## rejection -- a plausible, excellent, entirely fictional number.
    pinModels*: PinModelDefaults
    parasitics*: ParasiticDefaults
    sourceZ*: SourceDefaults
    flattenHierarchy*: bool
    keepInstances*: seq[string]
    modelUnmodelledParts*: bool
    capacitorParasitics*: bool
    modelSources*: bool
      ## Put the supply's own output impedance in series with it. **Off by
      ## default here**, unlike everywhere else in this library, and for two
      ## reasons that both point the same way.
      ##
      ## Rejection is quoted between two nodes and *both* are measured, so
      ## whatever sits upstream of the input node only decides how much
      ## ripple arrives there -- which `in_ripple_v` reports rather than
      ## assumes. The supply's impedance is therefore not part of the answer
      ## the way it is for a PDN sweep, where it sits in parallel with the
      ## decoupling and sets the result directly.
      ##
      ## And the default is *invented*: 10 mohm in series with 1 uH. On a
      ## switching converter that microhenry resonates with the input
      ## capacitors at tens of kilohertz, undamped, and a tone above it stops
      ## the run converging at all -- measured on `designs/lt8640a_buck.nim`,
      ## which fails outright with it on and reports 71.9 dB with it off. A
      ## number nobody stated should not decide whether a measurement
      ## happens.

proc defaultPsrrSpec*(): PsrrSpec =
  PsrrSpec(fStart: 0.0, fStop: 0.0, ptsPerDecade: 0, atF: 0.0,
           rippleF: 0.0, rippleV: 0.0, tSettle: 0.0, periods: 0,
           samplesPerPeriod: 0, floorV: 0.0, snrMargin: 0.0,
           pinModels: defaultPinModels(),
           parasitics: defaultParasitics(),
           sourceZ: defaultSourceImpedance(),
           flattenHierarchy: true, modelUnmodelledParts: true,
           capacitorParasitics: true, modelSources: false)

proc fStartOf(s: PsrrSpec): float = (if s.fStart > 0.0: s.fStart else: 10.0)
proc fStopOf(s: PsrrSpec): float = (if s.fStop > 0.0: s.fStop else: 1.0e7)
proc ptsOf(s: PsrrSpec): int = (if s.ptsPerDecade > 0: s.ptsPerDecade else: 20)
proc toneOf(s: PsrrSpec): float = (if s.rippleF > 0.0: s.rippleF else: 120.0)
proc amplitudeOf(s: PsrrSpec): float =
  if s.rippleV > 0.0: s.rippleV else: 0.1
proc periodsOf(s: PsrrSpec): int = (if s.periods > 0: s.periods else: 8)
proc perPeriodOf(s: PsrrSpec): int =
  if s.samplesPerPeriod > 0: s.samplesPerPeriod else: 200
proc floorOf(s: PsrrSpec): float =
  if s.floorV > 0.0: s.floorV else: defaultFloor
proc snrOf(s: PsrrSpec): float =
  if s.snrMargin > 0.0: s.snrMargin else: 2.0

proc prepare(nl: Netlist, spec: PsrrSpec, rep: var AnalysisReport,
             purpose: string, namedParts: varargs[string]): Netlist =
  ## The purpose differs between the two methods and it is not bookkeeping.
  ## An `.ac` sweep wants whatever model linearises -- `spSmallSignal`. A
  ## tone is a steady-state time-domain measurement, so it wants the model a
  ## part offers for that: on a converter carrying both, that is the
  ## switching one, and asking it for ripple rejection through the averaged
  ## model would measure the wrong half of the part.
  # Clone, flatten, *then* apply `simReplace` -- not the combined
  # `materializeSimNetlist` -- so a nested XSPICE component's `A`-line ports
  # are rendered from post-flatten net names rather than frozen at
  # child-template-local ones flatten is about to rename out from under it
  # (see `spice/flatten`'s module doc).
  var cloneNets: OrderedTable[string, Net]
  result = clone(nl, cloneNets)
  discard flattenForSim(result, spec.flattenHierarchy, spec.keepInstances,
                        namedParts)
  applySimReplacements(result, purpose = purpose)
  if spec.modelUnmodelledParts:
    rep.assumptions.add expandPinModels(result, spec.pinModels)
  if spec.capacitorParasitics:
    rep.assumptions.add expandCapacitorParasitics(result, spec.parasitics)

proc supplyPin(work: Netlist, source: string): Pin =
  ## The pin of `source` that faces the board: the one that is not on ground.
  ##
  ## By net rather than by name, because the name is not reliable at this
  ## point -- `expandSourceImpedance` may already have moved `+` onto an
  ## internal node, which is where the ripple belongs anyway.
  let c = findComponent(work, source)
  if c == nil:
    raise newException(NetlistError,
      "no such component: " & source & " -- a psrr measurement needs the " &
      "supply whose ripple it is injecting, named as the design writes it")
  let desig = spiceFormat.deckDesignator(c)
  if desig.len == 0 or desig[0].toUpperAscii != 'V':
    raise newException(NetlistError,
      source & " is a '" & c.kind & "', which reaches the deck as '" & desig &
      "'. Ripple is injected in series with a *voltage* source; there is " &
      "nothing to put it in series with here")
  var candidate: Pin
  for name, p in c.pins:
    if p.net == nil: continue
    if isGround(p.net) or p.net.name == "0": continue
    if name == "+": return p
    if candidate == nil: candidate = p
  if candidate == nil:
    raise newException(NetlistError,
      source & " has no pin facing anything but ground, so there is no " &
      "series path to put a ripple source into")
  candidate

proc injectRipple(work: Netlist, source, value: string): string =
  ## Splits the supply off its own net and puts a ripple source in the gap.
  ## Returns the designator, for nothing but the assumption text.
  var desig = ripplePrefix
  var n = 0
  while work.components.hasKey(desig):
    inc n
    desig = ripplePrefix & $n
  let probe = addCurrentProbe(work, supplyPin(work, source), desig)
  probe.source.attrs["value"] = value
  # An ideal series source, deliberately: this is the stimulus, and
  # `expandSourceImpedance`'s default 10 mohm + 1 uH would sit between the
  # ripple and the supply it is meant to be riding on.
  probe.source.attrs["rout"] = "0"
  probe.source.attrs["lout"] = "0"
  desig

proc netOr(work: Netlist, name, what: string): Net =
  result = findNet(work, name)
  if result == nil:
    raise newException(NetlistError,
      "no such net: " & name & " (psrr " & what & ")")

proc verdictOf(rep: var AnalysisReport, inAmp, outAmp, floorV: float,
               inputNet, outputNet: string, noise = 0.0): float =
  ## The ratio in dB, or `NaN` with the issue that says why not.
  ##
  ## `noise` is what the same measurement reads at frequencies carrying no
  ## signal; zero means the caller has no such estimate and only the absolute
  ## floor applies.
  if inAmp.isNaN or inAmp <= floorV:
    rep.issues.add newIssue(KindNoRipple, sevWarning,
      "no ripple reached net '" & inputNet & "': the injected tone measured " &
      eng(inAmp, "V") & " there, at or below the " & eng(floorV, "V") &
      " floor. Either something between the supply and that node removed it, " &
      "or the node named is not on the regulator's input")
    return NaN
  if outAmp.isNaN or outAmp <= floorV or outAmp <= noise:
    let against =
      if noise > floorV and not outAmp.isNaN and outAmp <= noise:
        "which is not above the " & eng(noise, "V") &
        " this same run reads at frequencies carrying no signal at all"
      else:
        "at or below the " & eng(floorV, "V") & " floor"
    rep.issues.add newIssue(KindNoFeedthrough, sevWarning,
      "net '" & inputNet & "' carried " & eng(inAmp, "V") & " of ripple and " &
      "net '" & outputNet & "' carried " & eng(outAmp, "V") & ", " & against &
      " -- which is not rejection, it is " &
      "the absence of a path. Whatever stands in for the regulator here has " &
      "an output that does not depend on its input: an ideal source at a " &
      "stated voltage (the default for a part carrying no model), or a " &
      "behavioural model that commands a voltage rather than a duty. " &
      "Rejection cannot be measured through it, and a number here would be " &
      "a claim that can never fail")
    return NaN
  20.0 * log10(inAmp / outAmp)

# --- the small-signal sweep -------------------------------------------------

proc acCard(spec: PsrrSpec): string =
  ".ac dec " & $ptsOf(spec) & " " & spiceFormat.spiceValue(fStartOf(spec)) &
  " " & spiceFormat.spiceValue(fStopOf(spec))

proc analyzePsrrAc*(nl: Netlist, source, inputNet, outputNet: string,
                    spec = defaultPsrrSpec()): AnalysisReport =
  ## Supply rejection across a band, from one `.ac` sweep.
  ##
  ## Reports `psrr_min_db` (the *worst* rejection anywhere in the band, which
  ## is the figure a rail has to be designed to), `f_psrr_min` (where that
  ## is), and `psrr_at_f` when `spec.atF` names a frequency.
  ##
  ## The drive amplitude is 1 V and that is not a physical choice: an `.ac`
  ## analysis is linear, so the level cannot affect the answer, and 1 makes
  ## the input trace read directly as the transfer function. Where the level
  ## *does* matter, the question wants `analyzePsrrTone` instead.
  result.name = "psrr"

  let work = prepare(nl, spec, result, spSmallSignal, source)
  discard netOr(work, inputNet, "input")
  discard netOr(work, outputNet, "output")
  if spec.modelSources:
    result.assumptions.add expandSourceImpedance(work, spec.sourceZ)
  let desig = injectRipple(work, source, "DC 0 AC 1")
  result.assumptions.add note(desig,
    "1 V of AC ripple injected in series with " & source & ", ahead of its " &
    "own output impedance. The sweep is linear, so the amplitude cannot " &
    "move the answer; what reaches net '" & inputNet & "' is measured rather " &
    "than assumed, so whatever the input filter removes is the filter's " &
    "credit and not the regulator's")

  try:
    result.raw = run(work, acCard(spec), label = "psrr:" & outputNet)
  except SpiceSimError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not sweep the supply ripple: " & e.msg)
    return

  let f = result.raw.freq()
  if f.len == 0:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the sweep produced no frequency axis")
    return
  let vin = result.raw.mag("v(" & inputNet & ")")
  let vout = result.raw.mag("v(" & outputNet & ")")
  if vin.len != f.len or vout.len != f.len:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the sweep produced " & $f.len & " frequencies but " & $vin.len &
      " and " & $vout.len & " points on the two nodes")
    return

  # The worst point in the band, found on the curve rather than at its ends:
  # a regulator's rejection has a minimum where its loop gain has rolled off
  # and its output capacitor has not yet taken over, and quoting either
  # endpoint would miss it.
  let floorV = floorOf(spec)
  var db: seq[float]
  var worst = Inf
  var worstF = NaN
  var sawSignal = false
  var sawIn = false
  for i in 0 ..< f.len:
    if vin[i] > floorV: sawIn = true
    if vout[i] > floorV: sawSignal = true
    let d = if vin[i] > 0.0 and vout[i] > 0.0:
              20.0 * log10(vin[i] / vout[i])
            else: NaN
    db.add d
    if not d.isNaN and d < worst:
      worst = d
      worstF = f[i]

  if not sawIn or not sawSignal:
    # One shared explanation for both halves, so the reasoning lives in one
    # place: `verdictOf` writes the issue and returns the NaN.
    let iRef = if vin.len > 0: vin[0] else: NaN
    let oRef = if vout.len > 0: vout[0] else: NaN
    discard verdictOf(result, (if sawIn: max(iRef, floorV * 2.0) else: iRef),
                      (if sawSignal: oRef else: 0.0), floorV,
                      inputNet, outputNet)
    result.add "psrr_min_db", NaN, "dB"
    result.add "f_psrr_min", NaN, "Hz"
    if spec.atF > 0.0: result.add "psrr_at_f", NaN, "dB"
    return

  result.add "psrr_min_db", worst, "dB"
  result.add "f_psrr_min", worstF, "Hz"
  if spec.atF > 0.0:
    result.add "psrr_at_f", valueAt(f, db, spec.atF, logX = true), "dB"

# --- one real tone ----------------------------------------------------------

proc analyzePsrrTone*(nl: Netlist, source, inputNet, outputNet: string,
                      spec = defaultPsrrSpec()): AnalysisReport =
  ## Supply rejection at one frequency, from a `.tran` with a real sinusoid
  ## on the supply.
  ##
  ## Reports `psrr_db` together with the two amplitudes it is the ratio of,
  ## `in_ripple_v` and `out_ripple_v` -- both extracted at exactly the
  ## injected frequency by `measure.harmonicAmplitudes`, which integrates
  ## over the samples' own timestamps and over a whole number of periods.
  ## That matters more here than anywhere else in this library: a switching
  ## converter's output carries its own switching ripple, often larger than
  ## the supply ripple that got through, and a peak-to-peak reading would
  ## report the switching frequency as rejection. Picking the tone out of it
  ## is the whole measurement.
  result.name = "psrr tone"

  let f0 = toneOf(spec)
  let amp = amplitudeOf(spec)
  let period = 1.0 / f0
  let window = float(periodsOf(spec)) * period
  let tStop = spec.tSettle + window
  let tStep = period / float(perPeriodOf(spec))

  let work = prepare(nl, spec, result, spSteadyState, source)
  discard netOr(work, inputNet, "input")
  discard netOr(work, outputNet, "output")
  if spec.modelSources:
    result.assumptions.add expandSourceImpedance(work, spec.sourceZ)
  let desig = injectRipple(work, source,
    "DC 0 SIN(0 " & spiceFormat.spiceValue(amp) & " " &
    spiceFormat.spiceValue(f0) & ")")
  result.assumptions.add note(desig,
    eng(amp, "V") & " of ripple at " & eng(f0, "Hz") & " injected in series " &
    "with " & source & ", ahead of its own output impedance. Unlike an `.ac` " &
    "drive this amplitude is part of the answer -- a `.tran` is not linear, " &
    "so a tone large enough to move a duty cycle or approach dropout gets a " &
    "different figure, which is the reason to run one")

  var card = ".tran " & spiceFormat.spiceValue(tStep) & " " &
             spiceFormat.spiceValue(tStop)
  if spec.tSettle > 0.0:
    card &= " " & spiceFormat.spiceValue(spec.tSettle)

  try:
    result.raw = run(work, card, label = "psrr tone:" & outputNet)
  except SpiceSimError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not run the ripple tone: " & e.msg)
    return

  let t = result.raw["time"]
  if t.len < 4:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the run produced " & $t.len & " sample(s), which is too few to " &
      "extract an amplitude from")
    return

  var vin, vout: seq[float]
  try:
    vin = result.raw["v(" & inputNet & ")"]
    vout = result.raw["v(" & outputNet & ")"]
  except KeyError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the run produced no trace for one of the two nodes: " & e.msg)
    return

  proc amplitudeAt(v: seq[float], f: float): float =
    let a = harmonicAmplitudes(t, v, f, upTo = 1)
    if a.len == 0: NaN else: a[0]

  proc noiseAt(v: seq[float]): float =
    ## What this run reads at frequencies where the circuit is not being
    ## driven -- its own truncation residue, and the yardstick the tone has
    ## to beat.
    ##
    ## **A `.tran` does not answer zero for a node nothing reaches.** It
    ## answers whatever the timestep control left behind, and projecting that
    ## onto one frequency gives a small number that looks exactly like a
    ## measurement: on a rail stood up as an ideal source, 414 nV against
    ## 100 mV in, which reports 107.6 dB of rejection. No absolute floor
    ## catches that, because the residue is a property of the run's settings
    ## rather than of the circuit -- refine the timestep and it moves.
    ##
    ## Two probes at irrational-looking multiples of the tone, so neither
    ## lands on a harmonic of it or of a switching frequency, and the
    ## **smaller** of the two is taken. Smaller because this is a floor a
    ## real measurement has to clear: if one probe happens to sit on
    ## something the circuit genuinely produces, using it would inflate the
    ## floor and refuse an answer that was real.
    let a = amplitudeAt(v, f0 * sqrt(2.0))
    let b = amplitudeAt(v, f0 * sqrt(5.0))
    if a.isNaN and b.isNaN: 0.0
    elif a.isNaN: b
    elif b.isNaN: a
    else: min(a, b)

  let inAmp = amplitudeAt(vin, f0)
  let outAmp = amplitudeAt(vout, f0)
  let noise = noiseAt(vout) * snrOf(spec)
  result.add "in_ripple_v", inAmp, "V"
  result.add "out_ripple_v", outAmp, "V"
  result.add "psrr_db",
    verdictOf(result, inAmp, outAmp, floorOf(spec), inputNet, outputNet,
              noise), "dB"
