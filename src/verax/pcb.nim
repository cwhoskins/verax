## Physical printed-circuit-board data model: layers, stack-up, copper,
## holes, component placements and board outline, indexed for lookup by net
## name and by location.
##
## The electrical model is not duplicated here -- a `Pcb` owns a `Netlist`
## from `verax/netlist` and points into it, so topology and geometry can be
## walked together without either half depending on the other's schema.
##
## File I/O is opt-in per format, e.g. `import verax/pcb/formats/kicad`,
## matching how `verax/netlist/formats/spice` and `verax/spice/ngspice` are
## kept out of the default import surface. `assemble.nim` is the one
## documented exception: `writeBoard` needs a concrete writer and there is
## exactly one (`formats/kicad.writePcb`'s synthesis branch), so this hub's
## compiled output now includes it -- but it is *not* re-exported here (no
## `export kicadFormat`), so `readPcb`/`writePcb`/`KicadDoc` stay reachable
## only via `import verax/pcb/formats/kicad`, same as before. "Formats stay
## opt-in" is a guarantee about the *symbol surface* `import verax/pcb`
## hands back, not about what gets compiled in on the way to `writeBoard`
## existing at all -- see `pcb/CLAUDE.md` for the fuller reasoning and the
## alternative this ruled out (`assemble.nim` with zero format dependency
## and `writeBoard` living in `formats/kicad.nim` instead, which would have
## kept the guarantee in its stronger form at the cost of the call site
## `verify.nim` actually uses, `pcb/assemble.writeBoard`).

import verax/pcb/units
import verax/pcb/geometry
import verax/pcb/types
import verax/pcb/graph
import verax/pcb/index
import verax/pcb/bom
import verax/pcb/trace
import verax/pcb/impedance
import verax/pcb/tline
import verax/pcb/footprint
import verax/pcb/assemble
import verax/pcb/variant

export units, geometry, types, graph, index, bom, trace, impedance, tline,
       footprint, assemble, variant
