# Collapsing arrays of repeated subsheet and component instances

> **Status:** implemented. `src/verax/schematic/arrays.nim`, on by default via the
> `lsArrays` (subsheet instances) and `lsPartArrays` (raw components) pipeline
> stages.

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

- `ArrayOrigin` = `aoSubsheet` / `aoComponent` — which of the two passes below
  built a given `PartArray`; carried through to `arrayReport*`'s `origin`
  field ("subsheet" / "component").
- `ArrayPortClass` = `apCommon` / `apDistributed` / `apChained` / `apIrregular`.
- `ArrayPort` — one subsheet port (or component pin) seen across every member:
  `nets` (member order, `""` for open), `cls`, `dir`, and per-class fields
  (`display`/`tag`, `head`/`tail`/`links`/`chainKey`/`chainLead` for a chain,
  `distinctNets`/`open` for irregular), plus `railCommon` (`apCommon` only:
  the shared net is ground/rail, so `pmBusBar` is suppressed at that pin —
  see "Component arrays" below).
- `PartArray` (named `SubsheetArray` before component grouping existed) —
  `origin`, `members`, `rep` (`members[0]`), `label`, `ports`.
- `ArrayPlan` — `arrays: seq[PartArray]`, `byRep`, `hidden` (the designators
  `prepare` drops), `portOfPin`, `suppressed` (nets that never route: chain
  links, distributed members after the first), `groupOf` (distributed member
  net → drawing port), `extraPins` (chain head/tail re-homed onto the
  representative), `arrayNets` (what `finish` skips in the net-name pass).

`buildSubsheetArrays(nl, bundles, plan: var ArrayPlan)` — one pass over
`nl.components`: signature grouping (keyed on `subNetlist.name` + the pin-key
sequence), a no-op under three instances, the `brCollapsed` decline,
sub-grouping, per-port classification, chain pairing (a reversible walk keyed
on `nameDir`/`hierDir` to orient the two halves), display allocation
(`uniqueDisplay`), and registration into `plan` (`registerArray`) — all shared
verbatim with the component pass via `classifyGroup`/`addSignatureArrays` (see
"Component arrays"). `arrayPlan(nl, bundles): ArrayPlan` is the standalone
subsheet-only convenience wrapper: build, then `finalizeArrayPlan`, which
derives `suppressed` for every distributed group from the *final* `groupOf`
and only then runs a **totality `doAssert`**: every net named by a hidden
member's pin must be suppressed, in `groupOf`, still on the representative's
own pin, on an irregular port, or owned by a bundle. A net every pin of which
sits on a hidden member and is in none of these would vanish with no marker —
a path-integrity property, so an assertion is the right instrument.

Plain-data bridges (spliced after `symbols.nim`, so every hand-off is plain
data — the `bundleGroupsFor`/`laneOf` pattern): `arrayLabelFor`,
`arrayTitleWidth` (box-top room for `"X1..X8"` + `"xN"`), `arrayPinFor` (mark /
tag / members / overridden net for one representative pin), `arrayRouteFor`
(skip / group for one `nl.nets` entry; `first` is `true` whenever this branch
is reached at all, since `suppressed` already excluded every other member of
the same group by construction). The chain-arc pass in `routing.nim` reads
`PartArray.ports` directly for the OUT/IN pin names.

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
9. (Later) `pipeline_types.nim` — `lsPartArrays` immediately after `lsArrays`.
   `arrays.nim` — `classifyGroup`/`addSignatureArrays`/`registerArray` factored
   out of the subsheet pass so `buildComponentArrays` can call them verbatim;
   `finalizeArrayPlan` split out so it runs exactly once over the union of
   both passes. `state.nim` — the component pass run under `lsPartArrays`
   right after `lsArrays`, and array representatives added to
   `compositePlan`'s exclusion set. `svg.nim`/`finish.nim` — the `PinMark`
   glyph pass and the `xN` badge generalized to a non-box symbol. See
   "Component arrays" below.

## Component arrays

