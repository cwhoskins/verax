## Tying a parsed `IbisFile` to a real design: which `[Component]` in the
## file describes which reference designator, and the check that its `[Pin]`
## names actually line up with that part's pins.
##
## This is the one module in `verax/ibis` that imports both `verax/netlist`
## and `verax/pcb`, and it is why the submodule sits where it does in the
## dependency order -- above both, imported by neither.
##
## **Deliberately not here:** turning an I/V table into a simulatable device
## (that is a `verax/spice/models` behavioural model, keyed on
## `Component.kind`), and turning an edge rate into a timing budget (that is
## an `verax/analysis` evaluator). This module stops at "the binding is
## consistent" -- which is the cheap check worth making before either of
## those is attempted.

import std/tables
import ../netlist
import ../pcb
import ./types

export types

type
  IbisBinding* = object
    ## "This IBIS component describes this designator." Holds the parsed
    ## file so a later consumer needs only the binding.
    file*: IbisFile
    componentName*: string
    designator*: string

proc bindIbis*(nl: Netlist, designator: string, f: IbisFile,
               componentName = ""): IbisBinding =
  ## Associate one `[Component]` in `f` with a reference designator in `nl`,
  ## and verify the pin names match.
  ##
  ## `componentName` defaults to `f`'s sole `[Component]` when it has exactly
  ## one. Raises `IbisError` if the designator is absent from `nl`, if the
  ## component name is ambiguous or absent, or on the first `[Pin]` whose
  ## name is not a pin of the netlist component -- the mismatch message names
  ## that pin, since finding it is the whole point of the binding.
  let comp = nl.findComponent(designator)
  if comp == nil:
    raise newException(IbisError,
      "netlist has no component '" & designator & "' to bind an IBIS model to")

  var cn = componentName
  if cn.len == 0:
    if f.components.len != 1:
      raise newException(IbisError,
        "IBIS file has " & $f.components.len & " components; name which one " &
        "binds to '" & designator & "'")
    cn = f.components[0].name
  let ic = f.component(cn)   # raises IbisError if absent

  for pe in ic.pins:
    if not comp.pins.hasKey(pe.name):
      raise newException(IbisError,
        "IBIS [Component] '" & cn & "' pin '" & pe.name &
        "' has no match on netlist component '" & designator & "'")

  IbisBinding(file: f, componentName: cn, designator: designator)

proc modelFor*(b: IbisBinding, pinName: string): IbisModel =
  ## The `[Model]` the bound component uses on one pin. Raises `IbisError` if
  ## the pin carries a reserved name (`POWER`/`GND`/`NC`) rather than a
  ## buffer model.
  b.file.modelFor(b.componentName, pinName)

proc placementOf*(pcb: Pcb, b: IbisBinding): Placement =
  ## The board `Placement` for a binding's designator, or `nil` if the part
  ## is not placed. A thin pass-through to `pcb/graph.placementOf`, here so a
  ## caller holding a binding never has to reach back to the `Component`.
  let comp = pcb.netlist.findComponent(b.designator)
  if comp == nil: return nil
  pcb.placementOf(comp)
