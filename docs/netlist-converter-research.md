# Netlist → schematic: research notes on a reference visualizer

Notes on `~/Downloads/netlist_converter.html` — a single-file browser app that
turns a SPICE-style netlist into a schematic — and how its ideas map onto
verax. Phase I (flat scene → self-contained SVG, plus a public JSON API) is
implemented in `src/verax/schematic/`; Phase II (hierarchical HTML renderer,
below) is not.

**What it is:** a heuristic visualizer. You paste a netlist (one component per
line, `Ref node1 node2 … value`) into a textarea, press *Render*, and get a
schematic as SVG, with drag-to-rearrange and hover-a-net-to-trace. It exists to
let a person *eyeball* topology and connectivity.

**What it is not:** a SPICE parser, a simulator, or an EDA tool. It ignores
directives, drops `KEY=value` parameters, understands eight device letters with
at most three terminals, and never interprets a value. It does no DRC, no
simulation, no BoM, and cannot write a netlist back out. It is a rendering aid.

---

## The pipeline

The app splits itself cleanly: **pure modules** (`parse · place · route`)
compute a model, and **DOM code** (`render · interact`) draws and edits it.

```
parse ──► place ──► route ──► render ──► interact
 netlist    x,y,rot    wires,     SVG       drag / hover /
 + nets     on a grid   junctions            zoom / export
```

### 1. Parse

Line-oriented and deliberately shallow:

- strip a `;` comment, skip blank lines and lines starting with `*` or `#`;
- skip SPICE directives (lines starting with `.`);
- split on whitespace; the first token is the reference designator and its
  first letter selects the device type;
- the next `n` tokens are node names; the remainder is the value, with
  `KEY=value` pairs filtered out;
- collect errors (unknown letter, duplicate designator, too few nodes) rather
  than aborting;
- build a `nets` map: net name → list of `(componentId, pin)`.

### 2. Place

Force-directed, not schematic-quality:

- seed components on a golden-angle spiral so nothing starts coincident;
- iterate ~400 steps with cooling: pairwise repulsion (inverse distance), an
  attraction pulling each component toward the centroid of its net-mates
  (ground nets excluded; power nets weaker), and a gentle gravity to origin;
- then pick an orientation per two-terminal part by where each pin "wants" to
  point — ground pins downward, supply pins upward, everything else toward the
  centroid of the other parts on that net; three-terminal parts keep a fixed
  orientation;
- finally snap centres to a grid and run declump passes.

### 3. Route

Per net, over the placed pin positions:

- **ground / power nets** are not wired: each pin gets a local ground or supply
  symbol drawn outward from it;
- a **single dangling pin** just gets a net label;
- otherwise build an orthogonal **minimum spanning tree** (Prim, Manhattan
  distance) over the pins, route each tree edge as an L-bend that picks the
  bend avoiding other pins, and drop a **junction dot** wherever three or more
  segments meet;
- one net label near the leftmost-top pin when the net name is alphabetic.

### 4. Render and interact

Rendering is plain SVG with a graph-paper grid: wires as polylines, junction
circles, ground/power symbols, net labels, and a small symbol library (US
resistor zigzag, capacitor plates, inductor arcs, voltage/current-source
circles, diode triangle+bar, BJT/MOSFET bodies). Component labels are
counter-rotated so they stay upright. Interaction is fit/zoom/pan, drag a part
(which re-routes live), hover a net to highlight every segment of it, and
export a self-contained SVG with CSS colours resolved to literals.

---

## Supported elements

| letters | terminals | drawn as |
| --- | --- | --- |
| `R`, `C`, `L` | 2 | resistor zigzag, capacitor plates, inductor arcs |
| `V`, `I` | 2 | circle (V with `+`/`−`, I with an arrow) |
| `D` | 2 | triangle + bar |
| `Q`, `M` | 3 | transistor body; pins fixed as collector/drain top, base/gate left, emitter/source bottom |

