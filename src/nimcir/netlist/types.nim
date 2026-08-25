## Core, format-agnostic netlist data model.
##
## Nets, components and pins are `ref object`s wired together with direct
## back-references (pin <-> component, pin <-> net, netlist <-> children) so
## that the graph is fully walkable from any starting point, not just
## reachable via the name-keyed dictionaries on `Netlist`. Nim's default ORC
## memory management collects the resulting reference cycles automatically.
##
## Every entity carries an open-ended `attrs` bag for format-specific extras
## (e.g. a SPICE value/model token) so file-format modules never need to
## extend this core schema.

import std/tables

type
  NetlistError* = object of CatchableError
    ## Raised on graph-consistency violations, e.g. a duplicate reference
    ## designator or net name within the same `Netlist`.

  NetType* = enum
    ntUnknown, ntSignal, ntPower, ntGround

  PinType* = enum
    ptUnknown, ptInput, ptOutput, ptInOut, ptPower, ptGround, ptPassive

  Pin* = ref object
    name*: string
    kind*: PinType
    component*: Component
      ## Owning component (back-reference).
    net*: Net
      ## Net this pin is connected to, or `nil` if unconnected.
    hierNet*: Net
      ## Set only when `component` is a hierarchical instance: the matching
      ## port `Net` inside `component.subNetlist`.
    attrs*: OrderedTable[string, string]

  Component* = ref object
    name*: string
    designator*: string
      ## Reference designator, e.g. "R1", "U3" — key in `Netlist.components`.
    partNumber*: string
    kind*: string
      ## Open-ended component kind, e.g. "resistor", "capacitor", "subcircuit".
    pins*: OrderedTable[string, Pin]
    netlist*: Netlist
      ## Owning netlist (back-reference).
    subNetlist*: Netlist
      ## Set only when this component instantiates a child hierarchical
      ## netlist (e.g. a SPICE `X` device).
    simModels*: OrderedTable[string, SimReplacement]
      ## Every simulation-only stand-in this component carries, keyed by the
      ## model's own `name` and held in the order they were added. Empty for
      ## every component that has none -- this field never affects
      ## non-simulation use of the netlist.
      ##
      ## **A part may need more than one model, and which one is right depends
      ## on the question being asked.** The LT8640A is the case that forced
      ## it: an averaged model of a switching regulator answers "what does
      ## this rail settle to" and "how does it start up" in a run that takes
      ## milliseconds of wall clock, and cannot show ripple at all because the
      ## switch node in it *is* a cycle average. A switching model shows the
      ## ripple and costs a thousand timepoints per millisecond of circuit
      ## time. Neither is the better model; they answer different questions,
      ## and a design that had to pick one would be choosing which question it
      ## is allowed to ask.
      ##
      ## Reach a model through `simReplace` (the default) or
      ## `spice/transform.selectSimModel`, which picks by *purpose*.
    simDefault*: string
      ## Which entry of `simModels` is used when nothing states a purpose, or
      ## when no model suits the stated one. Empty means the first one added,
      ## which is what a part carrying exactly one model always wants.
    attrs*: OrderedTable[string, string]

  Net* = ref object
    name*: string
    kind*: NetType
    pins*: seq[Pin]
      ## Connected pins, walkable directly (not just via name lookup).
    netlist*: Netlist
      ## Owning netlist (back-reference).
    attrs*: OrderedTable[string, string]

  Netlist* = ref object
    name*: string
      ## Deck/sheet title at the root, or the sub-circuit name for a child.
    nets*: OrderedTable[string, Net]
    components*: OrderedTable[string, Component]
    parent*: Netlist
      ## `nil` for the root netlist.
    children*: OrderedTable[string, Netlist]
      ## Hierarchical sub-netlists, keyed by instance designator.
    ports*: OrderedTable[string, Net]
      ## Ordered subset of `nets` exposed to the parent scope.
    instanceOf*: Component
      ## Back-reference to the instantiating `Component` in `parent`.
    models*: OrderedTable[string, string]
      ## SPICE `.MODEL` passthrough: name -> raw remainder-of-line.
    attrs*: OrderedTable[string, string]

  SimReplacement* = ref object
    ## A simulation-only override for a `Component`: "for simulation
    ## purposes, replace this component with a device of `kind`, wired as
    ## `pinNets` describes". Stored on `Component.simReplace` -- co-located
    ## with the component's own definition so it can't drift out of sync
    ## with it -- but it never mutates the component itself; it only takes
    ## effect when a simulation-ready netlist is materialized from a clone
    ## (see `nimcir/spice/transform.materializeSimNetlist`).
    name*: string
      ## This model's name within its component, e.g. `"averaged"`. The key in
      ## `Component.simModels`. Empty is legal and is what a part carrying a
      ## single model gets -- it is only ever needed to tell two apart.
    suits*: seq[string]
      ## The purposes this model is *preferred* for, e.g.
      ## `@[spSteadyState]`. Open strings, like `Component.kind`; the built-in
      ## vocabulary is the `sp*` consts in `nimcir/spice/transform`, which is
      ## also where selection lives.
      ##
      ## Advisory, not binding, and that asymmetry is deliberate. Naming a
      ## purpose *wins* the selection for it; naming none means "no
      ## preference, use me when nothing better applies". What it must never
      ## do is refuse: a model that declared itself for steady-state only
      ## would otherwise make a `.op` on the same design impossible, and an
      ## analysis blocked by a preference is a worse outcome than one run
      ## against the default. Two models claiming one purpose *does* raise --
      ## that is an ambiguity nothing can resolve, not a preference.
    kind*: string
      ## The replacement component's `kind`, e.g. "voltage_source".
    designator*: string
      ## Reference designator for the replacement. Empty string means
      ## "auto-derive a SPICE-convention-correct prefix for `kind` at
      ## materialize time" (see `nimcir/spice/transform.replaceComponent`).
    partNumber*: string
    pinNets*: OrderedTable[string, string]
      ## Replacement pin name -> net NAME (not a `Net` reference: this is
      ## captured against the original netlist but only ever applied to a
      ## later clone of it, which has its own distinct `Net` objects with
      ## the same names).
    attrs*: OrderedTable[string, string]
    build*: proc (nl: Netlist, old: Component): Component {.nimcall.}
      ## When set, this **replaces** `kind`/`pinNets`/`attrs`: the proc is
      ## handed the materialized clone and the component to stand in for, and
      ## returns whatever it built.
      ##
      ## The fields above describe a replacement as one component of one
      ## `kind` wired by a flat pin-name-to-net-name table, which covers a
      ## regulator becoming an ideal source and not much else. An XSPICE code
      ## model needs three things that shape cannot express: a `.MODEL` card
      ## registered in `Netlist.models` (without which `kinds.hasDeviceModel`
      ## is false, the part is not passive, and `spice/isolate` drops it at
      ## the boundary -- the exact failure the model was added to fix); an
      ## *ordered and grouped* port binding, since a differential port takes
      ## two nodes and a vector port is bracketed; and the rendered port text
      ## produced from the model's own `ModelSpec` rather than hand-written,
      ## so a wrong node count is caught here instead of surfacing as a
      ## `MIF-ERROR` out of ngspice.
      ##
      ## It mentions only netlist types, so this file learns nothing about
      ## XSPICE and the dependency still points the right way.

