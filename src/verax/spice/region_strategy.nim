## Region scoping strategies: how much of a design a simulation sees, and
## what closes each cut. A strategy is a registered proc, looked up by name
## from a bench's `ScopeRequest` -- never an enum switched on inside an
## analysis -- so several coexist and a new one is one `registerRegionStrategy`
## call. The graph walk they share is `netlist/region.growRegion`.
##
## Built-ins:
## - `whole`: the design as authored; nothing cut.
## - `terminated`: `isolate` -- grow through passives, stop at rails and
##   actives, hold rails at nominal with ideal sources, leak open ports.
## - `source_closed`: the seeds' connected component, walking through
##   rails, regulators and every model element -- everything except
##   ground. **Never invents a termination**: what is left out shares only
##   ground with what is kept, so leaving it out is exact. With `icSinks`, a
##   load IC's per-pin stand-in on a rail (the only place a cut is made) is
##   replaced by a constant sink drawing the same DC current -- the stated
##   `supply_current`, else what the stand-in drew at the rail's stated
##   voltage; a rail with no stated voltage keeps its stand-ins. A sink is
##   open at AC (a resistor is not), which is the trade made.
##
## A strategy receives the bench's work netlist (already cloned, flattened,
## replaced and pin-modelled) and may return it or a new fragment; it must
## record every invented boundary element as an `Assumption`.

import std/[math, strutils, tables]
import ../netlist/types
import ../netlist/graph
import ../netlist/kinds
import ../netlist/annotations
import ../netlist/region
import ../netlist/formats/spice as spiceFormat
import ../eng
import ./isolate
import ./extract
import ./provenance

export region, isolate

type
  ScopeRequest* = object
    strategy*: string
      ## Registered strategy name.
    seedParts*: seq[string]
    seedNets*: seq[string]
    isolation*: IsolationSpec
      ## `terminated`'s options (its `name` names the fragment).
    icSinks*: bool
      ## `source_closed`: stand load ICs' rail pins in as current sinks.
    design*: Netlist
      ## The design the bench was opened on (stated annotations of parts
      ## the model passes have already replaced).
    options*: Table[string, string]
      ## Free options for strategies registered outside verax.

  Scoped* = object
    netlist*: Netlist
      ## What is simulated.
    region*: Region
      ## The parts kept and dropped (`whole`: every top-level part).
    railNets*: seq[string]
      ## Nets held by an invented ideal source.
    openPorts*: seq[string]
      ## Nets left open (leaked) at the cut.
    assumptions*: seq[Assumption]

  ScopeChoice* = object
    ## The part of a `ScopeRequest` an analysis's spec carries (seeds come
    ## from the measurement itself). Part of the spec, so part of its key.
    strategy*: string
    icSinks*: bool

  ScopeProc* = proc (work: Netlist, req: ScopeRequest,
                     globals: var OrderedTable[string, Net]): Scoped {.closure.}

  RegionStrategy* = object
    name*: string
    doc*: string
      ## One line for reports: what the boundary is and what closes it.
    apply*: ScopeProc

var strategies: OrderedTable[string, RegionStrategy]

proc registerRegionStrategy*(s: RegionStrategy) =
  ## Re-registering a name replaces it (the override path).
  if s.name.len == 0 or s.apply == nil:
    raise newException(ValueError, "a region strategy needs a name and apply")
  strategies[s.name] = s

proc regionStrategyNames*(): seq[string] =
  for k in strategies.keys: result.add k

proc regionStrategy*(name: string): RegionStrategy =
  if name notin strategies:
    raise newException(KeyError, "no region strategy '" & name &
      "'; registered: " & regionStrategyNames().join(", "))
  strategies[name]

proc scope*(work: Netlist, req: ScopeRequest,
            globals: var OrderedTable[string, Net]): Scoped =
  regionStrategy(req.strategy).apply(work, req, globals)

proc wholeScope(work: Netlist, req: ScopeRequest,
                globals: var OrderedTable[string, Net]): Scoped =
  result.netlist = work
  for d in work.components.keys: result.region.parts.add d
  for n in work.nets.keys: result.region.nets.add n

proc terminatedScope(work: Netlist, req: ScopeRequest,
                     globals: var OrderedTable[string, Net]): Scoped =
  let iso = isolateFrom(work, req.seedParts, req.seedNets, req.isolation,
                        globals)
  result.netlist = iso.netlist
  result.region.parts = iso.seeds & iso.absorbed
  result.region.dropped = iso.dropped
  for n in iso.netlist.nets.keys: result.region.nets.add n
  result.railNets = iso.railNets
  result.openPorts = iso.openPorts
  result.assumptions = iso.assumptions

proc isPinStandIn(c: Component): bool =
  c.kind == "resistor" and c.attrs.getOrDefault("models.pin.expanded", "") == "true" and
    benchRole(c) == $brStandIn

proc railSide(c: Component): Net =
  ## The non-ground net of a two-pin part with one pin on ground.
  var other: Net = nil
  var grounded = false
  for _, p in c.pins:
    if p.net == nil: return nil
    if isGround(p.net) or p.net.name == "0": grounded = true
    else: other = p.net
  if grounded: other else: nil

