# `schematic` submodule

Turns a `Netlist` into a renderer-neutral **scene**, written as self-contained SVG and JSON. Depends **only on `netlist`**. A visualizer, not an EDA tool: heuristic placement, no DRC, no round trip; the bar is "readable enough to eyeball" (`docs/netlist-converter-research.md`). Consumers above it: `run_archive` (per-run `runNNN.svg/.json`, installed into `spice/ngspice`'s hook — `spice` does not import this module) and `verify` (`render.keepFullSchematic` → `runFULL.*`).

## Global invariants

- **Deterministic**: no randomness or clock; iteration is graph insertion order; `Table`/`HashSet` are only looked up, never iterated unless sorted after.
- **Zero-value ⇒ byte-identical output.** Every optional feature (bundles, arrays, power band, dividers, fallback kinds) has a zero-value plan, and every downstream path is guarded on it. A netlist without the feature must produce exactly the pre-feature scene, SVG and JSON. Preserve this when adding features.
- **Scene schema is additive only; `sceneSchemaVersion` stays 1.** New enum values are *appended* (`WireKind`: `wkBus`, `wkInterface`, `wkChain`, `wkPowerLink`); new enums put the legacy meaning at ordinal 0 (`fbUnrouted`, `pmNone`); new fields are emitted to JSON only when non-default.
- **Rail decisions come from `netlist/kinds.isGround`/`isRail`, never name guessing**, via local wrappers (`isGroundHere`/`isRailHere` in `geometry.nim`) where an explicit `ntPower` net kind beats a stray `ptGround` pin (an op-amp `V-`).
- **Sibling-clone trap**: rendering an instance's cloned child means global net `"0"` carries pins from every sibling clone with reused designators — **filter pins by owning-`Netlist` identity, not name**, everywhere `net.pins` is walked. Dual: `onThisSheet` accepts a global net whose `.netlist` is the root if `nl.nets` holds the identical object (else this sheet's own grounded parts are rejected).
- **`SchematicPart.designator` is a join key and never rewritten**; display text goes in `label` (`"U10A"`, `"X1..X8"`).
- Path-integrity failures in `routeNet` (empty path, wrong endpoint, occupancy violation, non-axis segment) are **assertions** (bugs). Unreachability is a placement problem and returns a recoverable `RouteOutcome`.

## `scene.nim`

`Schematic` with `SchematicPart` (pin-span `bodyW`/`bodyH` **and** drawn-ink `inkW`/`inkH`, `rotation` 0/90/180/270, pins, `label`, `count`/`members` for collapsed arrays), `SchematicWire` (per-net polylines, `members` for bundles), `SchematicJunction`, `SchematicLabel` (all placed by layout; the writer only renders), `SchematicPort` (rotation only 0 or 180; its stub is an ordinary `wkSignal` wire, so ports stay in occupancy), `SchematicFallback` (an unwired pin: net, part/pin, position, escape `ex`/`ey`, stub `points`; empty `points` = zero-space marker). **Fallbacks live in `fallbacks`, not `wires`** — never in occupancy or junctions. `SchematicDivider` (the power band rule) is not a label and never enters the label pass. `Point` relies on structural `==`/`hash` over grid-snapped coordinates. Bus width (`members.len > 1`) means multiple nets; colour (`wkBus`/`wkInterface`) means membership.

## `layout.nim` and its included units

`layout(nl): Schematic` is a pure façade over **`include`d** units (private state stays internal). **Include order is load-bearing**: `geometry` → `symbols` → `router` → `labels` → `placement` → `bundles` → `arrays` → `composites/composite` → `composites/passive`/`pi`/`tee` → `overrides` → `constrained` → `power` → `state` → `routing` → `finish` → `refinement` → `diagnostics` (see `layout.nim`). Anything spliced earlier can't name later types — that's why `boxSlots`/`symbolFor`, `powerBandAllows` and `repairTerminalClearance` take **plain-data** arguments (bools, partitions) rather than plan objects. `composite.nim` forward-declares the motif `*Kind()` ctors.

`state.nim` holds private `LayoutState`/`RoutingState` (never add these to the public `Schematic`), the stage bodies and their forwarders; `layout` is just the ordered stage list. Stage enum values are `ls*` (order in `layout.nim`); disabling a stage yields its zero-value plan.

