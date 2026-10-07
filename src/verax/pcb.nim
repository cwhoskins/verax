## Physical PCB data model: layers, stack-up, copper, holes, placements,
## outline, indexed by net name and location. A `Pcb` owns a `Netlist` and
## points into it.
##
## File I/O is opt-in per format (`import verax/pcb/formats/kicad`).
## `assemble.writeBoard` compiles in the KiCad writer, but the hub doesn't
## re-export it, so `readPcb`/`writePcb`/`KicadDoc` still need the explicit
## import.

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
