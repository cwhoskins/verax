## Graph mutation and hierarchy-instantiation API for the netlist data model.
##
## Every proc here keeps the bidirectional back-references on `Pin`,
## `Component`, `Net` and `Netlist` (see `nimcir/netlist/types`) consistent.
## Code outside this module should never hand-set `.net`, `.pins`,
## `.component`, `.parent`, `.children` or `.instanceOf` directly.

import std/tables
import ./types

export types

proc addComponent*(nl: Netlist, c: Component): Component =
  ## Registers `c` under `nl.components[c.designator]` and sets `c.netlist`.
  if nl.components.hasKey(c.designator):
    raise newException(NetlistError, "duplicate component designator: " & c.designator)
  c.netlist = nl
  nl.components[c.designator] = c
  result = c

proc addNet*(nl: Netlist, n: Net): Net =
  ## Registers `n` under `nl.nets[n.name]` and sets `n.netlist`.
  if nl.nets.hasKey(n.name):
    raise newException(NetlistError, "duplicate net name: " & n.name)
  n.netlist = nl
  nl.nets[n.name] = n
  result = n

proc addPin*(c: Component, p: Pin): Pin =
  ## Registers `p` under `c.pins[p.name]` and sets `p.component`.
  if c.pins.hasKey(p.name):
    raise newException(NetlistError, "duplicate pin name on " & c.designator & ": " & p.name)
  p.component = c
  c.pins[p.name] = p
  result = p

proc disconnect*(p: Pin) =
  ## Removes `p` from its current net's `pins` (if any) and clears `p.net`.
  let n = p.net
  if n != nil:
    for i in 0 ..< n.pins.len:
      if n.pins[i] == p:
        n.pins.delete(i)
        break
    p.net = nil

proc connect*(p: Pin, n: Net) =
  ## Wires `p` <-> `n` in both directions. Idempotent. If `p` was already
  ## connected to a different net, it is disconnected from that net first.
  if p.net == n: return
  if p.net != nil:
    disconnect(p)
  p.net = n
  n.pins.add(p)

proc connect*(c: Component, pinName: string, n: Net, kind: PinType = ptUnknown): Pin =
  ## Convenience overload: looks up `pinName` on `c`, auto-creating a `Pin`
  ## with the given `kind` if it doesn't exist yet, then connects it to `n`.
  if c.pins.hasKey(pinName):
    result = c.pins[pinName]
  else:
    result = addPin(c, newPin(pinName, kind))
  connect(result, n)

proc addChild*(parent: Netlist, instanceDesignator: string, child: Netlist) =
  ## Registers `child` under `parent.children[instanceDesignator]` and sets
  ## `child.parent`.
  if parent.children.hasKey(instanceDesignator):
    raise newException(NetlistError, "duplicate child instance: " & instanceDesignator)
  child.parent = parent
  parent.children[instanceDesignator] = child

proc addPort*(nl: Netlist, portName: string, n: Net) =
  ## Marks net `n` (must already belong to `nl.nets`) as an exposed
  ## hierarchical port, in declared order (this order becomes the
  ## `.SUBCKT` header order / `instantiate` argument order on write).
  if not nl.nets.hasKey(n.name) or nl.nets[n.name] != n:
    raise newException(NetlistError, "port net must belong to this netlist: " & n.name)
  nl.ports[portName] = n

