## Growing a region of a netlist from seeds: the graph half of every
## scoping strategy (`spice/region_strategy` adds what closes each cut in a
## deck; `report` grows picture regions with the same walk).
##
## A walk is breadth-first over nets. Each part reached is asked of
## `RegionRules.absorb`: take it and walk on through its other pins
## (`raInclude`), take it but stop there (`raBoundary` -- a block drawn at the
## edge), or leave it out (`raDrop`, recorded in `dropped`). A net is walked
## *from* only if `traverseNet` agrees -- the default refuses rails unless
## seeded, since every bypass cap shares VDD. `maxHops` is a backstop.
##
## Never mutates its input.

import std/[sets, strutils, tables]
import ./types
import ./kinds
import ./graph

type
  RegionAction* = enum
    raInclude   ## in the region, and walked through
    raBoundary  ## in the region, not walked through
    raDrop      ## left out; recorded in `Region.dropped`

  RegionRules* = object
    maxHops*: int
      ## How many nets from a seed growth may reach.
    absorb*: proc (c: Component, via: Net): RegionAction {.closure.}
      ## What to do with a part the walk reaches, and the net it was
      ## reached through. nil -> `raInclude`.
    traverseNet*: proc (n: Net, seeded: bool): bool {.closure.}
      ## Whether to walk on from `n`. nil -> `defaultTraverseNet`.
    closeCouplings*: bool
      ## Pull in a pinless coupling (`K`) once all the inductors it names
      ## are in the region -- the walk can't reach a part with no pins.

  Region* = object
    parts*: seq[string]
      ## Every part in the region (seeds first, then in the order reached),
      ## boundary blocks included.
    boundary*: seq[string]
      ## The `raBoundary` subset of `parts`.
    dropped*: seq[string]
      ## Parts the walk reached and left out, in the order reached.
    nets*: seq[string]
      ## Nets the walk visited, in order.
    rails*: seq[string]
      ## Visited nets `isRail` holds for (walked through or not).

proc defaultTraverseNet*(n: Net, seeded: bool): bool =
  ## A rail is a boundary, not a highway -- unless the caller seeded it.
  seeded or not isRail(n)

proc growRegion*(nl: Netlist, seedParts: openArray[string],
                 seedNets: openArray[Net], rules: RegionRules): Region =
  ## Seeds are always in the region (seed parts as `raInclude`); every pin
  ## of a seed part starts the walk, as does every seed net.
  var seedNetNames = initHashSet[string]()
  for n in seedNets: seedNetNames.incl n.name

  var selected = initOrderedSet[string]()
  for d in seedParts:
    if not nl.components.hasKey(d):
      raise newException(NetlistError, "no such component: " & d)
    selected.incl d

  var visited = initHashSet[string]()
  var queue: seq[tuple[net: Net, hop: int]]
  var droppedSeen = initHashSet[string]()

  template enqueue(n: Net, h: int) =
    if n != nil and n.name notin visited and h <= rules.maxHops:
      visited.incl n.name
      queue.add (net: n, hop: h)
      result.nets.add n.name
      if isRail(n): result.rails.add n.name

  for d in seedParts:
    for _, p in nl.components[d].pins:
      enqueue(p.net, 0)
  for n in seedNets:
    enqueue(n, 0)

  var qi = 0
  while qi < queue.len:
    let (net, hop) = queue[qi]
    inc qi
    let walk = if rules.traverseNet == nil:
                 defaultTraverseNet(net, net.name in seedNetNames)
               else: rules.traverseNet(net, net.name in seedNetNames)
    if not walk: continue

    for p in net.pins:
      let comp = p.component
      if comp == nil or comp.designator in selected: continue
      let action = if rules.absorb == nil: raInclude
                   else: rules.absorb(comp, net)
      case action
      of raDrop:
        if comp.designator notin droppedSeen:
          droppedSeen.incl comp.designator
          result.dropped.add comp.designator
      of raBoundary:
        selected.incl comp.designator
        result.boundary.add comp.designator
      of raInclude:
        selected.incl comp.designator
        for _, other in comp.pins:
          if other.net != nil and other.net != net:
            enqueue(other.net, hop + 1)

  if rules.closeCouplings:
    for _, comp in nl.components:
      if comp.kind notin couplingKinds or comp.designator in selected: continue
      let couples = comp.attrs.getOrDefault("spice.couples", "")
      if couples.len == 0: continue
      var all = true
      for d in couples.split(','):
        if d.strip() notin selected: all = false
      if all: selected.incl comp.designator

  for d in selected: result.parts.add d

# --- names as `spice/flatten` will spell them ----------------------------

proc instancePath(nl: Netlist): seq[string] =
  ## Designators of the instances from the root down to `nl`.
  var cur = nl
  while cur != nil and cur.instanceOf != nil:
    result.insert(cur.instanceOf.designator, 0)
    cur = cur.parent

proc flatName*(c: Component): string =
  ## `c`'s designator once its instances are flattened (`XA.XB.R1`).
  var parts = instancePath(c.netlist)
  parts.add c.designator
  parts.join($hierSep)

proc flatName*(n: Net): string =
  ## `n`'s name once flattened: a port net takes the name of the net it is
  ## wired to outside; ground and globals keep theirs.
  var cur = n
  while true:
    let nl = cur.netlist
    if nl == nil or nl.instanceOf == nil or isGround(cur): return cur.name
    var outer: Net = nil
    for _, p in nl.instanceOf.pins:
      if p.hierNet == cur and p.net != nil:
        outer = p.net
        break
    if outer == nil: break
    cur = outer
  var parts = instancePath(cur.netlist)
  parts.add cur.name
  parts.join($hierSep)
