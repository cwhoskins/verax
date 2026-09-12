# Interface-port placement: where it falls short, and how to fix it

Notes on how `src/verax/schematic/` positions the Altium-style interface-port
pennants (`nl.ports` → `SchematicPort`), why the result is often loose or
tangled, and the concrete ways past it. Written against the state after the
`freeGridMargin` change to `buildFreeGrid` (which fixed the strap nets falling
back on `SPI_DEV`) and the reduction of the port collision gap to `1 * grid`.

The quality bar for this submodule is "readable enough to eyeball" (see
`docs/netlist-converter-research.md`). Port placement clears it on a sheet with
two or three ports on separate rows; it does not on a sub-sheet whose whole
interface lands in one edge column (`SPI_DEV`, `spi_daisy_chain`), and the
reasons are specific.

---

## 1. What actually happens today

There is **no port-placement pass**. Ports are positioned inline in
`routeScene` (`routing.nim`, ~lines 163-325), once per routed-scene candidate,
right before the routing grid is built. Three decisions, all local:

### 1.1 Column x is a fixed offset

```nim
let leftColX  = round((pMinX - 2.0 * grid) / grid) * grid
let rightColX = round((pMaxX + 2.0 * grid) / grid) * grid
```

`pMinX`/`pMaxX` are the parts' bounding-box edges. Every left port sits
`2 * grid` left of the leftmost body regardless of what is in that gap; every
right port `2 * grid` right of the rightmost. A tall part next to the column
and a short one leave the same channel.

### 1.2 Column assignment is per-net direction

`toRight = dir in {pdOutput, pdBidir}`, with `dir` from `portDirection(net)`
(pin kind first, then a driver test), overridden to `_in`/`_out` for a
pass-through strap. Inputs and unspecified go left, outputs and bidir go right.
Nothing looks at the whole set of ports together, so a strap whose two
pennants (`sclk_in` on the left, `sclk_out` on the right) should wrap the box
on the *same* side is never told to.

### 1.3 y is a greedy downward stack

Each port's preferred y (`prefY`) is the y of its net's single "best" anchor
pin — the furthest-right pin for a right-column port, furthest-left for a
left-column one. Then:

```nim
col.sort(by prefY, then name)
var yCursor = NegInf
for i in col:
  var y = round(plans[i].prefY / grid) * grid
  if y < yCursor + 1.0 * grid: y = yCursor + 1.0 * grid   # only ever pushes DOWN
  yCursor = y
```

This is the visible defect. A column of ports whose anchor pins are within a
grid step of each other (every pin of a small shift-register box, say) comes
out as a hard-packed run starting at the topmost pin and cascading down past
the box — never centred on the cluster, never spread up. On `SPI_DEV` all six
pennants land inside U1's y-span, `sclk` grabs the only around-the-top track and
`cs` is forced to wrap underneath.

---

## 2. Methods

| # | Method | Effort | Payoff |
|---|---|---|---|
| **1** | **Wire-tension relaxation: pull each port toward its pin(s) (pre-route) then toward its routed wire (post-route), keep a min-gap** | low | fixes the cascade *and*, post-route, the strap climb-out on `SPI_DEV` |
| 2 | Exact 1-D compaction (isotonic regression / PAVA) of a fixed port order | low | provably minimal displacement; deterministic; no routing awareness |
| 3 | Route-aware slot search — a few candidate y per port, re-route, keep best (extend `recoverRouting` to ports) | med | highest quality; picks the strap wrap side correctly |
| 4 | Global column / wrap-side assignment as one small optimisation over all ports | med | coherent strap exits; fewer crossings |
| 5 | Channel-aware column x — put the column in the widest actual whitespace, not a fixed offset | med | guaranteed breakout room without inflating the whole grid |

Method 1 is implemented, pre-route and post-route (§3). The rest are sketched
below.

### 1 — wire-tension relaxation *(implemented)*

Model each port as a bead constrained to its edge column, free to move only in
y. Two forces:

