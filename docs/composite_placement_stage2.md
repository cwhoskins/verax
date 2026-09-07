# Composite placement, Stage 2: remaining work

Stage 1 (see `schematic_drawing_improvements.md` and `composites/composite.nim`'s
`CompositeKind`/`PlaceableItem` arena) made composite types registrable and
gave routing/placement a uniform arena to read, at strictly equivalent
behavior to the pre-registry code. Stage 2's goal is different in kind: make
composites actually **reduce placement cost**, not just routing endpoints —
and, the requirement that motivated it, let a sheet whose raw part count
exceeds the place-and-route thresholds still run when composites genuinely
collapse it below them. This file is the status and the reasoning for
whoever picks Stage 2 back up.

## Done: 2.1 + 2.2

`forcePlace`'s repulsion term and `separate`'s legalization search in
`src/verax/schematic/state.nim` now operate over `placementPool(state)` — one
entry per top-level arena item (`state.composites.topLevel` under
`lpConstrainedLayered`, one entry per raw component under `lpHistorical`) —
via three new helpers: `placementPool`, `poolMembers`/`poolOffsets` (thin
wrappers over `rawMembers`/`rawOffsets` that degrade to `@[item]`/`@[Point()]`
under historical, where `state.composites` is never built), and `poolOrigin`
(a pool item's representative position: the mean of its members' implied
origins, the same computation `restoreCompositeOffsets` already used).

`forcePlace`'s repulsion loop is now pairwise over pool items, not raw
components: two composites repel once, from their origins, broadcasting the
one resulting force to every member — not once per raw-member pair. This is
the real O(n²) → O(poolLen²) win, since it runs fresh on every one of 250
iterations. Everything else in `forcePlace` (pin-to-pin attraction, the
semantic-anchor term, the mean-force rigidity pass, `restoreCompositeOffsets`)
is untouched — attraction in particular is **deliberately** still O(raw pins²);
see "What Stage 2.3 is for" below.

`separate`'s constrained branch now iterates `placementPool(state)` directly
instead of every raw index with a skip-if-not-first-member guard. This one is
a pure simplification: the item processed and the order processed are
unchanged (proved by the oracle diff showing zero difference for constrained
too, not just historical), since `placementPool` under this policy *is*
`state.composites.topLevel`, built from the same `parallelRecognize` interleave
the raw-index scan implicitly walked.

**Why `lpHistorical` is provably untouched**: under historical, `placementPool`
returns `0 ..< comps.len` and `poolMembers`/`poolOffsets` return `@[item]`/
`@[Point()]` for every item — so every pool-based loop reduces to its
pre-Stage-2 raw-indexed form, same order, same arithmetic, same floating-point
summation order. Verified by SHA-256 diff against the Stage 1 baseline across
all 34 `designs/`+`templates/` files, both policies (68 runs, 260 archive
files) — zero differences, for *both* policies. That last part means the
existing corpus doesn't stress composites enough to show Stage 2's effect at
all; see the synthetic benchmark below for real signal.

### Empirical result (synthetic 90-part / 30-composite-pair sheet)

Nothing in `designs/`/`templates/` has enough parallel-composite mass to
exercise this path, so a purpose-built stress netlist (a chain of 30
resistor+capacitor parallel pairs, each pair's node also carrying a grounded
leg — see the throwaway harness described below to reconstruct it) was used to
get real numbers:

| | Stage 1 | Stage 2 (2.1+2.2) | Δ |
|---|---|---|---|
| `layout()` wall time | 63.9s | 56.5s | −12% |
| total wire length | 19160 | 17844 | −7% (better) |
| bounds area | 6.76M | 5.65M | −16% (better) |
| total bends | 319 | 365 | **+14% (worse)** |
| fallbacks | 2 | 2 | unchanged |
| raw-body overlaps / idempotence | none / holds | none / holds | unchanged |

Two honest takeaways:

1. **The wall-clock win is real but smaller than hoped**, because
   `recoverRouting`'s per-candidate-move cost (`constrainedAnchors` →
   `constrainedTargets`, still O(raw parts) — see 2.3) and the attraction term
   dominate more than repulsion did on this topology. Repulsion was the single
   most expensive *individual* computation (O(n²) × 250 iterations), but it
   was never the *only* O(n²)-or-worse cost in the pipeline.
