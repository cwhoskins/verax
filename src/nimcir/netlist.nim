## Circuit netlist data model: nets, components and pins wired together with
## direct object references so the graph is fully walkable from any
## starting point, plus name-keyed dictionaries for indexed lookup.
##
## File I/O is opt-in per format, e.g. `import nimcir/netlist/formats/spice`.

import nimcir/netlist/types
import nimcir/netlist/graph
import nimcir/netlist/interfaces

export types, graph, interfaces
