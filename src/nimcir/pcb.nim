## Physical printed-circuit-board data model: layers, stack-up, copper,
## holes, component placements and board outline, indexed for lookup by net
## name and by location.
##
## The electrical model is not duplicated here -- a `Pcb` owns a `Netlist`
## from `nimcir/netlist` and points into it, so topology and geometry can be
## walked together without either half depending on the other's schema.
##
## File I/O is opt-in per format, e.g. `import nimcir/pcb/formats/kicad`,
## matching how `nimcir/netlist/formats/spice` and `nimcir/spice/ngspice` are
## kept out of the default import surface.

import nimcir/pcb/units
import nimcir/pcb/geometry
import nimcir/pcb/types
import nimcir/pcb/graph
import nimcir/pcb/index
import nimcir/pcb/bom

export units, geometry, types, graph, index, bom
