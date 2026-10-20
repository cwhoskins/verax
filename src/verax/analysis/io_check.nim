## Static IO/electrical-rules checks over a `Netlist` (no simulation):
##
##  - `checkOutputConflicts`: no net driven by more than one output.
##  - `checkDCPaths`: every input has a DC path to an output, a rail, or a
##    pin's stated internal pull (`pull_up`/`pull_down`) -- and still has
##    one with every connector unplugged (`"input_floats_unmated"`).
##  - `checkPulls`: every stated pull-up can name the rail it returns to.
##
## A component that's neither conductive nor blocking (diodes, ICs, unknown
## kinds) yields `"ambiguous_dc_path"` rather than a guess;
## `spice_fallback` can try to resolve those.
##
## A connector's pins state what is plugged in (`kinds.connectorKinds`), so
## a connector `ptOutput` is a driver that exists only while something is
## mated. The DC walk counts it, then walks again without it: an input held
## only by a mate floats when the cable is pulled.
##
## Only as good as the `Pin.kind` data: a raw SPICE deck has no pin
## directions, so these find nothing on it. Analyse a section by extracting
## it first (`spice/extract`).

import std/[strutils, tables]
import ../netlist/types
import ../netlist/kinds
import ../netlist/annotations
import ../netlist/pinmux
import ./issue

export issue, kinds

proc pinLabel(p: Pin): string =
  p.component.designator & "." & p.name

proc pinListLabel(pins: seq[Pin]): string =
  var parts: seq[string]
  for p in pins: parts.add pinLabel(p)
  parts.join(", ")

proc componentListLabel*(comps: seq[Component]): string =
  var parts: seq[string]
  for c in comps: parts.add c.designator
  parts.join(", ")

proc checkOutputConflicts*(nl: Netlist, recursive = true): seq[Issue] =
  ## Flags a net driven by more than one `ptOutput` (`sevError`), or one
  ## `ptOutput` plus `ptInOut`s, or several `ptInOut`s (`sevWarning` -- an
  ## inout may be tri-stated/open-drain, e.g. I2C, which `PinType` can't
  ## express).
  for _, net in nl.nets:
    var outputs: seq[Pin]
    var inouts: seq[Pin]
    for p in net.pins:
      case p.kind
      of ptOutput: outputs.add p
      of ptInOut: inouts.add p
      else: discard
    let drivers = outputs & inouts
    if outputs.len >= 2:
      result.add newIssue("output_conflict", sevError,
        $outputs.len & " output pins drive net '" & net.name & "': " & pinListLabel(drivers),
        net = net, pins = drivers)
    elif drivers.len >= 2:
      # A declared shared interface signal: all-inout open-drain/tri-state is
      # intended.
      var declaredShared = outputs.len == 0 and inouts.len == drivers.len and drivers.len > 0
      let instance = net.attrs.getOrDefault("iface.instance")
      declaredShared = declaredShared and instance.len > 0 and
        net.attrs.getOrDefault("iface.shared") == "1"
      for p in drivers:
        declaredShared = declaredShared and
          p.attrs.getOrDefault("iface.instance") == instance
      if not declaredShared:
        result.add newIssue("output_conflict", sevWarning,
        "multiple driver-capable pins share net '" & net.name &
        "' (" & $inouts.len & " ptInOut pin(s) among them; may be an intentional " &
        "shared/tri-stated bus): " & pinListLabel(drivers),
          net = net, pins = drivers)
  if recursive:
    for _, child in nl.children:
      result.add checkOutputConflicts(child, recursive = true)

proc isMateDriver(p: Pin): bool {.inline.} =
  ## A driver on a connector: the mate's, present only while one is plugged in.
  p.kind == ptOutput and isConnector(p.component)

proc isTerminus(net: Net, unmated: bool): bool =
  ## "Reached": a rail (`kinds.isRail`), a net carrying an output pin, or
  ## one carrying a pin with a stated internal pull. With `unmated`, a
  ## connector's output (the mate's driver) does not count.
  if isRail(net): return true
  for p in net.pins:
    if p.kind == ptOutput and not (unmated and isMateDriver(p)): return true
    if hasPull(p): return true
  false

