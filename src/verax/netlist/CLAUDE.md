# `netlist` submodule

The in-memory netlist and its file formats.

## Core

- **`types.nim`** — `Netlist`/`Net`/`Component`/`Pin` as `ref object`s with **direct references in both directions** (`Pin.component`/`Pin.net`, `Net.pins`, `Component.pins`, `Netlist.parent`/`children`), plus name-keyed `OrderedTable`s. ORC collects the cycles. Every entity has an open `attrs: OrderedTable[string, string]` bag so formats never extend the schema.
- **`graph.nim`** — **the only place allowed to mutate back-references.** Never hand-set `.net`/`.pins`/`.component`/`.parent`; use `addComponent`/`addNet`/`connect`/`disconnect`/`removeComponent`/`addChild`/`addPort`/`renameNet`/`clone`/`instantiate`/`adoptNet`/`adoptComponent`/`mergeNets`/`setModel`/`registerGlobalNet`.
  - `renameNet` leaves `ports` *keys* alone (a port name is the published interface).
  - Hierarchical names join with `hierSep` (`'.'`). `findNet`/`findComponent`/`findPin` try the **flat key first, then descend into children**, so one name works before and after `spice/flatten`. `findPin` splits **right to left** (XSPICE pins are named `name.p`).
  - `removeComponent` calls `disconnect`, which nulls `Pin.net` — **snapshot net names before removing** a component you're replacing.
- **Hierarchy** — a sub-netlist hangs off `Component.subNetlist`. `instantiate` deep-clones per instance, except nets in the `globalNets` table (e.g. `"0"`), which are shared by identity. An instance pin's `hierNet` points at the matching port `Net` inside the child.
- **`issue.nim`** — shared `Issue` type. Lives here (not `analysis`) because `netlist`, `pcb` and `analysis` all report through it.

## `region.nim` — growing a region from seeds

`growRegion(nl, seedParts, seedNets, rules)` is the one graph walk every scoping strategy (`spice/region_strategy`), the report's circuit view and isolation share. Breadth-first over nets; each part reached is asked `RegionRules.absorb(part, via)` -> `raInclude` (walk on through its other pins), `raBoundary` (kept, not walked) or `raDrop` (left out, recorded). `traverseNet(net, seeded)` decides whether a net is walked *from* (default: not a rail unless seeded). `maxHops` is a backstop; `closeCouplings` pulls in a pinless `K` once its inductors are in. Seed parts are always walked through all their pins — pass an IC as a boundary block, not a seed, when that would flood (the report does).

