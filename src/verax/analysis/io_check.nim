## Static IO/electrical-rules checks over a `Netlist` (no simulation):
##
##  - `checkOutputConflicts`: no net driven by more than one output.
##  - `checkDCPaths`: every input has a DC path to an output or a rail.
##
## A component that's neither conductive nor blocking (diodes, ICs, unknown
## kinds) yields `"ambiguous_dc_path"` rather than a guess;
## `spice_fallback` can try to resolve those.
##
## Only as good as the `Pin.kind` data: a raw SPICE deck has no pin
## directions, so these find nothing on it. Analyse a section by extracting
## it first (`spice/extract`).

import std/[strutils, tables]
import ../netlist/types
import ../netlist/kinds
import ../netlist/annotations
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

proc isTerminus(net: Net): bool =
  ## "Reached": a rail (`kinds.isRail`) or a net carrying an output pin.
  if isRail(net): return true
  for p in net.pins:
    if p.kind == ptOutput: return true
  false

proc dcReachable(startNet: Net): tuple[reached: bool, ambiguous: seq[Component]] =
  ## BFS from `startNet` across conductive components and hierarchy
  ## boundaries until a terminus or exhaustion. Ambiguous components are
  ## collected, not traversed.
  var visited: seq[Net] = @[startNet]
  var queue: seq[Net] = @[startNet]
  var ambiguous: seq[Component]
  var qi = 0
  while qi < queue.len:
    let net = queue[qi]
    inc qi
    if isTerminus(net):
      return (true, ambiguous)

    for p in net.pins:
      let comp = p.component
      if comp == nil: continue
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

  (false, ambiguous)

proc checkDCPaths*(nl: Netlist, recursive = true): seq[Issue] =
  ## For every `ptInput` pin (recursing into children if `recursive`),
  ## walks for a DC path to a terminus. Unconnected: `"unconnected_input"`.
  ## Exhausted with nothing ambiguous: `"no_dc_path"` (`sevError`). With
  ## ambiguous parts: `"ambiguous_dc_path"` (`sevWarning`), which
  ## `spice_fallback.resolveAmbiguousDCPaths` consumes.
  for _, comp in nl.components:
    for _, p in comp.pins:
      if p.kind != ptInput: continue
      if p.net == nil:
        result.add newIssue("unconnected_input", sevError,
          "input pin " & pinLabel(p) & " is not connected to any net",
          pins = @[p])
        continue
      let (reached, ambiguous) = dcReachable(p.net)
      if reached: continue
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
    checkRailVoltages(nl, recursive)
