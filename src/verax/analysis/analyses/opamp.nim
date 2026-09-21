## Op-amp stage analysis: does the feedback network exist, what closed-loop
## gain and bandwidth does it actually give, and how much stability margin is
## left.
##
## Three separate questions, deliberately answered by three procs, because
## they cost different amounts and are wrong in different ways if conflated:
##
## * `checkFeedback` -- a pure graph walk, no simulation. An amplifier with no
##   path from its output back to its inverting input is not an amplifier.
## * `analyzeOpAmpResponse` -- one `.ac` sweep of the **closed-loop**
##   response: DC gain, -3 dB bandwidth, and closed-loop peaking.
## * `analyzeLoopGain` -- one `.ac` sweep of the **loop gain**, by breaking
##   the loop at the inverting input and injecting there. This is the only
##   one of the three that yields a real phase margin.
##
## **Why phase margin is not read off the closed-loop curve.** Phase margin
## is a property of the loop gain `Aol*beta` at its 0 dB crossing. The
## closed-loop response is `Aol/(1+Aol*beta)`, a different function with a
## different phase; reading "180 + phase at unity gain" off it gives a number
## that looks like a phase margin, moves in roughly the right direction, and
## is not one. So `analyzeOpAmpResponse` reports *peaking* instead -- a real
## and honest closed-loop stability indicator, since a peak in the closed-loop
## magnitude is exactly what low phase margin produces -- and the actual
## margin comes from `analyzeLoopGain`, which measures the loop.
##
## When the op-amp component carries no model of its own, a single-pole ideal
## macromodel (`verax/spice/models.idealOpAmp`) is substituted and recorded
## as an assumption. Read the caveats on that proc: it has one pole and no
## output impedance, so it can show you what your *feedback network* does but
## never what a specific part will do.