proc dcReachable(startNet: Net, unmated = false):
    tuple[reached: bool, ambiguous: seq[Component], mates: seq[Component]] =
  ## BFS from `startNet` across conductive components and hierarchy
  ## boundaries until a terminus or exhaustion. Ambiguous components are
  ## collected, not traversed. `mates` collects the connectors whose drivers
  ## sat on a visited net (only meaningful with `unmated`).
  var visited: seq[Net] = @[startNet]
  var queue: seq[Net] = @[startNet]
  var ambiguous: seq[Component]
  var mates: seq[Component]
  var qi = 0
  while qi < queue.len:
    let net = queue[qi]
    inc qi
    if isTerminus(net, unmated):
      return (true, ambiguous, mates)

    for p in net.pins:
      let comp = p.component
      if comp == nil: continue
      if isMateDriver(p) and comp notin mates: mates.add comp
      if comp.subNetlist != nil:
        if p.hierNet != nil and p.hierNet notin visited:
          visited.add p.hierNet
          queue.add p.hierNet
        continue

      # Per pin: `conductiveExits` gives one exit for a plain two-terminal
      # part, only the declared nets for a switch, and none for a part with
      # no other connected pin.
      let exits = conductiveExits(comp, p)
      for n in exits:
        if n notin visited:
          visited.add n
          queue.add n

      if exits.len == 0:
        # No exits: report ambiguity only if the walk couldn't tell (unknown
        # kind, or >2 pins undeclared). A declared spec's unlisted pairs are
        # `condBlocking`, so a declared switch is silently blocked there.
        for _, otherPin in comp.pins:
          if otherPin != p and otherPin.net != nil and otherPin.net != net and
             conductivityBetween(comp, p, otherPin) == condAmbiguous:
            if comp notin ambiguous:
              ambiguous.add comp
            break

    if net.netlist != nil and net.netlist.instanceOf != nil:
      for _, pp in net.netlist.instanceOf.pins:
        if pp.hierNet == net and pp.net != nil and pp.net notin visited:
          visited.add pp.net
          queue.add pp.net

  (false, ambiguous, mates)

proc floatsWhenUnmated*(net: Net): tuple[floats: bool, mates: seq[Component]] =
  ## Whether `net` has a DC path with every connector's driver present but
  ## none once they are all unplugged. `mates` names the connectors it
  ## depends on. The `unmated` claim condition's guard
  ## (`analysis/evaluators/dc_voltage`) and `checkDCPaths` share it.
  let (reached, _, _) = dcReachable(net)
  if not reached: return (false, @[])
  let (stillReached, _, mates) = dcReachable(net, unmated = true)
  if stillReached or mates.len == 0: return (false, @[])
  (true, mates)

proc floatsWithout*(net: Net, connectors: openArray[string]):
    tuple[floats: bool, mates: seq[Component]] =
  ## As `floatsWhenUnmated`, restricted to the named connectors: true only
  ## when one of `connectors` is among the mates `net` depends on.
  let (floats, mates) = floatsWhenUnmated(net)
  if not floats: return (false, @[])
  for m in mates:
    if m.designator in connectors: result.mates.add m
  result.floats = result.mates.len > 0

proc checkDCPaths*(nl: Netlist, recursive = true): seq[Issue] =
  ## For every `ptInput` pin (recursing into children if `recursive`),
  ## walks for a DC path to a terminus. Unconnected: `"unconnected_input"`.
  ## Exhausted with nothing ambiguous: `"no_dc_path"` (`sevError`). With
  ## ambiguous parts: `"ambiguous_dc_path"` (`sevWarning`), which
  ## `spice_fallback.resolveAmbiguousDCPaths` consumes. Reached only through
  ## a connector's driver: `"input_floats_unmated"` (`sevWarning`) -- the
  ## line floats with the cable pulled, so it wants a pull resistor or a
  ## stated internal pull. Not raised for a connector's own inputs (the
  ## mate's, gone with it) or an instance's pins (the child's are checked).
  for _, comp in nl.components:
    for _, p in comp.pins:
      if p.kind != ptInput: continue
      if p.net == nil:
        result.add newIssue("unconnected_input", sevError,
          "input pin " & pinLabel(p) & " is not connected to any net",
          pins = @[p])
        continue
      let (reached, ambiguous, _) = dcReachable(p.net)
      if reached:
        if isConnector(comp) or comp.subNetlist != nil: continue
        let (floats, mates) = floatsWhenUnmated(p.net)
        if floats:
          result.add newIssue("input_floats_unmated", sevWarning,
            "input pin " & pinLabel(p) & " on net '" & p.net.name &
            "' is driven only through connector(s) " & componentListLabel(mates) &
            "; with nothing plugged in it floats -- add a pull resistor, or " &
            "state the pin's internal pull (`pull_up = ...`/`pull_down = ...`)",
            net = p.net, pins = @[p], components = mates)
        continue
      if ambiguous.len == 0:
        result.add newIssue("no_dc_path", sevError,
          "input pin " & pinLabel(p) & " on net '" & p.net.name &
          "' has no static DC path to an output or power/ground net",
          net = p.net, pins = @[p])
      else:
        result.add newIssue("ambiguous_dc_path", sevWarning,
          "input pin " & pinLabel(p) & " on net '" & p.net.name &
          "' could not be statically resolved: path passes through " &
          "unclassified component(s) " & componentListLabel(ambiguous) &
          " -- see verax/analysis/spice_fallback.resolveAmbiguousDCPaths",
          net = p.net, pins = @[p], components = ambiguous)
  if recursive:
    for _, child in nl.children:
      result.add checkDCPaths(child, recursive = true)

