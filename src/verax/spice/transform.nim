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
## `simReplace` annotations (see `verax/netlist/dsl`) to an actual
## simulation-ready netlist: it clones the given netlist and applies every
## stored `Component.simReplace` it finds, recursing into hierarchy.
##
## **Which model, when a part carries several.** `Component.simModels` holds
## every stand-in a part has and `selectSimModel` picks one, by a *purpose*
## the caller states: what is being asked, not which SPICE card will be
## written. The distinction is load-bearing rather than pedantic -- the two
## LT8640A models are both `.tran` models, and the one that answers "how does
## this rail come up" is not the one that answers "how much ripple is on it".
## Naming the card would put them in the same bucket and leave the choice to a
## coin toss.

import std/[strutils, tables, sequtils]
import ../netlist/types
import ../netlist/graph
import ../netlist/formats/spice as spiceFormat

const
  spOperating* = "op"
    ## Where the circuit sits: one `.op` solve, nothing moving.
  spSmallSignal* = "ac"
    ## A frequency response, linearised about the operating point.
  spStartup* = "startup"
    ## A large-signal transient from nothing, watching something come up.
  spSteadyState* = "steady_state"
    ## A transient run past its settling, to look at what remains: ripple,
    ## a limit cycle, the waveform a converter makes once it is regulating.
  spLargeSignal* = "large_signal"
    ## A transient driven hard enough that linearising it would be a lie --
    ## clipping, saturation, distortion.

  simPurposes* = [spOperating, spSmallSignal, spStartup, spSteadyState,
                  spLargeSignal]
    ## The built-in vocabulary. Not closed: `SimReplacement.suits` is a `seq`
    ## of open strings for the same reason `Component.kind` is one, so a
    ## third-party analysis can name its own purpose and a model can declare
    ## itself for it without this list being edited.

proc selectSimModel*(c: Component, purpose = ""): SimReplacement =
  ## The model to stand in for `c` when the question being asked is `purpose`.
  ##
  ## A model naming the purpose in `suits` wins. Failing that, the component's
  ## default -- so a design that carries one model, or that carries several
  ## and only labelled the specialist, keeps working for every analysis. Two
  ## models naming the same purpose raises: that is a genuine ambiguity, and
  ## picking either would decide silently which analysis the design gets.
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

