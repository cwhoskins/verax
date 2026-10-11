## Simulation-only component replacement.
##
## `replaceComponent` swaps a component for a simpler model (e.g. an ideal
## source for a regulator IC). It mutates its argument -- call it on a clone,
## never the design. `materializeSimNetlist` clones and applies every stored
## `simReplace`, recursing into hierarchy.
##
## **Which model, when a part carries several**: `selectSimModel` picks by
## the *purpose* the caller states (what is being asked), not by analysis
## card -- two `.tran` models can answer different questions.

import std/[strutils, tables, sequtils]
import ../netlist/types
import ../netlist/graph
import ../netlist/formats/spice as spiceFormat
import ./provenance

const
  spOperating* = "op"
    ## Where the circuit sits: one `.op` solve, nothing moving.
  spSmallSignal* = "ac"
    ## A frequency response, linearised about the operating point.
  spStartup* = "startup"
    ## A large-signal transient from nothing, watching something come up.
  spSteadyState* = "steady_state"
    ## A transient past settling, looking at what remains: ripple, a limit
    ## cycle, a regulating converter's waveform.
  spLargeSignal* = "large_signal"
    ## A transient driven hard enough that linearising would be wrong:
    ## clipping, saturation, distortion.

  simPurposes* = [spOperating, spSmallSignal, spStartup, spSteadyState,
                  spLargeSignal]
    ## The built-in vocabulary; open, so third-party analyses can name their
    ## own purposes.

proc selectSimModel*(c: Component, purpose = ""): SimReplacement =
  ## The model to stand in for `c` for `purpose`: one naming it in `suits`,
  ## else the default. Two models naming the same purpose raises.
  if c == nil or c.simModels.len == 0: return nil
  if purpose.len == 0: return defaultSimModel(c)

  var matched: seq[SimReplacement]
  for _, sr in c.simModels:
    if purpose in sr.suits: matched.add sr
  if matched.len == 1: return matched[0]
  if matched.len > 1:
    var names: seq[string]
    for sr in matched:
      names.add (if sr.name.len > 0: "'" & sr.name & "'" else: "an unnamed model")
    raise newException(NetlistError,
      "component " & c.designator & " carries " & $matched.len &
      " simulation models for the same purpose '" & purpose & "': " &
      names.join(", ") & " -- exactly one may claim a purpose, so drop it " &
      "from the `suits` of the others")
  defaultSimModel(c)

proc replaceComponent*(nl: Netlist, oldDesignator: string, kind: string,
                        pinNets: openArray[(string, Net)],
                        newDesignator = "", partNumber = "",
                        attrs: openArray[(string, string)] = []): Component =
  ## Replaces `nl.components[oldDesignator]` with a fresh `kind` component,
  ## wired per `pinNets`. An empty `newDesignator` derives the SPICE prefix
  ## from `kind`, keeping trailing digits (`"U1"` -> `"V1"`): SPICE reads
  ## type from the leading letter.
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

proc applySimReplacements*(nl: Netlist, exclude: openArray[string] = [],
                          purpose = "") =
  ## Applies every component's stored `simReplace`, recursing into children.
  ## Exported so analyses can run it **after** `spice/flatten`: an XSPICE `A`
  ## line's port text is rendered once and frozen, so replacing before
  ## flattening leaves nested ports naming nets that no longer exist
  ## (singular matrix, "Timestep too small"). `materializeSimNetlist` is
  ## still right for callers that never flatten.
  ##
  ## Limitations of running post-flatten:
  ##
  ## * `exclude` matches designators exactly, so a part nested inside another
  ##   dissolving instance (`"XL.U1"`) isn't matched by `"U1"`.
  ## * A `build` proc must not look up a sibling net by bare name
  ##   (`findNet(nl, "gndiso")`): `nl` is the flattened top, where it's
  ##   `"XPOE.gndiso"`. Ground (`"0"`) is the only safe bare name; derive other
  ##   nets from `old.pins[...]`.
  var designators: seq[string]
  for designator in nl.components.keys:
    designators.add designator
  for designator in designators:
    if designator in exclude: continue
    let comp = nl.components[designator]
    let repl = selectSimModel(comp, purpose)
    if repl == nil: continue
    provenance(nl, comp, brStandIn):
      if repl.build != nil:
        # The replacement builds itself and must remove the part it replaces.
        discard repl.build(nl, comp)
      else:
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
    applySimReplacements(child, exclude, purpose)

proc materializeSimNetlist*(nl: Netlist, globalNets: var OrderedTable[string, Net],
                            exclude: openArray[string] = [],
                            purpose = ""): Netlist =
  ## Clones `nl` (never mutated) and applies every stored `simReplace`,
  ## recursing into children.
  ##
  ## `exclude` names parts to leave alone (`analysis/startup` applies the
  ## regulator's own model itself, after isolation). `purpose` selects among
  ## multiple models (see `selectSimModel`).
  result = clone(nl, globalNets)
  applySimReplacements(result, exclude, purpose)
