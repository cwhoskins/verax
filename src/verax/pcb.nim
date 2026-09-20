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
## kept out of the default import surface.

import verax/pcb/units
import verax/pcb/geometry
import verax/pcb/types
import verax/pcb/graph
import verax/pcb/index
import verax/pcb/bom
import verax/pcb/trace
import verax/pcb/impedance
import verax/pcb/tline

export units, geometry, types, graph, index, bom, trace, impedance, tline
