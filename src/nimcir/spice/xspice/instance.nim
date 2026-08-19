## Instantiating an XSPICE code model into a `Netlist` as an `A` device.
##
## **No change to `netlist/formats/spice.nim` is needed for this.** That
## module's `formatDeviceLine` already falls back, for any `kind` absent from
## its `pinTemplates` table, to emitting the pins in insertion order followed
## by `attrs["value"]`. For a component designated `a1`, with pins added in
## `.ifs` port order and `value` set to the model-instance name, that produces
## `a1 in out gain1` -- valid XSPICE syntax. The `.model` card rides along via
## the existing verbatim `Netlist.models` passthrough.
##
## What this buys over hand-building the component: the ports and parameters
## are checked against the `ModelSpec` the `.cm` was actually built from, so a
## wrong net count or a misspelled parameter fails here rather than as
## `MIF-ERROR - unable to find definition of model` from ngspice.
##
## **Limits, stated honestly.** Only scalar ports at their `Default_Type` are
## supported, because that is what bare positional nodes mean. Overriding a
## port's type (`%vd(a b)`), vector ports (`%v([a b c])`), `%vnam(v1)` and
## null ports all need the bracketed `A`-device syntax, which is *not*
## positional and which `formats/spice.nim` cannot currently read back. Those
## are deliberately out of scope here.

import std/[strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ./spec

type
  XspiceInstanceError* = object of CatchableError

proc addCodeModelInstance*(nl: Netlist, designator: string, spec: ModelSpec,
                           nets: openArray[Net],
                           params: openArray[(string, string)] = [],
                           modelName = ""): Component =
  ## Add an `A`-device instance of `spec` to `nl`, wiring `nets` to the
  ## model's ports in declaration order, and register the matching `.model`
  ## card in `nl.models`.
  ##
  ## `modelName` is the name shared by the device line and the `.model` card;
  ## it defaults to the lowercased designator, which keeps it unique per
  ## instance so two instances can carry different parameters.
  if designator.len == 0 or designator[0].toUpperAscii != 'A':
    raise newException(XspiceInstanceError,
      "an XSPICE code model instance must have a designator starting with " &
      "'A' (SPICE infers the device type from that letter); got: " & designator)

  for p in spec.ports:
    if p.vector:
      raise newException(XspiceInstanceError,
        "port '" & p.name & "' of code model '" & spec.name & "' is a vector; " &
        "vector ports need the bracketed A-device syntax, which this helper " &
        "does not emit")
  if nets.len != spec.ports.len:
    raise newException(XspiceInstanceError,
      "code model '" & spec.name & "' has " & $spec.ports.len & " ports but " &
      $nets.len & " nets were given for " & designator)

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
  # Pin insertion order is what the SPICE writer emits, so it must match the
  # port order in the .ifs -- which is also what fixes `conn[i]` in the model.
  for i, p in spec.ports:
    discard connect(result, p.name, nets[i], ptPassive)

  var card = spec.name & "("
  for i, (key, value) in params:
    if i > 0: card &= " "
    card &= key & "=" & value
  card &= ")"
  nl.models[inst] = card
