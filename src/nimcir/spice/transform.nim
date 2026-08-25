## Simulation-only component replacement.
##
## `replaceComponent` swaps a component for a simpler simulation model (e.g.
## an ideal voltage source in place of a voltage-regulator IC). It mutates
## whatever `Netlist` it's given -- callers should call it on a clone (or on
## the netlist `materializeSimNetlist` produces), never on the real design
## netlist, so the source-of-truth netlist is never silently altered by a
## simulation concern.
##
## `materializeSimNetlist` is the bridge from the DSL's co-located
## `simReplace` annotations (see `nimcir/netlist/dsl`) to an actual
## simulation-ready netlist: it clones the given netlist and applies every
## stored `Component.simReplace` it finds, recursing into hierarchy.

import std/[tables, sequtils]
import ../netlist/types
import ../netlist/graph
import ../netlist/formats/spice as spiceFormat

proc replaceComponent*(nl: Netlist, oldDesignator: string, kind: string,
                        pinNets: openArray[(string, Net)],
                        newDesignator = "", partNumber = "",
                        attrs: openArray[(string, string)] = []): Component =
  ## Removes `nl.components[oldDesignator]` and adds a fresh `Component` of
  ## `kind` in its place, connecting `pinNets[i][0] -> pinNets[i][1]` for
  ## each entry.
  ##
  ## `newDesignator`, if empty, is auto-derived from `kind`'s SPICE-convention
  ## prefix letter (e.g. `"voltage_source"` -> `'V'`), reusing any trailing
  ## digits from `oldDesignator` if present (`"U1"` -> `"V1"`). Reusing the
  ## old designator verbatim would be wrong: SPICE infers device type from
  ## the designator's leading letter, not any `kind` field, so a synthesized
  ## voltage source still named `"U1"` would be misparsed/rejected by
  ## ngspice, not silently work.
  if not nl.components.hasKey(oldDesignator):
    raise newException(NetlistError, "no such component: " & oldDesignator)

  var designator = newDesignator
  if designator.len == 0:
    let prefix = spiceFormat.designatorPrefix(kind)
    var digits = ""
    for i in countdown(oldDesignator.high, 0):
      if oldDesignator[i] in {'0'..'9'}:
        digits = oldDesignator[i] & digits
      else:
        break
    designator = prefix & (if digits.len > 0: digits else: "1")

  removeComponent(nl, oldDesignator)
  result = addComponent(nl, newComponent(designator, partNumber = partNumber, kind = kind))
  for (key, value) in attrs:
    result.attrs[key] = value
  for (pinName, net) in pinNets:
    discard connect(result, pinName, net)

proc applySimReplacements(nl: Netlist, exclude: openArray[string] = []) =
  var designators: seq[string]
  for designator in nl.components.keys:
    designators.add designator
  for designator in designators:
    if designator in exclude: continue
    let comp = nl.components[designator]
    let repl = comp.simReplace
    if repl != nil and repl.build != nil:
      # The replacement builds itself. It is handed the clone and the part it
      # stands in for, and is responsible for removing that part -- which is
      # what lets it register a `.MODEL` card and render its own ports.
      discard repl.build(nl, comp)
    elif repl != nil:
      var pinNets: seq[(string, Net)]
      for pinName, netName in repl.pinNets:
        if not nl.nets.hasKey(netName):
          raise newException(NetlistError,
            "simReplace on " & designator & " references unknown net: " & netName)
        pinNets.add (pinName, nl.nets[netName])
      discard replaceComponent(nl, designator, repl.kind, pinNets,
                                newDesignator = repl.designator, partNumber = repl.partNumber,
                                attrs = toSeq(repl.attrs.pairs))
  for _, child in nl.children:
    applySimReplacements(child, exclude)

proc materializeSimNetlist*(nl: Netlist, globalNets: var OrderedTable[string, Net],
                            exclude: openArray[string] = []): Netlist =
  ## Clones `nl` (via `graph.clone` -- `nl` itself is never mutated), then
  ## recursively walks the clone (including its `children`, for nested
  ## hierarchy) applying every component's stored `simReplace`, if any.
  ##
  ## `exclude` names components to leave alone. `analysis/startup` needs it:
  ## it applies the regulator's own `simReplace` itself, on the fragment and
  ## after isolation, because it takes over the designator so the inrush
  ## probe knows which branch to measure. Applying it here as well would
  ## replace the part twice.
  result = clone(nl, globalNets)
  applySimReplacements(result, exclude)
