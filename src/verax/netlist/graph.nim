## Graph mutation and hierarchy-instantiation API for the netlist data model.
##
## Every proc here keeps the bidirectional back-references on `Pin`,
## `Component`, `Net` and `Netlist` (see `verax/netlist/types`) consistent.
## Code outside this module should never hand-set `.net`, `.pins`,
## `.component`, `.parent`, `.children` or `.instanceOf` directly.

import std/[tables, strutils]
import ./types
import ./kinds

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

proc removeComponent*(nl: Netlist, designator: string) =
  ## Disconnects every pin of `nl.components[designator]`, then removes it
  ## from `nl.components` (and from `nl.children` if it had a `subNetlist`).
  ## Raises `NetlistError` if `designator` isn't present.
  if not nl.components.hasKey(designator):
    raise newException(NetlistError, "no such component: " & designator)
  let c = nl.components[designator]
  for _, p in c.pins:
    disconnect(p)
  nl.components.del(designator)
  if c.subNetlist != nil:
    nl.children.del(designator)

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

proc adoptNet*(nl: Netlist, n: Net, name: string, context = "") =
  ## Re-homes an existing `Net` into `nl` under `name`, deregistering it from
  ## wherever it was.
  ##
  ## `context` is appended to the collision message: the caller knows *why*
  ## the name was chosen (which instance is being flattened) and this proc
  ## does not, and a reader told only "that name is taken" has no way to see
  ## that one side of the clash was generated.
  ##
  ## It re-homes **the object**, not a copy, and that is the whole point:
  ## every `Pin.net` back-reference pointing at it stays valid untouched, and
  ## so does its `attrs` bag -- which carries `voltage` and the `role.*`
  ## membership tags that must survive a transform. Copying would mean
  ## rebuilding both, and getting either wrong is silent.
  if n == nil: raise newException(NetlistError, "adoptNet: nil net")
  if nl.nets.hasKey(name) and nl.nets[name] != n:
    let incumbent = nl.nets[name]
    var held = "already a net of '" & nl.name & "'"
    if incumbent.pins.len > 0:
      var on: seq[string]
      for p in incumbent.pins:
        if p.component != nil and p.component.designator notin on:
          on.add p.component.designator
      held.add " carrying " & on.join(", ")
    raise newException(NetlistError,
      "cannot name a net '" & name & "'" &
      (if context.len > 0: " " & context else: "") &
      ": that name is " & held & ". Rename one of them; a hierarchical name " &
      "is built from the instance designator, so the collision is with " &
      "something the design already spelled that way.")
  if n.netlist != nil and n.netlist.nets.hasKey(n.name) and n.netlist.nets[n.name] == n:
    n.netlist.nets.del(n.name)
  n.name = name
  n.netlist = nl
  nl.nets[name] = n

proc adoptComponent*(nl: Netlist, c: Component, designator: string,
                     context = "") =
  ## As `adoptNet`, for a component. Its pins come with it -- they reference
  ## it by object, not by name.
  if c == nil: raise newException(NetlistError, "adoptComponent: nil component")
  if nl.components.hasKey(designator) and nl.components[designator] != c:
    let incumbent = nl.components[designator]
    var held = "already a component of '" & nl.name & "'"
    if incumbent.kind.len > 0: held.add " of kind '" & incumbent.kind & "'"
    if incumbent.attrs.hasKey("value"):
      held.add " valued " & incumbent.attrs["value"]
    raise newException(NetlistError,
      "cannot name a component '" & designator & "'" &
      (if context.len > 0: " " & context else: "") &
      ": that designator is " & held & ". Rename one of them; a hierarchical " &
      "designator is built from the instance designator, so the collision is " &
      "with something the design already spelled that way.")
  if c.netlist != nil and c.netlist.components.hasKey(c.designator) and
     c.netlist.components[c.designator] == c:
    c.netlist.components.del(c.designator)
    if c.subNetlist != nil: c.netlist.children.del(c.designator)
  c.designator = designator
  c.netlist = nl
  nl.components[designator] = c
  if c.subNetlist != nil: nl.children[designator] = c.subNetlist

