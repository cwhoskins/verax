# `schematic` submodule

`src/nimcir/schematic/` turns a `Netlist` into a renderable schematic **scene**
and writes that scene as self-contained SVG (and, through a public API, JSON).
It is a leaf depending only on `nimcir/netlist` — never on `spice`, `analysis`,
`contract` or `pcb` — and it is a *visualizer*, not an EDA tool: heuristic
placement, no signal-flow awareness, no DRC, no round-trip. The quality bar is
"readable enough to eyeball", stated plainly in
`docs/netlist-converter-research.md`, which is the design note this submodule
implements.

- **`scene.nim`** — the renderer-neutral middle layer. `Schematic`, with placed
  `SchematicPart`s (position, symbol, body extents, a 0/90-degree `rotation`,
  per-pin world positions),
  `SchematicWire`s (per-net polylines, tagged signal/ground/supply),
  `SchematicJunction`s, `SchematicLabel`s and a bounding box — all in world
  units with no SVG, DOM or JSON types. `Point` carries the arithmetic the
  placement and routing passes use; it relies on the compiler's structural
  `==` and generic object `hash` (both key on the grid-snapped coordinates).
- **`layout.nim`** — `layout(nl: Netlist): Schematic`, pure and deterministic.
  After the separation pass, eligible two-terminal parts are rotated 0 or 90
  degrees so their pin axis follows the dominant direction of their
  neighbours (`rotationFor`); the rotated pin slots feed routing and the
  body extents stay square, so obstacles and separation are unaffected.
  Placement is a Fruchterman–Reingold force layout seeded on a golden-angle
  spiral (no randomness, no clock): repulsion, attraction along nets (ground
  nets excluded, power nets weaker, matching the reference visualizer), a
  gentle gravity, a grid snap, then a deterministic separation pass that
  places each part at the nearest grid cell whose **inflated body** is clear
  of every already-placed one — inflation is `routingClearance` (12 world
  units) plus an extra channel, so the final layout never overlaps and a
  route fits between any two bodies. Routing is per signal net: a tree grows
  from the first pin, each next pin attaching to the closest already-wired
  point through a Hanan free-space grid built from the inflated obstacle
  boundaries so no segment enters an inflated body; a wire
  reaches each pin directly through a short outward stub. **Rail decisions come from
  `netlist/kinds.isGround`/`isRail`, never from name guessing**: a ground net
  draws a local ground stub at each pin, a supply net a local up-stub
  labelled with the net name, and neither is wired as a tree. Junction dots
  appear where three or more segments meet. Routing is occupancy-aware and
  upholds one hard geometric invariant: **two distinct `SchematicWire` objects
  never share a positive-length collinear segment.** They may share a vertex
  and may cross perpendicularly; signal routes and rail stubs are emitted in
  a deterministic order and later geometry is steered or shortened so it only
  touches what is already there. Within one signal net the wires are grown as
  a tree (each next pin attaches to the closest already-wired point), so the
  net's polylines partition its segments exactly once. Controlled sources (`vcvs`,
  `vccs`, `cccs`, `ccvs`) draw as a rectangular `source4` buffer/controlled
  source with `OUT+`/`OUT-` on the right edge and `IN+`/`IN-` on the left,
  keyed by pin name rather than declaration order, and labelled inside the
  body (no source-type polarity marker). Determinism is a property worth
  stating, not assuming: iteration order is graph insertion order throughout,
  `Table`/`HashSet` keys are only ever *looked up* (never iterated) except
  where their contents are sorted afterwards (`junctions`).
- **`svg.nim`** — `renderSvg`/`writeSvgFile`. Self-contained SVG: every colour
  a literal, every style inlined, a graph-paper grid, wires as polylines,
  junction circles, ground/power symbols and a small symbol library (resistor
  zigzag, capacitor plates, inductor arcs, diode triangle+bar, source circles,
  controlled-source rectangle, transistor body). A rotated part is drawn with
  a `rotate(rotation)` group around its centre while its designator/value
  labels stay outside the group, so they remain upright. Anything a kind table
  does not recognise — and any hierarchical instance — is drawn as a
  **fallback box** with pins placed down the left edge then the right edge.
- **`json.nim`** — the public JSON API (`sceneToJson`, `sceneToJsonString`,
  `writeSceneJsonFile`), for a future interactive frontend that consumes the
  scene without re-parsing the SVG. Each part carries its `rotation` as an
  additive numeric field. The run archive itself stays SVG-only.

**Dependency direction stays intact**: `schematic` imports only `netlist`, and
`spice/ngspice` imports `schematic` to archive a per-run SVG while `verify`
imports it to archive the authored design as `runFULL.svg` — both consumers sit
above it on the existing spine, never across or up it.
