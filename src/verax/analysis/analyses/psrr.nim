## How much of the supply's ripple reaches the rail.
##
## ## Two methods
##
## `analyzePsrrAc` sweeps a small AC ripple across a band in one run --
## cheap, and right for anything `.ac` can linearise (linear regulators,
## LDOs, passive filters).
##
## `analyzePsrrTone` runs a `.tran` with one real sinusoid and extracts the
## amplitude at that frequency at both ends. One run per frequency, but it
## reaches what `.ac` can't: switching converters, XSPICE models without
## `AC_GAIN`, and ripple large enough that the answer depends on its size.
##
## Neither falls back to the other; the quantity names differ.
##
## ## Where the ripple goes in
##
## In series with the supply (its pin moved to a fresh net), never by
## editing its `value` string, which may be any SPICE source spec. It goes
## in **before** the supply's output impedance, so board wiring and input
## caps filter it as they would in reality.
##
## ## Input ripple is measured, never assumed
##
## Rejection is quoted between measured `in_ripple_v` and `out_ripple_v`, so
## an input filter's attenuation isn't credited to the regulator.
##
## ## The no-feedthrough guard
##
## An ideal-source regulator stand-in (or any model whose output ignores its
## input) has infinite rejection. Output ripple at the noise floor with real
## input ripple is therefore `NaN` plus `KindNoFeedthrough`, never a number.
##
## **No isolation**: a rail terminated at its nominal can't ripple.

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
    ## No measurable output ripple while the input had some -- almost always
    ## a model with no input-to-output path.
  KindNoRipple* = "psrr_no_input_ripple"
    ## No measurable *input* ripple: the injection never reached the node.

const
  ripplePrefix = "VPSRRIN"
  defaultFloor = 1.0e-9
    ## Volts. Below this a result is solver residue (~180 dB down on 1 V).

type
  PsrrSpec* = object
    fStart*, fStop*: float
      ## The swept band, for `analyzePsrrAc`. 0 takes 10 Hz to 10 MHz.
    ptsPerDecade*: int
      ## 0 takes 20.
    atF*: float
      ## Where `psrr_at_f` is read; 0 omits it. `NaN` outside the band.
    rippleF*: float
      ## The tone for `analyzePsrrTone`; 0 takes 120 Hz (rectified mains, the
      ## datasheet frequency).
    rippleV*: float
      ## Zero-to-peak volts; 0 takes 100 mV. Unlike `.ac`, the level matters
      ## (it can move a converter's duty cycle or push toward dropout).
    tSettle*: float
      ## When the measurement window opens.
    periods*: int
      ## Whole periods of `rippleF` in the window; 0 takes 8. Whole, or the
      ## tone leaks into other bins.
    samplesPerPeriod*: int
      ## 0 takes 200. Also caps ngspice's timestep, so it sets solve accuracy.
    floorV*: float
      ## Output amplitude below this is no signal; 0 takes 1 nV. Enough for
      ## `.ac` (unreached nodes read exactly zero); the tone method also needs
      ## `snrMargin`.
    snrMargin*: float
      ## How far above the run's numerical residue (`noiseAt`) an output must
      ## sit for the tone method to believe it; 0 takes 2 (6 dB). Without it an
      ## ideal-source rail reads ~100 dB of fictional rejection.
    pinModels*: PinModelDefaults
    parasitics*: ParasiticDefaults
    sourceZ*: SourceDefaults
    flattenHierarchy*: bool
    keepInstances*: seq[string]
    modelUnmodelledParts*: bool
    capacitorParasitics*: bool
    modelSources*: bool
      ## Put the supply's output impedance in series. **Off by default here**:
      ## both nodes are measured, so upstream impedance only changes how much
      ## ripple arrives; and the invented default (10 mohm + 1 uH) can
      ## resonate undamped with a converter's input caps and stop the run
      ## converging.

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
  ## The purpose differs by method: `.ac` wants `spSmallSignal`; a tone wants
  ## the steady-state model (on a converter, the switching one).
  # Clone, flatten, *then* `simReplace` (not `materializeSimNetlist`), so a
  # nested XSPICE component's ports use post-flatten net names.
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
  ## The supply's board-facing pin (the one not on ground), found by net
  ## because `expandSourceImpedance` may have moved `+` internally.
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
  ## Splits the supply off its net and inserts a ripple source; returns its
  ## designator (for the assumption text).
  var desig = ripplePrefix
  var n = 0
  while work.components.hasKey(desig):
    inc n
    desig = ripplePrefix & $n
  let probe = addCurrentProbe(work, supplyPin(work, source), desig)
  probe.source.attrs["value"] = value
  # An ideal series source: the default impedance would sit between the
  # ripple and the supply.
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
  ## The ratio in dB, or `NaN` with the issue saying why. `noise` is the
  ## reading at undriven frequencies; zero means only the absolute floor
  ## applies.
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
  ## Supply rejection across a band from one `.ac` sweep: `psrr_min_db` (the
  ## worst point -- what a rail is designed to), `f_psrr_min`, and
  ## `psrr_at_f` when `spec.atF` is set. Drive is 1 V (linear analysis;
  ## level-dependent questions want `analyzePsrrTone`).
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

  # The worst point is usually mid-band (loop gain rolled off, output cap not
  # yet dominant), not at either end.
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
  # `verdictOf` writes the issue and returns the NaN.
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
  ## Supply rejection at one frequency from a `.tran` with a real sinusoid:
  ## `psrr_db`, `in_ripple_v`, `out_ripple_v`, extracted at exactly the
  ## injected frequency by `harmonicAmplitudes`. Essential for converters,
  ## whose own switching ripple would swamp a peak-to-peak reading.
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
    ## The run's residue at undriven frequencies -- the floor the tone must
    ## beat. A `.tran` doesn't answer zero for an unreached node; it leaves a
    ## timestep artefact that looks like a measurement. Probed at two
    ## irrational multiples of the tone (avoiding harmonics), taking the
    ## **smaller** so a real signal on one probe can't inflate the floor.
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
