# `schematic` submodule

`src/verax/schematic/` turns a `Netlist` into a renderable schematic **scene**
and writes that scene as self-contained SVG (and, through a public API, JSON).
It is a leaf depending only on `verax/netlist` — never on `spice`, `analysis`,
`contract` or `pcb` — and it is a *visualizer*, not an EDA tool: heuristic
placement, no signal-flow awareness, no DRC, no round-trip. The quality bar is
"readable enough to eyeball", stated plainly in
`docs/netlist-converter-research.md`, which is the design note this submodule
implements.

- **`scene.nim`** — the renderer-neutral middle layer. `Schematic`, with placed
  `SchematicPart`s (position, symbol, the pin-span `bodyW`/`bodyH` **and** the
  smaller drawn-ink `inkW`/`inkH`, a `rotation` of 0/90/180/270, per-pin world
  positions, a `label` that overrides the drawn designator when it differs —
  `"U10A"` for a section of a multi-channel package (`netlist/packages`), `""`
  otherwise; `designator` itself is a join key `finish`/`routing`/`placement`
  all key on and is **never** rewritten in place, and a multi-channel package
  is deliberately **not** a composite — a recognizer keys on `Pin.kind`
  topology and `isTwoTerminal` wants two connected pins with
  `subNetlist == nil`, which an op-amp sharing a die is not),
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
  Bus/interface additions are **additive only** (`sceneSchemaVersion` stays
  **1**): `BundleMember` (`name`, `net`); `WireKind` gains `wkBus`/`wkInterface`
  *appended* so every archived ordinal is unchanged; `FallbackKind`
  (`fbUnrouted` is ordinal **0** and the zero value, so every pre-field
  archive is unchanged, and the writer emits `kind` only when it is not
  this); `members` on `SchematicWire` (member net names, empty for a scalar),
  `SchematicPin` and `SchematicPort` (the declared pairs a merged pin/port
  stands for). Width (`members.len > 1`) means one wire carries more than one
  net; colour (`wkBus` blue / `wkInterface` purple) means membership, and
  applies whether or not anything collapsed.
  Subsheet-array additions follow the same discipline (`sceneSchemaVersion`
  stays **1**): `wkChain` *appended* to `WireKind` (the collapsed link chain
  of a repeated subsheet array — `svg` draws it as a curve, `members` holds
  the N−1 link nets); `PinMark` (`pmNone` is ordinal **0** and the zero
  value — a bus-bar tick, a diagonal slash or a forked cap at a collapsed
  array's representative pin); `mark`/`tag` on `SchematicPin`; `count` (`>= 2`
  only on a representative — the drawn text is `label`, `"X1..X8"`) and
  `members` (the collapsed instance designators) on `SchematicPart`. See
  `arrays.nim`'s bullet and `docs/subsheet_arrays.md`. `wkPowerLink` is the
  newest appended `WireKind`: a ground/rail parallel-stack composite's
  internal fanout to its one shared glyph, drawn like `wkSignal` (a plain
  line, no glyph bars) — see the rail-decisions paragraph in the `layout.nim`
  bullet below.
  `SchematicDivider` (`y`, `x1`/`x2`, `label`) and `Schematic.dividers` are
  the newest additive fields: the separated power/decoupling band's dashed
  dividing rule (see the `power.nim` bullet below). Empty on every sheet with
  no power-classified unit — the same zero-value guarantee `fallbacks`/
  `ports` already carry — and it is not a `SchematicLabel`: the caption names
  the *divider*, not a part or a net, so it never enters the first-fit label
  pass `finish.nim` runs for everything else.
