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
    simReplace*: SimReplacement
      ## Set only when this component has a simulation-only replacement
      ## defined (see `nimcir/spice`). `nil` for every component that has
      ## none -- this field never affects non-simulation use of the netlist.
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

proc newSimReplacement*(kind: string, designator = "", partNumber = ""): SimReplacement =
  SimReplacement(kind: kind, designator: designator, partNumber: partNumber)

proc newSimReplacement*(build: proc (nl: Netlist, old: Component): Component {.nimcall.}):
    SimReplacement =
  ## A replacement that builds itself. See `SimReplacement.build`.
  SimReplacement(build: build)

proc newPin*(name: string, kind: PinType = ptUnknown): Pin =
  Pin(name: name, kind: kind)

proc newComponent*(designator: string, name = "", partNumber = "", kind = ""): Component =
  Component(designator: designator, name: name, partNumber: partNumber, kind: kind)

proc newNet*(name: string, kind: NetType = ntUnknown): Net =
  Net(name: name, kind: kind)

proc newNetlist*(name = "", parent: Netlist = nil): Netlist =
  Netlist(name: name, parent: parent)
