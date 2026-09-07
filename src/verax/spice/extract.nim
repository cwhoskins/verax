## Extracting a subcircuit out of a larger netlist so only that part needs
## to be simulated.
##
## Two cases:
##  - `extractInstance` for a component that's already hierarchical (has a
##    `subNetlist`) -- trivial, `clone()` already produces a detached,
##    port-preserving `Netlist`.
##  - `extractSubcircuit` for an arbitrary connected region of a flat (or
##    partially flat) netlist that isn't already organized as a subckt --
##    clones the whole netlist (reusing `clone()`'s nested-hierarchy/attrs
##    handling wholesale), strips everything not selected, and promotes
##    boundary nets to ports.
##
## Both return a plain `Netlist`, so `verax/spice/transform` and
## `verax/spice/probes` apply to the result with no glue code.

import std/[tables, sets]
import ../netlist/types
import ../netlist/graph

proc extractInstance*(comp: Component, globalNets: var OrderedTable[string, Net]): Netlist =
  ## `comp.subNetlist` must be non-nil. The result is a fresh clone with
  ## `.parent` unset -- exactly what "standalone" needs.
  if comp.subNetlist == nil:
    raise newException(NetlistError,
      "component has no subNetlist to extract: " & comp.designator)
  result = clone(comp.subNetlist, globalNets)

proc extractSubcircuit*(nl: Netlist, name: string, designators: openArray[string],
                         globalNets: var OrderedTable[string, Net]): Netlist =
  ## Selects `designators` directly from `nl.components` (no cross-level
  ## selection -- pass the exact owning `Netlist` for something nested
  ## inside a child, matching every other proc in this API). Any net with
  ## at least one pin on a selected component and at least one pin on a
  ## non-selected component becomes a port on the result, named after
  ## itself.
  var selected = initHashSet[string]()
  for d in designators:
    if not nl.components.hasKey(d):
      raise newException(NetlistError, "no such component: " & d)
    selected.incl d

  var boundary: seq[string]
  var boundarySeen = initHashSet[string]()
  for netName, net in nl.nets:
    var hasSelected = false
    var hasOther = false
    for p in net.pins:
      if p.component != nil:
        if p.component.designator in selected: hasSelected = true
        else: hasOther = true
    if hasSelected and hasOther and netName notin boundarySeen:
      boundarySeen.incl netName
      boundary.add netName

  result = clone(nl, globalNets)
  result.name = name

  var toRemove: seq[string]
  for designator in result.components.keys:
    if designator notin selected:
      toRemove.add designator
  for designator in toRemove:
    removeComponent(result, designator)

  for netName in boundary:
    addPort(result, netName, result.nets[netName])
