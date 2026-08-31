# Schematic drawing: where placement and routing fall short, and how to fix it

Notes on the readability ceiling of `src/nimcir/schematic/layout.nim` and the
concrete ways past it. Written against the state after the alignment pass
(`alignAxes`) and the route corner-minimisation pass (`smoothPolylines`) landed
— both help, neither addresses the structural problems below.

The quality bar for this submodule is "readable enough to eyeball" (see
`docs/netlist-converter-research.md`). On a resistor divider or a passive
ladder the current pipeline clears it. On a feedback amplifier — the RIAA
phono channel in `designs/lib/riaa.nim`, instantiated by
`designs/riaa_preamp.nim` — it does not, and the reasons are specific.

---

## 1. What actually goes wrong on `RIAA_CHANNEL`

`RIAA_CHANNEL` is 12 parts: an op-amp box `U1`, an input network (`RL`, `CIN`,
`RB`), a gain leg (`RG`, `CG`), a feedback network (`R7‖C5` in series with
`R8‖C6`), and two rail-decoupling caps (`CD1`, `CD2`). Dumping `layout` on it
shows three distinct failures.

### 1.1 Parallel R‖C pairs are not tight

`R7` and `C5` share **both** their nets (`OUT` and `f1`); so do `R8` and `C6`
(`f1` and `fb`). A parallel pair should render as a tight two-wide stack. The
dump has `R7` at `(240, 360)` and `C5` at `(240, 240)` — the same column, but
**120 world units apart**. `R8`/`C6` are worse: offset `(40, 120)`, i.e. on a
diagonal, co-oriented with nothing.

The cause is the separation pass. It places each part at the nearest 40-grid
cell where `overlapsAny(i, x, y, pos, ohw, ohh, placed)` is false.
`overlapsAny` is a per-axis AABB test — parts `i` and `j` clash iff
`|Δx| < ohw[i]+ohw[j]` **and** `|Δy| < ohh[i]+ohh[j]` — and
`ohw[i] = bodyW/2 + placementPad = 40 + 20`. So any two two-terminal parts must
sit at least `120` apart on their overlapping axis. `R7`↔`C5` are at exactly
`120`: the parallel-attraction spring in the force loop (the term that pulls a
two-net pair side by side) is strictly weaker than this hard floor and cannot
close the gap. `placementPad` exists to guarantee a routing channel between any
two bodies — but a parallel pair connects at both ends directly and **never has
a wire routed between it**, so the channel is wasted space that also breaks the
motif.

### 1.2 Rail-only decoupling caps drift

`CD1` (`VP`/`0`) lands at `(680, 280)`, `CD2` (`VN`/`0`) at `(880, 40)` — far
from `U1`'s `V+` pin at `(400, 324)` and `V-` at `(400, 476)`, which are the
pins they exist to bypass. A decoupling cap works because it is next to the
part it serves; here they are flung across the sheet.

The cause: a cap on `{rail, ground}` has **no attraction at all**. Ground nets
are excluded from the attraction term outright; rail nets pull at weight
`0.35`; and `leafSnap` skips the part because it requires exactly one
non-ground / non-rail net and `CD1` has zero. Nothing holds it anywhere, so it
settles wherever repulsion and the golden-spiral seed leave it.

### 1.3 Routing detours from arbitrary tree attachment

The `fb` net (pins on `U1` `IN-`, `RG`, `R8`, `C6`) routes its trunk as
`(324,420) → (312,420) → (312,292) → (308,292) → (308,200) → (320,200)` — a
three-corner staircase where one clean bend would do. The
`(312,292) → (308,292)` step is a **4-unit jog** that exists only to reach the
`x = 308` line that the `R8` branch attached to.

Two causes compound here:

- **Off-grid vertices.** `buildFreeGrid` builds a Hanan grid from *inflated
  obstacle boundaries* plus signal-terminal escape coordinates —
  `centre ± (bodyHalf + routingClearance)` = `centre ± 52` for a two-terminal
  part. Part centres are on the 40-grid; routing vertices are at
  `40k ± 52`, e.g. `x = 308, 312, 488`. Two wires that should run in one lane
  end up 4 units apart, and `dropCollinear` cannot remove the resulting corners
  because they are real.
- **Nearest-point attachment.** `routeNet` grows the net as a tree, attaching
  each new pin to the closest point already wired. The branch point is wherever
  that happened to be, not a shared trunk line. `smoothPolylines` freezes
  attachment points exactly (it must, to keep the net connected), so it cannot
  undo the jog.

