## Instantiating an XSPICE code model into a `Netlist` as an `A` device.
##
## An `A` line is **not positional** the way `R`/`C`/`V` lines are, which is
## the whole reason this module exists. Three things break the one-net-per-port
## assumption, all verified against ngspice-46's `src/xspice/mif/mif_inp2.c`:
##
## * a **differential** port (`vd`/`id`/`gd`/`hd`) takes *two* nodes, not one;
## * a **vector** port takes a bracketed list, `[a b c]`, with no nesting;
## * an unconnected port is the literal `null`, allowed for a whole
##   connection -- including a whole vector -- but **rejected inside** a
##   bracketed list.
##
## So the port text is rendered here and handed to `netlist/formats/spice.nim`
## through `attrs["xspice.ports"]`, the same verbatim-passthrough treatment
## that module already gives `.MODEL` cards. **Pins still carry real
## connectivity** -- a vector port becomes `name[0]`, `name[1]`, ...; a
## differential port becomes `name.p`/`name.n` -- so graph walks and ERC-style
## analysis see the actual nets, not an opaque string.
##
## What this buys over hand-building the component: ports and parameters are
## checked against the `ModelSpec` the `.cm` was built from, so a wrong node
## count fails here rather than as ngspice's `MIF-ERROR - unable to find
## definition of model`.
##
## **Round-trip caveat, stated plainly:** `formats/spice.nim` can *write* these
## lines but cannot read them back into ports -- with the `%type` prefix
## omitted, the node count per port is only knowable from that model's `.ifs`.
## Reading an `A` line falls back to generic `pin1..pinN`.

