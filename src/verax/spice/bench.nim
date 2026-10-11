## A test bench: what an analysis simulates, declared rather than
## hand-built. Every simulator-backed analysis builds its circuit through
## one of these, in stages it calls in its own order:
##
## 1. `openBench` -- clone, flatten (`flattenForSim`), apply `simReplace`s
##    for the analysis's purpose.
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

import std/tables
import ../netlist/types
import ../netlist/graph
import ../netlist/annotations
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

proc openBench*(nl: Netlist, name, purpose: string, flatten = true,
                keepInstances: openArray[string] = [],
                namedParts: openArray[string] = [],
                replaceExclude: openArray[string] = []): Bench =
  ## Stage 1. `nl` is never modified.
  result.info.name = name
  result.info.strategy = "whole"
  result.design = nl
  var cloneNets: OrderedTable[string, Net]
  result.work = clone(nl, cloneNets)
  discard flattenForSim(result.work, flatten, keepInstances, namedParts)
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
