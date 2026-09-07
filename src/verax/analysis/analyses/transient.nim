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
## So nothing here binds a driving part. Each analysis runs a `.tran` and
## reports what was happening over a stated window at the end of it. There are
## three, because there are three shapes of answer: `analyzeTransient` reports
## where a node **settled** and what is still moving on it,
## `analyzeOscillation` reports what a node is **running at** -- rate, size and
## purity -- for a circuit whose whole intent is not to settle, and
## `analyzeCurrent` reports what is flowing **through a part**, which is the
## one question in this library that is not about a node at all. They share
## the run and differ only in what is read off the window.
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

import ../../netlist/types
import ../../netlist/graph
import ../../netlist/formats/spice as spiceFormat
import ../../spice/transform
import ../../spice/flatten
import ../../spice/models
import ../../spice/ngspice
import ../measure
import ../report

export report

const
  KindNotSettled* = "transient_not_settled"
  KindDidNotOscillate* = "transient_did_not_oscillate"
  KindSimulationFailed* = "transient_simulation_failed"
  KindNoCurrent* = "transient_no_current"
  KindOverCurrent* = "part_over_current_rating"
  KindStepNotSeen* = "load_step_not_seen"
  KindStepNoRecovery* = "load_step_no_recovery"

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
  ProbeKind = enum
    pkVoltage    ## a node voltage, `v(<net>)`
    pkCurrent    ## the current through one part, `i(<desig>)` or `i(@<desig>[i])`

  Probe = object
    ## What to read off the run, named the way the *design* names it -- a net
    ## name or a designator, hierarchical path and all. Resolving it to a
    ## rawfile vector has to wait until the work netlist has been
    ## materialized, flattened and model-substituted, because that is when the
    ## part that reaches the deck exists and knows its deck designator.
    kind: ProbeKind
    target: string

  ProbeResult = object
    vector*: string
      ## The rawfile vector this probe resolved to; empty when it could not.
    saveTerm*: string
      ## What has to be named in a `.save` for that vector to exist at all.
      ## Empty when ngspice writes it anyway -- see `branchCurrentVector`.
    values*: seq[float]
      ## The whole run, not the window -- `WindowRun.w` cuts it.
    reason*: string
      ## Why `values` is empty. A voltage probe never gets one (a missing net
      ## raises), a current probe can: a three-terminal device, an `X`
      ## instance, an XSPICE model.

  WindowRun = object
    ## What a `.tran` gave back, cut to the measurement window.
    ##
    ## The run is shared between `analyzeTransient`, `analyzeOscillation` and
    ## `analyzeCurrent` because it genuinely is the same run: the same
    ## netlist, the same window, the same `uic`. Only what is read off it
    ## differs, and having the questions diverge in the *simulator setup* as
    ## well as in the arithmetic is how one of them ends up quietly measuring
    ## a different circuit.
    ##
    ## **More than one probe per run, and that is what makes a current claim
    ## affordable.** A converter is claimed on its inductor's peak *and* its
    ## input capacitor's RMS, and both are the same `.tran` over the same
    ## window; one probe per run would simulate a switching model twice at
    ## fifty timepoints a cycle to answer two readings of one waveform set.
    t*: seq[float]
    probes*: seq[ProbeResult]
    w*: Slice[int]
    ok*: bool

proc resolveProbe(work: Netlist, p: Probe): ProbeResult =
  ## Which rawfile vector answers this probe, against the netlist that will
  ## actually be written to the deck.
  ##
  ## **The two kinds fail differently on purpose.** A voltage probe names the
  ## one net the whole analysis is about, so a name that resolves to nothing
  ## raises: there is no partial answer to give. A current probe is one of
  ## several in a batch, and a part that cannot be measured must not take the
  ## rest of the batch with it -- so it comes back with a `reason` and the
  ## other parts are measured anyway.
  case p.kind
  of pkVoltage:
    let n = findNet(work, p.target)
    if n == nil:
      raise newException(NetlistError,
        "no such net: " & p.target & " (transient)")
    ProbeResult(vector: "v(" & n.name & ")")
  of pkCurrent:
    let c = findComponent(work, p.target)
    if c == nil:
      # Not necessarily a typo: a part the design really has can be gone by
      # now, because the netlist reaching the deck is a materialized,
      # flattened, model-substituted copy. An op-amp becomes a macromodel and
      # a ferrite bead becomes three elements, and neither leaves a device
      # carrying the original designator's current.
      return ProbeResult(reason:
        "'" & p.target & "' is not in the netlist that reaches the deck; a " &
        "model pass stood it in for, or dissolved it into, something else")
    let (vector, saveTerm, reason) =
      branchCurrentVector(spiceFormat.deckDesignator(c))
    ProbeResult(vector: vector, saveTerm: saveTerm, reason: reason)

