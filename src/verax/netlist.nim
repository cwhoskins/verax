## Circuit netlist data model: nets, components and pins wired together with
## direct object references so the graph is fully walkable from any
## starting point, plus name-keyed dictionaries for indexed lookup.
##
## File I/O is opt-in per format, e.g. `import verax/netlist/formats/spice`.

import verax/netlist/types
import verax/netlist/graph
import verax/netlist/interfaces

export types, graph, interfaces
