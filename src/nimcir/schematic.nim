## Schematic visualization: a heuristic "does the topology look like I think
## it does" view of a netlist.
##
## A renderer-neutral scene (`scene.nim`), deterministic placement/routing
## (`layout.nim`), and two writers over it: self-contained SVG (`svg.nim`) and
## a public JSON API (`json.nim`). This hub exports the whole pipeline; it is
## a leaf depending only on `nimcir/netlist`, so `import nimcir/schematic`
## drags in no simulator, no analysis and no contract machinery.

import nimcir/schematic/scene
import nimcir/schematic/layout
import nimcir/schematic/svg
import nimcir/schematic/json

export scene, layout, svg, json