- **`layout.nim`** — compatibility façade and pipeline coordinator for `layout(nl: Netlist): Schematic`, pure and deterministic. Its internal implementation is split across `geometry.nim`, `symbols.nim`, `placement.nim`, `router.nim`, `routing.nim`, `labels.nim`, `finish.nim`, `diagnostics.nim`, and (see below) `composites/composite.nim`, `composites/passive.nim`, `constrained.nim` and `power.nim`; these are included implementation units so private layout state stays internal while the established `layout` API remains the import boundary. The include order is load-bearing: `composites/composite` and `composites/passive` sit after `placement.nim` (they use `rotationChoices`/`slotOf`/`rotatedSlot`/`axisUnit`/`pinWorldPositions`) and before `constrained.nim` (which pools placement over the arena they define), `power.nim` sits after `constrained.nim` (its `poolPower` calls `unitExternallyPurePower`) and before `state.nim` (`state.prepare` builds the plan, `state.nim` also carries the actual `enforcePowerBand`/`placePowerUnit` mover pass, mirroring `overrides.nim`/`enforceLayoutSides` — the plain-data classification lives with the plan, the `LayoutState`-mutating enforcement lives where `LayoutState` exists), and `state.nim`'s include must stay between `constrained.nim` (uses its procs) and `routing.nim` (defines `RoutingState`). `bundles.nim` (bus/interface grouping) is included after `./placement` and before `./composites/composite` — see its own bullet; `arrays.nim` (repeated-subsheet grouping) is included right after `./bundles` and reads its plan; the two rail predicates `isGroundHere`/`isRailHere` were hoisted to module level in `geometry.nim` (the first include) once `bundlePlan` became the third consumer, deleting the verbatim-duplicate local closures that had sat in `routing.nim` and `finish.nim`. The pipeline stage list gained `lsBundles` between `lsPrepare` and `lsSemanticSeed`, then `lsArrays` between `lsBundles` and `lsSemanticSeed` (both consumed inside `prepare`, `lsArrays` after `lsBundles`); off ⇒ a zero-value plan and the pre-feature scene, bit-for-bit. It later gained `lsPowerBand` between `lsPack` and `lsLayoutOverrides` (see the `power.nim` bullet below) — a `layout.side` column is a left/right band inside whichever y-half a part already landed in, so the power band must settle first. Private included `state.nim` holds `LayoutState`/`RoutingState`: component-symbol-position state and label-only routing metadata must never be added to public `Schematic`. `state.nim` also carries the placement-stage bodies (`prepare`, `forcePlace`, `snapToGrid`, `separate`, `enforcePowerBand`) and the thin `*(state: var LayoutState)` forwarders, so `layout` itself is just the ordered stage list. `finish.nim` consumes the completed scene plus that state while preserving label order and bounds behavior, and now also emits the power band's dashed divider (`finishDividers`, run **after** `finishBounds` since its extent is derived from the finished scene bounds). `LayoutOptions.policy` is a `LayoutPolicy` enum holding a single value, `lpConstrainedLayered`, kept as an enum rather than deleted so a future second policy has somewhere to land without every `options.policy == lpConstrainedLayered` call site changing shape; `defaultLayoutOptions` sets it, so it is both the only and the default policy for an ordinary `layout(nl)` call, not just for archive rendering. `parseLayoutPolicy` and `archiveLayoutOptions` centralize the CLI/environment spelling (`--schematic-layout`/`$VERAX_SCHEMATIC_LAYOUT`, only ever `constrained-layered`) used by archive writers — a no-op today, kept for the same future-second-policy reason. `lsSemanticSeed` (after the deterministic golden-angle seed), `lsConstrainedRefinement` (after force placement and before existing legalization) and `lsCompositeOrient` (right after refinement, before separation — picks each orientable composite's rigid `unitRot`, see the `composites/` bullet) carry the constrained pipeline's bounded deterministic meaning; it uses the existing bounded routing recovery as `lsRoutingAwareRepair`. It is for ordinary sheets (at most 64 *placement units*, and at most 256 raw parts), not a general graph-drawing solver: output-pin arcs seed left-to-right columns, while bounded deterministic stage placement folds each semantic layer across at most three adjacent columns (grouping parallel flat two-terminal parts by the same unordered net pair) rather than making a passive-heavy layer arbitrarily vertical; a same-component return has the adjacent-stage freedom on either side of its source, not an output-side-only rule. A bounded semantic walk follows every flat device with exactly two connected terminals (regardless of kind) until an input endpoint, stopping at rails, ground, hierarchy and inputs. It uses the existing `portDirection(net) == pdInput` result, including its no-driver fallback, for input interfaces. A traversal step is keyed on `(pool item, exit net)`, not the pool item alone: a recognized composite is one *placement unit* but its members are still distinct signal edges, so a pi's grounded shunt must not consume the pool position its series member needs to be walked through (the bug that put `RIAA_CHANNEL`'s `RL`–`CIN`–`RB` pi right of the op-amp it feeds). Both members of a parallel pair share both nets, so from either they yield the same `(pool, exit)` step and still collapse to one; `seen` stays raw so path length is bounded by the raw part count. A same-component return keeps its traversed parts in the source column; a genuine return to an earlier component keeps its path passives right of the driving output. Insertion order otherwise breaks feedback arcs, and existing legalization remains authoritative for non-overlap. Its signal trees are atomic trunk-and-tap attempts: a failed net restores occupancy and becomes marker-only fallbacks. Do not attach heuristics, reorder existing passes, or reinterpret terminal/recovery safeguards.
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
  snap both survive it. After the definitive rotation pass, a bounded
  deterministic
  **terminal-clearance repair** reserves each prospective full 40-unit
  ground/supply glyph against foreign signal escape corridors,
  routing-inflated foreign bodies and different-net terminal glyphs. Exact
  connected terminal-pin coincidences on distinct nets are a hard condition
  (same-net coincidences remain valid): it reduces those before ordinary glyph
  conflicts, and the small-sheet glyph shortcut cannot bypass them. It tries
  implicated small passive parts first; a power-directed part with exactly
  one real signal net is `protectedLeaf` and keeps its placement when another
  part can move instead. Routing-time glyph blockers
  and stem shortening
  remain the safeguard for irreducible crowding. Routing is per signal net: a tree grows
  from the first pin, each next pin attaching to the closest already-wired
  point through a Hanan free-space grid built from the inflated obstacle
  boundaries and signal-terminal escape coordinates, so an off-centre pin can
  turn directly after its outward stub while no segment enters an inflated body; a wire
  reaches each pin directly through a short outward stub. `buildFreeGrid` also
  adds a `freeGridMargin` (5) `grid`-step ring of axes just outside the extreme
  obstacle/terminal coordinates on every side: without it the grid stops
  exactly at the outermost obstacle edge or rail/ground glyph bar, so a route
  that must wrap a part -- a pass-through strap wired to ports on *both* sides
  (`SPI_DEV`'s `sclk`/`cs`) -- has no track to turn on past the glyph blocking
  the centreline, and the net needlessly falls back. The path search is
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
  (`svg.nim`) is drawn perpendicular to whatever direction the stub took. A
  parallel-stack composite whose shared net pair is a rail/ground pair (a
  decoupling bank) draws only **one** glyph, at its representative member's
  pin; every other member's own pin is joined to it by
  `compositeInternalRoutes`' ordinary trunk-and-tap fanout (the same hook a
  genuine signal net's internal route uses), re-tagged `wkPowerLink` rather
  than `wkGround`/`wkSupply` -- neither endpoint of that fanout is a glyph
  location, so drawing it as ground/supply would put a second, misplaced bar
  at the shared member's bare pin and reserve a bogus glyph footprint there;
  tagging it plain `wkSignal` was tried first and rejected too, since it made
  the fanout indistinguishable from the router mistakenly building a real
  route for the ground/rail net, which is exactly what "ground/rail nets are
  never routed as a tree" exists to catch. Junction dots
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
  After each move the eligible rotations are recomputed (`constrainedRecomputeRotations`,
  the same definitive pass used after separation). Attempt-zero layouts are untouched: a netlist that already routes
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
  body (no source-type polarity marker). An `opamp`/`op_amp`/
  `operational_amplifier` component with exactly the five pins
  `IN+`/`IN-`/`OUT`/`V+`/`V-` draws as the traditional triangular symbol
  instead (`source4`'s `byName` pattern again — a mismatched pin set falls
  back to the box): `IN+`/`IN-` land on the flat base, `OUT` at the apex,
  `V+`/`V-` lead in from mid-width on the slanted top/bottom edges. Like
  `source4` it is `byName`-keyed with `slots` empty, so `rotatable` is false
  and it never turns. Determinism is a property worth
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
  port's `y` by a **wire-tension relaxation** of its column: every port is
  pulled toward its net's anchor-pin `y` (`portSpringRate` per sweep,
  `portSpringIters` sweeps) while a symmetric min-gap projection keeps
  `portMinGap` (`1 * grid`) between bodies, so a jammed column settles centred
  on the mean of its targets instead of cascading downward from the topmost pin
  (the old greedy `yCursor` stack). A column with room to spare leaves every
  port exactly on its target, so a sheet with no port collision is unchanged.
  That pre-route target is only a guess (no wire exists yet), so a **post-route
  pass** follows: `refinePortPlacement` (`refinement.nim`, stage `lsPortRefine`,
  after `lsRoutingAwareRepair`, on by default). For each ported net it reads the
  `y` its routed wire spends the most horizontal length on, sets **every** port
  on that net to that `y` through `LayoutState.portY` (an override the column
  relaxation reads as its spring target, so `portMinGap` still holds), and
  re-routes. A candidate commits only when the fresh scene scores strictly
  better — fewer fallbacks, then fewer `wireBends`, then less total length
  (`betterThan`) — so it can never worsen a sheet. Bounded by
  `portRefineRounds` sweeps and `portRefineMaxAttempts` re-routes, and gated off
  above `4 * feedbackMaxParts` raw parts like `recoverRouting`. This is what
  straightens `SPI_DEV`'s `sclk`/`cs` strap climb-outs (the pre-route
  relaxation is a no-op there). Column and `x` are never touched by either
  pass. `docs/port_placement.md` has the method survey and why the old
  `lpHistorical` policy stopped holding port coordinates byte-identical. The port body is a routing
  obstacle and its
  connection point is fed to `routeNet` as an extra net pin with an explicit
  inward escape, so the connecting wire is a normal net branch that never
  crosses a body; the plain text label for a ported net is suppressed.
  A **pass-through strap** — one internal net published under two plain port
  names, `<x>_in` and `<x>_out` (`designs/lib/spi_dev.nim`) — keeps both
  pennants but is oriented by the `_in` / `_out` suffix (`portDirection` sees
  one internal pin and calls both inputs). `strapNets` (a `CountTable` over the
  plain ported nets) is the test; `portConn` is a `seq` per net so both
  pennants route. A **published** net that will not route degrades to a
  by-name `fbNetLabel` (teal), not an amber `fbUnrouted` marker — the port
  pennant already says where it goes. Interface / bus ports never count —
  `bundles.byPort` owns them.
  One trap this pass has to handle: rendering a subcircuit **instance's
  cloned child** directly (what `verify`'s per-subckt sheets do) means its
  shared global net `"0"` carries pins from every sibling clone, and siblings
  reuse designators — so pins are filtered by owning-`Netlist` identity, not by
  name, everywhere `layout` walks `net.pins`. The dual of that filter is
  `onThisSheet` (`composites/composite.nim`): a **global** net (`"0"`, any
  `global = true` rail) stays a single object whose `.netlist` is the root, so
  a bare `net.netlist == nl` test wrongly rejects this sheet's own
  ground-connected two-terminal parts — `isTwoTerminal` (and the widened
  `isTraversable` built on it), plus `pathsFrom`'s own check, all accept a
  net that is either owned by `nl` *or* the identical object `nl.nets` holds
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
  is there. `diagnoseFallbackNet` **refuses** to diagnose a net whose every
  record is `fbNetLabel` (a deliberate bus/interface name tag): the scene
  reserved no channel for it, so "blocked by occupancy" would be a false
  alarm — it returns `deliberate = true, routed = true, failPin = -1`.
  `diagnoseAllFallbacks` **skips** those nets entirely (fifteen tags on a
  three-interface sheet would bury the one real failure). This works off the
  scene alone, which is why `SchematicFallback.kind` is serialized.
- **`bundles.nim`** — the bus/interface grouping index, an `include`d unit
  spliced **after `./placement`** (for `pinKey`/`portDirection`) and **before
  `./composites/composite`** (so `compositePlan` can exclude a bundled part).
  Buses and declared interfaces are *views* over scalar net `attrs`
  (`netlist/interfaces.nim`): `bundlePlan(nl)` is one read-only pass over
  `nl.nets` reading `bus.name`/`iface.instance` and friends **directly**.
  * **`findBus`/`findInterface`/`interfacesOf` are forbidden here.** They
    rescan every net; `findInterface` raises unless the `InterfaceDef` was
    registered *in this process*; and `busOf` — which `addInterfaceRecovery`
    calls — **writes** `bus.index` from table order. Layout must stay
    read-only, the pattern `analysis/io_check.nim:74-79` and
    `contract/design.nim:279` already use.
  * **Net attrs only, never a pin attr.** `promotePortDirections`
    (`interfaces.nim:223-238`) copies every `iface.*` key onto instance
    *pins* preferring the parent net's identity, so a pin-attr read would
    drag an `iface.nc` open net (`nc_X1_spi_miso`, which carries no
    `iface.instance` on the *net*) into the bundle it was explicitly left out
    of. Net-attr-only keeps a no-connect out by construction.
  * **Eligibility.** Group in `nl.nets` order: `iface.instance` wins, else
    `bus.name`. Reject a candidate with `< 2` member nets (discarded — its
    net routes as an ordinary scalar, keeping only its `ofNet` colour), or
    any member for which `isGroundHere`/`isRailHere` (a rail member declines
    the **whole** bundle). A non-box carrier blocks **collapse only**, not
    net-label degradation. A candidate whose members *uniformly* touch
    two or more endpoint entities (a component, or the sheet boundary —
    `bePort`, one entity however many `nl.ports` keys) → **`brCollapsed`**:
    one merged pin per entity, one thick coloured bus tree between them.
    **There is no entity cap** — uniformity is the whole test, so a bus
    fanning to any number of identically-touched boxes collapses rather than
    degrading past three (`designs/xbar_rf.nim`'s `m` bus: uniform across all
    eight `rf_switch` instances). Otherwise, if the candidate is **published
    or its members span 3+ component entities** (`union.parts` counts
    components, never the sheet boundary) → **`brNetLabel`**: grouped
    net-label tags, no wires — one merged tag per box endpoint carrying
    `>= 2` members (`spi1`, or `spi1(cs0)` for a coherent slice, `groupText`),
    a bare member tag on every other endpoint. A `>= 3`-entity interface
    takes this branch directly and **no longer retries per `bus.name`** (so
    it never gets a collapsed sub-bus); the retry survives only for the
    `< 3`-entity, non-ported, non-uniform leftover, where a narrower sub-bus
    can still be uniform even though the whole interface was not. A
    remaining failure stays **`brScalar`**: ordinary wires, recoloured. The
    whole-bundle rail decline and the `< 2` floor still keep a genuinely
    two-entity bus free to collapse; `designs/i2c_eeprom.nim`'s sda/scl
    now draw as grouped `i2c` tags (4 entities, non-uniform), and its
    readiness report is unchanged because the `i2c` role reads the netlist,
    not the picture.
  * **The plan is a function of the netlist alone.** Which nets group, and
    how, depends only on `attrs`, `nl.ports` identity and the pin graph, none
    of which a `recoverRouting` candidate move touches — so recovery moves
    never rebuild it. `prepare` computes it once, gated on `lsBundles`,
    **before `state.syms` is sized**: a merged pin takes `SPI_MEMORY`'s `U1`
    from `rows = 5` (`bodyH` 272) to `rows = 3` (`bodyH` 192), so the box
    sizing depends on the plan.
  * **`Bundle.display` is the occupancy tag.** `SchematicWire.net`,
    `SchematicPort.net`, the merged `SchematicPin.net` and
    `diagnostics.sceneRouterInputs` all key on it, so `bundlePlan`
    disambiguates it against every `nl.nets` key (append `"_iface"`/`"_bus"`,
    then `"_2"`…) — two scene entities silently sharing one tag is an
    invisible failure.
  * **The escape-seed dedupe trap** (in the voice of the sibling-clone
    `ownsPin` trap): `routing.nim` seeds one escape stub per pin of every
    non-rail net, tagged with *that net's* name. With merged slots,
    `spi_sclk`/`spi_mosi`/`spi_miso` all seed the *identical* segment at the
    merged point under three tags — and the bundle's own route then sees
    three **foreign** seeds lying exactly along its own first hop, which
    `edgeAllowed` forbids, so **the bundle can never route**. Same at the
    merged port. Fix: a collapsed pin/port is seeded **once**, tagged
    `b.display`, guarded by a `seededBundle` set.
  * **`boxSlots`/`symbolFor` take plain-data partitions**, not the plan
    object — `symbols.nim` is spliced long before `bundles.nim`. `groupOf`
    (parallel to `c.pins`), `groupNames`, `groupSide`; a merged group is one
    lane holding one shared slot `Point`, so `slotOf`/`pinWorldPositions`/
    `rotationScore`/`terminalClearance` are untouched. **`groupOf.len == 0`
    is the historical path, bit-for-bit** — that one default is the whole
    inertness guarantee at this layer. A merged net-label group resizes its
    box exactly as a collapsed one does (`byPin`/`bundled` cover both).
  * **`laneOf` is the one source of a merged lane's string.** Both
    `bundleGroupsFor` (box sizing) and `routing.nim`'s part loop (the merged
    `SchematicPin.name`/`.members`) route through it: a collapsed bundle
    gives `(b.pinName, b.sceneMembers)` unchanged, a merged `LabelGroup` its
    own `(text, members)`. Sizing `innerW` for `spi1(cs0)` while `svg` prints
    `spi1[5]` is the divergence this prevents. `SchematicPin.net` stays
    `b.display`, never the group text — `diagnostics.sceneRouterInputs` would
    re-seed an escape stub under a tag routing never used.
  * **The zero-value invariant.** A netlist with no `bus.*`/`iface.*` net
    attr yields a zero-value `BundlePlan`, and every new downstream path
    (`wireKindFor`, the collapsed/net-label branches in `routing.nim`, the
    merged `PortPlan`, `finish`'s `bundleNets`/`bundleLabelReqs`) is guarded
    on a non-empty plan ⇒ byte-identical historical output.
  * Public `bundleReport(nl)` sits beside `diagnoseFallbackNet`: "does
    `spi1_cs` collapse?" is a one-line unit test rather than an inference
    from geometry. Its `labels` field renders each `brNetLabel` group's
    merged tag (`"U1=spi1"` / `"X1=spi1(cs0)"` / `"R1="` for an unmerged
    carrier), so `groupText` is testable without laying anything out.
- **`arrays.nim`** — the repeated-**part** grouping index (subsheet instances
  and, since component grouping, raw components too), `include`d **after
  `./bundles`** (it reads `BundlePlan`/`BundleRole`, `pinKey`, `portDirection`,
  `isGroundHere`/`isRailHere`) and **before `./composites/composite`** (the
  arena is built over the already-filtered `state.comps`, and a collapsed
  array's representative is now also excluded from `compositePlan`'s arena —
  see the composites bullet). Spliced after `symbols.nim`, so every hand-off
  is plain data, the `bundleGroupsFor`/`laneOf` pattern. Full design note:
  `docs/subsheet_arrays.md`.
  * Two passes share one `ArrayPlan`, built by `state.prepare` under two
    stages (`lsArrays`, `lsPartArrays`, in that order): `buildSubsheetArrays`
    groups `Component`s that instantiate one subcircuit (`subNetlist.name` +
    the pin-key sequence — `graph.instantiate` fixes both); `buildComponentArrays`
    groups raw components (`subNetlist == nil`) sharing
    `kind \x1f value \x1f partNumber \x1f name \x1f <pin names> \x1f <pin kinds>`
    — **`value` is in the key deliberately** (a 10k and a 2k bank must never
    merge), and a component stating **neither** a value nor a `partNumber`
    excludes it from candidacy outright, checked before the key is built: the
    collapsed symbol shows one value, and a blank one asserts nothing about
    the N real parts it stands for. `xbar_rf`'s termination resistors state
    `value`; its SMA connectors and ADG904 switches carry no `value` at all
    but state `partNumber` — identified by what they *are* rather than what
    they measure, just as real an identity (this is also what keeps this
    codebase's own topology-only test fixtures — a resistor chain or star
    built to exercise placement/routing, stating neither because none of them
    are testing this feature — from silently qualifying the moment three of
    them share two empty strings).
    Both passes call the identical `classifyGroup`/`addSignatureArrays` body;
    what differs is candidacy and one extra veto for a component group (**the
    all-common decline**: a candidate must have at least one port classified
    `apDistributed`, or every port must be `apCommon` **and** `ArrayPort
    .railCommon` — the **bypass-bank floor** below — or it is dropped).
    `xbar_rf`'s eight `CBY*` decoupling caps are all `apCommon` **and**
    `railCommon` on `(v3v3rf, gnd)`, which the bypass-bank floor now lets
    through: a genuine rail/ground bank collapses to one badged symbol
    instead of `composites/passive.parallelStackKind`'s eight visible
    bodies. **A component group whose all-common ports are *not* a
    rail/ground pair still declines** (a signal-net parallel bank keeps its
    visible stack — the original reason for the decline). **The floor
    itself is three-tier**: a subsheet array, or a component array with no
    `apDistributed` port and no `railCommon` bank, still needs three or
    more members (the historical floor — two same-signature parts wired
    into *unrelated* roles, an ordinary divider's same-valued resistors,
    must not silently merge just because their value matches); a component
    array every one of whose ports is `apCommon` **and** `railCommon`
    collapses at **two** — that is unambiguously one repeated thing wired
    the identical way, never a coincidence; so does a component array of
    exactly two with an `apDistributed` port that is `ArrayPort
    .mergedByBundle` — its varying nets are members of one *declared* bus
    or interface, the identical evidence the bypass-bank floor reads off
    ground/rail identity instead, just carried by `iface`/`bus` — which is
    what lets `designs/usb_hs_link.nim`'s `R1`/`R2` (22R termination) and
    `D1`/`D2` (ESD clamps), each pair's far pin bound to the same
    `diff_pair` interface instance, collapse to one `x2` box apiece instead
    of drawing as four unrelated symbols; the port on the *other* side of
    each (the choke/connector-side pin, bound to plain nets with no
    declared bus behind them) still draws honestly as a `[1:2]` tag on the
    collapsed box — one declared-and-merged port vouches for the whole
    pairing, not every port needing its own proof. **Chain
    pairing is skipped for a non-box representative** (`symbolFor(rep).isBox`)
    — the recirculation arc is a fixed staple on the *box interior*, which a
    resistor symbol has none of, so a would-be chain degrades to
    *distributed* instead, the honest drawing. A **no-op pass** (no ≥3-instance
    subsheet, no ≥3-member raw-component signature, and no ≥2-member
    rail/ground bank) is the byte-identity guarantee, same as before. `prepare` drops the N−1 non-representative
    members of each collapsed array from `state.comps` **before `syms` is
    sized**; the filter is the sibling-clone shape
    (`pinPos.hasKey && partIdxByDesig.hasKey`, `ownsPin`) every layout site
    already tolerates, so `groupOf.len == 0`-style inertness is not needed —
    an empty `hidden` set makes the comps loop verbatim.
  * **A net distributed at both ends** (`8x(R+C)`: every `mid_i` sits on the R
    array's port 2 *and* the C array's port 1) is the one genuinely new
    failure mode component grouping introduces: writing `suppressed`
    per-array, as the subsheet-only pass safely could (a net was never
    claimed twice there), lets the two arrays — enumerating members in
    independent `nl.components` orders — suppress
    overlapping-but-different subsets of the shared nets, in the worst case
    suppressing every one, so the bus never routes; the totality assertion
    does not catch it, since every net is still accounted for (just
    unroutable). Fixed by `finalizeArrayPlan`, run exactly **once** after
    whichever of the two builders ran: it derives `suppressed` from the
    *final* `groupOf`, bucketing nets by `(array, port)` and keeping the one
    that comes first in `nl.nets` order, well-defined regardless of which
    array ends up owning the group. `arrayRouteFor`'s `first` is then simply
    `true` whenever a net survives the `suppressed` check — no comparison
    against the port's own member-order `nets[0]`, which need not agree with
    the `nl.nets`-order pick once two arrays enumerate the same members
    differently.
  * **A split visible only through bus/interface membership.**
    `subGroupsOf`'s partition key (`splitKeyOf`) reads `iface.instance` then
    `bus.name` off each bound net before falling back to the net's own
    name — a distributed port's members are N *distinct* nets by
    definition, so raw-identity counting can never see a split that exists
    only because those nets are declared members of two different buses:
    `xbar_rf`'s eight `rf_switch` instances bind `RFC` to `rin[0..3]` on
    four of them and `rout[0..3]` on the other four, sharing no net at all,
    and now draw as two `x4` groups (input/output) instead of one
    nonsensical `x8`; the same fix also splits its `JIN*`/`JOUT*` SMA
    connectors, and splits its 24 address/enable pulldowns into an `en` `x8`
    and an `a` `x16`. Precedence (`iface.instance` before `bus.name`) matches
    `bundles.nim`'s own: the bare signal name is identical across every
    instance of a declared interface, so keying on it first would fold every
    instance's same-named signal into one family and undo `spi_memories`'s
    three-way split. The same family name is what a *bundled*, still
    bundle-merged distributed pin draws once collapsed (`ArrayPort.bundleFamily`,
    set at classification time from the first bound member) — `xbar_rf`'s
    `a` bus, where the representative's own raw binding is one specific pair
    (`a_0_0`/`a_0_1`) but the collapsed box stands for every hidden member's
    binding on that bus, so `arrayPinFor` fills the pin's `net` with the bus
    name ("a") instead, and `routing.nim`'s net-label pass
    (`arrayBundleLabelFor`) substitutes it for the one visible tag a
    representative would otherwise draw under its own pre-collapse index.
    `rin`/`rout`/`en` never merge anywhere on their bundle, so they no longer
    take this path at all — the array draws and routes them directly, under
    the bundle's own tag reused verbatim (see the collapsed-array precedence
    bullet above). Every other, non-representative carrier keeps its own
    precise tag
    unchanged.
  * **`pmBusBar` on a glyph-drawing pin.** An `apCommon` port whose net is
    ground or a rail already draws its own terminal glyph there — the tick is
    merely redundant on a box but collides outright on a two-terminal symbol.
    `ArrayPort.railCommon`, set at classification time for both passes,
    suppresses the mark in `arrayPinFor`. Deliberately a visual change to
    `spi_daisy_chain`/`spi_memories` too (their `vdd`/`gnd` ticks disappear);
    the `chainSheet()` test fixture gained a common **signal** port so the
    mark keeps real test coverage.
  * **Totality is an invariant, not a hope.** Every distinct net named by a
    hidden member's pin must be suppressed, in `groupOf`, still on the
    representative's own pin, on an irregular port, or owned by a bundle — a
    `doAssert` inside `finalizeArrayPlan`, run over the complete plan (both
    passes' arrays) rather than per-pass. A net every pin of which sits on a
    hidden member and is in none of these disappears with no marker
    (`routing.nim` only marks a single-pin net), which is a path-integrity
    bug, hence an assertion.
  * **Four port classes.** *common* (one shared net → one wire + a bus-bar
    tick), *distributed* (N distinct nets → one `wkBus` wire, `[1:N]` tag),
    *chained* (`out(i) == in(i+1)`, linear and complete → a recirculation
    arc), *irregular* (a forked-cap glyph + `n·m` count, click-to-expand).
    Rail/ground ports are out of the vote; `N < 3` never collapses, except
    the bypass-bank floor above, which admits `N == 2` for a group every
    port of which is `apCommon` and railed; a
    non-linear or branched chain degrades to *distributed*.
  * **Sub-grouping** splits an array by every *splitting* port (its nets
    partition the members into ≥2 groups of ≥2, none open) before
    classifying, so `spi_memories`'s nine memories draw as three `x3` boxes.
  * **The collapsed-bundle decline is a placeable-endpoint count, not a
    blanket veto** (`survivesCollapsedBundles`): a `brCollapsed` bundle is a
    bus tree between its endpoint entities, so a candidate group is declined
    only when hiding its own non-representative members would leave that
    bundle with **fewer than two** entities still placeable — evaluated per
    sub-group against `plan.hidden` union the candidate's own hidden set, not
    "any member touches some collapsed bundle" (the old rule, which would
    have wrongly declined `xbar_rf`'s two `rf_switch x4` groups once `m`
    collapses across all eight switches: each group hides only three of the
    other seven, leaving five, then two, still on the bus). A `brNetLabel`/
    `brScalar` bundle keeps its own drawing and that port reads `bundled`
    regardless.
  * **Bundle-wins-at-the-pin only where the bundle actually merges one**
    (`ArrayPort.mergedByBundle`): a `brCollapsed` bundle, a `brNetLabel`
    `LabelGroup` folding `>= 2` owned members onto one carrier (`xbar_rf`'s
    `a` bus: `A0`+`A1` both land on one switch), or a bundle that merges a
    pin *anywhere on it at all* (a mixed bundle — merged on one carrier, not
    on another sharing the same members, has no single occupancy tag left
    for a bus tree to reuse coherently, so every carrier defers). A `bundled`
    port that is **never** merged anywhere on its bundle (one member per
    carrier throughout — `xbar_rf`'s `rin`/`rout`/`en`) is drawn **and
    routed** by the array instead: `classifyGroup` reuses the *bundle's own*
    `Bundle.display` (never a freshly allocated tag) as `ArrayPort.display`,
    so the array's real wire, the port pennant `bundles.byPort` already
    folds, and — when the same bus is distributed across more than one array
    (`rin`: a `connector x4` on one end, an `rf_switch x4` on the other) —
    the *other* array's own route all agree on one wire under one name with
    no cross-array coordination: whichever array's `plan.groupOf` write lands
    last is the one `arrayRouteFor` honours, and every competing array's own
    `display` is identical anyway. `routing.nim`'s net-label pass steps aside
    per carrier it no longer owns (`arrayOwnsDistributedPin`, and — for a
    carrier whose *own* representative is not itself an array member, e.g. a
    merged far-side box — a direct `arrays.groupOf` check on that carrier's
    own underlying net) and, once its triggering "first" member is
    array-owned, falls through into the ordinary route below instead of
    `continue`ing, so the same net iteration draws the array's real wire
    rather than a competing net-label tag. This is what actually routes
    `xbar_rf`'s `m`/`rin`/`rout` as real bus trees between its collapsed
    arrays; `en` reaches the same code path but its own placement happens
    not to route (the existing graceful "array bus that will not route"
    fallback still applies, converting the attempt back to net-label tags
    rather than a dashed failure).
  * **The escape-seed dedupe** is keyed on the **point**, not the part
    (unlike `seededBundle`): a distributed group's endpoints sit at
    *different* points on a foreign part (eight CS pins on an MCU), each
    needing its own seed.
  * **The port-folding trap**: a distributed member net that is also an
    `nl.ports` key folds to one pennant, first-wins with in-place `prefY`
    refinement, a mirror of `planForBundle`. Without it a member net whose
    only on-sheet owner is hidden finds no placed pin and the port silently
    disappears.
  * **Each chained pair gets its own recirculation arc** — a dashed
    annotation, a **fixed polyline** drawn as a tight staple on the box
    interior between that pair's IN and OUT pins (same row by construction).
    It never leaves the box, so it cannot conflict with the sheet or the
    box-top title; `svg` draws it dashed + arrowhead into the IN pin. It is
    never an `nl.nets` entry and is **exempt** from the routed-wire collinear /
    separation invariants (`distinctWiresNeverShareCollinearRuns` /
    `differentNetsRespectSeparation` skip `wkChain`). A parallel-chain group
    (`chainKey`) draws one arc per pair, stacked; only the lead carries the
    `xN` link-count badge (`SchematicWire.members` empty on the others). No aux
    lane, box keeps its historical size.
  * **The zero-value invariant.** No ≥3-instance subsheet ⇒ a zero-value
    `ArrayPlan` ⇒ byte-identical historical output; every downstream path
    (`prepare`'s filter, `symbols`' extra lanes, `routing`'s
    skip/group/arc branches, `finish`'s `arrayNets`) is guarded on it.
  * Public `arrayReport*(nl)` beside `bundleReport`, covering both passes:
    `source` (the subckt name or the component `kind`) and `origin`
    (`"subsheet"` / `"component"`) tell a subsheet array from a component one;
    `ports` renders `"vdd=common"`, `"sclk_out=chained(out,x7)"`,
    `"wp=distributed[1:6]"`, `"nc=irregular(2*6,open=4)"` regardless of which
    built the array.
- **`composites/composite.nim`**, **`composites/passive.nim`**,
  **`composites/pi.nim`** and **`composites/tee.nim`** — the composite arena
  `constrained.nim` pools placement over, and the four motifs registered into
  it. `state.nim`'s `planComposites` excludes every bundled part *and* every
  collapsed array's representative from `compositePlan`'s arena before it
  ever recognizes a motif. The bundle case was free (a bundle carrier is
  always a box, `isTwoTerminal` wants `subNetlist == nil`, so it could never
  have been eligible); a **component** array's representative is not — it is
  a flat two-terminal part still fully visible, exactly what
  `parallelStackKind`/`seriesChainKind`/pi/tee look for — so without the
  exclusion a termination resistor badged `x8` could be claimed as a member
  of a composite it does not belong to, and that composite's internal fanout
  would run to a symbol standing for eight different physical resistors, not
  one. **`composite.nim` also splits `isTwoTerminal` from a widened
  `isTraversable`**, for `netlist/traversal`'s `traverse:` block: every
  `recognize` hook here (`parallel`/`pi`/`tee`/`series`) keeps calling
  `isTwoTerminal` -- today's exactly-two-connected-pins test, verbatim --
  because each assumes a *unique* other net via `twoTermOtherNet`, which a
  declared multi-exit part (an 8-pin RF switch stating which `RFn` its
  `RFC` reaches) would break, and `isPassiveElement` filters only sources,
  not boxes, so nothing else would stop `pi`/`tee` from swallowing one.
  `isTraversable` widens that to "`isTwoTerminal`, or a declared spec with
  at least one conducting edge reachable from a net this sheet draws" and
  has exactly one caller, `constrained.pathsFrom`'s own semantic walk, whose
  single-exit hop (`twoTermOtherNet`) becomes a loop over
  `traversalExits(c, nl, fromNet): seq[Net]` — declared edges from whichever
  pin sits on `fromNet` when `c` states a spec, otherwise the same single
  `twoTermOtherNet` answer wrapped in a one-element `seq`. `composite.nim` is
  kind-agnostic: `CompositePort`,
  `PlaceableItem`, `CompositePlan` (the arena: `items`, the leaf/composite
  entries; `topLevel`, the arena indices placement actually sees, singletons
  and top-level composites interleaved in ascending first-raw-member order;
  `ownerOf`/`poolOf`, raw index to owning arena index / pool position), and
  the `CompositeKind` contract — seven `{.nimcall.}` hooks
  (`recognize`/`internalLayout`/`externalPins`/`pickRepresentative`/
  `internalRoute`/`rotationCandidates`/`footprint`) plus an `orientable` flag,
  a motif implements over
  the arrays `LayoutState` already threads, so a recognizer needs no access to
  placement/routing internals. **`internalLayout` authors one *canonical*
  frame** (the horizontal row / vertical stack the motifs below describe);
  `canonicalOffsets` returns it untouched and `rawOffsets` returns it turned
  by `PlaceableItem.unitRot`, a rigid 0/90/180/270 quarter-turn the
  `lsCompositeOrient` stage picks (and the definitive orient pass revisits via
  `revisitCompositeFrames`) for an `orientable` kind — the parallel stack and
  the series chain, whose canonical horizontal frame is arbitrary. The pi and
  the tee are **not** orientable: their shunt legs run to ground and
  ground-points-down is a real convention, so `unitRot` stays 0 and their
  output is byte-identical. `lsCompositeOrient` scores a trial frame by turning
  the *whole* unit (so internal pin distances stay fixed and only the reach to
  external net-mates counts): a unit whose every external net is a rail/ground
  (`unitExternallyPurePower` — a divider between planes, a decoupling bank) is
  ranked by `powerRank` then `rotationScore`; a unit with an external signal
  net by `rotationScore` alone (smaller angle breaks ties), so it turns only
  to shorten a real connection, not to point a lone ground leg down. It runs
  *before* `separate`/`pack` so a turned unit is legalized like any other, and
  `revisitCompositeFrames` re-scores by `constrainedRouteScore` once centres
  are settled, rejecting any frame whose turned bodies would overlap a foreign
  part. Both stages leave geometry untouched when the chosen frame equals the
  current one, and both are skipped on a sheet `constrainedEligible` declined.
  `recoverRouting` respects the committed `unitRot` (angles compose through
  `constrainedRecomputeRotations`) but deliberately does not re-search it per
  candidate. See `docs/composite_placement_stage2.md` §2.7. `footprint` is routing-only: `boundingBoxFootprint`
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
  `passive.nim` holds two motifs. `parallelStackKind`: parallel flat
  two-terminal parts sharing an unordered net pair become one placement unit,
  keyed by that unordered net pair so declaration and pin order cannot split
  the group (`parallelRecognize`). Canonical frame: members stacked along y,
  pin axis horizontal; `orientable`, so `lsCompositeOrient` may turn the stack
  to run along x instead. `parallelInternalRoute` reads the stacking axis from
  the covered-pin spread rather than assuming vertical. `seriesChainKind` (`docs/composites.md`
  idea 1, the complementary case — chained, not paralleled): flat two-terminal
  passive parts wired end to end through **link nets** become one horizontal
  row. A link net has exactly two pins in total, both on distinct *usable*
  members (`isTwoTerminal` **and** `isPassiveElement` **and** not a fallback
  box — an MCU with two nets wired is two-terminal but has no place in a
  passive row, and nor, now, would a declared multi-exit switch that the
  widened `isTraversable` alone would also have passed), and is neither
  ground, nor a rail, nor a declared `nl.ports` interface
  (a port must stay an external routable endpoint). Link nets give every usable
  part degree ≤ 2, so the link graph is paths and cycles; a cycle cannot be a
  horizontal row, so it is declined outright rather than cut at an arbitrary
  edge. There is no length cap. `seriesExternalPins` emits one `CompositePort`
  per link net (the two free chain ends get none — a single interior pin each,
  and a ground/rail end still draws its own glyph), so every link net is a
  `routing.fullyInternalComposite` and `compositeInternalRoutes` owns its
  wiring, exactly as the tee's mid node. Canonical *frame*: every member
  horizontal, one `2 * grid` gutter between bodies (an even pitch, so the
  grid-rounded centres stay symmetric), head-side net on the −x pin —
  `lsCompositeOrient` then turns the whole row through 0/90/180/270 (it is an
  `orientable` kind), so a chain between an upper and a lower endpoint draws as
  a vertical column. It does
  **not** compose with the parallel stack yet: a chain member is always a raw
  singleton, so a series-of-parallel-pairs needs the arena-index nesting fold
  `compositePlan` does not do (`docs/composite_placement_stage2.md` §2.6).
  Registered last, so where a pi/tee series leg also reads as a chain link the
  canonical filter drawing wins and `compositePlan`'s all-or-nothing claim
  check drops the chain group.
  `pi.nim` and `tee.nim` hold the two passive
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
- **`power.nim`** — power/decoupling band classification: which placement
  units belong in the separated power section `state.enforcePowerBand`
  carves out below the signal circuit, and why. `include`d right after
  `./constrained` (needs `unitExternallyPurePower`, `CompositePlan`/
  `rawMembers`) and before `./state` — deliberately plain data throughout,
  the `overrides.nim`/`enforceLayoutSides` split: this file holds only
  `PowerClass` (`pcSignal`/`pcPower`), `PowerPlan` (`cls`, parallel to
  `CompositePlan.items`; `any`, true only when the sheet has *both* a
  signal- and a power-classified unit — an all-power or all-signal sheet
  has nothing to separate, the zero-value guarantee every consumer is
  gated on), `poolPower` and `powerPlan`; the actual `LayoutState`-mutating
  mover (`enforcePowerBand`/`placePowerUnit`) lives in `state.nim`, where
  `LayoutState` exists. Classification runs at the **placement-unit**
  level, exactly `poolSide`'s shape: an authored `layout.power` override
  (`netlist/layouthints`) wins first-wins across a unit's members; failing
  that, `unitExternallyPurePower` (`constrained.nim`) classifies the whole
  unit as power when every net linking it to the rest of the sheet is a
  rail or ground — a decoupling bank, a bulk cap, a ferrite bead or
  inductor between two rails, an LC/RC filter between planes, a
  rail-to-rail divider. A unit with any external signal net stays in the
  signal circuit unless overridden — an LDO with an enable or feedback pin
  is exactly this case. `rawPowerFlags(power, plan, n)` projects `cls`
  onto raw component indices — the plain-data escape hatch `arrays.nim`'s
  `extraMembers` documents for `groupsOf` — since `geometry.nim`'s
  `powerBandAllows` (beside `sideBandAllows`) and `placement
  .repairTerminalClearance`'s new `isPower`/`powerSplit` parameters are
  spliced in *before* this file even exists and so cannot reference
  `PowerPlan`/`PowerClass` directly; `powerBandAllows` therefore takes a
  bare `bool` rather than the enum, for the identical reason.
  `state.prepare` builds `state.power` right after `planComposites` —
  after composites exist, so a composite's members classify as one unit —
  gated on `lsPowerBand`: disabling the stage leaves `state.power` at its
  zero value regardless of what any component states, so a disabled stage
  cannot change `groupsOf`'s `noMerge` behaviour either (`placement
  .groupsOf` gained a `noMerge: seq[bool]` parameter, parallel to `comps`,
  that suppresses its small-group-folds-into-nearest-power-rail-net-mate
  merge for a root group every one of whose members is flagged — without
  it, packing glues a power unit back onto the IC the band pass is about
  to pull it away from). `state.enforcePowerBand` is `enforceLayoutSides`'
  pattern turned through 90 degrees: partition `placementPool` into
  signal/power units, shelf-pack the power units in a left-to-right band
  strictly below the signal units' bounding box (`placePowerUnit`, a
  `placeOverrideUnit` sibling — the same expanding-ring nearest-free-cell
  search, seeded so the unit's own inflated top-left corner lands near the
  shelf cursor, **rounded to the grid** before the ring search since the
  cursor is rect-boundary arithmetic that need not itself land on a grid
  step), and record the resulting `state.powerSplit` y boundary so
  `repairTerminalClearance`/`recoverRouting` (both gained the identical
  `isPower`/`powerSplit` band-holding parameters `layout.side`'s
  `leftSplit`/`rightSplit` already have) cannot pull a part back above it.
  Runs at stage `lsPowerBand`, between `lsPack` and `lsLayoutOverrides` —
  before the side-column enforcement, since a `layout.side` band is carved
  inside whichever y-half a part already landed in. `finish.finishDividers`
  (run after `finishBounds`, since the divider's `x1`/`x2` span the
  finished scene bounds) emits the `SchematicDivider` (see `scene.nim`'s
  bullet) `svg.nim` draws as a dashed rule with a "POWER" caption.
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
  after it, so they stay upright. `drawFallback` branches on `kind`:
  `fbUnrouted` is a dashed amber polyline capped with an open circle (an empty
  `points` draws only the marker); `fbNetLabel` is a **solid teal** stub
  capped with a **chevron** — a deliberate name tag, told apart from a routing
  failure by colour. `lineAt`/`polyAt` take optional `stroke`/`width`
  defaulting to today's `#333333`/`2` literals, so every existing call site
  emits the identical string; a `wkBus` wire is `#1f6feb`, a `wkInterface`
  wire `#8250df`, both stroke **4** when collapsed. **Stroke width is
  cosmetic** — 4 leaves 4 units of visible gap inside `wireMinSeparation`'s 8,
  so the router needs no per-net clearance; a per-net clearance is a separate
  change with its own invariant test, and going to stroke 6 (2 units of gap
  reads as touching) is the thing to resist without also raising
  `wireMinSeparation`, which would move every existing layout. `drawDivider`
  draws the power/decoupling band's dashed rule (`#999999`, `12 8`
  dasharray) plus its "POWER" caption, right after the grid and before any
  wire — so a wire or symbol's white fill always paints over it, never the
  reverse. **Painter order** is grid, dividers, wires, fallback
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
  **Bus/interface fields go in additively and `sceneSchemaVersion` stays 1.**
  `optArr` sits beside `optStr` (absent → empty array, type-checked when
  present); `wireKindName`/`FromName` gain `"bus"`/`"interface"` and
  `fallbackKindName`/`FromName` are new, both failing loudly on an unknown
  token like every other enum here. The writer emits `members` on
  wires/pins/ports and `kind`/`bundle` on fallbacks **only when non-default**,
  so a bus-free scene's JSON is byte-identical to a pre-feature archive and
  both still round-trip. `dividers` follows the identical discipline: the
  writer emits it **only when `Schematic.dividers` is non-empty**, and the
  reader goes through `optArr` (an empty array when the key is absent), so a
  pre-feature archive with no power-classified unit round-trips unchanged
  and a divider-free scene's JSON is byte-identical to before the feature.
- **`render.nim`** — the composition layer above `svg`/`json`: it drives
  `layout` over a whole design *and* its sub-circuits and writes the run
  archive. `writeScenePair(scene, base)` writes `base.svg` and `base.json`
  from one scene (both `spice/ngspice`'s `runNNN` and everything below use
  it, so the two files can never disagree about geometry). `keepFullSchematic(nl)`
  is the whole `$VERAX_KEEP_RUNS` job `verify` calls: `runFULL` for the root,
  `runFULL.<sheet-id>` per distinct child-sheet variant, and `runFULL.html`.
  Same-named child occurrences deduplicate only when their routed scenes and
  resolved direct descendant targets agree; otherwise IDs are deterministic
  and globally collision-safe: the legacy unsuffixed `safeSheetName(name)`,
  then `.2`, `.3`, etc. (including sanitization collisions). `safeSheetName`
  maps anything outside `[A-Za-z0-9._-]` to `_` so a `.SUBCKT` name is always
  a legal path fragment. Best-effort
  (a `CatchableError` is swallowed) and a no-op when the variable is unset —
  drawing a picture must never fail a check. It sits here rather than in
  `verify` because it needs only `netlist`, and lives *outside* `svg`/`json`
  because it is the one place that calls `layout` itself and walks hierarchy.
  **`runFULL.html`** is a self-contained hierarchy browser — no external file,
  opens straight from disk. `explorerSheet(n, scene, id)` folds one level into
  an `ExplorerSheet` (id, title, the inline SVG with its XML prolog stripped
  since `<?xml …?>` is invalid mid-document, and a JSON part list); a part
  whose designator keys `n.children` carries that occurrence's resolved
  archive sheet ID as its `child`, every other part `null`.
  `renderExplorerHtml(sheets)` inlines
  every sheet into one `const MODEL` blob in the `explorerTemplate` (the only
  place `$TITLE$`/`$MODEL$` are substituted; `</` in the JSON is escaped so it
  cannot close the `<script>`). The page overlays one transparent `<rect>` per
  part, positioned from the scene's `bodyW`/`bodyH` in the SVG's own
  world-unit `viewBox`: single-click opens a properties panel, double-click on
  a `child`-bearing part pushes its sheet, an *Up* button pops the breadcrumb
  history. The root sheet's id is the sentinel `@root`, which `safeSheetName`
  can never produce, so it never collides with a subcircuit's.
  A **merged bundle pin is click-to-expand**: `explorerSheet`'s per-pin
  projection carries `x`/`y`/`members`, and `render()` appends one
  `rect.bundle` hit box per pin with a non-empty `members` **after** every
  part rect (so a pin wins the hit test — SVG hit-tests topmost-first), whose
  click opens `showPinProps` rendering the member list as the same two-column
  Pin/Net table. No schema or `json.nim` change — the explorer model is built
  independently of `sceneToJson`. Two traps hold: nothing in the file may
  contain the literal `src=` (`test_verify_keep.nim` asserts it over the whole
  HTML), and `const MODEL = …;` must stay one line (the same test extracts it
  with `html.find(";\n", …)`).

**Dependency direction stays intact**: `schematic` imports only `netlist`, and
`spice/ngspice` imports `schematic` to archive each per-run scene as
`runNNN.svg`/`runNNN.json` while `verify` imports it and calls
`render.keepFullSchematic` to archive the authored design as
`runFULL.svg`/`runFULL.json`, one `runFULL.<sheet-id>` pair per distinct
rendered child-sheet variant, and `runFULL.html` — both consumers sit above it on
the existing spine, never across or up it.
