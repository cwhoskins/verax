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
  special case. A `SchematicFallback` is the scene's "could not wire this"
  record: the exact `net` name, the owning `part`/`pin` ("" for a port
  connection point), the pin position, the pin's outward `ex`/`ey` escape and
  a `points` polyline for the dashed marker stub. An empty `points` is a
  **zero-space** fallback — no wire, only the marker and label at the pin.
  Fallbacks are stored in `Schematic.fallbacks`, *not* in `wires`, so they
  never reach the occupancy set or the junction pass.
- **`layout.nim`** — compatibility façade and pipeline coordinator for `layout(nl: Netlist): Schematic`, pure and deterministic. Its internal implementation is split across `geometry.nim`, `symbols.nim`, `placement.nim`, `router.nim`, `routing.nim`, `labels.nim`, `finish.nim`, `diagnostics.nim`, and (see below) `composites/composite.nim`, `composites/passive.nim` and `constrained.nim`; these are included implementation units so private layout state stays internal while the established `layout` API remains the import boundary. The include order is load-bearing: `composites/composite` and `composites/passive` sit after `placement.nim` (they use `rotationChoices`/`slotOf`/`rotatedSlot`/`axisUnit`/`pinWorldPositions`) and before `constrained.nim` (which pools placement over the arena they define), and `state.nim`'s include must stay between `constrained.nim` (uses its procs) and `routing.nim` (defines `RoutingState`). Private included `state.nim` holds `LayoutState`/`RoutingState`: component-symbol-position state and label-only routing metadata must never be added to public `Schematic`. `state.nim` also carries the placement-stage bodies (`prepare`, `forcePlace`, `snapToGrid`, `separate`) and the thin `*(state: var LayoutState)` forwarders, so `layout` itself is just the ordered stage list — the historical policy's serialized output stays byte-identical, so those bodies are a verbatim move, not a rewrite. `finish.nim` consumes the completed scene plus that state while preserving label order and bounds behavior. `LayoutOptions.policy` defaults to `lpHistorical`, whose output must remain byte-identical. `parseLayoutPolicy` and `archiveLayoutOptions` centralize the CLI/environment spelling used only by archive writers; ordinary `layout(nl)` remains historical. The opt-in `lpConstrainedLayered` policy gives `lsSemanticSeed` (after the deterministic golden-angle seed) and `lsConstrainedRefinement` (after force placement and before existing legalization) their bounded deterministic topology/layer meaning; it uses the existing bounded routing recovery as `lsRoutingAwareRepair`. It is for ordinary sheets (at most 64 *placement units*, and at most 256 raw parts), not a general graph-drawing solver: output-pin arcs seed left-to-right columns, while bounded deterministic stage placement folds each semantic layer across at most three adjacent columns (grouping parallel flat two-terminal parts by the same unordered net pair) rather than making a passive-heavy layer arbitrarily vertical; a same-component return has the adjacent-stage freedom on either side of its source, not an output-side-only rule. A bounded semantic walk follows every flat device with exactly two connected terminals (regardless of kind) until an input endpoint, stopping at rails, ground, hierarchy and inputs. It uses the existing `portDirection(net) == pdInput` result, including its no-driver fallback, for input interfaces. A same-component return keeps its traversed parts in the source column; a genuine return to an earlier component keeps its path passives right of the driving output. Insertion order otherwise breaks feedback arcs, and existing legalization remains authoritative for non-overlap. Its signal trees are atomic trunk-and-tap attempts: a failed net restores occupancy and becomes marker-only fallbacks. Do not attach heuristics, reorder existing passes, or reinterpret terminal/recovery safeguards.
  A placement unit is a raw singleton or a whole recognized composite
  (`constrainedEligible`, `constrained.nim`): the semantic layering
  (`constrainedTopology`/`constrainedTargets`) and the per-candidate route
  score `recoverRouting` calls per attempted move both cost against the
  *pool* -- singletons plus one entry per composite, not one entry per raw
  component -- so a sheet whose raw part count exceeds 64 but whose
  composite-collapsed pool does not still gets the constrained treatment
  instead of falling back to the ungrouped golden-spiral seed. The 256 raw
  ceiling exists because arc *discovery* (`pathsFrom`, the direct output-pin
  scan) and `constrainedRouteScore` are still raw-sized even after pooling:
  pooling looking favorable on paper must not admit an unboundedly large raw
  sheet into an O(pool · arcs) relaxation whose per-arc work is still
  O(raw). A composite-free sheet has pool == raw, so this is a strict
  loosening, never a tightening, of the pre-pooling all-raw gate.
  Eligible two-terminal parts take one of four orientations (0/90/180/270,
  `rotationChoices`): `bestRotation` first applies a **strong lexicographic
  power-direction rank** — ground pins down; rails annotated at <=0 V down;
  rails annotated >0 V up; unannotated rails up — then minimises each pin's
  Manhattan distance to the centroid of its net-mates' pins within equal
  ranks. An explicit `ntPower` kind beats a stray `ptGround` pin (an op-amp
  V- supply is still a rail), and hysteresis never retains a worse power
  rank. Thus both the pin axis **and which end each pin takes** fall out of
  semantic direction followed by wirelength — a 180° flip when it shortens
  the wires, no separate rule. Only the square
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
  snap both survive it. After the definitive rotation pass, the historical
  policy runs a **leaf-snap pass** (`leafSnap`); `lpConstrainedLayered` always
  skips it. The pass takes each square two-terminal part with exactly one
  non-ground / non-rail net, moves it to the nearest free grid cell out along
  its one net-mate pin's escape axis, and turns it so its connected pin faces
  back at that mate — except a powered leaf uses the same strong
  power-direction rank and is placed on the corresponding side so its signal
  pin still faces the mate — a single spring fixes a leaf's distance but not its
  direction or alignment, so the force layout leaves it adrift with its pin
  pointing away, and the rotation score's four-way ties (a shunt element sits
  symmetrically between its neighbours) were breaking on nothing better than
  the smaller angle. It runs last and owns both the position and the
  orientation of the leaves it touches; position is only ever moved *closer* to
  the mate pin, parts are visited in insertion order against the others' final
  centres, so it can only help and stays deterministic. A bounded deterministic
  **terminal-clearance repair** then reserves each prospective full 40-unit
  ground/supply glyph against foreign signal escape corridors,
  routing-inflated foreign bodies and different-net terminal glyphs. Exact
  connected terminal-pin coincidences on distinct nets are a hard condition
  (same-net coincidences remain valid): it reduces those before ordinary glyph
  conflicts, and the small-sheet glyph shortcut cannot bypass them. It tries
  implicated small passive parts first; protected powered leaves retain their
  `leafSnap` placement when another part can move. Routing-time glyph blockers
  and stem shortening
  remain the safeguard for irreducible crowding. Routing is per signal net: a tree grows
  from the first pin, each next pin attaching to the closest already-wired
  point through a Hanan free-space grid built from the inflated obstacle
  boundaries and signal-terminal escape coordinates, so an off-centre pin can
  turn directly after its outward stub while no segment enters an inflated body; a wire
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
  includes each **escape stub**, the fixed short segment a signal pin (or an
  interface port's connection point) takes out to the routing grid. Those
  stubs are seeded, tagged with their own net, before any ground/supply stub
  is drawn, and are handed to both consumers that must respect them: the
  rail/ground stub shortening test, and the signal route's occupancy check.
  Against a seeded stub a signal route may touch at an endpoint and may cross
  perpendicularly, but may never run along a positive-length part of it — a
  foreign net cannot thread another pin's escape corridor. The seed is
  deliberately *not* held to the stronger cross-net wire rule (which forbids
  even an end-to-end touch): that rule is for emitted wires, and the real
  RIAA operating-point fragment showed the stronger reading turning a route
  that merely ends at a neighbouring seed into a needless fallback. If no
  bend-aware path can be found under those
  rules, `routeNet` returns a recoverable `RouteOutcome` (`ok = false` with
  the first unconnected `failPin`) instead of raising — ordinary
  unreachability is a placement problem, not a bug. `layout` then runs a
  **placement–routing feedback loop** (`recoverRouting`): it tries
  deterministic single-part moves and keeps any move that routes strictly
  further than the best layout so far, up to a private budget of
  `feedbackAcceptedBudget` (4) accepted moves and `feedbackAttemptBudget`
  (30 — lowered from 65 once profiling `xbar_switch` showed every accepted
  move across its two recovering sheets landed by attempt 22, and the
  remaining 43 attempts of the old budget never once improved on the best
  layout found) total attempts. Movable parts are those with at least two
  non-ground / non-rail nets (`feedbackCandidateParts`, insertion order);
  each is tried on rings of grid cells around its current centre up to
  `feedbackMaxRadius` (4), and a candidate cell is rejected when it would
  overlap another part's *raw* body or its final recomputed rotations leave
  exact connected terminal pins on distinct nets coincident — the placement
  separation clearance may relax during recovery, but symbols never overlap.
  After each move the eligible rotations are recomputed (`recomputeRotations`, the same
  definitive pass used after separation); `leafSnap` is deliberately not
  rerun. Attempt-zero layouts are untouched: a netlist that already routes
  takes exactly the path it took before the loop existed. If recovery still
  cannot route — or the sheet has more than `feedbackMaxParts` (24)
  *placement units* (composites pooled, so a composite counts once, not once
  per raw member) or more than `4 * feedbackMaxParts` (96) raw parts
  regardless of pooling, where re-routing per candidate is too expensive —
  `layout` re-routes the best positions with fallbacks enabled instead of raising:
  the unrouteable net contributes no real wires, and every one of its pins
  becomes a `SchematicFallback` (a short dashed amber/orange stub sized
  against the complete occupancy set, so it never touches a real wire
  collinearly nor crowds it in parallel; an empty `points` is a zero-space
  fallback with only the marker and label at the pin). A signal net with a
  single dangling pin is treated the same way in *every* route — it is not a
  routing failure (`ok` stays true), but it is never silently dropped.
  Fallback stubs are not connectivity: they are finalised after all real
  wires, are never added to `occ`, and never produce a junction.
  Path-integrity failures inside `routeNet` (empty
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
  name, everywhere `layout` walks `net.pins`. The dual of that filter is
  `onThisSheet` (`composites/composite.nim`): a **global** net (`"0"`, any
  `global = true` rail) stays a single object whose `.netlist` is the root, so
  a bare `net.netlist == nl` test wrongly rejects this sheet's own
  ground-connected two-terminal parts — `isTraversable` and `pathsFrom` accept
  a net that is either owned by `nl` *or* the identical object `nl.nets` holds
  under that name, which a sibling's private net never is. Without it the pi
  section in `RIAA_CHANNEL` (`RL`–`CIN`–`RB`) is not recognized on the child
  sheet and its parts scatter.
  Finally a **label pass** places every free-standing `SchematicLabel` — each
  non-box part's designator+value as one stacked block, each signal net's name
  near its leftmost-then-topmost pin, each supply rail's name at its stub, and
  each fallback's exact net name at its pin (the fallback net is then skipped
  by the ordinary net-name pass, so a fallback is never labelled twice) — by
  a first-fit search over candidate spots around the thing named. It measures
  from `inkW`/`inkH`, the *drawn* symbol box, not the pin span, so a resistor's
  designator sits just above its zigzag rather than 40 units past it; a
  90/270 rotation swaps the ink extents. Candidates are the four sides (the
  ones **no pin escapes through** first — right, top, left, bottom — then the
  occupied ones, then the four corners); a candidate is rejected if its text
  box (`0.6·size` per monospace char) crosses any wire, any symbol lead stub,
  any dashed fallback stub, any drawn-ink rect, port body or ground/supply
  glyph footprint, or a label already placed. A net name's anchor pin has
  that pin's own escape side tried **last** — its wire leaves there. Placement
  order
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
  Finally a **scene-based fallback reroute diagnostic** lives here as
  `diagnoseFallbackNet`/`diagnoseFallbackNets`/`diagnoseAllFallbacks` (and
  the `FallbackReroute`/`RerouteBlockKind` result types). It is a
  *final-scene* diagnostic, deliberately not a historical replay: it takes a
  finished `Schematic` (the one archived beside its SVG), rebuilds the
  router's inputs from the scene alone — obstacles from part/port bodies,
  occupancy from the emitted wires, escape seeds from part pins and ports,
  rail/ground identity from wire kind (a scene no longer carries `Net.kind`)
  — and re-runs `routeNet` for one fallback net against that final geometry.
  The answer is "could this net route as a real tree in the scene that was
  actually drawn", and when it cannot it reports the first unreachable
  endpoint plus a first-order blocker classification (`rbObstacle` /
  `rbOccupancy` / `rbEscapeSeed`) with the offending net or body named. It
  inspects the failed pin's own escape point and its first-hop edges only — a
  failure deeper in the grid is honestly reported as occupancy without
  guessing a specific occupant — and it never attempts a placement feedback
  move. The scene-with-no-netlist input is why it pairs with the JSON reader:
  a run-archive `runNNN.json` is enough to ask why a dashed fallback marker
  is there.
- **`composites/composite.nim`**, **`composites/passive.nim`**,
  **`composites/pi.nim`** and **`composites/tee.nim`** — the composite arena
  `constrained.nim` pools placement over, and the three motifs registered into
  it. `composite.nim` is kind-agnostic: `CompositePort`,
  `PlaceableItem`, `CompositePlan` (the arena: `items`, the leaf/composite
  entries; `topLevel`, the arena indices placement actually sees, singletons
  and top-level composites interleaved in ascending first-raw-member order;
  `ownerOf`/`poolOf`, raw index to owning arena index / pool position), and
  the `CompositeKind` contract — seven `{.nimcall.}` hooks
  (`recognize`/`internalLayout`/`externalPins`/`pickRepresentative`/
  `internalRoute`/`rotationCandidates`/`footprint`) a motif implements over
  the arrays `LayoutState` already threads, so a recognizer needs no access to
  placement/routing internals. `footprint` is routing-only: `boundingBoxFootprint`
  (one padded box over every member) is the default and what the parallel
  stack and the tee use — their external terminals sit on that box's edge — while
  the pi returns `memberBodiesFootprint` (each member body padded on its own),
  because its series part's pins are boxed in by the wider flanking shunts and
  a route must thread the channels between the bodies to reach them. Placement
  legalization keeps its own bounding-box `compositeFootprint` regardless.
  `compositeKinds`, the registry, is a `let`, not
  a `var`: nothing outside this included module can register a kind, and
  **registration order is recognition precedence is output**. Adding a motif
  means adding a file beside `passive.nim` and one entry in `compositeKinds`
  — never a special case in the router, placement, or
  `constrainedRecomputeRotations`. `compositePlan` folds the kinds in
  registration order: it keeps each kind's multi-member groups, dropping any
  whose members an earlier kind already claimed, then lays the survivors plus
  the unclaimed singletons into `topLevel` in ascending first-raw-member
  order. This is the **non-nesting** subset of `docs/composite_placement_stage2.md`
  §2.6 — enough for pi/tee, whose members are always raw flat two-terminal
  singletons; a later kind that must genuinely *consume* an earlier composite
  as one of its own members (the op-amp inverting-amp example) still needs the
  arena-index fold this does not do.
  `passive.nim` holds `parallelStackKind`: parallel flat two-terminal parts
  sharing an unordered net pair become one placement unit, keyed by that
  unordered net pair so declaration and pin order cannot split the group
  (`parallelRecognize`). `pi.nim` and `tee.nim` hold the two passive
  filter-section motifs from `docs/composites.md` (ideas 3, and 1+2):
  * **pi** — a flat two-terminal series part with a flat two-terminal
    shunt-to-ground part at *each* end. Recognition is topology-only
    (`isGround` on the shunt legs, `isRail`/`isGround` rejected on the series
    nets) plus the rule that both series nets must reach beyond the composite
    (`>2` pins or a declared port) — a private two-pin end is the tee's mid
    node, and without that rule `[L1]--mid--[L2]` with a shunt at `mid`
    misreads as a pi around `L2`. Canonical drawing: series horizontal,
    a shunt one grid pitch below each pin, ground pins down.
  * **tee** — two flat two-terminal series parts meeting at a *private* mid
    net (exactly three pins, all flat two-terminal, not a port, not
    ground/rail) that also carries one shunt-to-ground part and nothing else.
    The mid net is wholly internal: `teeInternalRoute` draws its T-junction
    and `routing.fullyInternalComposite` makes the signal loop skip external
    routing for it (a net every pin of which is covered by one composite
    port). Canonical drawing: the two series parts in one horizontal row, the
    shunt on the midline one grid pitch below.
  Both exclude a source as a member (`isPassiveElement`, keyed on the symbol
  family, not `Component.kind` spelling): a source on a filter node is a leg
  to ground topologically but not a shunt element. Because `composite.nim` is
  included before `passive.nim`/`pi.nim`/`tee.nim` but must still name their
  `*Kind()` ctors in the registry, it forward-declares all three immediately
  above `compositeKinds` — `include` is a textual splice into one module, so
  these are ordinary forward declarations, resolved once each file's body is
  spliced in below.
- **`svg.nim`** — `renderSvg`/`writeSvgFile`. Self-contained SVG: every colour
  a literal, every style inlined, a graph-paper grid, wires as polylines,
  junction circles, ground/power symbols (each bar drawn perpendicular to the
  stub it caps, so a sideways or downward rail stub still gets an upright
  glyph) and a small symbol library (resistor zigzag, capacitor plates,
  inductor arcs, diode triangle+bar, source circles, controlled-source
  rectangle, transistor body). Wire corner treatment is renderer-only:
  every orthogonal non-junction turn is shown with a 4-unit 45-degree chamfer,
  capped at half of either adjacent segment. A same-net `SchematicJunction`
  retains its square bend; scenes, routing and JSON retain the original
  orthogonal points. The same renderer-only treatment applies to signal,
  ground and supply wires; ground/supply terminal glyph direction continues
  to use the original scene points, and fallback rendering is unchanged.
  Each symbol's stroked extent
  must match the `inkExtent` table in `layout.nim` — the two files are the
  only ones that know drawn geometry, and the label pass reads that table, so
  a change to a symbol's drawing here needs the matching entry updated there.
  A rotated part is drawn with a `rotate(rotation)` group around its centre;
  its `SchematicLabel`s were placed by `layout` outside any group and rendered
  after it, so they stay upright. `drawFallback` renders each
  `SchematicFallback` as a dashed amber/orange polyline (`stroke-dasharray`)
  capped with a small open-circle endpoint marker; an empty `points` draws
  only the marker at the pin. **Painter order** is grid, wires, fallback
  stubs, junction dots, part symbols, ports, labels: dots sit on top of the
  wires they join
  but under any symbol fill, so a dot that lands at a part pin or port edge
  never paints over the symbol, and a fallback marker stays on the wire layer
  rather than the symbol layer. Anything a kind table
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
  `writeSceneJsonFile` **and** the strict reader `jsonToScene` /
  `readSceneJsonFile`), for a future interactive frontend that consumes the
  scene without re-parsing the SVG, and for scene-based diagnostics that read
  a scene back from a run archive. The writer emits `schemaVersion` 1 with
  every `Schematic` field present — each part carries its `rotation` as an
  additive numeric field **and its `bodyW`/`bodyH` pin-span extents** (a
  reader must rebuild the part object exactly, not just enough of it to draw);
  ports are a `ports` array with `dir` as a string (`portDirName`); fallbacks
  are a `fallbacks` array carrying the exact `net`/`part`/`pin`, the pin
  `x`/`y`, the escape `ex`/`ey` and the dashed stub `points` (empty for a
  zero-space fallback). The reader is strict for version 1 — a missing or
  mistyped field, or a `schemaVersion` it does not know, raises
  `SceneJsonError` naming the field — and also reads the legacy **unversioned**
  archive format honestly: that format predates both `schemaVersion` and the
  fallback `ex`/`ey`, so the reader rebuilds the escape direction from the
  scene's own part/port geometry via `layout.fallbackEscapeDir` (`(0, 0)`
  when the scene cannot identify the owner, never an invented direction).
  The run archive writes the JSON beside its SVG: `spice/ngspice` for each
  derived `runNNN`, and `render.nim` for `runFULL` and each child sheet —
  always from the one routed scene, never a second layout.