proc mergeNets*(keep, gone: Net) =
  ## Moves every pin on `gone` onto `keep`, then deregisters `gone`.
  ##
  ## This is what a subcircuit port *is* once the hierarchy is gone: the net
  ## inside and the net outside were always the same conductor, joined by the
  ## instance pin. `keep`'s own annotations win and `gone`'s only fill gaps,
  ## because the outer net is the one the design as a whole talks about -- a
  ## port's local `voltage` must not overwrite the rail's.
  if keep == nil or gone == nil or keep == gone: return
  for p in gone.pins:
    p.net = keep
    keep.pins.add p
  gone.pins.setLen 0
  for k, v in gone.attrs:
    if not keep.attrs.hasKey(k): keep.attrs[k] = v
  if gone.netlist != nil and gone.netlist.nets.hasKey(gone.name) and
     gone.netlist.nets[gone.name] == gone:
    gone.netlist.nets.del(gone.name)
  gone.netlist = nil

const hierSep* = '.'
  ## Separates one level of hierarchy from the next in a flattened or
  ## hierarchically-addressed name: `R1` inside `XA` inside `XL` is
  ## `XL.XA.R1`.
  ##
  ## A dot, for three reasons, in order of weight. It is **what ngspice
  ## itself produces** when it expands a subcircuit -- `v(x1.n1)` is its
  ## hierarchical probe syntax -- so an internal node addressed this way is
  ## addressed under the name a reader already knows. The contract layer
  ## already spells `DESIGNATOR.pin` with the same meaning, so one dot
  ## uniformly means "descend one level". And the alternatives are worse: an
  ## underscore collides with ordinary designators and with the suffixes
  ## `spice/isolate` synthesizes, and a slash matches nothing the simulator
  ## or this codebase already says.
  ##
  ## The cost is that a name can no longer be split on the first or last dot
  ## to separate a component from its pin, because both halves may contain
  ## one -- XSPICE already names a differential port's pins `name.p`/`name.n`.
  ## Resolution is therefore a search over split points, longest component
  ## prefix winning, and `findPin` below is where that lives.

proc hierName*(parts: varargs[string]): string =
  ## Joins `parts` with `hierSep`, skipping empties.
  for part in parts:
    if part.len == 0: continue
    if result.len > 0: result.add hierSep
    result.add part

proc findNet*(nl: Netlist, path: string): Net =
  ## A net by flat name, or by a `hierSep`-separated path into `children`.
  ## `nil` when absent -- callers raise with their own message.
  ##
  ## The **flat key is tried first**, and that ordering is what lets one call
  ## serve both an authored hierarchy and a flattened one: before flattening
  ## `XL.amp` is found by descending, after it is found directly, and nothing
  ## that holds such a name has to know which world it is in.
  if nl == nil: return nil
  if nl.nets.hasKey(path): return nl.nets[path]
  let i = path.find(hierSep)
  if i <= 0: return nil
  let head = path[0 ..< i]
  if not nl.children.hasKey(head): return nil
  findNet(nl.children[head], path[i + 1 .. ^1])

proc findComponent*(nl: Netlist, path: string): Component =
  ## As `findNet`, for components.
  if nl == nil: return nil
  if nl.components.hasKey(path): return nl.components[path]
  let i = path.find(hierSep)
  if i <= 0: return nil
  let head = path[0 ..< i]
  if not nl.children.hasKey(head): return nil
  findComponent(nl.children[head], path[i + 1 .. ^1])

proc findPin*(nl: Netlist, path: string): Pin =
  ## A pin by `<component path><hierSep><pin name>`.
  ##
  ## Searched right to left rather than split, because **both halves may
  ## contain a dot**: the component may be `XL.U1` and the pin may be `in.p`.
  ## The first split point where the left side names a component and the
  ## right side names one of its pins wins, so the longest component prefix
  ## is preferred -- which is the reading a person makes too.
  if nl == nil: return nil
  var i = path.rfind(hierSep)
  while i > 0:
    let c = findComponent(nl, path[0 ..< i])
    if c != nil:
      let pinName = path[i + 1 .. ^1]
      if c.pins.hasKey(pinName): return c.pins[pinName]
    i = path.rfind(hierSep, last = i - 1)
  nil

