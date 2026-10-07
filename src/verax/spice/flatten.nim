## Dissolving hierarchy so a simulation can see through it. Without it,
## `spice/isolate` treats every instance as unmodellable and cuts it at its
## boundary.
##
## **Flattening rather than teaching each pass to recurse**: the model
## passes walk only `nl.components`, and `attrs["parasitics.expanded"]`
## already marks synthesized parts per component, so every pass works
## unchanged after flattening. Internal nodes get ngspice-style names, so
## probing inside an instance is just probing a node.
##
## **Lives under `spice/`** because destroying the designer's hierarchy is a
## simulation-only concession. **Mutates in place**; run it on a clone.

import std/[strutils, tables]
import ../netlist/types
import ../netlist/graph
import ../netlist/kinds

type
  Flattened* = object
    ## What the pass did, for reporting and for tests.
    dissolved*: seq[string]
      ## Instance paths inlined, outermost first.
    kept*: seq[string]
      ## Instance paths left intact because `keep` named them.
    renamed*: OrderedTable[string, string]
      ## Old `<instance path>/<local name>` -> new flat name, for messages
      ## like "R1 inside XL".

const flattenProvenance* = "flatten.of"
  ## The instance path an entity came from (namespaced, owned here).

proc isGlobalOf(nl: Netlist, n: Net): bool =
  ## Whether `n` is the parent's own object under that name (what `clone`
  ## does for a global net). By identity, not name.
  nl.nets.hasKey(n.name) and nl.nets[n.name] == n

proc inline(parent: Netlist, inst: Component, path: string, res: var Flattened) =
  ## Splices one already-flattened child into its parent and removes the
  ## instance.
  let child = inst.subNetlist
  let d = inst.designator

  # 1. Ports first: `Pin.hierNet` links the instance pin to the child's port
  #    net -- one conductor.
  for _, p in inst.pins:
    if p.hierNet != nil and p.net != nil and p.hierNet != p.net:
      mergeNets(p.net, p.hierNet)

  # 2. Everything else is promoted under a mangled name.
  var childNets: seq[Net]
  for _, n in child.nets: childNets.add n
  for n in childNets:
    if n.netlist != child: continue          # already merged away as a port
    if isGlobalOf(parent, n): continue       # shared by identity; leave it
    if isGround(n) and parent.nets.hasKey(n.name):
      # Ground is always shared; `XL.0` would give each block a private
      # reference.
      mergeNets(parent.nets[n.name], n)
      continue
    let flat = hierName(d, n.name)
    res.renamed[hierName(path, n.name)] = flat
    n.attrs[flattenProvenance] = path
    adoptNet(parent, n, flat, "while flattening instance '" & path & "'")

  var childComps: seq[Component]
  for _, c in child.components: childComps.add c
  for c in childComps:
    let flat = hierName(d, c.designator)
    res.renamed[hierName(path, c.designator)] = flat
    c.attrs[flattenProvenance] = path
    adoptComponent(parent, c, flat,
                   "while flattening instance '" & path & "'")

  # 3. `.MODEL` cards: identical duplicates collapse; different cards under
  #    one name raise (a real case for designator-derived XSPICE names).
  for name, card in child.models:
    if not parent.models.hasKey(name):
      setModel(parent, name, card)
    elif parent.models[name] == card:
      discard
    else:
      let flat = hierName(d, name)
      setModel(parent, flat, card)
      for _, c in parent.components:
        if not c.attrs.hasKey("value"): continue
        let toks = c.attrs["value"].split()
        if toks.len > 0 and toks[^1].toLowerAscii == name.toLowerAscii and
           c.attrs.getOrDefault(flattenProvenance) == path:
          var rebuilt = toks
          rebuilt[^1] = flat
          c.attrs["value"] = rebuilt.join(" ")

  removeComponent(parent, d)
  res.dissolved.add path

proc flattenInto(nl: Netlist, keep: seq[string], prefix: string,
                 res: var Flattened) =
  var instances: seq[Component]
  for _, c in nl.components:
    if c.subNetlist != nil: instances.add c
  for inst in instances:
    let path = hierName(prefix, inst.designator)
    if path in keep:
      res.kept.add path
      continue
    # Innermost first, so `XL.XA.R1` comes from one prefix per level.
    flattenInto(inst.subNetlist, keep, path, res)
    inline(nl, inst, path, res)

proc flatten*(nl: Netlist, keep: openArray[string] = []): Flattened =
  ## Dissolves every instance in `nl`, except those `keep` names
  ## (hierarchical instance paths, `"XL.XU1"`) -- for a component something
  ## refers to by designator, e.g. a design's own subcircuit macromodel. A
  ## `keep` entry matching nothing **raises**.
  var wanted: seq[string]
  for k in keep: wanted.add k
  flattenInto(nl, wanted, "", result)

  for k in wanted:
    if k notin result.kept:
      var seen: seq[string]
      for p in result.dissolved: seen.add p
      raise newException(NetlistError,
        "flatten was asked to keep instance '" & k & "', which does not exist" &
        (if seen.len > 0: "; it dissolved: " & seen.join(", ")
         else: "; there are no subcircuit instances here"))

proc flattenForSim*(work: Netlist, enabled: bool,
                    keepInstances: openArray[string],
                    namedParts: varargs[string]): Flattened =
  ## Called on an analysis's work clone right after cloning and **before any
  ## model pass**, since those walk only top-level components (an unflattened
  ## nested op-amp would reach the deck as `U1`, a distributed RC line).
  ## `applySimReplacements` runs after this too: XSPICE port text is frozen
  ## at replacement time and must use post-flatten names.
  ##
  ## Of `namedParts`, only a **top-level instance** is kept (a design's own
  ## macromodel). A hierarchical name like `XL.U1` requires its instance to
  ## dissolve, so it adds nothing to `keep`.
  if not enabled: return
  var wanted: seq[string]
  for k in keepInstances: wanted.add k
  for n in namedParts:
    if n.len == 0 or hierSep in n: continue
    if work.children.hasKey(n) and n notin wanted: wanted.add n
  flatten(work, wanted)
