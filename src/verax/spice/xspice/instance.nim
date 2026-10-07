## Instantiating an XSPICE code model as an `A` device. An `A` line isn't
## positional (verified against ngspice-46's `mif_inp2.c`):
##
## * a **differential** port (`vd`/`id`/`gd`/`hd`) takes two nodes;
## * a **vector** port takes a bracketed list `[a b c]`, unnested;
## * `null` leaves a whole connection (or vector) unconnected, but is
##   **rejected inside** brackets.
##
## So port text is rendered here into `attrs["xspice.ports"]` for
## `formats/spice.nim` to pass through. **Pins still carry connectivity**
## (`name[0]`..., `name.p`/`name.n`), so graph walks see real nets. Ports and
## parameters are checked against the `ModelSpec`, catching bad node counts
## before ngspice's `MIF-ERROR`.
##
## **Round trip**: `formats/spice.nim` writes these lines but reads them back
## as generic `pin1..pinN` (node counts need the model's `.ifs`).

import std/[strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ./spec

type
  XspiceInstanceError* = object of CatchableError

  PortBinding* = object
    ## The nodes wired to one port. Grouping follows the port's declaration
    ## (`vector` flag and type), so `wire(a, b)` and `wire([a, b])` bind the
    ## same.
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
  ## Nodes per element for a port type: single-ended types get ground as the
  ## implicit negative node; differential ones need two.
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
  ## Where a code-model component records its `.cm` path (namespaced,
  ## owned here).

proc collectCodeModels*(nl: Netlist): seq[string] =
  ## Every distinct `.cm` path this netlist needs, first-seen order,
  ## recursing into children. Stored in `attrs` because the deck netlist is a
  ## transformed fragment; attrs survive every transform, and only parts
  ## still present contribute.
  for _, c in nl.components:
    if not c.attrs.hasKey(xspiceCmAttr): continue
    let path = c.attrs[xspiceCmAttr]
    if path.len > 0 and path notin result: result.add path
  for _, child in nl.children:
    for path in collectCodeModels(child):
      if path notin result: result.add path

proc paramText(spec: ModelSpec, key, value: string): string =
  ## A parameter value as it must appear on a `.model` card. Strings are
  ## quoted: ngspice treats an unquoted token starting with a letter as a
  ## parameter reference and aborts (a value starting with a digit happens to
  ## parse, so failure would depend on the value). Already-quoted values pass
  ## through.
  let i = spec.paramIndex(key)
  if i < 0 or spec.params[i].dataType != xtString: return value
  if value.len >= 2 and value[0] == '"' and value[^1] == '"': return value
  '"' & value & '"'

proc addCodeModelInstance*(nl: Netlist, designator: string, spec: ModelSpec,
                           bindings: openArray[PortBinding],
                           params: openArray[(string, string)] = [],
                           modelName = "", cmPath = ""): Component =
  ## Add an `A`-device instance of `spec`, wiring `bindings` to ports in
  ## declaration order, and register its `.model` card. `modelName` defaults
  ## to the lowercased designator, so instances can differ in parameters.
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
    card &= key & "=" & paramText(spec, key, value)
  card &= ")"
  nl.models[inst] = card

proc addCodeModelInstance*(nl: Netlist, designator: string, spec: ModelSpec,
                           nets: openArray[Net],
                           params: openArray[(string, string)] = [],
                           modelName = "", cmPath = ""): Component =
  ## Convenience form for all-scalar single-ended ports: one net per port.
  var bindings: seq[PortBinding]
  for n in nets: bindings.add wire(n)
  addCodeModelInstance(nl, designator, spec, bindings, params, modelName, cmPath)