proc runWindow(nl: Netlist, probes: openArray[Probe], spec: TransientSpec,
               rep: var AnalysisReport, windowSamples = 1000,
               label = "",
               mutate: proc (work: Netlist) {.closure.} = nil): WindowRun =
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

  # Anything an analysis has to *add* to the circuit before it runs -- a
  # pulsed load, a ripple source -- goes in here, after every model pass and
  # before the probes resolve. After, because a stimulus is not a part of the
  # design and must not be handed to `expandPinModels`; before, because a
  # probe on the thing just added has to find it.
  if mutate != nil: mutate(work)

  for p in probes:
    result.probes.add resolveProbe(work, p)

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

  # A terminal current is computed from the solution rather than being part of
  # it, so it never reaches the rawfile unless it is named. `all` has to lead
  # the list for the reason `saveCurrentsCard` states: naming any vector turns
  # the default set off, and a card saying only `@l1[i]` would keep the
  # inductor's current and throw the rail it feeds away.
  var saveTerms: seq[string]
  for pr in result.probes:
    if pr.saveTerm.len > 0 and pr.saveTerm notin saveTerms:
      saveTerms.add pr.saveTerm
  if saveTerms.len > 0:
    setup.add ".save " & (@["all"] & saveTerms).join(" ")

  let runLabel =
    if label.len > 0: label
    elif probes.len > 0: "transient:" & probes[0].target
    else: "transient"
  try:
    rep.raw = run(work, card, setup, label = runLabel)
  except SpiceSimError as e:
    rep.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not run the transient: " & e.msg)
    return

  result.t = rep.raw["time"]
  if result.t.len == 0:
    rep.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the transient produced no samples")
    return

  for i in 0 ..< result.probes.len:
    if result.probes[i].vector.len == 0: continue
    try:
      result.probes[i].values = rep.raw[result.probes[i].vector]
    except KeyError:
      # The vector was asked for and did not come back. That is a statement
      # about the deck rather than about the circuit, so it says which vector
      # rather than reporting an empty measurement.
      result.probes[i].reason =
        "the run produced no vector '" & result.probes[i].vector & "'"
    if result.probes[i].values.len == 0 and result.probes[i].reason.len == 0:
      result.probes[i].reason =
        "the run produced no samples for '" & result.probes[i].vector & "'"

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

proc slice(r: WindowRun, i = 0): tuple[t, v: seq[float]] =
  ## Probe `i`'s window as two plain seqs, which is what `analysis/measure`
  ## takes.
  for k in r.w:
    result.t.add r.t[k]
    result.v.add r.probes[i].values[k]

proc measured(r: WindowRun, i: int, rep: var AnalysisReport,
              what: string): bool =
  ## Whether probe `i` came back with samples, reporting why not if it did
  ## not. `runWindow` succeeds as long as the *run* did, because a batch of
  ## current probes may have one part in it that cannot be measured -- so a
  ## single-probe analysis has to ask about its own probe before reading it.
  if r.probes[i].values.len > 0: return true
  rep.issues.add newIssue(KindSimulationFailed, sevWarning,
    "the transient measured nothing for " & what &
    (if r.probes[i].reason.len > 0: ": " & r.probes[i].reason else: ""))
  false