---

## 2. Placement methods

| # | Method | Effort | Payoff |
|---|---|---|---|
| P1 | Recognise motifs (parallel pair, series RC) and place each as one composite body, expand afterward | med | high — fixes §1.1 directly |
| **P2** | **Per-pair separation clearance: bonded pairs may abut** | low | high, simple |
| P3 | Anchor rail-only parts to the part they serve (placement analogue of `leafSnap`) | low | fixes §1.2 |
| **P4** | **Topology-aware seed instead of the golden-angle spiral** | med | high on feedback circuits |
| P5 | Op-amp template: when the sheet has an `opamp` box, place it and its networks by a fixed schema | high | very high where it applies |

P1, P3, P5 are sketched in the table. P2 and P4 in full below.

### P2 — per-pair separation clearance

**Where it lives.** The "separation: inflated bodies never overlap" block in
`layout`, and `overlapsAny` (`layout.nim`).

**The change.** Replace the scalar `ohw[i] + ohw[j]` / `ohh[i] + ohh[j]` in
`overlapsAny` with a `pairClearance(i, j)` — either a callback or a precomputed
`n × n` upper-triangular matrix (cheap at schematic sizes):

- **Bonded pair** → `bodyHalf(i) + bodyHalf(j) + smallGap`, with
  `smallGap = grid/2` (or a few units): the two bodies nearly touch.
- **Everything else** → today's `placementPad`-inflated sum, unchanged.

`overlapsAny` already takes an explicit `against: openArray[int]` so that
`leafSnap` and `alignAxes` can reuse it; adding a clearance parameter is the
same kind of contained signature change.

**Bonded-pair predicate.** Two two-terminal parts are bonded when either:

1. they share **both** their nets — a parallel `R‖C` / `R‖L` / `C‖C`; or
2. a net with **exactly two pins** connects them — a direct series hop with
   nothing to route through the gap.

Both mean no third wire is ever routed between them, which is the only thing
`placementPad` between them buys.

**The caveat that makes or breaks it.** `obstaclesFor` inflates each body by
`routingClearance` for `buildFreeGrid`. If a bonded pair sits at `body + 4`,
their inflated obstacles overlap and `buildFreeGrid` correctly drops the nodes
between them — but a sliver of "free" nodes can still survive at the pair's
outer corners, and Dijkstra will thread a foreign net through it. So P2 is
**two edits**: the clearance callback, *and* merging a bonded pair into one
combined obstacle rectangle in `obstaclesFor`.

**Tuning risk.** Shrinking clearance in a dense region can wall off a channel a
different net wanted. Keep `smallGap` at `grid/2` rather than `0`, and enable
only predicate (1) — parallel motifs — first; predicate (2) is where
through-routing pressure is highest and should come later, behind evidence.

**Interaction with invariants.** The 40-grid centre invariant
(`test_schematic.nim` "every part centre stays on the 40-unit grid") is
untouched — the search still steps by `grid`. The separation guarantee weakens
by design *for bonded pairs only*; the `+2·clear` and `+3·clear` assertions in
"placement never overlaps inflated component bodies" would need a bonded-pair
exception.

### P4 — topology-aware seed

**What it replaces.** The seed is
`pos[i] = (70·sqrt(i+1)·cos(i·2.399963…), … sin …)` — a golden-angle spiral
keyed on array index and nothing else. For a feedback amplifier the force
layout starts from a scramble and has to climb out of a tangled local minimum;
it usually does not fully, which is §1.3's structural half.

**What to compute.** A coarse `(col, row, side)` per part from the *component*
graph — parts adjacent iff they share a **signal** net (exclude ground and
rails or the graph collapses to diameter 1):

1. **Hub** = the part with the most pins, or the first whose `kind` is in
   `{opamp, mcu, transistor, …}`. Ties broken by designator.
2. **Column** = BFS distance from the hub. Hub at column 0.
3. **Side** for a part directly on the hub: read the hub pin it connects
   through — `ptInput → −x`, `ptOutput → +x`, `ptPower → −y`,
   `ptGround → +y`, `ptPassive`/other `→ −x`. Parts farther out inherit their
   BFS parent's side.
4. **Feedback detection** — the rule that un-tangles the RIAA network: a part
   on a net that touches both an output-side hub pin **and** an input-side hub
   pin is feedback → seed it at `(+x/2, −y)`, up and slightly toward the
   output, where a schematic draws the feedback shelf. `R7`, `C5`, `R8`, `C6`
   all match.