2. **Bends got worse.** Pool-level repulsion produces a different force
   equilibrium than per-member repulsion (summing one force between two
   origins is not the same as summing every member-pair force, even though
   both are "physically reasonable"), and this particular synthetic layout
   settled into a geometry with more bends despite less total wire length and
   a smaller bounding box. This is a tradeoff, not a bug — but it is a data
   point against assuming pool-level force placement is strictly better on
   every sheet, and worth re-checking once 2.3 is done and a wider stress
   corpus exists.

## Done: 2.3 + 2.4 + 2.5

### 2.3 — `constrainedTargets`/`constrainedTopology` over the pool

`CompositePlan` gained `poolOf: seq[int]` — raw index -> that raw component's
*position in* `topLevel`, not the arena index `ownerOf` already gave.
Everything else in 2.3 is `poolOf` threaded through the three functions that
used to reason in raw indices:

- **`pathsFrom`** takes `plan`; its `seen`/`skip` set moved from raw index to
  pool position, and a net-local `visitedHere` set takes only the first raw
  candidate per pool position before recursing. Before this, a net shared by
  both members of a recognized parallel pair offered two distinct next-hop
  candidates (R and C both lead to the same next net), so a chain of N such
  pairs walked as 2^N raw-index paths — every one of them duplicate once the
  pair is one placement unit. `TraversedPath` still carries raw indices; the
  mapping through `poolOf` happens once, in `constrainedTopology`.
