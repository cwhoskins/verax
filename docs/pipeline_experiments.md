Early components are not fixed during the main placement optimization.
 In src/nimcir/schematic/layout.nim, the 250-step force-layout loop computes displacement for every component, then updates every position. Repulsion, net attraction, and gravity are global; net attraction is
 pin-to-pin and considers all component pairs on each net.

 - Iterations: 250
 - Rotation updates: iterations 0–219
 - Rotation frozen: final 30 iterations
 - Initial positions: deterministic golden-angle spiral
 - Final force-layout positions: snapped to the 40-unit grid

 Rotation selection is snapshot-based: all rotations for an iteration are chosen from the previous positions/rotations, so component visitation order does not make earlier parts constrain later ones. Ties choose
 the lower rotation angle.

 Stages where ordering matters

 ### 1. Separation: sequential, earlier parts effectively fixed

 After force layout, layout.nim performs separation:

 - Components are visited in netlist insertion order.
 - Each is moved to the nearest grid cell whose inflated body clears all already-placed components.
 - Once accepted, that component is not reconsidered during this pass.
 - Thus, this is the first stage where “early components become fixed”; later components absorb displacement.

 The inflated clearance uses placementPad (20 units per side).

 ### 2. Group packing: groups move rigidly, not jointly optimized

 groupsOf and packGroups in src/nimcir/schematic/placement.nim form groups as follows:

 - Components connected by signal nets are unioned into the same group.
 - Ground and rail nets do not create signal groups.
 - Groups of at most two components may be merged into the group containing their nearest power-rail mate.
 - Equal-distance rail-mate ties use component insertion index.

 packGroups then performs one deterministic shelf-packing pass:

 - Groups are ordered by descending bounding-box height, then group ID.
 - Each group receives one rigid, grid-snapped translation.
 - Internal component geometry is unchanged.
 - Packing is discarded unless the resulting total bounding-box area is strictly smaller.

 Therefore, groups are not globally optimized together. They are first independently produced by the force layout, then translated as rigid blocks by a heuristic shelf pack. Groups do not rotate, deform, or
 exchange components during packing.

 ### 3. Definitive rotation

 recomputeRotations makes one snapshot-based pass after separation and packing. Positions are fixed at this point; every eligible component gets its final orientation.

 Only square, non-box, two-terminal symbols can rotate.

 ### 4. Leaf snap: sequential individual cleanup

 leafSnap then processes one-signal-net components in insertion order:

 - Each leaf may move to a nearby free grid cell toward its nearest mate.
 - It may also be reoriented to face that mate.
 - Each leaf is evaluated against the current positions of the other components.
 - Previously processed leaves are not jointly re-optimized.

 ### 5. Terminal-clearance repair: bounded individual moves

 repairTerminalClearance may move implicated components one at a time:

 - Prefers small passive symbols.
 - Candidate ordering is component class, body area, then insertion index.
 - Candidate cells are searched by increasing grid radius and deterministic dy/dx order.
 - A move is kept only if it strictly reduces glyph conflicts.
 - Maximum: 8 accepted moves, 160 attempts, radius 6.
 - Rotation is not recomputed after these moves.

 ### 6. Placement-routing feedback

 recoverRouting first tries routing without changing placement. If routing fails:

 - For sheets of at most 24 components, it tries single-component moves, not group moves.
 - Candidates are movable only if the component has at least two signal nets.
 - Components are tried in insertion order.
 - Candidate cells use rings up to radius 4, nearest first.
 - Maximum: 4 accepted moves, 65 total attempts.
 - A candidate is accepted if routing succeeds or reaches a later failure point.
 - Rotations are recomputed after each accepted candidate; leafSnap is not rerun.
 - Components never overlap raw bodies, but the original placement clearance may be relaxed.
 - Sheets larger than 24 components skip this feedback and use fallbacks if needed.

 Bottom line

 - Main force phase: all components move together; no early component is fixed.
 - Separation phase: sequential; earlier components constrain later ones.
 - Signal-connected components: influence one another during force placement, but are not treated as a rigid group there.
 - Packing phase: groups are moved together as rigid blocks, but only by a deterministic shelf-packing heuristic—not joint optimization.
 - Later repair/feedback: individual components move sequentially, with bounded deterministic searches.

 Relevant code: src/nimcir/schematic/layout.nim, src/nimcir/schematic/placement.nim, and tests/test_schematic.nim (determinism, packing, clearance, and rotation coverage).

 5 turns ↑65k ↓2.5k R105k $0.0180 ctx:65k openai-codex/gpt-5.6-luna


 Yes, but it is mixed:

 - Main placement: 250 global force-layout iterations. All components move together; early parts are not fixed. Connected parts attract each other, including across a net.
 - Separation: sequential by insertion order. Earlier accepted parts effectively become fixed while later parts move to free grid locations.
 - Group packing: signal-connected groups can be translated as rigid blocks, but they are not jointly re-optimized internally.
 - Cleanup: leaf snapping, terminal-clearance repair, and routing recovery make bounded, mostly one-component-at-a-time moves.

 So the initial result is group-influenced and iterative, but later stages do introduce ordering effects. There is not currently a full “optimize this entire connected group together, then lock it” phase.


 Can you research online several popular methods for improving global placement?


 Popular global-placement methods include:

 1. Analytic placement / quadratic optimization
    Model nets as springs and minimize total wirelength with density constraints. Common in VLSI placers such as RePlAce/DREAMPlace-style workflows. Fast global convergence; needs a legalization stage afterward.

 2. Electrostatic placement
    Treat components as charged objects: nets attract, density creates repulsion. This improves on simple pairwise repulsion by producing smoother, globally balanced layouts. Particularly effective for avoiding
    local crowding.

 3. Partitioning / recursive min-cut
    Repeatedly divide the connectivity graph into regions while minimizing cut nets, then place within each region. Good for preserving functional clusters and hierarchy.

 4. Multi-level coarsening
    Collapse strongly connected components into supernodes, place the coarse graph, then progressively expand and refine. This helps avoid poor local minima and is useful for schematic functional blocks.

 5. Simulated annealing
    Randomly propose moves, rotations, swaps, and group moves; sometimes accept worse moves early. Strong at escaping local minima, but slower and less deterministic unless carefully seeded.

 6. Force-directed placement with stress majorization
    A more stable version of force layout that repeatedly solves an optimization approximation rather than directly applying forces. Often gives better global structure and fewer oscillations.

 7. Constraint-based placement
    Add explicit constraints: keep decouplers near IC rail pins, keep feedback parts near an op-amp, align ports at edges, reserve pin escape corridors, preserve left-to-right signal flow. This is especially
    appropriate for schematics, where visual semantics matter more than raw wirelength.

 For nimcir, a practical combination would be:

 - multilevel / functional-group initial placement,
 - followed by electrostatic or analytic global refinement,
 - then constraint-driven local repair for rail stubs, pin escapes, ports, decouplers, and feedback loops.

 That would address the current weakness: later sequential repair is compensating for a global placement objective that does not understand schematic-specific directional constraints.


 Can you ask an advisor if it agrees with your combindation or your list is leaving out a good approach?


 Assigning planner as advisor substitute


 subagent planner [project]
   Act as an independent technical advisor. Evaluate the prior ...
 ✓ planner (project)

 ─── Task ───
 Act as an independent technical advisor. Evaluate the prior recommendation for improving nimcir schematic global placement: multilevel/functional-group initial placement + electrostatic/analytic global
 refinement + constraint-driven local repair. Identify whether it is suitable given the current deterministic schematic pipeline, and important omitted approaches. Compare methods (e.g. stress majorization,
 constrained graph drawing, min-cut/recursive partitioning, simulated annealing, orthogonal topology-aware placement) with recommendation and give a concise prioritized path. Do not edit or test.

 ─── Output ───
 → read CLAUDE.md
 → read src/nimcir/CLAUDE.md
 → find **/* in src/nimcir/schematic
 → find *schematic* in tests
 → grep /schematic|placement|layout|route/ in tests
 → read docs/architecture.md
 → read src/nimcir/schematic/CLAUDE.md
 → read src/nimcir/schematic/placement.nim
 → read src/nimcir/schematic/layout.nim
 → read src/nimcir/schematic/router.nim
 → read src/nimcir/schematic/routing.nim
 → read src/nimcir/schematic/scene.nim
 → read src/nimcir/schematic.nim
 → read tests/test_schematic.nim:450-949
 → grep /schematic|placement|force layout|stress major|anneal|min-cut|orthogonal/ in docs
 → read docs/schematic_drawing_improvements.md
 → read docs/netlist-converter-research.md
 → grep /alignAxes|smoothPolylines|crossing|wirelength|bends|fallback/ in src/nimcir/schematic
 → grep /exact|fallback|bend|cross|determin|grid|area|compact|chain|feedback|terminal/ in tests/test_schematic.nim
 → find **/*placement* in docs
 → read designs/CLAUDE.md
 → read src/nimcir/schematic/geometry.nim:1-360
 → read tests/test_schematic.nim:1-125
 → read tests/test_schematic.nim:950-1069
 → read tests/test_schematic.nim:1280-1389
 → read designs/lib/riaa.nim
 → grep /electrostatic|analytic global|stress majorization|majorization|min-cut|recursive partition|simulated anneal|functional group|multilevel/ in .

 Technical assessment

 Verdict

 The prior recommendation is directionally sound but too generic for nimcir.

 A pipeline of:

 1. topology/functional-group initial placement;
 2. global refinement;
 3. constraint-driven legalization and routing repair;

 fits nimcir’s pure, deterministic architecture. However, electrostatic or generic analytic placement should not be the next priority. The current Fruchterman–Reingold pass already supplies electrostatic
 repulsion, while the observed defects are mainly caused by missing schematic semantics:

 - no left-to-right signal-flow model;
 - no explicit feedback-loop placement;
 - no first-class parallel/series motifs;
 - rail-only parts lack a serving-part relationship;
 - placement optimizes geometric proximity rather than orthogonal routability and readability.

 The best near-term direction is therefore functional/motif-aware orthogonal placement with deterministic constraints, retaining global refinement only as a secondary cleanup stage.

 Current-pipeline fit

 The proposal must account for functionality that already exists:

 - deterministic golden-angle seed and Fruchterman–Reingold refinement in src/nimcir/schematic/layout.nim;
 - pin-level attraction and co-optimized rotation;
 - signal-connected grouping and guarded shelf packing through groupsOf/packGroups in src/nimcir/schematic/placement.nim;
 - hard grid snapping and inflated-body separation;
 - specialized leafSnap and repairTerminalClearance;
 - routing-aware local repair through recoverRouting in src/nimcir/schematic/routing.nim;
 - bend-aware Hanan-grid routing in src/nimcir/schematic/router.nim.

 Thus, “constraint-driven local repair” is not new—it should become more unified and objective-driven, rather than adding another isolated repair pass.

 Also, docs/schematic_drawing_improvements.md is partially stale: it describes bend-aware routing as future work, but (length, bends) Dijkstra is already implemented.

 Method comparison

 ┌────────────────────────────────┬────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │ Method                         │ Suitability        │ Assessment                                                                                                                                                │
 ├────────────────────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Functional-group/motif         │ High               │ Best match. Use parallel pairs, direct series chains, op-amp input/output/feedback networks, decouplers, and hierarchy as coarse objects. Current         │
 │ placement                      │                    │ groupsOf is mainly disconnected-block packing and is too coarse for this.                                                                                 │
 ├────────────────────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Constrained orthogonal/layered │ High               │ Most important omitted approach. Pin kinds and ports can establish left/right flow; power orientation already establishes up/down semantics. Alignment,   │
 │ drawing                        │                    │ ordering, side, and non-overlap constraints directly encode schematic readability.                                                                        │
 ├────────────────────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Stress majorization            │ Medium             │ More stable and mathematically controlled than FR, with monotonic stress reduction. Useful as an optional refinement over semantic seeds, but graph       │
 │                                │                    │ distance alone does not understand feedback shelves, motifs, or signal flow. Requires an in-repo linear solver or iterative approximation under the       │
 │                                │                    │ zero-dependency policy.                                                                                                                                   │
 ├────────────────────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Electrostatic/analytic         │ Medium-low         │ Analytic quadratic placement minimizes wirelength but tends to collapse objects unless paired with density spreading/legalization. Electrostatic          │
 │ placement                      │                    │ spreading largely duplicates current FR behavior. Neither directly improves orthogonal topology.                                                          │
 ├────────────────────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Min-cut/recursive partitioning │ Low-medium         │ Deterministic and scalable, useful for very large sheets or coarse group partitioning. Binary cuts poorly represent left/right flow, feedback loops, and  │
 │                                │                    │ tightly bonded motifs. Current sheet sizes do not justify making it primary.                                                                              │
 ├────────────────────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Simulated annealing            │ Low globally;      │ Can optimize crossings, bends, area, rotations, and route failures together. But fixed-seed randomness remains sensitive to iteration details, runtime is │
 │                                │ medium locally     │ harder to bound, and reproducibility is weaker. Consider only as bounded deterministic neighborhood search—not the global placer.                         │
 ├────────────────────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Orthogonal topology-aware      │ Highest            │ Directly targets the product: readable orthogonal schematics. Layering, port ordering, crossing reduction, alignment, feedback-loop placement, motif      │
 │ placement                      │                    │ compaction, and route-channel reservation matter more than Euclidean stress.                                                                              │
 ├────────────────────────────────┼────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
 │ Template placement             │ High but selective │ Op-amp/regulator/common passive templates can produce excellent results. Use as constraints or functional-group patterns with a generic fallback, not as  │
 │                                │                    │ a growing collection of whole-sheet special cases.                                                                                                        │
 └────────────────────────────────┴────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

 Other important omissions:

 - hypergraph-aware net treatment instead of expanding every high-fanout net into an equally weighted clique;
 - explicit crossing/congestion estimates in the placement objective;
 - deterministic barycentric ordering within layers;
 - layout stability under small netlist edits, which is different from repeated-run determinism;
 - a benchmark corpus and quality metrics before replacing the global algorithm;
 - constraint priorities and honest handling of infeasible constraints.

 Prioritized path

 ### 1. Establish objective metrics and benchmark sheets

 Before changing algorithms, define deterministic metrics over the final scene:

 - unrouted/fallback signal nets;
 - signal-wire crossings;
 - bends and short jogs;
 - total routed Manhattan length;
 - bounding-box area/aspect ratio;
 - motif cohesion;
 - directional violations;
 - component and terminal-clearance violations.

 Use at least divider(), resistorChain(), twoBlocks(), decoupledMcu(), riaaChannel(), and a two-stage/hub-free circuit. Prefer relational thresholds over pinning every coordinate.

 ### 2. Add semantic topology and functional-group seeding

 Build a private placement model from the existing netlist graph:

 - collapse parallel pairs and proven direct series motifs into coarse groups;
 - associate rail-only decouplers with likely consumers;
 - derive signal sides from ports and PinKind;
 - detect feedback paths from output-side nets back to input-side pins;
 - assign coarse layers, sides, and ordering deterministically;
 - expand groups into aligned grid placements.

 Retain the golden-angle seed only for topology with insufficient directional information.

 This is more suitable than introducing multilevel coarsening generically. At current sheet sizes, “multilevel” should mean semantic motif contraction, not performance-oriented graph coarsening.

 ### 3. Introduce constrained orthogonal refinement and legalization

 Use deterministic coordinate descent or ordered grid search with lexicographic priorities:

 1. no raw-body overlap;
 2. preserve power-direction constraints;
 3. avoid routing/terminal infeasibility;
 4. minimize fallback count and estimated congestion;
 5. minimize crossings and bends;
 6. preserve motif alignment and layer order;
 7. minimize wirelength and area.

 This should absorb or coordinate the intent currently spread across separation, leafSnap, terminal repair, and recoverRouting. Existing passes can remain initially as safeguards.

 ### 4. Evaluate stress majorization as an optional global refiner

 Only after semantic seeding exists, compare:

 - current FR;
 - stress majorization;
 - no continuous global refinement, only constrained grid refinement.

 Stress majorization is preferable to another electrostatic implementation if a continuous refiner is still useful. Keep it only if benchmark metrics improve without destabilizing orientation, grouping, or
 runtime.

 ### 5. Improve net topology and routing feedback

 Placement should estimate the route structure the actual router wants:

 - trunk-and-tap preference for multi-pin nets;
 - channel congestion;
 - orthogonal crossings;
 - escape-corridor availability.

 A later router improvement can replace nearest-tree attachment with a deterministic rectilinear trunk/Steiner heuristic. This is likely to improve readability more than global force tuning.

 ### 6. Defer scalability algorithms

 Add min-cut/recursive partitioning or conventional multilevel coarsening only if real sheets become large enough to demonstrate a runtime or global-separation problem. Simulated annealing should remain an
 experimental bounded local optimizer, not the default.

 Affected areas for a future implementation

 - src/nimcir/schematic/layout.nim — pipeline ordering and extraction of the current FR block.
 - src/nimcir/schematic/placement.nim — functional groups, layering, constraints, legalization, scoring.
 - src/nimcir/schematic/routing.nim — unified placement/routing feedback objective.
 - src/nimcir/schematic/router.nim — later trunk/Steiner routing and route-quality reporting.
 - src/nimcir/schematic/geometry.nim — congestion, crossing, and pair-clearance helpers.
 - tests/test_schematic.nim — topology-aware placement and metric-based regression cases.
 - src/nimcir/schematic/CLAUDE.md — updated placement invariants and deterministic tie-break rules.
 - docs/schematic_drawing_improvements.md — reconcile recommendations with the already-landed bend-aware router.

 No scene schema change should be necessary.

 Specific future test cases

 In tests/test_schematic.nim:

 1. RIAA functional layout
     - Setup: riaaChannel().
     - Action: call layout.
     - Expected: R7‖C5 and R8‖C6 are adjacent and aligned; feedback network is on a consistent side of U1; no fallbacks; existing wire-clearance invariants hold.

 2. Decoupler association
     - Setup: decoupledMcu() plus two ICs sharing one rail.
     - Action: layout.
     - Expected: each decoupler is nearer its selected consumer than unrelated rail users, with deterministic tie-breaking.

 3. Left-to-right flow
     - Setup: input port → stage → output port.
     - Expected: input-side components precede the stage and output-side components follow it; feedback may violate acyclic layering only in the designated feedback region.

 4. Passive fallback
     - Setup: resistor chain or graph with no directional pins.
     - Expected: compact, non-overlapping, routable placement without inventing signal direction.

 5. Determinism
     - Setup: every benchmark circuit.
     - Action: layout twice.
     - Expected: byte-identical scene JSON.

 6. Quality bounds
     - Setup: benchmark corpus.
     - Expected: no regression in fallback count, routing invariants, or area; bounded bends/crossings using fixed numeric thresholds.

 7. Constraint infeasibility
     - Setup: intentionally crowded symbols.
     - Expected: hard safety invariants remain intact and the result degrades to explicit fallbacks rather than overlap or assertion.

 Commands to run if approved for implementation

 Targeted:

 ```sh
   nim check --path:./src src/nimcir/schematic/layout.nim
   nim c -r --path:./src tests/test_schematic.nim
 ```

 Archive integration regressions:

 ```sh
   nim c -r --path:./src tests/test_spice_keep.nim
   nim c -r --path:./src tests/test_verify_keep.nim
 ```

 Full suite, inspecting output rather than trusting nimble’s exit status:

 ```sh
   nimble test
   nimble test 2>&1 | grep -cE "FAILED|Error:"
 ```

 The final grep count must be 0.

 Assumptions and decisions needed

 - Is the target still “readable enough to eyeball,” or is publication-quality/hand-drawn appearance now required?
 - What is the maximum expected component count per sheet?
 - May placement infer functional relationships such as “this capacitor decouples this IC,” or must such relationships eventually be annotated?
 - Is deterministic output sufficient, or must small netlist edits also preserve most existing coordinates?
 - Should left-to-right signal flow override compactness when the two conflict?

 Risks and non-goals

 Risks:

 - inferred function can be confidently wrong;
 - crossing and congestion objectives can increase area;
 - hard constraints may make some sheets infeasible;
 - changing placement can alter route ordering and expose fallback cases;
 - floating-point global solvers can weaken cross-platform reproducibility.

 Non-goals:

 - PCB placement or physical proximity;
 - importing contract, analysis, spice, or pcb;
 - external graph-drawing dependencies;
 - editable or round-trippable schematics;
 - guaranteed optimal placement or Steiner routing.

 Recommendation: approve semantic functional-group seeding plus constrained orthogonal refinement first. Treat stress majorization as a benchmarked optional replacement for FR, and defer generic analytic,
 min-cut, and annealing approaches until evidence justifies them. No implementation should begin until the quality target and inference policy are approved.

 5 turns ↑114k ↓4.7k R190k $0.8042 ctx:116k openai-codex/gpt-5.6-sol


 The advisor agrees with the overall staged approach, but recommends a shift in priority.

 For nimcir, the best next approach is:

 1. Semantic/motif-aware initial placement
    Identify parallel R/C pairs, series chains, feedback networks, decouplers, and hierarchy.

 2. Constrained orthogonal placement/refinement
    Encode left-to-right flow, power direction, feedback regions, alignment, escape corridors, crossing/congestion avoidance, and terminal clearance.

 3. Routing-aware local legalization
    Use the existing routing safeguards as final feedback, but unify their objectives rather than accumulating isolated repairs.

 The main omission from my initial list was constrained orthogonal graph drawing. It is more relevant than generic electrostatic or analytic placement because the output goal is a readable schematic, not merely
 short total wirelength.

 The advisor also suggests:
 - use stress majorization only as an optional replacement/refinement for the existing force pass;
 - defer min-cut, generic multilevel coarsening, and simulated annealing;
 - establish benchmark metrics first: fallbacks, crossings, bends, route length, area, motif cohesion, directional violations, and clearance.

 So: semantic topology first, constrained orthogonal refinement second, generic global optimization only where benchmarks prove it helps.


 These three are completely different approches than the ones you shared


 Clarifying advisor categories versus methods

 You’re right. I mixed algorithm families with a recommended architecture, which made the answer sound like three new placement methods.

 The original methods were distinct algorithms:

 - analytic/electrostatic placement,
 - recursive min-cut,
 - multilevel coarsening,
 - simulated annealing,
 - stress majorization,
 - constraint-based placement.

 The advisor’s three items were instead pipeline layers:

 - semantic seeding,
 - constrained refinement,
 - routing-aware repair.

 Those layers can use any of the original algorithms internally. For example:

 - semantic seeding could use recursive partitioning or multilevel coarsening;
 - constrained refinement could use analytic placement, electrostatics, or stress majorization;
 - routing-aware repair could use bounded simulated annealing or deterministic local search.

 A clearer recommendation would be:

 - Best candidate algorithm to evaluate next: stress majorization, replacing/refining the current force-directed phase.
 - Most valuable schematic-specific addition: constraint-based placement.
 - Best scaling/coarse-structure option: multilevel coarsening or recursive partitioning.
 - Useful but likely expensive local optimizer: simulated annealing.

