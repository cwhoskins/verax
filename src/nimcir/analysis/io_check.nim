## Two static IO/electrical-rules checks over a `Netlist`:
##
##  - `checkOutputConflicts`: no net should be driven by more than one
##    output.
##  - `checkDCPaths`: every input pin should have a DC path to an output or
##    to a power/ground net.
##
## Both are pure graph walks over `nimcir/netlist` -- no simulation. When
## `checkDCPaths` walks through a component it can't classify as
## DC-conductive or DC-blocking (an active device like a diode/transistor,
## an IC, or any unrecognized `Component.kind`), it reports the finding as
## `"ambiguous_dc_path"` rather than guessing; `nimcir/analysis/spice_fallback`
## is the opt-in, ngspice-backed way to attempt resolving those.
##
## These checks are only as informative as the `Pin.kind` data on the
## netlist they're given. A netlist read from a raw SPICE deck via
## `nimcir/netlist/formats/spice` mostly carries `ptPassive`/`ptUnknown`
## pins (SPICE has no native pin-direction concept), so these checks will
## find nothing to flag on it -- not because it's clean, but because
## there's no `ptInput`/`ptOutput` data to reason about. This analysis is
## meaningful for DSL-authored (or otherwise pin-kind-rich) netlists.
##
## "A section of a netlist" is handled by extracting first with
## `nimcir/spice/extract` (`extractSubcircuit`/`extractInstance`), then
## analyzing the resulting standalone `Netlist` like any other -- no subset
## selection is reinvented here.

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
  ## Flags any net driven by more than one `ptOutput` pin (`sevError`), or by
  ## exactly one `ptOutput` plus one-or-more `ptInOut` pins, or by two-or-more
  ## `ptInOut` pins with no `ptOutput` (`sevWarning` -- `ptInOut` pins count
  ## as conflict *participants*, but only at reduced confidence, since a
  ## `ptInOut` pin may be an intentionally tri-stated/open-drain bus member,
  ## e.g. I2C SDA/SCL -- `PinType` has no drive-strength field to distinguish
  ## that case from a real conflict).
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
      result.add newIssue("output_conflict", sevWarning,
        "multiple driver-capable pins share net '" & net.name &
        "' (" & $inouts.len & " ptInOut pin(s) among them; may be an intentional " &
        "shared/tri-stated bus): " & pinListLabel(drivers),
        net = net, pins = drivers)
  if recursive:
    for _, child in nl.children:
      result.add checkOutputConflicts(child, recursive = true)

proc isTerminus(net: Net): bool =
  ## A net counts as "reached" if it is a power/ground rail (see
  ## `netlist/kinds.isRail` for why that test accepts either signal), or if
  ## it carries an output pin.
  if isRail(net): return true
  for p in net.pins:
    if p.kind == ptOutput: return true
  false

proc dcReachable(startNet: Net): tuple[reached: bool, ambiguous: seq[Component]] =
  ## Breadth-first walk from `startNet` across conductive components and
  ## hierarchy boundaries (`Pin.hierNet` to descend into a `subNetlist`,
  ## `Netlist.instanceOf`/matching `hierNet` to ascend back out) until a
  ## terminus is reached or the walk is exhausted. Ambiguous components
  ## encountered along the way are collected but not traversed through.
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

      # A component only matters here if it has some *other* connected pin
      # on a genuinely different net -- otherwise it's a dead end for this
      # walk (e.g. the very component whose input is being checked, once
      # its other pins, if any, are exhausted) and must not be classified
      # as an ambiguous blocker just for touching this net.
      var otherNets: seq[Net]
      for _, otherPin in comp.pins:
        if otherPin != p and otherPin.net != nil and otherPin.net != net and
           otherPin.net notin otherNets:
          otherNets.add otherPin.net
      if otherNets.len == 0: continue

      case classifyConductivity(comp)
      of condConductive:
        for n in otherNets:
          if n notin visited:
            visited.add n
            queue.add n
      of condBlocking:
        discard
      of condAmbiguous:
        if comp notin ambiguous:
          ambiguous.add comp

    if net.netlist != nil and net.netlist.instanceOf != nil:
      for _, pp in net.netlist.instanceOf.pins:
        if pp.hierNet == net and pp.net != nil and pp.net notin visited:
          visited.add pp.net
          queue.add pp.net

  (false, ambiguous)

proc checkDCPaths*(nl: Netlist, recursive = true): seq[Issue] =
  ## For every `ptInput` pin (over `nl.components`, and recursively into
  ## `nl.children` if `recursive`), walks for a DC path to a terminus (see
  ## `isTerminus`). An unconnected pin is flagged immediately as
  ## `"unconnected_input"`. A connected pin that exhausts the walk with no
  ## ambiguous component encountered is `"no_dc_path"` (`sevError`,
  ## confident). If ambiguous components were encountered along the way,
  ## it's `"ambiguous_dc_path"` (`sevWarning`) instead -- this is exactly the
  ## record `nimcir/analysis/spice_fallback.resolveAmbiguousDCPaths` consumes.
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
          " -- see nimcir/analysis/spice_fallback.resolveAmbiguousDCPaths",
          net = p.net, pins = @[p], components = ambiguous)
  if recursive:
    for _, child in nl.children:
      result.add checkDCPaths(child, recursive = true)

proc isPort(nl: Netlist, net: Net): bool =
  ## Whether `net` is a published port of `nl` -- compared by identity, since
  ## `Netlist.ports` is keyed by the port's published name, which need not be
  ## the net's own.
  for _, p in nl.ports:
    if p == net: return true
  false

proc checkRailVoltages*(nl: Netlist, recursive = true): seq[Issue] =
  ## A power net whose nominal voltage nobody stated.
  ##
  ## Every simulation-backed analysis cuts a fragment out of the design and
  ## has to terminate the rails at its boundary. A rail with a stated voltage
  ## gets an ideal source there; a rail without one is **cut loose as a
  ## floating node**. That is not a substituted value, it is a change of
  ## topology, and it is why this is a structural finding rather than an
  ## assumption.
  ##
  ## The case that put it here: `designs/ts808_drive.nim` derives its 4.5 V
  ## bias from a divider, so no `power_rail` role fits it and it initially
  ## carried no voltage. Cutting it loose detached the drive stage's gain leg
  ## and measured an amplifier with a gain of 65 as a unity-gain follower --
  ## 5.9 mdB of peaking against a real 31.6 dB. Every claim passed and the
  ## report said `exit 0 (clean)`. The floating rail *was* reported, as one
  ## assumption among fifteen, reading exactly like the package-typical ESR
  ## two lines above it. Being reported and being *noticed* are different,
  ## and the difference is which section it lands in.
  ##
  ## `sevWarning`, not `sevError`: a rail nothing simulates is harmless, and
  ## a design may legitimately not know a voltage yet. It costs nothing to
  ## state one, so the message says so; `--strict` promotes it.
  for _, net in nl.nets:
    if not isRail(net) or isGround(net): continue
    if railVoltage(net).has: continue
    # A subcircuit's *port* is not a rail of its own: it is whatever the
    # parent wired to it, and the parent is where the voltage is stated. A
    # stereo board instancing one channel twice would otherwise report the
    # same missing voltage once per instance for a rail that is stated, and
    # the finding this check exists to make -- a genuinely floating node --
    # would be sitting among the false ones.
    if isPort(nl, net): continue

    # Naming what terminates on the rail is the actionable half. A rail
    # carrying only power pins and bypass capacitors loses little by
    # floating; one with a signal path returning to it loses the path.
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
