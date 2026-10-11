## What a node settles to, and what is still moving once it has.
##
## Nothing here binds a driving part, so circuits with no regulator or
## amplifier (charge pumps, oscillators, cycle-by-cycle converters) can be
## asked what a node does once it stops changing. Each analysis runs a
## `.tran` and reads a stated window at its end: `analyzeTransient` (where a
## node settled, what's still moving), `analyzeOscillation` (frequency,
## swing, purity), `analyzeCurrent` (current through a part). They share
## one run.
##
## **Simulated as authored -- no isolation.** Isolation terminates a cut
## rail at its nominal voltage, which is the number being measured.
##
## **`tSettle` is stated, not detected**: what counts as settled is a
## judgement about the circuit, and a wrong guess reports start-up as ripple.
##
## **Circuits that won't start themselves** (oscillators) need
## `initialConditions`: an `.ic` card plus `uic`, recorded as an assumption
## because every unnamed node then starts at zero rather than its bias.

import std/[math, strutils, tables]

import ../../netlist/types
import ../../units
import ../../netlist/graph
import ../../netlist/formats/spice as spiceFormat
import ../../spice/transform
import ../../spice/models
import ../../spice/ngspice
import ../../spice/bench
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
    scope*: ScopeChoice
      ## How much of the design is simulated (`spice/region_strategy`).
    tSettle*: float
      ## Simulated seconds before the measurement window opens.
    tWindow*: float
      ## Window length in seconds; `0` means to the end of the run.
    tStop*: float
      ## `0` derives `tSettle + tWindow`, or `tSettle * 1.2` with no window.
    tStep*: float
      ## The `.tran` print step; `0` derives one from the window.
    tMax*: float
      ## Ceiling on the simulator's timestep; `0` leaves it to ngspice. Needed
      ## for switching designs, where truncation-error control otherwise takes
      ## long steps between edges and undersamples the ripple.
    settleTol*: float
      ## Fractional band around the window mean the whole window must stay
      ## inside to count as settled. `0` disables the check.
    pinModels*: PinModelDefaults
    flattenHierarchy*: bool
    keepInstances*: seq[string]
    modelUnmodelledParts*: bool
    initialConditions*: OrderedTable[string, float]
      ## Node name -> volts, emitted as `.ic` and forcing `uic`. The only way
      ## to start a circuit that sits at its operating point forever. `uic`
      ## skips the operating-point solve, so every unnamed node starts at
      ## zero -- state enough of them.
    capacitorParasitics*: bool
      ## Expand each capacitor into C + ESR + ESL (default on). Converter
      ## ripple is mostly inductor current across ESR; without it ripple
      ## reads low.

proc defaultTransientSpec*(): TransientSpec =
  TransientSpec(scope: ScopeChoice(strategy: "source_closed", icSinks: true),
                tSettle: 0.0, tWindow: 0.0, tStop: 0.0, tStep: 0.0,
                tMax: 0.0, settleTol: 0.0,
                pinModels: defaultPinModels(), flattenHierarchy: true,
                modelUnmodelledParts: true, capacitorParasitics: true)

proc windowOf(t: openArray[float], fromT: float): Slice[int] =
  ## The samples at or after `fromT`; empty if none, so a mean over it is
  ## `NaN` ("window fell outside the run").
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
    ## What to read, named as the design names it (net or designator,
    ## hierarchical). Resolved to a rawfile vector only after the work
    ## netlist is flattened and model-substituted.
    kind: ProbeKind
    target: string

  ProbeResult = object
    vector*: string
      ## The rawfile vector this probe resolved to; empty when it could not.
    saveTerm*: string
      ## What a `.save` must name for the vector to exist; empty when
      ## ngspice writes it anyway (`branchCurrentVector`).
    values*: seq[float]
      ## The whole run; `WindowRun.w` cuts the window.
    reason*: string
      ## Why `values` is empty. Only current probes get one (three-terminal
      ## device, `X` instance, XSPICE model); a missing net raises.

  WindowRun = object
    ## What a `.tran` gave back, cut to the measurement window. Shared by
    ## all three analyses so they can't diverge in simulator setup, and
    ## multi-probe so several current claims cost one run.
    t*: seq[float]
    probes*: seq[ProbeResult]
    w*: Slice[int]
    ok*: bool

proc resolveProbe(work: Netlist, p: Probe): ProbeResult =
  ## Which rawfile vector answers this probe in the deck netlist. A voltage
  ## probe that resolves to nothing raises (no partial answer); a current
  ## probe gets a `reason` so the rest of the batch is still measured.
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
      # Not necessarily a typo: macromodels and parasitic expansion can
      # replace the original designator in the deck netlist.
      return ProbeResult(reason:
        "'" & p.target & "' is not in the netlist that reaches the deck; a " &
        "model pass stood it in for, or dissolved it into, something else")
    let (vector, saveTerm, reason) =
      branchCurrentVector(spiceFormat.deckDesignator(c))
    ProbeResult(vector: vector, saveTerm: saveTerm, reason: reason)

