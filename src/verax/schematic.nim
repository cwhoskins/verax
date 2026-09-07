## Schematic visualization: a heuristic "does the topology look like I think
## it does" view of a netlist.
##
## A renderer-neutral scene (`scene.nim`), deterministic placement/routing
## (`layout.nim`), two writers over it -- self-contained SVG (`svg.nim`) and a
## public JSON API (`json.nim`) -- and the run-archive composition layer
## (`render.nim`: the SVG/JSON pair writer and the `runFULL.html` hierarchy
## browser). This hub exports the whole pipeline; it is a leaf depending only
## on `verax/netlist`, so `import verax/schematic` drags in no simulator, no
## analysis and no contract machinery.

import verax/schematic/scene
import verax/schematic/layout
import verax/schematic/pipeline
import verax/schematic/svg
import verax/schematic/json
import verax/schematic/render

export scene, layout, pipeline, svg, json, render