proc newSimReplacement*(kind: string, designator = "", partNumber = "",
                        name = "", suits: openArray[string] = []): SimReplacement =
  SimReplacement(kind: kind, designator: designator, partNumber: partNumber,
                 name: name, suits: @suits)

proc newSimReplacement*(build: proc (nl: Netlist, old: Component): Component {.nimcall.},
                        name = "", suits: openArray[string] = []): SimReplacement =
  ## A replacement that builds itself. See `SimReplacement.build`.
  SimReplacement(build: build, name: name, suits: @suits)

# --- the models a component carries -----------------------------------------
#
# Storage is one table and the accessors below are the only way in, rather than
# a `simReplace` field beside a table of alternatives. Two places to look for a
# model is exactly the drift hazard this codebase avoids everywhere else: the
# question "what stands in for this part" would then have two answers that
# nothing keeps in step, and every consumer would have to know which of them to
# ask first.

proc addSimModel*(c: Component, sr: SimReplacement) =
  ## Adds one simulation model to `c`, keyed by `sr.name`.
  ##
  ## Raises on a duplicate name, for the reason `addComponent` raises on a
  ## duplicate designator: silently replacing the first would change which
  ## analysis is answering, with nothing said. Overwriting deliberately means
  ## removing the old one first.
  if sr == nil:
    raise newException(NetlistError,
      "addSimModel on " & c.designator & ": the model is nil")
  if c.simModels.hasKey(sr.name):
    raise newException(NetlistError,
      "component " & c.designator & " already carries a simulation model named '" &
      sr.name & "'" & (if sr.name.len == 0: " (an unnamed one)" else: "") &
      "; give the second one a distinct `name`")
  c.simModels[sr.name] = sr

proc removeSimModel*(c: Component, name: string) =
  ## Drops the named model. Silent if there is none, since "make sure this
  ## part carries no averaged model" is a reasonable thing to ask twice.
  c.simModels.del(name)
  if c.simDefault == name: c.simDefault = ""

proc defaultSimModel*(c: Component): SimReplacement =
  ## The model used when nothing states a purpose: `simDefault` if it names
  ## one, else the first added. `nil` when the component carries none.
  if c.simModels.len == 0: return nil
  if c.simDefault.len > 0 and c.simModels.hasKey(c.simDefault):
    return c.simModels[c.simDefault]
  for _, sr in c.simModels: return sr

proc simReplace*(c: Component): SimReplacement =
  ## The component's default simulation model, or `nil`.
  ##
  ## A proc rather than a field so that the one-model case -- which is every
  ## caller that predates multiple models, and still most of them -- reads and
  ## writes exactly as it did.
  defaultSimModel(c)

proc `simReplace=`*(c: Component, sr: SimReplacement) =
  ## Makes `sr` the component's *only* model, discarding any it already had.
  ##
  ## "Assign the model" can only mean this: the field it replaces held one
  ## value, so a caller writing it is saying what stands in for this part, not
  ## adding to a set. A design carrying several says so with `addSimModel`.
  c.simModels.clear()
  c.simDefault = ""
  if sr != nil: c.simModels[sr.name] = sr

proc newPin*(name: string, kind: PinType = ptUnknown): Pin =
  Pin(name: name, kind: kind)

proc newComponent*(designator: string, name = "", partNumber = "", kind = ""): Component =
  Component(designator: designator, name: name, partNumber: partNumber, kind: kind)

proc newNet*(name: string, kind: NetType = ntUnknown): Net =
  Net(name: name, kind: kind)

proc newNetlist*(name = "", parent: Netlist = nil): Netlist =
  Netlist(name: name, parent: parent)
