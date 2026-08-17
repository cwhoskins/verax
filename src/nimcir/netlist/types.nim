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

proc newPin*(name: string, kind: PinType = ptUnknown): Pin =
  Pin(name: name, kind: kind)

proc newComponent*(designator: string, name = "", partNumber = "", kind = ""): Component =
  Component(designator: designator, name: name, partNumber: partNumber, kind: kind)

proc newNet*(name: string, kind: NetType = ntUnknown): Net =
  Net(name: name, kind: kind)

proc newNetlist*(name = "", parent: Netlist = nil): Netlist =
  Netlist(name: name, parent: parent)
