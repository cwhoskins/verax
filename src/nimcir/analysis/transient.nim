## What a node settles to, and what is still moving once it has.
##
## Every other simulation-backed analysis here binds a *driving part*:
## `analyzeStartup` wants a regulator to stand up as a soft-start ramp,
## `analyzeOpAmpResponse` wants an amplifier and an input to drive. That is
## the right shape when there is one, and it excludes a whole class of
## circuit. A charge pump has no regulator and no amplifier; an oscillator has
## no input; a switching converter modelled cycle-by-cycle has a rail that
## does not *settle* so much as arrive at a limit cycle. None of them can be
## asked the one question that would answer all three: **run this and tell me
## what this node does once it has stopped changing.**
##
## So nothing here binds a driving part. Each analysis takes a netlist and a
## net, runs a `.tran`, and reports what the net does over a stated window at
## the end of the run. There are two, because there are two shapes of answer:
## `analyzeTransient` reports where a node **settled** and what is still
## moving on it, and `analyzeOscillation` reports what a node is **running
## at** -- rate, size and purity -- for a circuit whose whole intent is not to
## settle. They share the run and differ only in what is read off the window.
##
## **The design is simulated as authored -- no isolation.** That follows
## `runDcVoltage`'s precedent rather than `analyzePdn`'s, and for the same
## reason: isolation terminates a cut rail with an ideal source at the rail's
## *nominal* voltage, which is precisely the number being measured. A rail
## reported back at the value the boundary was told to hold it at is a check
## that measures its own assumption and passes every time.
##
## **The window is the product.** `tSettle` is when the measurement starts,
## and it is stated rather than detected: what counts as settled is a
## judgement about the circuit -- a converter's output is settled in a
## hundred microseconds and a soft-started rail is not settled for five
## milliseconds -- and a detector that guessed wrong would silently report a
## start-up transient as ripple. Everything before `tSettle` is simulated and
## then not measured, because getting there is what the simulator has to do
## anyway.
##
## **Starting a circuit that will not start itself.** An oscillator's
## operating point is a balance it sits in forever, so a `.tran` from it
## reports a flat line -- a correct answer to a question nobody asked.
## `TransientSpec.initialConditions` emits an `.ic` card and forces `uic`,
## which puts the state somewhere the circuit has to move away from. The cost
## is declared as an assumption on every run that uses it: `uic` skips the
## operating-point solve, so every node *not* named starts at zero rather
## than at its bias.

import std/[math, strutils, tables]

import ../netlist/types
import ../netlist/graph
import ../netlist/formats/spice as spiceFormat
import ../spice/transform
import ../spice/flatten
import ../spice/models
import ../spice/ngspice
import ./measure
import ./report

export report

const
  KindNotSettled* = "transient_not_settled"
  KindDidNotOscillate* = "transient_did_not_oscillate"
  KindSimulationFailed* = "transient_simulation_failed"

type
  TransientSpec* = object
    tSettle*: float
      ## Seconds of simulated time before the measurement window opens.
      ## Everything before this is run and discarded.
    tWindow*: float
      ## Length of the measurement window, in seconds. `0` means "to the end
      ## of the run", which is what a plain settling question wants.
    tStop*: float
      ## `0` derives it as `tSettle + tWindow`, or as `tSettle * 1.2` when no
      ## window was stated.
    tStep*: float
      ## The `.tran` print step. `0` derives one from the window, since the
      ## window is what is actually measured and a step coarser than it makes
      ## the measurement out of thin air.
    tMax*: float
      ## Ceiling on the simulator's own timestep. `0` leaves it to ngspice.
      ##
      ## It matters for anything switching: between edges the interesting
      ## nodes are smooth, so truncation-error control takes long steps and
      ## the ripple is sampled at whatever the solver felt like. A model may
      ## force its own breakpoints -- `lt8640a_sw` does -- and this is the
      ## caller's half of the same argument, for a design where the caller
      ## knows the rate and the parts do not.
    settleTol*: float
      ## Fractional band around the window's mean that the whole window must
      ## sit inside for the node to count as settled. `0` disables the check.
    pinModels*: PinModelDefaults
    flattenHierarchy*: bool
    keepInstances*: seq[string]
    modelUnmodelledParts*: bool
    initialConditions*: OrderedTable[string, float]
      ## Node name -> volts, emitted as an `.ic` card and forcing `uic` on the
      ## `.tran`.
      ##
      ## **This is the only way to reach a circuit that will not start from
      ## its own operating point.** An oscillator's operating point is a
      ## balance it never leaves without a disturbance, and a `.tran` from
      ## that point reports a flat line -- a correct answer to a question
      ## nobody asked. `.ic` plus `uic` puts the state somewhere the circuit
      ## has to move away from.
      ##
      ## `uic` is not free and the trade is worth stating: it tells ngspice to
      ## skip the operating-point solve entirely, so *every* node not named
      ## here starts at zero rather than at its bias. State enough of them,
      ## or the run measures a circuit starting from somewhere it never is.
    capacitorParasitics*: bool
      ## Expand each capacitor into C + ESR + ESL before running. On by
      ## default, and load-bearing here rather than merely more accurate: an
      ## ideal capacitor has no ESR, and a switching converter's output ripple
      ## is mostly the inductor's current triangle across exactly that ESR.
      ## Left off, the ripple this reports is the capacitive term alone and is
      ## low by roughly the ratio of the two.