proc runWindow(nl: Netlist, probes: openArray[Probe], spec: TransientSpec,
               rep: var AnalysisReport, windowSamples = 1000,
               label = "",
               mutate: proc (b: var Bench) {.closure.} = nil): WindowRun =
  ## Simulates the design as authored and returns the window. Assumptions
  ## and issues go onto `rep` as produced, including on failure paths.
  # Clone, flatten, *then* `simReplace` (not `materializeSimNetlist`), so a
  # nested XSPICE component's ports use post-flatten net names. The purpose
  # picks which model a multi-model part uses.
  var b = openBench(nl, "transient", spSteadyState, spec.flattenHierarchy,
                    spec.keepInstances)
  if spec.modelUnmodelledParts:
    b.modelUnmodelled(spec.pinModels)
  # Seeds: what is read. A stimulus `mutate` adds lands on a probed net.
  var seedNets, seedParts: seq[string]
  for p in probes:
    case p.kind
    of pkVoltage:
      let n = findNet(b.work, p.target)
      if n != nil: seedNets.add n.name
    of pkCurrent:
      let c = findComponent(b.work, p.target)
      if c != nil and b.work.components.hasKey(c.designator):
        seedParts.add c.designator
  b.scopeBench(spec.scope, seedParts, seedNets)
  rep.assumptions.add b.assumptions
  let work = b.netlist
  if spec.capacitorParasitics:
    rep.assumptions.add expandCapacitorParasitics(work)

  # Stimuli (a pulsed load, a ripple source) are added after every model
  # pass, so `expandPinModels` never sees them, and before probes resolve.
  if mutate != nil: mutate(b)

  for p in probes:
    result.probes.add resolveProbe(work, p)
    case p.kind
    of pkVoltage: b.probe(p.target, "V(" & p.target & ") over the window")
    of pkCurrent: b.probeCurrent(p.target, "current through " & p.target)

  let tWindow =
    if spec.tWindow > 0.0: spec.tWindow
    elif spec.tSettle > 0.0: spec.tSettle * 0.2
    else: 0.0
  let tStop =
    if spec.tStop > 0.0: spec.tStop
    else: spec.tSettle + (if tWindow > 0.0: tWindow else: 1.0e-3)
  # The print step is sized from the window, not the run, so the window
  # gets ~1000 samples (peak-to-peak is sensitive to undersampling).
  # ngspice also uses the print step as its maximum internal timestep, so it
  # sets solve accuracy -- hence `windowSamples` is a parameter: phase-
  # sensitive measurements (frequency) need more.
  let tStep =
    if spec.tStep > 0.0: spec.tStep
    elif tWindow > 0.0: tWindow / float(max(1, windowSamples))
    else: tStop / float(2 * max(1, windowSamples))

  var card = ".tran " & spiceValue(tStep) & " " & spiceValue(tStop)
  # `tstart` needs `tstep`/`tstop` before it. ngspice still simulates from
  # zero; `tstart` only drops earlier output.
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
    # `uic` makes the .ic the starting state, not a solver hint.
    card &= " uic"
    rep.assumptions.add note(
      "the run starts from stated initial conditions (" & terms.join(", ") &
      ") with uic, so no operating point was solved and every other node " &
      "starts at zero rather than at its bias")

  # Terminal currents reach the rawfile only when named. `all` leads, since
  # naming any vector drops the default set.
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
    rep.raw = b.run(card, setup, label = runLabel)
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
      # Asked for but missing: say which vector.
      result.probes[i].reason =
        "the run produced no vector '" & result.probes[i].vector & "'"
    if result.probes[i].values.len == 0 and result.probes[i].reason.len == 0:
      result.probes[i].reason =
        "the run produced no samples for '" & result.probes[i].vector & "'"

  # Also windowed here, since a deck with no `tstart` returns the whole run.
  result.w = windowOf(result.t, spec.tSettle)
  if result.w.a > result.w.b:
    rep.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the measurement window opens at " & eng(spec.tSettle, "s") &
      " but the run ended at " & eng(result.t[^1], "s") & " -- nothing was measured")
    return
  result.ok = true

proc slice(r: WindowRun, i = 0): tuple[t, v: seq[float]] =
  ## Probe `i`'s window as two seqs for `analysis/measure`.
  for k in r.w:
    result.t.add r.t[k]
    result.v.add r.probes[i].values[k]

