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
  ## Re-homes an existing `Net` into `nl` under `name`. `context` is appended
  ## to a collision message (the caller knows why the name was generated).
  ## Moves **the object**, not a copy, so `Pin.net` references and `attrs`
  ## (`voltage`, `role.*`) survive untouched.
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
  ## Moves every pin on `gone` onto `keep`, then deregisters `gone` -- what a
  ## subcircuit port becomes once hierarchy is gone. `keep`'s annotations win;
  ## `gone`'s only fill gaps (a port's local `voltage` mustn't overwrite the
  ## rail's).
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

proc hierNetPeers*(n: Net): seq[Net] =
  ## Every net that is the same conductor as `n` one hierarchy boundary away.
  ## The read-only counterpart of `mergeNets`, for evaluators walking the
  ## design as authored (before `spice/flatten` assigns flat names).
  ##
  ## Down: a pin on `n` whose component is an instance contributes its
  ## `hierNet`. Up: if `n` is a port net inside an instance, the instance pin
  ## bound to it contributes its outer `.net`. Both are needed, e.g. a pull-up
  ## nested behind a pass-through port.
  for p in n.pins:
    if p.component != nil and p.component.subNetlist != nil and p.hierNet != nil:
      result.add p.hierNet
  if n.netlist != nil and n.netlist.instanceOf != nil:
    for _, pp in n.netlist.instanceOf.pins:
      if pp.hierNet == n and pp.net != nil:
        result.add pp.net

proc hierNetGroup*(n: Net): seq[Net] =
  ## `n` plus every net that is the same conductor through instance
  ## boundaries, any depth, either direction (BFS over `hierNetPeers`).
  ## `@[n]` for a flat design.
  result = @[n]
  var qi = 0
  while qi < result.len:
    let cur = result[qi]
    inc qi
    for peer in hierNetPeers(cur):
      if peer notin result: result.add peer

const hierSep* = '.'
  ## Separates hierarchy levels in a flattened or hierarchical name:
  ## `XL.XA.R1`. A dot because ngspice uses it (`v(x1.n1)`), the contract
  ## layer's `DESIGNATOR.pin` already means "descend", and `_` collides with
  ## designators and synthesized suffixes.
  ##
  ## Names can't be split on a dot (XSPICE pins are `name.p`), so resolution
  ## searches split points, longest component prefix winning (`findPin`).

proc hierName*(parts: varargs[string]): string =
  ## Joins `parts` with `hierSep`, skipping empties.
  for part in parts:
    if part.len == 0: continue
    if result.len > 0: result.add hierSep
    result.add part

proc leafComponents*(nl: Netlist): seq[tuple[c: Component, path: string]] =
  ## Every leaf component under `nl` with its hierarchical path
  ## (`hierName("X1", "U1")`), walking instances rather than flattening, in
  ## netlist order. An instance contributes its contents, never itself. The
  ## one definition of "a placed/bought part" shared by `pcb/assemble` and
  ## `bom/collect`.
  proc walk(n: Netlist, prefix: string,
            res: var seq[tuple[c: Component, path: string]]) =
    for _, c in n.components:
      let p = hierName(prefix, c.designator)
      if c.subNetlist != nil: walk(c.subNetlist, p, res)
      else: res.add (c, p)
  walk(nl, "", result)

proc findNet*(nl: Netlist, path: string): Net =
  ## A net by flat name, or by a `hierSep` path into `children`; `nil` when
  ## absent. The flat key is tried first, so one call works before and after
  ## flattening.
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
  ## A pin by `<component path><hierSep><pin name>`. Both halves may contain
  ## a dot (`XL.U1`, `in.p`), so split points are searched right to left and
  ## the longest component prefix wins.
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
  ## Marks a designator this library chose (namespaced, never validated). A
  ## generated designator is positional -- inserting a part renumbers later
  ## ones -- so board and BoM flows must not trust it as a stable join key.

proc nextDesignator*(nl: Netlist, kind: string): string =
  ## The next free designator for `kind` in `nl`, e.g. `"C3"`. Numbered per
  ## netlist, so editing one module never renumbers another. Existing
  ## designators count only when exactly prefix + digits (`R_LEAK_vdd` isn't
  ## an `R`; `FB1` counts toward `FB`, not `F`).
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
  ## Every component with a generated designator.
  for designator, c in nl.components:
    if c.attrs.getOrDefault(generatedDesignatorAttr, "") == "true":
      result.add designator
  if recursive:
    for instance, child in nl.children:
      for d in generatedDesignators(child): result.add instance & hierSep & d

proc registerGlobalNet*(globals: var OrderedTable[string, Net], n: Net) =
  ## Marks `n` as shared by identity across every hierarchy level, keyed by
  ## name (what `clone`/`instantiate` consult, so node "0" is one object).
  ## A proc so DSL users needn't import `std/tables`.
  globals[n.name] = n

proc setModel*(nl: Netlist, name, card: string) =
  ## Registers a `.MODEL` card under `name`, written verbatim. A proc so DSL
  ## users needn't import `std/tables`. The body is **not parsed** (that risks
  ## silently simulating a different part); `kinds.hasDeviceModel` only
  ## checks the name exists.
  if name.len == 0:
    raise newException(NetlistError, "a model needs a name")
  nl.models[name] = card

proc renameNet*(nl: Netlist, oldName, newName: string) =
  ## Rekeys a net in `nl.nets` (and every `ports` entry pointing at it) and
  ## updates `Net.name`; the object graph is untouched. Used to promote a
  ## fragment's ground to SPICE node `"0"`. Port *names* are left alone --
  ## they're the published interface.
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
  ## Deep-copies `nl` into a detached `Netlist` (fresh objects; `parent`
  ## unset -- wire it with `addChild`). Nets named in `globalNets` are not
  ## cloned: pins connect to the shared object. Nested hierarchy is cloned
  ## recursively.
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
    # Every model, not just the default: a later analysis may ask for an
    # alternative by purpose.
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
  ## Clones `defNetlist` as a child of `parent`, creates the instance
  ## `Component`, and connects one `Pin` per port (declaration order) to
  ## `portNets`, with `pin.hierNet` set to the clone's port net.
  ## `partNumber` is left unset; the writer uses `subNetlist.name` for the
  ## `.SUBCKT` reference.
  if portNets.len != defNetlist.ports.len:
    raise newException(NetlistError,
      "port count mismatch instantiating '" & defNetlist.name & "' as " & instanceDesignator &
      "': expected " & $defNetlist.ports.len & ", got " & $portNets.len)
  let child = clone(defNetlist, globalNets)
  result = addComponent(parent, newComponent(instanceDesignator, kind = componentKind))
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
  ## `instantiate`, wiring ports **by name**. Positional wiring is a trap for
  ## `spice/boundary.asSubcircuit` output, where port order is incidental and
  ## swapping same-shaped nets simulates silently. Every port must be named;
  ## an unwired one raises listing the exposed ports.
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