proc defaultTransientSpec*(): TransientSpec =
  TransientSpec(tSettle: 0.0, tWindow: 0.0, tStop: 0.0, tStep: 0.0,
                tMax: 0.0, settleTol: 0.0,
                pinModels: defaultPinModels(), flattenHierarchy: true,
                modelUnmodelledParts: true, capacitorParasitics: true)

proc windowOf(t: openArray[float], fromT: float): Slice[int] =
  ## The samples at or after `fromT`. Empty range when nothing qualifies,
  ## which the caller has to check -- a mean over no samples is `NaN` and
  ## `NaN` is what "the window fell outside the run" should report.
  var lo = t.len
  for i in 0 ..< t.len:
    if t[i] >= fromT:
      lo = i
      break
  lo .. t.high

type
  WindowRun = object
    ## What a `.tran` gave back, cut to the measurement window.
    ##
    ## The run is shared between `analyzeTransient` and `analyzeOscillation`
    ## because it genuinely is the same run: the same netlist, the same
    ## window, the same `uic`. Only what is read off it differs, and having
    ## the two questions diverge in the *simulator setup* as well as in the
    ## arithmetic is how one of them ends up quietly measuring a different
    ## circuit.
    t*, v*: seq[float]
    w*: Slice[int]
    ok*: bool

