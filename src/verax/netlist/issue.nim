## Shared result type for a check that finds a problem. Lives in `netlist/`
## because `netlist/annotations`, `pcb` and `analysis` all need it;
## `analysis/issue.nim` re-exports it.
##
## A check never raises on a netlist-content problem -- the `Issue` is the
## return value. `Issue.kind` is an open string, so checks add their own
## kinds.

import std/tables
import ./types

type
  Severity* = enum
    sevInfo, sevWarning, sevError

  Issue* = object
    kind*: string
      ## Open check identifier (`"output_conflict"`, `"no_dc_path"`, ...).
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
      ## Open-ended extras (e.g. a resolved SPICE voltage).

proc newIssue*(kind: string, severity: Severity, message: string,
               net: Net = nil, pins: seq[Pin] = @[],
               components: seq[Component] = @[]): Issue =
  Issue(kind: kind, severity: severity, message: message, net: net,
        pins: pins, components: components)

proc `$`*(i: Issue): string =
  "[" & $i.severity & "] " & i.kind & ": " & i.message