const generatedDesignatorAttr* = "designator.generated"
  ## Marks a designator this library chose rather than a person. Namespaced,
  ## so the annotation registry never validates it.
  ##
  ## It matters downstream: a reference designator is the join key to a board
  ## (`pcb/graph.bindComponent` raises on a mismatch), the line in a BoM and
  ## the text on a silkscreen. A generated one is **positional** -- insert a
  ## part earlier and everything after it renumbers -- so it is safe for a
  ## part nothing names and nothing places, and wrong for anything that has
  ## already been laid out or fabricated. Marking them is what lets a layout
  ## or BoM flow tell the two apart instead of trusting every designator
  ## equally.

proc nextDesignator*(nl: Netlist, kind: string): string =
  ## The next free designator for `kind` in `nl`, e.g. `"C3"`.
  ##
  ## Numbered **per netlist, not per design**, and that is the property that
  ## makes generation tolerable at all: a subcircuit gets its own `C1`, `C2`,
  ## so adding a part to one module cannot renumber another, and flattening
  ## then prefixes with the instance path anyway. Global numbering would make
  ## every module's parts depend on every other module's edit history.
  ##
  ## Existing designators are respected, including hand-authored ones: a
  ## netlist that already carries `R1` and `R2` generates `R3`. Only a
  ## designator that is exactly the prefix followed by digits counts, so
  ## `R_LEAK_vdd` is not mistaken for an `R`, and `FB1` counts toward `FB`
  ## rather than toward `F`.
  let prefix = designatorPrefixFor(kind)
  var highest = 0
  for designator in nl.components.keys:
    if not designator.startsWith(prefix): continue
    let tail = designator[prefix.len .. ^1]
    if tail.len == 0: continue
    var allDigits = true
    for ch in tail:
      if ch notin {'0' .. '9'}: allDigits = false
    if not allDigits: continue
    let n = parseInt(tail)
    if n > highest: highest = n
  prefix & $(highest + 1)

proc addGenerated*(nl: Netlist, kind: string): Component =
  ## Adds a component of `kind` under a generated designator, marked as such.
  result = newComponent(nextDesignator(nl, kind), kind = kind)
  result.attrs[generatedDesignatorAttr] = "true"
  discard addComponent(nl, result)

proc generatedDesignators*(nl: Netlist, recursive = true): seq[string] =
  ## Every component here whose designator this library chose. What a board
  ## or BoM flow should look at before trusting a designator to be stable.
  for designator, c in nl.components:
    if c.attrs.getOrDefault(generatedDesignatorAttr, "") == "true":
      result.add designator
  if recursive:
    for instance, child in nl.children:
      for d in generatedDesignators(child): result.add instance & hierSep & d

proc registerGlobalNet*(globals: var OrderedTable[string, Net], n: Net) =
  ## Marks `n` as a net shared by *identity* across every level of hierarchy,
  ## keyed by its name -- what `clone`/`instantiate` consult so that SPICE
  ## node "0" is one object on the whole board rather than one per instance.
  ##
  ## Here rather than as a bare table assignment for exactly the reason
  ## `setModel` is: the DSL's `global = true` expanded to `globals[name] = n`,
  ## which forced every design file that used it to `import std/tables` for a
  ## statement that has nothing to do with tables. That went unnoticed until
  ## the first design with a subcircuit was written, because `global = true`
  ## is only worth stating when there is a child netlist to share a net with.
  globals[n.name] = n

