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
  `SchematicPart`s (position, symbol, the pin-span `bodyW`/`bodyH` **and** the
  smaller drawn-ink `inkW`/`inkH`, a `rotation` of 0/90/180/270, per-pin world
  positions),
  `SchematicWire`s (per-net polylines, tagged signal/ground/supply),
  `SchematicJunction`s, `SchematicLabel`s (text plus `anchor`/`size`/`role`/
  `owner` — every one placed by `layout` against the finished geometry, the
  writer only renders them), `SchematicPort`s and a bounding box —
  all in world units with no SVG, DOM or JSON types. `Point` carries the
  arithmetic the placement and routing passes use; it relies on the compiler's
  structural `==` and generic object `hash` (both key on the grid-snapped
  coordinates). A `SchematicPort` is one entry of `Netlist.ports` drawn at the
  sheet edge: a body centre, extents, a `PortDirection` (`pdInput`/`pdOutput`/
  `pdBidir`/`pdUnspecified`) and a `rotation` of 0 (body extends right) or 180
  (left) — never any other value. Its connecting stub is **not** a field: it is
  emitted as an ordinary `wkSignal` wire on the port's net, so a port stays
  inside the occupancy system and the net's polylines rather than being a
  special case.
- **`layout.nim`** — `layout(nl: Netlist): Schematic`, pure and deterministic.
  Eligible two-terminal parts take one of four orientations (0/90/180/270,
  `rotationChoices`): `bestRotation` picks the one minimising each pin's
  Manhattan distance to the centroid of its net-mates' pins, so both the pin
  axis **and which end each pin takes** fall out of one wirelength test — a
  180° flip when it shortens the wires, no separate rule. Only the square
  two-terminal symbols are eligible, so a quarter turn never swaps
  `bodyW`/`bodyH` and the obstacle/separation rects stay valid. Because the
  attraction force is **pin-to-pin**, rotation is co-optimised *inside* the
  force loop: each iteration re-picks every angle from a snapshot of the
  current centres/rotations (fresh-write, snapshot-read, so order-independent),
  with `grid`-sized hysteresis against flip-flop and the last 30 iterations
  frozen; a final hysteresis-free pass after separation/packing gives the
  definitive assignment. Placement is a Fruchterman–Reingold force layout
  seeded on a golden-angle spiral (no randomness, no clock): repulsion
  (centre-to-centre — this is the non-overlap term), **pin-to-pin** attraction
  along nets (ground nets excluded, power nets weaker; a net with pins on N
  parts pulls every pair, and a parallel pair sharing two nets is pulled by
  both wires at once, so its rest state is the two parts side by side rather
  than tugged toward one overlapping point — what centre-to-centre could not
  express), a gentle gravity, a grid snap, then a deterministic separation
  pass that
  places each part at the nearest grid cell whose **inflated body** is clear
  of every already-placed one — inflation is `routingClearance` (12 world
  units) plus an extra channel, so the final layout never overlaps and a
  route fits between any two bodies. After separation a **packing pass**
  (`groupsOf`/`packGroups`) partitions the parts into blocks joined by
  *signal* nets — `isGround`/`isRail` nets are excluded, then any block of
  `mergeMaxParts` (2) or fewer parts is folded into the block holding its
  nearest power-rail net-mate, so a decoupling cap or a pull-up is not
  stranded from its IC — and shelf-packs the block bounding boxes with a
  `groupGap` gutter. The force layout keeps disconnected sub-circuits apart by
  repulsion alone (only a weak gravity opposes it), leaving a page of empty
  space between them; packing collapses that. It is **guarded by total
  bounding-box area**: when the shelf arrangement is not smaller than the
  force layout's — a design whose blocks a shared rail already pulled
  together — the pass reverts, so it can only ever help. Each group moves by a
  rigid grid-snapped translation, so the separation invariant and the grid
  snap both survive it. After the definitive rotation pass a **leaf-snap pass**
  (`leafSnap`) takes each square two-terminal part with exactly one
  non-ground / non-rail net, moves it to the nearest free grid cell out along
  its one net-mate pin's escape axis, and turns it so its connected pin faces
  back at that mate — a single spring fixes a leaf's distance but not its
  direction or alignment, so the force layout leaves it adrift with its pin
  pointing away, and the rotation score's four-way ties (a shunt element sits
  symmetrically between its neighbours) were breaking on nothing better than
  the smaller angle. It runs last and owns both the position and the
  orientation of the leaves it touches; position is only ever moved *closer* to
  the mate pin, parts are visited in insertion order against the others' final
  centres, so it can only help and stays deterministic. Routing is per signal
  net: a tree grows
  from the first pin, each next pin attaching to the closest already-wired
  point through a Hanan free-space grid built from the inflated obstacle
  boundaries so no segment enters an inflated body; a wire
  reaches each pin directly through a short outward stub. The path search is
  **bend-aware**: state is `(node, incoming axis)` and cost is the
  lexicographic pair (Manhattan length, then bend count), so among all
  shortest obstacle-avoiding paths the fewest-bend one is chosen. Each source
  is seeded in both axis states -- the first graph edge is free whichever
  axis it takes -- and the short pin stubs at the two endpoints sit outside
  the graph, so neither is charged as a bend; equal (length, bends) pairs fall
  back to the lowest node index, then the horizontal axis state. **Rail
  decisions come from
  `netlist/kinds.isGround`/`isRail`, never from name guessing**: a ground net
  draws a local ground stub at each pin, a supply net a local stub labelled
  with the net name, and neither is wired as a tree. Each stub leaves its pin
  along that pin's outward escape direction (`escapeDir`), so it always juts
  *away* from the body -- a positive rail on a top-edge pin stubs up, a
  negative rail on a box's bottom-edge `V-` pin stubs *down* rather than back
  up through the body, and a rail on a side pin stubs sideways. The glyph
  (`svg.nim`) is drawn perpendicular to whatever direction the stub took. Junction dots
  appear where three or more segments meet. Routing is occupancy-aware and
  upholds one hard geometric invariant, stronger across nets than within one:
  **two wires of the same net never share a positive-length collinear
  segment** (they may meet at a vertex and may continue straight through one),
  while **two wires of different nets never touch collinearly at all — not
  even end-to-end — and keep at least `wireMinSeparation` (8 world units) of
  centreline separation wherever they run parallel and their projections
  overlap.** Different nets may still cross perpendicularly. Signal routes and
  rail stubs are emitted in a deterministic order and later geometry is
  steered or shortened so it only touches what is already there — this
  includes each **signal pin's escape stub**: those fixed short outward
  segments are seeded into the shortening test before any ground/supply stub
  is drawn, so a rail stub cannot end up running along one (a case tighter
  placement makes reachable). If no bend-aware path can be found under those
  rules, `routeNet` returns a recoverable `RouteOutcome` (`ok = false` with
  the first unconnected `failPin`) instead of raising — ordinary
  unreachability is a placement problem, not a bug. `layout` then runs a
  **placement–routing feedback loop** (`recoverRouting`): it tries
  deterministic single-part moves and keeps any move that routes strictly
  further than the best layout so far, up to a private budget of
  `feedbackAcceptedBudget` (4) accepted moves and `feedbackAttemptBudget`
  (65) total attempts. Movable parts are those with at least two
  non-ground / non-rail nets (`feedbackCandidateParts`, insertion order);
  each is tried on rings of grid cells around its current centre up to
  `feedbackMaxRadius` (4), and a candidate cell is rejected only when it
  would overlap another part's *raw* body — the placement separation
  clearance may relax during recovery, but symbols never overlap. After each
  move the eligible rotations are recomputed (`recomputeRotations`, the same
  definitive pass used after separation); `leafSnap` is deliberately not
  rerun. Attempt-zero layouts are untouched: a netlist that already routes
  takes exactly the path it took before the loop existed. If recovery still
  cannot route — or the sheet has more than `feedbackMaxParts` (24)
  components, where re-routing per candidate is too expensive — `layout`
  raises one enriched `doAssert` naming the net, pin, position and the
  accepted/attempt budgets. Path-integrity failures inside `routeNet` (empty
  path, wrong endpoint, occupancy violation, non-axis segment) stay
  immediate assertions: those are bugs, never placement problems. Within one
  signal net the wires are grown as a tree
  (each next pin attaches to the closest already-wired point), so the net's
  polylines partition its segments exactly once. Controlled sources (`vcvs`,
  `vccs`, `cccs`, `ccvs`) draw as a rectangular `source4` buffer/controlled
  source with `OUT+`/`OUT-` on the right edge and `IN+`/`IN-` on the left,
  keyed by pin name rather than declaration order, and labelled inside the
  body (no source-type polarity marker). Determinism is a property worth
  stating, not assuming: iteration order is graph insertion order throughout,
  `Table`/`HashSet` keys are only ever *looked up* (never iterated) except
  where their contents are sorted afterwards (`junctions`).
  **Interface ports** come from `nl.ports` (declared order — an `OrderedTable`,
  iterated like `nl.nets`). A rail or ground port is skipped: it already draws
  its own glyph, and `isGround`/`isRail` are consulted through local wrappers
  that let an explicit `ntPower` net kind beat a stray `ptGround`-kinded pin (an
  op-amp's `V-` supply pin) — otherwise that net would render as ground.
  `portDirection` reads pin kinds first (`ptOutput` → `pdOutput`, `ptInOut` →
  `pdBidir`, `ptInput` → `pdInput`) and falls back to a driver test: a net
  nothing on the sheet drives is an input, one something drives makes no
  directional claim. Ports live in a **fixed column** just outside the parts —
  the left edge for `pdInput`/`pdUnspecified`, the right edge for
  `pdOutput`/`pdBidir`, so signal reads left to right — and `layout` picks each
  port's `y` from its net-mate pin, pushed down only to clear a port already
  placed in that column. The port body is a routing obstacle and its
  connection point is fed to `routeNet` as an extra net pin with an explicit
  inward escape, so the connecting wire is a normal net branch that never
  crosses a body; the plain text label for a ported net is suppressed.
  One trap this pass has to handle: rendering a subcircuit **instance's
  cloned child** directly (what `verify`'s per-subckt sheets do) means its
  shared global net `"0"` carries pins from every sibling clone, and siblings
  reuse designators — so pins are filtered by owning-`Netlist` identity, not by
  name, everywhere `layout` walks `net.pins`.
  Finally a **label pass** places every free-standing `SchematicLabel` — each
  non-box part's designator+value as one stacked block, each signal net's name
  near its leftmost-then-topmost pin, each supply rail's name at its stub — by
  a first-fit search over candidate spots around the thing named. It measures
  from `inkW`/`inkH`, the *drawn* symbol box, not the pin span, so a resistor's
  designator sits just above its zigzag rather than 40 units past it; a
  90/270 rotation swaps the ink extents. Candidates are the four sides (the
  ones **no pin escapes through** first — right, top, left, bottom — then the
  occupied ones, then the four corners); a candidate is rejected if its text
  box (`0.6·size` per monospace char) crosses any wire, any symbol lead stub,
  any drawn-ink rect, port body or ground/supply glyph footprint, or a label
  already placed. A net name's anchor pin has that pin's own escape side tried
  **last** — its wire leaves there. Placement order
  is parts, then net names, then rail names, each scored against all before
  it; a wire or lead crossing outweighs any body/label overlap, and the
  lowest-penalty candidate wins (earliest on a tie), so a boxed-in label on a
  dense sheet lands in the *least bad* spot rather than dead centre — the pass
  is total and deterministic. Box designators/values are **not** placed here —
  `svg` draws those inside the body where `boxSlots` reserved the room. The
  force/separation/packing passes were deliberately **not** given label
  reservation: the label side depends on a rotation co-optimised inside the
  force loop, and widening the bodies would shift every existing layout and
  void `packGroups`' area guard — choosing a good spot in the space those
  passes already leave (`2·placementPad` between bodies) is cheaper and
  reversible. If crowding proves it insufficient, folding label extents into
  `ohw`/`ohh` is the follow-up.
- **`svg.nim`** — `renderSvg`/`writeSvgFile`. Self-contained SVG: every colour
  a literal, every style inlined, a graph-paper grid, wires as polylines,
  junction circles, ground/power symbols (each bar drawn perpendicular to the
  stub it caps, so a sideways or downward rail stub still gets an upright
  glyph) and a small symbol library (resistor
  zigzag, capacitor plates, inductor arcs, diode triangle+bar, source circles,
  controlled-source rectangle, transistor body). Each symbol's stroked extent
  must match the `inkExtent` table in `layout.nim` — the two files are the
  only ones that know drawn geometry, and the label pass reads that table, so
  a change to a symbol's drawing here needs the matching entry updated there.
  A rotated part is drawn with a `rotate(rotation)` group around its centre;
  its `SchematicLabel`s were placed by `layout` outside any group and rendered
  after it, so they stay upright. **Painter order** is grid, wires, junction
  dots, part symbols, ports, labels: dots sit on top of the wires they join
  but under any symbol fill, so a dot that lands at a part pin or port edge
  never paints over the symbol. Anything a kind table
  does not recognise — and any hierarchical instance — is drawn as a
  **fallback box** (`boxSlots` in `layout.nim`): `ptPower` pins leave the top
  edge, `ptGround` the bottom, `ptInput` the left and `ptOutput` the right,
  every other pin fills the left edge then the right, and each edge's pins are
  spread symmetrically about the body centre. Pins sit on the `bodyW`/`bodyH`
  extent — so their routing escape points stay on the Hanan grid exactly as a
  symbol's edge pins do — and the *drawn* rectangle is inset from that by
  `layout.boxStub` (20) on every side, so each pin visibly juts out on a short
  stub with its name printed just inside. The designator and value/kind stack
  at the top-left inside corner, clear of the centred rows and columns of pin
  labels — this is the **one** kind of part text `svg` still places itself
  (the label pass skips boxes), because `boxSlots` already sized the body to
  hold it. A box never rotates.
  `drawPort` draws each `SchematicPort` as one `<polygon>` pennant with its
  name centred: a flat-left/point-right pentagon for `pdInput`/`pdOutput`, a
  both-ends-pointed hexagon for `pdBidir`, a plain rectangle for
  `pdUnspecified` — every arrow points right (signal flow), and the polygon is
  computed directly rather than in a `rotate()` group so the text stays upright
  without the outside-the-group dance a part needs.
- **`json.nim`** — the public JSON API (`sceneToJson`, `sceneToJsonString`,
  `writeSceneJsonFile`), for a future interactive frontend that consumes the
  scene without re-parsing the SVG. Each part carries its `rotation` as an
  additive numeric field; ports are a `ports` array with `dir` as a string
  (`portDirName`). The run archive itself stays SVG-only.

**Dependency direction stays intact**: `schematic` imports only `netlist`, and
`spice/ngspice` imports `schematic` to archive a per-run SVG while `verify`
imports it to archive the authored design as `runFULL.svg` plus one
`runFULL.<subckt>.svg` per distinct instantiated subcircuit — both consumers sit
above it on the existing spine, never across or up it.
