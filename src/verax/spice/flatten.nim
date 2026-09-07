## Dissolving hierarchy so a simulation can see through it.
##
## `spice/isolate` folds `comp.subNetlist != nil` into a variable called
## `unmodellable`, which is close to backwards -- a subcircuit is the most
## thoroughly modelled thing in the graph. The consequence is that a
## hierarchically-authored board has every block cut at its boundary and
## there is nothing left to simulate. This is the pass that makes that
## question go away rather than answering it once per consumer.
##
## **Why flattening rather than teaching the walk to cross hierarchy.** Four
## passes would have to learn to recurse -- `expandPinModels`,
## `expandSourceImpedance`, `expandCapacitorParasitics` and the isolation
## walk itself -- and three of them would then need a notion of "this subtree
## is a synthesized macromodel, leave its parts alone" that does not exist.
## `attrs["parasitics.expanded"]` already marks modelling elements, and it is
## already **per component**, which is exactly the granularity flattening
## needs: after this pass a design-authored block's real 0402s get an ESR and
## `idealOpAmp`'s pole capacitor does not, with every existing pass unchanged.
##
## It also settles a documented limitation for free. Internal nodes become
## top-level ones named the way ngspice names them, so probing inside a
## nested instance -- previously unsupported -- is just probing a node.
##
## **This module lives under `spice/` deliberately.** It needs nothing from
## `spice`, but flattening destroys the hierarchy the designer wrote, so it
## is a simulation-only concession and belongs beside `transform`, `extract`
## and `isolate` rather than next to `graph.instantiate`, where it would
## invite someone to flatten a real design.
##
## Like every model pass here it **mutates in place**; run it on a clone.

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
      ## Old `<instance path>/<local name>` -> new flat name, for every net
      ## and component adopted. What an error message needs to say "R1 inside
      ## XL" rather than only `XL.R1`.

const flattenProvenance* = "flatten.of"
  ## Namespaced, so it is never validated and never collides: the instance
  ## path an entity came out of. Dotted means owned, and this is owned here.

proc isGlobalOf(nl: Netlist, n: Net): bool =
  ## Whether `n` is the very object the parent already holds under its own
  ## name -- which is what `clone` does for a net in `globalNets`. Compared by
  ## identity, not by name, because that is the property that makes a global
  ## net global.
  nl.nets.hasKey(n.name) and nl.nets[n.name] == n

proc inline(parent: Netlist, inst: Component, path: string, res: var Flattened) =
  ## Splices one already-flattened child into its parent and removes the
  ## instance component.
  let child = inst.subNetlist
  let d = inst.designator

  # 1. Ports first. `Pin.hierNet` is the link that exists precisely for this:
  #    it points at the port net *inside* the child that this instance pin
  #    connects to from outside. The two were always one conductor.
  for _, p in inst.pins:
    if p.hierNet != nil and p.net != nil and p.hierNet != p.net:
      mergeNets(p.net, p.hierNet)

  # 2. Everything else the child owns gets promoted under a mangled name.
  var childNets: seq[Net]
  for _, n in child.nets: childNets.add n
  for n in childNets:
    if n.netlist != child: continue          # already merged away as a port
    if isGlobalOf(parent, n): continue       # shared by identity; leave it
    if isGround(n) and parent.nets.hasKey(n.name):
      # Ground is shared even when it was not registered as global. Mangling
      # it to `XL.0` would give each block a private reference and every
      # measurement between blocks would then be meaningless.
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

  # 3. `.MODEL` cards, three ways. Two instances of one subcircuit register
  #    the same card twice and must collapse to one; two instances carrying
  #    *different* cards under one name must not silently pick a winner --
  #    `xspice/instance` derives a card name from the designator, so this is
  #    a real collision, not a hypothetical one.
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
    # Depth first, innermost first: flatten the child completely and *then*
    # inline it, so `XL.XA.R1` falls out of one prefixing pass per level
    # rather than needing path bookkeeping.
    flattenInto(inst.subNetlist, keep, path, res)
    inline(nl, inst, path, res)

proc flatten*(nl: Netlist, keep: openArray[string] = []): Flattened =
  ## Dissolves every subcircuit instance in `nl` into its parent, except
  ## those `keep` names.
  ##
  ## `keep` holds **hierarchical instance paths** (`"XU1"`, `"XL.XU1"`), and
  ## exists because the one real objection to flattening is that it dissolves
  ## a component something else refers to *by designator*. A role binds
  ## `opamp = U1`; `findOpAmpPins` needs that component present with named
  ## pins; `analyzeOpAmpResponse` has an explicit branch honouring a design's
  ## own subcircuit macromodel. Flatten unconditionally and every one of those
  ## reports `no such component`.
  ##
  ## **A `keep` entry that matches no instance raises**, rather than
  ## protecting nothing in silence. The thing it was meant to guard would be
  ## dissolved and the failure would surface three steps later as a missing
  ## component, which is exactly the hazard `addRole`'s `without` check exists
  ## to prevent.
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
  ## What an analysis calls on its work clone, immediately after cloning and
  ## **before any model pass**.
  ##
  ## That ordering is the reason to flatten at all rather than teach the
  ## isolation walk to cross hierarchy: `expandPinModels`,
  ## `expandSourceImpedance` and `expandCapacitorParasitics` all walk only
  ## `nl.components`, so a part inside an instance is invisible to every one
  ## of them. Flatten first and all three work on hierarchy unchanged. Left
  ## un-flattened, an op-amp inside a subcircuit never gets a macromodel and
  ## reaches the deck as `U1` -- which ngspice reads as a uniformly-distributed
  ## RC line and rejects for having no model.
  ##
  ## `namedParts` are the designators the caller was asked about. One is kept
  ## only if it names a **top-level instance**, which is precisely the "a
  ## design brought its own subcircuit macromodel" case: dissolving that would
  ## take away the very component the analysis was told to measure. A
  ## hierarchical name like `XL.U1` names something *inside* an instance and
  ## therefore requires that instance to be dissolved, so it contributes
  ## nothing to `keep`.
  if not enabled: return
  var wanted: seq[string]
  for k in keepInstances: wanted.add k
  for n in namedParts:
    if n.len == 0 or hierSep in n: continue
    if work.children.hasKey(n) and n notin wanted: wanted.add n
  flatten(work, wanted)
