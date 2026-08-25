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
## So this analysis binds nothing. It takes a netlist and a net, runs a
## `.tran`, and reports what the net does over a stated window at the end of
## the run.
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
## **What it does not do.** No initial conditions and no `.ic` card, so a
## circuit that will not start from its own operating point -- an oscillator
## sitting at its unstable equilibrium -- stays out of reach. That is the
## remaining half of `docs/findings.md` §23.

import std/[math, tables]

import ../netlist/types
import ../netlist/graph
import ../netlist/formats/spice as spiceFormat
import ../spice/transform
import ../spice/flatten
import ../spice/models
import ../spice/ngspice
import ./report

export report

const
  KindNotSettled* = "transient_not_settled"
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

proc analyzeTransient*(nl: Netlist, measureNet: string,
                       spec = defaultTransientSpec()): AnalysisReport =
  ## Runs the design and reports what `measureNet` does over the window.
  ##
  ## Measurements: `settled_v` (the window mean), `ripple_pp` (its
  ## peak-to-peak), `settled_min`, `settled_max` and `final_v`.
  result.name = "transient"

  var cloneNets: OrderedTable[string, Net]
  # `materializeSimNetlist` with a purpose, not a bare `clone`: a part
  # carrying more than one model gets the one that answers *this* question,
  # and for a switching regulator that is the difference between a rail with
  # ripple on it and a rail whose model has no ripple in it to find.
  let work = materializeSimNetlist(nl, cloneNets, purpose = spSteadyState)
  discard flattenForSim(work, spec.flattenHierarchy, spec.keepInstances)
  if spec.modelUnmodelledParts:
    result.assumptions.add expandPinModels(work, spec.pinModels)
  if spec.capacitorParasitics:
    result.assumptions.add expandCapacitorParasitics(work)

  let measured = findNet(work, measureNet)
  if measured == nil:
    raise newException(NetlistError,
      "no such net: " & measureNet & " (analyzeTransient)")

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
  let tStep =
    if spec.tStep > 0.0: spec.tStep
    elif tWindow > 0.0: tWindow / 1000.0
    else: tStop / 2000.0

  var card = ".tran " & spiceValue(tStep) & " " & spiceValue(tStop)
  # `tstart` is the fourth field and needs the third, so both are written
  # whenever either is. ngspice still *simulates* from zero -- tstart only
  # says from when to keep the output, which is exactly the distinction this
  # analysis is built on.
  if spec.tSettle > 0.0 or spec.tMax > 0.0:
    card &= " " & spiceValue(max(0.0, spec.tSettle))
    if spec.tMax > 0.0:
      card &= " " & spiceValue(spec.tMax)

  try:
    result.raw = run(work, @[card])
  except SpiceSimError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not run the transient: " & e.msg)
    return

  let t = result.raw["time"]
  let v = result.raw["v(" & measured.name & ")"]
  if t.len == 0 or v.len == 0:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the transient produced no samples for net '" & measureNet & "'")
    return

  # `tstart` is honoured by ngspice, but a deck that stated none still has the
  # whole run in the output, so the window is applied here too. Doing it in
  # both places is not redundancy: one of them controls how much data crosses
  # the process boundary and the other controls what is measured.
  let w = windowOf(t, spec.tSettle)
  if w.a > w.b:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the measurement window opens at " & eng(spec.tSettle, "s") &
      " but the run ended at " & eng(t[^1], "s") & " -- nothing was measured")
    return

  var lo = v[w.a]
  var hi = v[w.a]
  var sum = 0.0
  for i in w:
    if v[i] < lo: lo = v[i]
    if v[i] > hi: hi = v[i]
    sum += v[i]
  let mean = sum / float(w.b - w.a + 1)

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