proc measured(r: WindowRun, i: int, rep: var AnalysisReport,
              what: string): bool =
  ## Whether probe `i` has samples, reporting why not. `runWindow` succeeds
  ## if the run did, even when one probe is unmeasurable.
  if r.probes[i].values.len > 0: return true
  rep.issues.add newIssue(KindSimulationFailed, sevWarning,
    "the transient measured nothing for " & what &
    (if r.probes[i].reason.len > 0: ": " & r.probes[i].reason else: ""))
  false

proc analyzeTransient*(nl: Netlist, measureNet: string,
                       spec = defaultTransientSpec()): AnalysisReport =
  ## Reports what `measureNet` settled to: `settled_v` (window mean),
  ## `ripple_pp`, `settled_min`, `settled_max`, `final_v`.
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
  ## Reports what `measureNet` is running at: `osc_freq`, `swing_pp`,
  ## `osc_thd_pct`. These are `.tran` quantities: an oscillator has no input
  ## to sweep from, and driving a Wien bridge's `IN+` with an `.ac` source
  ## shorts its feedback (`opamp.checkInjectionPoint` refuses it).
  ##
  ## `osc_thd_pct` integrates whole periods, so a window still holding the
  ## start-up envelope reports it as distortion; amplitude stabilisation is
  ## slow, so `tSettle` usually needs to be long. Most circuits need
  ## `initialConditions` to start.
  result.name = "oscillation"

  # 10x `analyzeTransient`'s sample density: the print step caps ngspice's
  # timestep, and frequency and THD are phase-sensitive.
  let r = runWindow(nl, [Probe(kind: pkVoltage, target: measureNet)],
                    spec, result, windowSamples = 10_000)
  if not r.ok: return
  if not measured(r, 0, result, "net '" & measureNet & "'"): return
  let (wt, wv) = r.slice()

  let sw = swing(wv)
  result.add "swing_pp", sw.pp, "V"

  # Frequency first: THD over the wrong period leaks the fundamental into
  # the harmonic bins.
  let f0 = fundamentalFreq(wt, wv)
  result.add "osc_freq", f0, "Hz"
  result.add "osc_thd_pct", thd(wt, wv, f0) * 100.0, "%"

  if f0.isNaN:
    # `NaN` reads as notEvaluated downstream, so explain it here. Two causes,
    # two fixes.
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
  ## Runs the design once and reports the current through each part over
  ## the window, tagged with the designator in `Measurement.at`: `i_peak`,
  ## `i_rms`, `i_avg`, `i_pp`, `i_min`, `i_max`, plus `i_peak_derating` and
  ## `i_rms_derating` against a stated rating. This is where `current_rating`
  ## and `isat` are checked -- branch currents aren't in a `.op`.
  ##
  ## `i_peak`/`i_rms`/`i_avg` are magnitudes, as ratings are: the sign is a
  ## deck convention (a supply delivering 330 mA reads -330 mA). `i_min`/
  ## `i_max` keep the sign to show reversal. Every part is read off one run.
  result.name = "current"
  # Nothing to read, nothing to run.
  if parts.len == 0: return

  var probes: seq[Probe]
  for p in parts: probes.add Probe(kind: pkCurrent, target: p)

  let r = runWindow(nl, probes, spec, result,
                    label = "current:" & (if parts.len > 0: parts[0] else: ""))
  if not r.ok: return

  for i, part in parts:
    if r.probes[i].values.len == 0:
      # Name the part: downstream this is one notEvaluated among several.
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

    # `NaN` where the part states no rating: unchosen, not infinite headroom.
    let c = findComponent(nl, part)
    let isatAnn = if c == nil: absent(Amps)
                  else: annotationAs(c, "isat", Amps)
    let icontAnn = if c == nil: absent(Amps) else: currentRating(c)
    let isat = AnnValue[float](source: isatAnn.source, value: float(isatAnn.value))
    let icont = AnnValue[float](source: icontAnn.source, value: float(icontAnn.value))
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
    scope*: ScopeChoice
      ## How much of the design is simulated (`spice/region_strategy`).
    iFrom*, iTo*: float
      ## Load before and after the edge, in amps. `iTo < iFrom` measures a
      ## release.
    tSettle*: float
      ## When the baseline may be read. Stated, not detected.
    tBaseline*: float
      ## Averaging time before the edge. 0 takes `tSettle / 10`, or
      ## `tRecover` with no settle time.
    tEdge*: float
      ## Rise/fall time; 0 takes 1 us. Not cosmetic: slew decides whether
      ## ESR or loop bandwidth sets the droop.
    tHold*: float
      ## Time at `iTo` before returning to `iFrom`; 0 holds to the end (no
      ## release measured).
    tRecover*: float
      ## Watch time after each edge; 0 takes 10 x `tEdge`.
    settleTol*: float
      ## Band the rail must re-enter and stay in for `step_recover_s`; 0
      ## takes 1%.
    pinModels*: PinModelDefaults
    flattenHierarchy*: bool
    keepInstances*: seq[string]
    modelUnmodelledParts*: bool
    capacitorParasitics*: bool
    windowSamples*: int
      ## Points across the recovery window; 0 takes 2000. Also caps the
      ## solver timestep, so it sets how well the edge is solved.