proc runWindow(nl: Netlist, measureNet: string, spec: TransientSpec,
               rep: var AnalysisReport, windowSamples = 1000): WindowRun =
  ## Simulates the design as authored and returns the window.
  ##
  ## Assumptions and issues go onto `rep` as they are produced, including on
  ## every failure path -- a run that could not happen still has to say what
  ## it invented on the way to finding that out.
  var cloneNets: OrderedTable[string, Net]
  # `materializeSimNetlist` with a purpose, not a bare `clone`: a part
  # carrying more than one model gets the one that answers *this* question,
  # and for a switching regulator that is the difference between a rail with
  # ripple on it and a rail whose model has no ripple in it to find.
  let work = materializeSimNetlist(nl, cloneNets, purpose = spSteadyState)
  discard flattenForSim(work, spec.flattenHierarchy, spec.keepInstances)
  if spec.modelUnmodelledParts:
    rep.assumptions.add expandPinModels(work, spec.pinModels)
  if spec.capacitorParasitics:
    rep.assumptions.add expandCapacitorParasitics(work)

  let measured = findNet(work, measureNet)
  if measured == nil:
    raise newException(NetlistError,
      "no such net: " & measureNet & " (transient)")

  let tWindow =
    if spec.tWindow > 0.0: spec.tWindow
    elif spec.tSettle > 0.0: spec.tSettle * 0.2
    else: 0.0
  let tStop =
    if spec.tStop > 0.0: spec.tStop
    else: spec.tSettle + (if tWindow > 0.0: tWindow else: 1.0e-3)
  # The print step is sized from the *window*, not the run: a step chosen for
  # a five-millisecond run puts a handful of samples inside a twenty-
  # microsecond window, and a peak-to-peak over a handful of samples is a
  # number about the sampling rather than about the circuit. A thousand
  # samples across the window is deliberately generous -- peak-to-peak reads
  # extremes, which is exactly the statistic that undersampling shortens, and
  # on the LT8640A's 20-cycle window 400 samples read 6.94 mV where 1000
  # read 7.12.
  #
  # **It is not only a print step, and that is why `windowSamples` is a
  # parameter rather than a constant.** ngspice defaults its own maximum
  # internal timestep to the print step, so this figure sets how accurately
  # the circuit is *solved* and not merely how often the answer is written
  # down. A peak-to-peak barely notices; anything phase-sensitive does.
  # Measured on `designs/wien_osc.nim`, whose window is 31 periods long: at
  # a thousand samples the oscillation reads 1568.4 Hz, at ten thousand it
  # reads 1573.26 Hz and at a hundred thousand 1573.31 -- so the default
  # would have been wrong by 0.31%, three times the band that design's claim
  # is worth stating at, and wrong in a way that looks like a circuit
  # measurement rather than like a setting.
  let tStep =
    if spec.tStep > 0.0: spec.tStep
    elif tWindow > 0.0: tWindow / float(max(1, windowSamples))
    else: tStop / float(2 * max(1, windowSamples))

  var card = ".tran " & spiceValue(tStep) & " " & spiceValue(tStop)
  # `tstart` is the fourth field and needs the third, so both are written
  # whenever either is. ngspice still *simulates* from zero -- tstart only
  # says from when to keep the output, which is exactly the distinction this
  # analysis is built on.
  if spec.tSettle > 0.0 or spec.tMax > 0.0:
    card &= " " & spiceValue(max(0.0, spec.tSettle))
    if spec.tMax > 0.0:
      card &= " " & spiceValue(spec.tMax)

  var setup: seq[string]
  if spec.initialConditions.len > 0:
    var terms: seq[string]
    for node, v in spec.initialConditions:
      terms.add "v(" & node & ")=" & spiceValue(v)
    setup.add ".ic " & terms.join(" ")
    # `uic` is what makes the .ic the starting state rather than a hint to
    # the operating-point solver.
    card &= " uic"
    rep.assumptions.add note(
      "the run starts from stated initial conditions (" & terms.join(", ") &
      ") with uic, so no operating point was solved and every other node " &
      "starts at zero rather than at its bias")

  try:
    rep.raw = run(work, card, setup)
  except SpiceSimError as e:
    rep.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not run the transient: " & e.msg)
    return

  result.t = rep.raw["time"]
  result.v = rep.raw["v(" & measured.name & ")"]
  if result.t.len == 0 or result.v.len == 0:
    rep.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the transient produced no samples for net '" & measureNet & "'")
    return

  # `tstart` is honoured by ngspice, but a deck that stated none still has the
  # whole run in the output, so the window is applied here too. Doing it in
  # both places is not redundancy: one of them controls how much data crosses
  # the process boundary and the other controls what is measured.
  result.w = windowOf(result.t, spec.tSettle)
  if result.w.a > result.w.b:
    rep.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the measurement window opens at " & eng(spec.tSettle, "s") &
      " but the run ended at " & eng(result.t[^1], "s") & " -- nothing was measured")
    return
  result.ok = true

proc slice(r: WindowRun): tuple[t, v: seq[float]] =
  ## The window as two plain seqs, which is what `analysis/measure` takes.
  for i in r.w:
    result.t.add r.t[i]
    result.v.add r.v[i]

proc analyzeTransient*(nl: Netlist, measureNet: string,
                       spec = defaultTransientSpec()): AnalysisReport =
  ## Runs the design and reports what `measureNet` **settled to**.
  ##
  ## Measurements: `settled_v` (the window mean), `ripple_pp` (its
  ## peak-to-peak), `settled_min`, `settled_max` and `final_v`.
  result.name = "transient"

  let r = runWindow(nl, measureNet, spec, result)
  if not r.ok: return

  var lo = r.v[r.w.a]
  var hi = r.v[r.w.a]
  var sum = 0.0
  for i in r.w:
    if r.v[i] < lo: lo = r.v[i]
    if r.v[i] > hi: hi = r.v[i]
    sum += r.v[i]
  let mean = sum / float(r.w.b - r.w.a + 1)

  result.add "settled_v", mean, "V"
  result.add "ripple_pp", hi - lo, "V"
  result.add "settled_min", lo, "V"
  result.add "settled_max", hi, "V"
  result.add "final_v", r.v[^1], "V"

  if spec.settleTol > 0.0 and abs(mean) > 0.0:
    let band = abs(mean) * spec.settleTol
    if hi - lo > 2.0 * band:
      result.issues.add newIssue(KindNotSettled, sevWarning,
        "'" & measureNet & "' moves " & eng(hi - lo, "V") & " peak-to-peak over the " &
        "window from " & eng(spec.tSettle, "s") & ", which is wider than the " &
        eng(spec.settleTol * 100.0) & "% band around its mean of " &
        eng(mean, "V") & " -- either it has not settled yet, or what is left " &
        "is larger than the claim allows for", net = nl.nets.getOrDefault(measureNet))