Anything else is a parse error. Ground is recognised by name (`0`, `gnd`,
`vss`, `agnd`, `dgnd`, …) and supplies by a name regex; both are guesses.

---

## Key heuristics and limitations

- **Not a parser.** No `.subckt`/`.ends` hierarchy, no `.model`, no
  continuation lines (`+`), no expressions or behavioural sources; `KEY=value`
  parameters are silently dropped; the value string is displayed verbatim and
  never interpreted as a SPICE magnitude.
- **Name-based rail detection.** Ground/power is a hardcoded name list plus a
  regex, with no concept of annotation — a net like `GND_ANALOG` or `VREF` is
  simply misclassified.
- **Heuristic placement.** A physical spring/repulsion simulation, so there is
  no left-to-right signal flow, no hierarchical sheets, no port ordering; large
  circuits can end up clumped or tangled.
- **Heuristic routing.** L-bends with only pin-crossing avoidance — no
  obstacle avoidance beyond pins, no channel routing, no crossing minimisation,
  no buses.
- **Fixed symbols.** Three-terminal parts never rotate, the transistor arrow is
  NPN-only, and two-terminal orientation is a guess.
- **No EDA semantics.** No simulation, DRC, BoM, annotations, or netlist
  round-trip. It is a visualizer, and the honest quality bar is "readable enough
  to eyeball", not "publication-grade schematic".

---

## What carries over to verax

Two ideas are worth keeping, and one of them verax already does better.