`LayoutOptions.policy` has one value, `lpConstrainedLayered` (kept as an enum for a future second policy). `parseLayoutPolicy`/`archiveLayoutOptions` centralise `--schematic-layout`/`$VERAX_SCHEMATIC_LAYOUT`.

### Placement

- **Constrained pipeline** for ordinary sheets: ≤ 64 *placement units* (a composite counts once) **and** ≤ 256 raw parts (arc discovery and route scoring are still raw-sized). Output-pin arcs seed left-to-right columns; each semantic layer folds over ≤ 3 adjacent columns; parallel two-terminal parts on the same net pair group. The semantic walk follows flat two-terminal devices until an input, stopping at rails, ground, hierarchy and inputs. **Traversal steps are keyed on `(pool item, exit net)`**, not the pool item alone (a pi's shunt must not consume its series member's position). Existing legalization stays authoritative. Don't attach heuristics, reorder passes, or reinterpret terminal/recovery safeguards.
- **Rotation** (square two-terminal symbols only, so `bodyW`/`bodyH` never swap): `bestRotation` ranks lexicographically by power direction (ground down; ≤ 0 V rails down; > 0 V and unannotated rails up; `ntPower` beats a stray `ptGround`), then by pin-to-net-mate-centroid distance. Co-optimised inside the force loop from a snapshot (order-independent), `grid` hysteresis, last 30 iterations frozen; a final hysteresis-free pass after separation/packing is definitive.
- **Force layout**: Fruchterman–Reingold on a golden-angle spiral seed; centre-to-centre repulsion; **pin-to-pin** attraction (ground excluded, power weaker); gentle gravity; grid snap.
- **Separation**: each part to the nearest grid cell where its body inflated by `routingClearance` + channel is clear — guarantees no overlap and room for a route.
- **Packing** (`groupsOf`/`packGroups`): blocks joined by signal nets; blocks of ≤ `mergeMaxParts` fold into their nearest power-rail net-mate's block (decap stays with its IC; suppressed via `noMerge` for power-band units); shelf-pack. **Reverts if not smaller in area** — it can only help. Rigid grid-snapped translations.
- **Terminal-clearance repair**: reserves each 40-unit ground/supply glyph against foreign escape corridors, inflated bodies and other-net glyphs. Coincident connected pins on distinct nets are a hard condition, handled first. Moves small passives first; a `protectedLeaf` stays put when something else can move.
- **Composites** (`composites/`): see below. `lsCompositeOrient` picks each orientable unit's rigid `unitRot` before separation; `revisitCompositeFrames` re-scores after centres settle and rejects frames overlapping foreign parts.

### Routing

- Per signal net, a tree grown from the first pin; each next pin attaches to the closest wired point via a **Hanan free-space grid** from inflated obstacle boundaries plus terminal escape coordinates, with a `freeGridMargin` ring outside the extremes (so a route can wrap a part). **Bend-aware search**: state `(node, incoming axis)`, cost (length, bends); sources seeded in both axis states; endpoint stubs uncharged; ties → lowest node index, then horizontal.
- **Ground/rail nets are never routed as trees**: each pin gets a local stub along its outward `escapeDir` with a glyph (`svg` draws the bar perpendicular to the stub). A rail/ground parallel-stack composite draws **one** glyph; its internal fanout is tagged **`wkPowerLink`** (not ground/supply — would place a bogus glyph; not `wkSignal` — indistinguishable from mistakenly routing a rail).
- **Hard geometric invariant**: same-net wires never share a positive-length collinear segment; **different-net wires never touch collinearly at all (not even end-to-end) and keep ≥ `wireMinSeparation` (8) apart where parallel and overlapping**. Perpendicular crossings are fine. `wkChain` arcs are exempt.
- **Escape stubs** are seeded (tagged with their net) before any rail stub and respected by both rail-stub shortening and signal occupancy: a foreign route may touch a seed's endpoint or cross it, never run along it. Seeds are deliberately *not* held to the stronger end-to-end rule.
- **Recovery** (`recoverRouting`): deterministic single-part moves on rings up to `feedbackMaxRadius` around candidates with ≥ 2 signal nets; keep strictly-better layouts; budgets `feedbackAcceptedBudget` (4) / `feedbackAttemptBudget` (30). Never overlap raw bodies or coincide distinct-net pins. Respects committed `unitRot`. Skipped above `feedbackMaxParts` (24) units or 96 raw parts. A sheet that already routes is untouched.
- **Fallbacks**: if still unroutable, re-route with fallbacks — the failing net's pins become `SchematicFallback`s (dashed amber stubs sized against full occupancy, finalised after all real wires, never in occupancy or junctions). A single-pin signal net is a fallback too (but `ok` stays true).
- Hierarchy boxes and unknown kinds draw as **fallback boxes** (`boxSlots`): `ptPower` top, `ptGround` bottom, `ptInput` left, `ptOutput` right, others fill left then right; drawn rect inset by `boxStub` (20). Boxes never rotate. Controlled sources draw as `source4` (by pin name); an op-amp with exactly `IN+`/`IN-`/`OUT`/`V+`/`V-` draws as a triangle (by name, non-rotatable), else a box.

