## A test bench: what an analysis simulates, declared rather than
## hand-built. Every simulator-backed analysis builds its circuit through
## one of these, in stages it calls in its own order:
##
## 1. `openBench` -- clone, flatten (`flattenForSim`), unplug any `unmated`
##    connectors, apply `simReplace`s for the analysis's purpose.
## 2. `modelUnmodelled` -- per-pin / behavioural stand-ins
##    (`expandPinModels`). **Before** scoping: `terminated` won't traverse
##    an undescribed part.
## 3. `scopeBench` -- a registered `region_strategy` decides what is kept
##    and closes each cut.
## 4. Fragment passes the analysis wants (capacitor parasitics, source
##    impedance) -- plain `models` calls on `b.netlist`; provenance marks
##    them.
## 5. Fixture: `stimulus`, `probe`, `load`, `detached`, `focus` -- each
##    marks the element and records it in `b.info`.
## 6. `run` -- `ngspice.run` with `b.info`, so the run observer (the HTML
##    report) sees what was driven, read and cut.
##
## The stage order is each analysis's own, deliberately: a bench changes
## *where* things are recorded, never what is simulated.

import std/[strutils, tables]
import ../netlist/types
import ../netlist/graph
import ../netlist/annotations
import ../netlist/kinds
import ../netlist/pinmux
import ../netlist/formats/spice as spiceFormat
import ./flatten
import ./transform
import ./models
import ./region_strategy
import ./provenance
import ./backend
import ./ngspice

export region_strategy, provenance

type
  Bench* = object
    info*: BenchInfo
    work*: Netlist
      ## The model-substituted clone, before scoping (read pins/rails of the
      ## design here: after `terminated`, rails are terminations).
    netlist*: Netlist
      ## What runs: `work` until `scopeBench`, then the scoped netlist.
    scoped*: Scoped
    assumptions*: seq[Assumption]
      ## What the bench's own stages invented (pin models, the scope). An
      ## analysis appends these to its report.
    globals*: OrderedTable[string, Net]
    design*: Netlist
      ## What `openBench` was given (never modified).

const unmatedLeak = 1.0e9
  ## Ohms to ground on each net an unplugged connector leaves (see `unmate`).

proc unmate(b: var Bench, connectors: openArray[string]) =
  ## Each named connector has nothing plugged in: removed from the bench --
  ## before `simReplace`s run, so a `boundary.driveConnector` drive goes
  ## with it -- and recorded in `b.info.unmated`. Raises `NetlistError` on a
  ## name that is not a connector in the design.
  for d in connectors:
    let c = b.work.components.getOrDefault(d)
    if c == nil:
      raise newException(NetlistError, "cannot unmate '" & d &
        "': no such component at the top of the design")
    if not isConnector(c):
      raise newException(NetlistError, "cannot unmate '" & d & "': it is a " &
        (if c.kind.len > 0: c.kind else: "part of no stated kind") &
        ", not a connector")
    # The nets it leaves behind may now have no DC path at all (an
    # AC-coupled input), which ngspice refuses outright; a 1 Gohm leak is
    # the open circuit it can solve. Claims on such a net are failed by the
    # evaluator's floating guard, not read off the leak.
    let gnd = groundOf(b.work)
    var leaked: seq[Net]
    for _, p in c.pins:
      if p.net != nil and p.net != gnd and not isGround(p.net) and
         p.net notin leaked:
        leaked.add p.net
    removeComponent(b.work, d)
    if gnd != nil:
      for n in leaked:
        let r = addComponent(b.work, newComponent(
          $spiceFormat.designatorPrefix("resistor") & "_UNMATED_" & d & "_" & n.name,
          kind = "resistor"))
        discard connect(r, "1", n, ptPassive)
        discard connect(r, "2", gnd, ptPassive)
        r.attrs["value"] = spiceValue(unmatedLeak)
        mark(r, brTermination, note = d & " unplugged: net '" & n.name &
          "' left open, leaked to ground")
    if d notin b.info.unmated: b.info.unmated.add d
    b.assumptions.add note(d, "nothing plugged in: removed from the bench, " &
      "so its pins drive and load nothing")
    if leaked.len > 0:
      var names: seq[string]
      for n in leaked: names.add n.name
      b.assumptions.add assumption("net(s) " & names.join(", ") & " left by " & d,
        "leak", unmatedLeak, "ohm", annDerived,
        "tied to ground so the open net has a DC reference")

