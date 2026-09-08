# Collapsing arrays of repeated subsheet instances

> **Status:** implemented. `src/verax/schematic/arrays.nim`, on by default via the
> `lsArrays` pipeline stage.

## Context

A design that instantiates one subcircuit many times — `designs/spi_memories.nim`
(nine), `designs/spi_daisy_chain.nim` (eight), `designs/riaa_preamp.nim` (two) —
draws today as N separate fallback boxes and their combined fan of wires.
`symbols.nim`'s `if c.subNetlist != nil: return box()` is the whole of the
current treatment: nothing groups the instances, so the reader gets no help
seeing that they are one sheet built N times, and no help telling a net shared
across every member from one that differs per member.

This adds a **collapse**: draw one representative box badged `xN`, drop the
other N−1 from the scene, and encode each subsheet port's wiring so the
difference is legible — **common** (one net, every member), **distributed** (N
nets, one per member), **chained** (member *i*'s output feeds member *i+1*'s
input — a daisy chain), or **irregular** (anything else, expandable in the
`runFULL.html` explorer).

`bundles.nim` is the template for the plumbing: a private pure-function plan,
an `lsX` stage consumed inside `prepare`, a zero-value early return that
guarantees byte-identical output when nothing groups, plain-data bridges into
the earlier-spliced `symbols.nim`, additive-only scene fields, a public
`arrayReport` for unit-testing classification without geometry. The structural
difference: a bundle collapses *pins within one box*; an array collapses *whole
boxes*, so N−1 components stop being drawn.

## Fixed decisions

1. **One plain box, `xN` badge.** No ghost stack. `SchematicPart.label` carries
   `"X1..X8"` (the same field that carries `"U10A"` for a package section);
   `SchematicPart.designator` is a join key and is **never** rewritten.
2. **On by default** via `lsArrays`, consumed inside `prepare` exactly as
   `lsBundles` is. A netlist with no ≥3-instance subsheet yields a zero-value
   `ArrayPlan` and byte-identical historical output (the reserved-stage test,
   `tests/test_schematic.nim`).
3. **Drop, not hide.** `prepare` filters the N−1 non-representative members out
   of `state.comps` before `state.syms` is sized. The filter this needs
   (`pinPos.hasKey && partIdxByDesig.hasKey`, `ownsPin`) already exists at every
   layout site — it was written for the sibling-clone case, and a hidden array
   member *is* that case.
4. **Every chained pair gets its own recirculation arc — a dashed annotation,
   not a routed wire.** A chained pair is drawn on one row (IN pin left, OUT
   pin right, same y), and its arc is a *fixed polyline* staple on the box
   interior: from the OUT pin a short way in, up ~18px, across to above the IN
   pin, down, into it. It reads as "this port feeds through all N instances",
   sits clear of the box-top title text, and — being on the box interior
   between its own two pins — is **exempt** from
   `distinctWiresNeverShareCollinearRuns` / `differentNetsRespectSeparation`
   (both skip `wkChain`). A parallel-chain group (sclk / cs / data all walking
   the same members) draws one such arc per pair, stacked; only the lead
   carries the `xN` link-count badge. No auxiliary lane is drawn; the box
   keeps its historical size.
5. **`wkChain`** is appended to `WireKind` (existing ordinals unchanged); its
   `members` carries the N−1 link net names (empty on a non-lead parallel
   arc), and `svg` draws it dashed with an arrowhead into the IN pin and,
   when `members` is non-empty, an `xN` badge.
6. **Sub-grouping.** Before classifying, an array is split by every *splitting*
   port — one whose nets partition the members into ≥2 groups each of size ≥2,
   with no member left open. Each sub-group of ≥3 collapses independently;
   `spi_memories`'s nine memories split three ways by SPI bus.
7. **Guards:** rail/ground ports are excluded from the classification vote;
   `N < 3` never collapses; a chain must be linear and complete (every member,
   no branch at any link net, no cycle) or the port degrades to *distributed*.
8. **Declining** an array means only "a member carries a `brCollapsed` bundle"
   (a point-to-point wire whose far end would vanish). A `brNetLabel` /
   `brScalar` bundle degrades cleanly over hidden members, so the array still
   collapses and that port is marked `bundled` — **the bundle wins at the pin,
   the array wins at the box.**

## Data model

`arrays.nim` types (all private except `arrayReport*`):

- `ArrayPortClass` = `apCommon` / `apDistributed` / `apChained` / `apIrregular`.
- `ArrayPort` — one subsheet port seen across every member: `nets` (member
  order, `""` for open), `cls`, `dir`, and per-class fields (`display`/`tag`,
  `head`/`tail`/`links`/`chainKey`/`chainLead` for a chain, `distinctNets`/
  `open` for irregular).
- `SubsheetArray` — `members`, `rep` (`members[0]`), `label`, `ports`.
- `ArrayPlan` — `arrays`, `byRep`, `hidden` (the designators `prepare` drops),
  `portOfPin`, `suppressed` (nets that never route: chain links, distributed
  members after the first), `groupOf` (distributed member net → drawing port),
  `extraPins` (chain head/tail re-homed onto the representative), `arrayNets`
  (what `finish` skips in the net-name pass).

`arrayPlan(nl, bundles): ArrayPlan` — one pass over `nl.components`: signature
grouping (keyed on `subNetlist.name` + the pin-key sequence), zero-value early
return under three instances, the `brCollapsed` decline, sub-grouping,
per-port classification, chain pairing (a reversible walk keyed on
`nameDir`/`hierDir` to orient the two halves), display allocation copied from
`bundles.uniqueDisplay`, the bridges, and a **totality `doAssert`**: every net
named by a hidden member's pin must be suppressed, in `groupOf`, still on the
representative's own pin, on an irregular port, or owned by a bundle. A net
every pin of which sits on a hidden member and is in none of these would vanish
with no marker — a path-integrity property, so an assertion is the right
instrument.