Plain components repeat too: `designs/xbar_rf.nim` has eight SMA connectors,
eight ADG904 switches and eight 50-ohm termination resistors, drawn today as
24 separate symbols and their fan of wires with nothing telling the reader
they are one circuit repeated eight times. `buildComponentArrays` extends the
same collapse to a repeated **raw component** — `Component.subNetlist == nil`
— reusing every piece of the subsheet machinery above (`classifyGroup`, the
four port classes, `registerArray`) except candidacy and one extra veto.

Per the user's decision, grouping is **per component, not per motif**: an
8x(R+C) filter bank draws as one `R x8` and one `C x8`, never one merged
"filter x8" glyph — the two are different parts, and a reader must still be
able to ask "which resistor is this" independently of "which capacitor is
this".

Fixed decisions specific to this pass:

1. **The identity key** is
   `kind \x1f value \x1f partNumber \x1f name \x1f <pin names> \x1f <pin kinds>`.
   `value` is in the key deliberately (a 10k and a 2k bank must never merge);
   other attrs (`package`, `dielectric`, ...) are not, since they do not
   change the drawing. **A component with *neither* a stated value nor a part
   number excludes it from candidacy outright**, checked before the key is
   even built — the collapsed symbol shows one value, and a blank one asserts
   nothing about the N real parts it stands for. `xbar_rf`'s termination
   resistors state `value`; its SMA connectors and ADG904 switches carry no
   `value` at all but state `partNumber` — identified by what they *are*
   rather than what they measure, just as real an identity. This also
   happens to be the guard that keeps this codebase's own topology-only test
   fixtures (a resistor chain or star stating neither, built to exercise
   placement/routing, not this feature) from silently qualifying.
2. **Excluded from candidacy**: `c.subNetlist != nil` (the subsheet pass owns
   those), `isPackaged(c)` (a multi-section package already claims
   `SchematicPart.label` for `"U10A"`, and the two labels would fight), and
   any member in a `brCollapsed` bundle (unchanged from the subsheet pass).
3. **The all-common decline.** A candidate group must have at least one port
   classified `apDistributed` or it is dropped. `xbar_rf`'s eight `CBY*` caps
   are all on `(v3v3rf, gnd)` — both ports `apCommon` — which is a *bank*, not
   parallel channels, and `composites/passive.parallelStackKind` already draws
   a bank better as a visible stack of eight; without this rule the array
   would steal it and hide the count behind an `xN` badge instead of N
   visible bodies. (A port classified `apDistributed` can never itself be a
   rail — the classifier routes a rail-differing port to `apIrregular`
   first — so no separate rail carve-out is needed here.)
4. **Chain pairing is skipped for a non-box representative.** The
   recirculation arc is a fixed staple drawn on the *box interior*; a
   resistor symbol has no interior to draw one on. A series ladder of raw
   components therefore degrades to *distributed*, gated on the same box
   predicate `symbolFor` already computes (`symbolFor(rep).isBox`).
5. **A net distributed at both ends** is the one genuinely new failure mode:
   `8x(R+C)` gives `in_i -[R_i]- mid_i -[C_i]- gnd`, and every `mid_i` sits on
   the R array's port 2 *and* the C array's port 1. Suppressing per-array (as
   the subsheet-only pass safely could, since a net was never claimed twice)
   would let the two arrays — enumerating members in independent orders —
   suppress overlapping-but-different subsets of the eight `mid_i` nets, in
   the worst case suppressing every one, so the bus never routes; the
   totality assertion does not catch it, since every net is still accounted
   for (just unroutable). Fixed by `finalizeArrayPlan`: `suppressed` is
   derived from the *final* `groupOf` (after every pass has registered),
   bucketing nets by their `(array, port)` value and keeping the one that
   comes first in `nl.nets` order — well-defined regardless of which array
   ends up owning the group. `arrayRouteFor`'s `first` no longer compares
   against the port's own member-order `nets[0]`: it is simply `true`
   whenever a net survives the `suppressed` check, which by construction is
   exactly one member per group.
6. **`pmBusBar` on a glyph-drawing pin.** An `apCommon` port whose net is
   ground or a rail already draws its own terminal glyph there; the tick
   collides with it on a two-terminal symbol (and is merely redundant on a
   box). `ArrayPort.railCommon` records this at classification time for both
   passes, and `arrayPinFor` suppresses `pmBusBar` whenever it is set — a
   deliberate visual change to `spi_daisy_chain`/`spi_memories` too (their
   `vdd`/`gnd` bus-bar ticks disappear; `chainSheet()`'s test fixture gained a
   common **signal** port, `sel`, so the mark keeps real coverage).