`flatName(component|net)` spells a hierarchical entity as `spice/flatten` will (`XA.XB.R1`; a port net takes its outer net's name; ground keeps its own). Static evaluators name their `AssertionResult.scope` with it so the report can find what they read in the flattened design.

## `annotations.nim` — the vocabulary

A typo'd `attrs` key is indistinguishable from an absent one (and `spice/models` would silently default it *and report that as an assumption*). The registry fixes that.

- **Bare key means registered, dotted key means owned.** Bare keys are validated (`validateAnnotations`, and at compile time inside `spec:`); `xspice.*`, `parasitics.*`, `role.*`, `ann.src.*`, `kicad.*`, `switch.*`, `notes.*` etc. never are. The live list is `verax annotations`.
- The registry is a runtime table seeded from a `const` — the `const` lets the DSL reject bad keys at compile time; the table keeps runtime registration possible.
- `parseAnnFloat` **rejects SPICE magnitude suffixes** (`"20m"`) rather than guess. Values are SI base units.
- Accessors return `AnnValue[T]{source, value}` (= `Stated[T]`, from root `stated.nim`) and are **pure and never default**. Typed accessors carry the unit type (`esr(c): AnnValue[Ohms]`; `annotationAs(e, key, Volts)` raises if the key's registered unit differs). `setRawAnnotation` clears the key's `ann.src.*` marker (a raw write is authored); `validateAnnotations` reports a marker whose value is gone (`annotation_orphan_provenance`).
- Never defaulting: inventing a stand-in is the consumer's policy decision. `Assumption` lives here because `spice` produces them and can't import `analysis`.
- `akEnum` (`part_use`) and `akBool` (`dnp`, `bom_exclude`) values are checked **at the setter**, not only at `readiness`.
- `package` (case size, keys the parasitics table) and `footprint` (land pattern `"Lib:Name"`) are deliberately separate keys.
- `mpn`/`manufacturer` are distinct from `Component.partNumber` (which may be a house number). Free-text labels go in `description`, not `partNumber`.
- `notes:` block → `notes.<key>`, read by `notesOf`/`noteOf`: the way to attach free-form author data without tripping misspelling warnings.
- `pull_up`/`pull_down`/`pull_rail` (pin scope) state a part's internal reset-state pull on one pin; `pullRail(p)` resolves a pull-up's rail (named pin, else the part's one supply net). Read pulls through `pinmux.pinPull`, never these raw — it also consults the part's table.

## `kinds.nim` — electrical classification

Shared by `analysis/io_check` (DC path walks) and `spice/isolate` (what to absorb); they must agree, so it lives below both.

- `classifyConductivity(c)` — whole-component, unchanged on purpose (`isPassive` and `schematic` depend on it).
- `conductivityBetween(c, a, b)`/`conductiveExits(c, fromPin)` — per pin pair: (1) a stated `traversal` spec answers exclusively (undeclared pairs on a part with *some* edges are blocking); (2) two connected pins → `classifyConductivity`; (3) more than two → `condAmbiguous`, never guessed. DC walks (`io_check.dcReachable`, `static.dcConnected`) go through `conductiveExits`.
- `behaviouralKinds` (controlled sources) and `couplingKinds` (`mutual_inductance`, pinless `K` card) are accepted by `isPassive` (so isolation keeps them) but are **not** DC paths (so `io_check` never walks through them — a transformer is an isolation barrier).
- `designatorPrefixFor(kind)` (schematic/BoM designator, `FB` for a bead, fallback `U`) is **deliberately separate from `formats/spice.prefixByDeviceKind`** (SPICE device letter, `L` for a bead). Deriving one from the other is how `FB1` got simulated as a CCCS.
- `isRail`/`isGround` accept *either* `Net.kind` or a connected `Pin.kind` (netlists populate them inconsistently).
- `connectorKinds`/`isConnector` (moved down from `spice/boundary`, which re-exports them): **a connector's pin kinds and modports describe what is plugged in** (a probe's TCK is `ptOutput`). `io_check` treats such a driver as present only while mated.

## Attrs-backed side modules

All store state in namespaced `attrs` so it survives `clone`/`instantiate`/`flatten`/`extractSubcircuit`/`isolate` for free, and is expected to be lost on a SPICE round trip. Each has a pure accessor plus a `validate*` returning `Issue`s, reports only what was *stated*, and never nags a design that stated nothing.

- **`layouthints.nim`** — `layout.side`/`mirror`/`power`/`variant`. Rendering hints, never registered annotations; strictness comes from the DSL's `layout:` block. `*Auto` is both the zero value and "not stated". `variant` is a free string because `pcb/variant`'s registry can't be imported here. `layoutHintKeys` is the one place to add a key.
- **`traversal.nim`** — `traverse:` block: author-stated pin-to-pin conduction (e.g. an RF switch). **Owns storage, grammar and validation only — resolution is in `kinds.nim`** (putting it here would create an import cycle). An unknown pin name is `sevError` (it silently changes DC-path conclusions). `-` is not the pin separator (`IN-` is a real pin name). In `schematic`, only `constrained.pathsFrom` uses the widened `isTraversable`; composite recognizers keep `isTwoTerminal`.
- **`environment.nim`** — board ambient range (`t_ambient_min/max`, netlist scope) and per-part rise (`delta_t`), stated separately. **Models nothing** and is **not** passed as `.options temp`. `partTemperatureRange` shifts both ends by the rise. `environmentOf` reads the root. `temperatureRise` defaults to 0 with `annDefaulted` — the one accessor that defaults (an unstated rise and a zero rise agree for non-dissipating parts); `deltaT` is the pure accessor.
- **`bomdefaults.nim`** — `bom.*` procurement defaults, resolved **most specific first, field by field** up the parent chain. No tree-wide override: setters write to the netlist given (inside an `instance ..., with =` proc, that's the clone). A `bom:` default never overrides a part's own `spec:`. Unstated fields are `""` or `none` (`tolerance`, `derating` are `Option`). `bomDefaultKeys` is shared with `dsl.handleBom`.
- **`packages.nim`** — one physical package, several channels (a dual op-amp = N `Component`s sharing a die). Membership in `package.ref`/`section`/`def` attrs; a `PackageDef` registry keyed by part number (pure data, **no built-ins** — catalogues live in `designs/lib/`). `pkg.section("A", "U1")` for `instance ..., with =`; `pkg.assign(nl, "A", "U1A")` for flat netlists. **Global-pin checks compare by object identity via `outermostNet`, not by name** — both channels' `VP` nets share a name.
- **`pinmux.nim`** — what each pin may be muxed to. `PartPinmux` registry, no built-ins (`designs/lib/stm32h563.nim`). Capability `"SPI1.sclk"` splits on the **last** dot. `port` stamps `pinmux.peripheral`/`signal` from `peripheral =` and `functions = {...}`; `connectPort` stamps `iface.def`. Peripheral is **explicit, not inferred**; a `nil` table means check nothing; `functions = {"cs_1": "GPIO"}` exists because only one CS is hardware NSS. Signal names are interface names (`cs`, not `NSS`). `pinmux_pin_unknown` is a warning unless the table says `complete = true`. **`resetPulls`** holds the part's reset-state pulls by pin (a datasheet fact, inherited by every design using the part); `pinPull(p)` is the one read — a pull stated on the pin wins, then the table.
- **`interfaces.nim`** — scalar-net views for buses/interfaces; `bus.*`/`iface.*` attrs are the source of truth. `promotePortDirections` copies child port direction and parent interface identity to instance pins. A shared signal released by all participants suppresses multi-inout/undriven findings, but two `ptOutput` drivers still conflict. `narrow(i, signal, k)` is a **pure value-space** copy (never use `busOf`, which writes `bus.index`). Width-1 groups are the bare label, wider ones `label_0…`. Differential pairs are ordinary two-signal defs (`p`/`n`); checking lives in `contract`. `spiInterface` implies `spi`; fan-out over a wide `cs` is `contract/design.addImpliedRoles`' job.

## `formats/`

Each format implements `readNetlist(s: Stream, name = "")`/`writeNetlist(nl, s)` plus file wrappers; formats depend on the core, never the reverse. `formats/spice.nim` is the only one.

- Positional parsing per designator prefix; `X`/`U` resolve against `.SUBCKT`s (forward refs and nesting OK). `.MODEL` cards are stored verbatim; other dot-cards are skipped on read. Unknown prefixes fall back to `pin1..pinN`. `Pin.kind` doesn't survive a round trip (format limitation).
- **`spiceValue(x)`** is the only correct way to format a synthesized value — always scientific with an explicit exponent.
- `parseSpiceMagnitude` refuses anything not purely a magnitude and **refuses RKM** (`2k2`): ngspice reads it as 2000, an EDA tool means 2200.
- `prefixByDeviceKind` has write-side-only letters: `E`/`G` (controlled sources), `F`/`H` (still emit wrong args, but without them a `cccs` would be read as a **capacitor**), `S`/`W` (switches), `K` (pinless — `formatDeviceLine` resolves `attrs["spice.couples"]` to deck designators at write time), `A` (code models — **never in the forward map**; the `A` line is written from `attrs["xspice.ports"]` and can't be read back).
- **`deckDesignator(comp)` derives the device letter from `kind` and *prepends* it** (`FB1` → `LFB1`, never `L1`, so it stays unique). SPICE infers device type from the first letter only; an inductor filed as `C12` would simulate as a capacitor. Unknown kinds are left alone. Instances are always `X` (`U` is a distributed RC line to ngspice).
- `writeNetlist` calls **`checkDeckDesignators`** per level and raises on collisions (`XA.R1` and `RXA.R1` → one deck line); prepending isn't injective.
- `writeNetlist`'s optional `cards` are written before `.END` (how `spice/ngspice` attaches analysis cards). `writeNetlist` drops `Netlist.ports`; use `writeSubcktDefinition` for a reusable template.

## `dsl.nim`

Opt-in macro DSL. `netlist("name"): ...` and `subckt("name", [ports]): ...`; `instance designator, tmpl, [nets]` or `{"port": net}` (by name). Expands only to `graph.nim` calls. Use the `netlist-dsl` skill for syntax.

- Bare-identifier names become real `let`s (typos are compile errors). `kind`/`name`/`partNumber` are typed fields; other `key = value` pairs land in `attrs` (permissive) — except a `Quantity` value (`pull_up = 40.kohm`), which goes through the typed `setAnnotation` (registered key, unit checked), since `$` would store `"40.0 kohm"`.
- **`spec:` is strict**: keys validated against the registry at compile time; values are expressions. `environment:` is `spec:` at netlist scope. `layout:` and `bom:` are their own strict handlers (namespaced keys, not registry keys). `notes:` is the explicit free-form escape.
- `net [a, b, c], ...` declares a group (one `let` each); `name =` is refused on a group.
- `model "<name>", "<card>"` goes through `graph.setModel`; the card is **never parsed**. A registered model makes `kinds.hasDeviceModel` true, so `isPassive` accepts the part and `spice/models` stops standing it in.
- `for`/`if`/`case`/`when` are control flow over DSL statements only. A `let` bound inside is scoped to the branch — look things up with `findComponent` afterwards. `role`/`require` inside them are rejected. `discard` is an empty branch; `discard <expr>` is refused.
- Parameterized circuits: put a `subckt` block in a `proc` (`designs/lib/filters.nim`).
- **Omitted designators** are generated per netlist from `kind` (`graph.addGenerated`), marked `designator.generated`. They're positional — fine for parts nothing names or places; write a designator for anything you'll refer to.
- **`instance ..., with = proc(sub: Netlist)`** runs on the instance's clone immediately after `instantiate` — the way to vary per-instance parts by local designator, assign package sections, or set `bom:` defaults per instance.
- `simReplace kind=..., name=..., suits=...:` inside a `component` only *adds* to `Component.simModels`; `simDefault` picks the default. Duplicate `name` raises. See `spice/CLAUDE.md`.
- `buildNetlistBody*` is the extension point `contract/dsl` reuses.