import std/[complex, math, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/kinds
import ../../netlist/formats/spice as spiceFormat
import ../../spice/isolate
import ../../spice/transform
import ../../spice/models
import ../../spice/flatten
import ../../spice/ngspice
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
      ## Volts peak of the sine a large-signal run drives the stage with.
      ## `0` disables that analysis entirely.
    driveFreq*: float
      ## Hz of that sine.
    drivePeriods*: int
      ## Whole periods kept after settling. More is a better THD floor and a
      ## longer run; the window is always a whole number of them.
    driveSettlePeriods*: int
      ## Periods simulated and discarded before measuring, so a coupling or
      ## bias network has finished charging.
    pointsPerPeriod*: int
      ## Requested `.tran` timestep, as a divisor of the period. ngspice
      ## takes smaller steps where it needs them, which is why the harmonic
      ## integration reads timestamps rather than assuming a grid.
    thdHarmonics*: int
      ## How many harmonics above the fundamental enter the THD sum.
    maxThd*: float
      ## Percent of THD tolerated before it is flagged; `0` disables.
    boundToRails*: bool
      ## Clamp the substituted macromodel's output to the amplifier's stated
      ## supply rails. On by default: an unbounded output cannot saturate, so
      ## a stage running out of swing would measure perfectly clean. Has no
      ## effect when the rails state no voltage, which is what
      ## `io_check.checkRailVoltages` is there to catch.
    vsatHeadroom*: float
      ## Volts by which the part stops short of each rail. `0` means it
      ## saturates exactly at them, which no real amplifier does -- it makes
      ## the model an upper bound on swing rather than a prediction of it.
    gainAtFreq*: float
      ## Hz; when > 0 the response sweep also reports `gain_at_f`, the gain
      ## at exactly this frequency. `0` disables it. This is how a claim
      ## states the one number an audio stage is actually specified by --
      ## "20 dB at 1 kHz" -- rather than inferring it from a corner.
    maxHops*: int
    pinModels*: PinModelDefaults
    flattenHierarchy*: bool
      ## Dissolve subcircuit instances into the top level before anything
      ## else touches the netlist. On by default: left un-flattened, every
      ## instance is cut at its boundary by `spice/isolate` and no model pass
      ## reaches inside one. Off restores the older behaviour.
    keepInstances*: seq[string]
      ## Instance paths `flatten` must leave intact, beyond the part this
      ## analysis was named for (which is added automatically). For a design
      ## that brings its own subcircuit macromodel and expects it honoured.
    modelUnmodelledParts*: bool
      ## Stand in for the parts around this fragment that carry no model, so
      ## the simulation sees something where they sit rather than an open
      ## circuit. The part this analysis is *about* is never touched by it --
      ## that one is modelled deliberately further down.

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
  ## Locates the non-inverting input, inverting input and output by name.
  ##
  ## `Pin.kind` cannot do this -- it distinguishes input from output but not
  ## `+` from `-`, and that distinction is the entire content of "negative
  ## feedback". So this matches names, tolerantly (`+`/`IN+`/`INP`/... and the
  ## inverting and output equivalents, case-insensitively), and raises naming
  ## the pins actually present rather than guessing when none match.
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
  ## Breadth-first walk over nets, crossing only components whose behaviour is
  ## fully described by their value.
  ##
  ## Blocking parts count: a capacitor from output to inverting input is an
  ## integrator, which is negative feedback at every frequency that matters
  ## even though it is an open circuit at DC. Requiring a DC-conductive path
  ## would report every integrator and every AC-coupled stage as broken.
  ##
  ## A part with a *signal-passing* behavioural model counts too, and only
  ## because of what that registration means. The reason to exclude an active
  ## device is that its gain and direction are part of the loop and unknown
  ## here -- but for a registered kind they are known: the direction is
  ## input-to-output and the gain is unity or whatever `gain` states. So the
  ## walk crosses one, and crosses it **forwards only**, entering at the
  ## input pin and leaving at the output. Refusing would be worse than
  ## pedantic: `spice/models` is about to build that path for the simulation,
  ## and a static check calling the loop open while the .ac closes it makes
  ## the two disagree about the same circuit.
  ##
  ## `stopAtRails` refuses to traverse *through* a power or ground net, the
  ## same rule `spice/isolate` applies for the same reason: a rail is an AC
  ## ground that every stage on the board hangs off, so a walk that crosses
  ## one connects things that are not connected in any signal sense. It is
  ## off by default because `checkFeedback` genuinely wants the permissive
  ## walk -- a feedback network returning through a bias rail is unusual but
  ## not impossible -- and on for the injection test, where crossing a rail
  ## is always a false positive. The TS808's drive stage is the case that
  ## settled it: `vout` reaches `vamp` through the 47 uF-bypassed 4.5 V bias
  ## rail, which is not feedback and never was.
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
        # Forwards only: entered at the input, leave at the output. Walking
        # an amplifier backwards would find a path no signal can take.
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
  ## Static check, no simulation: is there a path from the output back to the
  ## inverting input through passives only?
  ##
  ## "Through passives only" is what makes this a *feedback* test rather than
  ## a connectivity test -- a path that leaves through another active device
  ## is not a feedback path, because that device's own gain and direction are
  ## part of the loop and unknown here.
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
  ## Whether driving `inputNet` would destroy the very loop being measured.
  ##
  ## Every `.ac` proc here works by hanging an ideal source on the stage's
  ## input net. An ideal source **holds that node**, so anything else feeding
  ## it is overridden -- which is exactly what you want at an input and
  ## catastrophic at a node the feedback returns to. The failure is silent:
  ## the sweep succeeds, the numbers are self-consistent, and they describe
  ## the forward path of a circuit whose loop has been cut.
  ##
  ## A Wien-bridge oscillator is the clean case. Its positive feedback lands
  ## directly on `IN+`; drive there and the whole R-C bridge is shorted out,
  ## and what gets measured is a flat gain of 3.2 rolling off at GBW/3.2.
  ## Measured, that reported `f_hi_3db` as **289 kHz** for a circuit whose
  ## entire behaviour happens at 1.59 kHz, and every claim made about it
  ## passed. A wrong number that passes is worse than no number.
  ##
  ## The test is a **conjunction**, and both halves are needed:
  ##
  ## * the driven net is one of the amplifier's own input pins' nets, and
  ## * there is a passive path from the output back to it.
  ##
  ## Either alone over-triggers. An ordinary inverting amplifier's input net
  ## reaches the output through `Rin` + `Rf`, so reachability alone would flag
  ## it -- but that net is not an op-amp pin, and driving it is correct. A
  ## non-inverting amplifier's input *is* `IN+`, so the pin test alone would
  ## flag it -- but nothing feeds back to `IN+`, so driving it is also
  ## correct. Only when both hold is the injection point inside the loop.
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
  frag: Netlist
  negPin: Pin
  posNet, outNet, gnd: Net
  assumptions: seq[Assumption]

proc prepare(nl: Netlist, opamp, inputNet, outputNet: string,
             spec: OpAmpSpec, bound = false): Prepared =
  ## Isolates the stage and makes sure there is an op-amp model in it.
  ##
  ## `bound` clamps the substituted macromodel to the amplifier's supply
  ## rails, and **only a large-signal caller asks for it**. Saturation is a
  ## large-signal idea: `.ac` linearises the circuit about its operating
  ## point, and the clamp is `min(max(...))`, whose derivative at the clamp
  ## is zero -- so an `.ac` sweep of a stage whose operating point sits on a
  ## rail comes back with no gain at all rather than with the small-signal
  ## gain it has. A single-supply stage with a ground-referenced input sits
  ## exactly there, so this is not a corner case.
  var isoSpec = defaultIsolationSpec("opamp_" & opamp)
  isoSpec.maxHops = spec.maxHops
  isoSpec.requireKnownRails = false
  # The signal nets must never be terminated with an ideal source: the input
  # gets the stimulus and the output is what is being measured.
  isoSpec.excludeRails = @[inputNet, outputNet]

  # Before isolating, so that a part in or around the loop is stood in for
  # rather than refused and cut. A buffer in the feedback path is the case
  # that matters: cut away, the loop is open, and a loop-gain figure measured
  # over an open loop is a confident number about a different circuit.
  var cloneNets: OrderedTable[string, Net]
  # Clone, flatten, *then* apply `simReplace` -- not the combined
  # `materializeSimNetlist` -- so a nested XSPICE component's `A`-line ports
  # are rendered from post-flatten net names rather than frozen at
  # child-template-local ones flatten is about to rename out from under it
  # (see `spice/flatten`'s module doc). `simReplace` is still honoured: a
  # component's own stand-in is the design's statement of how it wants that
  # part simulated, and this analysis used to ignore it entirely.
  # `bound` is what tells a large-signal caller apart from a small-signal
  # one, and it is also the only thing here that knows which purpose a part
  # carrying several models should be stood in for under.
  let work = clone(nl, cloneNets)
  discard flattenForSim(work, spec.flattenHierarchy, spec.keepInstances, opamp)
  applySimReplacements(work, purpose = (if bound: spLargeSignal else: spSmallSignal))

  # Read *after* flattening, and from the work copy. An amplifier inside a
  # subcircuit has pins on the child's own nets, whose names mean nothing at
  # the top level -- `amp` inside two instances is two different nodes. Once
  # flattened those pins sit on `XL.amp` and `XR.amp`, which is what the
  # fragment will be keyed by. Still before isolation, so the rails read here
  # are the design's and not the terminations about to replace them.
  let pins = findOpAmpPins(findComponent(work, opamp))

  if spec.modelUnmodelledParts:
    result.assumptions.add expandPinModels(work, spec.pinModels, [opamp])

  var globalNets: OrderedTable[string, Net]
  let iso = isolateFrom(work, [opamp], [inputNet, outputNet], isoSpec, globalNets)
  result.frag = iso.netlist
  result.assumptions.add iso.assumptions
  if iso.dropped.len > 0:
    result.assumptions.add note("components " & iso.dropped.join(", ") &
      " were cut at the boundary: any loading they present is not represented")

  result.gnd = result.frag.nets["0"]
  result.posNet = result.frag.nets[pins.pos.net.name]
  result.outNet = result.frag.nets[outputNet]
  let negNet = result.frag.nets[pins.neg.net.name]

  if result.frag.components[opamp].subNetlist != nil:
    # The design brought its own macromodel; use it untouched.
    result.negPin = findOpAmpPins(result.frag.components[opamp]).neg
  else:
    # Bounded to the part's supply rails when the design states them. Read
    # from the pre-isolation work copy, since the fragment's rails have
    # already been terminated.
    let rails = supplyRailsOf(findComponent(work, opamp))
    let clamp = bound and rails.known and spec.boundToRails
    let vHi = if clamp: rails.hi - spec.vsatHeadroom else: Inf
    let vLo = if clamp: rails.lo + spec.vsatHeadroom else: -Inf

    # A stated `gbw` beats the package default. The default is 1 MHz and a
    # real precision part is ten times that, which on a 40 dB stage is 0.7 dB
    # of gain at 1 kHz -- more than the entire accuracy budget of an
    # equalisation network, and invisible unless it can be stated.
    let statedGbw = annotationFloat(findComponent(work, opamp), "gbw")
    let gbw = if statedGbw.has and statedGbw.value > 0.0: statedGbw.value
              else: spec.idealGbw
    removeComponent(result.frag, opamp)
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
    let inst = instantiate(result.frag, "X" & opamp, tmpl,
                           @[result.posNet, negNet, result.outNet], globalNets)
    result.negPin = inst.pins["INN"]
    if not (statedGbw.has and statedGbw.value > 0.0):
      result.assumptions.add assumption(
        opamp, "gbw", gbw, "Hz", annDerived,
        "of a substituted ideal single-pole op-amp (Aol " & eng(spec.idealAol) &
        "); no offset, slew rate, output impedance, supply rails or second " &
        "pole are represented. State `gbw` on the part to use its own")

proc detachDrivers(frag: Netlist, netName: string): seq[string] =
  ## Removes anything already driving `netName` with a low impedance.
  ##
  ## Driving a stage "at its input" means replacing whatever feeds it with an
  ## ideal stimulus -- that is what the measurement is. It only became
  ## necessary once a *preceding* stage started being stood up as a
  ## macromodel instead of cut away: that stage's output is a VCVS, and
  ## putting the sweep's own source across a VCVS output is two ideal sources
  ## on one node. ngspice answers that with a singular matrix, which this
  ## module surfaced as `key not found: frequency` -- an error about a
  ## missing vector, three steps removed from the cause.
  ##
  ## Only genuinely stiff drivers are removed. A stage fed through a coupling
  ## capacitor or a series resistor is not driven by anything here, and
  ## nothing is touched.
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

  # A stage with no feedback has no closed-loop response to measure, so this
  # returns the structural finding rather than simulating an open-loop circuit
  # and reporting its (meaningless) numbers.
  let fb = checkFeedback(nl, opamp)
  if fb.len > 0:
    result.issues = fb
    return

  # Driving a node the feedback returns to measures a circuit that is not
  # this one, and does it without failing, so it is checked before the sweep
  # rather than second-guessed after it.
  let injIssues = checkInjectionPoint(nl, opamp, inputNet)
  if injIssues.len > 0:
    result.issues = injIssues
    return

  let p = prepare(nl, opamp, inputNet, outputNet, spec)
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

  try:
    result.raw = run(p.frag, @[acCard(spec)],
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

  # The band-referenced half of the answer, for a stage that is AC coupled
  # and therefore has no meaningful gain at DC.
  #
  # `gain_dc_db`, `bw_3db` and `peaking_db` above are all referenced to the
  # *first swept point*, which is right for a DC-coupled low-pass and is the
  # stopband of every single-supply stage -- there the gain-setting leg is
  # capacitively coupled, so the gain at DC is unity by construction. The
  # TS808 drive stage reports `gain_dc_db` of 0.001 dB against a real
  # midband gain of 32, and a `bw_3db` of 710 kHz measured 3 dB below
  # *unity*, on the far side of its own hump. Both numbers are arithmetically
  # correct and answer nothing.
  #
  # These four are referenced to the response's maximum instead, so they say
  # what the stage does rather than what it does at DC. Nothing is removed:
  # the DC-referenced set stays exactly as it was, because for a DC-coupled
  # stage it is the right question and the two agree.
  let (gMaxDb, gMaxHz) = gainMax(f, g)
  result.add "gain_max_db", gMaxDb, "dB"
  result.add "f_gain_max", gMaxHz, "Hz"
  let edges = bandEdges(f, g)
  result.add "f_lo_3db", edges.lo, "Hz"
  result.add "f_hi_3db", edges.hi, "Hz"

  # `NaN` when the stated frequency is outside the swept band, which reads as
  # "could not check" rather than as a pass: extrapolating a response past
  # what was simulated would be inventing data.
  if spec.gainAtFreq > 0.0:
    result.add "gain_at_f", valueAt(f, g, spec.gainAtFreq, logX = true), "dB"

  # Peaking: how far the closed-loop magnitude rises above its DC value. A
  # well-damped stage has none; a peak is what insufficient phase margin
  # looks like from outside the loop.
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
  ## injecting a test signal across the break.
  ##
  ## The break is made at the amplifier's own inverting input because that is
  ## a low-impedance-drives-high-impedance point: the feedback network drives
  ## it and the op-amp input barely loads it, so inserting a series source
  ## there does not disturb the loading the loop actually sees. Injecting at a
  ## point where impedances are comparable would measure a loop that is not
  ## the real one.
  ##
  ## With the source inserted between the feedback network (node A) and the
  ## amplifier input (node B), the loop gain is `T = -V(A)/V(B)`; the sign
  ## accounts for the inversion the op-amp itself contributes, so `T` comes
  ## out as the conventional positive `Aol*beta`.
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

  # Driving a node the feedback returns to measures a circuit that is not
  # this one, and does it without failing, so it is checked before the sweep
  # rather than second-guessed after it.
  let injIssues = checkInjectionPoint(nl, opamp, inputNet)
  if injIssues.len > 0:
    result.issues = injIssues
    return

  let p = prepare(nl, opamp, inputNet, outputNet, spec)
  result.assumptions = p.assumptions

  # Break the loop: the feedback network keeps the original net (A), the
  # amplifier input moves to a fresh one (B).
  let netA = p.negPin.net
  let netB = addNet(p.frag, newNet("LOOP_INJ", ntSignal))
  disconnect(p.negPin)
  connect(p.negPin, netB)

  # The input source is set to zero while the loop is measured -- the only
  # excitation must be the injected one, or the response would be a mixture of
  # the loop gain and the closed-loop response.
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

  try:
    result.raw = run(p.frag, @[acCard(spec)], label = "loop gain:" & opamp)
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
    # Nothing to report a margin against; say so rather than inventing one.
    result.add "phase_margin_deg", NaN, "deg"
    result.add "gain_margin_db", NaN, "dB"
    return

  let phaseAtX = valueAt(f, tPhase, fx, logX = true)
  let pm = 180.0 + phaseAtX

  # --- is this actually a loop transmission? -----------------------------
  #
  # `180 + phase at crossover` is the phase margin *of a loop the break
  # opened*. Breaking at the inverting input opens the only feedback path a
  # plain amplifier has, and for those this is exact: a unity-gain follower
  # and a gain-of-2 stage both measure 90 degrees against an ideal
  # single-pole model.
  #
  # It is not exact for a topology with a second path. A Sallen-Key returns
  # its first capacitor to the *output*, and that positive path stays closed
  # across this break -- so the measured ratio is not a loop transmission.
  # Its phase starts near +79 degrees instead of 0 and climbs through +180
  # while the magnitude is still above 0 dB, and `180 + phase` then reports
  # **450 degrees**: not a phase margin, and one that satisfies every
  # minimum a design could state. A stability claim that cannot fail is
  # worse than no stability claim, so the three signatures of that are
  # checked here and the margin is withheld rather than invented. `NaN`
  # reads as "could not check" everywhere downstream, which is the honest
  # answer -- and it is deliberately not a *failure*, because the circuit
  # may well be fine; it is this measurement that cannot say.
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

  # Gain margin: how far below 0 dB the loop gain has fallen by the time its
  # phase reaches -180. A one- or two-pole loop approaches -180 degrees
  # asymptotically without reaching it, so there is often no such frequency;
  # that is reported as NaN rather than as a large finite margin.
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
  ## What the stage does when it is *driven*, rather than what its transfer
  ## function is.
  ##
  ## Everything else in this module is small-signal: `.ac` linearises the
  ## circuit about its operating point, so a clipping diode is whatever
  ## conductance it happens to have at rest and never actually clips. That is
  ## the right model for gain, bandwidth and stability and it is the wrong
  ## one for an overdrive pedal, where the clipping *is* the product. This
  ## drives a sine in and measures what comes out.
  ##
  ## **The stimulus carries the node's own DC bias, and that is not a
  ## detail.** A single-supply stage sits at some mid-rail operating point;
  ## hanging a `SIN(0 ...)` source off its input would clamp that node to
  ## zero and measure a circuit biased into its own stop. So an operating
  ## point is found first, on the same fragment, and the sine is offset onto
  ## it. The alternative -- coupling the source through a large capacitor --
  ## keeps the bias but makes the settling time constant the input
  ## resistance times that capacitor, which is seconds for an ordinary input
  ## network and turns a millisecond run into an unusable one.
  ##
  ## What this still does not model: the substituted op-amp macromodel has
  ## no slew-rate limit, no output current limit and no supply rails, so it
  ## will not clip on its own. Distortion measured here is distortion the
  ## *network* produces -- diodes, saturating parts, anything with a real
  ## model. A stage whose only nonlinearity is the amplifier running out of
  ## swing will read as clean, and that is a limit of the model rather than
  ## a finding about the circuit.
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
  let p = prepare(nl, opamp, inputNet, outputNet, spec, bound = true)
  result.assumptions = p.assumptions

  let displaced = detachDrivers(p.frag, inputNet)
  if displaced.len > 0:
    result.assumptions.add note(displaced.join(", ") & " drove '" & inputNet &
      "' and was removed so the stage could be driven instead")

  # The operating point the stimulus has to sit on. Found on the fragment
  # with nothing driving the input yet, which is the bias the design gives
  # that node.
  var bias = 0.0
  try:
    let op = run(p.frag, @[".op"], label = "large signal bias:" & opamp)
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

  let period = 1.0 / spec.driveFreq
  let settle = float(spec.driveSettlePeriods) * period
  let stop = settle + float(spec.drivePeriods) * period
  let step = period / float(spec.pointsPerPeriod)
  # `tstart` discards the settling transient from the saved data rather than
  # from the simulation, so the window handed to the harmonic integration is
  # already steady-state.
  let card = ".tran " & spiceFormat.spiceValue(step) & " " &
    spiceFormat.spiceValue(stop) & " " & spiceFormat.spiceValue(settle)

  try:
    result.raw = run(p.frag, @[card], label = "large signal:" & opamp)
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

  # Gain *at this drive level*, from the fundamental alone -- which is what
  # separates it from the small-signal figure. A stage that is compressing
  # has a fundamental smaller than its linear gain would give, and the
  # difference between this and `gain_at_f` is the compression.
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
