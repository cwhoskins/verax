## Attaching the LT8640A behavioural models to a design.
##
## The design file declares the **real part** -- `kind = "buck"`,
## `partNumber = "LT8640A"`, with the datasheet's pin names -- and this
## module attaches a simulation-only stand-in beside it. That separation is
## the whole reason `Component.simReplace` exists: the netlist a BoM, a board
## layout or `explain` reads must be the part that gets soldered, not the
## `A` device that models it.
##
## `SimReplacement.build` rather than its `kind`/`pinNets` fields, because a
## code model needs three things that shape cannot express: a `.MODEL` card
## registered in `Netlist.models` (without which `kinds.hasDeviceModel` is
## false, the part is not passive, and `spice/isolate` drops it at the
## boundary), an ordered port binding, and port text rendered from the
## model's own `ModelSpec` so a miscount is caught here rather than as a
## `MIF-ERROR` out of ngspice.
##
## The `.cm` is built on demand into a cache directory and its path is
## recorded on the component as `xspice.cm`, which `spice/ngspice.run`
## collects off whatever fragment finally reaches the simulator.
##
## **Two models, not one.** `useLt8640a` attaches both `lt8640a_avg` and
## `lt8640a_sw` and lets `spice/transform.selectSimModel` choose. The averaged
## one is the default -- it answers the operating point, the rail voltage and
## the start-up ramp, and it does so in a run measured in milliseconds of wall
## clock. The switching one claims `spSteadyState` and answers the one
## question the averaged one is structurally unable to: what the ripple is.
## Reaching for a single model would have meant picking which of those the
## design is allowed to ask.

import std/[os, tables, times]

import verax/contract/dsl
import verax/netlist/graph
import verax/spice/xspice/instance
import verax/spice/xspice/build

import verax/spice/transform

import ./lt8640a_avg
import ./lt8640a_sw

proc cmPathFor(model: string): string =
  ## Builds the named model if it is not already built, and returns the `.cm`
  ## path.
  ##
  ## Lazy, and deliberately not done at module init: importing a parts library
  ## would then run `nim c` and a C compiler, so `verax check --offline` on a
  ## design that never simulates would pay several seconds and fail outright
  ## on a machine with no ngspice source tree. A design must stay inspectable
  ## with no simulator in the build.
  let cache = getEnv("VERAX_CACHE", getCacheDir() / "verax") / "codemodels"
  createDir(cache)
  # Lowercase: ngspice case-folds the lines it pre-parses, including
  # `pre_codemodel`, so a `.cm` whose path has an uppercase character in it
  # can never be loaded from a deck.
  result = cache / (model & ".cm")
  let src = currentSourcePath().parentDir / (model & ".nim")
  if fileExists(result) and getLastModificationTime(result) >=
     getLastModificationTime(src):
    return
  try:
    discard buildCodeModel(src, result)
  except CatchableError:
    # Building a `.cm` needs a *configured ngspice source tree* at
    # $NGSPICE_SRC, which a machine can perfectly well lack while still
    # having ngspice itself. Returning the path anyway is deliberate: the
    # component records it, `spice/ngspice.run` finds it missing, and the
    # reader gets one sentence naming the file and how to build it. Raising
    # here instead would abort the whole design -- including the static
    # checks and every claim that needs no simulator at all -- for a part
    # that may not even be on the path of what they asked about.
    discard

proc partNets(old: Component): seq[Net] =
  ## The nets the model's ports bind to, in the model's own declaration order.
  ##
  ## Pin names are the datasheet's; an `A` line is positional in the order the
  ## code model declares its ports. Mapping between them here, once, is the
  ## point -- a design should never have to know a model's port order. Both
  ## models declare the same seven ports in the same order, deliberately, so
  ## that swapping one for the other is a choice about *fidelity* and not
  ## about wiring.
  const want = ["VIN", "FB", "EN", "TR/SS", "SW", "PG", "BST"]
  for pinName in want:
    if not old.pins.hasKey(pinName):
      raise newException(NetlistError,
        old.designator & " has no pin '" & pinName & "'; the LT8640A models " &
        "need VIN, FB, EN, TR/SS, SW, PG and BST")
    let n = old.pins[pinName].net
    if n == nil:
      raise newException(NetlistError,
        old.designator & "." & pinName & " is not connected, and the models " &
        "have no way to represent an open pin")
    result.add n

