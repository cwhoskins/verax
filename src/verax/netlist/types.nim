## Core, format-agnostic netlist data model. Nets, components and pins are
## `ref object`s with direct back-references (pin <-> component, pin <->
## net, netlist <-> children), so the graph is walkable from anywhere; ORC
## collects the cycles. Every entity carries an open `attrs` bag so formats
## never extend the schema.

import std/tables

type
  NetlistError* = object of CatchableError
    ## Raised on graph-consistency violations (duplicate designator or net
    ## name in one `Netlist`).

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
      ## Every simulation-only stand-in, keyed by model `name`, in insertion
      ## order; empty for most parts and irrelevant outside simulation.
      ##
      ## A part may need several: an averaged switching-regulator model
      ## answers settling and start-up quickly but has no ripple; a switching
      ## model shows ripple at much higher cost. Reach one via `simReplace`
      ## (the default) or `spice/transform.selectSimModel` (by purpose).
    simDefault*: string
      ## The `simModels` entry used when no purpose is stated or none suits;
      ## empty means the first added.
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
    ## A simulation-only override: "replace this component with a device of
    ## `kind`, wired per `pinNets`". Stored on the component so it can't
    ## drift, but never mutates it; applied only to a materialized clone
    ## (`spice/transform.materializeSimNetlist`).
    name*: string
      ## The model's name within its component (key in `simModels`); empty is
      ## fine for a single model.
    suits*: seq[string]
      ## Purposes this model is *preferred* for (`sp*` consts in
      ## `spice/transform`; open strings). Advisory: naming a purpose wins
      ## selection for it, but never refuses other purposes. Two models
      ## claiming one purpose raises.
    kind*: string
      ## The replacement component's `kind`, e.g. "voltage_source".
    designator*: string
      ## Replacement designator; empty auto-derives a SPICE-correct prefix
      ## from `kind` (`spice/transform.replaceComponent`).
    partNumber*: string
    pinNets*: OrderedTable[string, string]
      ## Replacement pin name -> net NAME (applied to a later clone with
      ## distinct `Net` objects, so names, not references).
    attrs*: OrderedTable[string, string]
    build*: proc (nl: Netlist, old: Component): Component {.nimcall.}
      ## When set, **replaces** `kind`/`pinNets`/`attrs`: given the clone and
      ## the component, it builds the stand-in itself. Needed for XSPICE code
      ## models, which require a registered `.MODEL` card (or isolation drops
      ## the part), an ordered/grouped port binding, and port text rendered
      ## from the `ModelSpec`. Mentions only netlist types, so dependencies
      ## still point the right way.

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
# One table, reached only through these accessors -- never a separate
# `simReplace` field beside it, which would give "what stands in for this
# part" two answers.

proc addSimModel*(c: Component, sr: SimReplacement) =
  ## Adds a simulation model keyed by `sr.name`. Raises on a duplicate name
  ## (silently replacing would change which analysis answers); remove the
  ## old one first.
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
  ## Drops the named model; silent if absent.
  c.simModels.del(name)
  if c.simDefault == name: c.simDefault = ""

proc defaultSimModel*(c: Component): SimReplacement =
  ## The model used when no purpose is stated: `simDefault` if set, else the
  ## first added; `nil` if none.
  if c.simModels.len == 0: return nil
  if c.simDefault.len > 0 and c.simModels.hasKey(c.simDefault):
    return c.simModels[c.simDefault]
  for _, sr in c.simModels: return sr

proc simReplace*(c: Component): SimReplacement =
  ## The component's default simulation model, or `nil`.
  defaultSimModel(c)

proc `simReplace=`*(c: Component, sr: SimReplacement) =
  ## Makes `sr` the component's only model, discarding others. Use
  ## `addSimModel` to carry several.
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
