## Evaluators that answer from the graph alone -- no simulator, no toolchain.
##
## These are the producers for the quantities the built-in `i2c` role expands
## to, which until now were claims nothing could check. They are registered
## through the ordinary `registerEvaluator` path, with no privileged
## mechanism, for the same reason the built-in roles are: a built-in that
## cheats makes a user-written evaluator second-class.
##
## Two of the three are worth reading for what they *decline* to answer.
## `controller_count` cannot be derived from topology at all -- every device
## on an I2C bus has an inout data pin, and nothing in a netlist distinguishes
## the controller from a target -- so with no role binding to read it returns
## `esNotEvaluable` rather than a guess. `rc_corner` rests on an invented
## per-pin capacitance and says so in an `Assumption`, because a netlist
## carries neither trace nor pin capacitance and the answer is dominated by
## both.

import std/[math, sets, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/kinds
import ../../netlist/interfaces
import ../../netlist/annotations
import ../../netlist/formats/spice as spiceFormat
import ../evaluate

export evaluate

const
  assumedPinCapacitance* = 10.0e-12
    ## Farads per connected pin, for a bus whose capacitance nothing states.
    ##
    ## Bus capacitance is dominated by trace length and device pin
    ## capacitance, neither of which exists in a netlist -- so this number is
    ## invented every time and is reported as an assumption every time. 10 pF
    ## per pin is a common working figure; the I2C specification instead caps
    ## the *total* bus at 400 pF, which is a limit rather than a typical.

proc railOf(p: Pin): Net =
  ## The net on the far side of a two-terminal part from `p`, when it is a
  ## rail.
  let c = p.component
  for _, other in c.pins:
    if other == p: continue
    if other.net != nil and isRail(other.net): return other.net
  nil

proc pullupsOn(net: Net): seq[Component] =
  ## Every resistor with one end on `net` and the other on a rail. A pull-up
  ## and a pull-down are the same shape here; which rail it terminates to is
  ## a separate question from whether the line is passively driven at all.
  var seen: HashSet[string]
  for p in net.pins:
    let c = p.component
    if c == nil or c.kind != "resistor": continue
    if c.designator in seen: continue
    if railOf(p) != nil:
      seen.incl c.designator
      result.add c

proc capacitorsOn(net: Net): seq[Component] =
  var seen: HashSet[string]
  for p in net.pins:
    let c = p.component
    if c == nil or c.kind != "capacitor": continue
    if c.designator in seen: continue
    seen.incl c.designator
    result.add c

proc magnitudeOf(c: Component, value: var float): bool =
  ## A resistor's or capacitor's value as a number. Only asked of parts whose
  ## `value` is definitionally a bare magnitude -- see `parseSpiceMagnitude`
  ## for why the general `attrs["value"]` is never parsed.
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
  ## The output-low voltage an I2C target must hold, per the specification.
  ## Not a design choice, which is why it is a constant and not a parameter.

proc runPullupSinkCurrent(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  ## How much current whatever pulls the line low has to sink.
  ##
  ## The bound that `pullup_count` and `rc_corner` between them do not
  ## provide. Both of those catch a pull-up that is too *weak* -- absent, or
  ## slow against the bus capacitance -- and nothing caught one too strong.
  ## The I2C specification requires a target to hold VOL at or below 0.4 V
  ## while sinking 3 mA, so at 3.3 V the pull-up may not go below about
  ## 1 kohm. That floor and the RC ceiling squeeze from opposite sides, and a
  ## design pushed off one of them by fixing the other has no way to find
  ## out: `designs/sensor_node.nim` runs 1.2k *because* 1.5k failed the RC
  ## check, which put it within 20% of the other limit.
  ##
  ## Each pull-up is charged against the rail it actually terminates on,
  ## rather than against one rail for the whole net -- a bus with pull-ups to
  ## two different supplies is unusual and is not a reason to report a number
  ## about neither.
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
              else: default(AnnValue[float])
      if not magnitudeOf(r, ohms) or ohms <= 0.0:
        unreadable.add r.designator & " (no readable resistance)"
      elif not v.has:
        unreadable.add r.designator & " (rail '" &
          (if railNet != nil: railNet.name else: "?") & "' states no voltage)"
      else:
        total += max(v.value - i2cVol, 0.0) / ohms

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

    let pinLoad = float(net.pins.len) * assumedPinCapacitance
    farads += pinLoad
    assumptions.add assumption(net.name, "bus_capacitance", pinLoad, "F",
      annDefaulted,
      "assumed " & $(assumedPinCapacitance * 1.0e12) & " pF for each of " &
      $net.pins.len & " connected pins; a netlist carries neither trace nor " &
      "device pin capacitance")

    let resistance = 1.0 / conductance
    let corner = 1.0 / (2.0 * PI * resistance * farads)
    result.add verdict(a, corner, "Hz", "static.rc_corner", assumptions)

# --- dc_path_exists ----------------------------------------------------

proc dcConnected(a, b: Net): bool =
  ## Is there a DC-conductive path from `a` to `b`? A breadth-first walk
  ## across conductive pin pairs and hierarchy boundaries, the same
  ## traversal `analysis/io_check.dcReachable` uses -- but stopped at a
  ## *named target* rather than at any terminus. A pin pair `conductiveExits`
  ## does not return (an undeclared ambiguous part -- a diode, an IC, a
  ## **transformer** -- or a pair a declared spec does not name) is never
  ## crossed, which is what makes this the isolation-barrier check: the two
  ## windings of a `K`-coupled pair have no DC path between them. This is
  ## also what makes `dc_path_exists(rfc, rf1)` true across a declared
  ## ADG904 (`designs/xbar_rf.nim`): the switch's own `traverse:` spec
  ## answers `conductiveExits`, in place of the whole-component
  ## `classifyConductivity` this used to call.
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
  ## `dc_path_exists(a, b)` -- 1 when a DC-conductive path joins the two nets,
  ## 0 when nothing but ambiguous parts (a transformer, a diode, an IC) sit
  ## between them. The claim a coupled-inductor barrier makes checkable:
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

    # Every role instance touching this net, and every component any of them
    # bound as the controller. Two instances naming different controllers on
    # one bus is the real finding here.
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

    # Declared interface metadata is an equally authoritative source.  Keep
    # the role path for legacy netlists and user-defined roles.
    let live = findNet(d.netlist, netName)
    if live != nil:
      let defName = live.attrs.getOrDefault("iface.def")
      if defName.len > 0:
        try:
          let idef = interfaceDefOf(defName)
          for p in live.pins:
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

# --- registration -------------------------------------------------------

proc registerStaticEvaluators*() =
  ## Called at module init; exposed so an application that clears the registry
  ## can put these back, matching `roles.registerBuiltinRoles`.
  registerEvaluator(Evaluator(
    name: "static.pullup_count",
    produces: @["pullup_count"],
    needs: {capStatic},
    arity: 1 .. 1,
    subjectKinds: {skNet},
    setupDoc: pullupCountDoc,
    run: runPullupCount))

  registerEvaluator(Evaluator(
    name: "static.rc_corner",
    produces: @["rc_corner"],
    needs: {capStatic},
    arity: 1 .. 1,
    subjectKinds: {skNet},
    setupDoc: rcCornerDoc,
    run: runRcCorner))

  registerEvaluator(Evaluator(
    name: "static.pullup_sink_current",
    produces: @["pullup_sink_current"],
    needs: {capStatic},
    arity: 1 .. 1,
    subjectKinds: {skNet},
    setupDoc: sinkCurrentDoc,
    run: runPullupSinkCurrent))

  registerEvaluator(Evaluator(
    name: "static.dc_isolation",
    produces: @["dc_path_exists"],
    needs: {capStatic},
    arity: 2 .. 2,
    subjectKinds: {skNet},
    setupDoc: dcPathDoc,
    run: runDcPathExists))

  registerEvaluator(Evaluator(
    name: "static.controller_count",
    produces: @["controller_count"],
    needs: {capStatic},
    arity: 1 .. 1,
    subjectKinds: {skNet},
    # Every device on an I2C bus has an inout data pin, so nothing in a
    # netlist distinguishes the controller from a target. Only the role
    # knows, which makes this unreachable by a bare `require` -- and worth
    # saying so in `verax quantities` rather than at the point of failure.
    binds: @["controller"],
    setupDoc: controllerCountDoc,
    run: runControllerCount))

registerStaticEvaluators()