proc analyzeTransient*(nl: Netlist, measureNet: string,
                       spec = defaultTransientSpec()): AnalysisReport =
  ## Runs the design and reports what `measureNet` **settled to**.
  ##
  ## Measurements: `settled_v` (the window mean), `ripple_pp` (its
  ## peak-to-peak), `settled_min`, `settled_max` and `final_v`.
  result.name = "transient"

  let r = runWindow(nl, [Probe(kind: pkVoltage, target: measureNet)],
                    spec, result)
  if not r.ok: return
  if not measured(r, 0, result, "net '" & measureNet & "'"): return
  let v = r.probes[0].values

  var lo = v[r.w.a]
  var hi = v[r.w.a]
  var sum = 0.0
  for i in r.w:
    if v[i] < lo: lo = v[i]
    if v[i] > hi: hi = v[i]
    sum += v[i]
  let mean = sum / float(r.w.b - r.w.a + 1)

  result.add "settled_v", mean, "V"
  result.add "ripple_pp", hi - lo, "V"
  result.add "settled_min", lo, "V"
  result.add "settled_max", hi, "V"
  result.add "final_v", v[^1], "V"

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
  let r = runWindow(nl, [Probe(kind: pkVoltage, target: measureNet)],
                    spec, result, windowSamples = 10_000)
  if not r.ok: return
  if not measured(r, 0, result, "net '" & measureNet & "'"): return
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

proc analyzeCurrent*(nl: Netlist, parts: openArray[string],
                     spec = defaultTransientSpec()): AnalysisReport =
  ## Runs the design once and reports the current **through each part** over
  ## the settled window.
  ##
  ## Measurements, per part and tagged with its designator in
  ## `Measurement.at`: `i_peak`, `i_rms`, `i_avg`, `i_pp`, `i_min`, `i_max`,
  ## plus `i_peak_derating` and `i_rms_derating` when the part states a rating
  ## to be a fraction of.
  ##
  ## **This is the analysis `current_rating` and `isat` were waiting for.**
  ## Both keys have been registered and set by the part policy since the
  ## policy existed, and nothing read either: a branch current is not in a
  ## `.op` for anything but a voltage source, so an inductor's peak -- the
  ## check a converter most wants, since saturation is its failure mode --
  ## had no route to a claim. It is a `.tran` question, and this is the same
  ## `.tran` `analyzeTransient` already runs for the rail's ripple.
  ##
  ## **The three figures a rating is quoted against are magnitudes, because a
  ## rating is.** `i_peak`, `i_rms` and `i_avg` are all sign-free. The sign of
  ## a branch current is a *deck* convention and no claim should turn on it:
  ## an inductor's follows whichever pin the design happened to write first,
  ## and ngspice reports a voltage source's current positive when it flows
  ## *into* the + terminal, so a supply delivering 330 mA reads -330 mA. What
  ## the sign does carry is the waveform's shape, and `i_min`/`i_max` keep
  ## that -- a current that changes direction has `i_min < 0 < i_max`, which
  ## no magnitude shows.
  ##
  ## **Every part is read off one run.** A converter is claimed on its
  ## inductor's peak and its input capacitor's RMS at once, and those are two
  ## readings of one set of waveforms; one run per part would simulate a
  ## switching model twice over.
  result.name = "current"
  # Nothing to read means nothing to run: a `.tran` costs whatever the design
  # costs, and there would be no measurement at the end of it.
  if parts.len == 0: return

  var probes: seq[Probe]
  for p in parts: probes.add Probe(kind: pkCurrent, target: p)

  let r = runWindow(nl, probes, spec, result,
                    label = "current:" & (if parts.len > 0: parts[0] else: ""))
  if not r.ok: return

  for i, part in parts:
    if r.probes[i].values.len == 0:
      # Named, run, and still nothing to measure. Which part it was and why
      # has to be said here: downstream this is one `notEvaluated` among
      # several from the same batch, and "no measurement" without a subject
      # sends the reader to the wrong part.
      result.issues.add newIssue(KindNoCurrent, sevWarning,
        "no current could be measured through '" & part & "': " &
        (if r.probes[i].reason.len > 0: r.probes[i].reason
         else: "the probe resolved to nothing"),
        components = (block:
          let c = findComponent(nl, part)
          if c == nil: @[] else: @[c]))
      continue

    let (wt, wv) = r.slice(i)
    let sw = swing(wv)
    let peak = max(abs(sw.lo), abs(sw.hi))
    let rms = timeRms(wt, wv)
    let avg = abs(timeMean(wt, wv))

    result.add "i_peak", peak, "A", at = part
    result.add "i_rms", rms, "A", at = part
    result.add "i_avg", avg, "A", at = part
    result.add "i_pp", sw.pp, "A", at = part
    result.add "i_min", sw.lo, "A", at = part
    result.add "i_max", sw.hi, "A", at = part

    # The part's own ratings, finally read. `NaN` where the part states none,
    # which reads downstream as *not evaluated* rather than as a pass -- a
    # part with no `isat` on it is one nobody has chosen yet, not one with
    # infinite headroom.
    let c = findComponent(nl, part)
    let isat = if c == nil: AnnValue[float](source: annAbsent)
               else: annotationFloat(c, "isat")
    let icont = if c == nil: AnnValue[float](source: annAbsent)
                else: annotationFloat(c, "current_rating")
    result.add "i_peak_derating",
      (if isat.has and isat.value > 0.0: peak / isat.value else: NaN),
      "", at = part
    result.add "i_rms_derating",
      (if icont.has and icont.value > 0.0: rms / icont.value else: NaN),
      "", at = part

    if isat.has and isat.value > 0.0 and peak > isat.value:
      result.issues.add newIssue(KindOverCurrent, sevError,
        "'" & part & "' peaks at " & eng(peak, "A") & " against a stated " &
        "saturation current of " & eng(isat.value, "A") & " -- past it the " &
        "inductance collapses, so the ripple this run measured is not the " &
        "ripple the part would produce",
        components = (if c == nil: @[] else: @[c]))
    elif icont.has and icont.value > 0.0 and rms > icont.value:
      result.issues.add newIssue(KindOverCurrent, sevWarning,
        "'" & part & "' carries " & eng(rms, "A") & " RMS against a stated " &
        "continuous rating of " & eng(icont.value, "A"),
        components = (if c == nil: @[] else: @[c]))

