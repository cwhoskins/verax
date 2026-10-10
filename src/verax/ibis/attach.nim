## Tying a parsed `IbisFile` to a design: which `[Component]` describes
## which designator, and which `[Pin]` row each netlist pin is (by pin name,
## else `signal_name`). The one
## `ibis` module importing both `netlist` and `pcb`.
##
## Not here: I/V tables as simulatable devices (a `spice/models` job) or
## edge rates as timing budgets (an `analysis` job).

import std/[tables, sets, strutils]
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
    pinMap*: Table[string, string]
      ## Netlist pin name -> IBIS `[Pin]` name, for every netlist pin that
      ## matched one. A pin absent here is looked up under its own name
      ## (`ibisPin`), so a hand-built binding with no map still works.

proc bindIbis*(nl: Netlist, designator: string, f: IbisFile,
               componentName = ""): IbisBinding =
  ## Bind one `[Component]` (default: the file's only one) to a designator
  ## in `nl`, matching each netlist pin to a `[Pin]` row: by the row's pin
  ## name first, else by its `signal_name` (a vendor file names package
  ## pins `103` where a design names them `PA11`). A signal name on several
  ## rows matches only when every row uses the same model (`VDD` on twelve
  ## `POWER` pins); otherwise it is ambiguous and left unmatched. The part
  ## may declare fewer pins than the file describes -- a design states the
  ## pins it uses. Raises `IbisError` if the designator or component is
  ## absent or ambiguous, or if **no** netlist pin matches a row (the wrong
  ## file).
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

  result = IbisBinding(file: f, componentName: cn, designator: designator)
  var byName = initHashSet[string]()
  for pe in ic.pins: byName.incl pe.name
  for pn in comp.pins.keys:
    if pn in byName:
      result.pinMap[pn] = pn
      continue
    var hit = ""
    var model = ""
    var ambiguous = false
    for pe in ic.pins:
      if cmpIgnoreCase(pe.signal, pn) != 0: continue
      if hit.len == 0:
        hit = pe.name
        model = pe.model
      elif cmpIgnoreCase(pe.model, model) != 0:
        ambiguous = true
    if hit.len > 0 and not ambiguous: result.pinMap[pn] = hit
  if result.pinMap.len == 0:
    raise newException(IbisError,
      "IBIS [Component] '" & cn & "' has no [Pin] row matching any pin of " &
      "netlist component '" & designator & "' (by pin name or signal_name)")

proc ibisPin*(b: IbisBinding, netlistPin: string): string =
  ## The `[Pin]` name a netlist pin matched, else the pin's own name.
  b.pinMap.getOrDefault(netlistPin, netlistPin)

proc netlistPin*(b: IbisBinding, ibisPin: string): string =
  ## The netlist pin that matched a `[Pin]` row, else the row's own name.
  for k, v in b.pinMap:
    if v == ibisPin: return k
  ibisPin

proc modelFor*(b: IbisBinding, pinName: string): IbisModel =
  ## The `[Model]` the bound component uses on one netlist pin. Raises on a
  ## reserved name (`POWER`/`GND`/`NC`).
  b.file.modelFor(b.componentName, b.ibisPin(pinName))

proc placementOf*(pcb: Pcb, b: IbisBinding): Placement =
  ## The board `Placement` for the binding's designator, or `nil`.
  let comp = pcb.netlist.findComponent(b.designator)
  if comp == nil: return nil
  pcb.placementOf(comp)
