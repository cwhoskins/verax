## Tying a parsed `IbisFile` to a design: which `[Component]` describes
## which designator, and checking that the `[Pin]` names match. The one
## `ibis` module importing both `netlist` and `pcb`.
##
## Not here: I/V tables as simulatable devices (a `spice/models` job) or
## edge rates as timing budgets (an `analysis` job).

import std/tables
import ../netlist
import ../pcb
import ./types

export types

type
  IbisBinding* = object
    ## "This IBIS component describes this designator", holding the file.
    file*: IbisFile
    componentName*: string
    designator*: string

proc bindIbis*(nl: Netlist, designator: string, f: IbisFile,
               componentName = ""): IbisBinding =
  ## Bind one `[Component]` (default: the file's only one) to a designator
  ## in `nl` and verify pin names. Raises `IbisError` if the designator or
  ## component is absent or ambiguous, or naming the first `[Pin]` that
  ## isn't a netlist pin.
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
  ## The `[Model]` the bound component uses on one pin. Raises on a reserved
  ## name (`POWER`/`GND`/`NC`).
  b.file.modelFor(b.componentName, pinName)

proc placementOf*(pcb: Pcb, b: IbisBinding): Placement =
  ## The board `Placement` for the binding's designator, or `nil`.
  let comp = pcb.netlist.findComponent(b.designator)
  if comp == nil: return nil
  pcb.placementOf(comp)
