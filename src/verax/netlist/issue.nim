## Shared result type for a check that finds a problem with a design.
##
## This lives in `netlist/` rather than in `verax/analysis`, which is where
## it started and where most of its users are, for the same reason
## `netlist/kinds.nim` does: more than one subsystem needs it and none of
## them can own it. `netlist/annotations` validates the annotation
## vocabulary and must report what it finds; `pcb` will want to report
## design-rule findings; `analysis` already depends on `spice`. A type
## depended on by all three has to sit below all three. `analysis/issue.nim`
## re-exports this unchanged, so every existing import still works.
##
## A check never raises on a netlist-content problem it finds -- the problem
## *is* the return value (an `Issue`), not an exception; the only exception
## that can surface anywhere in this submodule is `spice/backend.SpiceSimError`,
## which `verax/analysis/spice_fallback` catches internally rather than
## propagating. `Issue.kind` is an open-ended string, not a closed enum,
## mirroring `Component.kind`/`SimReplacement.kind` elsewhere in this
## codebase -- so a future check can introduce its own `kind` values without
## editing this shared type.

import std/tables
import ./types

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
