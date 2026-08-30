Direct observations

 - Public entry point is layout*(nl: Netlist): Schematic in src/nimcir/schematic/layout.nim.
 - layout.nim is a compatibility façade that includes implementation units:
     - geometry.nim
     - symbols.nim
     - placement.nim
     - router.nim
     - routing.nim
     - labels.nim
     - diagnostics.nim
 - Included units share private symbols and state, so stages are not independently importable or replaceable today.
 - src/nimcir/schematic/scene.nim is the stable renderer-neutral public data contract. SVG and JSON consume Schematic; they do not participate in layout.
 - Existing public overloads include layout, renderSvg(Netlist|Schematic), JSON serialization, and fallback diagnostics.

 ### Current stage sequence

 1. Collect components in netlist insertion order.
 2. Select SymbolDefs and build designator index.
 3. Seed positions using a golden-angle spiral.
 4. Force-directed placement:
     - centre repulsion
     - pin-to-pin net attraction
     - gravity
     - rotation co-optimization
 5. Snap centres to the 40-unit grid.
 6. Separation using inflated body rectangles.
 7. Signal-net grouping and shelf packing.
 8. Definitive rotation recomputation.
 9. Leaf snapping.
 10. Terminal-clearance repair.
 11. Routing preparation and routing:
     - construct SchematicParts
     - derive interface ports
     - create obstacles and escape seeds
     - route ground/supply stubs
     - build Hanan grid
     - route signal trees
     - create junctions
     - create fallback markers
 12. Placement-routing feedback loop, which reruns routing for candidate single-part moves.
 13. Label placement against finished geometry.
 14. Bounding-box calculation.
 15. Fallback diagnostics operate later from a completed Schematic.

 Main refactoring issue

 The logical stages exist, but their boundaries are not represented in types. For example:

 - routeScene combines scene materialization, port placement, obstacle construction, rail routing, signal routing, fallback generation, and metadata needed by labels.
 - Placement state is spread across parallel sequences: comps, syms, pos, rots, ohw, ohh, and idxOf.
 - Routing state is split between RouteScene fields and local variables such as escapeSeeds, glyphs, occ, free, and portConn.
 - Labels consume both final scene data and netlist-derived metadata (portedNets, railLabelReqs, pin maps).
 - Feedback calls the combined routing stage recursively, making it difficult to replace only routing or only placement.

 This is inferred to make independent stage testing and enable/disable behavior substantially harder than necessary.

 Recommended design

 ### 1. Introduce an internal typed pipeline context

 Add an internal module, for example:

 src/nimcir/schematic/pipeline_types.nim

 Define explicit state/artifact objects:

 ```nim
   type
     LayoutInput = object
       netlist: Netlist
       components: seq[Component]
       symbols: seq[SymbolDef]
       indexByDesignator: Table[string, int]

     PlacementState = object
       positions: seq[Point]
       rotations: seq[float]
       halfWidths: seq[float]
       halfHeights: seq[float]

     RoutingState = object
       parts: seq[SchematicPart]
       ports: seq[SchematicPort]
       obstacles: seq[Obstacle]
       escapeSeeds: seq[OccSeg]
       glyphs: seq[OccSeg]
       occupancy: seq[OccSeg]
       freeGrid: tuple[nodes: seq[Point], adj: seq[seq[int]]]
       wires: seq[SchematicWire]
       junctions: seq[SchematicJunction]
       fallbacks: seq[SchematicFallback]
       portedNets: HashSet[string]
       railLabelReqs: seq[...]
       pinPositions: Table[string, Point]
       partIndices: Table[string, int]

     LayoutState = object
       input: LayoutInput
       placement: PlacementState
       routing: RoutingState
       scene: Schematic
 ```

 Prefer grouping related parallel sequences into objects. This prevents accidental mismatch between pos[i], rots[i], and syms[i].

 ### 2. Define explicit stage contracts

 Use a stage specification rather than implicit call order:

 ```nim
   type
     StageId = enum
       lsPrepare, lsForcePlacement, lsSeparate, lsPack,
       lsOrient, lsLeafSnap, lsTerminalRepair,
       lsPrepareRouting, lsRoute, lsRecoverRouting,
       lsLabels, lsBounds

     StageSpec = object
       id: StageId
       enabled: bool
 ```

 For the built-in pipeline, use a deterministic seq[StageSpec]. Stage execution can be a case dispatcher rather than closure-based callbacks:

 ```nim
   proc runStage(id: StageId, ctx: var LayoutContext)
 ```

 This is simpler to debug and avoids closure calling-convention and lifetime complications. If external/custom stages are eventually required, add a separate internal/public proc type later.

 Each stage should have a narrow proc such as:

 ```nim
   proc forcePlace*(input: LayoutInput, state: var PlacementState)
   proc separate*(input: LayoutInput, state: var PlacementState)
   proc pack*(input: LayoutInput, state: var PlacementState)
   proc route*(input: LayoutInput, placement: PlacementState,
               result: var RoutingState, options: RoutingOptions)
   proc placeLabels*(input: LayoutInput, scene: var Schematic,
                     routing: RoutingState)
 ```

 The exported status is optional; failed routing should remain a normal typed result, not an exception.

 ### 3. Separate preparation from policy

 The current routing stage should be decomposed into:

 - materializeParts
 - placePorts
 - buildRoutingObstacles
 - buildEscapeSeeds
 - emitTerminalStubs
 - buildFreeGrid
 - routeSignalNets
 - finalizeFallbacks
 - deriveJunctions

 routeNet in router.nim is already close to a good independently testable primitive. Preserve its current hard assertions for path-integrity bugs and its recoverable RouteOutcome for geometric unreachability.

 ### 4. Make feedback a policy around stages

 recoverRouting should not own a monolithic routeScene call. Instead define a reusable evaluation function:

 ```nim
   type
     RoutingAttempt = object
       status: ...
       routing: RoutingState

   proc evaluateRouting(input: LayoutInput,
                        placement: PlacementState,
                        options: LayoutOptions): RoutingAttempt
 ```

 Feedback then:

 1. evaluates the initial placement;
 2. generates candidates in fixed order;
 3. evaluates each candidate;
 4. accepts only strictly better failOrd progress;
 5. falls back deterministically when necessary.

 This preserves the current “attempt zero is unchanged” invariant while allowing routing or placement policies to be replaced independently.

 ### 5. Use options without changing the existing API

 Keep:

 ```nim
   proc layout*(nl: Netlist): Schematic
 ```

 Add an overload:

 ```nim
   proc layout*(nl: Netlist, options: LayoutOptions): Schematic
 ```

 LayoutOptions should contain enabled stages and budgets, with defaults matching today’s constants:

 ```nim
   type
     LayoutOptions* = object
       stages*: set[StageId]
       feedbackAcceptedBudget*: int
       feedbackAttemptBudget*: int
       feedbackMaxParts*: int
 ```

 The existing overload calls layout(nl, defaultLayoutOptions()). This keeps all current callers, SVG, JSON, archive, and verification behavior unchanged.

 For invalid combinations, choose explicit semantics:

 - disabled placement stages leave their prior state unchanged;
 - routing requires materialized parts and ports;
 - labels require a completed scene;
 - bounds can be independently rerun;
 - feedback is disabled automatically if routing is disabled;
 - missing prerequisites should produce a deterministic ValueError/typed status, not silently invent state.

 Determinism requirements to preserve

 The refactoring must retain:

 - component, net, pin, and port insertion order;
 - explicit sorting before any order-sensitive output;
 - stable tie-breaks for rotations, routing, packing, and candidate moves;
 - no iteration over Table/HashSet for output decisions unless sorted afterward;
 - exact grid snapping and -0.0 normalization;
 - route ordering and fallback ordering;
 - attempt-zero routing behavior;
 - exact Schematic field population and JSON schema.

 Stage configuration itself must be ordered and explicit. A set of enabled stages alone is insufficient because it does not express ordering; use a sequence plus dependency validation, or a fixed canonical order
 filtered by enabled IDs.

 Migration approach

 1. Extract shared constants and private geometry/state types into pipeline_types.nim.
 2. Extract input normalization and symbol selection.
 3. Wrap existing placement code behind PlacementState; initially preserve algorithms verbatim.
 4. Extract routing preparation and routing from routeScene into typed sub-stage procedures.
 5. Make recoverRouting call the new routing evaluator.
 6. Move label and bounds logic to consume Schematic plus explicit routing metadata.
 7. Keep layout.nim as the compatibility coordinator and public import boundary.
 8. Leave scene.nim, svg.nim, json.nim, and diagnostic public types unchanged.
 9. Gradually convert included implementation units into normal internal modules once shared symbols are explicit.

 Existing tests and proposed test seams

 Current coverage is primarily integration-level in tests/test_schematic.nim. It checks deterministic SVG/JSON, placement separation, rotations, routing invariants, fallbacks, labels, ports, glyph clearance, and
 JSON round trips.

 The refactoring should add direct tests for:

 - force placement from fixed LayoutInput;
 - separation on fixed positions;
 - packing area guard;
 - rotation selection and leaf snapping;
 - port placement;
 - Hanan-grid construction;
 - routeNet with fixed obstacles/occupancy;
 - fallback finalization;
 - label candidate selection;
 - bounds calculation;
 - stage-disabled combinations.

 No public scene or rendering API needs to change.