5. **Row** = spread parts sharing a `(col, side)` along the secondary axis, in
   designator order.

Convert `(col, row, side)` to world units (`col · 3·grid`, etc.), write it into
`pos[i]`, then run the existing force loop **unchanged** — it now refines a sane
arrangement instead of discovering one.

**Determinism.** BFS in insertion order, designator tie-breaks, no clock, no
RNG — the same guarantees the rest of the module already keeps. The
"layout is deterministic" test still holds.

**Limitations.**

- A sheet with two hubs (a two-stage amp) needs the BFS run per connected
  component, with `groupsOf` / `packGroups` packing the components afterward —
  which they already do.
- A topology with no clear hub (a passive ladder) gets an arbitrary hub, but
  those already lay out acceptably, so a "hub degree below threshold → keep the
  spiral" fallback costs nothing.
- It is a seed, not a constraint: the force loop can still walk a bad case back
  into a tangle. P4 raises the floor; it does not cap the ceiling. That is what
  P5 (a real template) would do.

---

## 3. Routing methods

| # | Method | Effort | Payoff |
|---|---|---|---|
| **R1** | **Bend-penalised path search (turn cost in `dijkstraFromSources`)** | med | highest single routing win |
| **R2** | **Steiner-tree routing: shared trunk + taps instead of nearest-point attachment** | med-high | high |
| R3 | Rip-up and re-route the highest-corner nets with all other final wires as obstacles | low-med | medium, iterative |
| **R4** | **Route on the 40-grid (uniform grid) instead of the obstacle-boundary Hanan grid** | high | biggest readability win; subsumes R1 |
| R5 | Post-route: cluster near-collinear segments sheet-wide, snap each cluster to one coordinate | low | medium |

R1 vs R2, then R4, in full below.

### R1 vs R2 — they change different things and compose

#### R1 — bend-penalised path search (route time, per connection)

`dijkstraFromSources` today has **state = node index** and cost = Manhattan
length. A staircase and a clean L between the same two endpoints cost the same,
so the tie-break (lowest node index; an equal-length relaxation never replaces
a predecessor) picks one arbitrarily.

To charge for corners, the cost of *leaving* a node depends on the direction
you *entered* it, so the **state becomes `(node, entry-direction)`** — each
node splits into up to four states (came-from N/S/E/W). Edge cost = segment
length + `turnPenalty` (≈ `0.5·grid`) whenever the outgoing direction differs
from the entry direction. `pathTo` reconstructs over `(node, dir)` pairs. The
determinism rules are re-stated on the pair: lowest node index, then lowest
direction ordinal.

**Fixes:** every individual pin-to-tree path comes out with the fewest bends
achievable *given its endpoints*.

**Does not fix:** which tree vertex a pin attaches to. The `fb` jog in §1.3
survives R1 — the `R8` branch still attaches at the nearest tree point
(`x = 308`) while the trunk elsewhere is at `x = 312`, and R1 routes the
cleanest possible path *to that slightly-off attachment*.

#### R2 — Steiner-tree routing (topology, per net)

Replace "grow the tree, attach each pin to the nearest wired point" with a
computed shared structure. A full rectilinear Steiner minimal tree is NP-hard;
the **trunk-and-branch heuristic** is enough for the 2–6-pin nets a schematic
has:

1. Pick a trunk line — the **median x** (or y) of the net's pins.
2. Run the trunk along that axis to span the pins' range on the other axis.
3. Drop one perpendicular branch from each pin to the trunk.

Every branch point lands *on the trunk line*, so there are **no jogs**. The
`fb` net becomes one vertical segment at `x ≈ 310` with four clean horizontal
taps. Total corner count drops and the net reads as "a bus with taps", which is
what a schematic should look like.

**Cost:** the trunk can cut through a body. Then either bend the trunk around
it (some cleanliness lost) or fall back to R1 for that net. Obstacle-aware
Steiner is the genuinely hard case; the pragmatic rule is "try the straight
trunk; if it is blocked, hand the net to R1".

#### Composed

R2 chooses the trunk line and the tap points; R1 routes the trunk and each tap
as an obstacle-avoiding, minimal-corner path. On a uniform grid (R4) this stops
being two algorithms and becomes one.

### R4 — route on the 40-grid

