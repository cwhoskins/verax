## Power-rail start-up: how fast a regulated rail comes up, whether it
## overshoots, and how much current the output capacitor bank pulls on the
## way (inrush).
##
## **What this measures, and what it does not.** A netlist names a regulator;
## it does not describe one. Unless the component carries a `simReplace`
## (see `verax/spice/transform`), this analysis substitutes an ideal source
## following an assumed soft-start ramp and then measures what the *output
## network* does in response: the RC/RLC rise of the rail into its capacitor
## bank and load, the overshoot that network produces, and the current the
## capacitors demand while charging.
##
## That is a real and frequently-asked question -- "how much inrush does my
## cap bank pull, and does the rail settle in time for the reset release" --
## and it is answerable from the netlist alone. It is **not** a model of the
## regulator: no control loop, no current limit or foldback, no dropout, no
## load regulation, no thermal behaviour. A rail that overshoots here would
## overshoot on a real board, but a rail that looks clean here can still
## misbehave for loop-stability reasons this cannot see. Every assumed value
## is listed in `AnalysisReport.assumptions`; attach a vendor macromodel via
## `simReplace` when the regulator's own dynamics matter.
##
## Unlike the frequency-domain analyses this needs no `.ac`, only `.tran`.

import std/[math, strutils, tables, sets]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/kinds
import ../../netlist/formats/spice as spiceFormat
import ../../spice/isolate
import ../../spice/models
import ../../spice/flatten
import ../../spice/probes
import ../../spice/transform
import ../../spice/ngspice
import ../measure
import ../report

export report

const
  KindDidNotReachTarget* = "startup_did_not_reach_target"
  KindOvershoot* = "startup_overshoot"
  KindInrushExceedsLimit* = "startup_inrush_exceeds_limit"
  KindSimulationFailed* = "startup_simulation_failed"

type
  StartupStart* = enum
    ## What the circuit looks like at t = 0, which for a start-up measurement
    ## is not a detail.
    ##
    ## A regulator this analysis stands up **itself** -- the assumed PWL ramp
    ## -- has no state of its own, so solving the operating point first is
    ## free and helps everything else in the fragment converge.
    ##
    ## A regulator that brought **its own model** is the opposite case: the
    ## whole reason to honour that model is that it soft-starts, and its soft
    ## start is state. Solving an operating point finds the state it settles
    ## *to* -- reference charged, output in regulation -- and the `.tran` then
    ## begins at the end of the ramp and reports a flat line. Measured on
    ## `designs/lt8640a_buck.nim`, that is a `rise_time_10_90` of zero for a
    ## part whose datasheet arithmetic says 4.08 ms.
    ssAuto
      ## Solve the operating point, unless the regulator stands itself up, in
      ## which case start from zero.
    ssOperatingPoint
      ## Always solve the operating point first. For a vendor macromodel that
      ## models no soft start and needs a bias to converge.
    ssZero
      ## Always `uic`: skip the operating-point solve and start every node at
      ## zero. Nothing is biased, which is the honest picture of a board at
      ## the instant power is applied and is wrong for anything already up.

  StartupSpec* = object
    targetV*: float
      ## Regulated output in volts. `0` means "read it from
      ## `Net.attrs["voltage"]` on the output net", and raise if absent.
    softStart*: float
      ## Assumed regulator ramp time in seconds. Only used when the regulator
      ## has no `simReplace` of its own.
    tStop*, tStep*: float
      ## `0` derives both from `softStart`.
    currentLimit*: float
      ## Amps; `0` disables the inrush check.
    overshootLimit*: float
      ## Fractional, e.g. `0.05` for 5%.
    settleTol*: float
      ## Fractional band for `settle_time`.
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
    startFrom*: StartupStart
      ## Where t = 0 is. See `StartupStart`; `ssAuto` is right for everything
      ## this analysis has been pointed at so far.

proc defaultStartupSpec*(): StartupSpec =
  StartupSpec(targetV: 0.0, softStart: 1.0e-3, tStop: 0.0, tStep: 0.0,
              currentLimit: 0.0, overshootLimit: 0.05, settleTol: 0.02,
              maxHops: 3,
              pinModels: defaultPinModels(), flattenHierarchy: true,
              modelUnmodelledParts: true, startFrom: ssAuto)