Plain-data bridges (spliced after `symbols.nim`, so every hand-off is plain
data — the `bundleGroupsFor`/`laneOf` pattern): `arrayLabelFor`,
`arrayTitleWidth` (box-top room for `"X1..X8"` + `"xN"`), `arrayPinFor` (mark /
tag / members / overridden net for one representative pin), `arrayRouteFor`
(skip / group / first for one `nl.nets` entry). The chain-arc pass in
`routing.nim` reads `SubsheetArray.ports` directly for the OUT/IN pin names.

Scene additions are additive only and `sceneSchemaVersion` stays **1**:
`wkChain` appended to `WireKind`; a new `PinMark` enum whose zero value
`pmNone` is the historical behaviour; `SchematicPin.mark`/`tag`;
`SchematicPart.count`/`members`. `json.nim` writes each **only when
non-default** and reads through `optInt`/`optStr`/`optArr`, so an array-free
scene's JSON is byte-identical to a pre-feature archive.

## Sequencing

1. `scene.nim` + `json.nim` — the additive fields. No behaviour change.
2. `pipeline_types.nim` — `lsArrays` between `lsBundles` and `lsSemanticSeed`.
3. `arrays.nim` — classifier + `arrayReport*` + `LayoutState.arrays`, plan
   computed but the `state.comps` filter not yet applied. Still byte-identical.
4. `state.prepare` filter + `symbols.nim` (`titleWidth`) + `routing.nim` (part
   loop, seed dedupe by point, port folding, distributed group route,
   chain-arc post-pass) + the `routeScene`/`recoverRouting` signatures.
   **This is the step to bisect to.**
5. `finish.nim` — `arrayNets` suppression.
6. `svg.nim` — the five glyphs (`wkChain` dashed arc, bus-bar tick, diagonal
   slash, forked cap, `xN` badge). ASCII `x`, not `×` — this file carries no
   font dependency.
7. `render.nim` — the explorer: `count` + `arrayMembers` per part, the
   instance→sheet table in `showProps` with a delegated handler,
   `showPinProps` handling array pins. No `src=` literal, `const MODEL` stays
   one line (the two `test_verify_keep` traps).
8. `designs/lib/spi_dev.nim` + `designs/spi_daisy_chain.nim`; the
   `designs/spi_memories.nim` 3×3 rewrite + `designs/CLAUDE.md`.

## Verification

- `nim c -r --path:./src tests/test_schematic.nim 2>&1 | grep -cE "FAILED|Error:"`
  returns 0, and the `subsheet arrays` suite (classification, N<3 floor,
  sub-grouping, totality at scene level, inertness, scene structure, the
  published-pennant trap, the three router invariants, JSON round-trip, SVG,
  the bundle interaction) all pass.
- `./bin/verax check designs/spi_daisy_chain.nim` exits 0 (the `dc_path_exists`
  claim on the SCLK strap), and its `runFULL` archive is one `SPI_DEV x8` box,
  one recirculation arc, zero fallbacks.
- `./bin/verax check designs/spi_memories.nim` exits 0; its `runFULL` archive
  is three `SPI_MEMORY x3` boxes.

## Risks

- **The vanishing-net risk** is closed by the totality assertion in
  `arrayPlan`.
- **Bundle/array precedence** — the `brCollapsed`-only decline keeps
  `spi_memories` collapsible; a `brNetLabel` bus (`wp`, the `spi[k]` interfaces)
  keeps its own drawing and that port reads `bundled` in `arrayReport`. The
  `[1:N]` treatment is not applied to a bundled port, so `wp` on the collapsed
  box shows the bundle's per-member tags rather than `wp[1:3]` — acceptable,
  the `xN` badge conveys the multiplicity.
- **The `bus` interaction shapes `spi_daisy_chain`** — a `bus` statement on the
  chain links would make `bundlePlan` claim all nine across nine entities as
  grouped net-label tags, downgrading every chained port to `bundled`; the
  links are declared as plain `net`s and the file header says why.
- **The `x` vs `×` glyph choice** in `svg.nim` — ASCII, deliberately, because
  the file carries no font dependency; it is the kind of thing that gets
  "tidied" later.
- **An array member cannot also be a composite member** — it is a box
  (`isTraversable` wants `subNetlist == nil`), so it never was.
- **Each chained pair gets its own recirculation arc**, a dashed annotation
  drawn as a tight staple on the box interior between that pair's IN and OUT
  pins (which share a row). It never leaves the box, so it cannot conflict
  with the sheet or with the box-top title text, and it is **exempt from the
  routed-wire collinear / separation invariants** (`wkChain` is skipped). A
  parallel-chain group draws one arc per pair, stacked; only the lead carries
  the `xN` link-count badge. No aux lane is drawn; the box keeps its
  historical size.
- **A pass-through strap keeps both port names.** `designs/lib/spi_dev.nim`
  publishes one internal net twice (`sclk_in` / `sclk_out`). `portDirection`
  sees one internal pin and would call both inputs, so `routing.nim` orients a
  net published under ≥2 plain port names by the `_in` / `_out` suffix and
  routes it to both pennants. Where that will not route on a crowded sheet the
  net falls back to a **by-name label** (`fbNetLabel`, teal) rather than an
  amber "unrouted" marker — a published net always has a defined external
  endpoint. Interface / bus ports are unaffected (`bundles.byPort` owns them).