proc openBench*(nl: Netlist, name, purpose: string, flatten = true,
                keepInstances: openArray[string] = [],
                namedParts: openArray[string] = [],
                replaceExclude: openArray[string] = [],
                unmated: openArray[string] = []): Bench =
  ## Stage 1. `nl` is never modified. `unmated` names connectors with
  ## nothing plugged in (the `unmated` claim condition): removed after
  ## flattening and before any `simReplace`, so neither a pin stand-in nor a
  ## `driveConnector` drive is invented for them. Raises `NetlistError` on a
  ## name that is not a connector.
  result.info.name = name
  result.info.strategy = "whole"
  result.design = nl
  var cloneNets: OrderedTable[string, Net]
  result.work = clone(nl, cloneNets)
  discard flattenForSim(result.work, flatten, keepInstances, namedParts)
  unmate(result, unmated)
  # A part that brings its own model owns its pins: a pull stated on one
  # is not emitted (`expandPinModels` does that only for stand-ins), and
  # saying so beats a pulled-up pin silently reading low.
  for d, c in result.work.components:
    if d in replaceExclude or selectSimModel(c, purpose) == nil: continue
    for _, p in c.pins:
      if hasPull(p):
        result.assumptions.add note(d & "." & p.name, "its stated internal " &
          "pull is not simulated: the part is replaced by its own model, " &
          "which owns its pins")
  applySimReplacements(result.work, replaceExclude, purpose = purpose)
  result.netlist = result.work

proc modelUnmodelled*(b: var Bench, d = defaultPinModels(),
                      exclude: openArray[string] = []) =
  ## Stage 2.
  b.assumptions.add expandPinModels(b.work, d, exclude)

proc scopeBench*(b: var Bench, req: ScopeRequest) =
  ## Stage 3. Records the strategy, seeds and what was cut in `b.info`.
  var req = req
  if req.design == nil: req.design = b.design
  b.scoped = scope(b.work, req, b.globals)
  b.netlist = b.scoped.netlist
  b.assumptions.add b.scoped.assumptions
  b.info.strategy = req.strategy
  b.info.strategyDoc = regionStrategy(req.strategy).doc
  b.info.seedParts = req.seedParts
  b.info.seedNets = req.seedNets
  b.info.dropped = b.scoped.region.dropped

proc scopeBench*(b: var Bench, choice: ScopeChoice,
                 seedParts, seedNets: openArray[string]) =
  ## Stage 3 from an analysis spec's `ScopeChoice`.
  var req = ScopeRequest(strategy: choice.strategy, icSinks: choice.icSinks)
  for p in seedParts:
    if p.len > 0 and p notin req.seedParts: req.seedParts.add p
  for n in seedNets:
    if n.len > 0 and n notin req.seedNets: req.seedNets.add n
  b.scopeBench(req)

proc record(b: var Bench, role: BenchRole, c: Component, text: string) =
  var nets: seq[string]
  for _, p in c.pins:
    if p.net != nil and p.net.name notin nets: nets.add p.net.name
  b.info.items.add BenchItem(role: role, designator: c.designator,
                             nets: nets, text: text)

proc stimulus*(b: var Bench, c: Component, text: string, owner = "") =
  ## `c` (already wired into `b.netlist`) drives the measurement. `owner`:
  ## the design part it stands in for, if any (a regulator's ramp).
  mark(c, brStimulus, owner, text)
  record(b, brStimulus, c, text)

proc load*(b: var Bench, c: Component, text: string) =
  ## `c` is a test load the analysis applies.
  mark(c, brLoad, note = text)
  record(b, brLoad, c, text)

proc probe*(b: var Bench, c: Component, text: string) =
  ## `c` exists to be read (a current-sense source).
  if benchRole(c).len == 0: mark(c, brProbe, note = text)
  record(b, brProbe, c, text)

proc probe*(b: var Bench, net: string, text: string) =
  ## A node read directly.
  let n = b.netlist.nets.getOrDefault(net)
  if n != nil and benchRole(n).len == 0: mark(n, brProbe, note = text)
  b.info.items.add BenchItem(role: brProbe, nets: @[net], text: text)
  if net notin b.info.focus: b.info.focus.add net

proc probeCurrent*(b: var Bench, designator: string, text: string) =
  ## The current through a design part, read off its own branch (the part
  ## is not marked: it is still the design's).
  var nets: seq[string]
  let c = b.netlist.components.getOrDefault(designator)
  if c != nil:
    for _, p in c.pins:
      if p.net != nil and p.net.name notin nets: nets.add p.net.name
  b.info.items.add BenchItem(role: brProbe, designator: designator,
                             nets: nets, text: text)

proc focus*(b: var Bench, nets: varargs[string]) =
  for n in nets:
    if n.len > 0 and n notin b.info.focus: b.info.focus.add n

proc detached*(b: var Bench, parts: openArray[string]) =
  for p in parts: b.info.detached.add p

proc run*(b: Bench, analysis: string, setup: seq[string] = @[],
          codemodels: seq[string] = @[], label = ""): SimResult =
  ngspice.run(b.netlist, analysis, setup, codemodels, label, b.info)

proc run*(b: Bench, cards: seq[string], codemodels: seq[string] = @[],
          label = ""): SimResult =
  ngspice.run(b.netlist, cards, codemodels, label, b.info)