7. **A component-array representative is excluded from `compositePlan`.**
   Unlike a subsheet representative (always a box — `isTraversable` wants
   `subNetlist == nil`, so it was never composite-eligible), a component
   array's representative is a flat two-terminal part still fully visible —
   exactly what `parallelStackKind`/`seriesChainKind`/pi/tee look for. Without
   the exclusion a termination resistor badged `x8` could be claimed as a
   member of a composite it does not belong to.
8. **A split visible only through declared bus/interface membership.** The
   sub-grouping this section shares with the subsheet pass (`subGroupsOf`)
   originally partitioned members by *raw net identity* — which finds nothing
   to split on a port whose members are N genuinely distinct nets, one per
   member, sharing no value at all. `xbar_rf`'s eight `rf_switch` instances
   bind `RFC` to `rin[0..3]` on four of them and `rout[0..3]` on the other
   four: no member shares a net with any other, yet the input/output boundary
   is exactly the two `x4` groups a reader expects, not one `x8`. The fix,
   `splitKeyOf`, is the value `subGroupsOf` counts instead of the raw net:
   `iface.instance` if present, else `bus.name`, else the net's own name (the
   historical fallback for a port with neither attr). Precedence matches
   `bundles.nim`'s own `iface.instance`-wins-else-`bus.name` rule — keying on
   the bare signal name first would fold every instance of a declared
   interface's same-named signal into one family and undo `spi_memories`'s
   three-way split. The same fix also splits `xbar_rf`'s `JIN*`/`JOUT*`
   connectors, its `RT_IN*`/`RT_OUT*` terminations, and its 24 address/enable
   pulldowns into an `en` `x8` and an `a` `x16`.

   The natural companion bug: a bus-fanned distributed port that splits this
   way is realistically also a `>= 3`-entity `brNetLabel` bundle (that is
   what makes a bus a bus, structurally), so "bundle wins at the pin"
   (decision 6 of the parent design's fixed decisions) suppresses the array's
   own mark/tag there — but the *representative's* drawn `net` field and its
   one surviving net-label tag still fell back to whichever single member
   binding the representative happened to keep (`"rin_0"`), which was
   correct when that component stood only for itself and became misleading
   once it stood for the whole array. `ArrayPort.bundleFamily`, set at
   classification time from `splitKeyOf` of the first bound member, and read
   by `arrayPinFor` (the pin's `net`) and `routing.nim`'s
   `arrayBundleLabelFor` (the one visible net-label tag an unmerged
   representative still draws), substitute the bus/interface name (`"rin"`)
   there instead. Every non-representative carrier — anything not hidden by
   an array — keeps its own precise per-net tag unchanged.

Verified: `nim c -r --path:./src tests/test_schematic.nim` — the
`component arrays` suite (classification, the N<3 floor and zero-value
inertness, the `lsPartArrays` stage-off byte-identity test, the all-common
decline, the both-ends-distributed fixture, value splitting the group, the
`isPackaged` exclusion, the chain-degrades-to-distributed fixture, the router
invariants plus `labelsClearOfGeometry`, a JSON round-trip and SVG glyph
probe, both bundle-interaction cases, the bundle-family pin/label fixture,
and the bus-family-only split fixture). `./bin/verax check
designs/xbar_rf.nim --schematic-only --keep-runs=out` and inspecting
`out/runFULL.svg`/`out/runFULL.html` is the worked example: two `connector x4`
boxes (input/output SMA edges), two `rf_switch x4` boxes (input/output
switch banks), two `resistor x4` symbols for the `RT_IN*`/`RT_OUT*`
terminations, one `resistor x8` and one `resistor x16` for the enable/address
pulldowns, the eight `CBY*` caps still a visible parallel stack, and zero
`fbUnrouted` fallbacks (every remaining fallback is a deliberate `fbNetLabel`
bus tag, each now reading its plain bus name).

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