- **Tension** — a spring pulling the port toward its target y. Pre-route, the
  target is a pin coordinate (the anchor pin today, or the barycentre of all
  the net's on-sheet pins). The port is a wire end under tension; it wants to
  be level with what it connects to.
- **Collision** — ports in one column may not come closer than `portMinGap`
  (`1 * grid`, one body height plus a hair).

Solve to equilibrium with a fixed number of relaxation sweeps: a spring step,
then a symmetric forward/backward min-gap projection. Equal spring stiffness
means a jammed column settles with its centroid on the mean of the targets and
every gap exactly `portMinGap` — the cluster is *centred*, not cascaded. A
column with room to spare leaves every port exactly on its target, so a sheet
that has no port collision today is unchanged.

**Determinism.** Fixed sweep count, fixed column order (target y, then name),
no clock, no RNG — the guarantees the rest of the module keeps.

**Limitations.** It moves ports only in y and only within their assigned
column — it cannot fix 1.2 (wrap side) or 1.1 (column x). It is a floor-raiser,
like the placement seed: a genuinely over-full column still packs tight, just
symmetrically. And it is a no-op on `SPI_DEV`, because that sheet's anchor pins
already sit a grid apart around y = 0 — the artifact it removes only shows when
a cluster is off-centre. `SPI_DEV` needs the *post-route* form (§3).

### 2 — exact 1-D compaction

Split "what order are the ports in" from "what exact y". Order: sort by target
y. Position: solve "place ordered points on a line, each near its target, with
minimum separation g" exactly with pool-adjacent-violators, O(n). This is the
provably minimal total squared displacement for that order — the same fixed
point method 1 relaxes toward, reached directly. Deterministic, trivial, no
routing awareness. Method 1 is preferred only because the post-route variant
needs the iterative form.

### 3 — route-aware slot search

Give each port a tiny candidate set — target y, ±grid, ±2·grid,
top-of-column, bottom-of-column — re-run the router per combination, score on
fallbacks + wirelength + crossings, keep the best. `recoverRouting` already
does exactly this for parts; ports are cheaper because the move is 1-D. It
picks the strap wrap side as a side effect: a strap is two ports, and the
search can independently send one high and one low, or both to one side.
Cost is combinatorial — cap the candidate set hard and order ports
most-constrained first.

### 4 — global column / wrap-side assignment

`portDirection` decides a port's column one net at a time. Replace it with a
joint assignment: minimise total crossings + vertical travel across all ports
at once, as a small partition / 2-colouring. A strap (a net with two ports)
then exits both pennants on a coherent side instead of `sclk` taking the top
and forcing `cs` under.

### 5 — channel-aware column x

Compute the column x from the widest vertical whitespace channel outside the
part cluster rather than a fixed `2 * grid`. Every port then has guaranteed
breakout room, which removes the "not enough horizontal space between the ports
and the box to break out vertically" failure — without the global grid
inflation that `freeGridMargin` introduced. Places nothing in y; pairs with
1–4.

---

## 3. What is implemented

### Method 1 — pre-route relaxation

In `routeScene` (`routing.nim`), replacing the `yCursor` greedy stack.
Constants in `geometry.nim`: `portMinGap` (the collision distance, `1 * grid`),
`portSpringIters` (relaxation sweeps), `portSpringRate` (per-sweep fraction
moved toward target). The spring target is the single anchor pin — the
barycentre refinement is still open.

### Method 1 — post-route pass *(the SPI_DEV fix)*

`refinePortPlacement` (`refinement.nim`), pipeline stage `lsPortRefine`
(between `lsRoutingAwareRepair` and `lsLabels`, on by default). After routing,
for each ported net it reads the y its wire spends the most horizontal length
on — the track tension is pulling the ports onto — sets **every** port on that
net to that y via `LayoutState.portY` (a spring-target override, so the column
min-gap still holds), and re-routes. The move commits only when the fresh scene
scores strictly better: fewer fallbacks, then fewer bends (`wireBends`), then
less total length (`betterThan`). So the pass can never make a sheet worse than
Method 1 alone. Bounded by `portRefineRounds` (2) sweeps and
`portRefineMaxAttempts` (24) re-routes; the same `4 * feedbackMaxParts` raw
ceiling `recoverRouting` uses gates it off on large sheets. Column and x are
never touched.

`SPI_DEV`, measured (`layout(spiDev())`):

| | Method 1 only | + post-route |
|---|---|---|
| total wire bends | 8 | **4** |
| total wire length | 1592 | **1232** |
| fallbacks | 0 | 0 |
| `sclk_in`/`sclk_out` y | −40 | **−160** (onto the over-the-top run) |
| `cs_in`/`cs_out` y | 0 | **+200** (onto the under-the-box run) |

Each strap wire becomes one straight run at the port y plus a single 2-bend tap
down to U1.

Port-refine's re-routes already broke the old `lpHistorical` policy's
byte-identical guarantee for schematic port coordinates before that policy
was retired outright (`lpConstrainedLayered` is now the only, default,
policy); coordinate-exact tests in `tests/test_schematic.nim` were
re-baselined both times.

**Still open**: the target is the longest horizontal run, not a true wire
attach point, and there is no per-bend force in the target selection itself
(only in the accept score). A strap still wraps opposite sides (`sclk` over,
`cs` under) — that is Method 4, not this.

## 4. Recommended sequence

1. **Method 1, both forms** — done.
2. **Method 5** — column x from real whitespace. Independent of 1, removes a
   distinct failure, lets `freeGridMargin` shrink again.
3. **Method 4** — wrap-side / column assignment. Needed before a strap-heavy
   sub-sheet reads cleanly.
4. **Method 3** — route-aware slot search, once 1/4/5 have raised the floor and
   the remaining cases are worth a per-candidate route. The post-route pass is
   already a narrow instance of this (y candidates from the wire, full re-route,
   score); generalising it means adding ±grid slots and a crossing term.