proc downstreamRails(nl: Netlist, fromNet: string): seq[string] =
  ## Every rail the regulator's output reaches through passive parts.
  ##
  ## During start-up *nothing* downstream of the regulator is at its nominal
  ## voltage -- a rail ramping from zero is the entire premise of the
  ## measurement. So a rail on this side must never be terminated with an
  ## ideal source at its nominal: a ferrite-filtered analog rail one hop from
  ## the output would be held stiff at 3.3 V while the rail feeding it ramps
  ## from zero, and would drive current backwards through the filter into it.
  ## Measured on a real design, that reported **2.8 kA** of inrush where the
  ## figure is 163 mA.
  ##
  ## This is the transient twin of what `IsolationSpec.excludeRails` already
  ## exists to prevent in `.ac`, where an ideal source is a dead short. The
  ## same field carries both; only the reason differs.
  ##
  ## The walk crosses `kinds.isPassive` parts only, so it stops dead at the
  ## regulator and never reaches the rail feeding its *input* -- which
  ## genuinely is up before start-up begins, and must keep its ideal source
  ## or there is nothing for the regulator to run from.
  var seen = toHashSet([fromNet])
  var queue = @[fromNet]
  while queue.len > 0:
    let netName = queue.pop()
    let net = nl.nets.getOrDefault(netName)
    if net == nil: continue
    if isRail(net) and not isGround(net) and netName notin result:
      result.add netName
    for pin in net.pins:
      let c = pin.component
      if c == nil or not isPassive(c): continue
      for _, other in c.pins:
        if other.net != nil and other.net.name notin seen:
          seen.incl other.net.name
          queue.add other.net.name