type Sink = tuple[amps: float, how: string]

proc sinkFor(c: Component, rail: Net, req: ScopeRequest,
             railPinsOf: Table[string, int]): Sink =
  ## The constant current `c` (a per-pin stand-in on `rail`) is replaced
  ## by, or `NaN` when nothing says (the stand-in is then kept).
  let owner = benchOf(c)
  let pinName = c.attrs.getOrDefault(benchPinKey, "")
  if req.design != nil and owner.len > 0:
    let part = findComponent(req.design, owner)
    if part != nil:
      if pinName.len > 0 and part.pins.hasKey(pinName):
        let ip = supplyCurrent(part.pins[pinName])
        if ip.has: return (float(ip.value), "stated on " & owner & "." & pinName)
      let ic = supplyCurrent(part)
      if ic.has and railPinsOf.getOrDefault(owner) == 1:
        return (float(ic.value), "stated on " & owner)
  let v = railVoltage(rail)
  var ohms: float
  if v.has and parseSpiceMagnitude(c.attrs.getOrDefault("value", ""), ohms) and
     ohms > 0.0:
    return (float(v.value) / ohms, "what its " & eng(ohms, "ohm") &
            " stand-in draws at the stated " & eng(float(v.value), "V"))
  (NaN, "")

proc uniqueName(nl: Netlist, base: string): string =
  result = base
  var n = 0
  while nl.components.hasKey(result):
    inc n
    result = base & "_" & $n

proc sourceClosedScope(work: Netlist, req: ScopeRequest,
                       globals: var OrderedTable[string, Net]): Scoped =
  var railPinsOf: Table[string, int]
  if req.icSinks:
    for _, c in work.components:
      if isPinStandIn(c):
        let r = railSide(c)
        if r != nil and isRail(r): inc railPinsOf.mgetOrPut(benchOf(c), 0)
  var sinks: Table[string, Sink]
  let icSinks = req.icSinks
  let rules = RegionRules(maxHops: 1_000_000, closeCouplings: true,
    traverseNet: proc (n: Net, seeded: bool): bool =
      not (isGround(n) or n.name == "0"),
    absorb: proc (c: Component, via: Net): RegionAction =
      if not icSinks or not isPinStandIn(c): return raInclude
      let rail = railSide(c)
      if rail == nil or rail != via or not isRail(rail): return raInclude
      let s = sinkFor(c, rail, req, railPinsOf)
      if s.amps.isNaN: return raInclude
      sinks[c.designator] = s
      raDrop)
  var seedNets: seq[Net]
  for name in req.seedNets:
    let n = findNet(work, name)
    if n == nil: continue  # the analysis reports its own missing nets
    seedNets.add n
  let r = growRegion(work, req.seedParts, seedNets, rules)
  result.region = r
  if r.parts.len == work.components.len and r.dropped.len == 0:
    result.netlist = work           # nothing to leave out
    return
  result.netlist = extractSubcircuit(work, work.name, r.parts, globals)
  let frag = result.netlist
  let gnd = frag.nets.getOrDefault("0")
  let left = work.components.len - r.parts.len - r.dropped.len
  if left > 0:
    result.assumptions.add note($left & " part(s) share only ground with " &
      "what is measured and were left out; the result does not depend on them")
  if gnd == nil: return
  var byOwner: OrderedTable[string, seq[string]]
  for d in r.dropped:
    let c = work.components[d]
    let rail = frag.nets.getOrDefault(railSide(c).name)
    let s = sinks[d]
    let owner = benchOf(c)
    let pinName = c.attrs.getOrDefault(benchPinKey, "")
    let src = addComponent(frag, newComponent(
      uniqueName(frag, $spiceFormat.designatorPrefix("current_source") &
                 "SINK_" & d), kind = "current_source"))
    # `+` on the rail: a positive value pulls current out of it.
    discard connect(src, "+", rail, ptPassive)
    discard connect(src, "-", gnd, ptPassive)
    src.attrs["value"] = "DC " & spiceValue(s.amps)
    src.attrs[benchPinKey] = pinName
    mark(src, brTermination, owner, owner & "." & pinName & " drawn as a " &
         "constant " & eng(s.amps, "A") & " from '" & rail.name & "'")
    byOwner.mgetOrPut(owner, @[]).add pinName & " " & eng(s.amps, "A") &
      " (" & s.how & ")"
  for owner, pins in byOwner:
    result.assumptions.add note(owner, "a load on the measured supply, " &
      "stood in as constant current sink(s): " & pins.join("; ") &
      ". A sink is open at AC, so it neither damps nor loads a ripple or " &
      "impedance result the way the part itself would")

registerRegionStrategy RegionStrategy(name: "whole",
  doc: "the design as authored; nothing cut", apply: wholeScope)
registerRegionStrategy RegionStrategy(name: "terminated",
  doc: "grown through passives from the seeds; rails held at nominal by " &
       "ideal sources, open nets leaked to ground", apply: terminatedScope)
registerRegionStrategy RegionStrategy(name: "source_closed",
  doc: "everything connected to the measurement other than through " &
       "ground, back to the real sources; nothing terminated (load ICs on " &
       "a rail optionally drawn as constant sinks)", apply: sourceClosedScope)