proc setModel*(nl: Netlist, name, card: string) =
  ## Registers a `.MODEL` card under `name`, to be written verbatim.
  ##
  ## Here rather than as a bare table assignment for the same reason every
  ## other mutation is: `Netlist.models` is state this module owns, and a DSL
  ## that expanded to `nl.models[name] = card` would force every design file
  ## to `import std/tables` for a statement that has nothing to do with
  ## tables.
  ##
  ## The card body is **not parsed**. Doing so would mean tracking every
  ## parameter of every device type in every SPICE dialect, and getting one
  ## wrong silently simulates a different part -- passing it through means
  ## the simulator reads exactly what the datasheet said. The one thing that
  ## does read it is `kinds.hasDeviceModel`, which only asks whether a name
  ## is present.
  if name.len == 0:
    raise newException(NetlistError, "a model needs a name")
  nl.models[name] = card

proc renameNet*(nl: Netlist, oldName, newName: string) =
  ## Rekeys a net in `nl.nets` (and under every `ports` entry pointing at it)
  ## and updates `Net.name` to match. The `Pin`/`Net` object graph is
  ## untouched -- every pin already holds a direct reference, so nothing
  ## needs rewiring; only the name-keyed dictionaries do.
  ##
  ## This lives here rather than in a caller because `Netlist.nets` keying is
  ## exactly the back-reference state this module exists to own. The concrete
  ## need is simulation: an extracted circuit fragment has to promote some
  ## rail to SPICE node `"0"`, which has no meaning until the net is actually
  ## named `"0"`.
  ##
  ## Port *names* are deliberately left alone: a port name is the subcircuit's
  ## published interface and is independent of the net name behind it (see
  ## `addPort`). Only the mapping's target net is renamed.
  if oldName == newName: return
  if not nl.nets.hasKey(oldName):
    raise newException(NetlistError, "no such net: " & oldName)
  if nl.nets.hasKey(newName):
    raise newException(NetlistError, "net already exists: " & newName)
  let n = nl.nets[oldName]
  nl.nets.del(oldName)
  n.name = newName
  nl.nets[newName] = n

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
    # Every model, not just the default: `simReplace` is the *default* one,
    # and a clone that kept only that would silently drop the alternative a
    # later analysis is about to ask for by purpose.
    newComp.simModels = oldComp.simModels
    newComp.simDefault = oldComp.simDefault
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

proc instantiateByPort*(parent: Netlist, instanceDesignator: string,
                        defNetlist: Netlist,
                        wiring: openArray[(string, Net)],
                        globalNets: var OrderedTable[string, Net],
                        componentKind = "subcircuit"): Component =
  ## `instantiate`, wiring ports **by name** instead of by position.
  ##
  ## Positional wiring is fine for a subcircuit whose ports a person just
  ## wrote. It is a trap for one produced by `spice/boundary.asSubcircuit`,
  ## where the port list came from whichever nets the connectors happened to
  ## sit on: two boards in a system routinely both call a port `vin`, and
  ## swapping two same-shaped nets is a miswiring that raises nothing and
  ## simulates happily.
  ##
  ## Every port must be named. An unwired one raises listing what the
  ## subcircuit exposes, rather than being quietly left open -- an open port
  ## on a board-to-board connection is a disconnected system, and the whole
  ## point of assembling one is that the connection exists.
  var ordered: seq[Net]
  for portName, _ in defNetlist.ports:
    var found: Net = nil
    for (k, n) in wiring:
      if k == portName: found = n
    if found == nil:
      var names: seq[string]
      for k in defNetlist.ports.keys: names.add k
      raise newException(NetlistError,
        "port '" & portName & "' of '" & defNetlist.name & "' is not wired " &
        "in instance '" & instanceDesignator & "'; it exposes: " &
        names.join(", "))
    ordered.add found
  for (k, _) in wiring:
    if not defNetlist.ports.hasKey(k):
      var names: seq[string]
      for name in defNetlist.ports.keys: names.add name
      raise newException(NetlistError,
        "'" & defNetlist.name & "' has no port '" & k & "'; it exposes: " &
        names.join(", "))
  instantiate(parent, instanceDesignator, defNetlist, ordered, globalNets,
              componentKind)