proc buildLt8640aAvg(nl: Netlist, old: Component): Component =
  ## Replaces the real part with the averaged `A` device, wired to the same
  ## nets.
  let nets = partNets(old)
  let desig = old.designator
  removeComponent(nl, desig)
  addCodeModelInstance(nl, "A" & desig, lt8640a_avgSpec, nets,
                       cmPath = cmPathFor("lt8640a_avg"))

proc buildLt8640aSw(nl: Netlist, old: Component): Component =
  ## The same, with the switching model.
  ##
  ## `fsw` is the one parameter that has to be passed rather than defaulted:
  ## the board sets the switching frequency with RT, and no model can read a
  ## frequency off a resistor. It is left at the model's own default here and
  ## overridden by `useLt8640a`'s `fsw` argument, so a design that changes RT
  ## says so in one place. `ilim`/`dmax` are the same shape for the two
  ## behaviours this part actually exposes a way to change -- see
  ## `useLt8640a`'s own doc comment for why those two and not a `MODE` pin.
  let nets = partNets(old)
  let desig = old.designator
  removeComponent(nl, desig)
  var params: seq[(string, string)]
  for key in ["fsw", "ilim", "dmax"]:
    let v = old.attrs.getOrDefault("lt8640a." & key, "")
    if v.len > 0: params.add (key, v)
  addCodeModelInstance(nl, "A" & desig, lt8640a_swSpec, nets, params,
                       cmPath = cmPathFor("lt8640a_sw"))

proc useLt8640a*(d: Design, designator: string, fsw = 1.0e6,
                 ilim = 0.0, dmax = 0.0) =
  ## Attaches both behavioural models to the named part. Call it after the
  ## `design(...)` block; it only adds to `simModels` and touches nothing
  ## else, so the design netlist still describes the board.
  ##
  ## By *designator* rather than by `Component`, because the DSL's `let`
  ## bindings are scoped to the macro's own block and a design file imports
  ## no `std/tables` -- so `d.netlist.components["U1"]` does not even
  ## compile. A helper meant to be called from a design has to be reachable
  ## with what a design has.
  ##
  ## `fsw` is what RT sets on the board. It reaches the switching model as an
  ## instance parameter and is recorded on the component, so it survives the
  ## clone -> flatten -> model -> isolate path that stands between a design
  ## and a deck.
  ##
  ## `ilim`/`dmax` are the closest this model comes to the real part's
  ## `SYNC/MODE` pin: the real LT8640A has one (Burst Mode vs. pulse-skip vs.
  ## an external sync clock) and `lt8640a_sw`'s port list does not model it
  ## at all -- see that module's own doc comment on what is a datasheet
  ## figure and what is a stand-in. What the model *does* expose as tunable
  ## behaviour is its peak current limit (`ilim`, datasheet-adjacent: this
  ## part's is fixed near 7 A, so a design asking for a different one is
  ## stating a simulation choice, not a strap) and its maximum duty cycle
  ## (`dmax`, which is what a dropout condition runs into). `0.0` for either
  ## means "leave the model's own default" -- neither is written to `attrs`
  ## unless a caller states one, so every existing design that never mentions
  ## them is byte-for-byte unaffected.
  let c = findComponent(d.netlist, designator)
  if c == nil:
    raise newException(NetlistError,
      "no such component: " & designator & " (attaching the LT8640A models)")
  c.attrs["lt8640a.fsw"] = $fsw
  if ilim > 0.0: c.attrs["lt8640a.ilim"] = $ilim
  if dmax > 0.0: c.attrs["lt8640a.dmax"] = $dmax
  addSimModel(c, newSimReplacement(buildLt8640aAvg, name = "averaged"))
  addSimModel(c, newSimReplacement(buildLt8640aSw, name = "switching",
                                   suits = [spSteadyState]))
  # Explicit rather than relying on insertion order: which model answers a
  # question nobody labelled is a decision worth writing down.
  c.simDefault = "averaged"