### Ports

From `nl.ports` (declared order); rail/ground ports skipped. `portDirection`: pin kinds first, else "nothing on the sheet drives it" → input. Fixed columns: inputs/unspecified left, outputs/bidir right. Pre-route `y` from a wire-tension relaxation with `portMinGap`. **Post-route `refinePortPlacement`** (`refinement.nim`, `lsPortRefine`) snaps each ported net's ports to the routed wire's dominant `y` via `LayoutState.portY` and commits only if strictly better (`betterThan`: fewer fallbacks, then bends, then length). Column and `x` are never touched. Port connection points are routed as extra net pins with an inward escape. **Pass-through straps** (`<x>_in`/`<x>_out` on one net) are oriented by suffix (`strapNets`); an unroutable published net degrades to a teal `fbNetLabel`. `docs/port_placement.md` has the survey.

### Labels

First-fit over candidate spots (free sides first — right, top, left, bottom — then occupied sides, then corners), measured from **ink** extents. Rejects crossings of wires, leads, fallback stubs, ink, ports, glyphs, prior labels; wire/lead crossings outweigh overlaps; lowest penalty wins (earliest on ties). Order: parts, net names, rail names, fallback names (a fallback net isn't labelled twice). A net name's anchor-pin escape side is tried last. Box designators are drawn by `svg` inside the box. Placement passes deliberately don't reserve label space.

### Diagnostics

`diagnoseFallbackNet`/`diagnoseFallbackNets`/`diagnoseAllFallbacks` rebuild router inputs **from a finished scene alone** (works on an archived `runNNN.json`) and re-run `routeNet` for one fallback net, classifying the first blocker (`rbObstacle`/`rbOccupancy`/`rbEscapeSeed`) at the failed pin's first hop only. A net whose every record is `fbNetLabel` is deliberate: `diagnoseFallbackNet` returns `deliberate = true`; `diagnoseAllFallbacks` skips it.

## `bundles.nim` — buses and interfaces

`bundlePlan(nl)`: one read-only pass over `nl.nets` reading `bus.*`/`iface.*` **net attrs directly**.

- **Never call `findBus`/`findInterface`/`interfacesOf`/`busOf` here** — they rescan, `findInterface` raises for defs not registered in-process, and `busOf` **writes** `bus.index`. Layout must stay read-only.
- **Net attrs only, never pin attrs** — `promotePortDirections` copies `iface.*` onto pins, which would drag no-connect nets into a bundle.
- Grouping: `iface.instance` wins, else `bus.name`. < 2 members → scalar. **Any rail/ground member declines the whole bundle.** Members uniformly touching ≥ 2 endpoint entities (components or the sheet boundary) → **`brCollapsed`** (one merged pin per entity, one thick bus tree; **no entity cap**). Else, if published or spanning ≥ 3 components → **`brNetLabel`** (grouped tags like `spi1`/`spi1(cs0)`, no wires). Per-`bus.name` retry only for the < 3-entity, unported, non-uniform leftover. Else **`brScalar`** (recoloured wires). A non-box carrier blocks collapse only.
- **The plan depends only on the netlist**, so recovery moves never rebuild it; computed in `prepare` **before `state.syms` is sized** (merged pins shrink boxes).
- **`Bundle.display` is the occupancy tag** (wires, ports, merged pins, `sceneRouterInputs` all key on it) and is disambiguated against every net name (`_iface`/`_bus`/`_2`…).
- **Escape-seed dedupe trap**: merged members would each seed the identical stub under different tags, blocking the bundle's own route. Seed a collapsed pin/port **once**, tagged `b.display` (`seededBundle`).
- `groupOf.len == 0` is the historical path bit-for-bit. **`laneOf` is the one source of a merged lane's string** (box sizing and pin naming must agree). `SchematicPin.net` stays `b.display`, never the group text.
- `bundleReport(nl)` is the public test hook.

## `arrays.nim` — repeated subsheets and parts

Collapses N identical things into one badged representative. Design note: `docs/subsheet_arrays.md`.

- Two builders sharing one `ArrayPlan` and one `classifyGroup` body: `buildSubsheetArrays` (same `subNetlist.name` + pin keys) and `buildComponentArrays` (key: kind, **value**, partNumber, name, pin names, pin kinds). A component stating **neither value nor partNumber** is never a candidate.
- **Port classes**: *common* (bus-bar tick), *distributed* (one `wkBus`, `[1:N]`), *chained* (`out(i) == in(i+1)`, linear and complete → recirculation arc; skipped for non-box reps → distributed), *irregular* (forked cap, `n·m`). Rail/ground ports don't vote. Sub-grouping splits by any port partitioning members into ≥ 2 groups of ≥ 2.
- **Floors**: normally ≥ 3 members. Component groups additionally need a distributed port, else are declined (a signal-net parallel bank keeps its visible stack) — **except** the bypass-bank floor: every port `apCommon` **and** `railCommon` collapses at **2**; and a pair with a distributed port that is `mergedByBundle` (declared bus/interface evidence) collapses at 2.
- **`finalizeArrayPlan` runs once after both builders** and derives `suppressed` from the final `groupOf` (bucket by `(array, port)`, keep the first in `nl.nets` order). Per-array suppression broke nets distributed at both ends.
- **Totality `doAssert`**: every net on a hidden member must be suppressed, grouped, on the representative, on an irregular port, or bundle-owned — or it would vanish without a marker.
- **`splitKeyOf`** reads `iface.instance` then `bus.name` then net name, so a split visible only through bus membership is seen (precedence matches `bundles.nim`).
- `railCommon` suppresses the bus-bar mark on glyph-drawing pins.
- **Collapsed-bundle decline** (`survivesCollapsedBundles`): decline a candidate only if hiding its members leaves a `brCollapsed` bundle with < 2 placeable entities.
- **Bundle wins at the pin only where it actually merges one** (`mergedByBundle`); otherwise the array draws and routes the port itself, **reusing `Bundle.display`** as `ArrayPort.display` so arrays and bundle agree on one wire with no coordination. The net-label pass steps aside (`arrayOwnsDistributedPin`). `ArrayPort.bundleFamily` gives a collapsed merged pin its bus name.
- Escape-seed dedupe here is keyed on the **point** (distributed endpoints sit at different points).
- **Port-folding trap**: a distributed member net that is also a port folds to one pennant, or the port disappears when its only owner is hidden.
- Chain arcs are **fixed polylines** inside the box (never in `nl.nets`, exempt from wire invariants); only the lead carries the `xN` badge.
- `prepare` drops non-representatives from `state.comps` **before `syms` is sized**.
- `arrayReport(nl)` is the public test hook.

## `composites/`

A **placement unit** is a raw singleton or a recognized composite. `CompositeKind` is seven `{.nimcall.}` hooks (`recognize`/`internalLayout`/`externalPins`/`pickRepresentative`/`internalRoute`/`rotationCandidates`/`footprint`) + `orientable`. `compositeKinds` is a `let`: **registration order is recognition precedence is output**. Add a motif as a file plus one registry entry — never a special case in router/placement. `compositePlan` is non-nesting (a later kind can't consume an earlier composite).

- **Excluded from the arena**: bundled parts and every collapsed array representative (a badged `x8` resistor must not join a composite).
- **`isTwoTerminal` vs `isTraversable`**: every recognizer uses `isTwoTerminal` (they assume a unique other net via `twoTermOtherNet`); only `constrained.pathsFrom` uses `isTraversable`/`traversalExits` (declared `traverse:` multi-exit parts).
- `internalLayout` authors a canonical frame; `rawOffsets` applies `unitRot`. Parallel stack and series chain are **orientable**; **pi and tee are not** (ground-down is a real convention). Orientation of a pure-power unit ranks by `powerRank` then `rotationScore`; a unit with a signal net by `rotationScore` only.
- `footprint` is routing-only: bounding box by default; the pi uses `memberBodiesFootprint` (routes must thread between bodies).
- **`parallelStackKind`**: parts sharing an unordered net pair. **`seriesChainKind`**: usable parts (`isTwoTerminal` + `isPassiveElement` + not a box) linked by nets with exactly two pins that are not ground/rail/port; cycles declined; registered last so pi/tee win. Doesn't nest with parallel stacks.
- **pi**: series part with a grounded shunt at each end; both series nets must reach beyond the composite. **tee**: two series parts meeting at a private 3-pin mid net plus a grounded shunt; the mid net is fully internal. Sources are never members (`isPassiveElement`, keyed on symbol family).

## `power.nim` — power/decoupling band

Classifies placement units (`pcSignal`/`pcPower`): `layout.power` override first (first-wins across members), else `unitExternallyPurePower` (every external net is rail/ground). `PowerPlan.any` is true only when **both** classes exist. Plain data here; the mover (`enforcePowerBand`/`placePowerUnit`) is in `state.nim`. Runs at `lsPowerBand` (after `lsPack`, before `lsLayoutOverrides` — side columns live inside a y-half). Power units are shelf-packed below the signal bounding box; `state.powerSplit` is respected by repair and recovery. `rawPowerFlags` projects to raw indices for earlier-included code. `finishDividers` runs after `finishBounds`.

## `svg.nim`

Self-contained (literal colours, inline styles). **Each symbol's stroked extent must match `inkExtent` in `layout.nim`** — update both together. Rotated parts use a `rotate()` group; labels are outside it so they stay upright. Corner chamfers (4 units) are renderer-only; scene/JSON keep orthogonal points. Fallbacks: `fbUnrouted` dashed amber + open circle; `fbNetLabel` solid teal + chevron. Bus `#1f6feb`, interface `#8250df`, stroke 4 when collapsed — **stroke is cosmetic; don't exceed 4 without raising `wireMinSeparation`** (which moves every layout). **Painter order**: grid, dividers, highlight underlays, wires, fallback stubs, junctions, symbols, ports, labels. Port pennants are computed polygons (no rotate group). `renderSvg(s, highlight)` underlays wires on the named nets (or bus members) with a translucent `highlightColour` band, leaving the wire itself untouched; an empty set is byte-identical to `renderSvg(s)` (`tests/test_schematic_highlight.nim`). `renderSvg(s, classes)` takes several `HighlightClass` (nets, colour) painted in order — the report's read/driven colours. The HTML report uses it to mark where a test injects and reads.

## `json.nim`

`sceneToJson`/`writeSceneJsonFile` and the strict reader `jsonToScene`/`readSceneJsonFile`. Version 1 writes every field (parts include `rotation`, `bodyW`/`bodyH`). The reader raises `SceneJsonError` naming any missing/mistyped field or unknown version, and reads the legacy **unversioned** format by rebuilding escape directions with `layout.fallbackEscapeDir` (`(0, 0)` when unknown — never invented). Optional fields use `optArr`/`optStr`; enum name tables fail loudly on unknown tokens.

## `render.nim`

`writeScenePair(scene, base)` writes `.svg` and `.json` from **one** scene (used by `spice/ngspice` too). `keepFullSchematic(nl)` writes `runFULL` for the root, `runFULL.<sheet-id>` per distinct child variant (same-named children dedupe only when routed scenes and child targets agree; else `.2`, `.3`…; `safeSheetName` maps to `[A-Za-z0-9._-]`), and `runFULL.html`. **Best-effort** — swallows `CatchableError`; drawing must never fail a check.

`runFULL.html` is a self-contained hierarchy browser: sheets inlined into one `const MODEL` (XML prologs stripped, `</` escaped); per-part hit rects (click = properties, double-click = descend, *Up* pops); merged bundle pins get their own hit rects added **after** part rects. Root id is `@root`. **Traps pinned by `test_verify_keep.nim`**: the HTML must never contain the literal `src=`, and `const MODEL = …;` must stay on one line.
