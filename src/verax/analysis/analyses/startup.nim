## Power-rail start-up: rise, overshoot, and inrush into the output bank.
##
## Without a `simReplace`, the regulator becomes an ideal source on an
## assumed soft-start ramp, and this measures what the *output network* does
## (rise into the bank, overshoot, charging current). It is **not** a
## regulator model: no loop, current limit, dropout, load regulation or
## thermal behaviour. Assumptions are listed in the report; attach a vendor
## model via `simReplace` when the regulator's dynamics matter. `.tran` only.

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
    ## The state at t = 0. A ramp this analysis builds has no state, so an
    ## operating point is free and aids convergence. A regulator's own model
    ## soft-starts, and an operating point would start the `.tran` at the end
    ## of the ramp (a rise time of zero).
    ssAuto
      ## Solve the operating point unless the regulator brought its own
      ## model; then start from zero.
    ssOperatingPoint
      ## Always solve the operating point (a macromodel with no soft start
      ## that needs a bias to converge).
    ssZero
      ## Always `uic`: every node starts at zero, as at power-on.

  StartupSpec* = object
    targetV*: float
      ## Regulated output in volts; `0` reads `Net.attrs["voltage"]` on the
      ## output net and raises if absent.
    softStart*: float
      ## Assumed ramp time in seconds; only without a regulator `simReplace`.
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
      ## Flatten subcircuit instances first (default on); otherwise
      ## `spice/isolate` cuts each instance at its boundary.
    keepInstances*: seq[string]
      ## Instance paths `flatten` keeps intact, beyond the analysed part
      ## (added automatically) -- for a design's own subcircuit macromodel.
    modelUnmodelledParts*: bool
      ## Stand in for unmodelled parts around the fragment rather than leave
      ## them open. Never applied to the analysed part.
    startFrom*: StartupStart
      ## Where t = 0 is; see `StartupStart`.

proc defaultStartupSpec*(): StartupSpec =
  StartupSpec(targetV: 0.0, softStart: 1.0e-3, tStop: 0.0, tStep: 0.0,
              currentLimit: 0.0, overshootLimit: 0.05, settleTol: 0.02,
              maxHops: 3,
              pinModels: defaultPinModels(), flattenHierarchy: true,
              modelUnmodelledParts: true, startFrom: ssAuto)

proc downstreamRails(nl: Netlist, fromNet: string): seq[string] =
  ## Every rail the regulator's output reaches through passive parts. None
  ## is at nominal during start-up, so none may be terminated with an ideal
  ## source -- a filtered rail held stiff would drive current backwards into
  ## the ramping one (inflating inrush by orders of magnitude). The
  ## transient twin of `excludeRails` in `.ac`. The walk stops at the
  ## regulator, so its input rail keeps its source.
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
  ## Isolates `regulator` with its output rail, replaces it with a ramped
  ## source, and runs one `.tran`. `measureNet` (default `outputNet`) is
  ## where the rail is judged; with post-regulator filtering it can ring
  ## even though the regulator pin ramps cleanly.
  let measured = if measureNet.len > 0: measureNet else: outputNet
  result.name = "Start-up of '" & measured & "' from " & regulator

  # `findComponent`, so a hierarchical path works too.
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
  # Seed both nets (their capacitor banks are the point) and exclude them
  # from termination (an ideal source would clamp the ramp).
  var seedNets = @[outputNet]
  if measured != outputNet: seedNets.add measured
  # Downstream rails too: seeded so their banks count toward inrush,
  # excluded so they don't back-feed (see `downstreamRails`).
  for r in downstreamRails(nl, outputNet):
    if r notin seedNets: seedNets.add r
  isoSpec.excludeRails = seedNets
  isoSpec.requireKnownRails = false

  # Stand in for loads before isolating (`isolate` won't traverse undescribed
  # parts). The regulator is excluded: it's about to become the ramp.
  var cloneNets: OrderedTable[string, Net]
  # Clone, flatten, *then* `simReplace` (not `materializeSimNetlist`), so a
  # nested XSPICE regulator's ports use post-flatten names. `simReplace` is
  # honoured for everything but the regulator.
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
  # Same purpose as the materialise above.
  let sr = selectSimModel(regComp, spStartup)

  # The regulator's stand-in, by component: a `build` model may name it
  # anything.
  var standIn: Component = nil

  if sr != nil and sr.build != nil:
    # **The `build` route**: an XSPICE model needs a `.MODEL` card, an ordered
    # port binding and port text, which `kind`/`pinNets` can't express, so
    # the model supplies a proc.
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
    # A user-described regulator, verbatim except the designator (taken over
    # so the inrush probe knows the branch).
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

  # The inrush probe needs a stand-in pin on `outputNet` to split. A
  # `simReplace` names its own pins, and an XSPICE model's ports can't be
  # re-netted. A switching regulator usually has no such pin (the inductor
  # carries the current), so it reports no `inrush_peak`; everything else is
  # unaffected.
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

  # `uic` when the part starts itself (see `StartupStart`).
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

  # The probe's sign is wiring, so inrush is a magnitude.
  var pk = (t: NaN, v: NaN)
  if haveInrush:
    pk = peakAbs(t, result.raw[iProbe.label])
    # Probed at `outputNet`, which may differ from the assertion's net.
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
