## Evaluators that answer from the graph alone -- no simulator. Registered
## through the ordinary `registerEvaluator` path.
##
## `controller_count` can't be derived from topology (every I2C device has
## an inout data pin), so without a role binding it is `esNotEvaluable`.
## `rc_corner` rests on an invented per-pin capacitance, reported as an
## `Assumption`.

import std/[math, sets, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/kinds
import ../../netlist/interfaces
import ../../netlist/annotations
import ../../units
import ../../netlist/formats/spice as spiceFormat
import ../evaluate

export evaluate

const
  assumedPinCapacitance* = 10.0e-12
    ## Farads per connected pin, for a bus whose capacitance nothing states.
    ## Always invented and reported as an assumption. (The I2C spec caps the
    ## total at 400 pF, a limit rather than a typical.)

proc allPins(net: Net): seq[Pin] =
  ## `net.pins` widened to pins on any net that is the same conductor
  ## through an instance boundary (`graph.hierNetGroup`), so a pull-up nested
  ## behind a pass-through port counts. `dcConnected` doesn't need it (it
  ## crosses hierarchy as it walks).
  for n in hierNetGroup(net):
    for p in n.pins: result.add p

proc railOf(p: Pin): Net =
  ## The net across a two-terminal part from `p`, when it is a rail.
  let c = p.component
  for _, other in c.pins:
    if other == p: continue
    if other.net != nil and isRail(other.net): return other.net
  nil

proc pullupsOn(net: Net): seq[Component] =
  ## Every resistor with one end on `net` and the other on a rail (pull-up or
  ## pull-down alike). Deduped by **component identity**, not designator:
  ## sibling instances can each have an `R1`.
  var seen: seq[Component]
  for p in allPins(net):
    let c = p.component
    if c == nil or c.kind != "resistor": continue
    if c in seen: continue
    if railOf(p) != nil:
      seen.add c
      result.add c

proc capacitorsOn(net: Net): seq[Component] =
  ## Deduped by component identity, as in `pullupsOn`.
  var seen: seq[Component]
  for p in allPins(net):
    let c = p.component
    if c == nil or c.kind != "capacitor": continue
    if c in seen: continue
    seen.add c
    result.add c

proc magnitudeOf(c: Component, value: var float): bool =
  ## A resistor's or capacitor's value as a number (only parts whose `value`
  ## is a bare magnitude; see `parseSpiceMagnitude`).
  if not c.attrs.hasKey("value"): return false
  parseSpiceMagnitude(c.attrs["value"], value)

# --- pullup_count -------------------------------------------------------

proc runPullupCount(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  for a in batch:
    let net = netSubject(d, a)
    if net.isNone:
      result.add notEvaluable(a, "static.pullup_count",
        "subject is not a net in this design")
      continue
    result.add verdict(a, float(pullupsOn(net.get).len), "",
                       "static.pullup_count")

# --- pullup_sink_current ------------------------------------------------

const i2cVol = 0.4
  ## The I2C spec's output-low voltage; a constant, not a design choice.

proc runPullupSinkCurrent(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  ## How much current whatever pulls the line low must sink -- the
  ## too-strong bound that `pullup_count` and `rc_corner` (too weak/slow)
  ## don't cover. I2C requires VOL <= 0.4 V at 3 mA, so ~1 kohm minimum at
  ## 3.3 V; the RC ceiling squeezes from the other side. Each pull-up is
  ## charged against the rail it actually terminates on.
  let d = ctx.design
  const name = "static.pullup_sink_current"
  for a in batch:
    let netOpt = netSubject(d, a)
    if netOpt.isNone:
      result.add notEvaluable(a, name, "subject is not a net in this design")
      continue
    let net = netOpt.get

    let pullups = pullupsOn(net)
    if pullups.len == 0:
      result.add notEvaluable(a, name,
        "net '" & net.name & "' has no pull-up, so nothing has to sink " &
        "anything to pull it low; pullup_count reports that separately")
      continue

    var total = 0.0
    var unreadable: seq[string]
    for r in pullups:
      var ohms: float
      var railNet: Net = nil
      for _, pin in r.pins:
        if pin.net != nil and pin.net != net and isRail(pin.net):
          railNet = pin.net
      let v = if railNet != nil: railVoltage(railNet)
              else: absent(Volts)
      if not magnitudeOf(r, ohms) or ohms <= 0.0:
        unreadable.add r.designator & " (no readable resistance)"
      elif not v.has:
        unreadable.add r.designator & " (rail '" &
          (if railNet != nil: railNet.name else: "?") & "' states no voltage)"
      else:
        total += max(float(v.value) - i2cVol, 0.0) / ohms

    if unreadable.len > 0:
      result.add notEvaluable(a, name,
        "cannot work out the sink current for " & unreadable.join(", ") &
        " -- this needs both the pull-up's resistance and its rail's " &
        "nominal voltage, and neither is guessed at")
      continue

    result.add verdict(a, total, "A", name)

# --- rc_corner ----------------------------------------------------------

proc runRcCorner(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  for a in batch:
    let netOpt = netSubject(d, a)
    if netOpt.isNone:
      result.add notEvaluable(a, "static.rc_corner",
        "subject is not a net in this design")
      continue
    let net = netOpt.get

    let pullups = pullupsOn(net)
    if pullups.len == 0:
      result.add notEvaluable(a, "static.rc_corner",
        "net '" & net.name & "' has no pull-up resistor, so it has no RC " &
        "corner to measure; pullup_count reports that separately")
      continue

    # Parallel conductance of everything pulling the line up.
    var conductance = 0.0
    var unparseable: seq[string] = @[]
    for r in pullups:
      var ohms: float
      if not magnitudeOf(r, ohms) or ohms <= 0.0:
        unparseable.add r.designator & " = " &
          (if r.attrs.hasKey("value"): r.attrs["value"].escape() else: "(unset)")
      else:
        conductance += 1.0 / ohms
    if unparseable.len > 0:
      result.add notEvaluable(a, "static.rc_corner",
        "cannot read a resistance from " & unparseable.join(", ") &
        " -- a value like \"2k2\" is read by ngspice as 2000, not 2200, so " &
        "it is refused rather than guessed at; state it as \"2200\"")
      continue
    if conductance <= 0.0:
      result.add notEvaluable(a, "static.rc_corner",
        "the pull-ups on '" & net.name & "' sum to zero conductance")
      continue

    var farads = 0.0
    var assumptions: seq[Assumption] = @[]
    for c in capacitorsOn(net):
      var f: float
      if magnitudeOf(c, f) and f > 0.0: farads += f

    let busPins = allPins(net)
    let pinLoad = float(busPins.len) * assumedPinCapacitance
    farads += pinLoad
    assumptions.add assumption(net.name, "bus_capacitance", pinLoad, "F",
      annDefaulted,
      "assumed " & $(assumedPinCapacitance * 1.0e12) & " pF for each of " &
      $busPins.len & " connected pins; a netlist carries neither trace nor " &
      "device pin capacitance")

    let resistance = 1.0 / conductance
    let corner = 1.0 / (2.0 * PI * resistance * farads)
    result.add verdict(a, corner, "Hz", "static.rc_corner", assumptions)

# --- dc_path_exists ----------------------------------------------------

proc dcConnected(a, b: Net): bool =
  ## Is there a DC-conductive path from `a` to `b`? BFS across conductive pin
  ## pairs (`conductiveExits`) and hierarchy boundaries, stopping at `b`.
  ## Ambiguous parts (diodes, ICs, transformers) are never crossed -- the
  ## isolation-barrier check -- while a declared `traverse:` spec is honoured.
  if a == b: return true
  var visited: seq[Net] = @[a]
  var queue: seq[Net] = @[a]
  var qi = 0
  while qi < queue.len:
    let net = queue[qi]
    inc qi
    for p in net.pins:
      let comp = p.component
      if comp == nil: continue
      if comp.subNetlist != nil:
        if p.hierNet != nil and p.hierNet notin visited:
          if p.hierNet == b: return true
          visited.add p.hierNet
          queue.add p.hierNet
        continue
      for exitNet in conductiveExits(comp, p):
        if exitNet == b: return true
        if exitNet notin visited:
          visited.add exitNet
          queue.add exitNet
    if net.netlist != nil and net.netlist.instanceOf != nil:
      for _, pp in net.netlist.instanceOf.pins:
        if pp.hierNet == net and pp.net != nil and pp.net notin visited:
          if pp.net == b: return true
          visited.add pp.net
          queue.add pp.net
  false

proc runDcPathExists(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  ## `dc_path_exists(a, b)`: 1 if a DC-conductive path joins the nets, 0 if
  ## only ambiguous parts separate them. E.g. a coupled-inductor barrier:
  ## `require dc_path_exists(vpoe, poe5v) == 0`.
  let d = ctx.design
  const name = "static.dc_isolation"
  for a in batch:
    let n1 = netSubject(d, a, 0)
    let n2 = netSubject(d, a, 1)
    if n1.isNone or n2.isNone:
      result.add notEvaluable(a, name,
        "dc_path_exists takes two nets that both exist in this design")
      continue
    result.add verdict(a, (if dcConnected(n1.get, n2.get): 1.0 else: 0.0),
                       "", name)

proc dcPathDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  var ns: seq[string]
  for s in batch[0].subjects:
    if s.kind == skNet: ns.add "'" & s.name & "'"
  "a graph walk from " & (if ns.len == 2: ns[0] & " to " & ns[1] else: "two nets") &
  " across DC-conductive parts only -- a transformer, a diode or an IC stops it"

# --- controller_count ---------------------------------------------------

proc runControllerCount(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  for a in batch:
    let netOpt = netSubject(d, a)
    if netOpt.isNone:
      result.add notEvaluable(a, "static.controller_count",
        "subject is not a net in this design")
      continue
    let netName = netOpt.get.name

    # Every role instance touching this net and the controller each bound;
    # two different controllers on one bus is the finding.
    var controllers: HashSet[string]
    var touchingRole = false
    for _, inst in d.roles:
      var touches = false
      for _, subj in inst.bindings:
        if subj.kind == skNet and subj.name == netName:
          touches = true
          break
      if not touches: continue
      touchingRole = true
      for part, subj in inst.bindings:
        if part == "controller" and subj.kind == skComponent:
          controllers.incl subj.name

    # Declared interface metadata is equally authoritative; the role path
    # covers legacy netlists and user roles.
    let live = findNet(d.netlist, netName)
    if live != nil:
      let defName = live.attrs.getOrDefault("iface.def")
      if defName.len > 0:
        try:
          let idef = interfaceDefOf(defName)
          for p in allPins(live):
            let mpName = p.attrs.getOrDefault("iface.modport")
            if idef.modports.hasKey(mpName) and idef.modports[mpName].controller:
              controllers.incl p.component.designator
        except NetlistError:
          discard
    if not touchingRole and controllers.len == 0:
      result.add notEvaluable(a, "static.controller_count",
        "no role binds net '" & netName & "', and nothing in a netlist " &
        "distinguishes a bus controller from a target -- every device on " &
        "the bus has an inout data pin")
      continue
    if controllers.len == 0:
      result.add notEvaluable(a, "static.controller_count",
        "the role on '" & netName & "' bound no `controller` part, and " &
        "controller-ness cannot be recovered from topology")
      continue
    result.add verdict(a, float(controllers.len), "", "static.controller_count")

# --- miso_driver_count ---------------------------------------------------

proc runMisoDriverCount(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  ## How many components drive MISO on one chip select. Per `spi` instance,
  ## so two memories sharing CS and MISO is caught without cross-instance
  ## bookkeeping. Two filters:
  ##
  ## * **leaf components only** -- an instance and the part inside it sit on
  ##   the same conductor and would count twice;
  ## * **the MISO pin must drive** (`ptOutput`/`ptInOut`) -- the controller's
  ##   MISO pin is `ptInput`, else it would count on every instance.
  let d = ctx.design
  const name = "static.miso_driver_count"
  for a in batch:
    let misoOpt = netSubject(d, a, 0)
    let csOpt = netSubject(d, a, 1)
    if misoOpt.isNone or csOpt.isNone:
      result.add notEvaluable(a, name,
        "miso_driver_count takes two nets that both exist in this design")
      continue
    let miso = misoOpt.get
    let cs = csOpt.get

    var csComponents: seq[Component]
    for p in allPins(cs):
      let c = p.component
      if c == nil or c.subNetlist != nil: continue
      if c notin csComponents: csComponents.add c

    var statedDirection = false
    var drivers: seq[Component]
    for p in allPins(miso):
      let c = p.component
      if c == nil or c.subNetlist != nil: continue
      if p.kind != ptUnknown: statedDirection = true
      if p.kind notin {ptOutput, ptInOut}: continue
      if c in csComponents and c notin drivers: drivers.add c

    if not statedDirection:
      result.add notEvaluable(a, name,
        "no pin on '" & miso.name & "' states a direction, so a driver " &
        "cannot be told from a receiver on it")
      continue

    result.add verdict(a, float(drivers.len), "", name)

# --- what each walk is ---------------------------------------------------

proc netOf(a: Assertion): string =
  for sub in a.subjects:
    if sub.kind == skNet: return sub.name
  "the design"

proc pullupCountDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  "a graph walk of net '" & netOf(batch[0]) &
  "', counting resistors that reach a rail from it"

proc rcCornerDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  "a graph walk of net '" & netOf(batch[0]) &
  "': the parallel pull-up resistance against an *invented* per-pin bus " &
  "capacitance, since a netlist carries neither trace nor pin capacitance"

proc sinkCurrentDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  "a graph walk of net '" & netOf(batch[0]) &
  "': the rail voltage divided by the parallel pull-up resistance, which is " &
  "what a device holding the line low has to sink"

proc controllerCountDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  "a graph walk of net '" & netOf(batch[0]) &
  "', counting the parts the role named as controllers -- nothing in a " &
  "netlist tells a controller from a target, since both have an inout pin"

proc misoDriverCountDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  var ns: seq[string]
  for s in batch[0].subjects:
    if s.kind == skNet: ns.add "'" & s.name & "'"
  "a graph walk of " & (if ns.len == 2: ns[0] & " and " & ns[1] else: "two nets") &
  ": leaf components with a driving pin on the first that also have a " &
  "pin on the second"

# --- registration -------------------------------------------------------

proc registerStaticEvaluators*() =
  ## Called at module init; exposed so an application that clears the
  ## registry can restore these.
  registerEvaluator(Evaluator(
    name: "static.pullup_count",
    produces: @["pullup_count"],
    units: {"pullup_count": ""}.toTable,
    needs: {capStatic},
    arity: 1 .. 1,
    subjectKinds: {skNet},
    setupDoc: pullupCountDoc,
    run: runPullupCount))

  registerEvaluator(Evaluator(
    name: "static.rc_corner",
    produces: @["rc_corner"],
    units: {"rc_corner": "Hz"}.toTable,
    needs: {capStatic},
    arity: 1 .. 1,
    subjectKinds: {skNet},
    setupDoc: rcCornerDoc,
    run: runRcCorner))

  registerEvaluator(Evaluator(
    name: "static.pullup_sink_current",
    produces: @["pullup_sink_current"],
    units: {"pullup_sink_current": "A"}.toTable,
    needs: {capStatic},
    arity: 1 .. 1,
    subjectKinds: {skNet},
    setupDoc: sinkCurrentDoc,
    run: runPullupSinkCurrent))

  registerEvaluator(Evaluator(
    name: "static.dc_isolation",
    produces: @["dc_path_exists"],
    units: {"dc_path_exists": ""}.toTable,
    needs: {capStatic},
    arity: 2 .. 2,
    subjectKinds: {skNet},
    setupDoc: dcPathDoc,
    run: runDcPathExists))

  registerEvaluator(Evaluator(
    name: "static.controller_count",
    produces: @["controller_count"],
    units: {"controller_count": ""}.toTable,
    needs: {capStatic},
    arity: 1 .. 1,
    subjectKinds: {skNet},
    # Only the role knows which device is the controller, so a bare
    # `require` can't reach this.
    binds: @["controller"],
    setupDoc: controllerCountDoc,
    run: runControllerCount))

  registerEvaluator(Evaluator(
    name: "static.miso_driver_count",
    produces: @["miso_driver_count"],
    units: {"miso_driver_count": ""}.toTable,
    needs: {capStatic},
    arity: 2 .. 2,
    subjectKinds: {skNet},
    setupDoc: misoDriverCountDoc,
    run: runMisoDriverCount))

registerStaticEvaluators()