proc analyzeStartup*(nl: Netlist, regulator, outputNet: string,
                     measureNet = "", spec = defaultStartupSpec()): AnalysisReport =
  ## Isolates `regulator` together with everything on its output rail,
  ## replaces the regulator with a ramped source, and runs one `.tran`.
  ##
  ## `outputNet` is where the regulator drives; `measureNet` is where the
  ## rail is judged, defaulting to the same net. They differ whenever there
  ## is post-regulator filtering -- a ferrite bead or an LC to the load -- and
  ## that case is exactly where the interesting behaviour lives, because a
  ## series inductance into a capacitor bank is a resonant circuit that can
  ## ring the rail well past its target even though the regulator itself
  ## ramps monotonically. Measuring at the regulator pin would show a clean
  ## ramp and miss it entirely.
  let measured = if measureNet.len > 0: measureNet else: outputNet
  result.name = "Start-up of '" & measured & "' from " & regulator

  # `findComponent` rather than the flat key: a regulator on a board that is
  # instanced into a system is addressed by a `hierSep`-separated path, and
  # the flat key resolves first anyway, so one call serves an authored
  # hierarchy and a flattened one alike.
  let regComp = findComponent(nl, regulator)
  if regComp == nil:
    raise newException(NetlistError, "no such component: " & regulator)
  if not nl.nets.hasKey(outputNet):
    raise newException(NetlistError, "no such net: " & outputNet)
  if not nl.nets.hasKey(measured):
    raise newException(NetlistError, "no such net: " & measured)

  var targetV = spec.targetV
  if targetV == 0.0:
    if not nl.nets[measured].attrs.hasKey("voltage"):
      raise newException(NetlistError,
        "no regulated voltage for '" & measured & "': set StartupSpec.targetV " &
        "or Net.attrs[\"voltage\"]")
    try:
      targetV = parseFloat(nl.nets[measured].attrs["voltage"])
    except ValueError:
      raise newException(NetlistError,
        "unparseable voltage attr on net '" & measured & "'")
  if targetV == 0.0:
    raise newException(NetlistError, "regulated voltage must be non-zero")

  var isoSpec = defaultIsolationSpec("startup_" & measured)
  isoSpec.maxHops = spec.maxHops
  # Both nets must be expanded (the capacitor bank hanging off them is the
  # whole point) and neither may be terminated with an ideal source, which
  # would clamp the very ramp being measured. Seeding does the first,
  # excluding does the second.
  var seedNets = @[outputNet]
  if measured != outputNet: seedNets.add measured
  # Every rail the output feeds is also seeded and also left un-terminated.
  # Seeding is what pulls that rail's own capacitor bank into the fragment,
  # and the regulator really does have to charge it, so leaving it out
  # under-reports the inrush; excluding is what stops it being stood up as a
  # stiff source and back-feeding the rail it hangs off. See
  # `downstreamRails` for what that costs when it is not done.
  for r in downstreamRails(nl, outputNet):
    if r notin seedNets: seedNets.add r
  isoSpec.excludeRails = seedNets
  isoSpec.requireKnownRails = false

  # Stand in for the loads before isolating, for the same reason `analyzePdn`
  # does: `isolate` will not traverse a part nothing describes, so once it has
  # run there is nothing left to model. The regulator is excluded -- it is
  # about to be replaced by a soft-start ramp, and a generic stand-in applied
  # first would quietly overwrite the one thing this analysis is here for.
  var cloneNets: OrderedTable[string, Net]
  # Clone, flatten, *then* apply `simReplace` -- not the combined
  # `materializeSimNetlist` -- so a nested XSPICE regulator's `A`-line ports
  # are rendered from post-flatten net names rather than frozen at
  # child-template-local ones flatten is about to rename out from under it
  # (see `spice/flatten`'s module doc). `simReplace` is still honoured for
  # everything but the regulator: a component's own stand-in is the design's
  # statement of how it wants that part simulated, and this analysis used to
  # ignore it entirely.
  let work = clone(nl, cloneNets)
  discard flattenForSim(work, spec.flattenHierarchy, spec.keepInstances, regulator)
  applySimReplacements(work, [regulator], purpose = spStartup)
  if spec.modelUnmodelledParts:
    result.assumptions.add expandPinModels(work, spec.pinModels, [regulator])

  var globalNets: OrderedTable[string, Net]
  let iso = isolateFrom(work, [regulator], seedNets, isoSpec, globalNets)
  result.assumptions.add iso.assumptions
  let frag = iso.netlist
  if iso.dropped.len > 0:
    result.assumptions.add note("components " & iso.dropped.join(", ") &
      " were cut at the boundary: the current they would draw during start-up " &
      "is not represented")

  # --- stand the regulator up ------------------------------------------
  let outNet = frag.nets[outputNet]
  let gnd = frag.nets["0"]
  let srcDesig = $spiceFormat.designatorPrefix("voltage_source") & "REG_" & regulator
  # The same purpose the materialise above used, so the part stood up here is
  # the one that would have been stood up there had it not been excluded.
  let sr = selectSimModel(regComp, spStartup)

  # What ends up standing in for the regulator, whatever route it took there.
  # The inrush probe needs the component, not the designator, because a
  # `build` model names it whatever it likes.
  var standIn: Component = nil

  if sr != nil and sr.build != nil:
    # **The `build` route.** `kind`/`pinNets` cannot express an XSPICE code
    # model -- there is a `.MODEL` card to register, an ordered port binding,
    # and port text to render -- so a model that needs any of those supplies
    # a proc instead, and it is handed the netlist and the part to stand in
    # for. Going through `replaceComponent` here would have read an empty
    # `kind` and an empty `pinNets` and produced a device of no type wired to
    # nothing.
    let old = frag.components.getOrDefault(regulator)
    if old == nil:
      raise newException(NetlistError,
        "regulator " & regulator & " did not survive isolation, so its own " &
        "model cannot be applied to the fragment")
    standIn = sr.build(frag, old)
    result.assumptions.add note("regulator " & regulator &
      " modelled by its own simReplace '" & sr.name & "', which builds its " &
      "own stand-in rather than naming a device kind")
  elif sr != nil:
    # The user described the regulator themselves; honour it verbatim except
    # for the designator, which is taken over so the inrush probe knows which
    # branch to measure.
    var pinNets: seq[(string, Net)]
    for pinName, netName in sr.pinNets:
      if not frag.nets.hasKey(netName):
        raise newException(NetlistError,
          "simReplace on " & regulator & " names net '" & netName &
          "' which is not in the isolated fragment")
      pinNets.add (pinName, frag.nets[netName])
    var attrs: seq[(string, string)]
    for k, v in sr.attrs: attrs.add (k, v)
    standIn = replaceComponent(frag, regulator, sr.kind, pinNets,
                               newDesignator = srcDesig, attrs = attrs)
    result.assumptions.add note("regulator " & regulator &
      " modelled by its own simReplace (kind '" & sr.kind & "')")
  else:
    let pwl = "PWL(0 0 " & spiceValue(spec.softStart) & " " & spiceValue(targetV) & ")"
    standIn = replaceComponent(frag, regulator, "voltage_source",
                               [("+", outNet), ("-", gnd)],
                               newDesignator = srcDesig,
                               attrs = [("value", pwl)])
    result.assumptions.add assumption(
      "regulator " & regulator, "softStart", spec.softStart, "s", annDerived,
      "ramp to " & eng(targetV, "V") & " by an ideal source")
    result.assumptions.add note(
      "regulator " & regulator & " has no simReplace, so it was replaced by that source" &
      " (assumed soft-start; no control loop, current limit or dropout is modelled)")

  let vProbe = addVoltageProbe(frag.nets[measured])

  # **The inrush probe is conditional, and saying why is the point.** It works
  # by splitting a pin off its net and putting a 0 V source in the gap, which
  # needs a pin on the stand-in that actually sits on `outputNet`. The `"+"`
  # this used to assume is the pin of the PWL source *this* analysis builds,
  # and it is not a pin any other model has to have: a design's own
  # `simReplace` names its pins after the datasheet, and a code model's ports
  # cannot be re-netted at all -- an `A` line's port text is rendered from the
  # model spec rather than from the component's pins, so moving a pin would
  # move it in the graph and not in the deck. `spice/probes` refuses that
  # outright now; here it is avoided one step earlier.
  #
  # A switching regulator is the ordinary case of a part with no such pin: the
  # LT8640A drives a *switch node* into an inductor, so the current reaching
  # `vout` is the inductor's and not the part's. Reporting no `inrush_peak`
  # is the honest answer -- there is no single branch that carries the inrush
  # -- and every other measurement here is unaffected.
  var iProbe: Probe
  var haveInrush = false
  if standIn != nil and not standIn.attrs.hasKey("xspice.ports"):
    for _, pin in standIn.pins:
      if pin.net != nil and pin.net.name == outputNet:
        iProbe = addCurrentProbe(frag, pin)
        haveInrush = true
        break
  if not haveInrush:
    result.assumptions.add note("no inrush current was measured: " &
      (if standIn == nil: "nothing stood in for " & regulator
       elif standIn.attrs.hasKey("xspice.ports"):
         standIn.designator & " is a code model, whose ports cannot be " &
         "split to insert a probe"
       else:
         standIn.designator & " has no pin on net '" & outputNet & "', so " &
         "there is no single branch carrying the current into it"))

  let tStop = if spec.tStop > 0.0: spec.tStop else: spec.softStart * 5.0
  let tStep = if spec.tStep > 0.0: spec.tStep else: tStop / 2000.0
  var card = ".tran " & spiceValue(tStep) & " " & spiceValue(tStop)

  # `uic` where the part starts *itself*. See `StartupStart`: an operating
  # point solves the state the soft start settles to, so the run would begin
  # at the end of the ramp this analysis exists to measure.
  let uic = case spec.startFrom
            of ssOperatingPoint: false
            of ssZero: true
            of ssAuto: sr != nil
  if uic:
    card &= " uic"
    result.assumptions.add note(
      "the run starts from zero with uic rather than from a solved operating " &
      "point, because " & regulator & " brings its own model and that model's " &
      "soft start is the thing being measured -- an operating point would " &
      "find the state it settles to. Nothing in the fragment is biased at " &
      "t = 0, which is the right picture for a board at the instant power is " &
      "applied and wrong for anything that is already up")

  try:
    result.raw = run(frag, @[card], label = "startup:" & measured)
  except SpiceSimError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not run the isolated start-up fragment: " & e.msg)
    return

  let t = result.raw["time"]
  let v = result.raw[vProbe.label]

  let final = v[^1]
  result.add "final_v", final, "V"
  result.add "rise_time_10_90", riseTime(t, v, targetV), "s"
  result.add "overshoot_pct", overshootFrac(v, targetV) * 100.0, "%"
  result.add "settle_time", settleTime(t, v, targetV, spec.settleTol), "s"

  # The probe source's branch current is signed by which pin was split, which
  # is an artefact of probe wiring rather than anything about the circuit, so
  # inrush is reported as a magnitude.
  var pk = (t: NaN, v: NaN)
  if haveInrush:
    pk = peakAbs(t, result.raw[iProbe.label])
    # Probed on the source feeding `outputNet`, which is not necessarily the
    # net the assertion names -- see `Measurement.at`.
    result.add "inrush_peak", abs(pk.v), "A", at = "net '" & outputNet & "'"
    result.add "t_inrush_peak", pk.t, "s", at = "net '" & outputNet & "'"

  # --- issues ------------------------------------------------------------
  if abs(final - targetV) > abs(targetV) * spec.settleTol:
    result.issues.add newIssue(KindDidNotReachTarget, sevError,
      "'" & measured & "' ended at " & eng(final, "V") & " rather than the expected " &
      eng(targetV, "V") & " -- the isolated fragment is loaded differently from the " &
      "real design, or the run is too short; every other measurement here is " &
      "unreliable until that is resolved", net = nl.nets[measured])

  let over = overshootFrac(v, targetV)
  if over > spec.overshootLimit:
    result.issues.add newIssue(KindOvershoot, sevWarning,
      "'" & measured & "' overshoots to " & eng(final * (1.0 + over), "V") & " (" &
      eng(over * 100.0) & "% above " & eng(targetV, "V") & "), past the " &
      eng(spec.overshootLimit * 100.0) & "% limit", net = nl.nets[measured])

  if haveInrush and spec.currentLimit > 0.0 and abs(pk.v) > spec.currentLimit:
    result.issues.add newIssue(KindInrushExceedsLimit, sevWarning,
      "inrush peaks at " & eng(abs(pk.v), "A") & " at " & eng(pk.t, "s") &
      ", above the " & eng(spec.currentLimit, "A") & " limit -- a regulator that " &
      "current-limits here will start up more slowly than this run shows, since no " &
      "current limit is modelled", net = nl.nets[measured])
