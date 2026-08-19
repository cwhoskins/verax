## Shared result type for `nimcir/analysis` checks.
##
## A check never raises on a netlist-content problem it finds -- the problem
## *is* the return value (an `Issue`), not an exception; the only exception
## that can surface anywhere in this submodule is `spice/backend.SpiceSimError`,
## which `nimcir/analysis/spice_fallback` catches internally rather than
## propagating. `Issue.kind` is an open-ended string, not a closed enum,
## mirroring `Component.kind`/`SimReplacement.kind` elsewhere in this
## codebase -- so a future check can introduce its own `kind` values without
## editing this shared type.

import std/tables
import ../netlist/types

type
  Severity* = enum
    sevInfo, sevWarning, sevError

  Issue* = object
    kind*: string
      ## Open-ended check identifier, e.g. `"output_conflict"`,
      ## `"no_dc_path"`, `"ambiguous_dc_path"`, `"unconnected_input"`.
    severity*: Severity
    message*: string
      ## Human-readable, ready to print as-is.
    net*: Net
      ## Primary offending/subject net, or `nil` if not net-scoped.
    pins*: seq[Pin]
      ## Offending/relevant pins.
    components*: seq[Component]
      ## Offending/relevant components.
    attrs*: OrderedTable[string, string]
      ## Open-ended extras (e.g. a resolved SPICE voltage), matching the
      ## `attrs` bag convention on every core type.

proc newIssue*(kind: string, severity: Severity, message: string,
               net: Net = nil, pins: seq[Pin] = @[],
               components: seq[Component] = @[]): Issue =
  Issue(kind: kind, severity: severity, message: message, net: net,
        pins: pins, components: components)

proc `$`*(i: Issue): string =
  "[" & $i.severity & "] " & i.kind & ": " & i.message