import std/[strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ./spec

type
  XspiceInstanceError* = object of CatchableError

  PortBinding* = object
    ## The nodes wired to one port of a code model.
    ##
    ## How they are grouped is decided by the port's declaration, not here:
    ## `wire(a, b)` and `wire([a, b])` produce the same binding, and the port's
    ## `vector` flag and type decide whether that means one differential
    ## element or two single-ended ones.
    nets*: seq[Net]
    isNull*: bool

func wire*(n: Net): PortBinding =
  ## A single-ended scalar port.
  PortBinding(nets: @[n])

func wire*(pos, neg: Net): PortBinding =
  ## A differential scalar port, positive node first.
  PortBinding(nets: @[pos, neg])

func wire*(nets: openArray[Net]): PortBinding =
  ## A vector port, in element order.
  PortBinding(nets: @nets)

func nullPort*(): PortBinding =
  ## An unconnected port; the model sees `portNull(x) == true`.
  PortBinding(isNull: true)

func nodesPerElement*(t: PortType): int =
  ## How many nodes one element of a port of this type consumes.
  ## ngspice's parser supplies ground as the negative node for the
  ## single-ended types, and demands an explicit second node for the
  ## differential ones.
  case t
  of xpVd, xpId, xpGd, xpHd: 2
  else: 1

func elementPinNames(port: PortSpec, elements: int): seq[string] =
  let per = nodesPerElement(port.default)
  for e in 0 ..< elements:
    let stem = if port.vector: port.name & "[" & $e & "]" else: port.name
    if per == 1: result.add stem
    else: result.add [stem & ".p", stem & ".n"]

proc boundInt(s: string): int =
  try: parseInt(s.strip)
  except ValueError:
    raise newException(XspiceInstanceError, "malformed vector bound: " & s)

proc checkBinding(spec: ModelSpec, i: int, b: PortBinding): int =
  ## Validate one port binding and return its element count.
  let p = spec.ports[i]
  if p.default == xpVnam:
    raise newException(XspiceInstanceError,
      "port '" & p.name & "' of code model '" & spec.name & "' is type vnam, " &
      "which names a voltage *source* rather than a net; that is not " &
      "representable as a Net binding and is unsupported")
  if b.isNull:
    if not p.nullAllowed:
      raise newException(XspiceInstanceError,
        "port '" & p.name & "' of code model '" & spec.name &
        "' is not Null_Allowed, so it cannot be left unconnected")
    return 0

  let per = nodesPerElement(p.default)
  for n in b.nets:
    if n == nil:
      raise newException(XspiceInstanceError,
        "port '" & p.name & "' was given a nil net; use nullPort() to leave " &
        "a port unconnected (and note ngspice rejects null inside a vector)")

  if not p.vector:
    if b.nets.len != per:
      raise newException(XspiceInstanceError,
        "port '" & p.name & "' is type " & p.default.ifsName & ", which takes " &
        $per & " node" & (if per == 1: "" else: "s") & "; got " & $b.nets.len)
    return 1

  if b.nets.len == 0:
    raise newException(XspiceInstanceError,
      "vector port '" & p.name & "' was given no nets")
  if b.nets.len mod per != 0:
    raise newException(XspiceInstanceError,
      "vector port '" & p.name & "' is type " & p.default.ifsName & " (" & $per &
      " nodes per element) but was given " & $b.nets.len & " nets, which is " &
      "not a whole number of elements")
  result = b.nets.len div per
  if p.vectorBounds.active:
    if p.vectorBounds.lo.len > 0 and result < boundInt(p.vectorBounds.lo):
      raise newException(XspiceInstanceError,
        "vector port '" & p.name & "' needs at least " & p.vectorBounds.lo &
        " elements; got " & $result)
    if p.vectorBounds.hi.len > 0 and result > boundInt(p.vectorBounds.hi):
      raise newException(XspiceInstanceError,
        "vector port '" & p.name & "' allows at most " & p.vectorBounds.hi &
        " elements; got " & $result)

func renderPort(p: PortSpec, b: PortBinding): string =
  if b.isNull: return "null"
  var names: seq[string]
  for n in b.nets: names.add n.name
  if p.vector: "[" & names.join(" ") & "]" else: names.join(" ")

const xspiceCmAttr* = "xspice.cm"
  ## Where a code-model component records the `.cm` shared object that
  ## defines it. Namespaced, so the annotation registry never validates it --
  ## dotted means owned, and `xspice.*` is owned here.

proc collectCodeModels*(nl: Netlist): seq[string] =
  ## Every distinct `.cm` path this netlist needs, in first-seen order,
  ## recursing into `children`.
  ##
  ## This exists because the netlist that reaches ngspice is almost never the
  ## one the design built: it is a fragment produced by `clone` -> `flatten`
  ## -> `expandPinModels` -> `isolate`, three layers below whoever knew which
  ## models the design used. An `attrs` entry rides through every one of
  ## those transforms for free, where a field on `Netlist` would have to be
  ## threaded through each of them and would still load a `.cm` for fragments
  ## that no longer contain the `A` device.
  for _, c in nl.components:
    if not c.attrs.hasKey(xspiceCmAttr): continue
    let path = c.attrs[xspiceCmAttr]
    if path.len > 0 and path notin result: result.add path
  for _, child in nl.children:
    for path in collectCodeModels(child):
      if path notin result: result.add path

proc addCodeModelInstance*(nl: Netlist, designator: string, spec: ModelSpec,
                           bindings: openArray[PortBinding],
                           params: openArray[(string, string)] = [],
                           modelName = "", cmPath = ""): Component =
  ## Add an `A`-device instance of `spec` to `nl`, wiring `bindings` to the
  ## model's ports in declaration order, and register the matching `.model`
  ## card in `nl.models`.
  ##
  ## `modelName` is shared by the device line and the `.model` card; it
  ## defaults to the lowercased designator, so two instances can carry
  ## different parameters.
  if designator.len == 0 or designator[0].toUpperAscii != 'A':
    raise newException(XspiceInstanceError,
      "an XSPICE code model instance must have a designator starting with " &
      "'A' (SPICE infers the device type from that letter); got: " & designator)
  if bindings.len != spec.ports.len:
    raise newException(XspiceInstanceError,
      "code model '" & spec.name & "' has " & $spec.ports.len & " ports but " &
      $bindings.len & " bindings were given for " & designator)

  var elements: seq[int]
  for i in 0 ..< bindings.len:
    elements.add checkBinding(spec, i, bindings[i])

  var declared: seq[string]
  for p in spec.params: declared.add p.name
  var seen: seq[string]
  for (key, _) in params:
    if spec.paramIndex(key) < 0:
      raise newException(XspiceInstanceError,
        "code model '" & spec.name & "' has no parameter '" & key &
        "'; declared parameters: " & declared.join(", "))
    if key in seen:
      raise newException(XspiceInstanceError,
        "parameter '" & key & "' given twice for " & designator)
    seen.add key

  let inst = if modelName.len > 0: modelName else: designator.toLowerAscii
  if nl.models.hasKey(inst):
    raise newException(XspiceInstanceError,
      "a .MODEL named '" & inst & "' is already registered in this netlist")

  result = addComponent(nl, Component(designator: designator,
                                      kind: "code_model",
                                      name: spec.name))
  result.attrs["value"] = inst
  result.attrs["xspice.model"] = spec.name
  if cmPath.len > 0: result.attrs[xspiceCmAttr] = cmPath

  var portText: seq[string]
  for i, p in spec.ports:
    portText.add renderPort(p, bindings[i])
    let names = elementPinNames(p, elements[i])
    for j, pinName in names:
      discard connect(result, pinName, bindings[i].nets[j], ptPassive)
  result.attrs["xspice.ports"] = portText.join(" ")

  var card = spec.name & "("
  for i, (key, value) in params:
    if i > 0: card &= " "
    card &= key & "=" & value
  card &= ")"
  nl.models[inst] = card

proc addCodeModelInstance*(nl: Netlist, designator: string, spec: ModelSpec,
                           nets: openArray[Net],
                           params: openArray[(string, string)] = [],
                           modelName = "", cmPath = ""): Component =
  ## Convenience form for a model whose ports are all scalar and
  ## single-ended: one net per port, in declaration order.
  var bindings: seq[PortBinding]
  for n in nets: bindings.add wire(n)
  addCodeModelInstance(nl, designator, spec, bindings, params, modelName, cmPath)
