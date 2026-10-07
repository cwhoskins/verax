## Extracting part of a netlist for simulation. `extractInstance` clones an
## existing hierarchical instance; `extractSubcircuit` clones the whole
## netlist, strips everything unselected, and promotes boundary nets to
## ports. Both return a plain `Netlist`.

import std/[tables, sets]
import ../netlist/types
import ../netlist/graph

proc extractInstance*(comp: Component, globalNets: var OrderedTable[string, Net]): Netlist =
  ## `comp.subNetlist` must be non-nil; returns a detached clone.
  if comp.subNetlist == nil:
    raise newException(NetlistError,
      "component has no subNetlist to extract: " & comp.designator)
  result = clone(comp.subNetlist, globalNets)

proc extractSubcircuit*(nl: Netlist, name: string, designators: openArray[string],
                         globalNets: var OrderedTable[string, Net]): Netlist =
  ## Selects `designators` from `nl.components` only (pass the owning
  ## netlist for nested parts). Nets touching both selected and unselected
  ## components become ports, named after themselves.
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