**The pure/impure split is exactly right.** `parse · place · route` compute a
model with no DOM in it; rendering and interaction are a thin adapter over that
model. That is the same boundary verax draws everywhere ("everything expensive
is opt-in per import", analyses that are pure over the design).

**Parse is already solved, and solved more correctly than the reference.**
verax must not port the reference's ad-hoc parser: `netlist/formats/spice.nim`
already reads SPICE decks into the format-agnostic `Netlist` graph, with
hierarchy (`.SUBCKT`/`.ENDS`), `.MODEL` passthrough, directive skipping, and —
unlike the reference — real value semantics (`parseSpiceMagnitude`,
`spiceValue`). The reference's shallow parse is precisely the case verax's
format layer was built to get right.

**Rail detection should be replaced, not copied.** The reference guesses from
names; verax has `netlist/kinds.isGround` / `isRail`, which answer from
`Net.kind`, `Pin.kind`, or the SPICE-reserved node `"0"`. Reuse those — the
annotation-driven answer is the improvement the reference lacks.

**The graph is already the right input.** Placement and routing need exactly
what verax's graph guarantees: enumerate `nl.nets`, walk `net.pins`, find
net-mates through `pin.component`, all without touching name-keyed tables. That
is the `Net.pins`/`Component.pins`/`Pin.component`/`Pin.net` bidirectionality
the core was built for.

---

## A practical Nim implementation for verax

In order of building:

1. **Reuse the netlist graph, not a parallel model.** Read a deck with
   `netlist/formats/spice.readNetlist` (or walk a DSL-built `Netlist`), and
   treat it as read-only input: placement/routing only ever *read* through the
   graph API, never mutate back-references. Symbol selection is keyed by
   `Component.kind` (verax is kind-based, not first-letter-based), with a
   small symbol registry; designators come from `kinds.designatorPrefixFor`.

2. **Introduce a renderer-neutral schematic scene.** A pure-data model —
   `Schematic`, with placed `SchematicPart`s (position, orientation, symbol),
   `SchematicWire`s (per-net polylines), junctions, supply symbols, and labels,
   all in world units with no SVG or DOM types. This is the renderer-neutral
   middle layer the reference lacks, and it is what makes the rest testable.

3. **Place and route are pure `proc(nl: Netlist): Schematic`.** Deterministic,
   no I/O, no simulator — mirroring the repo's habit of making analyses pure
   over the design and pinning output shape in tests. Port the reference's
   force-directed placement and MST/L-bend routing directly, but drive rail
   decisions from `kinds.isGround`/`isRail` and keep symbol/kind selection in a
   registry so it stays extensible.

4. **Emit SVG first.** A stdlib-only writer (like the `formats/` contract)
   that renders the scene as self-contained SVG, resolving colours to literals
   so the file is portable — exactly what the reference's export step does.
   Emitting the scene as JSON alongside costs nothing and readies step 5.

5. **An interactive browser frontend is optional and out-of-library.** The
   library's job ends at "produce an SVG/JSON scene". Interactivity
   (pan/zoom/hover-highlight/drag-to-rearrange) is a static HTML+JS shell
   consuming that scene — or, since place/route are pure and stdlib-only, the
   whole pipeline can be compiled to JS with `nim js` and run in-browser with
   no backend at all. Keep it a separate package, the way `python/` is:
   "opt-in per import" applies to the simulator, and a visualizer is no
   different.

Dependency direction stays intact: the scene/placement/routing module is a new
leaf depending only on `netlist` (and `units`/`eng` below it). It must not
import `spice`, `analysis`, `contract`, or `pcb`; SVG/JSON emission is a writer
beside the other format writers.

**Scope, stated plainly:** this would be a *heuristic visualizer* — a fast,
read-only "does the topology look like I think it does" view of a netlist. It
is not a SPICE parser (verax already has one), not a simulator, and not an EDA
tool: no signal-flow placement, no DRC, no BoM, no round-trip. Signal routing
*is* obstacle-aware (it keeps a fixed clearance from component bodies and
reaches pins directly through short outward stubs), but the placement is still
heuristic, so the picture is meant to be read by a human, not trusted by a
tool.

---

## Phase II: hierarchical HTML renderer

Phase I stops at one flat scene → one SVG/JSON file. Phase II adds the one
piece of hierarchy the reference never had — and stops deliberately short of a
schematic editor. The model is unchanged: a **scene** is the renderable view
of one `Netlist` level; **navigation** walks `Netlist.children`/`parent`.

**One scene per level; instances render as boxes.** A component whose
`subNetlist != nil` is drawn not as a device symbol but as a box labelled with
its designator, carrying the child's `ports` in declaration order as named
ports — the same order `addPort` established and `instantiate` turned into the
instance's pins, each with `hierNet` pointing down into the child. Those pins
sit on the parent level's nets like any other pin, so the existing placement
and `Net.pins`-based wiring already draw the links between a box's ports and
the surrounding parts; the only new rule is that a wire never crosses a level
boundary by itself — an instance pin *is* the boundary, and its far side
belongs to the child's scene.

**Navigation, not flattening.** Clicking a box renders that child's scene; a
breadcrumb shows the current scene and every ancestor, and clicking an
ancestor pops back. A scene's address is its instance path joined with
`hierSep` (`.`), the same shape `hierName` builds and `findNet`/`findComponent`
resolve — `XL.XA`, with the root as the empty path. The browser holds this as
plain state: a **scene stack** (current path plus ancestor paths) and a
per-level **scene model** (parts, wires, ports, and each box's child path).
Re-rendering is then just "get or compute the scene at path P", and back/up is
a stack pop, so there is no fragile URL↔object mapping to keep in sync.

**SVG/HTML split.** The schematic stays SVG, produced by Phase I's writer with
device symbols replaced by boxes at hierarchy edges; the chrome — breadcrumb,
click targets, tooltips — is HTML layered over it. Each box carries its child
path as a data attribute, so one click handler drives all navigation.

**Initial limitations, stated plainly.** Wires exist only *within* one level;
the only hierarchy edges are instance ports, so there is no arbitrary
cross-hierarchy wiring — a net cannot reach from inside one child into a
sibling. It is a viewer, not an EDA editor: descend, ascend, pan, zoom, hover
— no editing, no port reordering, no net renaming, no save or netlist
round-trip. Placement stays per-level and heuristic, so a child's port layout
is not promised to line up with its parent box's ports. And as in Phase I, the
graph is read-only input: `children`, `ports`, `hierNet` and `hierSep`-addressed
paths are consulted, never mutated.