# --- a load step ------------------------------------------------------------

const loadStepDesignator = "ILOADSTEP"

type
  LoadStepSpec* = object
    ## A current step at a node, and the window either side of it.
    iFrom*, iTo*: float
      ## The load before and after the edge, in amps. `iTo > iFrom` is the
      ## ordinary direction -- a part waking up -- and the reverse is legal
      ## and measures the release instead.
    tSettle*: float
      ## When the circuit has arrived and the baseline may be read. Stated,
      ## not detected, for the reason every window here is: a rail still
      ## soft-starting is not a rail whose droop means anything.
    tBaseline*: float
      ## How long to average before the edge for the pre-step level. 0 takes
      ## a tenth of `tSettle`, or `tRecover` when there is no settle time.
    tEdge*: float
      ## Rise and fall time of the step. 0 takes 1 us. **Not cosmetic**: a
      ## load's slew is what decides whether the droop is set by the output
      ## capacitor's ESR or by the loop's bandwidth, and an unrealistically
      ## fast edge asks the decoupling for something no real load demands.
    tHold*: float
      ## How long the load stays at `iTo` before returning to `iFrom`.
      ## 0 holds to the end of the run and never measures a release.
    tRecover*: float
      ## How long after each edge to watch. 0 takes ten times `tEdge`.
    settleTol*: float
      ## Fractional band the rail must re-enter and stay inside for
      ## `step_recover_s` to be a number. 0 takes 1%.
    pinModels*: PinModelDefaults
    flattenHierarchy*: bool
    keepInstances*: seq[string]
    modelUnmodelledParts*: bool
    capacitorParasitics*: bool
    windowSamples*: int
      ## Points across the *recovery* window. 0 takes 2000. A droop is an
      ## excursion between two samples if the sampling is coarse, so this is
      ## higher than `analyzeTransient`'s default and lower than
      ## `analyzeOscillation`'s -- and, as there, the derived print step is
      ## also ngspice's ceiling on its own timestep, so it sets how well the
      ## edge is *solved* and not merely how often it is written down.