proc checkPulls*(nl: Netlist, recursive = true): seq[Issue] =
  ## A pull that can't be honoured: a pin with both `pull_up` and
  ## `pull_down` (`"pull_conflict"`), or a pull-up -- stated on the pin or
  ## from its part's pinmux table -- with no resolvable rail
  ## (`"pull_rail_unresolved"`). Both `sevError`: the DC checks and
  ## the simulator would otherwise each guess differently.
  for _, comp in nl.components:
    for _, p in comp.pins:
      if pullUp(p).has and pullDown(p).has:
        result.add newIssue("pull_conflict", sevError,
          "pin " & pinLabel(p) & " states both pull_up and pull_down",
          net = p.net, pins = @[p])
        continue
      let pull = pinPull(p)
      if not pull.has or pull.value.kind != pkUp: continue
      let (_, problem) = pullRail(p)
      if problem.len > 0:
        result.add newIssue("pull_rail_unresolved", sevError, problem,
                            net = p.net, pins = @[p])
  if recursive:
    for _, child in nl.children:
      result.add checkPulls(child, recursive = true)

proc isPort(nl: Netlist, net: Net): bool =
  ## Whether `net` is a published port of `nl`, by identity (port names may
  ## differ from net names).
  for _, p in nl.ports:
    if p == net: return true
  false

proc checkRailVoltages*(nl: Netlist, recursive = true): seq[Issue] =
  ## A power net with no stated voltage. Simulation fragments terminate
  ## rails at their boundary; a rail without a voltage is **cut loose as a
  ## floating node** -- a change of topology, not a substituted value, so
  ## it's a structural finding rather than an assumption (a floating bias
  ## rail can turn a gain stage into a follower with every claim passing).
  ##
  ## `sevWarning`: an unsimulated rail is harmless and stating one is cheap;
  ## `--strict` promotes it.
  for _, net in nl.nets:
    if not isRail(net) or isGround(net): continue
    if railVoltage(net).has: continue
    # A subcircuit port isn't its own rail; the parent states the voltage.
    # Otherwise each instance would report a false finding.
    if isPort(nl, net): continue

    # Name what terminates on the rail: a bypass-only rail loses little by
    # floating; a signal path returning to it loses the path.
    var onIt: seq[string]
    var comps: seq[Component]
    for p in net.pins:
      let c = p.component
      if c == nil or c.kind == "capacitor": continue
      if c.designator notin onIt:
        onIt.add c.designator
        comps.add c

    var msg = "net '" & net.name & "' is a power rail with no stated " &
      "voltage, so an analysis that cuts a fragment out around it leaves " &
      "it floating rather than driving it -- which changes the topology " &
      "rather than substituting a value. State it with `spec: voltage = " &
      "...` on the net, or give it a `power_rail` role."
    if onIt.len > 0:
      msg &= " " & onIt.join(", ") &
        (if onIt.len == 1: " terminates" else: " terminate") &
        " on it and would lose that connection."

    result.add newIssue("rail_voltage_unknown", sevWarning, msg,
                        net = net, components = comps)

  if recursive:
    for _, child in nl.children:
      result.add checkRailVoltages(child, recursive = true)

proc analyzeIO*(nl: Netlist, recursive = true): seq[Issue] =
  checkOutputConflicts(nl, recursive) & checkDCPaths(nl, recursive) &
    checkPulls(nl, recursive) & checkRailVoltages(nl, recursive)