proc defaultLoadStepSpec*(): LoadStepSpec =
  LoadStepSpec(scope: ScopeChoice(strategy: "source_closed", icSinks: true),
               iFrom: 0.0, iTo: 0.0, tSettle: 0.0, tBaseline: 0.0,
               tEdge: 0.0, tHold: 0.0, tRecover: 0.0, settleTol: 0.0,
               pinModels: defaultPinModels(), flattenHierarchy: true,
               modelUnmodelledParts: true, capacitorParasitics: true,
               windowSamples: 0)

proc edgeOf*(spec: LoadStepSpec): float =
  ## The resolved edge time, exported so a report can state it.
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
  ## `PULSE(i1 i2 td tr tf pw per)`, with the period past the end of the
  ## run so the pulse happens once.
  let e = edgeOf(spec)
  let stop = stopOf(spec)
  "PULSE(" & spiceValue(spec.iFrom) & " " & spiceValue(spec.iTo) & " " &
  spiceValue(spec.tSettle) & " " & spiceValue(e) & " " & spiceValue(e) & " " &
  spiceValue(holdOf(spec)) & " " & spiceValue(10.0 * stop) & ")"

proc toTransient(spec: LoadStepSpec): TransientSpec =
  ## The window opens at the baseline, not the step, so the pre-step level
  ## is measured.
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
  result.scope = spec.scope

proc sliceBetween(t, v: openArray[float], fromT, toT: float):
    tuple[t, v: seq[float]] =
  for i in 0 ..< t.len:
    if t[i] >= fromT and t[i] <= toT:
      result.t.add t[i]
      result.v.add v[i]

proc analyzeLoadStep*(nl: Netlist, measureNet: string,
                      spec = defaultLoadStepSpec()): AnalysisReport =
  ## What a rail does when the load jumps, and how long it takes to recover
  ## -- the time-domain question a target impedance is a proxy for.
  ##
  ## The stimulus is an injected, pulsed constant-current sink: injected
  ## because a test load isn't a board part; a sink because a resistor's
  ## current follows the rail and damps the network being measured. Not
  ## isolated (a terminated rail can't droop). Capacitor parasitics are on:
  ## the instantaneous ESR step is often most of the droop.
  ##
  ## Reports `step_droop_v`/`_pct`, `step_overshoot_v`/`_pct` (on release),
  ## `step_recover_s`, and `step_v_min`/`step_v_max`. Anything unseen is
  ## `NaN` with an issue, never zero.
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
                    mutate = proc (b: var Bench) =
      let work = b.netlist
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
      # `+` on the measured node: a positive value pulls current out of it.
      let src = addComponent(work, newComponent(loadStepDesignator,
                                                kind = "current_source"))
      discard connect(src, "+", node, ptPassive)
      discard connect(src, "-", gnd, ptPassive)
      src.attrs["value"] = pulseValue(sink)
      b.load(src, "load stepped " & eng(sink.iFrom, "A") & " to " &
             eng(sink.iTo, "A") & " out of '" & measureNet & "'")
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

  # Time-weighted baseline, so existing ripple isn't counted as droop.
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

  # Direction follows the load step, not the excursion's sign: a step down
  # lifts the rail and isn't a droop.
  let rising = spec.iTo > spec.iFrom
  let droop = if rising: baseline - loaded.lo else: loaded.hi - baseline
  result.add "step_droop_v", max(droop, 0.0), "V"
  result.add "step_droop_pct",
    (if abs(baseline) > 0.0: 100.0 * max(droop, 0.0) / abs(baseline) else: NaN),
    "%"

  # Recovery is measured to the new settled level; load regulation's offset
  # isn't an unrecovered droop.
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

  # The release only when there was one within the record.
  if spec.tHold > 0.0 and tRel + recoverOf(spec) <= wt[^1]:
    let (rt, rv) = sliceBetween(wt, wv, tRel, tRel + e + recoverOf(spec))
    if rt.len >= 2:
      let rel = swing(rv)
      let over = if rising: rel.hi - baseline else: baseline - rel.lo
      result.add "step_overshoot_v", max(over, 0.0), "V"
      result.add "step_overshoot_pct",
        (if abs(baseline) > 0.0: 100.0 * max(over, 0.0) / abs(baseline)
         else: NaN), "%"