proc defaultLoadStepSpec*(): LoadStepSpec =
  LoadStepSpec(iFrom: 0.0, iTo: 0.0, tSettle: 0.0, tBaseline: 0.0,
               tEdge: 0.0, tHold: 0.0, tRecover: 0.0, settleTol: 0.0,
               pinModels: defaultPinModels(), flattenHierarchy: true,
               modelUnmodelledParts: true, capacitorParasitics: true,
               windowSamples: 0)

proc edgeOf*(spec: LoadStepSpec): float =
  ## The step's rise and fall time, with the default resolved. Exported
  ## because a report has to be able to say what a claim that stated no edge
  ## actually ran with.
  if spec.tEdge > 0.0: spec.tEdge else: 1.0e-6

proc recoverOf*(spec: LoadStepSpec): float =
  ## How long is watched after each edge, with the default resolved.
  if spec.tRecover > 0.0: spec.tRecover else: 10.0 * edgeOf(spec)

proc baselineOf*(spec: LoadStepSpec): float =
  ## How long is averaged before the edge for the pre-step level.
  if spec.tBaseline > 0.0: spec.tBaseline
  elif spec.tSettle > 0.0: spec.tSettle * 0.1
  else: recoverOf(spec)

proc holdOf*(spec: LoadStepSpec): float =
  ## How long the load stays applied.
  if spec.tHold > 0.0: spec.tHold else: recoverOf(spec)

proc stopOf(spec: LoadStepSpec): float =
  ## The step lands at `tSettle`; everything after it is the measurement.
  spec.tSettle + holdOf(spec) + recoverOf(spec) + 2.0 * edgeOf(spec)

proc pulseValue(spec: LoadStepSpec): string =
  ## `PULSE(i1 i2 td tr tf pw per)`. The period is set past the end of the
  ## run so the pulse happens exactly once: this measures one step, and a
  ## second edge arriving inside the recovery window would be measured as
  ## part of the first one's ringing.
  let e = edgeOf(spec)
  let stop = stopOf(spec)
  "PULSE(" & spiceValue(spec.iFrom) & " " & spiceValue(spec.iTo) & " " &
  spiceValue(spec.tSettle) & " " & spiceValue(e) & " " & spiceValue(e) & " " &
  spiceValue(holdOf(spec)) & " " & spiceValue(10.0 * stop) & ")"

proc toTransient(spec: LoadStepSpec): TransientSpec =
  ## The run is described to `runWindow` as one whose window opens at the
  ## *baseline*, not at the step: the pre-step level is measured data, not an
  ## assumption, so it has to be inside what comes back.
  result = defaultTransientSpec()
  result.tSettle = max(0.0, spec.tSettle - baselineOf(spec))
  result.tWindow = stopOf(spec) - result.tSettle
  result.tStop = stopOf(spec)
  result.tStep = recoverOf(spec) /
                 float(max(1, (if spec.windowSamples > 0: spec.windowSamples
                               else: 2000)))
  result.pinModels = spec.pinModels
  result.flattenHierarchy = spec.flattenHierarchy
  result.keepInstances = spec.keepInstances
  result.modelUnmodelledParts = spec.modelUnmodelledParts
  result.capacitorParasitics = spec.capacitorParasitics

proc sliceBetween(t, v: openArray[float], fromT, toT: float):
    tuple[t, v: seq[float]] =
  for i in 0 ..< t.len:
    if t[i] >= fromT and t[i] <= toT:
      result.t.add t[i]
      result.v.add v[i]

