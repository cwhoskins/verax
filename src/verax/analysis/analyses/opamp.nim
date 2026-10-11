## Op-amp stage analysis, as three procs with different costs:
##
## * `checkFeedback` -- a graph walk: is there a path from output to the
##   inverting input?
## * `analyzeOpAmpResponse` -- one `.ac` sweep of the **closed-loop**
##   response: gain, -3 dB bandwidth, peaking.
## * `analyzeLoopGain` -- one `.ac` sweep of the **loop gain**, breaking the
##   loop at the inverting input. The only source of a real phase margin.
##
## **Phase margin is never read off the closed-loop curve**: that's
## `Aol/(1+Aol*beta)`, a different function, and "180 + phase at unity gain"
## off it only looks like a margin. The closed-loop sweep reports peaking.
##
## A component with no model gets a single-pole ideal macromodel
## (`spice/models.idealOpAmp`), recorded as an assumption: it shows what the
## feedback network does, not what a specific part does.

import std/[complex, math, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/kinds
import ../../netlist/formats/spice as spiceFormat
import ../../spice/isolate
import ../../spice/transform
import ../../spice/models
import ../../spice/ngspice
import ../../spice/bench
import ../measure
import ../report

export report

const
  KindNoFeedback* = "opamp_no_feedback"
  KindInsufficientBandwidth* = "opamp_insufficient_bandwidth"
  KindGainPeaking* = "opamp_gain_peaking"
  KindLowPhaseMargin* = "opamp_low_phase_margin"
  KindSimulationFailed* = "opamp_simulation_failed"
  KindLoopBreakInvalid* = "opamp_loop_break_invalid"
  KindExcessDistortion* = "opamp_excess_distortion"
  KindClipping* = "opamp_clipping"
  KindInputInFeedback* = "opamp_input_in_feedback"

  posNames = ["+", "in+", "inp", "vin+", "ninv", "noninv"]
  negNames = ["-", "in-", "inn", "vin-", "inv"]
  outNames = ["out", "vout", "o", "output"]

type
  OpAmpSpec* = object
    fStart*, fStop*: float
    ptsPerDecade*: int
    minBandwidth*: float
      ## Hz; `0` disables the check.
    maxPeaking*: float
      ## dB of closed-loop peaking tolerated before it is flagged.
    minPhaseMargin*: float
      ## Degrees.
    idealAol*, idealGbw*: float
      ## Used only when the component carries no model of its own.
    driveAmplitude*: float
      ## Volts peak of the large-signal sine; `0` disables that analysis.
    driveFreq*: float
      ## Hz of that sine.
    drivePeriods*: int
      ## Whole periods kept after settling (more = better THD floor).
    driveSettlePeriods*: int
      ## Periods simulated and discarded before measuring.
    pointsPerPeriod*: int
      ## Requested `.tran` timestep as a divisor of the period. ngspice may
      ## step finer, so harmonic integration reads timestamps.
    thdHarmonics*: int
      ## How many harmonics above the fundamental enter the THD sum.
    maxThd*: float
      ## Percent of THD tolerated before it is flagged; `0` disables.
    boundToRails*: bool
      ## Clamp the substituted macromodel's output to the stated supply rails
      ## (default on); unbounded, a stage can't saturate. No effect when the
      ## rails state no voltage (`io_check.checkRailVoltages` flags that).
    vsatHeadroom*: float
      ## Volts the output stops short of each rail. `0` makes the model an
      ## upper bound on swing.
    gainAtFreq*: float
      ## Hz; when > 0 the sweep also reports `gain_at_f` ("20 dB at 1 kHz").
      ## `0` disables it.
    maxHops*: int
    pinModels*: PinModelDefaults
    flattenHierarchy*: bool
      ## Flatten subcircuit instances first (default on); otherwise
      ## `spice/isolate` cuts each instance at its boundary.
    keepInstances*: seq[string]
      ## Instance paths `flatten` keeps intact, beyond the analysed part
      ## (added automatically) -- for a design's own subcircuit macromodel.
    modelUnmodelledParts*: bool
      ## Stand in for unmodelled parts around the fragment rather than leave
      ## them open. Never applied to the analysed part.

proc defaultOpAmpSpec*(): OpAmpSpec =
  OpAmpSpec(fStart: 1.0, fStop: 1.0e8, ptsPerDecade: 20, minBandwidth: 0.0,
            maxPeaking: 1.0, minPhaseMargin: 45.0,
            idealAol: 1.0e5, idealGbw: 1.0e6,
            driveAmplitude: 0.0, driveFreq: 1.0e3, drivePeriods: 8,
            driveSettlePeriods: 4, pointsPerPeriod: 256, thdHarmonics: 9,
            maxThd: 0.0, boundToRails: true, vsatHeadroom: 0.0,
            gainAtFreq: 0.0, maxHops: 3,
            pinModels: defaultPinModels(),flattenHierarchy: true,
 modelUnmodelledParts: true)

proc matchPin(c: Component, names: openArray[string]): Pin =
  for pinName, p in c.pins:
    if pinName.toLowerAscii in names: return p
  nil

proc findOpAmpPins*(c: Component): tuple[pos, neg, outp: Pin] =
  ## Locates `+`, `-` and output pins by name (`Pin.kind` can't tell `+`
  ## from `-`). Tolerant, case-insensitive; raises listing the actual pins
  ## when none match.
  result = (pos: matchPin(c, posNames), neg: matchPin(c, negNames),
            outp: matchPin(c, outNames))
  if result.pos == nil or result.neg == nil or result.outp == nil:
    var have: seq[string]
    for pinName, _ in c.pins: have.add pinName
    raise newException(NetlistError,
      "cannot identify the +/-/OUT pins of " & c.designator & " from its pin names (" &
      have.join(", ") & "); expected one of " & posNames.join("/") & ", " &
      negNames.join("/") & ", " & outNames.join("/"))

proc reachesThroughPassives(fromNet, toNet: Net, excluding: Component,
                            stopAtRails = false): bool =
  ## Breadth-first walk over nets through parts fully described by their
  ## value. Blocking parts count (a capacitor in feedback is an integrator).
  ## A part with a signal-passing behavioural model is crossed **forwards
  ## only**, input to output, matching what `spice/models` builds.
  ##
  ## `stopAtRails` refuses to walk through power/ground (an AC ground every
  ## stage hangs off). Off for `checkFeedback`, which wants the permissive
  ## walk; on for the injection test, where crossing a bypassed bias rail is
  ## always a false positive.
  if fromNet == toNet: return true
  var visited = @[fromNet]
  var queue = @[fromNet]
  var qi = 0
  while qi < queue.len:
    let net = queue[qi]
    inc qi
    if stopAtRails and net != fromNet and isRail(net): continue

    for p in net.pins:
      let comp = p.component
      if comp == nil or comp == excluding: continue
      if comp.subNetlist != nil: continue

      if not isPassive(comp):
        if not passesSignal(comp.kind): continue
        # Forwards only: entered at the input, leave at the output.
        let (inp, outp) = signalPathPins(comp)
        if inp == nil or outp == nil or p != inp or outp.net == nil: continue
        if outp.net == toNet: return true
        if outp.net != net and outp.net notin visited:
          visited.add outp.net
          queue.add outp.net
        continue

      for _, other in comp.pins:
        if other.net == nil or other.net == net: continue
        if other.net == toNet: return true
        if other.net notin visited:
          visited.add other.net
          queue.add other.net
  false

proc checkFeedback*(nl: Netlist, opamp: string): seq[Issue] =
  ## Static check: is there a path from output back to the inverting input
  ## through passives only? A path through another active device isn't
  ## feedback (its gain and direction are unknown here).
  let c = findComponent(nl, opamp)
  if c == nil:
    raise newException(NetlistError, "no such component: " & opamp)
  let pins = findOpAmpPins(c)

  if pins.outp.net == nil or pins.neg.net == nil:
    return @[newIssue(KindNoFeedback, sevError,
      "op-amp " & opamp & " has an unconnected output or inverting input, so it " &
      "cannot have negative feedback", components = @[c])]

  if not reachesThroughPassives(pins.outp.net, pins.neg.net, c):
    return @[newIssue(KindNoFeedback, sevError,
      "no passive path from " & opamp & "." & pins.outp.name & " (net '" &
      pins.outp.net.name & "') back to " & opamp & "." & pins.neg.name & " (net '" &
      pins.neg.net.name & "'): the stage is running open-loop and will sit at a " &
      "supply rail", net = pins.outp.net, components = @[c])]

  @[]

proc checkInjectionPoint*(nl: Netlist, opamp, inputNet: string): seq[Issue] =
  ## Whether driving `inputNet` would cut the loop being measured. An ideal
  ## `.ac` source holds its node, so driving a node the feedback returns to
  ## silently measures the forward path (a Wien bridge driven at `IN+`
  ## reports its open bandwidth and every claim passes).
  ##
  ## Both must hold: the driven net is one of the amp's input pins' nets,
  ## **and** the output reaches it through passives. Either alone
  ## over-triggers (inverting amp's input reaches the output via `Rin`+`Rf`;
  ## non-inverting amp is driven at `IN+` with nothing feeding back there).
  let c = findComponent(nl, opamp)
  if c == nil: return @[]
  let target0 = findNet(nl, inputNet)
  if target0 == nil: return @[]
  let pins = findOpAmpPins(c)
  let target = target0

  var isAmpInput = false
  var whichPin = ""
  for pin in [pins.pos, pins.neg]:
    if pin != nil and pin.net == target:
      isAmpInput = true
      whichPin = pin.name
  if not isAmpInput: return @[]

  if pins.outp.net == nil: return @[]
  if not reachesThroughPassives(pins.outp.net, target, c, stopAtRails = true):
    return @[]

  @[newIssue(KindInputInFeedback, sevError,
    "net '" & inputNet & "' is " & opamp & "." & whichPin & " and the output " &
    "feeds back to it through passives, so it is inside the loop. Driving it " &
    "with an ideal source holds that node and removes the feedback path, and " &
    "the sweep would then measure the forward path of a different circuit. " &
    "Drive the node ahead of the input network instead, or -- if this stage " &
    "has no input, as an oscillator does not -- it has no closed-loop " &
    "response to sweep at all.",
    net = target, components = @[c])]

type Prepared = object
  b: Bench
  frag: Netlist
  negPin: Pin
  posNet, outNet, gnd: Net
  assumptions: seq[Assumption]

proc prepare(nl: Netlist, opamp, inputNet, outputNet: string,
             spec: OpAmpSpec, bound = false): Prepared =
  ## Isolates the stage and ensures it has an op-amp model. `bound` clamps
  ## the macromodel to the rails and **only large-signal callers ask for
  ## it**: the clamp's derivative is zero at a rail, so an `.ac` sweep of a
  ## stage biased there (common single-supply) would show no gain.
  var isoSpec = defaultIsolationSpec("opamp_" & opamp)
  isoSpec.maxHops = spec.maxHops
  isoSpec.requireKnownRails = false
  # Signal nets are never terminated: the input gets the stimulus and the
  # output is measured.
  isoSpec.excludeRails = @[inputNet, outputNet]

  # Before isolating, so a part in the loop (a buffer) is stood in for
  # rather than cut, which would open the loop.
  # Clone, flatten, *then* `simReplace` (not `materializeSimNetlist`), so a
  # nested XSPICE component's ports use post-flatten net names. `bound`
  # selects which purpose a multi-model part is stood in for.
  var b = openBench(nl, "opamp:" & opamp,
                    (if bound: spLargeSignal else: spSmallSignal),
                    spec.flattenHierarchy, spec.keepInstances, [opamp])
  let work = b.work

  # Read after flattening (a nested amp's pins move to `XL.amp` etc.) and
  # before isolation (so rails are the design's, not the terminations).
  let pins = findOpAmpPins(findComponent(work, opamp))

  if spec.modelUnmodelledParts:
    b.modelUnmodelled(spec.pinModels, [opamp])

  b.scopeBench ScopeRequest(strategy: "terminated", seedParts: @[opamp],
                            seedNets: @[inputNet, outputNet],
                            isolation: isoSpec)
  result.frag = b.netlist
  result.assumptions.add b.assumptions
  let iso = (dropped: b.scoped.region.dropped)
  if iso.dropped.len > 0:
    result.assumptions.add note("components " & iso.dropped.join(", ") &
      " were cut at the boundary: any loading they present is not represented")
  b.focus(inputNet, outputNet)

  result.gnd = result.frag.nets["0"]
  result.posNet = result.frag.nets[pins.pos.net.name]
  result.outNet = result.frag.nets[outputNet]
  let negNet = result.frag.nets[pins.neg.net.name]

  if result.frag.components[opamp].subNetlist != nil:
    # The design brought its own macromodel; use it untouched.
    result.negPin = findOpAmpPins(result.frag.components[opamp]).neg
  else:
    # Bounded to the stated supply rails, read from the pre-isolation copy.
    let rails = supplyRailsOf(findComponent(work, opamp))
    let clamp = bound and rails.known and spec.boundToRails
    let vHi = if clamp: rails.hi - spec.vsatHeadroom else: Inf
    let vLo = if clamp: rails.lo + spec.vsatHeadroom else: -Inf

    # A stated `gbw` beats the 1 MHz default, which can cost tenths of a dB
    # at audio frequencies on a high-gain stage.
    let statedGbw = annotationFloat(findComponent(work, opamp), "gbw")
    let gbw = if statedGbw.has and statedGbw.value > 0.0: statedGbw.value
              else: spec.idealGbw
    let tmpl = idealOpAmp("IDEAL_OPAMP", spec.idealAol, gbw, vHi, vLo)
    if clamp:
      result.assumptions.add note(opamp & " saturates at " & eng(vLo, "V") &
        " to " & eng(vHi, "V") & ", its stated supply rails less " &
        eng(spec.vsatHeadroom, "V") & " of headroom; a real part stops " &
        "short of its rails by anything from tens of millivolts to a " &
        "couple of volts, so annotate `voltage` on the rails and set the " &
        "headroom from the datasheet if the swing is what you are studying")
    elif bound:
      result.assumptions.add note(opamp & " has no stated supply rails, so " &
        "its output is unbounded and it cannot run out of swing: a stage " &
        "whose only nonlinearity is this amplifier saturating measures clean")
    var inst: Component
    provenance(result.frag, result.frag.components[opamp], brStandIn):
      removeComponent(result.frag, opamp)
      inst = instantiate(result.frag, "X" & opamp, tmpl,
                         @[result.posNet, negNet, result.outNet], b.globals)
    result.negPin = inst.pins["INN"]
    if not (statedGbw.has and statedGbw.value > 0.0):
      result.assumptions.add assumption(
        opamp, "gbw", gbw, "Hz", annDerived,
        "of a substituted ideal single-pole op-amp (Aol " & eng(spec.idealAol) &
        "); no offset, slew rate, output impedance, supply rails or second " &
        "pole are represented. State `gbw` on the part to use its own")
  result.b = b

proc detachDrivers(frag: Netlist, netName: string): seq[string] =
  ## Removes stiff drivers of `netName`, since the measurement replaces them
  ## with an ideal stimulus. Two ideal sources on one node (e.g. a preceding
  ## stage's VCVS macromodel) give a singular matrix. Drivers through a
  ## coupling cap or series resistor are left alone.
  let net = frag.nets.getOrDefault(netName)
  if net == nil: return
  var doomed: seq[Component]
  for p in net.pins:
    let c = p.component
    if c == nil or c in doomed: continue
    if c.kind == "voltage_source" or (c.kind == "vcvs" and p.name == "OUT+"):
      doomed.add c
  for c in doomed:
    result.add c.designator
    removeComponent(frag, c.designator)

proc acCard(spec: OpAmpSpec): string =
  ".ac dec " & $spec.ptsPerDecade & " " &
  spiceFormat.spiceValue(spec.fStart) & " " & spiceFormat.spiceValue(spec.fStop)

proc analyzeOpAmpResponse*(nl: Netlist, opamp, inputNet, outputNet: string,
                           spec = defaultOpAmpSpec()): AnalysisReport =
  ## Closed-loop gain and bandwidth of the stage, driven at `inputNet`.
  result.name = "Closed-loop response of " & opamp

  if findComponent(nl, opamp) == nil:
    raise newException(NetlistError, "no such component: " & opamp)
  for n in [inputNet, outputNet]:
    if findNet(nl, n) == nil:
      raise newException(NetlistError, "no such net: " & n)

  # No feedback means no closed-loop response; return the finding rather
  # than simulate an open loop.
  let fb = checkFeedback(nl, opamp)
  if fb.len > 0:
    result.issues = fb
    return

  # Driving inside the loop fails silently, so check before the sweep.
  let injIssues = checkInjectionPoint(nl, opamp, inputNet)
  if injIssues.len > 0:
    result.issues = injIssues
    return

  var p = prepare(nl, opamp, inputNet, outputNet, spec)
  result.assumptions = p.assumptions

  let displaced = detachDrivers(p.frag, inputNet)
  if displaced.len > 0:
    result.assumptions.add note(displaced.join(", ") & " drove '" & inputNet &
      "' and was removed so the sweep could drive it instead: this measures " &
      "the stage from that node onward, and whatever the displaced part " &
      "would have contributed is not represented")

  let src = addComponent(p.frag, newComponent(
    $spiceFormat.designatorPrefix("voltage_source") & "AC_IN", kind = "voltage_source"))
  discard connect(src, "+", p.frag.nets[inputNet], ptPassive)
  discard connect(src, "-", p.gnd, ptPassive)
  src.attrs["value"] = "DC 0 AC 1"
  p.b.detached(displaced)
  p.b.stimulus(src, "1 V AC into '" & inputNet & "'")
  p.b.probe(outputNet, "V(" & outputNet & ") / V(" & inputNet & ") is the closed-loop gain")

  try:
    result.raw = p.b.run(@[acCard(spec)],
                     label = "closed loop:" & opamp)
  except SpiceSimError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not sweep the isolated op-amp stage: " & e.msg)
    return

  let f = result.raw.freq()
  let g = result.raw.db("v(" & outputNet & ")")

  let dcGain = g[0]
  let bw = corner3dB(f, g)
  result.add "gain_dc_db", dcGain, "dB"
  result.add "bw_3db", bw, "Hz"
  result.add "f_unity", unityGainFreq(f, g), "Hz"
  if not bw.isNaN:
    result.add "gain_bw_product", pow(10.0, dcGain / 20.0) * bw, "Hz"

  # The band-referenced half, for AC-coupled stages. `gain_dc_db`, `bw_3db`
  # and `peaking_db` reference the first swept point, which for an
  # AC-coupled single-supply stage is unity gain at DC -- correct and
  # meaningless. These four reference the response maximum instead. Both
  # sets are reported; for a DC-coupled stage they agree.
  let (gMaxDb, gMaxHz) = gainMax(f, g)
  result.add "gain_max_db", gMaxDb, "dB"
  result.add "f_gain_max", gMaxHz, "Hz"
  let edges = bandEdges(f, g)
  result.add "f_lo_3db", edges.lo, "Hz"
  result.add "f_hi_3db", edges.hi, "Hz"

  # `NaN` outside the swept band; no extrapolation.
  if spec.gainAtFreq > 0.0:
    result.add "gain_at_f", valueAt(f, g, spec.gainAtFreq, logX = true), "dB"

  # Peaking above the DC value: what low phase margin looks like from
  # outside the loop.
  var peakDb = 0.0
  for x in g:
    if x - dcGain > peakDb: peakDb = x - dcGain
  result.add "peaking_db", peakDb, "dB"

  if peakDb > spec.maxPeaking:
    result.issues.add newIssue(KindGainPeaking, sevWarning,
      "closed-loop response of " & opamp & " peaks " & eng(peakDb, "dB") &
      " above its DC gain, which is what low phase margin looks like from " &
      "outside the loop -- run analyzeLoopGain for the actual margin",
      components = @[findComponent(nl, opamp)])

  if spec.minBandwidth > 0.0 and (bw.isNaN or bw < spec.minBandwidth):
    let got = if bw.isNaN: "no -3 dB corner within the swept band" else: eng(bw, "Hz")
    result.issues.add newIssue(KindInsufficientBandwidth, sevWarning,
      "closed-loop bandwidth of " & opamp & " is " & got & ", below the required " &
      eng(spec.minBandwidth, "Hz"), components = @[findComponent(nl, opamp)])

proc analyzeLoopGain*(nl: Netlist, opamp, inputNet, outputNet: string,
                      spec = defaultOpAmpSpec()): AnalysisReport =
  ## Phase and gain margin, by breaking the loop at the inverting input and
  ## injecting across the break. That point is low impedance driving high
  ## impedance, so the series source doesn't disturb loop loading. With the
  ## source between the feedback network (A) and the amp input (B),
  ## `T = -V(A)/V(B)` (the sign undoes the amp's inversion).
  result.name = "Loop gain of " & opamp

  if findComponent(nl, opamp) == nil:
    raise newException(NetlistError, "no such component: " & opamp)
  for n in [inputNet, outputNet]:
    if findNet(nl, n) == nil:
      raise newException(NetlistError, "no such net: " & n)

  let fb = checkFeedback(nl, opamp)
  if fb.len > 0:
    result.issues = fb
    return

  # Driving inside the loop fails silently, so check before the sweep.
  let injIssues = checkInjectionPoint(nl, opamp, inputNet)
  if injIssues.len > 0:
    result.issues = injIssues
    return

  var p = prepare(nl, opamp, inputNet, outputNet, spec)
  result.assumptions = p.assumptions

  # Break the loop: the feedback network keeps the original net (A), the
  # amplifier input moves to a fresh one (B).
  let netA = p.negPin.net
  let netB = addNet(p.frag, newNet("LOOP_INJ", ntSignal))
  disconnect(p.negPin)
  connect(p.negPin, netB)

  # Zero the input source so the injected signal is the only excitation.
  let displaced = detachDrivers(p.frag, inputNet)
  if displaced.len > 0:
    result.assumptions.add note(displaced.join(", ") & " drove '" & inputNet &
      "' and was removed so the input could be held at zero while the loop " &
      "is measured")

  let zero = addComponent(p.frag, newComponent(
    $spiceFormat.designatorPrefix("voltage_source") & "ZERO_IN", kind = "voltage_source"))
  discard connect(zero, "+", p.frag.nets[inputNet], ptPassive)
  discard connect(zero, "-", p.gnd, ptPassive)
  zero.attrs["value"] = "DC 0 AC 0"

  let inj = addComponent(p.frag, newComponent(
    $spiceFormat.designatorPrefix("voltage_source") & "INJ", kind = "voltage_source"))
  discard connect(inj, "+", netA, ptPassive)
  discard connect(inj, "-", netB, ptPassive)
  inj.attrs["value"] = "DC 0 AC 1"
  p.b.detached(displaced)
  p.b.stimulus(zero, "'" & inputNet & "' held at 0 V AC so the injection is the only excitation")
  p.b.stimulus(inj, "1 V AC in series at the inverting input: the loop is broken between '" &
               netA.name & "' (A) and LOOP_INJ (B)")
  p.b.probe(netA.name, "loop gain T = -V(A)/V(B)")
  p.b.probe("LOOP_INJ", "loop gain T = -V(A)/V(B)")

  try:
    result.raw = p.b.run(@[acCard(spec)], label = "loop gain:" & opamp)
  except SpiceSimError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not sweep the broken loop: " & e.msg)
    return

  let f = result.raw.freq()
  let a = result.raw.cplx("v(" & netA.name & ")")
  let b = result.raw.cplx("v(" & netB.name & ")")

  var tDb, tPhase: seq[float]
  for i in 0 ..< f.len:
    let t = -(a[i] / b[i])
    tDb.add(if abs(t) <= 0.0: -Inf else: 20.0 * log10(abs(t)))
    tPhase.add radToDeg(phase(t))
  tPhase = unwrapDeg(tPhase)

  result.add "loop_gain_dc_db", tDb[0], "dB"

  let fx = interpCrossing(f, tDb, 0.0, logX = true)
  result.add "crossover_hz", fx, "Hz"

  if fx.isNaN:
    # Nothing to report a margin against.
    result.add "phase_margin_deg", NaN, "deg"
    result.add "gain_margin_db", NaN, "dB"
    return

  let phaseAtX = valueAt(f, tPhase, fx, logX = true)
  let pm = 180.0 + phaseAtX

  # --- is this actually a loop transmission? -----------------------------
  #
  # Exact for a plain amplifier (the break opens its only feedback path).
  # A topology with a second path (Sallen-Key's capacitor to the output)
  # stays partly closed, so `180 + phase` can read 450 degrees -- a margin
  # that passes any minimum. The three signatures are checked here and the
  # margin withheld as `NaN` (not checked, not failed).
  var crossings = 0
  for i in 1 ..< tDb.len:
    if (tDb[i - 1] < 0.0) != (tDb[i] < 0.0): inc crossings

  const openedTol = 30.0
  let dcPhase = tPhase[0]
  let opened = abs(dcPhase) <= openedTol or abs(abs(dcPhase) - 180.0) <= openedTol

  var invalid: seq[string]
  if not opened:
    invalid.add "the ratio starts at " & eng(dcPhase, "deg") & " at the " &
      "bottom of the sweep, where a loop the break had opened would be " &
      "within " & eng(openedTol, "deg") & " of 0 or 180"
  if crossings > 1:
    invalid.add "the magnitude crosses 0 dB " & $crossings & " times, so " &
      "there is no single crossing for a margin to be measured at"
  if not (pm > -180.0 and pm <= 180.0):
    invalid.add "180 plus the phase at crossover is " & eng(pm, "deg") &
      ", outside the range a phase margin can occupy"

  if invalid.len > 0:
    result.add "phase_margin_deg", NaN, "deg"
    result.add "gain_margin_db", NaN, "dB"
    result.issues.add newIssue(KindLoopBreakInvalid, sevWarning,
      "breaking the loop at " & opamp & "'s inverting input did not open " &
      "it, so this sweep is not a loop transmission and no phase or gain " &
      "margin was taken from it: " & invalid.join("; ") & ". A second " &
      "feedback path is what this looks like -- a Sallen-Key returns its " &
      "first capacitor to the output, and that path stays closed across " &
      "this break. The closed-loop peaking is still measured and is a real " &
      "indicator; the margin is not available from here.",
      components = @[findComponent(nl, opamp)])
    return

  result.add "phase_margin_deg", pm, "deg"

  # Gain margin at the -180 degree crossing. One- or two-pole loops never
  # reach it, so it's often `NaN` rather than a large finite number.
  let f180 = interpCrossing(f, tPhase, -180.0, logX = true)
  if f180.isNaN:
    result.add "gain_margin_db", NaN, "dB"
  else:
    result.add "gain_margin_db", -valueAt(f, tDb, f180, logX = true), "dB"

  if pm < spec.minPhaseMargin:
    result.issues.add newIssue(KindLowPhaseMargin, sevWarning,
      "loop gain of " & opamp & " crosses 0 dB at " & eng(fx, "Hz") & " with only " &
      eng(pm, "deg") & " of phase margin, below the " & eng(spec.minPhaseMargin, "deg") &
      " minimum -- expect overshoot and ringing on a step",
      components = @[findComponent(nl, opamp)])


# --- large signal --------------------------------------------------------

proc analyzeLargeSignal*(nl: Netlist, opamp, inputNet, outputNet: string,
                         spec = defaultOpAmpSpec()): AnalysisReport =
  ## What the stage does when driven with a sine, for circuits whose
  ## nonlinearity is the point (clipping stages) -- `.ac` linearises it away.
  ##
  ## **The stimulus carries the node's own DC bias**, found by an `.op` on
  ## the same fragment: `SIN(0 ...)` would clamp a mid-rail input to zero,
  ## and coupling through a large capacitor makes settling take seconds.
  ##
  ## The macromodel has no slew-rate or output-current limit, so distortion
  ## measured here comes from the network (diodes, modelled parts) and the
  ## rail clamp only.
  result.name = "Large-signal response of " & opamp

  if findComponent(nl, opamp) == nil:
    raise newException(NetlistError, "no such component: " & opamp)
  for n in [inputNet, outputNet]:
    if findNet(nl, n) == nil:
      raise newException(NetlistError, "no such net: " & n)
  if spec.driveAmplitude <= 0.0:
    raise newException(NetlistError,
      "a large-signal run needs a drive amplitude; set spec.driveAmplitude")
  if spec.driveFreq <= 0.0:
    raise newException(NetlistError, "drive frequency must be positive")

  boundOpAmpsToRails = spec.boundToRails
  defer: boundOpAmpsToRails = false
  var p = prepare(nl, opamp, inputNet, outputNet, spec, bound = true)
  result.assumptions = p.assumptions

  let displaced = detachDrivers(p.frag, inputNet)
  if displaced.len > 0:
    result.assumptions.add note(displaced.join(", ") & " drove '" & inputNet &
      "' and was removed so the stage could be driven instead")

  # The bias the design gives the input, with nothing driving it.
  var bias = 0.0
  try:
    p.b.detached(displaced)
    p.b.focus(inputNet, outputNet)
    let op = p.b.run(@[".op"], label = "large signal bias:" & opamp)
    bias = op["v(" & inputNet & ")"][0]
  except CatchableError:
    result.assumptions.add note("the operating point of '" & inputNet &
      "' could not be found, so the drive sits on 0 V; on a single-supply " &
      "stage that biases the input into its own stop and every number " &
      "below is about a circuit in that state")

  let src = addComponent(p.frag, newComponent(
    $spiceFormat.designatorPrefix("voltage_source") & "DRIVE",
    kind = "voltage_source"))
  discard connect(src, "+", p.frag.nets[inputNet], ptPassive)
  discard connect(src, "-", p.gnd, ptPassive)
  src.attrs["value"] = "SIN(" & spiceFormat.spiceValue(bias) & " " &
    spiceFormat.spiceValue(spec.driveAmplitude) & " " &
    spiceFormat.spiceValue(spec.driveFreq) & ")"
  p.b.stimulus(src, "sine " & eng(spec.driveAmplitude, "V") & " at " &
               eng(spec.driveFreq, "Hz") & " on the input's own bias, into '" &
               inputNet & "'")
  p.b.probe(outputNet, "output swing, clipping and THD")

  let period = 1.0 / spec.driveFreq
  let settle = float(spec.driveSettlePeriods) * period
  let stop = settle + float(spec.drivePeriods) * period
  let step = period / float(spec.pointsPerPeriod)
  # `tstart` drops the settling transient from the saved data.
  let card = ".tran " & spiceFormat.spiceValue(step) & " " &
    spiceFormat.spiceValue(stop) & " " & spiceFormat.spiceValue(settle)

  try:
    result.raw = p.b.run(@[card], label = "large signal:" & opamp)
  except SpiceSimError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not drive the stage: " & e.msg)
    return

  let t = result.raw["time"]
  let vo = result.raw["v(" & outputNet & ")"]

  let sw = swing(vo)
  result.add "output_swing", sw.pp, "V"
  result.add "clip_high", sw.hi, "V"
  result.add "clip_low", sw.lo, "V"

  let d = thd(t, vo, spec.driveFreq, spec.thdHarmonics)
  result.add "thd_pct", d * 100.0, "%"

  # Gain at this drive level, from the fundamental alone; its difference
  # from `gain_at_f` is the compression.
  let amps = harmonicAmplitudes(t, vo, spec.driveFreq, spec.thdHarmonics)
  if amps.len > 0 and amps[0] > 0.0:
    result.add "gain_compressed_db",
      20.0 * log10(amps[0] / spec.driveAmplitude), "dB"
  else:
    result.add "gain_compressed_db", NaN, "dB"

  if not d.isNaN and d * 100.0 > spec.maxThd and spec.maxThd > 0.0:
    result.issues.add newIssue(KindExcessDistortion, sevWarning,
      "driven at " & eng(spec.driveAmplitude, "V") & " peak and " &
      eng(spec.driveFreq, "Hz") & ", " & opamp & " produces " &
      eng(d * 100.0, "%") & " total harmonic distortion",
      components = @[findComponent(nl, opamp)])