- **`render.nim`** — the composition layer above `svg`/`json`: it drives
  `layout` over a whole design *and* its sub-circuits and writes the run
  archive. `writeScenePair(scene, base)` writes `base.svg` and `base.json`
  from one scene (both `spice/ngspice`'s `runNNN` and everything below use
  it, so the two files can never disagree about geometry). `keepFullSchematic(nl)`
  is the whole `$NIMCIR_KEEP_RUNS` job `verify` calls: `runFULL` for the root,
  `runFULL.<safeSheetName>` per distinct child (`Netlist.name`-deduplicated),
  and `runFULL.html`. `safeSheetName` maps anything outside `[A-Za-z0-9._-]`
  to `_` so a `.SUBCKT` name is always a legal path fragment. Best-effort
  (a `CatchableError` is swallowed) and a no-op when the variable is unset —
  drawing a picture must never fail a check. It sits here rather than in
  `verify` because it needs only `netlist`, and lives *outside* `svg`/`json`
  because it is the one place that calls `layout` itself and walks hierarchy.
  **`runFULL.html`** is a self-contained hierarchy browser — no external file,
  opens straight from disk. `explorerSheet(n, scene, id)` folds one level into
  an `ExplorerSheet` (id, title, the inline SVG with its XML prolog stripped
  since `<?xml …?>` is invalid mid-document, and a JSON part list); a part
  whose designator keys `n.children` carries that child's `safeSheetName` as
  its `child`, every other part `null`. `renderExplorerHtml(sheets)` inlines
  every sheet into one `const MODEL` blob in the `explorerTemplate` (the only
  place `$TITLE$`/`$MODEL$` are substituted; `</` in the JSON is escaped so it
  cannot close the `<script>`). The page overlays one transparent `<rect>` per
  part, positioned from the scene's `bodyW`/`bodyH` in the SVG's own
  world-unit `viewBox`: single-click opens a properties panel, double-click on
  a `child`-bearing part pushes its sheet, an *Up* button pops the breadcrumb
  history. The root sheet's id is the sentinel `@root`, which `safeSheetName`
  can never produce, so it never collides with a subcircuit's.

**Dependency direction stays intact**: `schematic` imports only `netlist`, and
`spice/ngspice` imports `schematic` to archive each per-run scene as
`runNNN.svg`/`runNNN.json` while `verify` imports it and calls
`render.keepFullSchematic` to archive the authored design as
`runFULL.svg`/`runFULL.json`, one `runFULL.<subckt>` pair per distinct
instantiated subcircuit, and `runFULL.html` — both consumers sit above it on
the existing spine, never across or up it.