proc applySimReplacements*(nl: Netlist, exclude: openArray[string] = [],
                          purpose = "") =
  ## Applies every component's stored `simReplace`, recursing into
  ## `nl.children`. Exported so each analysis call site can run it *after*
  ## `spice/flatten` rather than before -- see `flatten.nim`'s module doc for
  ## why the ordering matters: an XSPICE `A` line's port text is rendered
  ## once at replacement time and kept as a frozen string (`addCodeModelInstance`,
  ## `probes.nim`), and flattening a nested instance afterward renames the
  ## underlying `Net` objects without ever revisiting that string. Run
  ## before flatten, a nested XSPICE component's ports stay stuck at
  ## child-template-local net names that no longer exist once flatten has
  ## renamed everything else, and the deck's `A` line names nodes nothing
  ## else in the circuit uses -- floating/duplicate nodes, a singular
  ## matrix, and ngspice reporting "Timestep too small" on what is actually
  ## a failed `.op`. `materializeSimNetlist` (clone + replace, combined)
  ## still exists and is still correct for a caller that never flattens --
  ## `tests/test_spice_transform.nim` pins that contract down -- so this
  ## does not fold flatten in; each of the nine analysis call sites now
  ## does clone -> flatten -> `applySimReplacements` as three explicit
  ## steps instead of `materializeSimNetlist` -> flatten as two.
  ##
  ## **`exclude` and `namedParts`-style designator matching stay
  ## string-exact against whatever nesting level a component sits at when
  ## this runs.** After the reorder that is *post-flatten*: a component
  ## nested one level inside a *different* dissolving instance now has a
  ## dotted designator (`"XL.U1"`), and a bare `exclude = ["U1"]` would
  ## silently stop matching it. Checked against every current caller and
  ## its tests -- none excludes or names a part that ends up nested inside
  ## an instance other than its own -- so this is not a live regression,
  ## only a narrower latent limitation the reorder exposes. Fixing it would
  ## need dot-aware matching (compare against the trailing `hierSep`
  ## segment as well as the whole string); out of scope here.
  ##
  ## **A second, live one, found by actually nesting every design that has
  ## a `SimReplacement.build`: a `build` proc that looks up a *sibling* net
  ## by bare name (`graph.findNet(nl, "gndiso")`, rather than through
  ## `old.pins[...]`) breaks under this reorder, because `nl` is no longer
  ## the sheet's own local scope by the time `build` runs -- it is the
  ## fully-flattened top netlist, where that name is `"XPOE.gndiso"`, not
  ## `"gndiso"`.** `designs/xbar_poe.nim`'s `buildSi3402` does exactly this
  ## (for `gndiso` and `swp`) and, nested inside `designs/xbar_switch.nim`,
  ## every one of that design's 15 assertions went from measured and
  ## passing to `esNotEvaluated` with `evaluator 'spice.pdn' failed:
  ## buildSi3402: missing OUT/0/gndiso` -- confirmed by isolating this
  ## reorder alone (every other call site and every other nested design
  ## byte-identical) and by reverting only `graph.nim`/`static.nim`'s
  ## unrelated `[static]`-evaluator fix (no change). **Ground (`"0"`) is the
  ## one bare name that stays safe** -- `graph.clone`'s `globalNets` and
  ## `flatten`'s own doc comment both single it out as merged rather than
  ## renamed, the one net shared by identity at every level of hierarchy --
  ## which is why `xbar_power.nim`'s `buildIdealBuck` and
  ## `designs/lib/adjreg.nim`'s `buildAdjRegLoop`, which only ever look up
  ## `findNet(nl, "0")`, measured byte-identical before and after. Every
  ## other net name is not safe to look up bare inside a `build` proc once
  ## it might run post-flatten; deriving from `old.pins[...]` (as
  ## `designs/lib/lt8640a.nim`'s `partNets` does) is safe because a `Pin`
  ## is a direct object reference that `flatten` never invalidates, only
  ## renames the `Net` it points at. Not fixed here: `designs/xbar_poe.nim`
  ## is a design file, out of this fix's scope, and the honest fix is not
  ## small -- `gndiso` is not one of `U1`'s own pins, so there is no
  ## `old.pins[...]` to read it from, and `SimReplacement.build` is
  ## `{.nimcall.}` with nothing to capture a sibling net in at declaration
  ## time either.
  var designators: seq[string]
  for designator in nl.components.keys:
    designators.add designator
  for designator in designators:
    if designator in exclude: continue
    let comp = nl.components[designator]
    let repl = selectSimModel(comp, purpose)
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
    applySimReplacements(child, exclude, purpose)

proc materializeSimNetlist*(nl: Netlist, globalNets: var OrderedTable[string, Net],
                            exclude: openArray[string] = [],
                            purpose = ""): Netlist =
  ## Clones `nl` (via `graph.clone` -- `nl` itself is never mutated), then
  ## recursively walks the clone (including its `children`, for nested
  ## hierarchy) applying every component's stored `simReplace`, if any.
  ##
  ## `exclude` names components to leave alone. `analysis/startup` needs it:
  ## it applies the regulator's own `simReplace` itself, on the fragment and
  ## after isolation, because it takes over the designator so the inrush
  ## probe knows which branch to measure. Applying it here as well would
  ## replace the part twice.
  ##
  ## `purpose` says what is being asked, and only matters for a part carrying
  ## more than one model; see `selectSimModel`. Every analysis in this library
  ## passes its own, so a design that labels a model for one of them gets it
  ## without any call site having to know the design.
  result = clone(nl, globalNets)
  applySimReplacements(result, exclude, purpose)