- **`constrainedTopology`** still *discovers* arcs on raw indices (real pins,
  real nets), then maps every arc — ordinary, feedback, same-column alike —
  through `poolOf` in one place, keeping only `poolOf[src] < poolOf[dst]` and
  deduplicating via a `HashSet` used for membership only (never iterated, per
  this submodule's determinism rule). Contracting a DAG can reintroduce a
  cycle (two raw arcs between different members of the same two composites
  can point opposite ways once both ends collapse to one pool position each),
  so this is the same deterministic insertion-order cycle break one level up,
  not a restatement of the raw one. `layers`/`sameColumn` are now sized and
  indexed by pool position (`plan.topLevel.len`, not `comps.len`), so a
  composite's members share a layer *by construction* — the post-hoc `max`
  the old `constrainedTargets` used to reconcile per-member layers is gone
  because there is only one layer value per composite to begin with.
- **`constrainedTargets`** deleted its own `parallelRecognize(comps, syms)` call;
  groups come from `rawMembers(plan, plan.topLevel[g])` and `groupOfPart` is
  `plan.poolOf`. A composite is placed as **one packed body**: the unit
  origin goes at the stage slot and each member sits at
  `origin + rawOffsets(plan, idx)[at]` — the same canonical
  raw-body-touching offsets `restoreCompositeOffsets` re-rigidifies around
  afterward — instead of stacking members `constrainedParallelPitch` (120)
  apart and letting the later re-rigidify pass collapse that to the real
  80-unit gap around the mean of the implied origins. Centring now tracks
  `minY` as well as `maxY` (member offsets are signed), shifting by
  `(minY + maxY) / 2`; for an all-singleton sheet every offset is 0, so this
  is exactly the historical `maxY / 2`. `constrainedParallelPitch` is dead
  and removed.

**Why a composite-free sheet is provably unchanged**: `poolOf` is the identity
permutation when `compositePlan` recognizes no multi-member group (`topLevel`
is the ascending singleton list), every member offset is `Point()`, and
`minY` is then always 0 — so every pool-indexed loop above reduces to its
pre-2.3 raw-indexed form, bit-for-bit. Confirmed by the SHA-256 capture below:
zero differences on every composite-free sheet, both policies.

### 2.4 — `recoverRouting`'s gate is pool-sized, with a raw ceiling

`routing.nim`'s `comps.len > options.feedbackMaxParts` bail became:

```nim
let poolLen = if constrained: composites.topLevel.len else: comps.len
if poolLen > options.feedbackMaxParts or
   comps.len > 4 * options.feedbackMaxParts:
  return routeScene(..., withFallbacks = true, ...)
```

Under `lpHistorical`, `poolLen` is `comps.len` and the raw ceiling (96) sits
strictly above the historical one (24), so it cannot bind first — the branch
fires on exactly the same sheets as before. Recorded honestly in the code:
what this does *not* pool-size is `constrainedRecomputeRotations`, which still
rebuilds `pinWorldPositions` from every raw component per candidate, and
`constrainedRouteScore` inside it, still O(raw pins · raw comps) — that
residual raw cost is precisely why the `4 * feedbackMaxParts` raw ceiling
above is not optional once the pool gate is loosened.

### 2.5 — pool-based `constrainedMaxParts` + the secondary raw ceiling

The three copies of `comps.len <= constrainedMaxParts` in `constrainedTargets`,
`constrainedSemanticSeed` and `constrainedAnchors` became one shared
predicate:

```nim
const
  constrainedMaxParts    = 64
  constrainedMaxRawParts = 4 * constrainedMaxParts   # 256

proc constrainedEligible(comps: seq[Component], plan: CompositePlan): bool =
  comps.len > 0 and plan.topLevel.len <= constrainedMaxParts and
    comps.len <= constrainedMaxRawParts
```

This is the threshold the original request was actually about: a sheet whose
raw part count exceeds 64 but whose composite-collapsed pool does not now
still gets the constrained treatment, gated on the *pool* count that 2.3 made
the actual cost driver, with a raw ceiling (256, four times the old all-raw
limit) so a large raw sheet cannot ride in just because pooling looks
favorable on paper — the O(pool · arcs) relaxation and per-`recoverRouting`-
candidate `constrainedRouteScore` are still raw-sized per arc/pin underneath.

### Acceptance test

`tests/test_schematic.nim`, `"constrained layering admits a raw-over-gate
sheet whose pool clears it"`: 33 parallel R‖C pairs in series, an `mcu` output
driving the first net and an `mcu` input reading the last — 68 raw parts (over
`constrainedMaxParts` (64) by raw count alone) and 35 pool items (under it).
It asserts `U1.x < U2.x`, each pair co-columnar, a wide-short bounding box (the
layered treatment's signature, which the ungrouped golden-spiral seed a
raw-count-only gate would have fallen back to does not produce), the two
collinear/separation routing invariants, and `layout(...) == layout(...)`.
`lsRecoverRouting`/`lsRoutingAwareRepair` are excluded so it measures
placement, not the feedback loop. Measured on the development machine (debug
build): ~1.9 s — felt, but far below the ~16 s `resistorChain(37)` already
costs elsewhere in the same file under the historical policy.

A companion test, `"constrained layering falls back cleanly once the pool
itself exceeds the gate"`, uses 63 pairs (pool 65, one over the gate even
after collapsing every composite) and asserts nothing beyond `layout`
producing a scene with the expected part count — the point is that the
over-pool path still degrades to "lays out", not that it looks like the
eligible case. Measured: ~10.3 s with force placement, packing, terminal
repair and leaf-snap also excluded (irrelevant to what this test checks, and
expensive at 128 raw parts); this is a gate smoke test, not a
placement-quality test, so it is kept deliberately minimal.

### SHA-256 capture (subset scope)

Full-corpus capture (all of `designs/`+`templates/`, both policies) is what
Stage 1's baseline used; Stage 2.3 instead captured a **targeted subset**,
chosen after a throwaway harness classified every design/template sheet as
composite-bearing or composite-free (any two flat two-terminal parts sharing
an unordered net pair) from its historical archive's JSON. 34 of the 48
sheets surveyed bear at least one composite — the corpus turned out far
denser in composite structure than Stage 1's "near-zero composite density"
survey suggested, because that survey predates decoupling-cap-heavy designs
like `xbar_rf`/`sensor_node` being added. The captured subset: `aa_filter`,
`lt8640a_buck`, `riaa_preamp` (root + `RIAA_CHANNEL`), `sensor_head`,
`gain_stage`, `sallen_key`, `oscillator` (composite-bearing) plus `divider`,
`i2c`, `subcircuit` (root + `REFDIV`, composite-free controls) — chosen for
size (seconds, not the 4-6 minutes each of `xbar_rf`/`xbar_switch`/
`xbar_control`/`xbar_poe`/`xbar_power`/`xbar_usbc` costs per single
`bin/verax check` invocation) while still spanning both root and subcircuit
sheets, both design and template files, and collapse ratios from mild
(`RIAA_CHANNEL`'s 12 raw -> 10 pool, ~83%) to total (`sensor_head`'s 5 raw
parts -> 1 pool item).
The larger `xbar_*` sheets were not captured here; they exercise the same
mechanism at larger scale, and the synthetic stress benchmark below is the
real scaling signal regardless.

Result, `bin/verax check <design> --schematic-only --keep-runs=DIR` before
(this repo's prior commit) vs after, both policies:

- **`historical`**: zero differences, every sheet in the subset — expected
  structurally (`lpConstrainedLayered`'s code paths are the only ones 2.3
  touched) and confirmed empirically.
- **`constrained-layered`, composite-free controls** (`divider`, `i2c`,
  `subcircuit` + `REFDIV`): zero differences — the identity-`poolOf` argument
  above, holding in practice.
- **`constrained-layered`, composite-bearing sheets**: all except
  `sensor_head` differ. Spot-checked on `riaa_preamp`'s root sheet: `C1`,
  `C2`, `V1`, `V2` and the two `XL`/`XR` subcircuit instances all move to new
  (still grid-snapped) centres, while wire count (14) and fallback count (4)
  are unchanged before and after — the difference is placement, not a routing
  regression, exactly the "packed-unit seed, not a behavior change" effect
  2.3's design predicts.
- **`sensor_head` is the one composite-bearing exception, and it is
  explainable**: its one composite is *every* raw part on the sheet (5 raw ->
  1 pool item — the whole circuit is one parallel group). With only one pool
  item, there is nothing else on the sheet to place it relative to: the old
  stack-then-recentre seed and the new pack-then-recentre seed are each
  linear, symmetric arrangements centred on zero (just at different member
  spacing), so `restoreCompositeOffsets`'s origin recovery
  (`mean(pos[i] - offsets[i])`) is a difference-of-symmetric-sequences and
  collapses to the same value either way, and force placement of a single
  item (nothing to repel or attract against) converges to the same fixed
  point regardless. `system_sensor_rig.SENSOR_HEAD` (4 raw -> 1 pool) shows
  the identical pattern.

### 2.3 row of the synthetic benchmark

Re-run on the same synthetic sheet (30 R‖C parallel pairs in series, each
pair's destination node also carrying a grounded resistor leg — 90 raw parts,
30 composite pool items), reconstructed as a throwaway harness since no
version of it is committed; the reconstruction was checked against the
existing table row before trusting it for a new one; `wire_length` (17844)
and `bends` (365, counted as points beyond the two endpoints per wire, not
direction changes) landed on the pre-existing 2.1+2.2 numbers exactly, and
`bounds_area` matched once it read `Schematic.minX/minY/maxX/maxY` — the
labels/junctions/50-unit-pad-inflated bounding box `finishBounds` actually
computes — instead of a bare min/max over part bodies:

| | Stage 2 (2.1+2.2) | Stage 2.3 | Δ |
|---|---|---|---|
| `layout()` wall time | 54.2s | 41.8s | −23% |
| total wire length | 17844 | 16408 | −8% (better) |
| bounds area | 5.65M | 5.57M | −1% (better) |
| total bends | 365 | 268 | −27% (better) |
| fallbacks | 2 | 2 | unchanged |
| idempotence (`layout()` called twice) | holds | holds | unchanged |

Every column moved the right way, unlike 2.1+2.2's mixed result (which traded
worse bends for a wall-clock and area win). The reason is structural, not
tuning: 2.1/2.2 only cheapened *repulsion*'s cost, so `recoverRouting`'s
per-candidate `constrainedAnchors` → `constrainedTargets` call — still
O(raw parts · arcs) at the time — and the raw-sized pin-to-pin attraction term
still dominated. 2.3 cheapens (and, via one-step packing instead of
stack-then-rerigidify, *changes the seed of*) exactly that semantic-layering
path, so the wall-clock win compounds with a genuinely different, and on this
topology strictly better, converged geometry — fewer bends and less wire from
a better starting point for the same force solve, not merely a faster path to
the same one.

### 2.6 — a second `CompositeKind`

**Partly done.** `piKind` and `teeKind` (`schematic/composites/pi.nim`,
`tee.nim`) are now registered after `parallelStackKind` — the two passive
filter sections from `docs/composites.md` (ideas 3, and 2). `seriesChainKind`
(`passive.nim`) followed as the fourth kind under the same non-nesting fold —
`docs/composites.md` idea 1, flat two-terminal passive parts wired end to end
through private two-pin link nets, registered last so a pi/tee series leg that
also reads as a chain link keeps the filter drawing. `compositePlan`
gained a **non-nesting fold**: it keeps each kind's multi-member groups in
registration order, drops any whose members an earlier kind already claimed,
then lays the survivors plus unclaimed singletons into `topLevel` in ascending
first-raw-member order. A seventh hook, `footprint`, was added so the pi (whose
series pins are interior to the members' bounding box) can reserve the member
bodies individually while the parallel stack and tee keep the bounding box.
`routing.fullyInternalComposite` lets a signal net every pin of which is
covered by one composite port (the tee's private mid) skip external routing
and be drawn by `compositeInternalRoutes` alone. `isTraversable` and
`pathsFrom` gained `onThisSheet`: a **global** net (`"0"`, a `global = true`
rail) keeps `.netlist` pointing at the root even in a cloned child sheet, and
the old bare `net.netlist == nl` test rejected the child sheet's own
ground-connected passives — so the pi section in `RIAA_CHANNEL` (`RL`/`CIN`/
`RB`) was not recognized when `keepFullSchematic` drew the instance's clone,
and its parts scattered. `onThisSheet` accepts a net owned by `nl` or the
identical object in `nl.nets` (which a sibling's private net never is).
Verified against the full
`nimble test` + `nimble verify` corpus (default historical policy unaffected
— it never builds the plan; constrained-layered tests unchanged — no design
carries a pi/tee shape) plus dedicated `tests/test_schematic.nim` cases.

**Still out of scope:** a *nesting* kind — one that consumes an earlier
composite as one of its own members (the original op-amp inverting-amplifier /
parallel-passive-feedback example). That needs the arena-index fold over the
pool an earlier kind's `topLevel` leaves behind, and it would be the first
real exercise of `rawMembers`/`rawOffsets`'s recursion past depth 1. pi/tee
and the series chain did not need it (their members are always raw flat
two-terminal singletons); a series-of-parallel-pairs is the same still-open
case from the passive side.

### 2.7 — unit orientation

**Done.** A singleton square two-terminal part gets a genuine four-way
rotation search (`bestRotation`: power direction, then pin-to-pin wirelength,
then smaller angle). A recognized composite lost it — three of the four
motifs' `rotationCandidates` returned exactly one canonical assignment, the
fourth (parallel stack) only a 0/180 flip of a permanently horizontal axis —
so a chain that reads naturally as a vertical column was forced into a
horizontal row with long wires at both ends. The fix could not live in
`rotationCandidates`: the spatial arrangement is in `internalLayout`, whose
offsets are re-imposed by `restoreCompositeOffsets` after every stage, so
emitting 90/270 member angles would turn each body in place while leaving the
unit strung along the same axis.

- `CompositeKind.orientable` (`bool`) and `PlaceableItem.unitRot` (`float`,
  one of 0/90/180/270) are the only new state. `orientable` is `true` for the
  parallel stack and the series chain, `false` for the pi and the tee — their
  shunt legs run to ground and ground-points-down is a real convention, not a
  wirelength trade. A pinned kind keeps `unitRot == 0` and its output is
  byte-identical.
- `internalLayout` still authors one canonical frame. `canonicalOffsets`
  returns it untouched; `rawOffsets` returns it turned by `unitRot`
  (`rotatedSlot`, which keeps grid-multiples on the grid). Every position
  consumer already goes through `rawOffsets` or through `pos`, so the turn
  composes for free. `constrainedRecomputeRotations` adds `unitRot` onto every
  member angle each `rotationCandidates` hook returns.
- **Two-stage decision.** `lsCompositeOrient` (new stage, between
  `lsConstrainedRefinement` and `lsSeparate`) picks each orientable unit's
  frame *before* `snapToGrid`/`separate`/`pack`. The trial pin-world turns the
  whole unit, so a rigid rotation leaves every internal pin-pin distance fixed
  and only the members' reach to their *external* net-mates moves the score.
  What leads that score depends on `unitExternallyPurePower`: a unit whose
  every external net is a rail or ground (a rail-to-rail divider, a decoupling
  bank) is scored `powerRank` first, then `rotationScore`, then smaller angle
  — it stands up to its planes ground-down for free. A unit with any external
  signal net is scored on `rotationScore` alone, and turns off its canonical
  frame only when the win clears `compositeFrameHysteresis` (`2 * grid`) —
  never merely to point one ground leg down, and never for a marginal
  wirelength gain (both misfires drag a settled sheet: the first put
  `pi_filter`'s RL/RT load divider off its row, and small churn like it
  displaces neighbours the separator then packs around — see
  `docs/findings.md` #29). Because the stage runs before legalization,
  separation packs whatever frame it picked and a turned unit can never
  overlap; the flip side is that turning a unit reshapes it for the separator,
  so the same hysteresis applies to `revisitCompositeFrames`' length term. The definitive orient pass
  then calls `revisitCompositeFrames`: with centres settled, retry all four
  frames scored by `constrainedRouteScore` (hits → bends → length; drift is
  left out so pure anchor drift never churns a frame), rejecting any frame
  whose turned member raw bodies overlap a foreign part — the same test
  `recoverRouting` uses. On a dense sheet the incumbent frame stands; only
  where there is room does the route score improve it. Both stages leave the
  geometry untouched when the chosen frame equals the current one:
  `restoreCompositeOffsets` recentres on the grid, so re-laying for no reason
  nudges an already-legal unit. Both are also skipped entirely on a sheet
  `constrainedEligible` declined — its O(pool · routeScore) cost is only
  bounded under that gate, and a golden-spiral fallback sheet has no frame
  worth refining. `powerRank` leading the pure-power path means a chain or
  bank with a ground/rail member still lands ground-down with no motif rule.
- **`recoverRouting` deliberately does not re-search the frame.** It calls
  `constrainedRecomputeRotations` once per attempted candidate cell; a
  four-frame re-search there multiplies an already-budgeted loop by four. It
  passes the stored plan through, so a moved candidate still *respects* the
  committed `unitRot` (angles compose), it just does not revisit it. A
  per-attempt frame search inside the feedback loop is the open follow-up.
- **Known asymmetry left in place.** `constrainedTargets` centres the sheet on
  `(minY + maxY) / 2` but derives `xShift` from the column count with no
  member-extent term. A turned unit's offsets are now signed in x too, so its
  x-extent is uncentred — but this only feeds the *soft* anchor set (the
  `drift` tie-break), and an `xShift` with a `minX`/`maxX` term would move
  every composite-free constrained sheet. `constrainedTargets` also runs as
  the seed, before `lsCompositeOrient`, where every `unitRot` is still 0, so
  the seed is bit-for-bit unchanged.
- `parallelInternalRoute` was the one motif body that hardcoded the stacking
  axis (trunk sorted by y, taps horizontal); it now reads the axis from the
  covered-pin spread. `seriesInternalRoute` already emitted an L that
  degenerates correctly for a vertical row and needed no change.

## Verification method, for whoever continues this

There are no golden/snapshot files anywhere in this repo (confirmed by
survey before Stage 1). "Byte-identical" can only be proved by capturing
SHA-256 sums of the `--schematic-only --keep-runs=DIR` archive
(`runFULL.svg`/`.json`/`.html` per design) across `designs/*.nim` and
`templates/*.nim`, for both `--schematic-layout=historical` and
`constrained-layered`, before and after a change, then diffing. This is slow
(the corpus takes several minutes per full pass) and **must run with no
concurrent edits to `src/`** — `bin/verax check` recompiles against the live
on-disk source per invocation, so editing mid-capture silently corrupts the
baseline (this happened once during Stage 1 and was caught by the corpus
shrinking from 260 to 206 archive files).

Because the existing corpus has near-zero composite density, any Stage 2 step
touching `forcePlace`/`separate`/`constrainedTargets` needs a synthetic
stress netlist to get a real before/after signal — a chain of N parallel
resistor+capacitor pairs (grounded on each junction) is enough; the harness
used for the table above just calls `layout()` once for timing, once again to
check `==` for idempotence, and counts `scene.fallbacks.len`, total polyline
length, total bend count (points beyond the two endpoints, per wire), and
bounding-box area from the returned `Schematic`. Route around
`refinement.nim`'s `refineRouting`, which `echo`s per net on every `layout()`
call (still present, still unrelated to this work, still worth removing
separately) — redirect stdout or write results straight to a file rather than
relying on `echo` for a timed measurement.