proc analyzeLoadStep*(nl: Netlist, measureNet: string,
                      spec = defaultLoadStepSpec()): AnalysisReport =
  ## What a rail does when the load jumps, and how long it takes to get over
  ## it.
  ##
  ## **The time-domain twin of a target impedance, and the thing a target
  ## impedance is a proxy for.** `analyzePdn` answers "how low is this rail's
  ## impedance across the band", which is a real question and an indirect
  ## one: what the board actually has to do is hold the rail up when the MCU
  ## wakes, and getting from an impedance curve to that answer is an argument
  ## the reader has to complete. This asks it directly.
  ##
  ## The stimulus is a **constant-current sink the analysis injects**, pulsed,
  ## and both halves of that are deliberate. Injected, because a test load is
  ## not a part anybody solders -- putting one in the design would put it on
  ## the BoM and in the layout, which is the same argument `analyzeLoadSweep`
  ## makes for its own sink. A sink and not a resistor, because a resistor's
  ## current follows the rail: it would *damp* the very network being
  ## measured, and a droop measured against one is smaller than the real
  ## thing by however much the rail sagged. `spice/boundary` measured that
  ## difference at 12% on an anti-resonant peak, and a droop is the same
  ## effect in the time domain.
  ##
  ## **The design is simulated as authored -- no isolation**, on
  ## `analyzeTransient`'s reasoning: a rail terminated at its nominal by a
  ## boundary source cannot droop.
  ##
  ## Capacitor parasitics are on and load-bearing rather than merely more
  ## accurate. The first thing a step does is pull its current through the
  ## output capacitor's ESR, and that step is instantaneous and is often most
  ## of the droop; an ideal capacitor has no ESR and reports a droop that
  ## rises smoothly from zero, which is the wrong shape and the wrong number.
  ##
  ## Reports `step_droop_v`/`step_droop_pct` (how far the rail fell below
  ## where it was), `step_overshoot_v`/`step_overshoot_pct` (how far it rose
  ## above on the release), `step_recover_s`, and the signed envelope
  ## `step_v_min`/`step_v_max`. Anything the run could not see is `NaN` with
  ## an issue, never zero: a droop of zero and a droop nobody measured are
  ## opposite conclusions.
  result.name = "load step"

  if spec.iTo == spec.iFrom:
    result.issues.add newIssue(KindStepNotSeen, sevWarning,
      "a load step from " & eng(spec.iFrom, "A") & " to " &
      eng(spec.iTo, "A") & " is not a step. Every quantity here is a " &
      "difference across the edge, so there is no default magnitude to " &
      "assume and nothing to measure at this one")
    return

  let tSpec = toTransient(spec)
  let sink = spec           # captured by the closure below

  var injected = false
  let r = runWindow(nl, [Probe(kind: pkVoltage, target: measureNet)],
                    tSpec, result, label = "load step:" & measureNet,
                    mutate = proc (work: Netlist) =
      let node = findNet(work, measureNet)
      if node == nil:
        raise newException(NetlistError,
          "no such net: " & measureNet & " (load step)")
      let gnd = findNet(work, "0")
      if gnd == nil:
        raise newException(NetlistError,
          "no ground node '0' to pull a load step into on '" & measureNet &
          "'. A step needs a reference for the current it draws.")
      if work.components.hasKey(loadStepDesignator):
        raise newException(NetlistError,
          "the design already contains '" & loadStepDesignator &
          "', which is the designator a load step injects its own sink under")
      # `+` on the measured node and `-` on the reference, as
      # `analyzeLoadSweep` does: SPICE runs positive current from `+` through
      # the source to `-`, so a positive value pulls current out of the node.
      let src = addComponent(work, newComponent(loadStepDesignator,
                                                kind = "current_source"))
      discard connect(src, "+", node, ptPassive)
      discard connect(src, "-", gnd, ptPassive)
      src.attrs["value"] = pulseValue(sink)
      injected = true)

  if injected:
    result.assumptions.add note(loadStepDesignator,
      "a constant-current sink stepped from " & eng(spec.iFrom, "A") &
      " to " & eng(spec.iTo, "A") & " in " & eng(edgeOf(spec), "s") &
      " at " & eng(spec.tSettle, "s") & ", injected at net '" & measureNet &
      "' by the analysis. It is not in the design: a test load is not a part " &
      "anybody solders, and a resistor would sag with the rail and damp the " &
      "network being measured")

  if not r.ok: return
  if not measured(r, 0, result, "net '" & measureNet & "'"): return

  let (wt, wv) = r.slice()
  if wt.len < 4:
    result.issues.add newIssue(KindStepNotSeen, sevWarning,
      "the run produced " & $wt.len & " sample(s) around the step, which is " &
      "too few to measure an excursion between")
    return

  let e = edgeOf(spec)
  let tStep = spec.tSettle
  let tRel = spec.tSettle + edgeOf(spec) + holdOf(spec)

  # The pre-step level, time-weighted over the baseline window rather than
  # taken as one sample: whatever ripple the rail already carries is not part
  # of the droop, and reading a single point would fold it in whole.
  let (bt, bv) = sliceBetween(wt, wv, tStep - baselineOf(spec), tStep)
  let baseline = if bt.len >= 2: timeMean(bt, bv)
                 elif bv.len > 0: bv[^1]
                 else: NaN

  # The loaded window: the edge itself plus the recovery after it.
  let (lt, lv) = sliceBetween(wt, wv, tStep, tStep + e + recoverOf(spec))
  let loaded = swing(lv)

  result.add "step_v_min", loaded.lo, "V"
  result.add "step_v_max", loaded.hi, "V"

  if baseline.isNaN or lt.len < 2:
    result.issues.add newIssue(KindStepNotSeen, sevWarning,
      "the run did not produce samples either side of the edge at " &
      eng(tStep, "s") & ": the baseline window is " &
      eng(baselineOf(spec), "s") & " and the recovery window " &
      eng(recoverOf(spec), "s"))
    return

  # Which way the rail moves is decided by which way the load moved, not by
  # the sign of the excursion: a step *up* in current droops the rail and a
  # step down lifts it, and calling the second one a droop would report a
  # release as a failure.
  let rising = spec.iTo > spec.iFrom
  let droop = if rising: baseline - loaded.lo else: loaded.hi - baseline
  result.add "step_droop_v", max(droop, 0.0), "V"
  result.add "step_droop_pct",
    (if abs(baseline) > 0.0: 100.0 * max(droop, 0.0) / abs(baseline) else: NaN),
    "%"

  # Where the rail settles *under* the new load, which is not where it
  # started: load regulation moves it, and crediting that shift to the
  # transient would report a permanent offset as a droop that never
  # recovered.
  let (ft, fv) = sliceBetween(wt, wv,
                              tStep + e + recoverOf(spec) * 0.75,
                              tStep + e + recoverOf(spec))
  let settled = if ft.len >= 2: timeMean(ft, fv)
                elif fv.len > 0: fv[^1]
                else: baseline

  let tol = if spec.settleTol > 0.0: spec.settleTol else: 0.01
  if abs(settled) > 0.0:
    let back = settleTime(lt, lv, settled, tol)
    if back.isNaN:
      result.add "step_recover_s", NaN, "s"
      result.issues.add newIssue(KindStepNoRecovery, sevWarning,
        "'" & measureNet & "' had not come back inside " &
        eng(tol * 100.0) & "% of " & eng(settled, "V") & " by the end of the " &
        eng(recoverOf(spec), "s") & " recovery window -- either it is still " &
        "ringing, or it is not going to. Widen the window before reading " &
        "this as instability",
        net = nl.nets.getOrDefault(measureNet))
    else:
      result.add "step_recover_s", max(back - tStep, 0.0), "s"
  else:
    result.add "step_recover_s", NaN, "s"

  # The release, and only when there was one. A hold that runs to the end of
  # the record has no falling edge in it, and reporting the last sample as an
  # overshoot would invent one.
  if spec.tHold > 0.0 and tRel + recoverOf(spec) <= wt[^1]:
    let (rt, rv) = sliceBetween(wt, wv, tRel, tRel + e + recoverOf(spec))
    if rt.len >= 2:
      let rel = swing(rv)
      let over = if rising: rel.hi - baseline else: baseline - rel.lo
      result.add "step_overshoot_v", max(over, 0.0), "V"
      result.add "step_overshoot_pct",
        (if abs(baseline) > 0.0: 100.0 * max(over, 0.0) / abs(baseline)
         else: NaN), "%"