proc clone*(nl: Netlist, globalNets: var OrderedTable[string, Net]): Netlist =
  ## Deep-copies `nl` into a brand-new, detached `Netlist` graph (fresh
  ## `Component`/`Net`/`Pin` objects). The returned netlist's `parent` is
  ## left unset -- callers wire that up via `addChild`.
  ##
  ## Any net whose name is already a key in `globalNets` (e.g. SPICE node
  ## `"0"`) is *not* cloned: the copy's pins are wired to the shared object
  ## in `globalNets` instead, so global/ground nets stay a single identical
  ## object across the whole hierarchy.
  ##
  ## Nested hierarchy (components in `nl` that themselves have a
  ## `subNetlist`) is cloned recursively, so instantiating a template that
  ## contains its own sub-instances works transparently.
  result = newNetlist(nl.name)
  result.models = nl.models
  result.attrs = nl.attrs

  var netMap: OrderedTable[string, Net]
  for name, oldNet in nl.nets:
    var newNetRef: Net
    if globalNets.hasKey(name):
      newNetRef = globalNets[name]
    else:
      newNetRef = newNet(name, oldNet.kind)
      newNetRef.attrs = oldNet.attrs
      newNetRef.netlist = result
    result.nets[name] = newNetRef
    netMap[name] = newNetRef

  for portName, oldPortNet in nl.ports:
    result.ports[portName] = netMap[oldPortNet.name]

  var compMap: OrderedTable[string, Component]
  for designator, oldComp in nl.components:
    let newComp = newComponent(designator, oldComp.name, oldComp.partNumber, oldComp.kind)
    newComp.attrs = oldComp.attrs
    newComp.netlist = result
    result.components[designator] = newComp
    compMap[designator] = newComp

  for designator, oldComp in nl.components:
    let newComp = compMap[designator]
    for pinName, oldPin in oldComp.pins:
      let newPinRef = newPin(pinName, oldPin.kind)
      newPinRef.attrs = oldPin.attrs
      newPinRef.component = newComp
      newComp.pins[pinName] = newPinRef
      if oldPin.net != nil:
        let targetNet = netMap[oldPin.net.name]
        newPinRef.net = targetNet
        targetNet.pins.add(newPinRef)

    if oldComp.subNetlist != nil:
      let newChild = clone(oldComp.subNetlist, globalNets)
      newChild.parent = result
      newChild.instanceOf = newComp
      newComp.subNetlist = newChild
      result.children[designator] = newChild
      for pinName, oldPin in oldComp.pins:
        if oldPin.hierNet != nil:
          newComp.pins[pinName].hierNet = newChild.nets[oldPin.hierNet.name]

proc instantiate*(parent: Netlist, instanceDesignator: string, defNetlist: Netlist,
                   portNets: seq[Net], globalNets: var OrderedTable[string, Net],
                   componentKind = "subcircuit"): Component =
  ## Clones `defNetlist` as a new child of `parent` (see `clone`), creates
  ## the instance `Component` (designator = `instanceDesignator`,
  ## `partNumber` = `defNetlist.name`), and for each port of `defNetlist`
  ## (in declaration order) creates and connects a `Pin` to the matching
  ## entry of `portNets`, setting `pin.hierNet` to the clone's corresponding
  ## port net.
  if portNets.len != defNetlist.ports.len:
    raise newException(NetlistError,
      "port count mismatch instantiating '" & defNetlist.name & "' as " & instanceDesignator &
      "': expected " & $defNetlist.ports.len & ", got " & $portNets.len)
  let child = clone(defNetlist, globalNets)
  result = addComponent(parent, newComponent(instanceDesignator, kind = componentKind,
                                              partNumber = defNetlist.name))
  addChild(parent, instanceDesignator, child)
  child.instanceOf = result
  result.subNetlist = child
  var i = 0
  for portName, portNet in child.ports:
    let pin = addPin(result, newPin(portName))
    connect(pin, portNets[i])
    pin.hierNet = portNet
    inc i

proc isConnected*(p: Pin): bool =
  p.net != nil

proc connectedComponents*(n: Net): seq[Component] =
  ## Distinct components with a pin on `n`, in pin-connection order.
  for p in n.pins:
    if p.component != nil and p.component notin result:
      result.add(p.component)

proc root*(nl: Netlist): Netlist =
  ## Walks `parent` links up to the top-level (root) netlist.
  result = nl
  while result.parent != nil:
    result = result.parent
