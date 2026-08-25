## Re-export of the shared `Issue` result type, which lives in
## `nimcir/netlist/issue` because `netlist/annotations` and (later) `pcb`
## need it too and depend on neither `spice` nor `analysis`. See that
## module for the type and the conventions around it.
##
## Kept as a module of its own so `import nimcir/analysis/issue` -- and the
## `export issue` in every check module -- continue to mean what they always
## did.

import ../netlist/issue
export issue