proc analyzeOscillation*(nl: Netlist, measureNet: string,
                         spec = defaultTransientSpec()): AnalysisReport =
  ## Runs the design and reports what `measureNet` is **running at**.
  ##
  ## Measurements: `osc_freq` (Hz), `swing_pp` (V peak-to-peak) and
  ## `osc_thd_pct` (%). Those three are how an oscillator is specified, and
  ## every one of them is a `.tran` quantity: an oscillator has no transfer
  ## function to sweep, because there is nothing to sweep it *from*.
  ##
  ## **Why this is not `analyzeOpAmpResponse` with a different reading.** The
  ## `.ac` family measures by hanging an ideal source on the stage's input
  ## net, and an ideal source *holds* that node. A Wien bridge returns its
  ## positive feedback straight to `IN+`, so driving there shorts the bridge
  ## out of the circuit and the tool reports the forward path's bandwidth for
  ## a circuit that does everything it does at 1.59 kHz --
  ## `opamp.checkInjectionPoint` now refuses it by name. There is no version
  ## of a swept measurement that answers this. The circuit has to be run.
  ##
  ## **The window is the product, as it is for `analyzeTransient`, and here
  ## it is doing more work.** `osc_thd_pct` integrates over whole periods of
  ## `osc_freq`, so a window that still has start-up envelope in it reports
  ## the envelope as distortion. `tSettle` states when the circuit is up; the
  ## amplitude-stabilising network is usually what sets it, and it is slow --
  ## a diode-clamped Wien bridge takes tens of milliseconds to find its
  ## level, against a period of well under one.
  ##
  ## Almost every circuit worth pointing this at needs
  ## `TransientSpec.initialConditions` to start at all.
  result.name = "oscillation"

  # Ten times the sample density `analyzeTransient` derives, and the reason
  # is in `runWindow`: the derived print step is also ngspice's ceiling on
  # its own timestep, so it sets how accurately the circuit is solved. Every
  # quantity here is phase-sensitive -- a frequency directly, and a
  # distortion figure through the window it integrates over -- where a
  # settling voltage and a ripple are not. The cost on `wien_osc` is 0.42 s
  # against 0.06 s, for a frequency that stops moving with the setting.
  let r = runWindow(nl, measureNet, spec, result, windowSamples = 10_000)
  if not r.ok: return
  let (wt, wv) = r.slice()

  let sw = swing(wv)
  result.add "swing_pp", sw.pp, "V"

  # Frequency first, because the distortion figure is measured *at* it: a
  # Fourier integral over the wrong period leaks the fundamental into every
  # harmonic bin, and a leaked fundamental reads as distortion the circuit
  # does not have.
  let f0 = fundamentalFreq(wt, wv)
  result.add "osc_freq", f0, "Hz"
  result.add "osc_thd_pct", thd(wt, wv, f0) * 100.0, "%"

  if f0.isNaN:
    # `NaN` reads as *notEvaluated* downstream rather than as a failure, so
    # the reason has to be said here or the reader is told only that nothing
    # came back. Two distinguishable causes, and the fix differs.
    let flat = sw.pp <= 1.0e-9
    result.issues.add newIssue(KindDidNotOscillate, sevWarning,
      "no repeated crossing of the mean was found on '" & measureNet &
      "' in the window from " & eng(spec.tSettle, "s") & ", so there is no " &
      "frequency to report" &
      (if flat:
         " -- the node moved " & eng(sw.pp, "V") & " over the whole window, " &
         "which is a circuit sitting at its operating point. An oscillator " &
         "starts from a disturbance; state one in " &
         "TransientSpec.initialConditions."
       else:
         " -- the node is moving " & eng(sw.pp, "V") & " but not periodically " &
         "within this window, so it is still starting up, has stopped, or " &
         "the window is shorter than a period. Widen tSettle or tWindow."),
      net = nl.nets.getOrDefault(measureNet))