**Current state.** `buildFreeGrid` builds a **Hanan grid from inflated obstacle
boundaries and signal-terminal escape coordinates**: collect every `x1,x2` and
`y1,y2` of every obstacle plus every escape-point axis (values like
`40k + 52`), take the full cross product, and drop interior points. Adjacent
visible nodes on each axis are linked; additional collinear links would have
the same Manhattan cost and bend count. Escape points are
`pin ± routingClearance`. **Nothing is on the 40-grid** — typical vertex
x-coords are `308, 312, 488`. Two wires that should share a lane land 4 units
apart, and every route picks up sub-grid jogs `dropCollinear` cannot remove
because they are real corners.

**The change.** Make the routing graph the **uniform 40-grid** (or 20-grid)
clipped to cells outside inflated bodies:

- Nodes at every `(40i, 40j)` in the sheet bounding box not inside an obstacle.
- Escape point = one full grid step out from the pin (`pin ± grid`) onto a
  node.
- Adjacency = **4-neighbour** (to the next non-blocked node up/down/left/right).
  **No all-pairs visibility pass** — Dijkstra / A* handles long straight runs.
  This is *simpler and faster* than the current Hanan construction, not more
  complex.

**Consequences:**

- Every wire vertex is a multiple of the routing grid, exactly like part
  centres. Parallel wires share a lane; collinear runs are genuinely collinear;
  junctions align; `dropCollinear` collapses aggressively; `smoothPolylines`
  becomes largely redundant.
- The bend penalty (R1) is now trivial — on a uniform grid you always know your
  direction — so **R4 subsumes R1**.
- **Clearance must be re-tuned.** A guaranteed-clear 40-grid *column* between
  any two parts needs minimum centre distance `body + 2·grid = 160` (up from
  120), which widens every layout ~33%. The alternative is a **20-grid** for
  routing: the current `120` minimum (→ a 40-unit gap) always contains a
  20-line when centres are on the 40-grid, so sheets do not grow and wires
  still look far cleaner.
- `buildFreeGrid` and the graph-construction half of `routeNet` are rewritten;
  the `routingClearance`-based Hanan logic retires. The occupancy /
  `collinearOverlap` invariant machinery is unchanged.

**Why it is the biggest win and the biggest job.** It is the difference between
"auto-routed" and "hand-drawn", it makes R1 free and R2 clean — but it touches
placement clearance tuning, the free-grid builder, the router, and re-baselines
every coordinate-exact test in `tests/test_schematic.nim`.

---

## Constrained-layered policy (implemented)

`lpConstrainedLayered` is the opt-in general placement policy for these
problems; it does not recognise a particular circuit.  Its semantic layers are
bounded **soft anchors**, not a template: output and declared input-port paths
seed columns, then force placement, legalization and routing remain free to
avoid obstacles.  It ranks deterministic group candidates lexicographically by
power direction, estimated obstacle-aware rectilinear route quality (blocked
L choices, bends, Manhattan length), then seed drift.  Declared ports are
included as candidate endpoints, so input/output interfaces break an otherwise
symmetric passive layout before port bodies are rendered.

Parallel flat two-terminal components are placement/orientation units keyed by
an unordered net pair.  An early composite plan gives every member a canonical,
grid-rounded raw-body-touching offset (the current 80 × 80 passives are 80
units centre-to-centre): `placementPad` is applied only around the unified
external footprint, never between private members. The plan is authoritative
through seed, force, constrained legalization, packing, cleanup, recovery and
routing, so a foreign part cannot split the compact unit and recovery moves it
rigidly. Routing reuses its canonical terminals and unified padded footprint.
Endpoint declaration order is canonicalised by net name and a reversed member
is flipped when necessary, making same-net pins adjacent rather than facing
across the pair. This remains deliberately policy-gated: `lpHistorical`
retains its existing output exactly.

## 4. Recommended sequence

By value-to-risk:

1. **P2 + P3** — small, contained changes that fix the two most visible
   placement defects (loose parallel pairs, drifting decouplers). No invariant
   is lost except the deliberate bonded-pair separation exception.
2. **R1** — bend-penalised routing. Removes staircases sheet-wide and lets most
   of `smoothPolylines` be deleted.
3. **P4** — topology seed. Needed before the force layout can be trusted on any
   circuit with a feedback loop; low risk because the force loop still runs
   unchanged on top of it.
4. **P1** — motif grouping, if pairs are still not tight enough after P2.
5. **R4** — only when the goal is a genuinely hand-drawn look. It is a real
   project: placement tuning, a new router, and a test re-baseline. R2 rides
   along naturally once R4 is in.
